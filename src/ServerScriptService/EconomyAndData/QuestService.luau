--!strict
--[[
	QuestService
	Owns every daily quest / achievement ladder defined in
	Configs.QuestDefinitions: accruing progress, rolling the day over, and
	paying out claims.

	## Server-authoritative claims

	The client sends only a category id. It does not send a tier, an amount,
	or a currency — QuestService re-reads QuestDefinitions itself and pays
	from that. The only claim it will honour is `claimed + 1`, and only once
	the recorded progress genuinely reaches that tier's requirement, so the
	worst a tampered client can do is ask for a reward it has already earned
	and would have been given anyway.

	## Progress sources

	  Playtime    a tick loop, PLAYTIME_TICK_SECONDS at a time
	  Laps        CheckpointValidator.grantLapReward calls RecordLap
	  Poses       TeleportPoseService.PerformPose calls RecordPose
	  DailyLogin  computed on join from LastLoginDay
	  Invite      GetJoinData().ReferredByPlayerId on the joining player

	## The daily cycle is derived from the date, not from a reset pass

	For a ResetsDaily category, the stored claim count is believed only when
	its stored day stamp is TODAY (see claimedTiersFor). That makes each daily
	reward exactly once per day in BOTH directions: a reset that never ran
	cannot leave yesterday's claims blocking today's ladder, and a reset that
	ran twice cannot re-open a ladder already paid for today. The periodic
	reset loop only zeroes progress counters and pushes the UI — nothing about
	"has this already been paid" depends on it having fired.

	## The day boundary is checked on a loop, not only on join

	A player who leaves a session running past midnight must roll over too.
	Doing it only on join would mean their dailies silently never reset until
	they rejoined, which is exactly the sort of thing that gets reported as
	"quests are stuck".

	## What this module deliberately does NOT do

	It never writes Gold/TotalFans directly without also adding to the
	LifetimeQuestGold/LifetimeQuestFans audit totals in the same function, so
	"what have quests actually paid this player" stays answerable from the
	save alone rather than by replaying logs.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestDefinitions = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("QuestDefinitions"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local ProfileManager = require(script.Parent:WaitForChild("ProfileManager"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))

local SECONDS_PER_DAY = 86400
-- Coarse on purpose. Playtime rewards are measured in whole minutes, so a
-- finer tick would just be more writes to the same in-memory number for no
-- observable difference. See the note on ProfileStore write frequency in
-- PROJECT_STATE — nothing here touches the DataStore API directly.
local PLAYTIME_TICK_SECONDS = 15
local DAY_ROLLOVER_CHECK_SECONDS = 60
-- How long to wait for ProfileManager to finish its session claim before
-- giving up on a joining player's login streak. ProfileManager has no
-- "profile ready" signal yet (there is a TODO for one); until it does, this
-- polls rather than racing it.
local PROFILE_WAIT_TIMEOUT_SECONDS = 30

local QuestService = {}

local function currentDayNumber() : number
	return math.floor(os.time() / SECONDS_PER_DAY)
end

local function getQuestData(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return nil
	end
	return profile.Data.Quests
end

-- Progress for one category, in that category's own unit. Kept in ONE place
-- so the claim check and the UI payload can never disagree about how far
-- along a player is — the classic way a rewards system pays for progress the
-- player can't see, or refuses progress they can.
local function progressFor(questData, categoryId: string) : number
	if categoryId == "Playtime" then
		return math.floor(questData.PlaytimeSecondsToday / 60)
	elseif categoryId == "Laps" then
		return questData.LapsToday
	elseif categoryId == "Poses" then
		return questData.PosesToday
	elseif categoryId == "DailyLogin" then
		return questData.LoginStreakDays
	elseif categoryId == "Invite" then
		return questData.InvitesAccepted
	end
	return 0
end

-- How many tiers of `category` count as already claimed RIGHT NOW.
--
-- For a daily category this is derived from the calendar, not from whether a
-- reset pass has run: the stored count is believed only when its day stamp
-- is today, and otherwise reads as 0. That is what makes each daily reward
-- exactly once per day in both directions — a reset that never fired cannot
-- leave yesterday's claims blocking today's ladder, and a reset that fired
-- twice cannot re-open a ladder that was already paid for today.
--
-- Every claimable/UI/claim decision goes through this one function, so the
-- panel and the payout can never disagree about what has been claimed.
local function claimedTiersFor(questData, category: QuestDefinitions.QuestCategory) : number
	local claimed = questData.ClaimedTierByCategory[category.Id] or 0
	if claimed == 0 then
		return 0
	end
	if category.ResetsDaily and (questData.ClaimedDayByCategory[category.Id] or 0) ~= currentDayNumber() then
		return 0
	end
	return claimed
end

-- Zeroes the daily PROGRESS counters when the stored day is stale. Claim
-- state needs no equivalent here — claimedTiersFor derives it from the day
-- stamp instead, so this function is not load-bearing for correctness; it
-- only keeps the stored numbers tidy and lets callers know when to push.
--
-- Returns true if anything actually changed, so the periodic loop can skip a
-- pointless client push on the 99% of ticks where nothing happened.
local function applyDailyResetIfNeeded(player: Player) : boolean
	local questData = getQuestData(player)
	if questData == nil then
		return false
	end

	local today = currentDayNumber()
	if questData.LastResetDay == today then
		return false
	end

	questData.LastResetDay = today
	questData.PlaytimeSecondsToday = 0
	questData.LapsToday = 0
	questData.PosesToday = 0
	return true
end

local function buildStatePayload(player: Player) : { [string]: { Progress: number, ClaimedTiers: number } }?
	local questData = getQuestData(player)
	if questData == nil then
		return nil
	end

	-- Progress and claim counts only. The client already has
	-- QuestDefinitions from ReplicatedStorage, so shipping names, targets and
	-- reward amounts on every push would be re-sending a constant.
	local payload = {}
	for _, category in QuestDefinitions.Categories do
		payload[category.Id] = {
			Progress = progressFor(questData, category.Id),
			ClaimedTiers = claimedTiersFor(questData, category),
		}
	end
	return payload
end

local function pushState(player: Player)
	local payload = buildStatePayload(player)
	if payload ~= nil then
		Network.Quests.QuestStateChanged:FireClient(player, payload)
	end
end

QuestService.PushState = pushState

-- True if `categoryId` has a tier ready to claim right now. Used by the UI
-- badge (the "you have something waiting" dot), which is the whole reason a
-- player opens the panel at all.
function QuestService.HasClaimableTier(player: Player) : boolean
	local questData = getQuestData(player)
	if questData == nil then
		return false
	end

	for _, category in QuestDefinitions.Categories do
		local nextTier = category.Tiers[claimedTiersFor(questData, category) + 1]
		if nextTier ~= nil and progressFor(questData, category.Id) >= nextTier.Requirement then
			return true
		end
	end
	return false
end

-- The one place a quest reward is ever paid. Every guard that matters lives
-- here and nowhere else.
local function tryClaim(player: Player, categoryId: string)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local category = QuestDefinitions.ById[categoryId]
	if category == nil then
		-- Unknown id: a stale client, or a crafted request. Either way there
		-- is nothing to pay and nothing to say.
		return
	end

	-- Roll the day over BEFORE evaluating the claim. Otherwise a client that
	-- held the panel open across midnight could claim a tier against
	-- yesterday's progress that this very call is about to wipe.
	applyDailyResetIfNeeded(player)

	local questData = profile.Data.Quests
	local claimed = claimedTiersFor(questData, category)
	local nextTier = category.Tiers[claimed + 1]
	if nextTier == nil then
		return -- ladder already fully claimed
	end

	if progressFor(questData, categoryId) < nextTier.Requirement then
		Network.Track.ShowNotification:FireClient(player, "NOT THERE YET!")
		SoundDirector.PlayForPlayer(player, "SkillBlocked")
		return
	end

	-- Committed. The claim counter and its day stamp are advanced in the same
	-- breath as the payout, with no yield between them, so there is no window
	-- in which a second request could observe the old counter and pay twice.
	-- The day stamp is written on every claim, not just the first of the day,
	-- so it always describes the count sitting beside it.
	questData.ClaimedTierByCategory[categoryId] = claimed + 1
	questData.ClaimedDayByCategory[categoryId] = currentDayNumber()

	local reward = nextTier.Reward
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		-- The pass is "Double Gain Fans and Gold", so it applies to both
		-- currencies here, matching how lap and Grand Prix rewards treat it.
		reward *= 2
	end

	if category.RewardCurrency == "Gold" then
		profile.Data.Gold += reward
		questData.LifetimeQuestGold += reward
		SoundDirector.PlayForPlayer(player, "GoldGain")
	else
		profile.Data.TotalFans += reward
		questData.LifetimeQuestFans += reward
		SoundDirector.PlayForPlayer(player, "FanGain")
	end

	ProfileManager.SyncAttributes(player)
	Network.Track.ShowNotification:FireClient(
		player,
		`{category.DisplayName} — +{Utils.FormatNumber(reward)} {if category.RewardCurrency == "Gold" then "💰" else "🌟"}`,
		"Pop"
	)
	pushState(player)
end

-- Called by CheckpointValidator.grantLapReward, alongside the lifetime
-- TotalLapsCompleted increment — the daily count is the same fact recorded
-- with a different lifetime, so it is recorded at the same moment.
function QuestService.RecordLap(player: Player)
	applyDailyResetIfNeeded(player)
	local questData = getQuestData(player)
	if questData == nil then
		return
	end
	questData.LapsToday += 1
	pushState(player)
end

-- Called by TeleportPoseService for every accepted pose — i.e. one that
-- passed the AtFanBox check, the known-emote check and the anti-spam
-- cooldown. Deliberately counts the POSE, not the reward: the Gold tip is
-- rationed to once per ten-minute window, but the quest ladder is about how
-- often you play to the crowd, so the two must not share a gate.
function QuestService.RecordPose(player: Player)
	applyDailyResetIfNeeded(player)
	local questData = getQuestData(player)
	if questData == nil then
		return
	end
	questData.PosesToday += 1
	pushState(player)
end

-- Streak rule, in full: same day = already counted, do nothing; exactly
-- yesterday = the streak continues; anything else (including a brand-new
-- profile, whose LastLoginDay is 0) = the streak broke and restarts at 1.
--
-- Restarting also has to clear the DailyLogin claim counter, or a player who
-- reached day 5, lapsed, and came back would be sitting on 5 claimed tiers
-- against a streak of 1 and could never claim anything again.
local function applyLoginStreak(player: Player)
	local questData = getQuestData(player)
	if questData == nil then
		return
	end

	local today = currentDayNumber()
	if questData.LastLoginDay == today then
		return
	end

	if questData.LastLoginDay == today - 1 then
		questData.LoginStreakDays += 1
	else
		questData.LoginStreakDays = 1
		-- DailyLogin is NOT a ResetsDaily category, so claimedTiersFor does
		-- not date-guard it — a broken streak has to clear the count here or
		-- a player who reached day 5, lapsed, and came back would sit on 5
		-- claimed tiers against a streak of 1 and never claim again.
		questData.ClaimedTierByCategory.DailyLogin = 0
		questData.ClaimedDayByCategory.DailyLogin = today
	end
	questData.LastLoginDay = today
end

-- Credits whoever invited this player, if anyone. ReferredByPlayerId is set
-- by Roblox only for a join that actually came through an in-experience
-- invite, so it cannot be spoofed by a normal join.
--
-- KNOWN LIMIT: the inviter is credited only if they are still in this
-- server. Crediting an absent inviter would need a cross-session store
-- (their profile is session-locked to whichever server they are on, or to
-- nothing at all), which is a bigger piece of machinery than this ladder
-- justifies today. Documented rather than silently half-working.
local function creditInviter(joiningPlayer: Player)
	local joinData = joiningPlayer:GetJoinData()
	local inviterUserId = joinData and joinData.ReferredByPlayerId
	if inviterUserId == nil or inviterUserId == 0 or inviterUserId == joiningPlayer.UserId then
		return
	end

	local inviter = Players:GetPlayerByUserId(inviterUserId)
	if inviter == nil then
		return
	end

	local questData = getQuestData(inviter)
	if questData == nil then
		return
	end

	-- Dedupe by the joining player's user id. Without this, two accounts can
	-- invite each other in a loop and farm the entire ladder in a minute.
	local key = tostring(joiningPlayer.UserId)
	if questData.InvitedUserIds[key] then
		return
	end

	questData.InvitedUserIds[key] = true
	questData.InvitesAccepted += 1
	Network.Track.ShowNotification:FireClient(inviter, `{joiningPlayer.DisplayName} JOINED ON YOUR INVITE!`, "Pop")
	pushState(inviter)
end

local function onPlayerAdded(player: Player)
	local waitedSeconds = 0
	while ProfileManager.GetProfile(player) == nil and waitedSeconds < PROFILE_WAIT_TIMEOUT_SECONDS do
		task.wait(0.5)
		waitedSeconds += 0.5
		if player.Parent ~= Players then
			return
		end
	end
	if ProfileManager.GetProfile(player) == nil then
		return
	end

	applyDailyResetIfNeeded(player)
	applyLoginStreak(player)
	creditInviter(player)
	pushState(player)
end

function QuestService.Init()
	Network.Quests.RequestQuestState.OnServerEvent:Connect(function(player: Player)
		pushState(player)
	end)

	Network.Quests.ClaimQuestTier.OnServerEvent:Connect(function(player: Player, categoryId: unknown)
		if typeof(categoryId) ~= "string" then
			return
		end
		tryClaim(player, categoryId)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerAdded, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- Playtime accrual.
	task.spawn(function()
		while true do
			task.wait(PLAYTIME_TICK_SECONDS)
			for _, player in Players:GetPlayers() do
				local questData = getQuestData(player)
				if questData ~= nil then
					questData.PlaytimeSecondsToday += PLAYTIME_TICK_SECONDS
					-- Push only when a whole minute has just ticked over —
					-- the UI is denominated in minutes, so the other three
					-- ticks in each minute would be identical payloads.
					if questData.PlaytimeSecondsToday % 60 == 0 then
						pushState(player)
					end
				end
			end
		end
	end)

	-- Day boundary, for sessions that outlive it.
	task.spawn(function()
		while true do
			task.wait(DAY_ROLLOVER_CHECK_SECONDS)
			for _, player in Players:GetPlayers() do
				if applyDailyResetIfNeeded(player) then
					pushState(player)
				end
			end
		end
	end)
end

return QuestService

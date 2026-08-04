--!strict
--[[
	DailyPassRewardService
	Pays MonetizationConfigs.GamePasses.DailyBonus (id 1932605475) its daily
	Gold and Fans: EconomyRates.DailyPassGoldReward / DailyPassFanReward, once
	per calendar day, to anyone who owns the pass.

	The pass previously did nothing at all — it was not in MonetizationConfigs
	and its id appeared nowhere in the codebase, so owning it had no effect.

	## "Actual time", the same way every other daily reward here does it

	Eligibility is a DAY NUMBER comparison — os.time() // 86400, the same basis
	as Quests.LastResetDay/LastLoginDay and GoldRevivesLastResetDay — not
	"24 hours since you last collected". Those differ: an elapsed-time rule
	drifts later every day (collect at 09:00, then 09:40, then 10:15 ...) and
	eventually rations a "daily" reward to roughly six a week. A day-number rule
	is fixed to the wall clock, so it is collectable once per real day, whenever
	the player logs in.

	The last-paid day lives on the PROFILE, not in memory. That is what makes it
	once per day rather than once per rejoin.

	## Why there is a rollover tick as well as a join check

	Checking only on join pays nothing to a player who is already online when
	midnight passes; they would have to disconnect and come back. The tick is
	cheap because it is an integer comparison against a cached ownership answer
	(see MonetizationService's cache) — it does not issue a web request per
	player per tick, and it does not touch the DataStore. Granting mutates the
	in-memory profile only; ProfileStore's own autosave is what eventually
	writes it, exactly like every other reward in this game.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local MonetizationService = require(script.Parent:WaitForChild("MonetizationService"))

local SECONDS_PER_DAY = 86400
-- How long to wait for a joining player's profile before giving up. Matches
-- QuestService's own join hook, which has the same dependency.
local PROFILE_WAIT_TIMEOUT_SECONDS = 30
-- Midnight rollover check. A minute of latency on a once-a-day reward is
-- imperceptible, and at this rate the loop costs one integer comparison per
-- player per minute.
local ROLLOVER_CHECK_SECONDS = 60

local DailyPassRewardService = {}

local function currentDayNumber() : number
	return math.floor(os.time() / SECONDS_PER_DAY)
end

-- Grants the day's reward if this player owns the pass and has not been paid
-- today. Returns true only when it actually paid, so callers can avoid
-- notifying about a no-op.
local function tryGrant(player: Player) : boolean
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return false
	end

	local today = currentDayNumber()
	-- Day check BEFORE the ownership check, deliberately: the day comparison is
	-- free and rejects the overwhelmingly common case (already paid today), so
	-- the rollover tick never reaches the ownership call for a player who has
	-- already collected.
	if profile.Data.LastDailyPassRewardDay == today then
		return false
	end

	if not MonetizationService.PlayerOwnsGamePass(player, "DailyBonus") then
		return false
	end

	-- Stamped BEFORE the notification, so nothing between here and the client
	-- message can produce a second payment for the same day.
	profile.Data.LastDailyPassRewardDay = today
	profile.Data.Gold += EconomyRates.DailyPassGoldReward
	profile.Data.TotalFans += EconomyRates.DailyPassFanReward
	ProfileManager.SyncAttributes(player)

	Network.Track.ShowNotification:FireClient(
		player,
		`DAILY BONUS! +{Utils.FormatNumber(EconomyRates.DailyPassGoldReward)} 💰 +{Utils.FormatNumber(EconomyRates.DailyPassFanReward)} 🌟`,
		"Pop"
	)
	return true
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
	tryGrant(player)
end

function DailyPassRewardService.Init()
	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(onPlayerAdded, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- One loop for the whole server, not one per player.
	task.spawn(function()
		while true do
			task.wait(ROLLOVER_CHECK_SECONDS)
			for _, player in Players:GetPlayers() do
				tryGrant(player)
			end
		end
	end)
end

-- Exposed for testing: reports what the service would decide for a player
-- without paying anything.
function DailyPassRewardService.GetStatus(player: Player) : { [string]: any }
	local profile = ProfileManager.GetProfile(player)
	return {
		HasProfile = profile ~= nil,
		Today = currentDayNumber(),
		LastPaidDay = if profile ~= nil then profile.Data.LastDailyPassRewardDay else -1,
		OwnsPass = MonetizationService.PlayerOwnsGamePass(player, "DailyBonus"),
		DueToday = profile ~= nil and profile.Data.LastDailyPassRewardDay ~= currentDayNumber(),
	}
end

return DailyPassRewardService

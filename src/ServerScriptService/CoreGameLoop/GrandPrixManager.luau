--!strict
--[[
	GrandPrixManager
	State machine for the scheduled Grand Prix event:
	Waiting -> Countdown -> Racing -> Ended -> (loop).

	This used to be scaffolding that could never actually run: enterEnded()
	was defined but called from nowhere, so there was no Racing -> Ended
	transition at all. The race started (on an hourly timer) and then simply
	stayed in Racing forever — which also meant the
	TrackGenerator.Regenerate() call inside enterEnded, and the whole
	"every race is a fresh track" design, were unreachable in real play.
	The loop below now has real end conditions.

	A race ends the moment ANY of these is true:
	  - every remaining racer has completed GRAND_PRIX_LAPS laps,
	  - only one racer is still standing and there was more than one to
	    begin with (last man standing — the race is decided, no point
	    running out the clock),
	  - nobody is left standing at all,
	  - RACE_TIME_LIMIT_SECONDS have elapsed.

	Scheduling is anchored to REAL-WORLD wall-clock time rather than to an
	interval counted from whenever this particular server booted or finished
	its last race: Grand Prix run at :00, :12, :24, :36 and :48 of every hour
	— 8:00, 8:12, 8:24 — and every server in the game agrees on that without
	any of them having to talk to each other. See nextScheduledStart().

	Who is "standing" is deliberately NOT tracked with its own bookkeeping.
	ArcadeManager already owns lives, the revive-purchase window, and the
	return-to-Hub that ends a racer's run; the single observable outcome of
	all of that is the player's PlayerState leaving InRace. This module just
	polls for that, so a racer eliminated by hazards, by falling out, or by
	letting the revive timer expire is picked up identically, with no new
	plumbing and no chance of the two views disagreeing.

	Lap counting comes from CheckpointValidator via
	SetLapCompletedHandler — that module is already the authority on lap
	completion (checkpoint 8 IS the finish line) and this avoids a require
	cycle, since this module requires it for RefreshCheckpoints.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local TrackGenerator = require(script.Parent:WaitForChild("TrackGenerator"))
local ArcadeManager = require(script.Parent:WaitForChild("ArcadeManager"))
local SoundDirector = require(script.Parent:WaitForChild("SoundDirector"))
local LeaderboardBuilder = require(script.Parent:WaitForChild("LeaderboardBuilder"))
local HubGenerator = require(script.Parent:WaitForChild("HubGenerator"))
local VisualEffectsService = require(script.Parent:WaitForChild("VisualEffectsService"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))
local CheckpointValidator = require(script.Parent.Parent:WaitForChild("Security"):WaitForChild("CheckpointValidator"))
local TrackBoundaryMonitor = require(script.Parent.Parent:WaitForChild("Security"):WaitForChild("TrackBoundaryMonitor"))

export type RaceState = "Waiting" | "Countdown" | "Racing" | "Ended"

export type RacerStatus = {
	Player: Player,
	LivesRemaining: number,
	LastCheckpointOrdinal: number,
	LapsCompleted: number,
	FinishPlace: number?, -- set once they complete GRAND_PRIX_LAPS; 1 = won
	IsEliminated: boolean, -- ran out of lives / left the track before finishing
	EliminationOrder: number?, -- 1 = first knocked out, so a HIGHER number lasted longer
}

local COUNTDOWN_SECONDS = 15
-- Only the last few seconds get a beep. Beeping for all 15 would be noise
-- rather than a cue, and the on-screen timer already covers the long wait.
local COUNTDOWN_BEEP_SECONDS = 3
-- The wall-clock slot size: one Grand Prix every 12 minutes, at :00, :12, :24,
-- :36 and :48. Changing this changes the marks themselves (30 * 60 would give
-- :00/:30), so it wants to stay a whole divisor of an hour.
local RACE_INTERVAL_SECONDS = 12 * 60
local RACE_TIME_LIMIT_SECONDS = 4 * 60
local GRAND_PRIX_LAPS = 2
local MAX_LIVES = 3
local TICK_SECONDS = 1
-- Slow on purpose: the client ticks its own display down between these, so
-- this only has to correct drift, not drive the clock. At 40 players a
-- once-per-second broadcast would be 40 remote fires a second for a label.
local TIMER_BROADCAST_SECONDS = 5
-- How often, while Racing, everyone in the server is told who is winning.
-- The four stadium boards already carry live standings, but they are a thing
-- you have to be looking AT — a racer is looking at the track and a spectator
-- may be anywhere in the Hub. This is the same information pushed instead of
-- pulled. Deliberately a slow cadence: the toast holds for ~1.2s, so 15s is
-- frequent enough to follow the race and far enough apart that it never
-- competes with the checkpoint/reward notices that are about YOUR run.
local LEADER_BROADCAST_SECONDS = 15
-- Checkpoints in a lap, read from the blueprint rather than hardcoded — this
-- is the same source CheckpointValidator's own count comes from.
local CHECKPOINT_COUNT = #TrackBlueprints.OvalSegments

local GrandPrixManager = {}

-- The next real-world :00/:12/:24/:36/:48 mark strictly after `after`.
--
-- os.time() is UTC epoch seconds and the epoch itself falls on a :00, so whole
-- multiples of a 12-minute interval ARE those marks — no calendar
-- arithmetic is needed, and there is no daylight-saving edge case to get wrong
-- because UTC has no DST. (Roblox servers run UTC regardless of where the
-- machine or the player is; the client turns the timestamp into the player's
-- own local time for display, so a player in UTC+1 correctly reads 9:24.)
--
-- STRICTLY after, not "at or after": this is called with the current time, and
-- landing exactly on a mark would otherwise schedule a race for the instant
-- that has just passed and fire it immediately.
--
-- What this replaces: `os.time() + RACE_INTERVAL_SECONDS`, i.e. one interval
-- counted from whenever this server last finished a race. That made the
-- schedule per-server and arbitrary — a server booted at 8:07 ran at 8:19,
-- 8:31, ... while the one next door ran 8:22, 8:34 — so "when is the next
-- Grand Prix" had no answer that held anywhere except the server you happened
-- to be standing in, and none that could be advertised anywhere outside the
-- game.
local function nextScheduledStart(after: number) : number
	return math.floor(after / RACE_INTERVAL_SECONDS) * RACE_INTERVAL_SECONDS + RACE_INTERVAL_SECONDS
end

local currentState: RaceState = "Waiting"
local nextRaceStartTime: number = nextScheduledStart(os.time())
local racerStatuses: { [Player]: RacerStatus } = {}
local raceEndTime: number = 0
local countdownEndTime: number = 0
local finishedCount = 0
local eliminatedCount = 0
-- Leader announcements. The deadline is re-armed from enterRacing rather than
-- run off a free-standing timer loop, so the first announcement lands exactly
-- LEADER_BROADCAST_SECONDS into the race instead of at whatever phase a
-- server-lifetime timer happened to be at.
local nextLeaderBroadcastTime: number = 0
-- Who the last announcement named. A CHANGE of leader is the most exciting
-- thing that can happen mid-race, so it gets different wording and the bouncy
-- "Pop" style; an unchanged leader gets a quieter progress line. nil at the
-- start of a race, which is why the first announcement always reads as a
-- takeover — correct, since it is the first time anyone is told who is ahead.
local lastAnnouncedLeader: Player? = nil

-- ===== Roster helpers =====

local function newStatus(player: Player) : RacerStatus
	return {
		Player = player,
		LivesRemaining = MAX_LIVES,
		LastCheckpointOrdinal = 0,
		LapsCompleted = 0,
		FinishPlace = nil,
		IsEliminated = false,
		EliminationOrder = nil,
	}
end

-- Still out there racing: not finished, not knocked out. This is what the
-- last-man-standing and all-done end conditions are counted from.
local function isActive(status: RacerStatus) : boolean
	return status.FinishPlace == nil and not status.IsEliminated
end

local function rosterCount() : number
	local count = 0
	for _ in racerStatuses do
		count += 1
	end
	return count
end

local function activeCount() : number
	local count = 0
	for _, status in racerStatuses do
		if isActive(status) then
			count += 1
		end
	end
	return count
end

-- Sorted worst-to-best is never what anyone wants here, so this returns
-- best-first: finishers by finishing order, then everyone still running
-- (deeper into the race ranks higher), then the eliminated with the most
-- recent knockout first — i.e. exactly the "who lasted longest" order the
-- survivor payouts are drawn from, and a sensible live standings order too.
local function rankedStatuses() : { RacerStatus }
	local ranked: { RacerStatus } = {}
	for _, status in racerStatuses do
		table.insert(ranked, status)
	end

	table.sort(ranked, function(a: RacerStatus, b: RacerStatus)
		local aFinished = a.FinishPlace ~= nil
		local bFinished = b.FinishPlace ~= nil
		if aFinished ~= bFinished then
			return aFinished
		end
		if aFinished and bFinished then
			return (a.FinishPlace :: number) < (b.FinishPlace :: number)
		end

		if a.IsEliminated ~= b.IsEliminated then
			return not a.IsEliminated -- anyone still standing outranks anyone out
		end
		if a.IsEliminated and b.IsEliminated then
			return (a.EliminationOrder or 0) > (b.EliminationOrder or 0) -- knocked out later = ranked higher
		end

		if a.LapsCompleted ~= b.LapsCompleted then
			return a.LapsCompleted > b.LapsCompleted
		end
		return a.LastCheckpointOrdinal > b.LastCheckpointOrdinal
	end)

	return ranked
end

-- How long the CURRENT state has left to run: the wait for the next race
-- while Waiting, the start countdown during Countdown, the remaining race
-- time while Racing. Ended is transient (one tick) so it reports 0.
local function secondsRemainingInState() : number
	if currentState == "Waiting" then
		return math.max(0, nextRaceStartTime - os.time())
	elseif currentState == "Countdown" then
		-- Real remaining, NOT the COUNTDOWN_SECONDS constant. Returning the
		-- constant made every periodic broadcast reset the client's deadline
		-- to "15 seconds from now", so the displayed countdown jittered
		-- upward instead of counting down (measured live: 0:12, 0:13, 0:10,
		-- 0:12, 0:14). Only visible because the timer is re-broadcast on a
		-- cycle — the one-shot state change alone would have looked fine.
		return math.max(0, countdownEndTime - os.time())
	elseif currentState == "Racing" then
		return math.max(0, raceEndTime - os.time())
	end
	return 0
end

-- Sent on every state change and on a slow cycle in between (see
-- TIMER_BROADCAST_SECONDS). The client counts down locally between updates
-- rather than the server pushing once a second to every player.
--
-- Declared above broadcastState because broadcastState calls it: a `local
-- function` referenced before its declaration resolves to nil, and Luau
-- won't complain at build time.
-- nextRaceStartTime rides along as an absolute UTC timestamp so the client can
-- show the mark itself ("NEXT GP 20:30") next to the countdown — the whole
-- point of a wall-clock schedule is that players can plan around it, which
-- they cannot do from a duration alone. It is the client that turns it into a
-- clock reading, in the PLAYER's own time zone; the server never assumes one.
local function broadcastTimer()
	local remaining = secondsRemainingInState()
	for _, player in Players:GetPlayers() do
		Network.Track.GrandPrixTimer:FireClient(player, currentState, remaining, nextRaceStartTime)
	end
end

-- Ships COUNTDOWN_SECONDS alongside the state so the client can run its own
-- countdown off a monotonic local clock instead of polling the server or
-- trying to reconcile os.time() skew across machines.
local function broadcastState()
	for _, player in Players:GetPlayers() do
		Network.Track.GrandPrixStateChanged:FireClient(player, currentState, COUNTDOWN_SECONDS)
	end
	broadcastTimer()
end

-- What the four stadium boards say across a race. Countdown is the grid (no
-- lap progress exists yet), Ended is the result the payout was calculated
-- from — see RESULT_HOLD_SECONDS for why the boards outlive the state.
local BOARD_SUBTITLE_BY_STATE: { [string]: string } = {
	Countdown = "STARTING GRID",
	Racing = "LIVE STANDINGS",
	Ended = "FINAL RESULT",
}

-- The boards keep showing the final result for this long after the race is
-- over. Without it the result would be on screen for one TICK_SECONDS: the
-- loop calls enterWaiting() on the very next tick after enterEnded(), so
-- "until the winner and rewards are announced" cannot be expressed as a
-- state, only as a hold.
local RESULT_HOLD_SECONDS = 20
-- Incremented whenever board ownership changes hands. A pending revert only
-- fires if it still holds the current token, so a Grand Prix that starts
-- during the hold (or a second race entirely) can't have its boards wiped by
-- the previous race's timer.
local boardHandoffToken = 0

local function pushStandingsToBoards(ranked: { RacerStatus })
	local rows: { LeaderboardBuilder.GrandPrixRow } = {}
	for _, status in ranked do
		table.insert(rows, {
			UserId = status.Player.UserId,
			DisplayName = status.Player.DisplayName,
			LapsCompleted = status.LapsCompleted,
			CheckpointOrdinal = status.LastCheckpointOrdinal,
			LivesRemaining = status.LivesRemaining,
			IsEliminated = status.IsEliminated,
			FinishPlace = status.FinishPlace,
		})
	end
	LeaderboardBuilder.SetGrandPrixMode(rows, BOARD_SUBTITLE_BY_STATE[currentState] or "")
end

local function broadcastStandings()
	local ranked = rankedStatuses()

	local standings = {}
	for _, status in ranked do
		table.insert(standings, {
			PlayerName = status.Player.Name,
			LivesRemaining = status.LivesRemaining,
			CheckpointOrdinal = status.LastCheckpointOrdinal,
			LapsCompleted = status.LapsCompleted,
			IsEliminated = status.IsEliminated,
			FinishPlace = status.FinishPlace,
		})
	end

	for _, player in Players:GetPlayers() do
		Network.Track.UpdateRaceStandings:FireClient(player, standings)
	end

	-- Same data, same moment, to the stadium boards. Driving both from this
	-- one function is what stops the boards and the (now hidden) on-screen
	-- list ever showing different standings for the same race.
	if currentState ~= "Waiting" then
		boardHandoffToken += 1
		pushStandingsToBoards(ranked)
	end
end

-- Tells the WHOLE SERVER who is winning, every LEADER_BROADCAST_SECONDS of a
-- live race — spectators in the Hub included, since a Grand Prix is meant to
-- be the thing everyone is watching and not knowing who is ahead is what makes
-- it ignorable.
--
-- Reuses Network.Track.ShowNotification, i.e. the same pooled/stacking toast
-- every other notice already goes through, so these queue and reflow with
-- everything else instead of needing a second on-screen surface that could
-- overlap it.
local function broadcastLeader()
	local ranked = rankedStatuses()

	-- The leader is the best racer STILL RUNNING, not simply ranked[1].
	-- rankedStatuses() puts finishers first, and once someone has completed the
	-- full distance their win is already settled and already announced by their
	-- own FINISHED toast — repeating their name every 15 seconds would be stale
	-- news, while the live contest for the next place went unmentioned.
	local leader: RacerStatus? = nil
	for _, status in ranked do
		if isActive(status) then
			leader = status
			break
		end
	end
	-- Unreachable in the loop below (activeCount() == 0 makes raceEndReason()
	-- return "ALL RACERS DONE" and the race ends before this is called), but
	-- this must not be the thing that errors if that ever stops being true.
	if leader == nil then
		return
	end

	local leaderPlayer = leader.Player
	local isNewLeader = lastAnnouncedLeader ~= leaderPlayer
	lastAnnouncedLeader = leaderPlayer

	-- LapsCompleted is laps FINISHED, so the lap they are on is one more. It
	-- can never exceed GRAND_PRIX_LAPS here: completing the last one sets
	-- FinishPlace, which makes them inactive and disqualifies them above.
	local progress = `LAP {leader.LapsCompleted + 1}/{GRAND_PRIX_LAPS} · CP {leader.LastCheckpointOrdinal}/{CHECKPOINT_COUNT}`

	for _, player in Players:GetPlayers() do
		local text: string
		if player == leaderPlayer then
			text = if isNewLeader then `👑 YOU TOOK THE LEAD! {progress}` else `👑 STILL LEADING — {progress}`
		else
			text = if isNewLeader
				then `🔥 {leaderPlayer.DisplayName} TAKES THE LEAD!`
				else `🏁 LEADER: {leaderPlayer.DisplayName} · {progress}`
		end
		Network.Track.ShowNotification:FireClient(player, text, if isNewLeader then "Pop" else nil)
	end
end

-- ===== Rewards =====

local function grantReward(player: Player, reward: EconomyRates.PlacementReward, reasonText: string)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	-- Same treatment the other two Gold/Fan reward sites already give the
	-- "Double Gain Fans and Gold" pass (CarryItemService.TryDeposit and
	-- CheckpointValidator.grantLapReward) — a pass that doubles gains would
	-- be conspicuous for skipping the single biggest payout in the game.
	local goldReward = reward.Gold
	local fanReward = reward.Fans
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		goldReward *= EconomyRates.DoubleGainMultiplier
		fanReward *= EconomyRates.DoubleGainMultiplier
	end

	profile.Data.Gold += goldReward
	profile.Data.TotalFans += fanReward
	ProfileManager.SyncAttributes(player)
	SoundDirector.PlayForPlayer(player, "GoldGain")
	SoundDirector.PlayForPlayer(player, "FanGain")
	Network.Track.ShowNotification:FireClient(
		player,
		`{reasonText} +{Utils.FormatNumber(goldReward)} 💰 +{Utils.FormatNumber(fanReward)} 🌟`,
		"Pop"
	)
end

-- Two independent ladders, paid from the same final ranking. A racer who won
-- AND outlasted everyone draws from both on purpose — see EconomyRates.
local function payOutRewards()
	local ranked = rankedStatuses()

	local finishers: { RacerStatus } = {}
	for _, status in ranked do
		if status.FinishPlace ~= nil then
			table.insert(finishers, status)
		end
	end
	table.sort(finishers, function(a, b)
		return (a.FinishPlace :: number) < (b.FinishPlace :: number)
	end)

	for place, status in finishers do
		local reward = EconomyRates.GrandPrixFinisherRewards[place]
		if reward == nil then
			break -- past the paying places
		end
		grantReward(status.Player, reward, `GRAND PRIX #{place} FINISH!`)
	end

	-- rankedStatuses() is already "who lasted longest," best first.
	local survivorPlaces = #EconomyRates.GrandPrixSurvivorRewards
	for place, status in ranked do
		local reward = EconomyRates.GrandPrixSurvivorRewards[place]
		if reward == nil then
			break
		end
		grantReward(status.Player, reward, `LAST {survivorPlaces} STANDING — #{place}!`)
	end

	-- Unclaimed finisher prize money is shared out, not deleted.
	--
	-- The finisher ladder is 5 places deep, but the race can (and usually
	-- does) end on the 5-minute time limit with nobody having driven the full
	-- 2 laps — or with only one or two finishers. Those unearned places used
	-- to simply evaporate, which meant the most common outcome of a Grand
	-- Prix was that most of its prize pool paid nobody, and the racers who
	-- survived to the flag got nothing for it beyond the survivor ladder.
	--
	-- Everyone still on the field at the end splits the remainder evenly.
	-- Deliberately EVEN rather than ranked: this pool exists precisely
	-- because the race produced no finishing order to rank by, so inventing
	-- one from checkpoint progress would be dressing up a tie as a result.
	local unclaimedGold, unclaimedFans = 0, 0
	for place = #finishers + 1, #EconomyRates.GrandPrixFinisherRewards do
		unclaimedGold += EconomyRates.GrandPrixFinisherRewards[place].Gold
		unclaimedFans += EconomyRates.GrandPrixFinisherRewards[place].Fans
	end

	if unclaimedGold <= 0 and unclaimedFans <= 0 then
		return
	end

	-- "Still on the field" = never eliminated and never finished. A finisher
	-- has already been paid from the ladder above, and an eliminated racer is
	-- exactly who this is not for.
	local stillStanding: { RacerStatus } = {}
	for _, status in ranked do
		if not status.IsEliminated and status.FinishPlace == nil then
			table.insert(stillStanding, status)
		end
	end

	if #stillStanding == 0 then
		-- Everyone was knocked out, so there is nobody the pool belongs to.
		return
	end

	local share: EconomyRates.PlacementReward = {
		Gold = math.floor(unclaimedGold / #stillStanding),
		Fans = math.floor(unclaimedFans / #stillStanding),
	}
	for _, status in stillStanding do
		grantReward(status.Player, share, `STILL STANDING — SHARED {#stillStanding} WAYS!`)
	end
end

-- ===== State transition handlers =====

local function enterWaiting()
	-- Init() also calls this, on a server that has never run a race — there is
	-- no result to hold in that case, and holding one would leave the boards
	-- captioned FINAL RESULT with nothing on them.
	local cameFromRace = currentState == "Ended"

	currentState = "Waiting"
	racerStatuses = {}
	finishedCount = 0
	eliminatedCount = 0
	-- Re-derived from the wall clock rather than added to the old value, so a
	-- race that ran late (or early, via StartRaceNow) doesn't push the whole
	-- rest of the day off the marks — the schedule is absolute, and every
	-- Waiting period simply runs until the next one.
	nextRaceStartTime = nextScheduledStart(os.time())
	broadcastState()
	broadcastStandings()

	-- Hand the boards back to the all-time categories, after letting the final
	-- result stand (see RESULT_HOLD_SECONDS). The rows the boards are holding
	-- are a copied snapshot, so clearing racerStatuses above does not blank
	-- them mid-hold.
	boardHandoffToken += 1
	local token = boardHandoffToken
	if cameFromRace then
		task.delay(RESULT_HOLD_SECONDS, function()
			if boardHandoffToken == token then
				LeaderboardBuilder.SetGrandPrixMode(nil)
			end
		end)
	else
		LeaderboardBuilder.SetGrandPrixMode(nil)
	end

	-- The roster was just emptied, so every JOIN GRAND PRIX toggle in the
	-- server is now stale-on. Enrolment is deliberately per-race rather than
	-- sticky: a player who wandered off after one race shouldn't be silently
	-- teleported into the next one 12 minutes later.
	for _, player in Players:GetPlayers() do
		Network.Hub.ToggleGrandPrixEntry:FireClient(player, false)
	end
end

-- Free-run arcade racing and a live Grand Prix can't share the track: a
-- non-participant lapping the circuit would be indistinguishable from a
-- racer, would trip the same hazards, and would be competing for the same
-- pickups without ever appearing in the standings. So at Countdown, anyone
-- InRace who did NOT sign up is sent back to the Hub.
--
-- Scoped deliberately narrowly: players sitting in the Hub, at a Fan Box, or
-- anywhere else are not touched at all — the only thing being reclaimed is
-- the track itself.
local function clearNonParticipantsFromTrack()
	for _, player in Players:GetPlayers() do
		if racerStatuses[player] ~= nil then
			continue
		end
		if PlayerStateService.GetState(player) ~= PlayerState.InRace then
			continue
		end

		ArcadeManager.LeaveTrack(player)
		Network.Track.ShowNotification:FireClient(player, "GRAND PRIX STARTING — TRACK CLOSED", "Pop")
	end
end

-- Start-line slots. Everyone previously spawned on the exact same CFrame,
-- which in Roblox means N characters resolving overlapping collisions at
-- once — they shove each other off the line before the race even starts.
-- Slots are laid out across the track's own width first, then backwards in
-- rows, so a full grid still sits on real road behind the start line.
local START_GRID_COLUMNS = 5
local START_GRID_LATERAL_SPACING = 12
local START_GRID_ROW_SPACING = 10

local function startGridOffset(slotIndex: number) : CFrame
	local zeroBased = slotIndex - 1
	local column = zeroBased % START_GRID_COLUMNS
	local row = math.floor(zeroBased / START_GRID_COLUMNS)
	local lateral = (column - (START_GRID_COLUMNS - 1) / 2) * START_GRID_LATERAL_SPACING
	-- +Z is BEHIND the start line: segment 1 runs along -Z from the origin
	-- (see ArcadeManager.TRACK_START_CFRAME), so later rows start further back.
	return CFrame.new(lateral, 0, row * START_GRID_ROW_SPACING)
end

local function enterCountdown()
	currentState = "Countdown"
	-- Set BEFORE broadcastState, which broadcasts the timer.
	countdownEndTime = os.time() + COUNTDOWN_SECONDS
	broadcastState()
	clearNonParticipantsFromTrack()

	-- Anyone who pressed JOIN GRAND PRIX during the Waiting window is on the
	-- roster; put them all back on the start line together with a clean slate
	-- (EnterTrack teleports, sets InRace, and resets checkpoint progress) so
	-- warming up on the track beforehand confers nothing.
	local slotIndex = 0
	for player, status in racerStatuses do
		if player.Parent == nil then
			continue
		end

		status.LapsCompleted = 0
		status.LastCheckpointOrdinal = 0
		status.FinishPlace = nil
		status.IsEliminated = false
		status.EliminationOrder = nil
		status.LivesRemaining = MAX_LIVES

		local profile = ProfileManager.GetProfile(player)
		if profile ~= nil then
			profile.Data.Lives = MAX_LIVES
			ProfileManager.SyncAttributes(player)
		end

		ArcadeManager.EnterTrack(player)

		slotIndex += 1
		local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart ~= nil then
			rootPart.CFrame = rootPart.CFrame * startGridOffset(slotIndex)
		end
	end

	broadcastStandings()

	-- Audible countdown for the last COUNTDOWN_BEEP_SECONDS. Self-terminating
	-- on a state change rather than running to completion blind: the race can
	-- leave Countdown early (an admin StartRaceNow, or the roster emptying),
	-- and beeps arriving after the lights have gone green would be worse than
	-- no beeps at all.
	task.spawn(function()
		for remaining = COUNTDOWN_BEEP_SECONDS, 1, -1 do
			while currentState == "Countdown" and secondsRemainingInState() > remaining do
				task.wait(0.1)
			end
			if currentState ~= "Countdown" then
				return
			end
			for player in racerStatuses do
				SoundDirector.PlayForPlayer(player, "CountdownTick")
			end
		end
	end)
end

local function enterRacing()
	currentState = "Racing"
	raceEndTime = os.time() + RACE_TIME_LIMIT_SECONDS
	-- Armed here, not at server start, so the first leader call lands exactly
	-- 15s after the flag drops. Cleared rather than carried over, so the
	-- opening announcement of every race reads as a takeover.
	nextLeaderBroadcastTime = os.time() + LEADER_BROADCAST_SECONDS
	lastAnnouncedLeader = nil
	broadcastState()
	broadcastStandings()

	-- The GO. Fired here rather than as the last countdown beep so it lands
	-- on the actual state transition and can't be left playing over a race
	-- that never started.
	for player in racerStatuses do
		SoundDirector.PlayForPlayer(player, "CountdownGo")
	end
end

local function enterEnded(reason: string)
	currentState = "Ended"
	broadcastState()
	broadcastStandings()
	payOutRewards()

	for player in racerStatuses do
		if PlayerStateService.GetState(player) == PlayerState.InRace then
			ArcadeManager.LeaveTrack(player)
		end
		PlayerStateService.SetState(player, PlayerState.InLobby)
	end

	-- Regenerate here (not in enterWaiting, which also runs on server
	-- startup right after TrackGenerator.Init() already built it once) so
	-- every race after the first is a "new experience" per spec.
	TrackGenerator.Regenerate(workspace)

	-- Regenerate destroys the old Track folder (including every checkpoint
	-- trigger Part) and builds a new one — CheckpointValidator/
	-- TrackBoundaryMonitor each cache their own references to that geometry
	-- once at server-start Init() and never on their own notice a
	-- replacement, so without this refresh they'd keep validating against
	-- destroyed instances after every Grand Prix (real bug: Destroy() only
	-- sets Parent = nil, it doesn't stop property reads on the stale
	-- reference, so this was silently "working" only because the oval's
	-- geometry happens to be identical every regeneration — not something
	-- to keep relying on).
	CheckpointValidator.RefreshCheckpoints()
	TrackBoundaryMonitor.RefreshTrackGeometry()

	for _, player in Players:GetPlayers() do
		Network.Track.ShowNotification:FireClient(player, `GRAND PRIX OVER — {reason}`, "Pop")
	end

	-- Fireworks over the infield, for the whole server. Fired here rather than
	-- per-winner because a Grand Prix normally times out with nobody
	-- finishing (see payOutRewards' shared remainder) — tying the celebration
	-- to a winner would mean most races end in silence. This is the event
	-- ending, and everyone watching from the Hub should see it.
	--
	-- Lands during the RESULT_HOLD_SECONDS window while the four stadium
	-- boards are still showing the final standings, so the fireworks and the
	-- result are on screen together.
	local hubCFrame = HubGenerator.GetHubCFrame()
	if hubCFrame ~= nil then
		VisualEffectsService.ShowFireworks(hubCFrame)
	end
end

-- ===== Live race bookkeeping =====

-- Registered on CheckpointValidator; fires once per completed lap.
local function onLapCompleted(player: Player)
	if currentState ~= "Racing" then
		return
	end

	local status = racerStatuses[player]
	if status == nil or not isActive(status) then
		return
	end

	status.LapsCompleted += 1

	if status.LapsCompleted >= GRAND_PRIX_LAPS then
		finishedCount += 1
		status.FinishPlace = finishedCount
		-- Their race is done; send them home so they aren't left running
		-- laps that no longer count (and so the last-man-standing check
		-- isn't held open by someone who already won).
		ArcadeManager.LeaveTrack(player)
		Network.Track.ShowNotification:FireClient(player, `FINISHED — P{finishedCount}!`, "Pop")

		-- Crossing the line for the last time is the single most celebratory
		-- moment in the mode and had no effect of its own — it reused the
		-- ordinary lap burst and then teleported the player away. Confetti and
		-- a crowd cheer land at the Hub, which is where LeaveTrack has just
		-- put them, so the celebration is somewhere they can actually see it
		-- rather than back on a track they are no longer standing on.
		local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart ~= nil then
			VisualEffectsService.ShowConfettiBurst(rootPart.Position, 1.6)
			SoundDirector.PlayAtPart(rootPart, "CrowdCheer")
		end
	end

	broadcastStandings()
end

-- Anyone on the roster who is no longer InRace, and didn't get there by
-- finishing, is out — see the module docstring on why this is a poll of
-- ArcadeManager's outcome rather than its own parallel bookkeeping.
local function reapEliminatedRacers()
	local changed = false

	for player, status in racerStatuses do
		if not isActive(status) then
			continue
		end

		local goneFromServer = player.Parent == nil
		if goneFromServer or PlayerStateService.GetState(player) ~= PlayerState.InRace then
			eliminatedCount += 1
			status.IsEliminated = true
			status.EliminationOrder = eliminatedCount
			changed = true
		else
			status.LivesRemaining = (player:GetAttribute("Lives") :: number?) or status.LivesRemaining
			status.LastCheckpointOrdinal = CheckpointValidator.GetLastOrdinal(player)
		end
	end

	if changed then
		broadcastStandings()
	end
end

-- Returns a human-readable reason if the race is over, nil if it should
-- keep running.
local function raceEndReason() : string?
	if os.time() >= raceEndTime then
		return "TIME UP"
	end

	local active = activeCount()
	if active == 0 then
		return "ALL RACERS DONE"
	end

	local standing = 0
	for _, status in racerStatuses do
		if not status.IsEliminated then
			standing += 1
		end
	end
	if rosterCount() > 1 and standing <= 1 then
		return "LAST ONE STANDING"
	end

	return nil
end

-- ===== Public surface =====

-- Enrolment is its own explicit, reversible opt-in (LeftMenuBar's
-- JOIN GRAND PRIX toggle, via Network.Hub.ToggleGrandPrixEntry) and is
-- deliberately separate from actually being on the track — a player can sign
-- up from the Hub 20 minutes early and carry on doing whatever they like
-- until Countdown teleports them to the start line.
--
-- Joining mid-Racing is allowed on purpose: a late joiner just has less time
-- and fewer laps banked, which is fairer than locking someone out of a
-- 12-minute cycle.
function GrandPrixManager.JoinGrandPrix(player: Player)
	if racerStatuses[player] ~= nil then
		return
	end
	racerStatuses[player] = newStatus(player)
	-- Echoed here rather than only in the remote handler, so the button
	-- stays truthful no matter what enrolled the player. (Caught live: a
	-- server-side JoinGrandPrix left the button still reading "not joined".)
	Network.Hub.ToggleGrandPrixEntry:FireClient(player, true)
	broadcastStandings()
end

-- Opting back out. Refused once the race is actually underway — by then the
-- roster is the scoreboard, and letting someone erase themselves from it
-- mid-race would also let a losing racer dodge being counted.
function GrandPrixManager.LeaveGrandPrix(player: Player)
	if currentState == "Countdown" or currentState == "Racing" then
		return
	end
	if racerStatuses[player] == nil then
		return
	end
	racerStatuses[player] = nil
	Network.Hub.ToggleGrandPrixEntry:FireClient(player, false)
	broadcastStandings()
end

function GrandPrixManager.IsJoined(player: Player) : boolean
	return racerStatuses[player] ~= nil
end

-- Brings the next Grand Prix forward to right now (it still runs the full
-- Countdown). Server-side only, deliberately not exposed on any remote — a
-- 12-minute cadence is untestable and unadministrable otherwise, and every
-- alternative meant either shipping a shortened interval or reaching into
-- this module's locals from outside.
--
-- This is a one-off jump, not a reschedule: enterWaiting() re-derives the next
-- start from the wall clock when this race ends, so an off-schedule test race
-- puts the server back on the :00/:12/:24/:36/:48 marks by itself.
function GrandPrixManager.StartRaceNow()
	if currentState ~= "Waiting" then
		return
	end
	nextRaceStartTime = os.time()
end

function GrandPrixManager.GetState() : RaceState
	return currentState
end

function GrandPrixManager.GetNextRaceStartTime() : number
	return nextRaceStartTime
end

function GrandPrixManager.GetRaceEndTime() : number
	return raceEndTime
end

function GrandPrixManager.GetRacerStatus(player: Player) : RacerStatus?
	return racerStatuses[player]
end

-- ===== Loop =====

local function runLoop()
	while true do
		if currentState == "Waiting" and os.time() >= nextRaceStartTime then
			enterCountdown()
			task.wait(COUNTDOWN_SECONDS)
			enterRacing()
		elseif currentState == "Racing" then
			reapEliminatedRacers()
			local reason = raceEndReason()
			if reason ~= nil then
				enterEnded(reason)
			elseif os.time() >= nextLeaderBroadcastTime then
				-- Deliberately in the `else` of the end check: a race that is
				-- ending this very tick should announce its RESULT, not who was
				-- narrowly ahead a moment before the flag.
				nextLeaderBroadcastTime = os.time() + LEADER_BROADCAST_SECONDS
				broadcastLeader()
			end
		elseif currentState == "Ended" then
			enterWaiting()
		end

		task.wait(TICK_SECONDS)
	end
end

function GrandPrixManager.Init()
	enterWaiting()

	CheckpointValidator.SetLapCompletedHandler(onLapCompleted)

	-- Free-run arcade entry is refused from Countdown until the race ends.
	ArcadeManager.SetTrackClosedCheck(function()
		return currentState == "Countdown" or currentState == "Racing"
	end)

	-- The button sends "toggle", not "join" or "leave" — the server decides
	-- which it was and fires the resulting state back, so the button can
	-- never drift out of sync with the roster (e.g. after enterWaiting()
	-- clears everyone, or after a refused mid-race opt-out).
	Network.Hub.ToggleGrandPrixEntry.OnServerEvent:Connect(function(player: Player)
		if GrandPrixManager.IsJoined(player) then
			GrandPrixManager.LeaveGrandPrix(player)
			-- LeaveGrandPrix refuses mid-race, and refusing is silent, so
			-- re-assert the real answer here or the button would be left
			-- showing an opt-out that never happened.
			if GrandPrixManager.IsJoined(player) then
				Network.Hub.ToggleGrandPrixEntry:FireClient(player, true)
			end
		else
			GrandPrixManager.JoinGrandPrix(player)
		end
	end)

	-- enterWaiting()'s broadcastState() above fires before anyone has
	-- joined; catch up anyone who joins after that (which, in practice, is
	-- everyone) with the state as of the moment they load in.
	Players.PlayerAdded:Connect(function(player: Player)
		Network.Track.GrandPrixStateChanged:FireClient(player, currentState, COUNTDOWN_SECONDS)
		Network.Track.GrandPrixTimer:FireClient(player, currentState, secondsRemainingInState(), nextRaceStartTime)
		Network.Hub.ToggleGrandPrixEntry:FireClient(player, false)
	end)

	task.spawn(function()
		while true do
			task.wait(TIMER_BROADCAST_SECONDS)
			broadcastTimer()
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		racerStatuses[player] = nil
	end)

	task.spawn(runLoop)
end

return GrandPrixManager

--!strict
--[[
	GrandPrixManager
	State machine for the hourly Grand Prix event: Waiting -> Countdown ->
	Racing -> Ended -> (loop). Scaffolding only — no scoring/spawn logic yet.

	Scheduling uses os.time() so the "hourly" cadence survives server
	restarts without drifting (per project convention: no wait()/spawn(),
	task.wait()/task.spawn() only).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local TrackGenerator = require(script.Parent:WaitForChild("TrackGenerator"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))

export type RaceState = "Waiting" | "Countdown" | "Racing" | "Ended"

export type RacerStatus = {
	Player: Player,
	LivesRemaining: number,
	LastCheckpointOrdinal: number,
	IsEliminated: boolean, -- true once LivesRemaining hits 0 -> teleported back to Hub
}

local COUNTDOWN_SECONDS = 15
local RACE_INTERVAL_SECONDS = 60 * 60 -- one Grand Prix per hour
local MAX_LIVES = 3

local GrandPrixManager = {}

local currentState: RaceState = "Waiting"
local nextRaceStartTime: number = os.time() + RACE_INTERVAL_SECONDS
local racerStatuses: { [Player]: RacerStatus } = {}

-- ===== State transition handlers (scaffolding) =====

local function enterWaiting()
	currentState = "Waiting"
	racerStatuses = {}
	nextRaceStartTime = os.time() + RACE_INTERVAL_SECONDS
	-- TODO: open Hub access, disable track hazards.
end

local function enterCountdown()
	currentState = "Countdown"
	-- TODO: lock in the roster, teleport racers to Segment_01_StartLine,
	-- initialize racerStatuses for each participant with MAX_LIVES. Once
	-- that exists, this loop will actually have entries — harmless no-op
	-- until then.
	for player in racerStatuses do
		PlayerStateService.SetState(player, PlayerState.InRace)
	end
end

local function enterRacing()
	currentState = "Racing"
	-- TODO: enable hazards (AssemblyAngularVelocity), start lap tracking.
end

local function enterEnded()
	currentState = "Ended"
	-- TODO: broadcast standings via Network.Track.UpdateRaceStandings,
	-- pay out fan rewards through ProfileManager.

	for player in racerStatuses do
		PlayerStateService.SetState(player, PlayerState.InLobby)
	end

	-- Regenerate here (not in enterWaiting, which also runs on server
	-- startup right after TrackGenerator.Init() already built it once) so
	-- every race after the first is a "new experience" per spec.
	TrackGenerator.Regenerate(workspace)
end

-- ===== 3-lives / checkpoint respawn scaffolding =====

-- Called when a racer falls off (rotating hazard) or is combat-KO'd.
-- Checkpoint detection is spatial (workspace:GetPartsInPart against the
-- checkpoint's trigger part), never .Touched — see CheckpointValidator.
function GrandPrixManager.HandleRacerDown(player: Player)
	local status = racerStatuses[player]
	if status == nil or status.IsEliminated then
		return
	end

	status.LivesRemaining -= 1

	if status.LivesRemaining <= 0 then
		status.IsEliminated = true
		PlayerStateService.SetState(player, PlayerState.InLobby)
		-- TODO: teleport player back to Commercial Hub (0 lives case).
	else
		-- TODO: respawn player at TrackBlueprints segment matching
		-- status.LastCheckpointOrdinal.
	end
end

-- `checkpointOrdinal` is whole-course (1-8, one per ReplicatedStorage.
-- Configs.CourseSequence stop), not per-track-type — TrackBlueprints'
-- single Oval checkpoint currently reports ordinal 1 since Oval is
-- CourseSequence stop 1. Only the Oval exists as real geometry today, so
-- in practice this only ever receives 1 until more course stops are built.
function GrandPrixManager.HandleCheckpointReached(player: Player, checkpointOrdinal: number)
	local status = racerStatuses[player]
	if status == nil or status.IsEliminated then
		return
	end

	status.LastCheckpointOrdinal = checkpointOrdinal
	-- TODO: validate ordinal is sequential (see Security/CheckpointValidator)
	-- before trusting it, to prevent checkpoint-skip exploits.
end

-- ===== Public accessors =====

function GrandPrixManager.GetState() : RaceState
	return currentState
end

function GrandPrixManager.GetNextRaceStartTime() : number
	return nextRaceStartTime
end

-- ===== Loop =====

local function runLoop()
	while true do
		if currentState == "Waiting" and os.time() >= nextRaceStartTime then
			enterCountdown()
			task.wait(COUNTDOWN_SECONDS)
			enterRacing()
		elseif currentState == "Ended" then
			enterWaiting()
		end

		-- TODO: replace with real win-condition / timer checks that drive
		-- Racing -> Ended.

		task.wait(1)
	end
end

function GrandPrixManager.Init()
	enterWaiting()
	task.spawn(runLoop)
end

return GrandPrixManager

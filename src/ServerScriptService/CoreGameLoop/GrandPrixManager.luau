--!strict
--[[
	GrandPrixManager
	State machine for the hourly Grand Prix event: Waiting -> Countdown ->
	Racing -> Ended -> (loop). Scaffolding only — no scoring/spawn logic yet.

	Scheduling uses os.time() so the "hourly" cadence survives server
	restarts without drifting (per project convention: no wait()/spawn(),
	task.wait()/task.spawn() only).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

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

-- Broadcast so the client can gate UI (e.g. LiveRaceHUD only shows the
-- Grand Prix standings panel during Countdown/Racing) on whether a Grand
-- Prix is actually happening, instead of always showing an empty panel.
local function broadcastState()
	for _, player in Players:GetPlayers() do
		Network.Track.GrandPrixStateChanged:FireClient(player, currentState)
	end
end

-- ===== State transition handlers (scaffolding) =====

local function enterWaiting()
	currentState = "Waiting"
	racerStatuses = {}
	nextRaceStartTime = os.time() + RACE_INTERVAL_SECONDS
	-- TODO: open Hub access, disable track hazards.
	broadcastState()
end

local function enterCountdown()
	currentState = "Countdown"
	broadcastState()
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
	broadcastState()
end

local function enterEnded()
	currentState = "Ended"
	-- TODO: broadcast standings via Network.Track.UpdateRaceStandings,
	-- pay out fan rewards through ProfileManager.
	broadcastState()

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

-- `checkpointOrdinal` is 1-8, one per oval segment (TrackBlueprints.
-- OvalSegments/CheckpointOrdinal) — NOT wired to anything today, since
-- CheckpointValidator (the actual, active checkpoint system driving
-- ArcadeManager's free-run track) tracks progress itself and never calls
-- this function. This whole roster/GrandPrix-scoped checkpoint path
-- remains part of the still-unimplemented Countdown/roster flow.
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

	-- enterWaiting()'s broadcastState() above fires before anyone has
	-- joined; catch up anyone who joins after that (which, in practice, is
	-- everyone) with the state as of the moment they load in.
	Players.PlayerAdded:Connect(function(player: Player)
		Network.Track.GrandPrixStateChanged:FireClient(player, currentState)
	end)

	task.spawn(runLoop)
end

return GrandPrixManager

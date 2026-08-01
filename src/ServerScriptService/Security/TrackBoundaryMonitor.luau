--!strict
--[[
	TrackBoundaryMonitor
	New module (not in the original directory tree). Spatial-distance
	boundary enforcement (never .Touched), on a periodic check loop:

	- InLobby/AtFanBox player physically ends up on the track (jumped the
	  barrier instead of using EnterTrack) -> bounced back to the Hub, no
	  penalty. This is prevention, not punishment.
	- InRace player ends up off the track (jumped/knocked over a barrier)
	  or falls below the world (a "pit") -> ArcadeManager.HandleTrackViolation
	  (costs a life, respawns at the checkpoint).
	- InRace player moves against the track's direction of travel for more
	  than WRONG_DIRECTION_THRESHOLD_STUDS (cumulative, resets when they
	  move the right way again) -> fires a client-side warning.

	The track's centerline is sampled ONCE into a dense point cloud at
	Init() (each sample CFrame's own LookVector doubles as "the correct
	direction of travel there," since TrackPieceBuilder's samples are
	already oriented along the chain) rather than recomputed every check.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local TrackPieceBuilder = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("TrackPieceBuilder"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local ArcadeManager = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("ArcadeManager"))
local TeleportPoseService = require(script.Parent.Parent:WaitForChild("LobbyAndHub"):WaitForChild("TeleportPoseService"))

local CHECK_INTERVAL_SECONDS = 0.5
local STRAIGHT_SAMPLES_PER_SEGMENT = 6
local ON_TRACK_MARGIN = TrackGeometry.SegmentWidth / 2 + TrackGeometry.BarrierThickness + 10
local FALL_OUT_Y_THRESHOLD = -100
local WRONG_DIRECTION_THRESHOLD_STUDS = 20
local WRONG_DIRECTION_DOT_THRESHOLD = -0.3
-- A single check tick shouldn't see a legitimate racer move further than
-- this (even boosted); anything bigger is a teleport (EnterTrack, checkpoint
-- respawn, ReturnToHub, ...) and must not be counted as "moved backward."
local TELEPORT_JUMP_THRESHOLD_STUDS = 40

local TrackBoundaryMonitor = {}

local trackPoints: { Vector3 } = {}
local trackForwards: { Vector3 } = {}

local lastPositionByPlayer: { [Player]: Vector3 } = {}
local backwardAccumByPlayer: { [Player]: number } = {}
local wrongDirectionNotifiedByPlayer: { [Player]: boolean } = {}

local function buildTrackPointCloud()
	trackPoints = {}
	trackForwards = {}

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local samples: { CFrame }
		local exitCFrame: CFrame

		if segment.SegmentType == "Straight" then
			samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, STRAIGHT_SAMPLES_PER_SEGMENT)
		else
			samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, TrackGeometry.CurveSubdivisions)
		end

		for _, sampleCFrame in samples do
			table.insert(trackPoints, sampleCFrame.Position)
			table.insert(trackForwards, sampleCFrame.LookVector)
		end

		currentCFrame = exitCFrame
	end
end

-- Returns the index of the nearest track-centerline sample and the
-- distance to it. Used for both "are we on track" and "which way should
-- we be facing here."
local function findNearestTrackSample(position: Vector3) : (number?, number)
	local bestIndex: number? = nil
	local bestDistance = math.huge

	for index, point in trackPoints do
		local distance = (point - position).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			bestIndex = index
		end
	end

	return bestIndex, bestDistance
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function resetWrongDirectionTracking(player: Player)
	backwardAccumByPlayer[player] = 0
	wrongDirectionNotifiedByPlayer[player] = false
end

local function checkWrongDirection(player: Player, position: Vector3, nearestIndex: number)
	local lastPosition = lastPositionByPlayer[player]
	lastPositionByPlayer[player] = position

	if lastPosition == nil then
		return
	end

	local delta = position - lastPosition
	local deltaMagnitude = delta.Magnitude

	if deltaMagnitude < 0.5 then
		return -- effectively stationary; don't let noise reset progress
	end

	if deltaMagnitude > TELEPORT_JUMP_THRESHOLD_STUDS then
		-- Almost certainly a teleport (EnterTrack/checkpoint respawn/
		-- ReturnToHub), not real movement — don't count it either way.
		resetWrongDirectionTracking(player)
		return
	end

	local expectedForward = trackForwards[nearestIndex]
	local dot = delta.Unit:Dot(expectedForward)

	if dot < WRONG_DIRECTION_DOT_THRESHOLD then
		local accumulated = (backwardAccumByPlayer[player] or 0) + deltaMagnitude
		backwardAccumByPlayer[player] = accumulated

		if accumulated > WRONG_DIRECTION_THRESHOLD_STUDS and not wrongDirectionNotifiedByPlayer[player] then
			Network.Track.ShowNotification:FireClient(player, "WRONG DIRECTION")
			wrongDirectionNotifiedByPlayer[player] = true
		end
	else
		resetWrongDirectionTracking(player)
	end
end

local function checkPlayer(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local state = PlayerStateService.GetState(player)
	local position = rootPart.Position
	local _, nearestDistance = findNearestTrackSample(position)
	local onTrack = nearestDistance <= ON_TRACK_MARGIN

	if state == PlayerState.InRace then
		local fellOut = position.Y < FALL_OUT_Y_THRESHOLD
		if fellOut or not onTrack then
			ArcadeManager.HandleTrackViolation(player)
			resetWrongDirectionTracking(player)
			lastPositionByPlayer[player] = nil -- next tick just re-baselines post-respawn
			return
		end

		local nearestIndex = select(1, findNearestTrackSample(position))
		if nearestIndex ~= nil then
			checkWrongDirection(player, position, nearestIndex)
		end
	elseif state == PlayerState.InLobby or state == PlayerState.AtFanBox then
		if onTrack then
			-- Jumped/climbed onto the track without going through
			-- EnterTrack — bounce back, no penalty.
			TeleportPoseService.ReturnToHub(player)
			lastPositionByPlayer[player] = nil
		end
	end
end

function TrackBoundaryMonitor.Init()
	buildTrackPointCloud()

	Players.PlayerRemoving:Connect(function(player: Player)
		lastPositionByPlayer[player] = nil
		backwardAccumByPlayer[player] = nil
		wrongDirectionNotifiedByPlayer[player] = nil
	end)

	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				checkPlayer(player)
			end
			task.wait(CHECK_INTERVAL_SECONDS)
		end
	end)
end

return TrackBoundaryMonitor

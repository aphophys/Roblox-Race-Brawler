--!strict
--[[
	HubGenerator
	New module (not in the original directory tree) — builds the Commercial
	Hub platform inside the oval (the inner ring of the 3-ring design) and
	places the server's SpawnLocation on it, so players start inside the
	oval where they can pick skills before heading to the track or their
	Fan Box.

	The Hub's position is the centroid of the oval's 8 piece entry points —
	walks the same TrackBlueprints/TrackGeometry chain as TrackGenerator/
	FanBoxGenerator (via TrackPieceBuilder's Sample* helpers, only using
	them for the chained exit CFrame, not to place geometry) rather than a
	hand-measured position, so it stays correct if the track's dimensions
	change. This is an approximation (average of entry points, not a true
	polygon centroid) — good enough for a roughly symmetric oval.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

local HUB_RADIUS = 140
local HUB_FLOOR_THICKNESS = 4
local HUB_FLOOR_COLOR = Color3.fromRGB(90, 200, 120)
local SPAWN_PAD_SIZE = Vector3.new(12, 1, 12)

local HubGenerator = {}

local cachedHubCFrame: CFrame? = nil

local function computeHubCFrame() : CFrame
	local currentCFrame = CFrame.new(0, 0, 0)
	local entryPositions: { Vector3 } = {}

	for _, segment in TrackBlueprints.OvalSegments do
		table.insert(entryPositions, currentCFrame.Position)

		local exitCFrame: CFrame
		if segment.SegmentType == "Straight" then
			local _, straightExit = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, 1)
			exitCFrame = straightExit
		else
			local _, curveExit = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, 1)
			exitCFrame = curveExit
		end
		currentCFrame = exitCFrame
	end

	local sum = Vector3.new(0, 0, 0)
	for _, position in entryPositions do
		sum += position
	end

	return CFrame.new(sum / #entryPositions)
end

-- Returns the last-generated Hub's center CFrame, for TeleportPoseService.
-- ReturnToHub. nil until GenerateHub has run once.
function HubGenerator.GetHubCFrame() : CFrame?
	return cachedHubCFrame
end

function HubGenerator.GenerateHub(parent: Instance) : Model
	local hubCFrame = computeHubCFrame()
	cachedHubCFrame = hubCFrame

	local hubModel = Instance.new("Model")
	hubModel.Name = "Hub"

	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Shape = Enum.PartType.Cylinder
	floor.Material = Enum.Material.Grass
	floor.Color = HUB_FLOOR_COLOR
	floor.Size = Vector3.new(HUB_FLOOR_THICKNESS, HUB_RADIUS * 2, HUB_RADIUS * 2)
	-- Cylinder's default axis is local X; rotate so it lies flat (axis up Y).
	floor.CFrame = hubCFrame * CFrame.Angles(0, 0, math.rad(90))
	floor.Name = "HubFloor"
	floor.Parent = hubModel

	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Anchored = true
	spawnPad.Neutral = true
	spawnPad.Size = SPAWN_PAD_SIZE
	spawnPad.CFrame = hubCFrame * CFrame.new(0, HUB_FLOOR_THICKNESS / 2 + SPAWN_PAD_SIZE.Y / 2, 0)
	spawnPad.Name = "HubSpawn"
	spawnPad.Parent = hubModel

	hubModel.PrimaryPart = spawnPad
	hubModel.Parent = parent

	return hubModel
end

function HubGenerator.Init()
	HubGenerator.GenerateHub(workspace)
end

return HubGenerator

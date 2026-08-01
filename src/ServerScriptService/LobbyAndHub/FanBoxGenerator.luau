--!strict
--[[
	FanBoxGenerator
	New module (not in the original directory tree) — builds the 20-pod
	Outer Ring around the core oval: for each of the 4 Straight track
	pieces, 3 evenly-spaced "Straight" fan box pods (12 total); for each of
	the 4 Curve track pieces, 2 evenly-spaced "Curve" fan box pods (8
	total). 12 + 8 = 20, matching the requested split.

	Walks TrackBlueprints/TrackGeometry itself (via TrackPieceBuilder's
	Sample* helpers) rather than depending on TrackGenerator having run —
	both start from the same CFrame.new(0,0,0) and read the same configs,
	so they produce identical, independently-computed chains.

	Pods are placed on the local +X side of every piece. Because every
	curve in the oval turns the same direction (see TrackPieceBuilder.
	BuildCurve), +X stays on the same physical side (inside or outside the
	loop) for the whole lap — which side that physically ends up being
	doesn't matter for this greybox pass, but it's a real assumption if the
	oval's turn direction ever changes.

	Every pod starts at FanBoxTiers.Tiers[1] scale (empty) and is named
	"__EmptySlot_<n>" — FanBoxSlotManager renames it to the occupying
	player's name on assignment, which is what FansBoxRenderer (client)
	looks up by.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local FanBoxTiers = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("FanBoxTiers"))

local TrackPieceBuilder = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("TrackPieceBuilder"))

local STRAIGHT_PODS_PER_PIECE = 3
local CURVE_PODS_PER_PIECE = 2
local RING_GAP = 30 -- studs beyond the track barrier before the fan box ring starts

local FanBoxGenerator = {}

local function podOffsetCFrame() : CFrame
	local lateralOffset = TrackGeometry.SegmentWidth / 2 + TrackGeometry.BarrierThickness + RING_GAP
	return CFrame.new(lateralOffset, 0, 0)
end

local function buildPod(parent: Instance, centerCFrame: CFrame, slotIndex: number, shape: "Straight" | "Curve") : Model
	local emptyTier = FanBoxTiers.Tiers[1]

	local pod = Instance.new("Model")
	pod.Name = `__EmptySlot_{slotIndex}`
	pod:SetAttribute("SlotIndex", slotIndex)
	pod:SetAttribute("SlotShape", shape)

	local crowdMesh = Instance.new("Part")
	crowdMesh.Name = "CrowdMesh"
	crowdMesh.Anchored = true
	crowdMesh.Material = Enum.Material.Fabric
	crowdMesh.Color = Color3.fromRGB(60, 120, 200)
	crowdMesh.Size = FanBoxTiers.PodBaseSize * emptyTier.MeshScale
	crowdMesh.CFrame = centerCFrame * podOffsetCFrame() * CFrame.new(0, FanBoxTiers.PodBaseSize.Y / 2, 0)
	crowdMesh.Parent = pod

	pod.PrimaryPart = crowdMesh
	pod.Parent = parent

	return pod
end

-- Builds all 20 pods under `parent`, returns the folder containing them.
function FanBoxGenerator.GenerateRing(parent: Instance) : Folder
	local fanBoxFolder = Instance.new("Folder")
	fanBoxFolder.Name = "FanBoxes"

	local currentCFrame = CFrame.new(0, 0, 0)
	local slotIndex = 0

	for _, segment in TrackBlueprints.OvalSegments do
		if segment.SegmentType == "Straight" then
			local samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, STRAIGHT_PODS_PER_PIECE)
			for _, sampleCFrame in samples do
				slotIndex += 1
				buildPod(fanBoxFolder, sampleCFrame, slotIndex, "Straight")
			end
			currentCFrame = exitCFrame
		else
			local samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, CURVE_PODS_PER_PIECE)
			for _, sampleCFrame in samples do
				slotIndex += 1
				buildPod(fanBoxFolder, sampleCFrame, slotIndex, "Curve")
			end
			currentCFrame = exitCFrame
		end
	end

	fanBoxFolder.Parent = parent
	return fanBoxFolder
end

function FanBoxGenerator.Init()
	FanBoxGenerator.GenerateRing(workspace)
end

return FanBoxGenerator

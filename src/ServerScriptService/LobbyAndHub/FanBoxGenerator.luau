--!strict
--[[
	FanBoxGenerator
	Builds the Outer Ring around the core oval: for each of the 4 Straight
	track pieces, N evenly-spaced "Straight" fan box pods; for each of the
	4 Curve track pieces, M evenly-spaced "Curve" fan box pods. N and M are
	derived from Players.MaxPlayers (the server's configured player cap:
	Studio -> Home tab -> Game Settings -> Players -> Max Players; also
	readable/settable live in a script as `game.Players.MaxPlayers`) so the
	total pod count scales with however many concurrent players this server
	can actually hold, split straight:curve in a 3:2 per-piece ratio. At
	MaxPlayers == 20 this produces the original fixed 12 Straight + 8 Curve
	split.

	Walks TrackBlueprints/TrackGeometry itself (via TrackPieceBuilder's
	Sample* helpers) rather than depending on TrackGenerator having run —
	both start from the same CFrame.new(0,0,0) and read the same configs,
	so they produce identical, independently-computed chains.

	Pods are placed on the local -X side of every piece (the LEFT of the
	direction of travel). Because every curve in the oval turns the same
	direction (clockwise — see TrackPieceBuilder.SampleCurve), one side
	stays consistently outside the loop for the whole lap: for a clockwise
	loop, the interior is always on the RIGHT of travel, so outside is
	always -X.

	Every pod is always visible, starting at Tier1 ("Empty") and named
	"__EmptySlot_<n>" — FanBoxSlotManager renames it to the occupying
	player's name on assignment (and back on release, resetting it to
	Tier1). An unclaimed pod deliberately still shows a baseline crowd
	rather than nothing — per explicit instruction, the only real
	requirement is that each player gets exactly one pod for as long as
	they're in the server, not that unclaimed pods look empty.

	===== Crowd geometry is now templated, not built per pod =====
	Every pod's CrowdMesh used to be independently built (3 steps + 21 noob
	figures) and UnionAsync-ed from scratch — correct, but that meant one
	full CSG operation per pod (pod count scales with Players.MaxPlayers).
	FanBoxCrowdTemplates now builds the 5 FanBoxTiers crowd shapes ONCE (a
	single real UnionAsync call total) and stores them as reusable
	templates under ReplicatedStorage.Assets.FanBoxCrowdTemplates. buildPod
	below just Clones the Tier1 (Empty) template and repositions it — no
	yielding, no per-pod CSG risk. SwapPodTier (used by FanBoxSlotManager
	whenever a pod's occupant or their fan count changes) swaps in whatever
	tier template actually matches, the same way.

	Because pod construction is now just a Clone + CFrame set (no yielding
	operation left per pod), GenerateRing no longer needs the batched-
	concurrency scheme a from-scratch UnionAsync-per-pod design required —
	it's a plain sequential loop again.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local FanBoxTiers = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("FanBoxTiers"))

local TrackPieceBuilder = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("TrackPieceBuilder"))
local FanBoxCrowdTemplates = require(script.Parent:WaitForChild("FanBoxCrowdTemplates"))

-- Original fixed design was 3 Straight pods per Straight piece, 2 Curve
-- pods per Curve piece (12 + 8 = 20 total, at 4 pieces of each type). Kept
-- as a 3:2 WEIGHT ratio and scaled by Players.MaxPlayers (see
-- computePodsPerPiece) instead of being fixed numbers, so the total pod
-- count tracks however many concurrent players this server can hold.
local STRAIGHT_POD_WEIGHT = 3
local CURVE_POD_WEIGHT = 2
local PIECE_COUNT_PER_TYPE = 4 -- the oval has 4 Straight + 4 Curve pieces (TrackBlueprints)
local FALLBACK_MAX_PLAYERS = 20 -- used only if Players.MaxPlayers is unset/0, which shouldn't normally happen

local RING_GAP = 30 -- studs beyond the track barrier before the fan box ring starts

local DEFAULT_TIER_INDEX = 1 -- "Empty" — what every pod starts as before a player is assigned

local FanBoxGenerator = {}

local function podOffsetCFrame() : CFrame
	local lateralOffset = TrackGeometry.SegmentWidth / 2 + TrackGeometry.BarrierThickness + RING_GAP
	return CFrame.new(-lateralOffset, 0, 0)
end

-- Derives (straightPodsPerPiece, curvePodsPerPiece) from Players.MaxPlayers
-- so the ring's total pod count scales with this server's actual player
-- cap instead of a fixed number — see module docstring. Preserves the
-- original 3:2 straight:curve per-piece ratio; at MaxPlayers == 20 this
-- returns exactly (3, 2), reproducing the original fixed 12+8 design.
local function computePodsPerPiece() : (number, number)
	local maxPlayers = Players.MaxPlayers
	if maxPlayers == nil or maxPlayers <= 0 then
		maxPlayers = FALLBACK_MAX_PLAYERS
	end

	local totalWeight = (STRAIGHT_POD_WEIGHT + CURVE_POD_WEIGHT) * PIECE_COUNT_PER_TYPE
	local podsPerWeightUnit = maxPlayers / totalWeight

	local straightPodsPerPiece = math.max(1, math.round(STRAIGHT_POD_WEIGHT * podsPerWeightUnit))
	local curvePodsPerPiece = math.max(1, math.round(CURVE_POD_WEIGHT * podsPerWeightUnit))

	return straightPodsPerPiece, curvePodsPerPiece
end

-- Fallback used only if FanBoxCrowdTemplates has no template ready (e.g.
-- its own debug/inspection mode is on) — a plain block, so a pod is never
-- left without SOME BasePart named "CrowdMesh".
local function buildFallbackBlock(originCFrame: CFrame) : BasePart
	local block = Instance.new("Part")
	block.Anchored = true
	block.CanCollide = true -- a fan box stand should be something a player can stand on, not pass through
	block.Material = Enum.Material.Fabric
	block.Color = Color3.fromRGB(60, 120, 200)
	block.Size = FanBoxTiers.PodBaseSize
	block.CFrame = originCFrame * CFrame.new(0, FanBoxTiers.PodBaseSize.Y / 2, 0)
	block.Name = "CrowdMesh"
	return block
end

-- Clones the given tier's template Model and positions it at
-- `originCFrame` via Model:PivotTo (robust regardless of whatever CFrame
-- the CrowdMesh part itself ends up with — see FanBoxCrowdTemplates'
-- docstring for why the previous CFrame-composition approach was wrong),
-- then extracts just the CrowdMesh part, discarding the temporary
-- Model+GroundPivot wrapper.
local function cloneTierAt(tierIndex: number, originCFrame: CFrame) : BasePart
	local template = FanBoxCrowdTemplates.GetTemplateForTier(tierIndex)
	if template == nil then
		return buildFallbackBlock(originCFrame)
	end

	local modelClone = template:Clone()
	modelClone:PivotTo(originCFrame)

	local crowdMesh = modelClone:FindFirstChild("CrowdMesh")
	if crowdMesh == nil or not crowdMesh:IsA("BasePart") then
		modelClone:Destroy()
		return buildFallbackBlock(originCFrame)
	end

	crowdMesh.Parent = nil -- detach before destroying the wrapper, so it survives
	modelClone:Destroy()

	return crowdMesh :: BasePart
end

-- Swaps a pod's CrowdMesh for the given tier's template, in place (same
-- position) — used both when a player is first assigned a pod, whenever
-- their fan count crosses into a new tier while they hold it, and when a
-- pod is released (reset back to Tier1). Destroys the pod's previous
-- CrowdMesh.
function FanBoxGenerator.SwapPodTier(pod: Model, tierIndex: number)
	local oldCrowdMesh = pod:FindFirstChild("CrowdMesh")
	local targetCFrame: CFrame? = nil
	if oldCrowdMesh ~= nil and oldCrowdMesh:IsA("BasePart") then
		targetCFrame = (oldCrowdMesh :: BasePart).CFrame
	end
	if targetCFrame == nil then
		return
	end

	local newCrowdMesh = cloneTierAt(tierIndex, targetCFrame)
	newCrowdMesh.Parent = pod
	pod.PrimaryPart = newCrowdMesh

	if oldCrowdMesh ~= nil then
		oldCrowdMesh:Destroy()
	end
end

local function buildPod(parent: Instance, centerCFrame: CFrame, slotIndex: number, shape: "Straight" | "Curve") : Model
	local pod = Instance.new("Model")
	pod.Name = `__EmptySlot_{slotIndex}`
	pod:SetAttribute("SlotIndex", slotIndex)
	pod:SetAttribute("SlotShape", shape)

	local originCFrame = centerCFrame * podOffsetCFrame()
	local crowdMesh = cloneTierAt(DEFAULT_TIER_INDEX, originCFrame)
	crowdMesh.Parent = pod
	pod.PrimaryPart = crowdMesh

	pod.Parent = parent

	return pod
end

-- Builds all pods under `parent`, returns the folder containing them.
function FanBoxGenerator.GenerateRing(parent: Instance) : Folder
	local fanBoxFolder = Instance.new("Folder")
	fanBoxFolder.Name = "FanBoxes"

	local straightPodsPerPiece, curvePodsPerPiece = computePodsPerPiece()

	local currentCFrame = CFrame.new(0, 0, 0)
	local slotIndex = 0

	for _, segment in TrackBlueprints.OvalSegments do
		if segment.SegmentType == "Straight" then
			local samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, straightPodsPerPiece)
			for _, sampleCFrame in samples do
				slotIndex += 1
				buildPod(fanBoxFolder, sampleCFrame, slotIndex, "Straight")
			end
			currentCFrame = exitCFrame
		else
			local samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, curvePodsPerPiece)
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
	FanBoxCrowdTemplates.BuildAll()
	FanBoxGenerator.GenerateRing(workspace)
end

return FanBoxGenerator

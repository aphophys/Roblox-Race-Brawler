--!strict
--[[
	FanBoxGenerator
	Builds the Outer Ring around the core oval: for each of the 4 Straight
	track pieces, N evenly-spaced "Straight" fan box pods; for each of the
	4 Curve track pieces, M evenly-spaced "Curve" fan box pods.

	===== Pod count/spacing/width: derived together, not independently
	(this round's redesign) =====
	N and M used to come from a fixed 3:2 straight:curve WEIGHT ratio
	scaled by Players.MaxPlayers — arbitrary, and didn't account for
	straight and curve pieces having genuinely different lengths (a 90°
	curve at TrackGeometry.CurveRadius is actually LONGER than a straight
	piece here), so pods ended up unevenly spaced around the loop, and at
	their fixed built width they never came close to touching. Per
	explicit instruction ("make it wider to almost... be connected to
	other fans box and make it even between curve and straight tracks to
	simulate 'stadium look'"), computePodsPerPiece now:
	1. Computes the WHOLE loop's real arc length (4 straights + 4 curves,
	   using each piece's true length, not a guess).
	2. Picks a pod COUNT: however many NOMINAL_POD_WIDTH-wide pods
	   naturally fit that loop, OR Players.MaxPlayers, whichever is larger
	   (so every player is still guaranteed a pod).
	3. Derives the ACTUAL pod width from `loopArcLength / podCount` — the
	   exact width that makes that many pods tile the whole loop with zero
	   gap and zero overlap. This width is normally close to
	   NOMINAL_POD_WIDTH, but shrinks below it if Players.MaxPlayers needs
	   more pods than the nominal width could fit without overlapping —
	   an earlier version scaled up the COUNT alone in that case and left
	   pods physically overlapping (caught via live Studio measurement:
	   adjacent pod centers were 30 studs apart while each pod was built
	   35 studs wide). This width is passed to FanBoxCrowdTemplates.
	   BuildAll() so the actual built geometry always matches.
	4. Splits that pod count between straight/curve pieces using the
	   SAME derived width for both (`round(pieceLength / actualWidth)`),
	   which is what makes the straight:curve spacing genuinely even
	   instead of an assumed ratio.

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

-- The DEFAULT pod width to build at if the track comfortably fits enough
-- of them — matches FanBoxTiers.PodBaseSize.Z. computePodsPerPiece may
-- derive a SMALLER actual width than this if Players.MaxPlayers needs
-- more pods than fit the loop at this nominal width without overlapping.
local NOMINAL_POD_WIDTH = FanBoxTiers.PodBaseSize.Z
local PIECE_COUNT_PER_TYPE = 4 -- the oval has 4 Straight + 4 Curve pieces (TrackBlueprints)
local FALLBACK_MAX_PLAYERS = 20 -- used only if Players.MaxPlayers is unset/0, which shouldn't normally happen

local RING_GAP = 30 -- studs beyond the track barrier before the fan box ring starts

local DEFAULT_TIER_INDEX = 1 -- "Empty" — what every pod starts as before a player is assigned

-- Set once by GenerateRing (via computePodsPerPiece) at server start, and
-- read again later by SwapPodTier — a live tier-graduation swap needs the
-- SAME actual pod width this server generated pods at, not the nominal
-- default, or a fallback-block swap could end up a different width than
-- its neighbors.
local currentPodWidth: number = FanBoxTiers.PodBaseSize.Z

local FanBoxGenerator = {}

local function podOffsetCFrame() : CFrame
	local lateralOffset = TrackGeometry.SegmentWidth / 2 + TrackGeometry.BarrierThickness + RING_GAP
	return CFrame.new(-lateralOffset, 0, 0)
end

-- Derives (straightPodsPerPiece, curvePodsPerPiece, actualPodWidth) — see
-- module docstring for the full 4-step reasoning. A 90° curve at
-- TrackGeometry.CurveRadius has arc length radius * angleInRadians; a
-- straight piece's length is just TrackGeometry.StraightLength.
local function computePodsPerPiece() : (number, number, number)
	local maxPlayers = Players.MaxPlayers
	if maxPlayers == nil or maxPlayers <= 0 then
		maxPlayers = FALLBACK_MAX_PLAYERS
	end

	local curveArcLengthStuds = TrackGeometry.CurveRadius * math.rad(TrackGeometry.CurveArcDegrees)
	local loopArcLengthStuds = PIECE_COUNT_PER_TYPE * (TrackGeometry.StraightLength + curveArcLengthStuds)

	local naturalPodCount = math.max(1, math.round(loopArcLengthStuds / NOMINAL_POD_WIDTH))
	local podCount = math.max(naturalPodCount, maxPlayers)

	-- The width that makes exactly `podCount` pods tile the whole loop
	-- with zero gap AND zero overlap — normally close to
	-- NOMINAL_POD_WIDTH, only shrinking below it if maxPlayers pushed
	-- podCount higher than the loop naturally fits at that nominal width.
	local actualPodWidth = loopArcLengthStuds / podCount

	local straightPodsPerPiece = math.max(1, math.round(TrackGeometry.StraightLength / actualPodWidth))
	local curvePodsPerPiece = math.max(1, math.round(curveArcLengthStuds / actualPodWidth))

	return straightPodsPerPiece, curvePodsPerPiece, actualPodWidth
end

-- Fallback used only if FanBoxCrowdTemplates has no template ready (e.g.
-- its own debug/inspection mode is on) — a plain block, so a pod is never
-- left without SOME BasePart named "CrowdMesh". Sized at `podWidth` (the
-- same actual width real templates were built at this server run) so a
-- fallback pod still lines up with its neighbors instead of leaving a
-- gap or overlap in the stand.
local function buildFallbackBlock(originCFrame: CFrame, podWidth: number) : BasePart
	local block = Instance.new("Part")
	block.Anchored = true
	block.CanCollide = true -- a fan box stand should be something a player can stand on, not pass through
	block.Material = Enum.Material.Fabric
	block.Color = Color3.fromRGB(60, 120, 200)
	block.Size = Vector3.new(FanBoxTiers.PodBaseSize.X, FanBoxTiers.PodBaseSize.Y, podWidth)
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
local function cloneTierAt(tierIndex: number, originCFrame: CFrame, podWidth: number) : BasePart
	local template = FanBoxCrowdTemplates.GetTemplateForTier(tierIndex)
	if template == nil then
		return buildFallbackBlock(originCFrame, podWidth)
	end

	local modelClone = template:Clone()
	modelClone:PivotTo(originCFrame)

	local crowdMesh = modelClone:FindFirstChild("CrowdMesh")
	if crowdMesh == nil or not crowdMesh:IsA("BasePart") then
		modelClone:Destroy()
		return buildFallbackBlock(originCFrame, podWidth)
	end

	crowdMesh.Parent = nil -- detach before destroying the wrapper, so it survives
	modelClone:Destroy()

	return crowdMesh :: BasePart
end

-- Swaps a pod's CrowdMesh for the given tier's template, in place — used
-- both when a player is first assigned a pod, whenever their fan count
-- crosses into a new tier while they hold it, and when a pod is released
-- (reset back to Tier1). Destroys the pod's previous CrowdMesh.
--
-- CONFIRMED BUG, found via direct Studio inspection (execute_luau), not
-- guessing: this used to read `targetCFrame = oldCrowdMesh.CFrame` — the
-- OLD crowd mesh's own CFrame, which is its CSG centroid (e.g. Y=4.75 for
-- a populated tier whose shape spans Y 0-9.5), NOT the pod's actual
-- ground-level origin (Y=0). Every swap therefore re-pivoted the new
-- clone's GroundPivot to the previous mesh's centroid height instead of
-- true ground, adding that height again on top — compounding upward with
-- every single swap (explains "still floating... and now higher": at
-- least one swap always happens via FanBoxSlotManager.AssignSlot, even
-- for a same-tier reassignment, and live tier-graduation swaps stack
-- further). Fixed by having buildPod stamp the pod's real ground-level
-- originCFrame as a CFrame attribute at creation time, and reading THAT
-- here instead of ever inferring a ground reference from a mesh's own
-- CFrame again.
function FanBoxGenerator.SwapPodTier(pod: Model, tierIndex: number)
	local originCFrame = pod:GetAttribute("OriginCFrame")
	if typeof(originCFrame) ~= "CFrame" then
		return
	end

	local oldCrowdMesh = pod:FindFirstChild("CrowdMesh")

	local newCrowdMesh = cloneTierAt(tierIndex, originCFrame, currentPodWidth)
	newCrowdMesh.Parent = pod
	pod.PrimaryPart = newCrowdMesh

	if oldCrowdMesh ~= nil then
		oldCrowdMesh:Destroy()
	end
end

local function buildPod(parent: Instance, centerCFrame: CFrame, slotIndex: number, shape: "Straight" | "Curve", podWidth: number) : Model
	local pod = Instance.new("Model")
	pod.Name = `__EmptySlot_{slotIndex}`
	pod:SetAttribute("SlotIndex", slotIndex)
	pod:SetAttribute("SlotShape", shape)

	local originCFrame = centerCFrame * podOffsetCFrame()
	pod:SetAttribute("OriginCFrame", originCFrame) -- the one true ground-level reference for this pod — see SwapPodTier

	local crowdMesh = cloneTierAt(DEFAULT_TIER_INDEX, originCFrame, podWidth)
	crowdMesh.Parent = pod
	pod.PrimaryPart = crowdMesh

	pod.Parent = parent

	return pod
end

-- Builds all pods under `parent`, returns the folder containing them.
function FanBoxGenerator.GenerateRing(parent: Instance) : Folder
	local fanBoxFolder = Instance.new("Folder")
	fanBoxFolder.Name = "FanBoxes"

	local straightPodsPerPiece, curvePodsPerPiece, podWidth = computePodsPerPiece()
	currentPodWidth = podWidth -- remembered for SwapPodTier, see its declaration

	local currentCFrame = CFrame.new(0, 0, 0)
	local slotIndex = 0

	for _, segment in TrackBlueprints.OvalSegments do
		if segment.SegmentType == "Straight" then
			local samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, straightPodsPerPiece)
			for _, sampleCFrame in samples do
				slotIndex += 1
				buildPod(fanBoxFolder, sampleCFrame, slotIndex, "Straight", podWidth)
			end
			currentCFrame = exitCFrame
		else
			local samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, curvePodsPerPiece)
			for _, sampleCFrame in samples do
				slotIndex += 1
				buildPod(fanBoxFolder, sampleCFrame, slotIndex, "Curve", podWidth)
			end
			currentCFrame = exitCFrame
		end
	end

	fanBoxFolder.Parent = parent
	return fanBoxFolder
end

function FanBoxGenerator.Init()
	local _, _, podWidth = computePodsPerPiece()
	FanBoxCrowdTemplates.BuildAll(podWidth)
	FanBoxGenerator.GenerateRing(workspace)
end

return FanBoxGenerator

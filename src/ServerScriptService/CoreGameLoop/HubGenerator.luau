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

-- The Hub sits at the oval's centroid; the closest the track's own paved
-- surface ever gets to that centroid is along the two straights, at
-- distance (CurveRadius - SegmentWidth/2) — the two straights sit exactly
-- 2*CurveRadius apart, straddling the centroid, and the road's inner edge
-- is SegmentWidth/2 in from its centerline. Deriving HUB_RADIUS from that
-- (with a real safety margin) instead of a hand-picked number: a
-- previous flat 140 studs left only ~4 studs of actual clearance against
-- the track edge at TrackGeometry's current values (CurveRadius=180,
-- SegmentWidth=72 -> 180-36=144) — razor-thin enough that a HazardBar (a
-- spinning rod placed at a random segment's midpoint) reportedly ended up
-- visibly inside the Commercial Hub. This also means HUB_RADIUS
-- automatically stays safe if TrackGeometry's dimensions ever change,
-- instead of silently drifting back into the track again.
-- Widened from 40 to 14 so the pavement actually reaches everything in the
-- commercial hub — the leaderboards and the vendor stands previously stood on
-- bare terrain OUTSIDE it, which is what made them read as floating: they were
-- being placed at the floor's top face (Y+2) while the ground under them was
-- terrain at Y ~ 0.
--
-- 14 studs is still a real margin against the track's inner edge, and the
-- original reason for 40 does not apply here: that was a spinning HazardBar
-- placed at a SEGMENT midpoint reaching into the hub, and segment midpoints
-- are on the road itself, 36+ studs beyond this edge.
local HUB_RADIUS_SAFETY_MARGIN = 14
local HUB_RADIUS = TrackGeometry.CurveRadius - TrackGeometry.SegmentWidth / 2 - HUB_RADIUS_SAFETY_MARGIN
local HUB_FLOOR_THICKNESS = 4

-- ===== Why the floor is a STADIUM and not a disc =====
--
-- The infield is not circular, so a circular floor can only ever cover a
-- fraction of it. Walking the piece chain gives the exact shape: the two
-- straight sides sit 2*CurveRadius apart straddling the centroid, and each
-- end is a SEMICIRCLE of radius CurveRadius whose centre is at the end of the
-- straights — the two curve pieces at one end share a centre (verified by
-- tracing the chain: both End1 pieces turn about the same point). Subtract
-- SegmentWidth/2 for the road's inner edge and the paved infield is a
-- stadium: half-width HUB_RADIUS across the straights, and a rectangle
-- HUB_STRAIGHT_HALF_LENGTH either side of centre capped by two HUB_RADIUS
-- half-discs, reaching HUB_RADIUS + HUB_STRAIGHT_HALF_LENGTH toward the curve
-- ends.
--
-- This matters because the two curve-side leaderboards stand at radius 190,
-- which is BEYOND the straights' inner edge (144) — no disc can reach them
-- without cutting through the road. The previous attempt to fix the floating
-- moved the boards and the vendor stands inward onto the disc instead; that
-- is the wrong half of the problem to move, because their positions were
-- chosen against TrackBoundaryMonitor's margin (see LeaderboardBuilder) and
-- are not free to change. The floor grows to meet them instead.
--
-- One straight SIDE of the oval is several straight pieces long, so the
-- rectangle's half-length is derived from how many straights the blueprint
-- puts on a side rather than from a single piece's length.
local STRAIGHT_SEGMENT_COUNT = (function() : number
	local count = 0
	for _, segment in TrackBlueprints.OvalSegments do
		if segment.SegmentType == "Straight" then
			count += 1
		end
	end
	return count
end)()
local STRAIGHTS_PER_SIDE = STRAIGHT_SEGMENT_COUNT / 2
local HUB_STRAIGHT_HALF_LENGTH = TrackGeometry.StraightLength * STRAIGHTS_PER_SIDE / 2
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

-- Unit direction the straights RUN along, i.e. the stadium's long axis. Taken
-- from the first straight piece's own travel rather than assumed to be world
-- Z: the oval happens to be built axis-aligned today (the chain starts at an
-- identity CFrame), and this returns exactly (0, 0, -1) for it, but deriving
-- it means the floor stays correct if the track is ever laid down rotated.
-- The returned CFrame keeps IDENTITY rotation on purpose — LeaderboardBuilder
-- and HubAmenitiesBuilder both place things with world-axis offsets from
-- GetHubCFrame, so rotating it here would silently rotate the furniture out
-- from under the floor.
local function computeStraightAxis() : Vector3
	local _, exitCFrame = TrackPieceBuilder.SampleStraight(CFrame.new(0, 0, 0), TrackGeometry.StraightLength, 1)
	return exitCFrame.Position.Unit
end

-- Returns the last-generated Hub's center CFrame, for TeleportPoseService.
-- ReturnToHub. nil until GenerateHub has run once.
function HubGenerator.GetHubCFrame() : CFrame?
	return cachedHubCFrame
end

-- Exported so HubAmenitiesBuilder and LeaderboardBuilder place furniture
-- relative to the REAL disc instead of each re-deriving the same formula —
-- three copies of it is three chances for the floor and the things standing
-- on it to disagree about where the edge is.
-- Half-width of the pavement measured ACROSS the straights — the tightest
-- direction, and the one everything laid out as a ring has to fit inside.
HubGenerator.HubRadius = HUB_RADIUS
-- Half-length of the pavement's rectangular middle, along the straights.
-- Toward the curve ends the pavement continues for another HUB_RADIUS on top
-- of this (the stadium's end caps).
HubGenerator.HubStraightHalfLength = HUB_STRAIGHT_HALF_LENGTH
-- Furthest the pavement reaches from the centre, toward either curve end.
HubGenerator.HubHalfLength = HUB_STRAIGHT_HALF_LENGTH + HUB_RADIUS
-- World Y of the floor's walkable surface.
HubGenerator.FloorTopY = HUB_FLOOR_THICKNESS / 2

-- True when a world position stands over the pavement (Y is ignored). The
-- stadium test lives HERE, next to the code that builds the shape, so a
-- builder placing furniture can ask instead of re-deriving the outline — the
-- floating bugs in this hub have all been some other module holding its own
-- stale copy of where the floor ends.
--
-- A stadium is exactly "within HUB_RADIUS of the spine", where the spine is
-- the segment of length 2*HUB_STRAIGHT_HALF_LENGTH along the straights; that
-- single distance-to-segment covers the rectangle and both end caps at once.
-- Returns false before GenerateHub has run, since there is no floor yet.
function HubGenerator.IsOnPavement(worldPosition: Vector3) : boolean
	local hubCFrame = cachedHubCFrame
	if hubCFrame == nil then
		return false
	end

	local axis = computeStraightAxis()
	local offset = worldPosition - hubCFrame.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local along = math.clamp(flat:Dot(axis), -HUB_STRAIGHT_HALF_LENGTH, HUB_STRAIGHT_HALF_LENGTH)
	return (flat - axis * along).Magnitude <= HUB_RADIUS
end

-- Guarantees the Hub's own SpawnLocation is unambiguously where players
-- land — disables (not destroys, in case it's something the user placed
-- intentionally) any other SpawnLocation in Workspace. Without this, a
-- leftover default-template SpawnLocation could compete with ours and win,
-- which would put players on/near the track instead of the Hub.
local function disableOtherSpawnLocations(oursSpawn: SpawnLocation)
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("SpawnLocation") and descendant ~= oursSpawn then
			descendant.Enabled = false
		end
	end
end

function HubGenerator.GenerateHub(parent: Instance) : Model
	local hubCFrame = computeHubCFrame()
	cachedHubCFrame = hubCFrame

	local hubModel = Instance.new("Model")
	hubModel.Name = "Hub"

	-- Stadium floor: one slab through the middle plus a half-disc at each end.
	-- Built as three parts because Roblox has no stadium primitive; the caps
	-- are full cylinders whose inner halves are buried in the slab, which
	-- costs nothing and avoids a wedge/union that would need to be authored
	-- rather than generated. All three are named HubFloor* so a raycast
	-- anywhere on the pavement reports the same thing.
	local straightAxis = computeStraightAxis()
	local floorCFrame = CFrame.lookAt(hubCFrame.Position, hubCFrame.Position + straightAxis)

	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Material = Enum.Material.Grass
	floor.Color = HUB_FLOOR_COLOR
	-- Local Z runs along the straights (floorCFrame looks down straightAxis).
	floor.Size = Vector3.new(HUB_RADIUS * 2, HUB_FLOOR_THICKNESS, HUB_STRAIGHT_HALF_LENGTH * 2)
	floor.CFrame = floorCFrame
	floor.Name = "HubFloor"
	floor.Parent = hubModel

	for _, endSign in { -1, 1 } do
		local cap = Instance.new("Part")
		cap.Anchored = true
		cap.Shape = Enum.PartType.Cylinder
		cap.Material = Enum.Material.Grass
		cap.Color = HUB_FLOOR_COLOR
		cap.Size = Vector3.new(HUB_FLOOR_THICKNESS, HUB_RADIUS * 2, HUB_RADIUS * 2)
		-- Cylinder's default axis is local X; rotate so it lies flat (axis up
		-- Y), then push it out to the end of the slab — the same point the
		-- oval's own end semicircle is centred on.
		cap.CFrame = floorCFrame
			* CFrame.new(0, 0, endSign * HUB_STRAIGHT_HALF_LENGTH)
			* CFrame.Angles(0, 0, math.rad(90))
		cap.Name = "HubFloorEnd"
		cap.Parent = hubModel
	end

	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Anchored = true
	spawnPad.Neutral = true
	spawnPad.Size = SPAWN_PAD_SIZE
	spawnPad.CFrame = hubCFrame * CFrame.new(0, HUB_FLOOR_THICKNESS / 2 + SPAWN_PAD_SIZE.Y / 2, 0)
	spawnPad.Name = "HubSpawn"
	spawnPad.Parent = hubModel

	hubModel.PrimaryPart = spawnPad
	hubModel.Parent = parent

	disableOtherSpawnLocations(spawnPad)

	return hubModel
end

function HubGenerator.Init()
	HubGenerator.GenerateHub(workspace)
end

return HubGenerator

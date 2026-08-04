--!strict
--[[
	TerrainGroundBuilder
	Real Terrain ground under and around the whole map, so the stadium
	visibly SITS on land instead of floating.

	Why this exists: the only ground this place ever had was Studio's default
	Baseplate Part, and TrackGenerator has to keep that thing far below the
	track (see BASEPLATE_SAFETY_Y) or it silently plugs every hazard that
	needs a real gap at ground level — WaterDock/IceFrost pools, SkyRail's
	bridge gaps. That left the entire built world (Y ~ 0..23: road top +1,
	barriers +10, fan-box stands +23) hovering ~47 studs above the only solid
	surface in the game, with nothing in between — measured live by raycasting
	straight down off the track and hitting Workspace.Baseplate at Y = -47.
	That gap IS the "map is above ground" bug; shrinking it (the earlier
	-150 -> -55 pass) made it smaller, not absent.

	The fix is to stop asking one Part to be both "the visible ground" and
	"the void safety net" — those are contradictory jobs. Terrain takes over
	the visible-ground job:

	- GROUND_SURFACE_Y is 0, i.e. 1 stud BELOW the road's top face (the road
	  slab spans -1..+1). So the ground tucks under the road rather than
	  poking through it, and the track reads as a roadbed laid slightly proud
	  of the surrounding land.
	- Terrain water and Terrain ground are the same system, so WaterDock/
	  IceFrost's pools now carve a real pond into this ground instead of
	  hanging in mid-air: they're 8 studs deep from Y = 0, so the water
	  surface lands exactly flush with the grass. (They did have to start
	  clearing their own volume to Air first — water cannot displace solid
	  terrain; see ThemeHazardBuilder.fillWaterBlock.)
	- Hazards that genuinely need a void (SkyRail) call CarveChasm to cut one
	  back out, all the way down past TrackBoundaryMonitor's
	  FALL_OUT_Y_THRESHOLD, so falling through a bridge gap still costs a
	  life instead of landing softly on new grass.

	Rebuild() also replaces ThemeHazardBuilder.ClearAllTerrainWater(): one
	FillBlock over the whole managed region resets material AND occupancy for
	every voxel in it, which wipes the previous generation's water and
	chasms in the same pass that lays the fresh ground. Measured live at
	~0.03s for this region, so running it on every Regenerate() is free.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

-- Where the ground's VISIBLE surface should land. Deliberately 0, not -1:
-- the road slab occupies -1..+1, so a surface at 0 sits inside the road's own
-- thickness (invisible under it) while still leaving the road standing 1 stud
-- proud at its edges — a roadbed laid on the land, not a slab hovering over it.
local GROUND_SURFACE_Y = 0

-- Terrain does NOT render a SOLID material's surface at the top face you hand
-- FillBlock: occupancy smoothing puts the visible/collidable surface half a
-- voxel (2 studs) higher. Measured live across fill tops 0/-1/-2/-3/-4/-6,
-- which rendered at 2.00/1.00/0.02/-0.98/-2.00/-3.98 — an exact, constant +2.
-- Without correcting for it the ground came out at Y = 2, i.e. 1 stud OVER
-- the road's top face, burying the track edge in grass.
--
-- WATER is the exception and must NOT subtract this: it renders exactly at
-- its own fill top (a water fill topped at Y = 0 measured 0.00 against
-- adjacent grass at 0.02 — already flush). That's why ThemeHazardBuilder's
-- pools pass their intended volume straight through untouched.
local SURFACE_RENDER_OFFSET = 2
-- Bottom of the ground slab. Sits 1 stud below the relocated Baseplate's top
-- face (TrackGenerator.BASEPLATE_SAFETY_Y = -55, so top = -47), so a carved
-- chasm bottoms out on the Baseplate rather than on nothing — and there's no
-- second void hiding between the two.
local GROUND_BOTTOM_Y = -48
-- How far the ground extends past the outermost track centerline sample.
-- Fan-box stands sit ~66 studs outside the barriers, so this leaves ~250
-- studs of visible land beyond them in every direction.
local GROUND_MARGIN_STUDS = 320
-- Ground, not Grass: Roblox's Grass material renders 3D grass blades that
-- read as an open field rather than a stadium apron, which is what "remove
-- grass" was asking for. Purely a material swap — surface height, footprint
-- and every hazard interaction below are unaffected.
local GROUND_MATERIAL = Enum.Material.Ground

local TerrainGroundBuilder = {}

TerrainGroundBuilder.GroundSurfaceY = GROUND_SURFACE_Y
TerrainGroundBuilder.GroundBottomY = GROUND_BOTTOM_Y

-- Walks the same fixed segment chain TrackGenerator builds from (segment
-- POSITIONS are deterministic — only which theme lands where is randomized)
-- and returns the axis-aligned XZ bounds of the oval's centerline, padded by
-- GROUND_MARGIN_STUDS.
local function paddedOvalBoundsXZ() : (Vector2, Vector2)
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local samples: { CFrame }
		local exitCFrame: CFrame

		if segment.SegmentType == "Straight" then
			samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, 2)
		else
			samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, TrackGeometry.CurveSubdivisions)
		end

		for _, sampleCFrame in samples do
			local position = sampleCFrame.Position
			minX = math.min(minX, position.X)
			maxX = math.max(maxX, position.X)
			minZ = math.min(minZ, position.Z)
			maxZ = math.max(maxZ, position.Z)
		end

		currentCFrame = exitCFrame
	end

	return Vector2.new(minX - GROUND_MARGIN_STUDS, minZ - GROUND_MARGIN_STUDS),
		Vector2.new(maxX + GROUND_MARGIN_STUDS, maxZ + GROUND_MARGIN_STUDS)
end

-- The volume actually handed to FillBlock, as (centerCFrame, size). Its top
-- face is SURFACE_RENDER_OFFSET BELOW GROUND_SURFACE_Y so the rendered
-- surface lands on GROUND_SURFACE_Y — see that constant's note.
--
-- Exposed rather than kept private because TrackGenerator sizes the legacy
-- Baseplate to this same XZ footprint (so no bare Baseplate ledge is left
-- sticking out past the grass) and shouldn't have to re-derive the numbers.
function TerrainGroundBuilder.GetGroundVolume() : (CFrame, Vector3)
	local minXZ, maxXZ = paddedOvalBoundsXZ()
	local fillTopY = GROUND_SURFACE_Y - SURFACE_RENDER_OFFSET
	local center = CFrame.new(
		(minXZ.X + maxXZ.X) / 2,
		(fillTopY + GROUND_BOTTOM_Y) / 2,
		(minXZ.Y + maxXZ.Y) / 2
	)
	local size = Vector3.new(
		maxXZ.X - minXZ.X,
		fillTopY - GROUND_BOTTOM_Y,
		maxXZ.Y - minXZ.Y
	)
	return center, size
end

-- Lays (or re-lays) the ground. Called at the top of every
-- TrackGenerator.GenerateOval, before any piece or hazard is built, so the
-- water/chasm carving those hazards do lands on a clean slate — see the
-- module docstring on why this also obsoletes a separate water-clearing pass.
function TerrainGroundBuilder.Rebuild()
	local centerCFrame, size = TerrainGroundBuilder.GetGroundVolume()
	workspace.Terrain:FillBlock(centerCFrame, size, GROUND_MATERIAL)
end

-- Cuts a full-depth hole through the ground under `centerCFrame`'s footprint
-- — for hazards whose whole point is that you fall (SkyRail's bridge gaps).
-- Goes all the way to GROUND_BOTTOM_Y so the drop clears
-- TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD (-40) and the violation fires
-- before the player reaches anything solid.
--
-- `centerCFrame` is a segment-aligned CFrame at road level; `width`/`length`
-- are its local X/Z extents. FillBlock honors the rotation, so a chasm under
-- a rotated segment stays aligned with that segment rather than the world
-- axes.
-- Carved from GROUND_SURFACE_Y (not the lower fill top) straight down to
-- GROUND_BOTTOM_Y: clearing Air above where any ground exists is a harmless
-- no-op, and starting at the rendered surface guarantees nothing is left
-- behind at the lip of the hole.
function TerrainGroundBuilder.CarveChasm(centerCFrame: CFrame, width: number, length: number)
	local depth = GROUND_SURFACE_Y - GROUND_BOTTOM_Y
	local chasmCenter = centerCFrame * CFrame.new(0, GROUND_SURFACE_Y - depth / 2 - centerCFrame.Position.Y, 0)
	workspace.Terrain:FillBlock(chasmCenter, Vector3.new(width, depth, length), Enum.Material.Air)
end

return TerrainGroundBuilder

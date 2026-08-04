--!strict
--[[
	ThemeHazardBuilder
	New module — one real hazard/obstacle builder per TrackThemes entry,
	replacing the old "2 random segments get a generic orange spinning bar"
	system. TrackGenerator now calls HAZARD_BUILDERS[theme.Id] for EVERY
	segment, so every theme's own signature hazard actually shows up
	wherever that theme lands.

	Two mechanics are deliberately built on Roblox's own built-in state
	machine instead of new plumbing, so MovementModifier's existing
	Swimming/Climbing branch (built earlier this session) picks them up
	for free:
	- Climbing walls are real TrussPart geometry (Roblox's default
	  character controller auto-enters Humanoid.Climbing on contact).
	- Water is real Terrain (workspace.Terrain:FillBlock(..., Water)) —
	  Roblox auto-enters Humanoid.Swimming in real terrain water.

	"Phaseable" walls reuse CollisionTags.MarkPhaseable (built this session
	for PhaseSelf) exactly like the original Classic hazard bar already
	did. "Costs a life" zones (Volcanic magma, NeonCircuit's landed
	blocks) reuse ZoneHazardMonitor, which itself reuses
	ArcadeManager.HandleTrackViolation — the same life-loss/respawn path
	TrackBoundaryMonitor already drives for off-track violations.

	Terrain is a single global instance, not scoped per Track folder, so
	anything poured into it has to be reset when TrackGenerator.Regenerate()
	rebuilds the oval — otherwise a previous generation's water survives at
	a segment that just landed on a different, non-water theme. That reset
	is no longer this module's job: TerrainGroundBuilder.Rebuild() lays
	fresh ground over the whole map footprint at the top of every
	GenerateOval, and a FillBlock rewrites material AND occupancy for every
	voxel it covers — so stale water and stale chasms get wiped by the same
	pass that lays the ground. (This module used to own a
	ClearAllTerrainWater() that filled Air at each straight segment's
	position; it was removed as redundant once real ground existed, since
	"clear to Air" and "lay ground" can't both be the last word on the same
	voxels.)

	Two hazards now write INTO that ground rather than hanging above it:
	WaterDock/IceFrost's fillWaterBlock carves a real pond (their 8-stud
	pools start at Y = 0, which is exactly the ground surface, so the water
	lands flush with the surrounding land), and SkyRail carves a full-depth
	chasm back out of the ground under its bridge gaps — without that, the
	new ground would catch a player falling through a gap a few studs down
	and quietly delete the entire mechanic.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local CollisionTags = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("CollisionTags"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))
local ZoneHazardMonitor = require(script.Parent:WaitForChild("ZoneHazardMonitor"))
local SoundDirector = require(script.Parent:WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent:WaitForChild("VisualEffectsService"))
local TerrainGroundBuilder = require(script.Parent:WaitForChild("TerrainGroundBuilder"))

local ThemeHazardBuilder = {}

-- ===== Shared helpers =====

local function midpoint(entryCFrame: CFrame, exitCFrame: CFrame) : CFrame
	return entryCFrame:Lerp(exitCFrame, 0.5)
end

-- How wide a hazard that is meant to span the WHOLE road should actually be.
-- One stud short of each barrier's inner face (the road is SegmentWidth wide
-- and the barriers stand on its outer edges), which is the only span that
-- satisfies both halves of the requirement:
--   * No walkable gap. A character's collision hull is ~4 studs across and its
--     HumanoidRootPart alone is 2, so a 1-stud strip is not a lane — there is
--     no "hug the barrier and walk past" line.
--   * No interpenetration. The sweeper rank used to be SegmentWidth +
--     BarrierThickness = 75 studs, i.e. 1.5 studs INTO each anchored barrier,
--     permanently. An unanchored part held by a rigid AlignPosition sitting
--     inside an anchored one is a standing contact the solver has to resolve
--     every step, and it is the most likely source of the yaw/position drift
--     these bars have been repeatedly patched for.
local HAZARD_SPAN_WIDTH = TrackGeometry.SegmentWidth - 2

-- Widest lateral gap a hazard may leave and still count as blocking the road.
-- A character's HumanoidRootPart is 2 studs across before any limbs, so a lane
-- narrower than this is not a lane. Used by the checks below, which exist
-- because every "you can just run around it" bug found in this module so far
-- was invisible in the config: the numbers looked reasonable individually and
-- only the arithmetic between them was wrong.
local MAX_PASSABLE_GAP = 2

assert(
	TrackGeometry.HazardBarLength <= HAZARD_SPAN_WIDTH,
	`ThemeHazardBuilder: TrackGeometry.HazardBarLength is {TrackGeometry.HazardBarLength} but the road only has `
		.. `{HAZARD_SPAN_WIDTH} studs of hazard span — a longer bar sweeps into the anchored barriers`
)
assert(
	TrackGeometry.SegmentWidth - TrackGeometry.HazardBarLength <= MAX_PASSABLE_GAP * 2,
	`ThemeHazardBuilder: a {TrackGeometry.HazardBarLength}-stud spinning bar on a {TrackGeometry.SegmentWidth}-stud `
		.. `road leaves a {(TrackGeometry.SegmentWidth - TrackGeometry.HazardBarLength) / 2}-stud lane against each `
		.. `barrier that the bar can never reach — the hazard is walked around for free`
)

-- Server-pins an unanchored hazard's physics.
--
-- Roblox hands network ownership of an unanchored part to whichever player is
-- nearest, automatically, the moment one gets close. For a hazard that is
-- driven from the server every Heartbeat that is not a small problem: writes to
-- AssemblyAngularVelocity on a CLIENT-owned assembly are discarded, so
-- createSpinningBar's spin — the entire mechanic — quietly stops being
-- server-authoritative exactly when a racer is near enough for it to matter,
-- and the client is then the one deciding whether the bar hits them. Same
-- reasoning for the falling blocks, which cost a life based on where the server
-- thinks they landed.
--
-- Pieces are built into the Track folder BEFORE TrackGenerator parents that
-- folder into workspace, and SetNetworkOwner needs the part to actually be in
-- the workspace, so a part built early waits for its ancestry instead of
-- failing silently.
local function pinPhysicsToServer(part: BasePart)
	if part:IsDescendantOf(workspace) then
		part:SetNetworkOwner(nil)
		return
	end

	local connection: RBXScriptConnection
	connection = part.AncestryChanged:Connect(function()
		if part:IsDescendantOf(workspace) then
			connection:Disconnect()
			part:SetNetworkOwner(nil)
		elseif part.Parent == nil then
			connection:Disconnect()
		end
	end)
end

-- True center CFrame of a segment's own paved surface. For a Straight
-- segment the entry/exit Lerp IS the road centerline (straight lines have
-- no curvature), but for a Curve segment that same Lerp instead cuts
-- across the CHORD connecting the two ends of the arc — landing at
-- sagitta = radius * (1 - cos(arcDegrees/2)) off the actual curved road,
-- ~53 studs for this project's 180-stud-radius 90-degree curves. That's
-- nearly 1.5x the road's own 36-stud half-width, so anything positioned
-- via the naive Lerp on a curve floats detached from the visible track
-- entirely, not just slightly off. This was a real, confirmed bug: every
-- curve-segment hazard placed this way (Classic's 2 side-by-side bars,
-- Volcanic's magma pool, NeonCircuit's spawner) landed off the actual
-- paved curve, reading as "hazards not on their segment" / geometry
-- floating disconnected from the track. Sampling the exact same
-- TrackPieceBuilder.SampleCurve the curve's own RoadChord_* parts were
-- built from, and taking its middle chord, guarantees the result sits
-- exactly on one of those real, rendered road pieces.
local function segmentCenter(segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame) : CFrame
	if segment.SegmentType == "Straight" then
		return midpoint(entryCFrame, exitCFrame)
	end

	local chordSamples = TrackPieceBuilder.SampleCurve(entryCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, TrackGeometry.CurveSubdivisions)
	local middleIndex = math.ceil(#chordSamples / 2)
	return chordSamples[middleIndex]
end

-- A spinning hazard bar (Classic's signature hazard) — the same
-- AlignPosition(RigidityEnabled) + Heartbeat-reasserted-spin anti-drift
-- pattern the original addHazardBar used, extracted so both the straight
-- (1 big) and curve (2 small) variants share it.
local function createSpinningBar(parent: Instance, pivotCFrame: CFrame, barLength: number) : BasePart
	local targetAngularVelocity = Vector3.new(0, math.rad(TrackGeometry.HazardSpinDegreesPerSecond), 0)

	local hazard = Instance.new("Part")
	hazard.Anchored = false
	hazard.CanCollide = true
	hazard.Material = Enum.Material.Neon
	hazard.Color = Color3.fromRGB(255, 140, 0)
	hazard.Name = "HazardBar"
	hazard.Size = Vector3.new(barLength, 1, 1)
	hazard.CFrame = pivotCFrame
	CollisionTags.MarkPhaseable(hazard)

	local attachment = Instance.new("Attachment")
	attachment.Parent = hazard

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = pivotCFrame.Position
	alignPosition.MaxForce = 1e6
	alignPosition.Responsiveness = 200
	alignPosition.RigidityEnabled = true
	alignPosition.Parent = hazard

	hazard.AssemblyAngularVelocity = targetAngularVelocity

	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		hazard.AssemblyAngularVelocity = targetAngularVelocity
	end)
	hazard.Destroying:Connect(function()
		heartbeatConnection:Disconnect()
	end)

	hazard.Parent = parent
	pinPhysicsToServer(hazard)
	return hazard
end

-- Volcanic's sweeper bars. Two axes to keep straight, and they are
-- deliberately opposite to each other:
--   ORIENTATION — the bar's long axis lies PERPENDICULAR to the road, i.e.
--     spanning the track width, so it presents a wall you can't step around.
--   TRAVEL      — it slides PARALLEL to the road, up and down the segment.
-- That combination is what makes it read as a sweeper rather than a moving
-- pillar. An earlier pass had these the other way round (bar along the road,
-- sliding sideways), which just produced a rod that drifted next to runners.
--
-- A bar's local X is its length, and a segment CFrame's own X axis is the
-- track's lateral axis, so orientation needs NO rotation at all — the
-- previous CFrame.Angles(0, 90°, 0) was what turned it the wrong way.
--
-- Deliberately NOT lethal and NOT life-costing: a physical obstacle only.
-- Nothing registers it with ZoneHazardMonitor (that registration is what
-- makes the magma pool and the neon blocks cost a life), so contact just
-- shoves you — hence full width but only a stud thick, and low enough to
-- jump.
--
-- Same rigid AlignPosition anti-drift pattern as the spin bars, re-targeted
-- every Heartbeat to a triangle-wave point along the along-track line.
-- `phase` (0..1) offsets where in that cycle this bar starts, so a row of
-- them ripples instead of moving as one slab.
local SWEEPER_HEIGHT = 3.5
-- One end-to-end pass. The sweep span is TrackGeometry.StraightLength * 0.8
-- = 144 studs, so this is the number that actually sets the bar's speed:
-- at 3s it moved 48 studs/s, three times a player's 16 WalkSpeed, which is
-- unreadable and unavoidable rather than difficult (reported from play as
-- "too fast on the lava theme"). At 6s it is 24 studs/s — still faster than
-- a runner, so it does catch you, but slow enough to see coming and time.
local SWEEPER_TRAVEL_SECONDS = 6

local function createSweeperBar(parent: Instance, entryCFrame: CFrame, exitCFrame: CFrame, barLength: number, sweepSpan: number, phase: number) : BasePart
	local centerCFrame = midpoint(entryCFrame, exitCFrame) * CFrame.new(0, SWEEPER_HEIGHT, 0)
	local nearPos = (centerCFrame * CFrame.new(0, 0, -sweepSpan / 2)).Position
	local farPos = (centerCFrame * CFrame.new(0, 0, sweepSpan / 2)).Position

	local hazard = Instance.new("Part")
	hazard.Anchored = false
	hazard.CanCollide = true
	-- Same look as the rotating hazard bars, on purpose: both are "solid
	-- moving thing that shoves you, costs nothing", so they should teach the
	-- player the same lesson rather than looking like two different rules.
	hazard.Material = Enum.Material.Neon
	hazard.Color = Color3.fromRGB(255, 140, 0)
	hazard.Name = "SweeperHazardBar"
	hazard.Size = Vector3.new(barLength, 1, 1)
	hazard.CFrame = centerCFrame * CFrame.new(0, 0, -sweepSpan / 2)
	CollisionTags.MarkPhaseable(hazard)

	local attachment = Instance.new("Attachment")
	attachment.Parent = hazard

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = hazard.Position
	alignPosition.MaxForce = 1e6
	alignPosition.Responsiveness = 60 -- softer than the spin bars' 200: visibly glides rather than snapping
	alignPosition.RigidityEnabled = true
	alignPosition.Parent = hazard

	-- AlignPosition pins where the bar IS, not which way it FACES, and this
	-- bar is unanchored (it has to be, to shove players rather than be walked
	-- through). Without this the yaw drifts: measured 0.94 instead of 1.00 on
	-- the perpendicular-to-road check within seconds of spawning, before any
	-- player had even touched one — and a racer running into a sweeper would
	-- twist it further, eventually leaving a diagonal bar with a gap at the
	-- barrier. Same RigidityEnabled treatment as the position constraint.
	local orientationAttachment = Instance.new("Attachment")
	orientationAttachment.Parent = hazard

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = orientationAttachment
	alignOrientation.CFrame = hazard.CFrame
	alignOrientation.MaxTorque = 1e6
	alignOrientation.Responsiveness = 200
	alignOrientation.RigidityEnabled = true
	alignOrientation.Parent = hazard

	local cycleSeconds = SWEEPER_TRAVEL_SECONDS * 2
	local startClock = os.clock() - phase * cycleSeconds

	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local elapsed = (os.clock() - startClock) % cycleSeconds
		local alpha = if elapsed <= SWEEPER_TRAVEL_SECONDS
			then elapsed / SWEEPER_TRAVEL_SECONDS
			else (cycleSeconds - elapsed) / SWEEPER_TRAVEL_SECONDS
		alignPosition.Position = nearPos:Lerp(farPos, alpha)
	end)
	hazard.Destroying:Connect(function()
		heartbeatConnection:Disconnect()
	end)

	hazard.Parent = parent
	pinPhysicsToServer(hazard)
	return hazard
end

-- A rank of SWEEPER_COUNT bars sharing one segment, evenly spread through the
-- travel cycle so there is always one somewhere along the straight.
local SWEEPER_COUNT = 4

local function createSweeperRank(parent: Instance, entryCFrame: CFrame, exitCFrame: CFrame, sweepSpan: number)
	-- A sweeper with a gap at the edge is just a slalom, so this spans the full
	-- road — but stopping 1 stud short of each barrier rather than reaching 1.5
	-- studs INTO them, which is what it used to do. See HAZARD_SPAN_WIDTH.
	local barLength = HAZARD_SPAN_WIDTH

	for i = 1, SWEEPER_COUNT do
		createSweeperBar(parent, entryCFrame, exitCFrame, barLength, sweepSpan, (i - 1) / SWEEPER_COUNT)
	end
end

-- A real TrussPart climbing wall — Roblox's default character controller
-- auto-enters Humanoid.Climbing on contact, no custom state code needed.
-- `baseCFrame` is at ground/road level; the wall extends upward from
-- there. `phaseable` controls whether PhaseSelf can pass through it.
--
-- TrussPart hard-clamps its X/Y Size components to 2 studs regardless of
-- what's set (confirmed live) — only its local Z axis is freely sizable.
-- A single truss can't span both "tall" and "wide," so a "wall" is really
-- a row of thin (2x2 cross-section) vertical poles spanning the intended
-- width, each individually rotated 90° about X so its long (Z) axis
-- points along world Y (confirmed live via LookVector) instead of running
-- horizontally like a fresh TrussPart's local Z does by default.
local function createClimbWall(parent: Instance, baseCFrame: CFrame, height: number, phaseable: boolean, wallWidthOverride: number?) : BasePart
	-- Defaults to the FULL track width (plus a stud of overlap into each
	-- barrier) so there is genuinely no way around it and the player has to
	-- climb or jump — a wall covering only part of the width is just a
	-- cosmetic detour everyone runs past. IceFrost is the one caller that
	-- overrides this, because its wall shares the segment 50/50 with a water
	-- lane and the water is the alternative route.
	local wallWidth = wallWidthOverride or (TrackGeometry.SegmentWidth + TrackGeometry.BarrierThickness * 2)
	-- Poles are a 2x2 cross-section (TrussPart's X/Y are clamped to 2 studs
	-- regardless of what's set — see module history). Spacing must be <=
	-- pole width so adjacent poles touch/overlap; otherwise a 2-stud gap
	-- lets a player walk straight through without ever climbing, defeating
	-- "climb only" (confirmed as a real gap live-testing HillMud's wall).
	local poleSpacing = 2
	local poleCount = math.max(1, math.floor(wallWidth / poleSpacing) + 1)

	local firstPole: BasePart? = nil
	for i = 0, poleCount - 1 do
		local offsetX = (i - (poleCount - 1) / 2) * poleSpacing

		local pole = Instance.new("TrussPart")
		pole.Anchored = true
		pole.Size = Vector3.new(2, 2, height)
		pole.CFrame = baseCFrame * CFrame.new(offsetX, height / 2, 0) * CFrame.Angles(math.rad(90), 0, 0)
		pole.Name = "ClimbWall"
		pole.Parent = parent

		if phaseable then
			CollisionTags.MarkPhaseable(pole)
		end

		if firstPole == nil then
			firstPole = pole
		end
	end

	return firstPole :: BasePart
end

-- Small floating platforms up a climb wall's height — an alternate
-- jump-over route instead of climbing the whole thing.
--
-- **The one rule this layout exists to enforce: no platform may ever sit
-- above another one.** Two previous shapes both broke it and both were
-- reported from play as "bouncing" / "blocked by the step above":
--   1. All platforms in a single XZ column — jumping from one hit the
--      underside of the next.
--   2. An alternating ±9 zig-zag (the "fix" for 1). Alternating repeats
--      every 2 steps, so platform 3 landed at the SAME lateral offset as
--      platform 1, with the two only ~3 studs apart in z — and the platform
--      is 8 studs deep, so they overlapped heavily. Platform 1 got a ceiling
--      12 studs over its take-off point: exactly the original bug, just two
--      steps further up the wall. It also asked for an 18-stud lateral hop
--      with a 6-stud rise between consecutive platforms, which no Roblox
--      jump arc can make.
-- The layout is now a MONOTONIC staircase: every step advances the same
-- direction across the wall, so a repeat offset is arithmetically impossible
-- and every platform has open sky above it. Approach distance from the wall
-- is constant for the same reason — varying it was what let the repeated
-- lateral offsets overlap instead of merely lining up.

-- Under Roblox's default ~7-stud jump height, with margin for the fact that
-- the player also has to travel sideways during the same arc.
local JUMP_PLATFORM_MAX_RISE = 5
-- Platforms are JUMP_PLATFORM_SIZE deep/wide, so a 10-stud advance leaves a
-- 2-stud gap between neighbours: visibly separate steps, trivially cleared.
local JUMP_PLATFORM_LATERAL_STEP = 10
local JUMP_PLATFORM_SIZE = 8
-- Clear of the wall itself (truss poles occupy z = -1..1) on the approach
-- side, so the staircase is in front of the wall rather than buried in it.
local JUMP_PLATFORM_APPROACH = 6

local function addJumpPlatforms(parent: Instance, baseCFrame: CFrame, wallHeight: number, phaseable: boolean)
	-- Count derives from the wall's own height so every wall variant (30-stud
	-- straight, 15-stud curve) gets a rise inside the jump arc rather than a
	-- fixed count that happens to work for one of them. Minus one because the
	-- final hop is from the top platform over the wall, not onto a platform.
	local platformCount = math.max(1, math.ceil(wallHeight / JUMP_PLATFORM_MAX_RISE) - 1)
	local rise = wallHeight / (platformCount + 1)

	for i = 1, platformCount do
		local lateralOffset = (i - (platformCount + 1) / 2) * JUMP_PLATFORM_LATERAL_STEP

		local platform = Instance.new("Part")
		platform.Anchored = true
		platform.CanCollide = true
		platform.Material = Enum.Material.Rock
		platform.Color = Color3.fromRGB(110, 80, 55)
		platform.Size = Vector3.new(JUMP_PLATFORM_SIZE, 1, JUMP_PLATFORM_SIZE)
		platform.CFrame = baseCFrame * CFrame.new(lateralOffset, rise * i, JUMP_PLATFORM_APPROACH)
		platform.Name = "JumpPlatform"
		if phaseable then
			CollisionTags.MarkPhaseable(platform)
		end
		platform.Parent = parent
	end
end

-- Pours a pool. The Air pass is NOT redundant: Roblox stores water as a
-- separate per-voxel channel from solid material, and a voxel already fully
-- occupied by solid terrain has no room left for it — so FillBlock(..., Water)
-- into solid ground is silently a complete no-op, leaving the ground exactly
-- as it was. Confirmed live the moment TerrainGroundBuilder started laying
-- real ground under the map: every WaterDock/IceFrost pool disappeared,
-- reading as untouched grass, because the water was being poured into solid
-- grass instead of into the empty air it used to have to itself. Clearing
-- the pool's own volume to Air first carves the basin (the surrounding
-- grass becomes its walls, and the grass left below becomes its floor), and
-- the water then has somewhere to go.
--
-- No vertical correction here, deliberately, even though
-- TerrainGroundBuilder's solid ground needs one: water renders its surface
-- exactly at the fill's top face, while solid material renders half a voxel
-- (2 studs) above it. Measured side by side — a water fill topped at Y = 0
-- renders at 0.00 against adjacent grass rendering at 0.02, i.e. already
-- flush. Callers pass the pool they actually want and get it.
-- A platform that slides back and forth between two points and CARRIES the
-- player standing on it. `travelOffset` is half the journey, in the
-- platform's own local space, so Vector3.new(0, 6, 0) oscillates 12 studs
-- vertically and Vector3.new(14, 0, 0) oscillates 28 studs laterally.
-- `phase` (0..1) offsets where in the cycle this one starts.
--
-- Unanchored + AlignPosition rather than an anchored part re-CFramed every
-- frame: teleporting an anchored part doesn't transfer any motion to a
-- character standing on it, so the player just slides off (or the platform
-- passes through them). A real constraint moves the part through the physics
-- solver, so normal friction carries the rider. AlignOrientation is here for
-- the same reason the sweeper bars needed it — position constraints don't
-- pin facing, and a stepped-on platform will otherwise tip.
--
-- Deliberately NOT pinned with pinPhysicsToServer, unlike every other
-- unanchored hazard here. This is the one that a player STANDS ON, and letting
-- the rider's own client own it is what keeps the ride smooth instead of
-- stuttering against replicated motion. Nothing is lost by it: this platform is
-- driven purely through a RigidityEnabled AlignPosition whose target the server
-- rewrites every Heartbeat, and constraint properties replicate server -> client,
-- so a client-owned platform still ends up exactly where the server put it.
-- (The spin bars can't rely on that, because their motion is
-- AssemblyAngularVelocity, which a client-owned assembly ignores.)
local function createMovingPlatform(parent: Instance, baseCFrame: CFrame, size: Vector3, travelOffset: Vector3, travelSeconds: number, phase: number) : BasePart
	local nearCFrame = baseCFrame * CFrame.new(-travelOffset)
	local farPosition = (baseCFrame * CFrame.new(travelOffset)).Position

	local platform = Instance.new("Part")
	platform.Anchored = false
	platform.CanCollide = true
	platform.Material = Enum.Material.Metal
	platform.Color = Color3.fromRGB(210, 190, 90)
	platform.Name = "SkyRailMovingPlatform"
	platform.Size = size
	platform.CFrame = nearCFrame
	CollisionTags.MarkMovingPlatform(platform)

	local attachment = Instance.new("Attachment")
	attachment.Parent = platform

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = nearCFrame.Position
	alignPosition.MaxForce = 1e8 -- has to hold a rider's weight too, not just its own
	alignPosition.Responsiveness = 200
	alignPosition.RigidityEnabled = true
	alignPosition.Parent = platform

	local orientationAttachment = Instance.new("Attachment")
	orientationAttachment.Parent = platform

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = orientationAttachment
	alignOrientation.CFrame = nearCFrame
	alignOrientation.MaxTorque = 1e8
	alignOrientation.Responsiveness = 200
	alignOrientation.RigidityEnabled = true
	alignOrientation.Parent = platform

	local cycleSeconds = travelSeconds * 2
	local startClock = os.clock() - phase * cycleSeconds
	local nearPosition = nearCFrame.Position

	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local elapsed = (os.clock() - startClock) % cycleSeconds
		local alpha = if elapsed <= travelSeconds
			then elapsed / travelSeconds
			else (cycleSeconds - elapsed) / travelSeconds
		alignPosition.Position = nearPosition:Lerp(farPosition, alpha)
	end)
	platform.Destroying:Connect(function()
		heartbeatConnection:Disconnect()
	end)

	platform.Parent = parent
	return platform
end

local function fillWaterBlock(centerCFrame: CFrame, size: Vector3)
	workspace.Terrain:FillBlock(centerCFrame, size, Enum.Material.Air)
	workspace.Terrain:FillBlock(centerCFrame, size, Enum.Material.Water)
end

-- Destroys the segment's cloned "Road" Part and returns its Color/Material/
-- thickness/width so callers can rebuild solid strips around a hole. Needed
-- because Terrain water and the Road Part are two independent systems — a
-- water pool poured underneath a still-intact full-segment Road slab is
-- invisible to players, who just keep walking on the solid Road above it
-- and never touch the water (confirmed live: teleporting into a WaterDock
-- pool's XZ footprint landed the player standing on Road at road-surface
-- height, terrain read Air, not Water, at that exact spot). Every water
-- theme must remove the Road under the water's footprint and rebuild only
-- the dry parts as separate strips, the same way buildSkyRail already
-- destroys+replaces Road for its gaps.
local function destroyRoadForRebuild(pieceModel: Model) : (Color3, Enum.Material, number, number)
	local existingRoad = pieceModel:FindFirstChild("Road") :: BasePart?
	local roadColor = if existingRoad ~= nil then existingRoad.Color else Color3.fromRGB(150, 150, 150)
	local roadMaterial = if existingRoad ~= nil then existingRoad.Material else Enum.Material.Concrete
	local roadWidth = if existingRoad ~= nil then existingRoad.Size.X else TrackGeometry.SegmentWidth
	local roadThickness = if existingRoad ~= nil then existingRoad.Size.Y else TrackGeometry.RoadThickness
	if existingRoad ~= nil then
		existingRoad:Destroy()
	end
	return roadColor, roadMaterial, roadWidth, roadThickness
end

-- Adds one solid Road strip spanning forward-distance [startZ, endZ] from
-- entryCFrame (same convention as TrackPieceBuilder.SampleStraight:
-- entryCFrame * CFrame.new(0, 0, -distance)), `width` studs wide, laterally
-- centered at `offsetX`. No-ops for a degenerate (<=0) span.
local function addRoadStrip(pieceModel: Model, entryCFrame: CFrame, roadColor: Color3, roadMaterial: Enum.Material, roadThickness: number, width: number, offsetX: number, startZ: number, endZ: number)
	local length = endZ - startZ
	if length <= 0.01 or width <= 0.01 then
		return
	end

	local strip = Instance.new("Part")
	strip.Anchored = true
	strip.CanCollide = true
	strip.Material = roadMaterial
	strip.Color = roadColor
	strip.Size = Vector3.new(width, roadThickness, length)
	strip.CFrame = entryCFrame * CFrame.new(offsetX, 0, -(startZ + endZ) / 2)
	strip.Name = "Road"
	strip.Parent = pieceModel
end

-- ===== Curve road surgery =====
--
-- A Curve piece's floor isn't one slab like a Straight's — it's
-- TrackGeometry.CurveSubdivisions separate `RoadChord_N` parts, each one a
-- short straight chord approximating the arc (see TrackPieceBuilder.
-- BuildCurve). That's why themes that cut a hole in the floor
-- (WaterDock/IceFrost/SkyRail) originally just skipped curves entirely and
-- left them bare: `destroyRoadForRebuild` looks for a single "Road" child and
-- finds nothing. Removing the two MIDDLE chords gives a hole in the middle of
-- the arc without disturbing the entry/exit ends where the piece joins its
-- neighbours.
local CURVE_MIDDLE_CHORD_INDICES = { 4, 5 }

-- Extra length to give any Terrain fill that follows a curve chord (a pond, a
-- chasm), on top of the chord's own length.
--
-- A curve's floor is a POLYGON inscribed in the arc, so two adjacent chords meet
-- at a vertex on the centreline with their end faces CurveArcDegrees/
-- CurveSubdivisions apart — 11.25 degrees here. Filling each chord's exact length
-- therefore leaves an uncarved wedge at every junction, zero-width on the
-- centreline and fanning out to ~7 studs long at the road's outer edge (the
-- chords converge on the inside of the turn and diverge on the outside). That
-- wedge is not cosmetic: in WaterDock's curve pond it is a DRY RIDGE across the
-- water on the outside line — walkable, and precisely where a player avoiding
-- the swim would already be running — and in SkyRail's curve chasm it is a nub
-- of solid ground jutting out from under the ledge.
--
-- Overlapping the fills closes the wedge out past the road's own edge. It also
-- fills a few studs under the NEIGHBOURING chords' road slabs, which changes
-- nothing anyone can see or stand on: those slabs are anchored Parts and are not
-- touched by a Terrain fill.
local CURVE_CHORD_FILL_OVERLAP = 8

do
	local wedgeAtRoadEdge = (TrackGeometry.SegmentWidth / 2)
		* math.rad(TrackGeometry.CurveArcDegrees / TrackGeometry.CurveSubdivisions)
	assert(
		CURVE_CHORD_FILL_OVERLAP >= wedgeAtRoadEdge,
		`ThemeHazardBuilder: CURVE_CHORD_FILL_OVERLAP is {CURVE_CHORD_FILL_OVERLAP} but adjacent curve chords fan `
			.. `{string.format("%.1f", wedgeAtRoadEdge)} studs apart at the road's edge — curve ponds and chasms will `
			.. `be left with a solid ridge across them at every chord junction`
	)
end

local function curveChordLength() : number
	local anglePerStepRad = math.rad(TrackGeometry.CurveArcDegrees / TrackGeometry.CurveSubdivisions)
	return 2 * TrackGeometry.CurveRadius * math.sin(anglePerStepRad / 2)
end

-- Destroys the middle chords and hands back their CFrames (sampled from the
-- exact same SampleCurve call the chords were built from, so anything placed
-- at them lands precisely in the hole) plus the road's own appearance, for
-- callers that want to rebuild part of it.
local function removeMiddleCurveChords(pieceModel: Model, entryCFrame: CFrame) : ({ CFrame }, number, Color3, Enum.Material, number)
	local samples = TrackPieceBuilder.SampleCurve(entryCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, TrackGeometry.CurveSubdivisions)

	local removedCFrames: { CFrame } = {}
	local roadColor = Color3.fromRGB(150, 150, 150)
	local roadMaterial = Enum.Material.Concrete
	local roadThickness = TrackGeometry.RoadThickness

	for _, chordIndex in CURVE_MIDDLE_CHORD_INDICES do
		local chord = pieceModel:FindFirstChild(`RoadChord_{chordIndex}`)
		if chord ~= nil and chord:IsA("BasePart") then
			roadColor, roadMaterial, roadThickness = chord.Color, chord.Material, chord.Size.Y
			chord:Destroy()
		end
		if samples[chordIndex] ~= nil then
			table.insert(removedCFrames, samples[chordIndex])
		end
	end

	return removedCFrames, curveChordLength(), roadColor, roadMaterial, roadThickness
end

-- Curve equivalent of addRoadStrip: rebuilds part of a removed chord,
-- `width` studs wide and offset `offsetX` from the chord's centreline. Takes
-- the chord's own CFrame rather than a start/end distance, since a curve has
-- no single forward axis to measure along.
local function addCurveRoadStrip(pieceModel: Model, chordCFrame: CFrame, roadColor: Color3, roadMaterial: Enum.Material, roadThickness: number, width: number, offsetX: number, chordLength: number)
	local strip = Instance.new("Part")
	strip.Anchored = true
	strip.CanCollide = true
	strip.Material = roadMaterial
	strip.Color = roadColor
	strip.Size = Vector3.new(width, roadThickness, chordLength)
	strip.CFrame = chordCFrame * CFrame.new(offsetX, 0, 0)
	strip.Name = "RoadChord_Rebuilt"
	strip.Parent = pieceModel
end

-- Volcanic's magma pool — a life-costing ZoneHazardMonitor zone, not a
-- physical wall (players cross the road normally elsewhere; the pool
-- itself is the hazard).
-- Tall enough that a normally-standing player's HumanoidRootPart (which
-- sits several studs above their feet, not at ground level) still falls
-- inside the zone's Y half-size — the thin decorative pool part alone
-- (4 studs tall, right at road height) sat entirely below a standing
-- player's rootpart height and never actually caught anyone walking
-- across it (confirmed live: lives stayed unchanged standing directly in
-- the pool's footprint). Same generous-height fix TrackGenerator's own
-- checkpoint triggers already use (CHECKPOINT_TRIGGER_HEIGHT).
local MAGMA_ZONE_HEIGHT = 40
-- Lava has to GLOW to read as lava. Recolouring alone wasn't enough (it was
-- tried, and still "looks the same as ground"): CrackedLava is a matte,
-- heavily-textured material, so a flush patch of it is just differently
-- coloured dirt at a glance — and being flush with the road, the very fix
-- that made it play correctly is what removed the last silhouette cue that
-- it was anything at all.
--
-- Neon is the answer, and specifically the same Neon the skill pickups use:
-- it ignores scene lighting and renders at full emissive brightness, so the
-- patch reads as hot from any angle and at any distance. Same reason
-- SkillPickupSpawner's markers and the hazard bars are Neon.
local MAGMA_MATERIAL = Enum.Material.Neon
local MAGMA_COLOR = Color3.fromRGB(255, 30, 12)
-- Sunk FLUSH so its top face is level with the road surface — a pool in the
-- ground, which is what makes "go around it" a real decision rather than
-- "walk up onto it".
local MAGMA_POOL_THICKNESS = 1.5

-- One pool. Callers place several of these rather than a single big one.
local function createMagmaPatch(parent: Instance, centerCFrame: CFrame, patchWidth: number, patchLength: number)
	local pool = Instance.new("Part")
	pool.Anchored = true
	pool.CanCollide = false
	pool.Material = MAGMA_MATERIAL
	pool.Color = MAGMA_COLOR
	pool.Name = "MagmaPool"
	pool.Size = Vector3.new(patchWidth, MAGMA_POOL_THICKNESS, patchLength)
	-- Top face flush with the road's top face (road spans -1..+1 about the
	-- segment CFrame), so nothing to step up onto.
	pool.CFrame = centerCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 - MAGMA_POOL_THICKNESS / 2, 0)
	pool.Parent = parent

	-- The life-costing volume is a separate, much taller invisible part: a
	-- standing player's HumanoidRootPart sits several studs above their feet,
	-- so a zone only as tall as the visible pool never actually contains
	-- anyone walking through it (confirmed live in an earlier round).
	local zone = Instance.new("Part")
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanQuery = false
	zone.Transparency = 1
	zone.Name = "MagmaZone"
	zone.Size = Vector3.new(patchWidth, MAGMA_ZONE_HEIGHT, patchLength)
	zone.CFrame = centerCFrame * CFrame.new(0, MAGMA_ZONE_HEIGHT / 2 - TrackGeometry.RoadThickness / 2, 0)
	zone.Parent = parent
	ZoneHazardMonitor.RegisterZone(zone)
end

-- Several staggered patches instead of one slab spanning the segment. A
-- single big pool has exactly one answer (hug whichever side is clear);
-- alternating patches down the segment force repeated direction changes or
-- jumps, which is what makes the theme play differently from a plain road.
--
-- ===== Why the widths and offsets are checked against each other =====
--
-- "Alternating patches force direction changes" is only true if no single
-- lateral line clears EVERY patch. The previous numbers (0.42 width, offsets
-- peaking at +/-0.28/-0.26) did not manage that: a patch reached x = 35.3 on the
-- + side but only -33.8 on the -, so running the left-hand barrier crossed the
-- whole segment untouched — and a CURVE, which uses only the first three
-- offsets, had a free lane on BOTH sides. Since magma is the one hazard that is
-- supposed to be dodgeable, a permanent free lane doesn't make it easier, it
-- deletes it: there is no decision left to make.
--
-- The fix is not simply "make the patches huge" — that swings it the other way
-- and demands lateral moves no runner can make between patches. These offsets
-- are picked so that the union of the patches covers the road out to the last
-- stud a player can physically occupy, while consecutive patches never ask for
-- more than ~7 studs of sideways travel. The assertion below is what keeps both
-- of those true if anyone retunes the width or the list.
local MAGMA_PATCH_WIDTH_FRACTION = 0.46
local MAGMA_PATCH_LATERAL_OFFSETS = { -0.26, 0.27, -0.10, 0.26, -0.27 }
-- A curve gets a shorter field and so consumes only the first few offsets; the
-- coverage check has to hold for that prefix too, not just the whole list.
local MAGMA_CURVE_PATCH_COUNT = 3

-- Furthest a HumanoidRootPart can actually get from the road's centreline: the
-- barrier's inner face, less the rootpart's own half-width. Coverage is checked
-- against this rather than the full half-width, because the last stud of road
-- is geometry no player can stand their centre on.
local REACHABLE_HALF_WIDTH = TrackGeometry.SegmentWidth / 2 - 1

do
	local patchHalfWidth = TrackGeometry.SegmentWidth * MAGMA_PATCH_WIDTH_FRACTION / 2

	-- Both extremes have to be covered by the FIRST MAGMA_CURVE_PATCH_COUNT
	-- offsets (a curve never sees the rest of the list).
	local reachMin, reachMax = math.huge, -math.huge
	for i = 1, MAGMA_CURVE_PATCH_COUNT do
		local offset = MAGMA_PATCH_LATERAL_OFFSETS[i] * TrackGeometry.SegmentWidth
		reachMin = math.min(reachMin, offset - patchHalfWidth)
		reachMax = math.max(reachMax, offset + patchHalfWidth)
	end

	assert(
		reachMin <= -REACHABLE_HALF_WIDTH and reachMax >= REACHABLE_HALF_WIDTH,
		`ThemeHazardBuilder: magma patches only reach x = {string.format("%.1f", reachMin)}..`
			.. `{string.format("%.1f", reachMax)} within the first {MAGMA_CURVE_PATCH_COUNT} offsets, but a player can `
			.. `stand out to +/-{REACHABLE_HALF_WIDTH} — that is a clear lane along the barrier through the whole field`
	)

	-- And no two CONSECUTIVE patches may demand an unreachable sideways move:
	-- the clear side of one has to be within reach of the clear side of the
	-- next. Patch i is clear beyond offset_i + halfWidth (or before offset_i -
	-- halfWidth), so the demand is how far those safe edges are apart.
	for i = 1, #MAGMA_PATCH_LATERAL_OFFSETS - 1 do
		local a = MAGMA_PATCH_LATERAL_OFFSETS[i] * TrackGeometry.SegmentWidth
		local b = MAGMA_PATCH_LATERAL_OFFSETS[i + 1] * TrackGeometry.SegmentWidth
		if (a < 0) ~= (b < 0) then
			local lateralDemand = math.abs((a + patchHalfWidth * math.sign(-a)) - (b + patchHalfWidth * math.sign(-b)))
			assert(
				lateralDemand <= 12,
				`ThemeHazardBuilder: magma patches {i} and {i + 1} are {string.format("%.1f", lateralDemand)} studs `
					.. `apart laterally on their clear sides — more sideways travel than a runner can make in the gap `
					.. `between them, so the field is unavoidable rather than dodgeable`
			)
		end
	end
end

local function createMagmaField(parent: Instance, centerCFrame: CFrame, spanLength: number, patchCount: number)
	local patchWidth = TrackGeometry.SegmentWidth * MAGMA_PATCH_WIDTH_FRACTION
	local patchLength = math.max(10, (spanLength / patchCount) * 0.62)

	for i = 1, patchCount do
		local lengthFraction = (i - 0.5) / patchCount - 0.5
		local lateralOffset = MAGMA_PATCH_LATERAL_OFFSETS[((i - 1) % #MAGMA_PATCH_LATERAL_OFFSETS) + 1]
		createMagmaPatch(
			parent,
			centerCFrame * CFrame.new(lateralOffset * TrackGeometry.SegmentWidth, 0, lengthFraction * spanLength),
			patchWidth,
			patchLength
		)
	end
end

-- ===== Per-theme builders =====

-- Classic: 1 big spinning bar on straights, 2 smaller bars side-by-side on
-- curves.
--
-- ===== Why both variants are derived from HazardBarLength alone =====
--
-- A spinning bar's reach is its HALF-length measured from its own pivot, so the
-- only thing that decides whether the hazard can be walked around is where each
-- pivot sits and how far each bar reaches from it. Both variants used to get
-- that wrong in the same way — by taking one number from TrackGeometry and the
-- other from SegmentWidth, so the two never had to agree:
--
--   * Straight: one 60-stud bar pivoted on the centreline reached x = +/-30 on a
--     road spanning +/-36. A 6-stud lane against each barrier, always clear.
--   * Curve: two 30-stud bars pivoted at +/-SegmentWidth/4 = +/-18 covered [3, 33]
--     and [-33, -3] — a 6-stud clear lane straight down the MIDDLE of the road,
--     which is also the natural racing line, plus 3 studs at each edge.
--
-- Deriving the curve's pivot offset from HazardBarLength/4 (not SegmentWidth/4)
-- makes the pair exactly tile the straight variant's span: each bar reaches
-- HazardBarLength/4 from a pivot HazardBarLength/4 off centre, so one covers
-- [0, span/2] and the other [-span/2, 0]. They meet at the centreline and stop
-- a stud short of the barriers, with no arithmetic left over to leave a gap.
-- The two bars' tips now touch, which is exactly why hazards were made
-- non-collidable with each other in CollisionTags.
local function buildClassic(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)
	local pivotCFrame = center * CFrame.new(0, TrackGeometry.BarrierHeight / 2, 0)

	if segment.SegmentType == "Straight" then
		createSpinningBar(pieceModel, pivotCFrame, TrackGeometry.HazardBarLength)
	else
		local lateralOffset = TrackGeometry.HazardBarLength / 4
		local smallBarLength = TrackGeometry.HazardBarLength / 2
		createSpinningBar(pieceModel, pivotCFrame * CFrame.new(lateralOffset, 0, 0), smallBarLength)
		createSpinningBar(pieceModel, pivotCFrame * CFrame.new(-lateralOffset, 0, 0), smallBarLength)
	end
end

-- HillMud: climbable (phaseable) stony walls + jump-over platforms.
-- Curve: 2 low walls (one per chord end). Straight: 1 high wall, centered.
local function buildHillMud(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType == "Straight" then
		local center = midpoint(entryCFrame, exitCFrame)
		local wallHeight = 30
		createClimbWall(pieceModel, center, wallHeight, true)
		addJumpPlatforms(pieceModel, center, wallHeight, true)
	else
		local wallHeight = 15
		-- Pulled well clear of the segment ends. A curve's entry/exit CFrames
		-- are exactly where TrackGenerator puts the checkpoint triggers, so
		-- building a truss wall on them meant a player respawning at that
		-- checkpoint — or starting a lap there — materialised inside the wall.
		-- Offsetting along the arc keeps the hazard while leaving the
		-- spawn/respawn plane clear.
		local endClearance = 34
		local walls = {
			entryCFrame * CFrame.new(0, 0, -endClearance),
			exitCFrame * CFrame.new(0, 0, endClearance),
		}
		for _, baseCFrame in walls do
			createClimbWall(pieceModel, baseCFrame, wallHeight, true)
			-- No count override any more: the derivation gives a 15-stud wall
			-- 2 platforms at a 5-stud rise. The old single-platform override
			-- put its one step at half the wall height — a 7.5-stud first hop
			-- straight off the ground, right at the edge of what Roblox can
			-- jump, which made the "optional" route a coin flip.
			addJumpPlatforms(pieceModel, baseCFrame, wallHeight, true)
		end
	end
end

-- IceFrost: straight only (spec doesn't mention curve — curves stay a
-- plain reskin). Two parallel lanes, split evenly across the full segment
-- width with no gap between or around them, so there's no dry strip a
-- player could sneak through untouched: left half is real water
-- (Swimming), right half is a NON-phaseable, gapless ice TrussPart wall
-- (Climbing only, "cannot phase through") standing on its own solid road
-- half. The water half's Road is removed (see destroyRoadForRebuild) so
-- players actually fall into the terrain water instead of walking over it.
local function buildIceFrost(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType ~= "Straight" then
		-- Curves used to be left completely bare here (the water/wall split
		-- needs road surgery a Curve's chord floor doesn't support). They get
		-- the theme's other half instead: a gapless, NON-phaseable ice wall at
		-- the middle of the arc. Full width, because the "half water"
		-- exemption from the full-width rule only ever applied to the
		-- straight — there is no water lane on a curve to be the alternative
		-- route, so anything narrower would just be a detour.
		local curveCenter = segmentCenter(segment, entryCFrame, exitCFrame)
		local wallHeight = 22
		createClimbWall(pieceModel, curveCenter, wallHeight, false)
		return
	end

	local center = midpoint(entryCFrame, exitCFrame)
	local waterDepth = 8
	local margin = TrackGeometry.StraightLength * 0.05
	local gapStartZ = margin
	local gapEndZ = TrackGeometry.StraightLength - margin
	local laneLength = gapEndZ - gapStartZ
	local halfWidth = TrackGeometry.SegmentWidth / 2

	local roadColor, roadMaterial, _roadWidth, roadThickness = destroyRoadForRebuild(pieceModel)

	-- Full-width dry margins before/after the split lane, so players land
	-- on solid ground approaching and leaving it.
	addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, TrackGeometry.SegmentWidth, 0, 0, gapStartZ)
	addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, TrackGeometry.SegmentWidth, 0, gapEndZ, TrackGeometry.StraightLength)
	-- Wall-lane half keeps solid road for the wall to stand on; the
	-- water-lane half is left with no Road part at all.
	addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, halfWidth, halfWidth / 2, gapStartZ, gapEndZ)

	fillWaterBlock(
		center * CFrame.new(-halfWidth / 2, -waterDepth / 2, 0),
		Vector3.new(halfWidth, waterDepth, laneLength)
	)

	local wallHeight = 25
	createClimbWall(pieceModel, center * CFrame.new(halfWidth / 2, 0, 0), wallHeight, false, halfWidth)
end

-- Volcanic: magma pool (life-loss zone) on both straight/curve; straight
-- also gets the traveling hazard bar.
local function buildVolcanic(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)

	if segment.SegmentType == "Straight" then
		createMagmaField(pieceModel, center, TrackGeometry.StraightLength * 0.72, 5)
		createSweeperRank(pieceModel, entryCFrame, exitCFrame, TrackGeometry.StraightLength * 0.8)
	else
		-- Curves get a shorter field: the arc is already a handling test, and
		-- the usable racing line through it is narrower to begin with.
		createMagmaField(pieceModel, center, 60, 3)
	end
end

-- Decorative low rim (CanCollide = false) that visually "encloses" a pool
-- without ever risking blocking a player's path across the segment.
local function addPoolRim(parent: Instance, poolCenterCFrame: CFrame, poolWidth: number, poolLength: number)
	local halfLength = poolLength / 2
	for _, offsetZ in { halfLength, -halfLength } do
		local rim = Instance.new("Part")
		rim.Anchored = true
		rim.CanCollide = false
		rim.Material = Enum.Material.WoodPlanks
		rim.Color = Color3.fromRGB(90, 70, 50)
		rim.Size = Vector3.new(poolWidth, 1.5, 1)
		rim.CFrame = poolCenterCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 + 0.75, offsetZ)
		rim.Name = "WaterDockEnclosure"
		rim.Parent = parent
	end
end

-- WaterDock: straight only. Two variants picked at random per segment —
-- (A) a big ¾-length pool forcing a straight swim across, (B) a small
-- ¼-length pool with 2 narrow bridges to cross (or fall in and swim). Both
-- variants cut the Road out full-width under the pool (see
-- destroyRoadForRebuild) so the pool is a real gap players fall into,
-- not terrain water hidden under a still-solid road slab.
local function buildWaterDock(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType ~= "Straight" then
		-- Curves used to be bare. They now get the theme's actual signature
		-- mechanic rather than decoration: removeMiddleCurveChords cuts a real
		-- hole in the middle of the arc, and the same Air-then-Water fill the
		-- straight uses turns it into a pond you have to swim. Full chord
		-- width, so there's no dry lane around it.
		local chordCFrames, chordLength = removeMiddleCurveChords(pieceModel, entryCFrame)
		local poolDepth = 8

		for _, chordCFrame in chordCFrames do
			fillWaterBlock(
				chordCFrame * CFrame.new(0, -poolDepth / 2, 0),
				Vector3.new(TrackGeometry.SegmentWidth, poolDepth, chordLength + CURVE_CHORD_FILL_OVERLAP)
			)
			-- The rim is decoration and stays on the chord's real length; only the
			-- water itself needs the overlap (see CURVE_CHORD_FILL_OVERLAP).
			addPoolRim(pieceModel, chordCFrame, TrackGeometry.SegmentWidth, chordLength)
		end
		return
	end

	local center = midpoint(entryCFrame, exitCFrame)
	-- Full segment width, not 80%: the leftover 10% strip on each side used
	-- to be a dry side road. It wasn't obvious before there was any ground —
	-- back then the strip was open void and nobody walked it — but
	-- TerrainGroundBuilder now puts real, walkable ground at Y = 0 right
	-- there, which turned it into a free bypass around the entire hazard.
	local poolWidth = TrackGeometry.SegmentWidth
	local poolDepth = 8

	local roadColor, roadMaterial, roadWidth, roadThickness = destroyRoadForRebuild(pieceModel)

	local function buildPool(poolLength: number)
		local gapStartZ = TrackGeometry.StraightLength / 2 - poolLength / 2
		local gapEndZ = TrackGeometry.StraightLength / 2 + poolLength / 2
		addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, roadWidth, 0, 0, gapStartZ)
		addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, roadWidth, 0, gapEndZ, TrackGeometry.StraightLength)
		fillWaterBlock(center * CFrame.new(0, -poolDepth / 2, 0), Vector3.new(poolWidth, poolDepth, poolLength))
		addPoolRim(pieceModel, center, poolWidth, poolLength)
	end

	if math.random() < 0.5 then
		-- Variant A: big pool, straight swim across.
		buildPool(TrackGeometry.StraightLength * 0.75)
	else
		-- Variant B: small pool, 2 narrow bridges across it.
		local poolLength = TrackGeometry.StraightLength * 0.25
		buildPool(poolLength)

		-- Narrow, and built as a zig-zag rather than one straight slab: a
		-- straight plank is a free walk, whereas steering a narrow zig-zag is
		-- something anything messing with your controls (ReverseControlTarget,
		-- ScrambleGlobal, a shove) can genuinely dump you off.
		--
		-- ## Why this is built from WAYPOINTS and not from offsets
		--
		-- The previous version placed each plank as an axis-aligned slab at
		-- `laneOffset ± jogAmount`, and claimed in this very comment that "the
		-- planks overlap end-to-end so the path is continuous". They did not.
		-- Measured on a real generation: consecutive planks sat 12 studs apart
		-- laterally while being 4 studs wide, sharing only 2 studs of Z — an
		-- 8-STUD SIDEWAYS GAP over open water, three times per crossing. The
		-- "narrow bridge" was three disconnected stepping stones, which is
		-- exactly the "bridge is not active as a bridge" report.
		--
		-- The failure was that continuity depended on two independent numbers
		-- (the jog and the plank width) happening to agree. Now each plank is
		-- built BETWEEN two shared waypoints and rotated to face along that
		-- span, so consecutive planks meet at a point they both derive from.
		-- Continuity is structural: it cannot be broken by retuning the jog,
		-- the count, or the pool length. The difficulty is the width and the
		-- direction changes, as intended.
		local bridgeWidth = 4
		local plankCount = 3
		local jogAmount = 5
		local plankOverlap = 1.5 -- kills hairline seams at the joints
		local crossingSpan = poolLength + 8
		local deckY = TrackGeometry.RoadThickness / 2 + 0.5

		for _, laneOffset in { -TrackGeometry.SegmentWidth * 0.2, TrackGeometry.SegmentWidth * 0.2 } do
			-- Opposite starting phase per lane, so neither crossing is a
			-- mirror of the other.
			local phase = if laneOffset < 0 then 1 else -1

			local function waypoint(index: number) : Vector3
				local sideways = (if index % 2 == 0 then 1 else -1) * phase * jogAmount
				return Vector3.new(
					laneOffset + sideways,
					deckY,
					-crossingSpan / 2 + crossingSpan * (index / plankCount)
				)
			end

			for plankIndex = 1, plankCount do
				local from, to = waypoint(plankIndex - 1), waypoint(plankIndex)
				local span = to - from
				local mid = from + span / 2

				local bridge = Instance.new("Part")
				bridge.Anchored = true
				bridge.CanCollide = true
				bridge.Material = Enum.Material.WoodPlanks
				bridge.Color = Color3.fromRGB(120, 90, 60)
				bridge.Size = Vector3.new(bridgeWidth, 1, span.Magnitude + plankOverlap)
				-- Rotated to lie ALONG its own span, which is what makes the
				-- two ends land on the shared waypoints.
				bridge.CFrame = center * CFrame.lookAt(mid, mid + span.Unit)
				bridge.Name = "WaterDockBridge"
				bridge.Parent = pieceModel
			end
		end
	end
end

-- SkyRail: straight replaces the solid road with 4 elevated bridge slabs
-- and real gaps between them — falling through is caught for free by
-- TrackBoundaryMonitor's existing fall-out check. Curve keeps its normal
-- solid floor.
--
-- The gaps only work if there's genuinely nothing under them, so this is
-- also the one theme that has to cut a chasm back out of
-- TerrainGroundBuilder's ground: with the ground left intact, a player who
-- fell through a gap would land on grass ~10 studs down instead of passing
-- TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD (-40) and losing a life. Carved
-- across the full segment width (not just the bridges' 50%) so stepping off
-- the SIDE of a bridge drops you too, which is the whole read of an
-- elevated skyway.
-- Walkable, not jumpable: Roblox characters auto-step obstacles up to about
-- 2 studs, so a flight built from rises under that can simply be walked up.
local SKYRAIL_STEP_RISE = 1.6
local SKYRAIL_BRIDGE_HEIGHT = 10
local SKYRAIL_APPROACH_LENGTH = 24
local SKYRAIL_STEP_RUN_LENGTH = 36

-- ===== Why the path is this narrow, and why the lengths are checked =====
--
-- The elevated pieces used to be SegmentWidth * 0.28 = 20.2 studs wide while
-- being 18 (bridge) and 8 (moving platform) studs LONG. Measured on a real
-- generation, every elevated element was wider across the track than it was
-- long along it — so instead of reading as a bridge you walk down, each one
-- read as a slab laid ACROSS the track, which is exactly how it was reported.
-- A bridge is a thing that is long in the direction you travel; that is not a
-- style preference, it is what makes the shape legible at a glance.
--
-- So the width comes down to a genuine catwalk (a character is ~4 studs wide,
-- so 10 is demanding but fair) and the span is divided so that every elevated
-- piece stays LONGER than it is wide. The assertion at the bottom of this
-- block is what stops a future tweak to any one of these constants quietly
-- reintroducing the crosswise look — it is cheap, it runs once, and the bug it
-- catches is invisible in the config.
local SKYRAIL_PATH_WIDTH = TrackGeometry.SegmentWidth * 0.14
local SKYRAIL_BRIDGE_SPAN_FRACTION = 0.26
local SKYRAIL_MOVER_COUNT = 2
local SKYRAIL_MOVER_GAP = 2
-- Railings. Purely visual (CanCollide = false): they are what makes the deck
-- read as a bridge from a distance, but a solid rail would also remove the
-- risk of falling, which is the entire point of the theme.
local SKYRAIL_RAIL_HEIGHT = 2.5
local SKYRAIL_RAIL_THICKNESS = 0.5

local function skyRailElevatedLayout(length: number)
	local climbStartZ = SKYRAIL_APPROACH_LENGTH
	local elevatedStartZ = climbStartZ + SKYRAIL_STEP_RUN_LENGTH
	local descendStartZ = length - SKYRAIL_APPROACH_LENGTH - SKYRAIL_STEP_RUN_LENGTH
	local elevatedSpan = descendStartZ - elevatedStartZ
	local bridgeLength = elevatedSpan * SKYRAIL_BRIDGE_SPAN_FRACTION
	local moverSpan = elevatedSpan - bridgeLength * 2
	local moverLength = moverSpan / SKYRAIL_MOVER_COUNT - SKYRAIL_MOVER_GAP
	return climbStartZ, elevatedStartZ, descendStartZ, bridgeLength, moverSpan, moverLength
end

do
	local _, _, _, bridgeLength, _, moverLength = skyRailElevatedLayout(TrackGeometry.StraightLength)
	for name, alongLength in { Bridge = bridgeLength, MovingPlatform = moverLength } do
		assert(
			alongLength > SKYRAIL_PATH_WIDTH,
			`ThemeHazardBuilder: SkyRail {name} is {string.format("%.1f", alongLength)} studs along the track but `
				.. `{string.format("%.1f", SKYRAIL_PATH_WIDTH)} across it — wider than it is long reads as a bar `
				.. `laid across the track, not a bridge`
		)
	end
end

-- Two thin beams down the long edges of an elevated deck, running ALONG the
-- track. Non-collidable, so they change how the piece reads without changing
-- how it plays.
local function addDeckRailings(parent: Instance, deckCFrame: CFrame, deckWidth: number, deckLength: number)
	for _, side in { -1, 1 } do
		local rail = Instance.new("Part")
		rail.Anchored = true
		rail.CanCollide = false
		rail.CanQuery = false
		rail.CanTouch = false
		rail.Material = Enum.Material.Metal
		rail.Color = Color3.fromRGB(120, 128, 140)
		rail.Size = Vector3.new(SKYRAIL_RAIL_THICKNESS, SKYRAIL_RAIL_HEIGHT, deckLength)
		rail.CFrame = deckCFrame * CFrame.new(side * (deckWidth / 2 - SKYRAIL_RAIL_THICKNESS / 2), SKYRAIL_RAIL_HEIGHT / 2 + 0.5, 0)
		rail.Name = "SkyRailRailing"
		rail.Parent = parent
	end
end

-- A flight of steps climbing (or descending) between two heights along the
-- segment's forward axis. Anchored: these are the fixed part of the route.
local function addStepFlight(parent: Instance, entryCFrame: CFrame, startZ: number, endZ: number, startY: number, endY: number, width: number)
	local rise = endY - startY
	local stepCount = math.max(1, math.ceil(math.abs(rise) / SKYRAIL_STEP_RISE))
	local runPerStep = (endZ - startZ) / stepCount

	for i = 1, stepCount do
		local stepY = startY + rise * (i / stepCount)
		local stepCenterZ = startZ + runPerStep * (i - 0.5)

		local step = Instance.new("Part")
		step.Anchored = true
		step.CanCollide = true
		step.Material = Enum.Material.Metal
		step.Color = Color3.fromRGB(180, 180, 190)
		step.Size = Vector3.new(width, 1, math.abs(runPerStep) + 0.5)
		step.CFrame = entryCFrame * CFrame.new(0, stepY, -stepCenterZ)
		step.Name = "SkyRailStep"
		step.Parent = parent
	end
end

-- SkyRail straight. The elevated section used to begin with the whole road
-- destroyed and the first bridge simply floating at Y=10 — a player arriving
-- at road level (Y=1) met a 9-stud rise across an 18-stud void with nothing
-- in between, which is exactly the "transition looks impossible" report. The
-- route is now continuous end to end:
--
--   solid road -> step flight up -> elevated bridges + moving platforms
--                -> step flight down -> solid road
--
-- Only the elevated middle is carved out underneath, so the approach and
-- exit keep real ground and only the part that is SUPPOSED to be a drop is
-- one. Bridges are narrower than before (the width is the difficulty now
-- that the height transition is fair), and the middle of the span is a pair
-- of vertically-oscillating platforms that have to be timed.
local function buildSkyRailStraight(pieceModel: Model, entryCFrame: CFrame)
	local length = TrackGeometry.StraightLength
	local pathWidth = SKYRAIL_PATH_WIDTH

	local roadColor, roadMaterial, roadWidth, roadThickness = destroyRoadForRebuild(pieceModel)

	local climbStartZ, elevatedStartZ, descendStartZ, bridgeLength, moverSpan, moverLength =
		skyRailElevatedLayout(length)
	local elevatedEndZ = descendStartZ
	local exitRoadStartZ = length - SKYRAIL_APPROACH_LENGTH

	-- Real ground to arrive on and to land back on.
	addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, roadWidth, 0, 0, climbStartZ)
	addRoadStrip(pieceModel, entryCFrame, roadColor, roadMaterial, roadThickness, roadWidth, 0, exitRoadStartZ, length)

	-- Everything between the two road strips is a genuine drop.
	local carveLength = exitRoadStartZ - climbStartZ
	TerrainGroundBuilder.CarveChasm(
		entryCFrame * CFrame.new(0, 0, -(climbStartZ + carveLength / 2)),
		TrackGeometry.SegmentWidth,
		carveLength
	)

	addStepFlight(pieceModel, entryCFrame, climbStartZ, elevatedStartZ, 0, SKYRAIL_BRIDGE_HEIGHT, pathWidth)
	addStepFlight(pieceModel, entryCFrame, descendStartZ, exitRoadStartZ, SKYRAIL_BRIDGE_HEIGHT, 0, pathWidth)

	-- Elevated span: bridge, moving-platform gap, bridge. Every deck here is
	-- longer along the track than it is wide across it — see the assertion by
	-- SKYRAIL_PATH_WIDTH for why that is load-bearing rather than cosmetic.
	for _, startZ in { elevatedStartZ, elevatedEndZ - bridgeLength } do
		local deckCFrame = entryCFrame * CFrame.new(0, SKYRAIL_BRIDGE_HEIGHT, -(startZ + bridgeLength / 2))

		local bridge = Instance.new("Part")
		bridge.Anchored = true
		bridge.CanCollide = true
		bridge.Material = Enum.Material.Metal
		bridge.Color = Color3.fromRGB(180, 180, 190)
		bridge.Size = Vector3.new(pathWidth, 1, bridgeLength)
		bridge.CFrame = deckCFrame
		bridge.Name = "SkyRailBridge"
		bridge.Parent = pieceModel

		addDeckRailings(pieceModel, deckCFrame, pathWidth, bridgeLength)
	end

	for i = 1, SKYRAIL_MOVER_COUNT do
		local moverZ = elevatedStartZ + bridgeLength + moverSpan * ((i - 0.5) / SKYRAIL_MOVER_COUNT)
		createMovingPlatform(
			pieceModel,
			entryCFrame * CFrame.new(0, SKYRAIL_BRIDGE_HEIGHT, -moverZ),
			Vector3.new(pathWidth, 1, moverLength),
			Vector3.new(0, 5, 0), -- 10 studs of vertical travel
			2.5,
			(i - 1) / SKYRAIL_MOVER_COUNT -- opposite phases: one rising while the other falls
		)
	end
end

-- SkyRail curve. The mechanic is the straight's moving platforms turned on
-- their side: decks that slide ACROSS the track rather than up and down, over a
-- chasm, with a solid ledge left along one edge as the alternative route.
--
-- ===== Why the ledge is narrow, and why it is on the OUTSIDE =====
--
-- The first version of this made the platforms dead content by getting both of
-- those wrong at once, and it is worth being explicit about why, because
-- neither mistake looks like a mistake in isolation:
--
--   1. The ledge was `halfWidth` — 36 studs, HALF THE ROAD. That is not a ledge
--      you squeeze along, it is a normal two-lane road with some scenery moving
--      about next to it. Nothing about it reads as a risk.
--   2. The ledge was on the INSIDE of the turn. Curves here run clockwise (see
--      TrackPieceBuilder.SampleCurve), so +X is the inside — the SHORTER path.
--      So the safe route was also the fast route.
--
-- Together those meant the moving platforms were strictly worse than ignoring
-- them: longer, riskier, and pointless. A racer would never touch one, which is
-- exactly how it was reported — the hazard is bypassed by simply staying on the
-- other side.
--
-- Both are fixed by the same swap. The ledge goes on the OUTSIDE and gets cut to
-- a genuine catwalk, so the two routes trade against each other: the ledge is
-- safe but it is the long way round and it is narrow enough that a shove from
-- another racer puts you in the chasm, while the platforms are the inside line
-- and cost you a wait for the timing. That is the decision the segment was
-- supposed to offer.
local SKYRAIL_CURVE_LEDGE_WIDTH = 12

-- ===== Why the decks oscillate VERTICALLY and do not sweep sideways =====
--
-- The first attempt at making this segment matter gave each chord one narrow
-- deck that slid ACROSS the chasm, the idea being that a racer would ride it
-- over. Measured live, a rider does not survive that: standing on a deck moving
-- 11.7 studs/second sideways, the player drifted 0.1 -> 3.5 -> 7.4 -> 10.9 ->
-- 14.8 studs off it and fell into the chasm inside 1.5 seconds, at normal
-- WalkSpeed with no input.
--
-- That is not a tuning problem, it is the mechanism. A laterally-moving platform
-- can only drag a rider along by FRICTION, and it is fighting the Humanoid's own
-- movement controller, which re-drives horizontal velocity toward MoveDirection *
-- WalkSpeed every physics step — the same behaviour DesertWindService's docstring
-- documents defeating a raw velocity push. Slowing the sweep down only makes the
-- rider lose ground more slowly.
--
-- Vertical motion has no such problem: the rider rests ON the deck and gravity
-- holds them there, which is exactly why the SkyRail STRAIGHT's movers work. So
-- the curve now uses that same proven shape. Each chord carries a ROW of decks
-- spanning the chasm; a racer picks a lane and crosses ALONG the track (the
-- chasm runs the length of both middle chords), hopping from the first chord's
-- deck to the second's. Staggered phases mean those two decks are rarely level,
-- so the hop is a timing gate rather than a walk — which is the "jump off moving
-- platforms" the segment was always meant to be.
--
-- The lanes still trade against each other, because the chasm reaches the inside
-- barrier: the innermost lane is the shortest line round the turn, and the ledge
-- (outside, see below) is the longest but solid.
local SKYRAIL_CURVE_LANE_COUNT = 3
local SKYRAIL_CURVE_LANE_GAP = 4
-- Keeps the outermost decks off the ledge edge and off the anchored barrier —
-- same standing-contact problem HAZARD_SPAN_WIDTH exists to avoid.
local SKYRAIL_CURVE_EDGE_CLEARANCE = 1
-- Half the vertical travel, so decks oscillate over twice this. Deliberately
-- smaller than the straight's 5: two fully out-of-phase decks then differ by at
-- most 2x this, and the hop between them has to stay inside a Roblox jump
-- (~7 studs) even at the worst moment, or the lane is impassable rather than
-- difficult.
local SKYRAIL_CURVE_DECK_RISE = 2.5
local SKYRAIL_CURVE_TRAVEL_SECONDS = 2.5

assert(
	SKYRAIL_CURVE_LEDGE_WIDTH <= TrackGeometry.SegmentWidth / 3,
	`ThemeHazardBuilder: the SkyRail curve ledge is {SKYRAIL_CURVE_LEDGE_WIDTH} studs of a `
		.. `{TrackGeometry.SegmentWidth}-stud road — wide enough to just run down, which makes the moving platforms `
		.. `beside it content nobody has a reason to use`
)
assert(
	SKYRAIL_CURVE_DECK_RISE * 2 < 7,
	`ThemeHazardBuilder: SkyRail curve decks swing {SKYRAIL_CURVE_DECK_RISE * 2} studs apart at worst, which is more `
		.. `than a Roblox jump clears — the crossing would be impossible rather than timed`
)

local function buildSkyRailCurve(pieceModel: Model, entryCFrame: CFrame)
	local chordCFrames, chordLength, roadColor, roadMaterial, roadThickness = removeMiddleCurveChords(pieceModel, entryCFrame)
	local halfWidth = TrackGeometry.SegmentWidth / 2

	-- -X is the OUTSIDE of a clockwise turn; see the note above.
	local ledgeOffsetX = -(halfWidth - SKYRAIL_CURVE_LEDGE_WIDTH / 2)
	local chasmWidth = TrackGeometry.SegmentWidth - SKYRAIL_CURVE_LEDGE_WIDTH
	local chasmOffsetX = halfWidth - chasmWidth / 2
	local chasmMinX = chasmOffsetX - chasmWidth / 2

	local usableWidth = chasmWidth - SKYRAIL_CURVE_EDGE_CLEARANCE * 2
	local deckWidth = (usableWidth - SKYRAIL_CURVE_LANE_GAP * (SKYRAIL_CURVE_LANE_COUNT - 1)) / SKYRAIL_CURVE_LANE_COUNT
	local deckLength = chordLength * 0.9
	-- Sits the deck's LOW point just above the ledge's surface, so boarding from
	-- the ledge is a step rather than a climb, and its high point stays inside a
	-- jump from the solid road either side of the chasm.
	local baseY = TrackGeometry.RoadThickness / 2 + 0.5 + SKYRAIL_CURVE_DECK_RISE

	for chordIndex, chordCFrame in chordCFrames do
		-- Narrow solid ledge along the outside edge.
		addCurveRoadStrip(pieceModel, chordCFrame, roadColor, roadMaterial, roadThickness, SKYRAIL_CURVE_LEDGE_WIDTH, ledgeOffsetX, chordLength)

		-- Everything from the ledge to the inside barrier is a real drop.
		TerrainGroundBuilder.CarveChasm(
			chordCFrame * CFrame.new(chasmOffsetX, 0, 0),
			chasmWidth,
			chordLength + CURVE_CHORD_FILL_OVERLAP
		)

		for laneIndex = 1, SKYRAIL_CURVE_LANE_COUNT do
			local laneX = chasmMinX
				+ SKYRAIL_CURVE_EDGE_CLEARANCE
				+ deckWidth / 2
				+ (laneIndex - 1) * (deckWidth + SKYRAIL_CURVE_LANE_GAP)

			createMovingPlatform(
				pieceModel,
				chordCFrame * CFrame.new(laneX, baseY, 0),
				Vector3.new(deckWidth, 1, deckLength),
				Vector3.new(0, SKYRAIL_CURVE_DECK_RISE, 0),
				SKYRAIL_CURVE_TRAVEL_SECONDS,
				-- Each lane keeps its own rhythm, and the two chords in a lane are
				-- half a cycle apart — so the along-track hop, which is the one a
				-- racer actually has to make, is never simply handed to them.
				(((laneIndex - 1) / SKYRAIL_CURVE_LANE_COUNT) + (chordIndex - 1) * 0.5) % 1
			)
		end
	end
end

local function buildSkyRail(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType == "Straight" then
		buildSkyRailStraight(pieceModel, entryCFrame)
	else
		buildSkyRailCurve(pieceModel, entryCFrame)
	end
end

-- Desert: no static geometry — DesertWindService drives the periodic wind
-- push for any live segment tagged ThemeId == "Desert" (see that module).
-- Desert was an EMPTY builder: measured on a real generation, a Desert
-- straight had 3 parts (road + two barriers) and a Desert curve 24 (chords +
-- barriers) — i.e. both of its segments were bare road, 2 of the 16
-- theme/segment combinations with nothing in them at all. The only Desert
-- content was the ambient headwind (DesertWindService) and the sand recolour,
-- neither of which is something to dodge, so the segment played as a gap in
-- the race rather than as part of it.
--
-- Deliberately built from helpers that are already proven live elsewhere
-- rather than a new mechanic: sweeper bars are Volcanic's (a non-lethal shove
-- across the road, which reads as a sandstorm gust here), and the dune walls
-- are HillMud's climb-wall-plus-jump-platforms pair, including its hard-won
-- endClearance rule. Adding a bespoke desert mechanic would be more
-- interesting and much more likely to ship broken; this makes the segment
-- playable with code whose failure modes are already known.
--
-- The sweepers keep their orange Neon look instead of being recoloured to
-- sand. That is on purpose and matches the note on createSweeperBar: a moving
-- thing that shoves you should teach the same lesson on every theme, and a
-- sand-coloured bar on a sand road is a hazard you do not see coming.
local DESERT_DUNE_HEIGHT = 12
local DESERT_DUNE_END_CLEARANCE = 34

local function buildDesert(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType == "Straight" then
		createSweeperRank(pieceModel, entryCFrame, exitCFrame, TrackGeometry.StraightLength * 0.8)
	else
		-- Same offset-from-the-ends rule HillMud documents: a curve's entry and
		-- exit CFrames are exactly where the checkpoint triggers sit, so a wall
		-- built on them spawns respawning players inside it.
		for _, baseCFrame in {
			entryCFrame * CFrame.new(0, 0, -DESERT_DUNE_END_CLEARANCE),
			exitCFrame * CFrame.new(0, 0, DESERT_DUNE_END_CLEARANCE),
		} do
			createClimbWall(pieceModel, baseCFrame, DESERT_DUNE_HEIGHT, true)
			addJumpPlatforms(pieceModel, baseCFrame, DESERT_DUNE_HEIGHT, true)
		end
	end
end

local NEON_TELEGRAPH_SECONDS = 1.5
local NEON_BLOCK_LIFETIME_SECONDS = 3
-- One block every ~6-9s meant a player could cross a whole segment without
-- ever seeing one. Now a faster cycle AND several blocks per cycle, so the
-- segment is a continuous dodge rather than an occasional surprise.
local NEON_SPAWN_INTERVAL_SECONDS = 2.5
local NEON_BLOCKS_PER_WAVE = 3
local NEON_BLOCK_SIZE = 8
-- Fraction of the road width the drop spot is sampled across. Was 0.8, which
-- put every spot inside x = +/-28.8; with an 8-stud block that is a reach of 32.8
-- on a road whose barriers are at 36, so the outer 3 studs on each side were
-- never a target at all. On a hazard that is already random, a strip that is
-- structurally never hit is not "unlikely", it is a safe lane — and unlike the
-- Classic bar you can stand in it indefinitely. Sampling out to +/-32.4 lets a
-- block's own footprint reach past the barrier face on either side.
local NEON_SPAWN_WIDTH_FRACTION = 0.9

assert(
	TrackGeometry.SegmentWidth * NEON_SPAWN_WIDTH_FRACTION / 2 + NEON_BLOCK_SIZE / 2 >= REACHABLE_HALF_WIDTH,
	`ThemeHazardBuilder: NeonCircuit blocks can only reach x = +/-`
		.. `{string.format("%.1f", TrackGeometry.SegmentWidth * NEON_SPAWN_WIDTH_FRACTION / 2 + NEON_BLOCK_SIZE / 2)} `
		.. `but a player can stand out to +/-{REACHABLE_HALF_WIDTH} — the barrier line is a permanently safe lane`
)

-- NeonCircuit: a recurring spawner (both straight/curve) that telegraphs a
-- random spot with a red ring for NEON_TELEGRAPH_SECONDS, then drops a
-- real falling block there. The block is registered with ZoneHazardMonitor
-- (life loss on contact, matching Volcanic's magma) for its lifetime, then
-- despawns. The loop self-terminates once `pieceModel` is destroyed
-- (Regenerate()) — no explicit connection to clean up, unlike the
-- Heartbeat-driven hazard bars above.
local function buildNeonCircuit(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)
	local spanLength = if segment.SegmentType == "Straight" then TrackGeometry.StraightLength * 0.7 else 60

	-- One wave = NEON_BLOCKS_PER_WAVE independent telegraph->drop sequences
	-- fired at once at different spots. Split into its own function so each
	-- block keeps its own timing rather than the whole wave sharing one, and
	-- so waves can overlap.
	local function dropBlock()
		local lateralOffset = (math.random() - 0.5) * TrackGeometry.SegmentWidth * NEON_SPAWN_WIDTH_FRACTION
		local longitudinalOffset = (math.random() - 0.5) * spanLength
		local spotCFrame = center * CFrame.new(lateralOffset, 0, longitudinalOffset)

		local telegraph = Instance.new("Part")
		telegraph.Anchored = true
		telegraph.CanCollide = false
		telegraph.CanQuery = false
		telegraph.Shape = Enum.PartType.Cylinder
		telegraph.Material = Enum.Material.Neon
		telegraph.Color = Color3.fromRGB(255, 20, 20)
		telegraph.Transparency = 0.3
		telegraph.Size = Vector3.new(0.2, 10, 10)
		telegraph.CFrame = spotCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 + 0.2, 0) * CFrame.Angles(0, 0, math.rad(90))
		telegraph.Name = "NeonTelegraph"
		telegraph.Parent = pieceModel

		task.wait(NEON_TELEGRAPH_SECONDS)
		telegraph:Destroy()

		if pieceModel.Parent == nil then
			return
		end

		local block = Instance.new("Part")
		block.Anchored = false
		block.CanCollide = true
		block.Material = Enum.Material.Neon
		block.Color = Color3.fromRGB(200, 0, 200)
		block.Size = Vector3.new(NEON_BLOCK_SIZE, NEON_BLOCK_SIZE, NEON_BLOCK_SIZE)
		block.CFrame = spotCFrame * CFrame.new(0, 60, 0)
		block.Name = "NeonFallingBlock"
		block.Parent = pieceModel

		-- The life-costing volume is a SEPARATE, larger, non-collidable part
		-- welded to the block — registering the block itself never worked.
		-- ZoneHazardMonitor asks "is this player's HumanoidRootPart inside
		-- the zone", but the block is CanCollide = true, so the physics
		-- solver shoves a player out of it the instant they overlap: the
		-- rootpart is never inside when the 0.5s poll runs. Confirmed live —
		-- standing in a landed block left lives at 3/3. This is the same
		-- separate-zone fix the magma pool already needed, for the same
		-- reason, and it's why MagmaZone exists alongside MagmaPool.
		local zone = Instance.new("Part")
		zone.Name = "NeonBlockZone"
		zone.Size = block.Size + Vector3.new(3, 8, 3)
		zone.CFrame = block.CFrame
		zone.Anchored = false
		zone.CanCollide = false
		zone.CanQuery = false
		zone.Massless = true
		zone.Transparency = 1
		zone.Parent = block

		local zoneWeld = Instance.new("WeldConstraint")
		zoneWeld.Part0 = zone
		zoneWeld.Part1 = block
		zoneWeld.Parent = zone

		-- After the weld, not before: welding the zone in re-forms the assembly,
		-- and a re-formed assembly goes back to automatic ownership. Where this
		-- block lands decides whether someone loses a life, so the server has to
		-- be the one simulating the fall — see pinPhysicsToServer.
		pinPhysicsToServer(block)

		ZoneHazardMonitor.RegisterZone(zone)

		-- Landing feedback. Touched rather than a fixed delay because the fall
		-- time depends on what it lands ON (road, a jump platform, another
		-- block), and a crash that plays before or after the visible impact is
		-- worse than none. It spawns 60 studs up, so there is nothing for it
		-- to be touching at birth. `:Once` so a block that bounces or gets
		-- shoved along the road only ever crashes once.
		block.Touched:Once(function()
			SoundDirector.PlayAtPart(block, "BlockImpact")
			VisualEffectsService.ShowImpactBurst(block.Position, block.Color)
		end)

		task.delay(NEON_BLOCK_LIFETIME_SECONDS, function()
			if block.Parent ~= nil then
				ZoneHazardMonitor.UnregisterZone(zone)
				block:Destroy()
			end
		end)
	end

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(NEON_SPAWN_INTERVAL_SECONDS + math.random())
			if pieceModel.Parent == nil then
				break
			end

			-- Each block on its own thread: dropBlock yields for its own
			-- telegraph, so running them inline would serialise the wave into
			-- one-at-a-time again, which is exactly the behaviour being fixed.
			for _ = 1, NEON_BLOCKS_PER_WAVE do
				task.spawn(dropBlock)
			end
		end
	end)
end

-- ===== Public surface =====

-- SegmentType (in the function signature below) matches TrackBlueprints.
-- SegmentBlueprint's own field type — keeping the annotation as a comment
-- here since Luau doesn't support inline `Table.field: Type = value`
-- syntax on a non-local assignment (that's local-declaration-only).
ThemeHazardBuilder.HAZARD_BUILDERS = {
	Classic = buildClassic,
	HillMud = buildHillMud,
	IceFrost = buildIceFrost,
	Volcanic = buildVolcanic,
	WaterDock = buildWaterDock,
	SkyRail = buildSkyRail,
	Desert = buildDesert,
	NeonCircuit = buildNeonCircuit,
}

return ThemeHazardBuilder

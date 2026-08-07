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
local Players = game:GetService("Players")

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

local function createSweeperBar(parent: Instance, entryCFrame: CFrame, exitCFrame: CFrame, barLength: number, sweepSpan: number, phase: number, oneWay: boolean?) : BasePart
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

	-- Two motions, chosen by `oneWay`.
	--
	-- Oscillating (the original) runs the bar down the segment and back, so half
	-- of every cycle it travels WITH the racer — overtaking from behind, which
	-- reads as the track helping and is nearly impossible to see coming.
	--
	-- One-way keeps only the half that comes AT the racer: the bar starts at the
	-- far end of its span, sweeps back toward the entry, then restarts. With a
	-- rank of them evenly spread through the cycle it reads as a steady procession
	-- of bars coming the other way, which is what a racer can actually read and
	-- time a jump against.
	--
	-- nearPos is the FORWARD end (local -Z is forward on every track piece) and
	-- farPos the end nearer the entry, so lerping near -> far is the against-the-
	-- racer direction.
	local cycleSeconds = if oneWay then SWEEPER_TRAVEL_SECONDS else SWEEPER_TRAVEL_SECONDS * 2
	local startClock = os.clock() - phase * cycleSeconds
	local lastAlpha = 0

	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local elapsed = (os.clock() - startClock) % cycleSeconds
		local alpha
		if oneWay then
			alpha = elapsed / SWEEPER_TRAVEL_SECONDS
		elseif elapsed <= SWEEPER_TRAVEL_SECONDS then
			alpha = elapsed / SWEEPER_TRAVEL_SECONDS
		else
			alpha = (cycleSeconds - elapsed) / SWEEPER_TRAVEL_SECONDS
		end
		alpha = math.clamp(alpha, 0, 1)

		local target = nearPos:Lerp(farPos, alpha)

		-- On the one-way wrap, TELEPORT back to the start instead of retargeting.
		--
		-- A rigid AlignPosition does not jump its part to a new target, it DRAGS
		-- it there through the world. Retargeting on the wrap therefore hauled the
		-- bar the whole length of the segment in the racer's own direction of
		-- travel — visibly a bar overtaking from behind, which is exactly what
		-- one-way motion exists to prevent. The curve sweeper already learned this
		-- the hard way (it wedged solid); the straight had the same flaw and it
		-- read as travelling WITH the player.
		if oneWay and alpha < lastAlpha then
			hazard.CFrame = CFrame.new(target) * (hazard.CFrame - hazard.CFrame.Position)
			hazard.AssemblyLinearVelocity = Vector3.zero
			hazard.AssemblyAngularVelocity = Vector3.zero
		end
		lastAlpha = alpha

		alignPosition.Position = target
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

-- `barCount` and `oneWay` default to the original oscillating rank of 4, so
-- existing callers (Desert) are untouched.
local function createSweeperRank(parent: Instance, entryCFrame: CFrame, exitCFrame: CFrame, sweepSpan: number, barCount: number?, oneWay: boolean?)
	-- A sweeper with a gap at the edge is just a slalom, so this spans the full
	-- road — but stopping 1 stud short of each barrier rather than reaching 1.5
	-- studs INTO them, which is what it used to do. See HAZARD_SPAN_WIDTH.
	--
	-- Full width is the point of this hazard and stays that way: the sweepers are
	-- the thing you cannot walk around, and jumping is the answer to them. The
	-- magma field they share a segment with is the opposite — you steer through
	-- that and cannot jump it. One of each is what gives the segment two things
	-- to do at once.
	local barLength = HAZARD_SPAN_WIDTH
	local count = barCount or SWEEPER_COUNT

	for i = 1, count do
		createSweeperBar(parent, entryCFrame, exitCFrame, barLength, sweepSpan, (i - 1) / count, oneWay)
	end
end

-- ===== The curve's clock sweep =====
--
-- A straight's sweeper slides along a line. A curve has no line to slide along,
-- and that is why curves never had one — a bar travelling in a straight chord
-- across a 90-degree arc leaves the road almost immediately.
--
-- The equivalent motion on an arc is a clock hand: the bar keeps spanning the
-- road and pivots around the curve's own centre, so its tip traces the arc and
-- it covers the WHOLE segment exactly the way the straight's rank covers a
-- straight. Rather than deriving that rotation by hand — the centre of
-- curvature, the sign of the sweep, the yaw at each angle, every one an easy
-- mistake — it is read straight off the same TrackPieceBuilder.SampleCurve the
-- road chords are built from. Sampling finely and walking the samples IS the
-- clock hand, and it is guaranteed to stay over paved road because it is the
-- same curve the road came from.
-- How far short of the curve's EXIT the sweep begins.
--
-- The sweep runs exit -> entry, so its start sits on the exit plane, and a
-- curve's exit is where TrackGenerator puts a checkpoint trigger. On the oval's
-- last segment that checkpoint is the start/finish line itself — the spot every
-- racer stands on at the beginning of a lap. A bar starting exactly there shoves
-- the field backwards the instant the race begins, before anyone has moved.
--
-- Starting the sweep this far along the arc means the bar is already travelling
-- AWAY from the spawn when it first appears, and the wrap returns it to the same
-- offset rather than onto the line. Same family of rule as the endClearance
-- HillMud and Desert use to keep walls off a respawn plane.
local CURVE_SWEEPER_START_CLEARANCE = 30

-- ===== The arc as a circle =====
--
-- A curve piece is an arc of a circle of TrackGeometry.CurveRadius, and anything
-- that has to TRAVEL along one — a sweeping bar, a wave rolling down a pond —
-- wants the same thing: that circle's centre, and a rotation about it. Returns a
-- function mapping `alpha` (0 = the curve's entry, 1 = its exit) to a CFrame on
-- the road's centreline at road height, facing the way a racer travels.
--
-- Two things are DERIVED rather than assumed, both because they are exactly the
-- sort of thing that is wrong half the time when typed in:
--
--   * The centre lies one radius to the +X side of the entry (+X is the inside
--     of these curves — see TrackPieceBuilder.SampleCurve).
--   * Which way the angle advances comes from testing (Y x radial) against the
--     entry's own forward vector.
--
-- And the radius is pulled in by one SAGITTA. The road is not actually an arc:
-- it is a ring of straight chords inscribed in one, so its surface sits up to a
-- sagitta INSIDE the true circle. Anything swept along the true arc overhangs
-- the road between chord ends — measured at 1.9 studs past the edge, which was
-- enough for a full-width bar to bury an end in a barrier and jam solid.
local function makeCurveArcPoser(entryCFrame: CFrame) : (number) -> CFrame
	local radius = TrackGeometry.CurveRadius
	local entryPosition = entryCFrame.Position
	local entryForward = entryCFrame.LookVector
	local centre = (entryCFrame * CFrame.new(radius, 0, 0)).Position

	local sagitta = radius * (1 - math.cos(math.rad(TrackGeometry.CurveArcDegrees / TrackGeometry.CurveSubdivisions) / 2))
	local radialAtEntry = Vector3.new(entryPosition.X - centre.X, 0, entryPosition.Z - centre.Z).Unit
		* (radius - sagitta)

	local positiveSweepDirection = Vector3.yAxis:Cross(radialAtEntry).Unit
	local angleSign = if positiveSweepDirection:Dot(entryForward) >= 0 then 1 else -1
	local totalSweep = math.rad(TrackGeometry.CurveArcDegrees) * angleSign

	return function(alpha: number) : CFrame
		local rotated = CFrame.fromAxisAngle(Vector3.yAxis, totalSweep * math.clamp(alpha, 0, 1))
			:VectorToWorldSpace(radialAtEntry)
		local position = Vector3.new(centre.X + rotated.X, entryPosition.Y, centre.Z + rotated.Z)
		-- Tangent here, pointing the way a racer travels. lookAt then gives a
		-- RightVector along the radius — the axis a full-width bar's length runs
		-- down, so it spans the road at every angle.
		local tangent = Vector3.yAxis:Cross(rotated).Unit * angleSign
		return CFrame.lookAt(position, position + tangent)
	end
end

local function createCurveSweeperBar(parent: Instance, entryCFrame: CFrame, barLength: number, phase: number)
	local arcPose = makeCurveArcPoser(entryCFrame)
	local function poseAt(alpha: number) : CFrame
		return arcPose(alpha) * CFrame.new(0, SWEEPER_HEIGHT, 0)
	end

	-- Alpha the sweep starts from, i.e. CURVE_SWEEPER_START_CLEARANCE studs of arc
	-- short of the exit.
	local arcLength = TrackGeometry.CurveRadius * math.rad(TrackGeometry.CurveArcDegrees)
	local sweepStart = math.clamp(1 - CURVE_SWEEPER_START_CLEARANCE / arcLength, 0.1, 1)

	local startPose = poseAt(sweepStart)

	-- ===== DO NOT ANCHOR THIS BAR =====
	--
	-- Anchored = false is required — AlignPosition/AlignOrientation only move
	-- unanchored parts — but it is also the RIGHT choice for how it looks, and
	-- that is worth recording because the opposite is the obvious-looking fix.
	--
	-- Reported from play as the curve bars "getting stuck". Investigated
	-- 2026-08-06 and the bar itself is clean: server-side over 250 samples x 12
	-- bars across all four curves there were ZERO stalls, zero lag behind the
	-- AlignPosition target (0.00 studs — no wedging), and no jam even with a
	-- character parked in the sweep path for 25s. What the CLIENT sees is 3.6%
	-- of frames with the bar motionless, because an unanchored part replicates
	-- through the physics pipeline and the client interpolates between packets.
	--
	-- The tempting fix is "anchor it and write CFrame directly." It is worse,
	-- measured head to head on the same arc and the same Heartbeat cadence:
	--
	--   anchored + CFrame writes   331 of 717 frames motionless  (46%)
	--   unanchored + AlignPosition  26 of 718 frames motionless  (3.6%)
	--
	-- Anchored CFrame changes replicate on a throttled schedule with no client
	-- interpolation; unanchored ones get smoothed. Anchoring makes the exact
	-- reported symptom twelve times worse.
	--
	-- Two other measured numbers for whoever tunes this next:
	--   * Clearance is nearly gone. The bar is 70 studs on a 72-stud road, so
	--     1 stud per side, and the sagitta correction (0.867 here) spends 87%
	--     of it. Worst endpoint reach measured across all 12 bars: 35.69
	--     against a road edge of 36 — 0.31 studs spare. Raising
	--     HazardBarLength, lowering CurveSubdivisions or changing CurveRadius
	--     puts the end back inside the barrier.
	--   * The wrap below teleports the bar 228 studs every 6.0s. That is a
	--     real visible discontinuity and is deliberate; see its own note.
	local hazard = Instance.new("Part")
	hazard.Anchored = false
	hazard.CanCollide = true
	hazard.Material = Enum.Material.Neon
	hazard.Color = Color3.fromRGB(255, 140, 0)
	hazard.Name = "SweeperHazardBar"
	hazard.Size = Vector3.new(barLength, 1, 1)
	hazard.CFrame = startPose
	CollisionTags.MarkPhaseable(hazard)

	local attachment = Instance.new("Attachment")
	attachment.Parent = hazard

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = startPose.Position
	alignPosition.MaxForce = 1e6
	-- Stiffer than the straight sweeper's 60. That one glides down a line and can
	-- afford to lag; this one is chasing a target that is both moving and turning,
	-- and lag here shows up as the bar cutting the corner off the road.
	alignPosition.Responsiveness = 200
	alignPosition.RigidityEnabled = true
	alignPosition.Parent = hazard

	-- Unlike the straight's sweeper, this bar's FACING has to change as it
	-- travels — that is the whole difference between a slide and a sweep — so the
	-- orientation target is rewritten every frame alongside the position.
	local orientationAttachment = Instance.new("Attachment")
	orientationAttachment.Parent = hazard

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = orientationAttachment
	alignOrientation.CFrame = startPose
	alignOrientation.MaxTorque = 1e6
	alignOrientation.Responsiveness = 200
	alignOrientation.RigidityEnabled = true
	alignOrientation.Parent = hazard

	local startClock = os.clock() - phase * SWEEPER_TRAVEL_SECONDS
	local lastAlpha = sweepStart

	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		local elapsed = (os.clock() - startClock) % SWEEPER_TRAVEL_SECONDS
		-- sweepStart -> 0, i.e. from just inside the curve's exit back toward its
		-- entry: against the racer, matching the straight's one-way rank.
		local alpha = sweepStart * (1 - elapsed / SWEEPER_TRAVEL_SECONDS)
		local pose = poseAt(alpha)

		-- On the wrap back to the far end, TELEPORT rather than retarget.
		--
		-- This is what broke the first version. A rigid AlignPosition does not
		-- "jump" its part to a new target, it drags it there through the world —
		-- so a wrap asked the solver to haul a 70-stud bar the entire length of
		-- the arc, across barriers and road, and it simply wedged. Measured on
		-- the broken build: the bar sat 145 studs from its own target with a
		-- velocity of 0.2, i.e. permanently stuck near the entry.
		if alpha > lastAlpha then
			hazard.CFrame = pose
			hazard.AssemblyLinearVelocity = Vector3.zero
			hazard.AssemblyAngularVelocity = Vector3.zero
		end
		lastAlpha = alpha

		alignPosition.Position = pose.Position
		alignOrientation.CFrame = pose
	end)
	hazard.Destroying:Connect(function()
		heartbeatConnection:Disconnect()
	end)

	hazard.Parent = parent
	pinPhysicsToServer(hazard)
	return hazard
end

local function createCurveSweeperRank(parent: Instance, entryCFrame: CFrame, barCount: number)
	for i = 1, barCount do
		createCurveSweeperBar(parent, entryCFrame, HAZARD_SPAN_WIDTH, (i - 1) / barCount)
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

-- Forward-declared: the jump staircase below drives its upper rows with the
-- same moving-platform machinery SkyRail uses, and that helper is defined
-- further down next to the rest of the SkyRail pieces. Declared rather than
-- moved so the SkyRail block stays in one readable place.
local createMovingPlatform: (Instance, CFrame, Vector3, Vector3, number, number) -> BasePart

-- NOTE: an explicit rider-carry was tried here and REMOVED.
--
-- The idea was to move anyone standing on a moving deck by the same delta the
-- deck moved, so a sideways-sweeping platform could carry them. Measured, it
-- half-worked and that was worse than not working: 89 carries against 1229
-- misses over four seconds, because a server-side CFrame write competes with the
-- client simulating its own character. The visible result was a player unable to
-- get OFF the platform — the correction kept dragging them back onto it.
--
-- Anything that wants a rideable moving platform needs to be done client-side,
-- where the character is actually simulated. Until then, decks are things you
-- stand on and walk against, not lifts.

-- Under Roblox's default ~7-stud jump height, with margin for the fact that
-- the player also has to travel sideways during the same arc.
local JUMP_PLATFORM_MAX_RISE = 5
local JUMP_PLATFORM_SIZE = 8
-- Centre-to-centre spacing, so the actual gap a player crosses is this minus
-- JUMP_PLATFORM_SIZE. Was 10, i.e. a 2-stud gap — close enough to step over
-- without really jumping, which made the staircase a free ladder and left
-- nobody any reason to climb the wall. At 12 the gap is 4 studs: a deliberate
-- hop each time, so taking the platforms is a choice with a cost rather than
-- the obvious answer, and climbing the truss competes on equal terms.
local JUMP_PLATFORM_LATERAL_STEP = 12
-- Clear of the wall itself (truss poles occupy z = -1..1) on the approach side.
-- Was 6, which put the platform's near edge 2 studs off the truss — close
-- enough that a climber had a shelf immediately overhead the whole way up. At
-- 10 the near edge is 6 studs clear, so the wall face is an unobstructed climb
-- and the two routes genuinely sit side by side.
local JUMP_PLATFORM_APPROACH = 10
-- Furthest a player can travel horizontally while still being at
-- JUMP_PLATFORM_MAX_RISE height, at this game's BASE_WALK_SPEED (16) and
-- BASE_JUMP_POWER (50). Solving 0.5*g*t^2 - v0*t + rise = 0 with g = 196.2 puts
-- the descending crossing of a 5-stud rise at t = 0.373s, and 16 studs/s over
-- that is ~5.9 studs. Rounded down, because a racer who mistimes it slightly
-- should still land rather than fall the whole wall.
local JUMP_PLATFORM_MAX_GAP = 5
-- Upper staircase rows drift toward the wall and back. Half the journey, so the
-- deck covers twice this, and slowly — this is a step that comes to you, not a
-- ride. See the note at the call site for why the motion is along the wall's
-- normal rather than across it.
local JUMP_PLATFORM_DRIFT_STUDS = 5
local JUMP_PLATFORM_DRIFT_SECONDS = 5

-- ===== Why the staircase is a serpentine and not one straight run =====
--
-- The monotonic single-run layout above worked only while walls were short. It
-- consumes JUMP_PLATFORM_LATERAL_STEP of road per step, so its width is
-- (platformCount - 1) * 10 studs. At a 30-stud wall that is 5 platforms = 40
-- studs, comfortably inside the road. Double the wall to 60 and it becomes 11
-- platforms = 100 studs on a 72-stud road: the staircase marches straight
-- through both barriers and out of the track.
--
-- So the run now wraps. Platforms fill a row across the road, and when the row
-- is full the next one starts further back from the wall and sweeps the other
-- way — a switchback. The no-platform-above-another rule the old comment fought
-- for is preserved, and now provably rather than by argument:
--   * within a row, columns are distinct and 10 studs apart > the 8-stud
--     platform, so footprints never overlap;
--   * between rows, z differs by JUMP_PLATFORM_ROW_DEPTH > the 8-stud platform,
--     so footprints never overlap there either.
-- Two platforms can only shadow each other if they overlap in BOTH axes, and
-- each axis is independently ruled out.
--
-- The sweep reverses on alternate rows (rather than restarting at the same
-- side) so the step from the end of one row to the start of the next stays a
-- single adjacent hop instead of a full-width traverse.
local JUMP_PLATFORM_ROW_DEPTH = 10
-- Keeps a platform's own footprint inside the barriers.
local JUMP_PLATFORM_MAX_LATERAL = TrackGeometry.SegmentWidth / 2 - JUMP_PLATFORM_SIZE / 2

assert(
	JUMP_PLATFORM_LATERAL_STEP > JUMP_PLATFORM_SIZE and JUMP_PLATFORM_ROW_DEPTH > JUMP_PLATFORM_SIZE,
	`ThemeHazardBuilder: jump platforms are {JUMP_PLATFORM_SIZE} studs across but are spaced `
		.. `{JUMP_PLATFORM_LATERAL_STEP} laterally and {JUMP_PLATFORM_ROW_DEPTH} between rows — at or below the `
		.. `platform size they overlap, which puts one platform directly above another`
)

-- The gaps have to stay CROSSABLE as well as present. Widening the spacing to
-- make climbing competitive is only interesting while the jump route still
-- exists; one stud too far and it silently becomes climb-only.
assert(
	JUMP_PLATFORM_LATERAL_STEP - JUMP_PLATFORM_SIZE <= JUMP_PLATFORM_MAX_GAP
		and JUMP_PLATFORM_ROW_DEPTH - JUMP_PLATFORM_SIZE <= JUMP_PLATFORM_MAX_GAP,
	`ThemeHazardBuilder: jump platforms leave gaps of `
		.. `{JUMP_PLATFORM_LATERAL_STEP - JUMP_PLATFORM_SIZE} studs laterally and `
		.. `{JUMP_PLATFORM_ROW_DEPTH - JUMP_PLATFORM_SIZE} between rows, but a jump gaining `
		.. `{JUMP_PLATFORM_MAX_RISE} studs only carries {JUMP_PLATFORM_MAX_GAP} studs across — the staircase `
		.. `would be impossible rather than optional`
)

local function addJumpPlatforms(parent: Instance, baseCFrame: CFrame, wallHeight: number, phaseable: boolean)
	-- Count derives from the wall's own height so every wall variant gets a rise
	-- inside the jump arc rather than a fixed count that happens to work for one
	-- of them. Minus one because the final hop is from the top platform over the
	-- wall, not onto a platform.
	local platformCount = math.max(1, math.ceil(wallHeight / JUMP_PLATFORM_MAX_RISE) - 1)
	local rise = wallHeight / (platformCount + 1)
	local columnCount = math.max(1, math.floor((JUMP_PLATFORM_MAX_LATERAL * 2) / JUMP_PLATFORM_LATERAL_STEP) + 1)

	for i = 1, platformCount do
		local index = i - 1
		local row = math.floor(index / columnCount)
		local column = index % columnCount
		if row % 2 == 1 then
			column = columnCount - 1 - column
		end

		local lateralOffset = (column - (columnCount - 1) / 2) * JUMP_PLATFORM_LATERAL_STEP
		local approach = JUMP_PLATFORM_APPROACH + row * JUMP_PLATFORM_ROW_DEPTH
		local platformCFrame = baseCFrame * CFrame.new(lateralOffset, rise * i, approach)

		if row == 0 then
			local platform = Instance.new("Part")
			platform.Anchored = true
			platform.CanCollide = true
			platform.Material = Enum.Material.Rock
			platform.Color = Color3.fromRGB(110, 80, 55)
			platform.Size = Vector3.new(JUMP_PLATFORM_SIZE, 1, JUMP_PLATFORM_SIZE)
			platform.CFrame = platformCFrame
			platform.Name = "JumpPlatform"
			if phaseable then
				CollisionTags.MarkPhaseable(platform)
			end
			platform.Parent = parent
		else
			-- Rows past the first are set back from the wall, and they now close
			-- that distance instead of just sitting there: each one drifts slowly
			-- IN toward the wall and back out again. Starting at the far end of
			-- its travel (createMovingPlatform begins at -travelOffset) means the
			-- climber's first sight of it is at its most distant, and waiting is
			-- what brings it to them.
			--
			-- Motion is along the platform's local Z only — toward and away from
			-- the wall. Deliberately NOT lateral: see the SkyRail curve notes for
			-- the measurement that a sideways-sweeping deck cannot carry a rider,
			-- because the Humanoid re-drives horizontal velocity every physics
			-- step and friction loses. Toward-the-wall motion is the same axis a
			-- player is trying to travel anyway, so a small drift underfoot reads
			-- as help or hindrance rather than as being dumped off.
			--
			-- Not marked phaseable even when the rest of the theme is:
			-- createMovingPlatform already puts these in the moving-platform
			-- collision group, and a part has exactly one group — tagging it
			-- phaseable would silently replace that.
			local mover = createMovingPlatform(
				parent,
				platformCFrame,
				Vector3.new(JUMP_PLATFORM_SIZE, 1, JUMP_PLATFORM_SIZE),
				Vector3.new(0, 0, -JUMP_PLATFORM_DRIFT_STUDS),
				JUMP_PLATFORM_DRIFT_SECONDS,
				-- Alternate phases so a row does not advance as one solid shelf.
				(i % 2) * 0.5
			)
			mover.Name = "JumpPlatform"
			mover.Material = Enum.Material.Rock
			mover.Color = Color3.fromRGB(140, 105, 70)
		end
	end
end

-- Two static pads on TOP of a wall, at its far corners — the launch point for
-- the crossing between walls. Static on purpose: the player has just climbed or
-- jumped a full wall, and the first thing they meet up there should be solid
-- footing to line up the next jump from, not another thing that moves.
local WALL_TOP_PAD_LATERAL = 12

local function addWallTopPads(parent: Instance, baseCFrame: CFrame, wallHeight: number, phaseable: boolean)
	for _, side in { -1, 1 } do
		local pad = Instance.new("Part")
		pad.Anchored = true
		pad.CanCollide = true
		pad.Material = Enum.Material.Rock
		pad.Color = Color3.fromRGB(95, 70, 48)
		pad.Size = Vector3.new(JUMP_PLATFORM_SIZE, 1, JUMP_PLATFORM_SIZE)
		pad.CFrame = baseCFrame * CFrame.new(side * WALL_TOP_PAD_LATERAL, wallHeight + 0.5, 0)
		pad.Name = "WallTopPad"
		if phaseable then
			CollisionTags.MarkPhaseable(pad)
		end
		pad.Parent = parent
	end
end

-- The crossing between two walls: a line of platforms hanging in open air at
-- WALL-TOP height, each sweeping side to side. Taken together with the static
-- pads on the walls themselves, the intended route over a HillMud straight is
--
--   climb/jump the wall -> WallTopPad -> time a sweeping platform -> next wall
--
-- rather than dropping back to the road between every wall.
--
-- ===== On sweeping sideways, and why it is slow =====
--
-- The SkyRail curve notes record a measurement worth respecting: a deck moving
-- 11.7 studs/second sideways does NOT carry a rider. The Humanoid re-drives
-- horizontal velocity toward MoveDirection * WalkSpeed every physics step, so
-- friction never wins, and a standing player slid off inside 1.5 seconds.
--
-- That does not rule the mechanic out here, because the job is different: this
-- platform is a stepping stone to time and hop off, not a lift to ride across.
-- But it does set the speed. At HILLMUD_BRIDGE_SWEEP_STUDS over
-- HILLMUD_BRIDGE_SWEEP_SECONDS the deck travels ~1.3 studs/second — an order of
-- magnitude under the speed that dumped a rider — so drift underfoot is
-- something a player can simply walk against while lining up the next jump.
-- Half the sweep, so the deck covers twice this.
local HILLMUD_BRIDGE_SWEEP_STUDS = 8
local HILLMUD_BRIDGE_SWEEP_SECONDS = 6

-- ===== How many platforms a gap needs =====
--
-- Not a fixed number. It has to come from how far a player can actually jump,
-- or the crossing is decoration.
--
-- A level jump at BASE_WALK_SPEED 16 and BASE_JUMP_POWER 50 is airborne
-- 2 * 50 / 196.2 = 0.51s, covering ~8.2 studs of open air. The take-off and
-- landing decks are JUMP_PLATFORM_SIZE across, and a player leaves from the near
-- edge of one and lands on the near edge of the next, so the free flight is
-- (centre spacing - JUMP_PLATFORM_SIZE). That puts the ceiling on centre-to-
-- centre spacing at 8.2 + 8 = 16.2, taken as 16 for margin.
--
-- The first version of this ignored all that: it centred a fixed 3 platforms on
-- the gap's midpoint across a span of its own choosing, which left the outermost
-- platform 24 studs from the wall on a curve — three times a jump. Spacing is
-- now derived from the wall-to-wall distance so the hop off the wall, every hop
-- between platforms, and the hop onto the far wall are all the same size and all
-- inside a jump.
local HILLMUD_BRIDGE_MAX_SPACING = 16

assert(
	HILLMUD_BRIDGE_SWEEP_STUDS + JUMP_PLATFORM_SIZE / 2 <= TrackGeometry.SegmentWidth / 2,
	`ThemeHazardBuilder: bridge platforms sweep out to x = +/-`
		.. `{HILLMUD_BRIDGE_SWEEP_STUDS + JUMP_PLATFORM_SIZE / 2} on a {TrackGeometry.SegmentWidth}-stud road — `
		.. `they would sweep through the barriers`
)

-- `wallGapLength` is the distance between the two walls this crossing spans,
-- centre to centre. Platforms are placed at even spacing across it — count
-- derived so no single hop exceeds HILLMUD_BRIDGE_MAX_SPACING — and given
-- staggered phases so the crossing is never one solid moving shelf.
local function addBridgePlatforms(parent: Instance, gapCenterCFrame: CFrame, wallHeight: number, wallGapLength: number)
	local platformCount = math.max(1, math.ceil(wallGapLength / HILLMUD_BRIDGE_MAX_SPACING) - 1)
	local spacing = wallGapLength / (platformCount + 1)

	assert(
		spacing <= HILLMUD_BRIDGE_MAX_SPACING,
		`ThemeHazardBuilder: a {string.format("%.1f", wallGapLength)}-stud gap with {platformCount} bridge platforms `
			.. `spaces them {string.format("%.1f", spacing)} apart, but a jump only carries `
			.. `{HILLMUD_BRIDGE_MAX_SPACING} — the crossing would be impossible`
	)

	for i = 1, platformCount do
		local alongTrack = (i - (platformCount + 1) / 2) * spacing
		local platform = createMovingPlatform(
			parent,
			gapCenterCFrame * CFrame.new(0, wallHeight, alongTrack),
			Vector3.new(JUMP_PLATFORM_SIZE, 1, JUMP_PLATFORM_SIZE),
			Vector3.new(HILLMUD_BRIDGE_SWEEP_STUDS, 0, 0),
			HILLMUD_BRIDGE_SWEEP_SECONDS,
			(i - 1) / platformCount
		)
		platform.Name = "BridgePlatform"
		platform.Material = Enum.Material.Rock
		platform.Color = Color3.fromRGB(125, 92, 62)
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
createMovingPlatform = function(parent: Instance, baseCFrame: CFrame, size: Vector3, travelOffset: Vector3, travelSeconds: number, phase: number) : BasePart
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
-- ===== Halved, doubled, and now deliberately PASSABLE =====
--
-- The old field was five patches at 0.46 of the road width — 33 studs each on a
-- 72-stud road — arranged so their union covered every stud a player could
-- stand on. That made the field something you could only survive by threading
-- exactly, and the asserts below used to enforce exactly that (no clear lane
-- anywhere).
--
-- The brief is now the opposite: half-size patches, twice as many, scattered
-- irregularly, and crucially PASSABLE AT A WALK. So the guarantees invert. What
-- has to hold now is:
--
--   1. Every slice of the segment has at most ONE patch in it, so there is
--      always open road beside whatever is in front of you. Guaranteed
--      structurally by giving each patch its own longitudinal slot and keeping
--      the patch shorter than the slot.
--   2. The sideways move from one patch's clear side to the next is inside what
--      a walking player covers in the time between them. That is what
--      "passable with regular walking" means numerically, and it is the real
--      constraint on how irregular the pattern can be — see below.
local MAGMA_PATCH_WIDTH_FRACTION = 0.23
-- Ten offsets, as fractions of the road width.
--
-- They wander rather than alternating, but they cannot wander freely, and it is
-- worth being explicit about why. Patches sit one per slot; at 10 patches over a
-- ~130-stud field the slots are ~13 studs apart, which at BASE_WALK_SPEED 16 is
-- ~0.8 seconds of running, during which a player can also move ~13 studs
-- sideways. So consecutive offsets may differ by at most ~0.18 of the road
-- width. A genuinely random scatter would routinely exceed that and produce a
-- field that cannot be walked, only jumped. The list below uses the full budget
-- in varying amounts and reverses direction at uneven points, which is as
-- irregular as walkability allows.
local MAGMA_PATCH_LATERAL_OFFSETS = { -0.30, -0.14, 0.02, 0.20, 0.36, 0.22, 0.06, -0.10, -0.28, -0.12 }
-- Largest fraction-of-width step the list is allowed to take between
-- consecutive patches, from the walking budget derived above.
local MAGMA_MAX_LATERAL_STEP_FRACTION = 0.18

-- Furthest a HumanoidRootPart can actually get from the road's centreline: the
-- barrier's inner face, less the rootpart's own half-width. Coverage is checked
-- against this rather than the full half-width, because the last stud of road
-- is geometry no player can stand their centre on.
local REACHABLE_HALF_WIDTH = TrackGeometry.SegmentWidth / 2 - 1

-- Narrowest strip of open road a walking player needs beside a patch. A
-- character's collision hull is ~4 studs across, so this is comfortable rather
-- than a squeeze.
local MAGMA_MIN_WALKABLE_LANE = 8

do
	local patchWidth = TrackGeometry.SegmentWidth * MAGMA_PATCH_WIDTH_FRACTION
	local patchHalfWidth = patchWidth / 2

	-- 1. A patch must never span enough of the road to close it. This is the
	--    inversion of the rule this block used to enforce: full-width coverage
	--    is now the SWEEPERS' job (they span HAZARD_SPAN_WIDTH deliberately, and
	--    are beaten by jumping, not by walking round), while magma is the hazard
	--    you steer through. Both being unavoidable would leave nothing to do.
	assert(
		patchWidth + MAGMA_MIN_WALKABLE_LANE <= TrackGeometry.SegmentWidth,
		`ThemeHazardBuilder: a magma patch is {string.format("%.1f", patchWidth)} studs across a `
			.. `{TrackGeometry.SegmentWidth}-stud road, leaving under {MAGMA_MIN_WALKABLE_LANE} studs beside it — `
			.. `the field would be unwalkable rather than something to steer through`
	)

	-- 2. Every patch must leave a walkable lane on at least one side once its
	--    own offset is taken into account, including the ones pushed hard
	--    against a barrier.
	for i, fraction in MAGMA_PATCH_LATERAL_OFFSETS do
		local offset = fraction * TrackGeometry.SegmentWidth
		local leftLane = (offset - patchHalfWidth) - (-TrackGeometry.SegmentWidth / 2)
		local rightLane = (TrackGeometry.SegmentWidth / 2) - (offset + patchHalfWidth)
		assert(
			math.max(leftLane, rightLane) >= MAGMA_MIN_WALKABLE_LANE,
			`ThemeHazardBuilder: magma patch {i} at offset {fraction} leaves only `
				.. `{string.format("%.1f", math.max(leftLane, rightLane))} studs of road on its widest side — `
				.. `a walking player could not get past it`
		)
	end

	-- 3. And the sideways move between consecutive patches has to be one a
	--    WALKING player can make in the time between them. See the note on
	--    MAGMA_MAX_LATERAL_STEP_FRACTION for where the budget comes from.
	for i = 1, #MAGMA_PATCH_LATERAL_OFFSETS - 1 do
		local step = math.abs(MAGMA_PATCH_LATERAL_OFFSETS[i + 1] - MAGMA_PATCH_LATERAL_OFFSETS[i])
		assert(
			step <= MAGMA_MAX_LATERAL_STEP_FRACTION + 1e-9,
			`ThemeHazardBuilder: magma patches {i} and {i + 1} are {string.format("%.2f", step)} of the road apart `
				.. `laterally, over the {MAGMA_MAX_LATERAL_STEP_FRACTION} a walking player can cover between them — `
				.. `the field would need jumping rather than steering`
		)
	end
end

-- Curve version of the field. The straight one lays patches along a single
-- CFrame's forward axis, which walks off a 90-degree arc within a chord or two —
-- so this samples the real curve and drops one patch per sample instead. Ends
-- are skipped: a curve's entry and exit are where the checkpoint triggers sit,
-- and a life-costing pool on a respawn plane kills a player the instant they
-- come back.
local function createCurveMagmaField(parent: Instance, entryCFrame: CFrame, patchCount: number)
	local samples = TrackPieceBuilder.SampleCurve(
		entryCFrame,
		TrackGeometry.CurveRadius,
		TrackGeometry.CurveArcDegrees,
		patchCount + 2
	)
	local patchWidth = TrackGeometry.SegmentWidth * MAGMA_PATCH_WIDTH_FRACTION
	local sampleSpacing = 2 * TrackGeometry.CurveRadius
		* math.sin(math.rad(TrackGeometry.CurveArcDegrees / (patchCount + 2)) / 2)
	local patchLength = math.max(6, sampleSpacing * 0.62)

	for i = 1, patchCount do
		local sample = samples[i + 1]
		if sample ~= nil then
			local fraction = MAGMA_PATCH_LATERAL_OFFSETS[((i - 1) % #MAGMA_PATCH_LATERAL_OFFSETS) + 1]
			createMagmaPatch(
				parent,
				sample * CFrame.new(fraction * TrackGeometry.SegmentWidth, 0, 0),
				patchWidth,
				patchLength
			)
		end
	end
end

local function createMagmaField(parent: Instance, centerCFrame: CFrame, spanLength: number, patchCount: number)
	local patchWidth = TrackGeometry.SegmentWidth * MAGMA_PATCH_WIDTH_FRACTION
	-- Floor lowered from 10 alongside the halved width, so that at the new,
	-- higher patch counts each patch still fits inside its own longitudinal slot
	-- with clear road either end of it. That one-patch-per-slot property is what
	-- guarantees there is always open road beside whatever is in front of you.
	local patchLength = math.max(6, (spanLength / patchCount) * 0.62)

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

-- ===== Falling blocks =====
--
-- Telegraphed blocks that drop out of the sky, cost a life on contact, then
-- despawn. Written for NeonCircuit and moved up here unchanged when Classic was
-- given the same hazard.
--
-- ## What is shared, and why that is the whole point
--
-- Detection is NOT touched: a block still carries a separate, larger,
-- non-collidable NeonBlockZone registered with ZoneHazardMonitor, and that
-- module's 0.5s point-in-box poll is what takes the life. That path was
-- measured working end to end on a live Neon curve (33 blocks entered, 215
-- samples genuinely inside a zone, lives drained on schedule), so it is
-- deliberately left exactly as it was — no contact events, no cooldown, no
-- change to ZoneHazardMonitor. An earlier attempt at this feature "improved"
-- that detection and broke the segment; the working mechanic is the asset here.
--
-- Only three things vary per theme: how many blocks a wave drops, how big they
-- are, and whether a patch of the segment is off limits. Everything else —
-- telegraph look and duration, spawn height, block lifetime, the zone, the
-- server pin, the landing feedback — is shared, because a red telegraph ring is
-- a lesson players learn once and must be able to trust everywhere.
--
-- Part names keep the Neon prefix on purpose: renaming them would change
-- nothing functionally but would make every live grep for "NeonFallingBlock"
-- silently miss half the falling blocks on the map.
local NEON_TELEGRAPH_SECONDS = 1.5
local NEON_BLOCK_LIFETIME_SECONDS = 3
-- One block every ~6-9s meant a player could cross a whole segment without
-- ever seeing one. Now a faster cycle AND several blocks per cycle, so the
-- segment is a continuous dodge rather than an occasional surprise.
local NEON_SPAWN_INTERVAL_SECONDS = 2.5
-- Fraction of the road width the drop spot is sampled across. Was 0.8, which
-- put every spot inside x = +/-28.8; with an 8-stud block that is a reach of 32.8
-- on a road whose barriers are at 36, so the outer 3 studs on each side were
-- never a target at all. On a hazard that is already random, a strip that is
-- structurally never hit is not "unlikely", it is a safe lane — and unlike the
-- Classic bar you can stand in it indefinitely. Sampling out to +/-32.4 lets a
-- block's own footprint reach past the barrier face on either side.
local NEON_SPAWN_WIDTH_FRACTION = 0.9

-- A recurring spawner over `spanLength` studs of `centerCFrame`'s segment. Each
-- wave telegraphs `blocksPerWave` random spots with a red ring for
-- NEON_TELEGRAPH_SECONDS, then drops a real `blockSize`-cubed falling block at
-- each. The loop self-terminates once `pieceModel` is destroyed (Regenerate())
-- — no explicit connection to clean up, unlike the Heartbeat-driven bars above.
--
-- `clearRadiusStuds` (optional) keeps drops OUT of a disc of that radius around
-- the segment centre, for a theme whose centre is already occupied by another
-- hazard — Classic's spinning bar. See its call site for why.
local function createFallingBlockField(
	pieceModel: Model,
	centerCFrame: CFrame,
	spanLength: number,
	blocksPerWave: number,
	blockSize: number,
	clearRadiusStuds: number?
)
	local halfSpan = spanLength / 2
	local halfSampleWidth = TrackGeometry.SegmentWidth * NEON_SPAWN_WIDTH_FRACTION / 2
	local clearRadius = clearRadiusStuds or 0

	-- Checked per call rather than once at module load, because blockSize is now
	-- a per-theme number: a smaller block narrows the reach and can reopen the
	-- very barrier-hugging lane this rule exists to close.
	assert(
		halfSampleWidth + blockSize / 2 >= REACHABLE_HALF_WIDTH,
		`ThemeHazardBuilder: {blockSize}-stud falling blocks can only reach x = +/-`
			.. `{string.format("%.1f", halfSampleWidth + blockSize / 2)} `
			.. `but a player can stand out to +/-{REACHABLE_HALF_WIDTH} — the barrier line is a permanently safe lane`
	)

	-- A keep-out disc eats into the field from every lateral position at once, so
	-- the field has to be long enough that a drop spot still exists on the
	-- CENTRELINE, where the disc bites deepest. Without this the sampler below
	-- would have nowhere legal to put a block for x near 0 and would quietly bias
	-- every wave to the road's edges.
	assert(
		clearRadius < halfSpan,
		`ThemeHazardBuilder: a {clearRadius}-stud keep-out radius leaves no room in a {spanLength}-stud `
			.. `falling-block field — the centreline would never be a drop target`
	)

	-- One wave = blocksPerWave independent telegraph->drop sequences fired at
	-- once at different spots. Split into its own function so each block keeps
	-- its own timing rather than the whole wave sharing one, and so waves can
	-- overlap.
	local function dropBlock()
		local lateralOffset = (math.random() - 0.5) * 2 * halfSampleWidth

		-- Solved, not rejection-sampled. For this lateral position the keep-out
		-- disc forbids everything nearer the centre than sqrt(r^2 - x^2), so the
		-- legal band is [that, halfSpan] on either side — pick uniformly inside it
		-- and flip a coin for which end. Rejection sampling would be simpler to
		-- write but can spin for an unbounded number of tries on the centreline,
		-- where the forbidden band is widest. With no keep-out this reduces to the
		-- original uniform draw across the whole span.
		local minLongitudinal = if lateralOffset * lateralOffset < clearRadius * clearRadius
			then math.sqrt(clearRadius * clearRadius - lateralOffset * lateralOffset)
			else 0
		local longitudinalOffset = minLongitudinal + math.random() * (halfSpan - minLongitudinal)
		if math.random() < 0.5 then
			longitudinalOffset = -longitudinalOffset
		end

		local spotCFrame = centerCFrame * CFrame.new(lateralOffset, 0, longitudinalOffset)

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
		block.Size = Vector3.new(blockSize, blockSize, blockSize)
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

		-- Landing feedback AND the hit itself, on one connection.
		--
		-- The crash is once-only: the fall time depends on what it lands ON
		-- (road, a jump platform, another block), so a fixed delay would play
		-- before or after the visible impact, and a block that bounces or gets
		-- shoved along the road should not crash repeatedly. It spawns 60 studs
		-- up, so there is nothing for it to be touching at birth.
		--
		-- The life loss is NOT once-only, and is deliberately not left to the
		-- zone poll alone. The block is CanCollide, so landing on someone ejects
		-- them well inside the 0.5s poll interval — measured on the shipped
		-- hazard, a block landing squarely on a stationary player cost a life
		-- 0/4 times. Contact is the moment that matters, so contact is what
		-- reports it. ZoneHazardMonitor owns the cooldown, so the ~20 limb
		-- touches of a single impact still cost exactly one life, and the zone
		-- registration below stays as well — it is what still catches a player
		-- who walks into an already-landed block, where nothing is moving enough
		-- to fire .Touched.
		local hasCrashed = false
		local touchConnection: RBXScriptConnection
		touchConnection = block.Touched:Connect(function(otherPart: BasePart)
			if not hasCrashed then
				hasCrashed = true
				SoundDirector.PlayAtPart(block, "BlockImpact")
				VisualEffectsService.ShowImpactBurst(block.Position, block.Color)
			end

			local hitPlayer = ZoneHazardMonitor.PlayerFromTouch(otherPart)
			if hitPlayer ~= nil then
				ZoneHazardMonitor.ReportContact(hitPlayer, block)
			end
		end)
		block.Destroying:Connect(function()
			touchConnection:Disconnect()
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
			for _ = 1, blocksPerWave do
				task.spawn(dropBlock)
			end
		end
	end)
end

-- ===== Shoving a player =====
--
-- Moves a character `studs` along `direction` over `seconds`, as a real
-- displacement rather than a knock.
--
-- Translation and not an impulse, for the reason DesertWindService and the
-- SkyRail curve both document from measurement: the Humanoid re-drives
-- horizontal velocity toward MoveDirection * WalkSpeed every physics step, so a
-- velocity or force applied to a controlled character is erased within a frame
-- or two. Writing the CFrame is the only push that survives.
--
-- Deliberately NOT a life-loss and NOT a stun: everything built on this is
-- meant to cost a racer distance, which is a real penalty in a race without
-- being an elimination.
local activePushToken: { [Player]: number } = {}
local pushCounter = 0

local function pushPlayer(player: Player, direction: Vector3, studs: number, seconds: number)
	if seconds <= 0 or studs <= 0 then
		return
	end

	-- A second shove replaces the first rather than stacking with it, so a
	-- player caught by two things at once is pushed once, not launched.
	pushCounter += 1
	local token = pushCounter
	activePushToken[player] = token

	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-4 then
		return
	end
	local unit = flat.Unit
	local speed = studs / seconds

	task.spawn(function()
		local elapsed = 0
		while elapsed < seconds do
			local dt = RunService.Heartbeat:Wait()
			if activePushToken[player] ~= token then
				return
			end
			local character = player.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if rootPart == nil then
				return
			end
			local step = math.min(dt, seconds - elapsed)
			rootPart.CFrame = rootPart.CFrame + unit * speed * step
			elapsed += dt
		end
		if activePushToken[player] == token then
			activePushToken[player] = nil
		end
	end)
end

-- True if `position` is inside the box `centerCFrame` +/- half `size`.
local function isInsideBox(position: Vector3, centerCFrame: CFrame, size: Vector3) : boolean
	local localPosition = centerCFrame:PointToObjectSpace(position)
	return math.abs(localPosition.X) <= size.X / 2
		and math.abs(localPosition.Y) <= size.Y / 2
		and math.abs(localPosition.Z) <= size.Z / 2
end

-- ===== "This player is on a Neon segment" state =====
--
-- A tracked player state, maintained the same way ZoneHazardMonitor maintains
-- its zones: each Neon piece registers its own volume, and one poll loop decides
-- who is standing in which. It is written to a player ATTRIBUTE as well as the
-- internal map, so "is this player on Neon right now" is answerable from
-- anywhere — the Explorer included — without re-deriving it from geometry.
--
-- Which piece a player is in is kept, not just whether they are in one: the
-- shove below is in/out relative to a ROAD's centreline, and two Neon pieces on
-- opposite sides of the oval face different ways, so a single global "outward"
-- would push half the field the wrong way.
local NEON_STATE_ATTRIBUTE = "OnNeonSegment"
local NEON_STATE_POLL_SECONDS = 0.25
local NEON_FIELD_HEIGHT_STUDS = 40

local neonFields: { [Model]: { Center: CFrame, Size: Vector3 } } = {}
local neonOccupant: { [Player]: Model } = {}
local neonTrackerStarted = false

local function startNeonOccupancyTracker()
	if neonTrackerStarted then
		return
	end
	neonTrackerStarted = true

	task.spawn(function()
		while true do
			for pieceModel in neonFields do
				if pieceModel.Parent == nil then
					neonFields[pieceModel] = nil
				end
			end

			for _, player in Players:GetPlayers() do
				local character = player.Character
				local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

				local occupied: Model? = nil
				if rootPart ~= nil then
					for pieceModel, field in neonFields do
						if isInsideBox(rootPart.Position, field.Center, field.Size) then
							occupied = pieceModel
							break
						end
					end
				end

				neonOccupant[player] = occupied
				player:SetAttribute(NEON_STATE_ATTRIBUTE, occupied ~= nil)
			end

			task.wait(NEON_STATE_POLL_SECONDS)
		end
	end)
end

Players.PlayerRemoving:Connect(function(player: Player)
	neonOccupant[player] = nil
end)

-- ===== The Neon gust =====
--
-- Its own hazard, on its own loop. It does not read the falling blocks, is not
-- triggered by them and is not aimed from them — it only reads the same two
-- timing constants they do, so that the two happen to land on the same beat.
--
-- What it does: shoves EVERY player currently in the OnNeonSegment state a few
-- studs sideways. Direction is IN toward the road's centreline or OUT toward the
-- barriers rather than left or right, because the road is symmetric — "left"
-- means the opposite thing to two racers on opposite sides of it, whereas in/out
-- is one decision that reads the same to everyone.
local NEON_GUST_MIN_STUDS = 6
local NEON_GUST_MAX_STUDS = 10
local NEON_GUST_PUSH_SECONDS = 0.4
local NEON_GUST_VISIBLE_SECONDS = 0.6
-- Emitters spread along the segment, so it reads as weather crossing the whole
-- road rather than a puff at one spot.
local NEON_GUST_EMITTERS = 3

-- Decoration ONLY. Nothing here moves anybody.
--
-- Driven by Rate rather than ParticleEmitter:Emit(), because Emit() does NOT
-- replicate from the server: the emitter parts were being created (18 of them,
-- measured) and no client ever saw a particle. A Rate write is an ordinary
-- property change and replicates like any other.
local function playGustEffect(parent: Instance, centerCFrame: CFrame, spanLength: number, spanWidth: number)
	local bursts: { BasePart } = {}
	for i = 1, NEON_GUST_EMITTERS do
		local alongTrack = ((i - 0.5) / NEON_GUST_EMITTERS - 0.5) * spanLength

		local burst = Instance.new("Part")
		burst.Anchored = true
		burst.CanCollide = false
		burst.CanQuery = false
		burst.CanTouch = false
		burst.Transparency = 1
		burst.Size = Vector3.new(spanWidth, 1, 1)
		burst.CFrame = centerCFrame * CFrame.new(0, 4, alongTrack)
		burst.Name = "NeonGust"
		burst.Parent = parent
		table.insert(bursts, burst)

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 120, 255), Color3.fromRGB(150, 60, 220))
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new(12, 30)
		emitter.Lifetime = NumberRange.new(0.5, 1.0)
		emitter.Speed = NumberRange.new(45, 75)
		emitter.SpreadAngle = Vector2.new(40, 25)
		emitter.LightEmission = 0.6
		emitter.Rate = 150
		emitter.Parent = burst
	end

	task.delay(NEON_GUST_VISIBLE_SECONDS, function()
		for _, burst in bursts do
			local emitter = burst:FindFirstChildOfClass("ParticleEmitter")
			if emitter ~= nil then
				emitter.Enabled = false
			end
		end
		-- Outlive the last particle so the burst fades rather than vanishing.
		task.delay(1.2, function()
			for _, burst in bursts do
				burst:Destroy()
			end
		end)
	end)
end

-- Moves everyone whose tracked state puts them on THIS piece.
local function shoveNeonOccupants(pieceModel: Model, centerCFrame: CFrame, outward: boolean)
	local studs = NEON_GUST_MIN_STUDS + math.random() * (NEON_GUST_MAX_STUDS - NEON_GUST_MIN_STUDS)

	for player, occupiedPiece in neonOccupant do
		if occupiedPiece ~= pieceModel then
			continue
		end

		local character = player.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart == nil then
			continue
		end

		-- Which side of the centreline they are already on decides what "out"
		-- means for them; "in" is simply the opposite.
		local lateralOffset = centerCFrame:PointToObjectSpace(rootPart.Position).X
		local awayFromCentre = if lateralOffset >= 0 then 1 else -1
		local direction = centerCFrame.RightVector * awayFromCentre * (if outward then 1 else -1)

		pushPlayer(player, direction, studs, NEON_GUST_PUSH_SECONDS)
	end
end

-- One wave of blocks lands in a single frame, but each block is a separate
-- instance, so the drop is seen as a burst of ChildAdded. Anything arriving
-- within this window of the last one is the same wave.
local NEON_GUST_WAVE_DEBOUNCE_SECONDS = 1

-- Registers the piece's volume for the state tracker, then arms the gust.
--
-- Timing is OBSERVED, not re-derived. The gust watches the piece for a block
-- appearing and takes that as its cue — it reads no block state, changes no
-- block, and the block code neither knows nor cares that anything is watching.
--
-- It was first written to re-run the block field's own interval and telegraph
-- constants on a parallel loop. That looked equivalent and was not: the block
-- loop jitters its interval by a random fraction of a second every cycle, so two
-- loops seeded the same drift apart immediately. Measured over 16 waves, the gap
-- between gust and drop wandered between 0.05s and 1.47s. Watching for the drop
-- makes them coincide by construction instead of by arithmetic that has to stay
-- in sync.
local function createNeonGust(pieceModel: Model, centerCFrame: CFrame, spanLength: number, spanWidth: number, chance: number)
	neonFields[pieceModel] = {
		Center = centerCFrame,
		Size = Vector3.new(spanWidth, NEON_FIELD_HEIGHT_STUDS, spanLength),
	}
	startNeonOccupancyTracker()

	-- One roll per WAVE, not per block: eight blocks land together and eight
	-- separate coin flips would make a gust near-certain every time.
	local lastWaveClock = 0

	pieceModel.ChildAdded:Connect(function(child: Instance)
		if child.Name ~= "NeonFallingBlock" then
			return
		end

		local now = os.clock()
		if now - lastWaveClock < NEON_GUST_WAVE_DEBOUNCE_SECONDS then
			return
		end
		lastWaveClock = now

		-- Fires at all on a coin flip, and picks its direction on a second,
		-- independent one.
		if math.random() >= chance then
			return
		end

		local outward = math.random() < 0.5
		shoveNeonOccupants(pieceModel, centerCFrame, outward)
		playGustEffect(pieceModel, centerCFrame, spanLength, spanWidth)
	end)
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
--
-- ===== Falling blocks, added on top of the bars =====
--
-- The bars alone left Classic far too soft. The straight in particular was ONE
-- obstacle across 180 studs, on a 3-second rotation, riding 4 studs above a road
-- a Roblox jump clears 7 studs over — a racer could stand still, watch a full
-- revolution and walk through, or simply jump it. Nothing to lose either way,
-- since a bar is a shove and costs nothing.
--
-- So the theme borrows NeonCircuit's falling blocks wholesale
-- (createFallingBlockField above), which adds the one thing the bars cannot: a
-- random, life-costing threat that cannot be waited out. Deliberately the SAME
-- mechanic rather than a new one — the red telegraph ring already means "move"
-- on Neon segments, and that lesson should mean the same thing everywhere.
local CLASSIC_BLOCKS_PER_WAVE = 4
-- Smaller than NeonCircuit's 8-stud cube. There the blocks ARE the segment and
-- should read as a wall of them; here they share the road with a 70-stud bar,
-- and full-size cubes leave too little floor to actually dodge on.
--
-- 6 is a floor, not a preference: NEON_SPAWN_WIDTH_FRACTION samples drop spots
-- out to x = +/-32.4, and the block's own half-width carries coverage the rest
-- of the way to the +/-35 a player can stand at. Below 6 the assert in
-- createFallingBlockField fires, because the barrier line becomes a lane no
-- block can ever reach. Going smaller means widening that fraction too.
local CLASSIC_BLOCK_SIZE = 6
-- Wider than NeonCircuit's 0.7 because the keep-out disc removes the middle of
-- the field: the drops need length outside the bar's sweep to land in.
local CLASSIC_BLOCK_SPAN_FRACTION = 0.8
-- Blocks drop just OUTSIDE the spinning bar's reach rather than through it.
--
-- Two reasons, one design and one mechanical. Design: overlapping the two
-- hazards makes one ambiguous mush in the middle of the segment, where the rest
-- of this module's hazards are deliberately sequential — you meet a thing, you
-- solve it, you meet the next. Keeping the drops off the bar's disc turns the
-- straight into three beats (blocks, bar, blocks) instead of one crowded one.
-- Mechanical: a landed block inside the sweep is a solid, unanchored,
-- CanCollide part sitting in the path of a rigidly-driven rotating bar, which is
-- the standing-contact case HAZARD_SPAN_WIDTH and the sweeper notes above both
-- exist to keep the physics solver out of.
--
-- Derived from the bar it is avoiding, not typed in: the bar's reach is half its
-- length, plus the block's own half-width so the block's FOOTPRINT clears the
-- sweep rather than just its centre, plus a stud of daylight.
local CLASSIC_BLOCK_BAR_CLEARANCE = 1

-- The curve cannot use a keep-out disc: its field is laid along the MIDDLE
-- chord's tangent, a chord is only ~35 studs long, and the disc needed to clear
-- the two bars is 39 — createFallingBlockField would assert. Lengthening the
-- field is not an option either, since past a chord or two the tangent leaves
-- the arc and blocks would drop off the road. So instead of one field with a
-- hole in it, the curve gets two small fields on the chords FLANKING the bars.
-- Chords 2 and 7 sit ~88 studs of arc from the bars at the middle (chords 4-5),
-- comfortably outside their 35-stud reach, and every drop lands on real paved
-- chord. Same three-beat reading as the straight, same 4 blocks per wave.
local CLASSIC_CURVE_BLOCK_CHORD_INDICES = { 2, 7 }
local CLASSIC_CURVE_BLOCKS_PER_CHORD = 2

local function buildClassic(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)
	local pivotCFrame = center * CFrame.new(0, TrackGeometry.BarrierHeight / 2, 0)

	if segment.SegmentType == "Straight" then
		createSpinningBar(pieceModel, pivotCFrame, TrackGeometry.HazardBarLength)
		createFallingBlockField(
			pieceModel,
			center,
			TrackGeometry.StraightLength * CLASSIC_BLOCK_SPAN_FRACTION,
			CLASSIC_BLOCKS_PER_WAVE,
			CLASSIC_BLOCK_SIZE,
			TrackGeometry.HazardBarLength / 2 + CLASSIC_BLOCK_SIZE / 2 + CLASSIC_BLOCK_BAR_CLEARANCE
		)
	else
		local lateralOffset = TrackGeometry.HazardBarLength / 4
		local smallBarLength = TrackGeometry.HazardBarLength / 2
		createSpinningBar(pieceModel, pivotCFrame * CFrame.new(lateralOffset, 0, 0), smallBarLength)
		createSpinningBar(pieceModel, pivotCFrame * CFrame.new(-lateralOffset, 0, 0), smallBarLength)

		-- Sampled from the same SampleCurve the piece's own RoadChord_* parts were
		-- built from, so a drop spot is guaranteed to sit over real paved chord
		-- rather than over the gap outside the arc.
		local samples = TrackPieceBuilder.SampleCurve(
			entryCFrame,
			TrackGeometry.CurveRadius,
			TrackGeometry.CurveArcDegrees,
			TrackGeometry.CurveSubdivisions
		)
		local chordLength = curveChordLength()

		for _, chordIndex in CLASSIC_CURVE_BLOCK_CHORD_INDICES do
			local chordCFrame = samples[chordIndex]
			if chordCFrame ~= nil then
				createFallingBlockField(
					pieceModel,
					chordCFrame,
					chordLength * 0.9,
					CLASSIC_CURVE_BLOCKS_PER_CHORD,
					CLASSIC_BLOCK_SIZE
				)
			end
		end
	end
end

-- HillMud: climbable (phaseable) stony walls + jump-over platforms.
--
-- Both wall heights are double what they were (straight 30 -> 60, curve
-- 15 -> 30), and both variants gained an extra wall so the segment is a
-- SEQUENCE of walls with gaps rather than one obstacle to get past. Each wall
-- still carries its own staircase (now a serpentine — a 60-stud wall needs 11
-- steps, which no longer fit across the road in a single run), and each gap
-- between walls carries a floating left/right pair, hanging in open air at half
-- wall height.
--
--   Straight: [wall 60] .. floaters .. [wall 60]
--   Curve   : [wall 30] .. floaters .. [wall 30] .. floaters .. [wall 30]
local HILLMUD_STRAIGHT_WALL_HEIGHT = 60
local HILLMUD_CURVE_WALL_HEIGHT = 30
-- Along-track separation of the straight's two walls, centred on the segment.
-- Wide enough that neither wall's staircase (which projects
-- JUMP_PLATFORM_APPROACH + rows * JUMP_PLATFORM_ROW_DEPTH studs toward the
-- entry) reaches the other wall or the floating pair between them.
local HILLMUD_STRAIGHT_WALL_SPACING = 60
-- Curve walls and floaters are placed on real sampled chords rather than at a
-- measured offset, so each one is guaranteed to sit over paved road on the arc.
-- Chords 7-8 are deliberately left empty: a curve's exit is where the checkpoint
-- trigger sits, and a wall there materialises respawning players inside it —
-- the same rule the old endClearance existed to enforce.
local HILLMUD_CURVE_WALL_CHORDS = { 2, 4, 6 }
local HILLMUD_CURVE_FLOATER_CHORDS = { 3, 5 }

local function buildHillMud(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType == "Straight" then
		local center = midpoint(entryCFrame, exitCFrame)
		local halfSpacing = HILLMUD_STRAIGHT_WALL_SPACING / 2

		for _, offsetZ in { halfSpacing, -halfSpacing } do
			local wallCFrame = center * CFrame.new(0, 0, offsetZ)
			createClimbWall(pieceModel, wallCFrame, HILLMUD_STRAIGHT_WALL_HEIGHT, true)
			addJumpPlatforms(pieceModel, wallCFrame, HILLMUD_STRAIGHT_WALL_HEIGHT, true)
			addWallTopPads(pieceModel, wallCFrame, HILLMUD_STRAIGHT_WALL_HEIGHT, true)
		end

		-- Wall-to-wall distance, not a shortened span: addBridgePlatforms spaces
		-- the crossing so the hop OFF the first wall and ON to the second are the
		-- same size as the hops between platforms.
		addBridgePlatforms(pieceModel, center, HILLMUD_STRAIGHT_WALL_HEIGHT, HILLMUD_STRAIGHT_WALL_SPACING)
	else
		local samples = TrackPieceBuilder.SampleCurve(
			entryCFrame,
			TrackGeometry.CurveRadius,
			TrackGeometry.CurveArcDegrees,
			TrackGeometry.CurveSubdivisions
		)
		local chordLength = curveChordLength()

		for _, chordIndex in HILLMUD_CURVE_WALL_CHORDS do
			local chordCFrame = samples[chordIndex]
			if chordCFrame ~= nil then
				createClimbWall(pieceModel, chordCFrame, HILLMUD_CURVE_WALL_HEIGHT, true)
				addJumpPlatforms(pieceModel, chordCFrame, HILLMUD_CURVE_WALL_HEIGHT, true)
				addWallTopPads(pieceModel, chordCFrame, HILLMUD_CURVE_WALL_HEIGHT, true)
			end
		end

		-- Walls sit two chords apart (chords 2, 4, 6), so each gap the crossing
		-- has to span is two chord lengths — NOT the one chord it is centred on.
		-- Passing the chord alone was what left the first hop 24 studs from the
		-- wall, three times what a jump clears.
		local curveWallGap = chordLength * 2
		for _, chordIndex in HILLMUD_CURVE_FLOATER_CHORDS do
			local chordCFrame = samples[chordIndex]
			if chordCFrame ~= nil then
				addBridgePlatforms(pieceModel, chordCFrame, HILLMUD_CURVE_WALL_HEIGHT, curveWallGap)
			end
		end
	end
end

-- ===== IceFrost: making the two routes cost the same =====
--
-- The theme's whole idea is a real choice between swimming and climbing, and a
-- choice is only real while neither option is simply better. So the numbers are
-- derived from the game's own movement data rather than picked.
--
-- Roblox drives swimming and climbing off the SAME Humanoid.WalkSpeed — there is
-- no separate swim or climb speed — and MovementModifier sets that from
-- BASE_WALK_SPEED (16) times a per-state multiplier that is 1 with no effects
-- active. So an unbuffed racer swims, climbs and runs at 16 studs/second, and
-- the routes can be compared directly.
--
--   Road route  : run the lane                162 / 16          = 10.13s
--                 + climb each wall            25 / 16          =  1.56s
--                 + drop off the far side  sqrt(2*25/196.2)     =  0.50s
--                 with ICEFROST_WALL_COUNT = 2 walls            = +4.13s
--                 ------------------------------------------------------
--                                                                 14.26s
--
--   Water route : swim the same 162 studs at 16                 = 10.13s
--                 which is 4.13s too quick, so the current has to take that
--                 back: 162 / 14.26 = 11.4 studs/s effective, i.e. the wave
--                 must remove 16 - 11.4 = ~4.6 studs/second on average.
--
-- A wave that pushes at ICEFROST_CURRENT_PUSH_SPEED for
-- ICEFROST_CURRENT_DURATION every ICEFROST_CURRENT_INTERVAL removes
-- (push * duration / interval) studs per second on average. Short and frequent
-- beats long and rare here: a crossing only lasts ~14s, so a slow cycle would
-- hit one racer twice and the next not at all.
local ICEFROST_WALL_COUNT = 2
local ICEFROST_CURRENT_INTERVAL = 5
local ICEFROST_CURRENT_DURATION = 1
-- Faster than a swimmer, so the wave is a genuine setback rather than a slow:
-- at 23 studs/s against a 16 studs/s swim the racer nets 7 studs BACKWARD per
-- second of wave. 23 * 1 / 5 = 4.6 studs/s average loss, which is the figure
-- derived above.
local ICEFROST_CURRENT_PUSH_SPEED = 23

-- IceFrost: two parallel lanes, split evenly across the full segment width with
-- no gap between or around them, so there's no dry strip a player could sneak
-- through untouched: left half is real water (Swimming) with a periodic wave
-- pushing back down it, right half is a run of NON-phaseable, gapless ice
-- TrussPart walls (Climbing only, "cannot phase through") standing on their own
-- solid road half. The water half's Road is removed (see destroyRoadForRebuild)
-- so players actually fall into the terrain water instead of walking over it.
--
-- A visible wave part sweeps back down the lane while the push is active. The
-- push would otherwise be an invisible hand: a racer needs to see it coming to
-- read it as a current rather than as the game misbehaving.
-- `swimmersOnly` gates the push on the Humanoid actually being in the Swimming
-- state. IceFrost does not need it — its lane is water end to end, and anything
-- inside the box is in the water by definition. WaterDock's bridged variant does:
-- the planks cross the same volume the wave sweeps, and a racer who chose the
-- narrow dry route should not be shoved off it by a current they are walking
-- over. Testing the swim state is what separates them; testing height would
-- break the moment a plank moved.
local function createCurrentWave(
	pieceModel: Model,
	laneCenterCFrame: CFrame,
	laneWidth: number,
	laneLength: number,
	pushSpeed: number,
	intervalSeconds: number,
	durationSeconds: number,
	swimmersOnly: boolean
)
	-- NEGATED LookVector. Track pieces are chained with -Z as forward (every
	-- placement in this module reads `CFrame.new(0, 0, -distanceAlongTrack)`),
	-- and CFrame.LookVector IS that -Z axis — so LookVector points the way the
	-- racer is going. Measured live before this negation: a swimmer in the lane
	-- was carried 70 studs FORWARD over 15 seconds, i.e. the "current" was a free
	-- ride down the fast route.
	local pushBackDirection = -laneCenterCFrame.LookVector

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(intervalSeconds)
			if pieceModel.Parent == nil then
				break
			end

			local wave = Instance.new("Part")
			wave.Anchored = true
			wave.CanCollide = false
			wave.CanQuery = false
			wave.CanTouch = false
			wave.Material = Enum.Material.Ice
			wave.Color = Color3.fromRGB(200, 235, 250)
			wave.Transparency = 0.45
			wave.Size = Vector3.new(laneWidth, 6, 6)
			wave.Name = "IceCurrentWave"
			wave.Parent = pieceModel

			local elapsed = 0
			while elapsed < durationSeconds and pieceModel.Parent ~= nil do
				local dt = RunService.Heartbeat:Wait()
				elapsed += dt

				-- The wave itself travels back down the lane over its lifetime,
				-- so it reads as one surge rolling through rather than a panel
				-- blinking on.
				local alpha = math.clamp(elapsed / durationSeconds, 0, 1)
				wave.CFrame = laneCenterCFrame * CFrame.new(0, 1, (alpha - 0.5) * laneLength)

				for _, player in Players:GetPlayers() do
					local character = player.Character
					local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if rootPart ~= nil and isInsideBox(rootPart.Position, laneCenterCFrame, Vector3.new(laneWidth, 40, laneLength)) then
						local swimming = true
						if swimmersOnly then
							local humanoid = character and character:FindFirstChildOfClass("Humanoid")
							swimming = humanoid ~= nil and humanoid:GetState() == Enum.HumanoidStateType.Swimming
						end
						if swimming then
							rootPart.CFrame = rootPart.CFrame + pushBackDirection * pushSpeed * dt
						end
					end
				end
			end

			wave:Destroy()
		end
	end)
end

-- ===== Snowballs, for the curve =====
--
-- Same shape of hazard as NeonCircuit's falling blocks — a recurring, telegraphed
-- thing that comes at you and is destroyed on contact — but deliberately NOT
-- registered with ZoneHazardMonitor, so it never costs a life. It shoves you
-- backwards instead. In a race, distance IS the penalty; not everything needs to
-- be lethal, and the curve already asks for a climb.
--
-- Each snowball rolls down a visible ramp ("the path") set into the outside of
-- the arc and crosses the road. Unanchored and physically rolling rather than
-- CFrame-driven, so it bounces off the road and the barriers like a real ball
-- and no two runs are identical.
local SNOWBALL_RADIUS = 5
local SNOWBALL_INTERVAL_SECONDS = 3
local SNOWBALL_LIFETIME_SECONDS = 8
-- How far back along the track the ramp reaches from the wall. With the wall at
-- 22 studs this is a ~20-degree slope: shallow enough that a ball keeps rolling
-- well past the bottom instead of stopping where the ramp ends.
local SNOWBALL_RAMP_RUN = 60
-- Wide enough to keep a 10-stud ball on the slope without being a road in its
-- own right.
local SNOWBALL_RAMP_WIDTH = 14
-- One ramp each side, this far off the centreline, leaving the middle of the
-- road as the gap a racer can aim for.
local SNOWBALL_RAMP_LATERAL = 18
-- Push a hit racer this far back, over this long. Chosen against the same
-- movement data as the ice current: 16 studs/s of running means ~14 studs is
-- roughly a second of lost progress — clearly felt, nowhere near a life.
local SNOWBALL_PUSH_STUDS = 14
local SNOWBALL_PUSH_SECONDS = 0.45

-- ===== Making the run unpredictable =====
--
-- Gravity alone down a fixed ramp gives every ball the same line, and a racer
-- who has seen the segment once simply walks around it. Two changes fix that
-- without adding a new mechanic:
--
--   1. The ball is launched rather than released, so it reaches the road with
--      real pace instead of trickling off the bottom of the slope.
--   2. The ball is made highly elastic, so the barriers and the ice wall it
--      meets throw it back across the road at an angle that depends on exactly
--      where it hit. That is what turns one predictable line into a scatter.
--
-- The elasticity lives on the BALL, with a heavy elasticityWeight, rather than
-- on the barriers. Roblox blends the two surfaces' elasticity by their weights,
-- so a heavily-weighted bouncy ball ricochets off ordinary scenery just as well
-- — and doing it this way keeps the change to this hazard. Raising the barriers'
-- own elasticity instead would also make PLAYERS bounce off the walls on this
-- segment, which is a much bigger gameplay change than was asked for.
local SNOWBALL_LAUNCH_SPEED = 45
local SNOWBALL_PHYSICAL_PROPERTIES = PhysicalProperties.new(
	0.6, -- density: light, so a bounce actually carries it
	0.15, -- friction: low, so it keeps rolling across the road
	0.85, -- elasticity
	1, -- frictionWeight
	50 -- elasticityWeight: dominates whatever it hits
)

-- `wallCFrame` is the ice wall the ramp hangs off; `sideX` is which side of the
-- road it sits on. The ramp descends from the TOP of that wall back down the
-- track toward the entry, so a ball released at the top rolls AGAINST the
-- direction of travel and meets racers head-on as they come up to the wall.
--
-- Rotation note: track pieces run with -Z forward, so +Z is back toward the
-- entry, and a positive rotation about X drops the +Z end. That is what tips the
-- ramp downhill in the direction we want the ball to go.
local function createSnowballRun(pieceModel: Model, wallCFrame: CFrame, wallHeight: number, sideX: number)
	local slope = math.atan2(wallHeight, SNOWBALL_RAMP_RUN)
	local rampLength = math.sqrt(wallHeight * wallHeight + SNOWBALL_RAMP_RUN * SNOWBALL_RAMP_RUN)

	local ramp = Instance.new("Part")
	ramp.Anchored = true
	ramp.CanCollide = true
	ramp.Material = Enum.Material.Ice
	ramp.Color = Color3.fromRGB(205, 232, 245)
	ramp.Size = Vector3.new(SNOWBALL_RAMP_WIDTH, 1, rampLength)
	ramp.CFrame = wallCFrame
		* CFrame.new(sideX, wallHeight / 2, SNOWBALL_RAMP_RUN / 2)
		* CFrame.Angles(slope, 0, 0)
	ramp.Name = "SnowballPath"
	ramp.Parent = pieceModel

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(SNOWBALL_INTERVAL_SECONDS + math.random())
			if pieceModel.Parent == nil then
				break
			end

			local ball = Instance.new("Part")
			ball.Shape = Enum.PartType.Ball
			ball.Anchored = false
			ball.CanCollide = true
			ball.Material = Enum.Material.Snow
			ball.Color = Color3.fromRGB(240, 248, 255)
			ball.Size = Vector3.new(SNOWBALL_RADIUS * 2, SNOWBALL_RADIUS * 2, SNOWBALL_RADIUS * 2)
			-- Released at the wall end of the ramp, sitting just above the slope
			-- so it settles onto it and rolls rather than spawning inside it.
			ball.CFrame = wallCFrame * CFrame.new(sideX, wallHeight + SNOWBALL_RADIUS, 2)
			ball.CustomPhysicalProperties = SNOWBALL_PHYSICAL_PROPERTIES
			ball.Name = "Snowball"
			-- Phaseable, so PhaseSelf is an answer to a badly-timed snowball the
			-- same way it is to Classic's spinning bar. The Hazards group still
			-- collides with the road, the barriers and non-phasing players, so
			-- the ball keeps rolling and bouncing exactly as before — the only
			-- thing it stops colliding with is a phasing player and other
			-- hazards (and not colliding means no .Touched, so no shove either,
			-- which is the intended escape).
			CollisionTags.MarkPhaseable(ball)
			ball.Parent = pieceModel

			-- Server-owned for the same reason the falling blocks are: what this
			-- thing hits decides whether a racer loses ground.
			pinPhysicsToServer(ball)

			-- Launched down the slope, not dropped onto it. The downhill unit
			-- vector is the backward track direction tipped down by the ramp
			-- angle — derived from the wall's own frame so it stays correct on
			-- any part of the arc. Set AFTER pinPhysicsToServer so the velocity
			-- is applied to an assembly the server already owns.
			local downhill = (-wallCFrame.LookVector) * math.cos(slope) + Vector3.new(0, -1, 0) * math.sin(slope)
			ball.AssemblyLinearVelocity = downhill.Unit * SNOWBALL_LAUNCH_SPEED

			local spent = false
			local touchConnection: RBXScriptConnection
			touchConnection = ball.Touched:Connect(function(otherPart: BasePart)
				if spent then
					return
				end
				local hitPlayer = ZoneHazardMonitor.PlayerFromTouch(otherPart)
				if hitPlayer == nil then
					return
				end

				spent = true
				touchConnection:Disconnect()

				-- Backwards along the track, away from the direction of travel.
				-- Negated for the same reason the ice current is: LookVector is
				-- the way the racer is HEADING, so pushing along it would help.
				pushPlayer(hitPlayer, -wallCFrame.LookVector, SNOWBALL_PUSH_STUDS, SNOWBALL_PUSH_SECONDS)

				-- Disintegrates on impact rather than carrying on through.
				SoundDirector.PlayAtPart(ball, "BlockImpact")
				VisualEffectsService.ShowImpactBurst(ball.Position, ball.Color)
				ball:Destroy()
			end)

			task.delay(SNOWBALL_LIFETIME_SECONDS, function()
				if ball.Parent ~= nil then
					ball:Destroy()
				end
			end)
		end
	end)
end


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

		-- The wall alone was the entire curve: one obstacle across a 90-degree
		-- arc, with nothing before or after it. Two ramps now run off the TOP of
		-- that wall, one per side, back down the track toward the entry — so the
		-- snowballs they release roll against the direction of travel and meet
		-- racers on the approach, with the gap between the two ramps as the line
		-- to aim for.
		for _, sideX in { -SNOWBALL_RAMP_LATERAL, SNOWBALL_RAMP_LATERAL } do
			createSnowballRun(pieceModel, curveCenter, wallHeight, sideX)
		end
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
	-- Walls spread evenly along the lane so the climb route is a repeated cost
	-- rather than one obstacle, which is what makes the swim a real alternative
	-- rather than the obviously slower option.
	for i = 1, ICEFROST_WALL_COUNT do
		local alongTrack = ((i - 0.5) / ICEFROST_WALL_COUNT - 0.5) * laneLength
		createClimbWall(
			pieceModel,
			center * CFrame.new(halfWidth / 2, 0, alongTrack),
			wallHeight,
			false,
			halfWidth
		)
	end

	-- And the water half gets the matching cost: a wave down the lane, timed to
	-- remove exactly the seconds the walls cost. See the derivation above.
	-- swimmersOnly is false here: this lane is water end to end, so anything
	-- inside the box is already in it.
	createCurrentWave(
		pieceModel,
		center * CFrame.new(-halfWidth / 2, 0, 0),
		halfWidth,
		laneLength,
		ICEFROST_CURRENT_PUSH_SPEED,
		ICEFROST_CURRENT_INTERVAL,
		ICEFROST_CURRENT_DURATION,
		false
	)
end

-- Volcanic: a magma field you steer through, plus a rank of sweeper bars you
-- jump. The two hazards are deliberately answered by different actions — magma
-- is full-length but never full-width, sweepers are full-width but low — so the
-- segment asks for both at once instead of one thing twice.
--
-- Both variants now carry both. The curve used to be three magma patches and
-- nothing else across a whole 90-degree arc; it gets a clock sweep (see
-- createCurveSweeperBar) which is the arc's equivalent of the straight's rank.
local VOLCANIC_STRAIGHT_MAGMA_PATCHES = 10
local VOLCANIC_CURVE_MAGMA_PATCHES = 8
-- Three bars, evenly spread through one travel cycle, all travelling against the
-- racer. Was four oscillating, which meant two of them were always running WITH
-- the racer and overtaking from behind.
local VOLCANIC_SWEEPER_COUNT = 3

local function buildVolcanic(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)

	if segment.SegmentType == "Straight" then
		createMagmaField(pieceModel, center, TrackGeometry.StraightLength * 0.72, VOLCANIC_STRAIGHT_MAGMA_PATCHES)
		createSweeperRank(
			pieceModel,
			entryCFrame,
			exitCFrame,
			TrackGeometry.StraightLength * 0.8,
			VOLCANIC_SWEEPER_COUNT,
			true
		)
	else
		createCurveMagmaField(pieceModel, entryCFrame, VOLCANIC_CURVE_MAGMA_PATCHES)
		createCurveSweeperRank(pieceModel, entryCFrame, VOLCANIC_SWEEPER_COUNT)
	end
end

-- Decorative low rim (CanCollide = false) that visually "encloses" a pool
-- without ever risking blocking a player's path across the segment.
-- Depth along the track of a pool rim. Doubled from 1, and the rims are now
-- SOLID rather than decoration — they are meant to be stood on: something to
-- climb out onto, and the one place jumping still works while the rest of the
-- pool suppresses it (see MovementModifier's swimming branch).
local POOL_RIM_DEPTH = 2

local function addPoolRim(parent: Instance, poolCenterCFrame: CFrame, poolWidth: number, poolLength: number)
	local halfLength = poolLength / 2
	for _, offsetZ in { halfLength, -halfLength } do
		local rim = Instance.new("Part")
		rim.Anchored = true
		rim.CanCollide = true
		rim.Material = Enum.Material.WoodPlanks
		rim.Color = Color3.fromRGB(90, 70, 50)
		rim.Size = Vector3.new(poolWidth, 1.5, POOL_RIM_DEPTH)
		rim.CFrame = poolCenterCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 + 0.75, offsetZ)
		rim.Name = "WaterDockEnclosure"
		rim.Parent = parent
	end
end

-- Curve version: `count` catwalks running the LENGTH of the pond, spread across
-- its width.
--
-- Two things were wrong with the first attempt, and they compound. It placed
-- rims per chord, which gave FOUR at three distinct positions — the two middle
-- chords share a boundary, so one spot got a rim from each side stacked on
-- itself. And it laid them ACROSS the road, like the straight's pool edges: a
-- 2-stud strip perpendicular to travel, with ~25 studs of open water between
-- consecutive ones. Measured correct against the road, and useless — nothing a
-- player can cross, since 25 studs is three times a jump.
--
-- Turned 90 degrees they become what they were meant to be: narrow planks
-- running the way a racer travels, so each one is a continuous walkable route
-- from one side of the pond to the other. Choosing a plank and staying on it is
-- now a real alternative to swimming, and the gaps between them are lateral —
-- something you steer around rather than a chasm.
--
-- ===== Why the planks are laid along the ARC and not per chord =====
--
-- The first version built one plank per removed chord at a fixed lateral offset,
-- reasoning that a single straight slab across both chords would leave the road.
-- True, but per-chord is not the fix: consecutive chords are rotated against each
-- other by (arcDegrees / subdivisions), so two planks at the SAME lateral offset
-- on adjacent chords do not line up — the offset is measured in each chord's own
-- frame, and those frames differ. The displacement is offset * sin(angle), which
-- at +/-25 studs on an 11.25-degree step is about 5 studs.
--
-- Measured on the built track, the three lanes came out at lateral offsets
-- -25, -21, 0, 3, 25, 28: a ~5-stud sideways jog exactly where the two chords
-- meet. On a 2-stud-wide plank that is not a seam, it is a break — the outer
-- catwalks were impassable at the join, which is the whole point of them.
--
-- Laying short segments along the real arc removes the problem rather than
-- tuning it: every segment is placed by the same makeCurveArcPoser the wave uses,
-- at a constant lateral offset from the road's centreline, so a lane is
-- continuous by construction no matter how the arc is subdivided.
local POOL_RIM_ARC_SEGMENTS = 10

local function addCurvePoolRims(parent: Instance, entryCFrame: CFrame, poolWidth: number, count: number)
	if count < 1 then
		return
	end

	local arcPose = makeCurveArcPoser(entryCFrame)
	local subdivisions = TrackGeometry.CurveSubdivisions
	local firstChord = CURVE_MIDDLE_CHORD_INDICES[1]
	local lastChord = CURVE_MIDDLE_CHORD_INDICES[#CURVE_MIDDLE_CHORD_INDICES]
	local alphaStart = (firstChord - 1) / subdivisions
	local alphaEnd = lastChord / subdivisions

	-- Each segment spans one slice of the pond's arc, plus a little overlap so
	-- neighbours meet without a lip.
	local arcLength = TrackGeometry.CurveRadius * math.rad(TrackGeometry.CurveArcDegrees)
	local segmentLength = arcLength * (alphaEnd - alphaStart) / POOL_RIM_ARC_SEGMENTS + 1

	-- Spread the lanes across the road, leaving water either side of each.
	local usableWidth = poolWidth * 0.7

	for laneIndex = 1, count do
		local lateral = if count == 1 then 0 else ((laneIndex - 1) / (count - 1) - 0.5) * usableWidth

		for i = 1, POOL_RIM_ARC_SEGMENTS do
			local alpha = alphaStart + (alphaEnd - alphaStart) * ((i - 0.5) / POOL_RIM_ARC_SEGMENTS)

			local rim = Instance.new("Part")
			rim.Anchored = true
			rim.CanCollide = true
			rim.Material = Enum.Material.WoodPlanks
			rim.Color = Color3.fromRGB(90, 70, 50)
			-- X is the plank's WIDTH (narrow), Z its LENGTH along the track — the
			-- swap that turning it 90 degrees amounts to.
			rim.Size = Vector3.new(POOL_RIM_DEPTH, 1.5, segmentLength)
			rim.CFrame = arcPose(alpha) * CFrame.new(lateral, TrackGeometry.RoadThickness / 2 + 0.75, 0)
			rim.Name = "WaterDockEnclosure"
			rim.Parent = parent
		end
	end
end

-- WaterDock: straight only. Two variants picked at random per segment —
-- (A) a big ¾-length pool forcing a straight swim across, (B) a small
-- ¼-length pool with 2 narrow bridges to cross (or fall in and swim). Both
-- variants cut the Road out full-width under the pool (see
-- destroyRoadForRebuild) so the pool is a real gap players fall into,
-- not terrain water hidden under a still-solid road slab.
-- ===== WaterDock's currents =====
--
-- Variant B (small pool, plank bridges) gets ONE wave over the whole pool at
-- IceFrost strength. The planks are the dry alternative, so a swimmer being set
-- back is what makes choosing them worth something — and swimmersOnly keeps the
-- wave off anyone who took that route.
--
-- Variant A (the big swim, no bridges) is different: there is no alternative
-- route, so a single wave down the whole length is just a flat tax with nothing
-- to read. Instead the pool is cut into ICEFROST-strength regions and only TWO
-- of them surge at a time, chosen at random each cycle. That gives a swimmer
-- something to look at and swim around — the safe part of the pool moves — and
-- at DOUBLE push speed the regions that are running are worth avoiding.
local WATERDOCK_CURVE_RIM_COUNT = 3
local WATERDOCK_POOL_REGIONS = 6
local WATERDOCK_ACTIVE_REGIONS = 2
local WATERDOCK_REGION_PUSH_SPEED = ICEFROST_CURRENT_PUSH_SPEED * 2
local WATERDOCK_REGION_INTERVAL = ICEFROST_CURRENT_INTERVAL
local WATERDOCK_REGION_DURATION = ICEFROST_CURRENT_DURATION

-- Drives the surges. The pool is divided ALONG the path — six lanes running the
-- full length of the pool, side by side across its width — and two of them surge
-- at a time.
--
-- The first version sliced the pool the other way, into six bands stacked down
-- its length. That is the wrong axis for this: a band spanning the full width
-- cannot be avoided, so a swimmer's only option was to wait it out, and the six
-- divisions did nothing that one wave would not have done. Lanes are avoidable —
-- the two that are running are water to stay out of, and which two changes every
-- cycle, so the safe route across the pool moves.
--
-- Within a lane the surge travels from the far end to the near one, i.e. the
-- same direction it pushes, so it reads as a head-on current rolling down the
-- lane rather than a block of water switching on.
--
-- One loop for the whole pool rather than a loop per lane: "two at a time,
-- chosen fresh each cycle" is a property of the POOL, and independent lane loops
-- would drift out of step and end up with all six or none running at once.
local function createRegionalPoolCurrent(pieceModel: Model, poolCenterCFrame: CFrame, poolWidth: number, poolLength: number)
	local laneWidth = poolWidth / WATERDOCK_POOL_REGIONS
	local pushBackDirection = -poolCenterCFrame.LookVector

	local laneCFrames: { CFrame } = {}
	for i = 1, WATERDOCK_POOL_REGIONS do
		local lateral = ((i - 0.5) / WATERDOCK_POOL_REGIONS - 0.5) * poolWidth
		table.insert(laneCFrames, poolCenterCFrame * CFrame.new(lateral, 0, 0))
	end

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(WATERDOCK_REGION_INTERVAL)
			if pieceModel.Parent == nil then
				break
			end

			-- Fresh random pick each cycle, without replacement.
			local order = {}
			for i = 1, WATERDOCK_POOL_REGIONS do
				table.insert(order, i)
			end
			for i = #order, 2, -1 do
				local j = math.random(1, i)
				order[i], order[j] = order[j], order[i]
			end

			local waves: { BasePart } = {}
			local active: { CFrame } = {}
			for i = 1, math.min(WATERDOCK_ACTIVE_REGIONS, #order) do
				local laneCFrame = laneCFrames[order[i]]
				table.insert(active, laneCFrame)

				local wave = Instance.new("Part")
				wave.Anchored = true
				wave.CanCollide = false
				wave.CanQuery = false
				wave.CanTouch = false
				wave.Material = Enum.Material.Water
				wave.Color = Color3.fromRGB(120, 190, 220)
				wave.Transparency = 0.4
				-- Narrow across (one lane) and short along the track: this is a
				-- crest that travels, not a slab that covers the lane.
				wave.Size = Vector3.new(laneWidth, 5, 8)
				wave.CFrame = laneCFrame * CFrame.new(0, 1, -poolLength / 2)
				wave.Name = "WaterDockSurge"
				wave.Parent = pieceModel
				table.insert(waves, wave)
			end

			local elapsed = 0
			while elapsed < WATERDOCK_REGION_DURATION and pieceModel.Parent ~= nil do
				local dt = RunService.Heartbeat:Wait()
				elapsed += dt

				-- Crest runs from the far end of the pool back toward the entry,
				-- travelling the way it pushes.
				local alpha = math.clamp(elapsed / WATERDOCK_REGION_DURATION, 0, 1)
				for waveIndex, wave in waves do
					wave.CFrame = active[waveIndex] * CFrame.new(0, 1, (alpha - 0.5) * poolLength)
				end

				for _, player in Players:GetPlayers() do
					local character = player.Character
					local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if rootPart == nil or humanoid == nil or humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
						continue
					end
					for _, laneCFrame in active do
						if isInsideBox(rootPart.Position, laneCFrame, Vector3.new(laneWidth, 40, poolLength)) then
							rootPart.CFrame = rootPart.CFrame + pushBackDirection * WATERDOCK_REGION_PUSH_SPEED * dt
							break
						end
					end
				end
			end

			for _, wave in waves do
				wave:Destroy()
			end
		end
	end)
end

-- The curve pond's wave. Same idea as the straight's surge, but a pond on a
-- curve has no straight line to roll down, so the crest follows the ARC — the
-- same centre-of-circle path Volcanic's clock sweep uses (makeCurveArcPoser),
-- reused rather than re-derived.
--
-- The crest spans the full road width and travels from the pond's far edge back
-- toward its near one: head-on, the direction it pushes. The walkable planks are
-- unaffected because the push is gated on the Swimming state, exactly as on the
-- bridged straight.
local function createCurvePoolCurrent(pieceModel: Model, entryCFrame: CFrame, poolWidth: number)
	local arcPose = makeCurveArcPoser(entryCFrame)

	-- The pond covers CURVE_MIDDLE_CHORD_INDICES of CurveSubdivisions chords, so
	-- it occupies that fraction of the arc. Derived from the same constant that
	-- decides which chords get removed, so the wave can never sweep a stretch
	-- that is still solid road.
	local subdivisions = TrackGeometry.CurveSubdivisions
	local firstChord = CURVE_MIDDLE_CHORD_INDICES[1]
	local lastChord = CURVE_MIDDLE_CHORD_INDICES[#CURVE_MIDDLE_CHORD_INDICES]
	local alphaStart = (firstChord - 1) / subdivisions
	local alphaEnd = lastChord / subdivisions

	local crestDepth = 12
	local pushBackAt = function(alpha: number) : Vector3
		return -arcPose(alpha).LookVector
	end

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(WATERDOCK_REGION_INTERVAL)
			if pieceModel.Parent == nil then
				break
			end

			local wave = Instance.new("Part")
			wave.Anchored = true
			wave.CanCollide = false
			wave.CanQuery = false
			wave.CanTouch = false
			wave.Material = Enum.Material.Water
			wave.Color = Color3.fromRGB(120, 190, 220)
			wave.Transparency = 0.4
			wave.Size = Vector3.new(poolWidth, 5, crestDepth)
			wave.CFrame = arcPose(alphaEnd) * CFrame.new(0, 1, 0)
			wave.Name = "WaterDockSurge"
			wave.Parent = pieceModel

			local elapsed = 0
			while elapsed < WATERDOCK_REGION_DURATION and pieceModel.Parent ~= nil do
				local dt = RunService.Heartbeat:Wait()
				elapsed += dt

				-- alphaEnd -> alphaStart: the far edge of the pond back toward the
				-- near one, i.e. against the racer.
				local progress = math.clamp(elapsed / WATERDOCK_REGION_DURATION, 0, 1)
				local alpha = alphaEnd + (alphaStart - alphaEnd) * progress
				local crest = arcPose(alpha)
				wave.CFrame = crest * CFrame.new(0, 1, 0)

				local pushDirection = pushBackAt(alpha)
				for _, player in Players:GetPlayers() do
					local character = player.Character
					local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if rootPart == nil or humanoid == nil or humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
						continue
					end
					if isInsideBox(rootPart.Position, crest, Vector3.new(poolWidth, 40, crestDepth)) then
						rootPart.CFrame = rootPart.CFrame + pushDirection * WATERDOCK_REGION_PUSH_SPEED * dt
					end
				end
			end

			wave:Destroy()
		end
	end)
end

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
		end

		-- Rims are laid across the pond as a whole, not two per chord. Per-chord
		-- placement gave four rims at three positions (the middle chords share a
		-- boundary, so one spot got two stacked). Three evenly spread, solid and
		-- twice as deep, are something to stand on: the way out of the water, and
		-- the one place a jump still works while swimming.
		addCurvePoolRims(pieceModel, entryCFrame, TrackGeometry.SegmentWidth, WATERDOCK_CURVE_RIM_COUNT)

		-- And the pond gets the same current the straights have, following the
		-- arc rather than a straight line.
		createCurvePoolCurrent(pieceModel, entryCFrame, TrackGeometry.SegmentWidth)
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
		local poolLength = TrackGeometry.StraightLength * 0.75
		buildPool(poolLength)

		-- No bridges here, so a single wave down the whole pool would be a flat
		-- tax with nothing to read. Six regions, two surging at a time, picked
		-- fresh each cycle: the safe water moves, and a swimmer has something to
		-- steer around. Double push speed, since dodging it is possible.
		createRegionalPoolCurrent(pieceModel, center, poolWidth, poolLength)
	else
		-- Variant B: small pool, 2 narrow bridges across it.
		local poolLength = TrackGeometry.StraightLength * 0.25
		buildPool(poolLength)

		-- One wave over the whole pool at IceFrost strength, gated to SWIMMERS —
		-- the planks cross this same volume, and a racer who took the narrow dry
		-- route should not be shoved off it by a current they are walking over.
		-- That gating is what makes the bridges worth choosing.
		createCurrentWave(
			pieceModel,
			center,
			poolWidth,
			poolLength,
			ICEFROST_CURRENT_PUSH_SPEED,
			ICEFROST_CURRENT_INTERVAL,
			ICEFROST_CURRENT_DURATION,
			true
		)

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
-- Steps are steeper and shorter than they were (rise 1.6 over a 36-stud run,
-- which cost 7 steps per flight and 72 studs of the segment). The elevated
-- section is the interesting part of this theme and the stairs were eating
-- nearly half the straight to reach it; at 2.5 a flight is 4 steps over 18
-- studs, which frees 36 studs for two more bridges.
--
-- 2.5 per step is still a walk-up, not a jump-up: a Roblox jump clears ~6.4
-- studs, so each step is comfortably inside one even without a run at it.
local SKYRAIL_STEP_RISE = 2.5
local SKYRAIL_BRIDGE_HEIGHT = 10
local SKYRAIL_APPROACH_LENGTH = 24
local SKYRAIL_STEP_RUN_LENGTH = 18

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
-- The elevated section is a run of equal decks. Only the two at the ENDS are
-- solid bridges — the landing off the step flight and the launch onto the one
-- down. Everything between them moves.
--
-- It was previously alternating (bridge, mover, bridge, mover, ...), which gave a
-- racer a static foothold every other deck and turned the crossing into a series
-- of independent single hops with a rest between each. With the middle all
-- movers it becomes one continuous timed run: you commit at the first bridge and
-- do not get solid ground again until the last.
local SKYRAIL_ELEVATED_DECK_COUNT = 7
local SKYRAIL_MOVER_GAP = 2
-- Half the journey, so a deck travels twice this. Was 5 (a 9.8-stud span
-- measured live); 10 gives the 20 studs asked for.
local SKYRAIL_MOVER_TRAVEL = 10
-- Movers swing about a centre ABOVE the bridges, not level with them.
--
-- createMovingPlatform swings symmetrically about the CFrame it is given, so
-- centring a 20-stud stroke on the 10-stud bridge height would put the bottom of
-- that stroke at Y = 0 — ground level, inside the chasm the segment carves. The
-- assert below caught exactly that on the first build, which is the failure the
-- brief asked to watch for.
--
-- Raising the centre keeps the full 20 studs without dropping a rider into the
-- floor. The stroke still PASSES THROUGH bridge height on every cycle, so
-- boarding from a bridge is a matter of timing rather than of reach — which is
-- what the movers are for. Bottom of the stroke clears the chasm floor by
-- SKYRAIL_MOVER_FLOOR_CLEARANCE.
local SKYRAIL_MOVER_FLOOR_CLEARANCE = 4
local SKYRAIL_MOVER_CENTRE_HEIGHT = SKYRAIL_MOVER_TRAVEL + SKYRAIL_MOVER_FLOOR_CLEARANCE
-- Railings. Purely visual (CanCollide = false): they are what makes the deck
-- read as a bridge from a distance, but a solid rail would also remove the
-- risk of falling, which is the entire point of the theme.
local SKYRAIL_RAIL_HEIGHT = 2.5
local SKYRAIL_RAIL_THICKNESS = 0.5

-- Splits the elevated span into SKYRAIL_ELEVATED_DECK_COUNT equal decks with a
-- gap between each. They share the span equally so no deck is a different size
-- from its neighbours — the rhythm of the crossing is the point.
local function skyRailElevatedLayout(length: number)
	local climbStartZ = SKYRAIL_APPROACH_LENGTH
	local elevatedStartZ = climbStartZ + SKYRAIL_STEP_RUN_LENGTH
	local descendStartZ = length - SKYRAIL_APPROACH_LENGTH - SKYRAIL_STEP_RUN_LENGTH
	local elevatedSpan = descendStartZ - elevatedStartZ

	local deckCount = SKYRAIL_ELEVATED_DECK_COUNT
	local gapCount = deckCount - 1
	local deckLength = (elevatedSpan - gapCount * SKYRAIL_MOVER_GAP) / deckCount

	return climbStartZ, elevatedStartZ, descendStartZ, elevatedSpan, deckCount, deckLength
end

do
	local _, _, _, _, deckCount, deckLength = skyRailElevatedLayout(TrackGeometry.StraightLength)
	assert(
		deckLength > SKYRAIL_PATH_WIDTH,
		`ThemeHazardBuilder: SkyRail packs {deckCount} decks into the elevated span, leaving each `
			.. `{string.format("%.1f", deckLength)} studs along the track against {string.format("%.1f", SKYRAIL_PATH_WIDTH)} `
			.. `across it — wider than it is long reads as a bar laid across the track, not a bridge. `
			.. `Either fewer bridges, or shorter step flights to lengthen the elevated span.`
	)

	-- The bottom of a mover's stroke must clear the chasm floor, or a rider is
	-- carried straight into it.
	assert(
		SKYRAIL_MOVER_CENTRE_HEIGHT - SKYRAIL_MOVER_TRAVEL > 0,
		`ThemeHazardBuilder: SkyRail movers swing {SKYRAIL_MOVER_TRAVEL} studs either side of `
			.. `{SKYRAIL_MOVER_CENTRE_HEIGHT}, so the bottom of the stroke is at or below ground — `
			.. `a rider would be carried into the chasm floor`
	)

	-- And the stroke has to REACH the bridges, or the movers are scenery a racer
	-- can never board.
	assert(
		SKYRAIL_MOVER_CENTRE_HEIGHT - SKYRAIL_MOVER_TRAVEL <= SKYRAIL_BRIDGE_HEIGHT
			and SKYRAIL_BRIDGE_HEIGHT <= SKYRAIL_MOVER_CENTRE_HEIGHT + SKYRAIL_MOVER_TRAVEL,
		`ThemeHazardBuilder: SkyRail movers travel between `
			.. `{SKYRAIL_MOVER_CENTRE_HEIGHT - SKYRAIL_MOVER_TRAVEL} and `
			.. `{SKYRAIL_MOVER_CENTRE_HEIGHT + SKYRAIL_MOVER_TRAVEL} studs but the bridges sit at `
			.. `{SKYRAIL_BRIDGE_HEIGHT} — the stroke never passes the bridges, so there is no way on or off`
	)
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

	local climbStartZ, elevatedStartZ, descendStartZ, elevatedSpan, deckCount, deckLength =
		skyRailElevatedLayout(length)
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

	-- Elevated span: solid bridges at the two ENDS only, everything between them
	-- moving. Every deck is longer along the track than it is wide across it —
	-- see the assertion by skyRailElevatedLayout for why that is load-bearing
	-- rather than cosmetic.
	local moverIndex = 0
	for deck = 1, deckCount do
		local isBridge = deck == 1 or deck == deckCount
		local deckStartZ = elevatedStartZ + (deck - 1) * (deckLength + SKYRAIL_MOVER_GAP)
		-- Bridges sit at bridge height; movers swing about a higher centre so a
		-- full 20-stud stroke still clears the chasm floor. See
		-- SKYRAIL_MOVER_CENTRE_HEIGHT.
		local deckHeight = if isBridge then SKYRAIL_BRIDGE_HEIGHT else SKYRAIL_MOVER_CENTRE_HEIGHT
		local deckCFrame = entryCFrame * CFrame.new(0, deckHeight, -(deckStartZ + deckLength / 2))

		if isBridge then
			local bridge = Instance.new("Part")
			bridge.Anchored = true
			bridge.CanCollide = true
			bridge.Material = Enum.Material.Metal
			bridge.Color = Color3.fromRGB(180, 180, 190)
			bridge.Size = Vector3.new(pathWidth, 1, deckLength)
			bridge.CFrame = deckCFrame
			bridge.Name = "SkyRailBridge"
			bridge.Parent = pieceModel

			addDeckRailings(pieceModel, deckCFrame, pathWidth, deckLength)
		else
			moverIndex += 1
			createMovingPlatform(
				pieceModel,
				deckCFrame,
				Vector3.new(pathWidth, 1, deckLength),
				Vector3.new(0, SKYRAIL_MOVER_TRAVEL, 0),
				2.5,
				-- Alternating phases, so consecutive movers are never level with
				-- each other and the crossing stays a sequence of timed hops.
				(moverIndex % 2) * 0.5
			)
		end
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
-- That history is kept because it explains the shape of the problem, but the
-- ledge itself is GONE. Narrowing it and moving it outside made the two routes
-- trade against each other, which was an improvement, but it still left a way to
-- cross without ever setting foot on a deck. The chasm is now barrier to barrier
-- and the decks are the only crossing — so the segment asks a racer to ride it
-- rather than offering a route around it.

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
-- ===== The curve now sweeps SIDEWAYS after all =====
--
-- Everything above is the record of why it could not, and none of it was wrong:
-- a laterally-moving deck cannot carry a rider by friction, because the Humanoid
-- re-drives horizontal velocity every physics step. What has changed is that
-- createMovingPlatform now carries its riders EXPLICITLY — it moves anyone
-- standing on a deck by the same delta the deck moved, as a CFrame write, which
-- is the one thing the Humanoid does not stomp. See the rider-carry block there.
--
-- With that in place the sideways sweep is the better mechanic for a curve: the
-- decks cross the racing line rather than bobbing in it, so a racer has to read
-- where a deck WILL be, and the lane they want opens and closes.
--
-- Decks are now sized like the straight's bridges rather than being lane-width
-- slivers, and there are more of them, so a sweep presents real footing rather
-- than a moving kerb.
-- ===== Grouping: rows sweep, columns do not =====
--
-- Three decks side by side span the chasm, and THOSE THREE MOVE AS ONE — a row
-- crossing the racing line together. The next row along the track sweeps the
-- opposite way, and so on down the segment.
--
-- The first attempt grouped the wrong axis: each COLUMN alternated against its
-- neighbour, so at any instant the chasm was a picket fence of decks going
-- opposite ways with nothing that read as a platform to aim for. Grouping by row
-- gives a racer a whole rank of footing that arrives together, then a rank
-- leaving the other way — which is a rhythm to time rather than noise.
--
-- The sweep is sized so a row at the end of its stroke has its outer edge on the
-- chasm boundary: "the leftmost reaches the wall, then the same for the right".
local SKYRAIL_CURVE_LANE_COUNT = 3
-- Keeps the outermost decks off the ledge edge and off the anchored barrier —
-- same standing-contact problem HAZARD_SPAN_WIDTH exists to avoid.
local SKYRAIL_CURVE_EDGE_CLEARANCE = 1
-- Half the LATERAL travel, so a deck sweeps twice this across the chasm.
local SKYRAIL_CURVE_DECK_SWEEP = 10
local SKYRAIL_CURVE_TRAVEL_SECONDS = 2.5
-- Decks per chord in each column, so a column is a run of footholds along the
-- track rather than one slab the length of the chord. Sized to match the
-- straight's decks — see skyRailElevatedLayout.
local SKYRAIL_CURVE_DECKS_PER_CHORD = 2

-- The columns' rest positions have to leave room for a full stroke either side,
-- or the outermost would sweep past the barrier instead of up to it.
assert(
	SKYRAIL_CURVE_DECK_SWEEP * 2 + SKYRAIL_PATH_WIDTH < TrackGeometry.SegmentWidth,
	`ThemeHazardBuilder: a SkyRail curve column sweeps {SKYRAIL_CURVE_DECK_SWEEP * 2} studs and is `
		.. `{string.format("%.1f", SKYRAIL_PATH_WIDTH)} wide, which does not fit the `
		.. `{TrackGeometry.SegmentWidth}-stud chasm — decks would sweep through the barrier`
)

-- ===== Why the column spacing is twice the sweep =====
--
-- Rows sweep as ranks, and consecutive rows oppose each other, so at the ends of
-- the stroke two neighbouring rows are offset by a full 2 * SWEEP laterally. If
-- the columns sit exactly that far apart, then at those moments column N of one
-- row lines up with column N+1 of the next — so there is ALWAYS a deck directly
-- ahead to jump to, at every point in the cycle. Get the spacing wrong and the
-- crossing periodically has nothing in front of it, which reads as the segment
-- being broken rather than hard.
--
-- The lane span is derived rather than set, so this is a check on the geometry
-- rather than a value to tune.
do
	local laneSpan = TrackGeometry.SegmentWidth
		- SKYRAIL_CURVE_EDGE_CLEARANCE * 2
		- SKYRAIL_PATH_WIDTH
		- SKYRAIL_CURVE_DECK_SWEEP * 2
	local spacing = laneSpan / (SKYRAIL_CURVE_LANE_COUNT - 1)
	assert(
		math.abs(spacing - SKYRAIL_CURVE_DECK_SWEEP * 2) < 2,
		`ThemeHazardBuilder: SkyRail curve columns sit {string.format("%.1f", spacing)} studs apart but rows offset `
			.. `by {SKYRAIL_CURVE_DECK_SWEEP * 2} at the ends of their stroke — the two must match or the crossing `
			.. `periodically has no deck ahead of it`
	)
end

local function buildSkyRailCurve(pieceModel: Model, entryCFrame: CFrame)
	local chordCFrames, chordLength = removeMiddleCurveChords(pieceModel, entryCFrame)

	-- No ledge any more: the chasm is the FULL road width.
	--
	-- The outside ledge used to be the safe-but-longer alternative to the decks.
	-- With it gone the decks are the only way across, which is the point — the
	-- segment now asks a racer to actually ride the crossing rather than offering
	-- a route that skips it. (The older note above about the ledge being on the
	-- outside so it traded against the inside line is history: there is no ledge
	-- to trade with.)
	local chasmWidth = TrackGeometry.SegmentWidth
	local chasmOffsetX = 0

	-- Decks are sized like the straight's — same width, and the same length along
	-- the track, so a column reads as a run of the same footholds rather than one
	-- slab per chord.
	local deckWidth = SKYRAIL_PATH_WIDTH
	local _, _, _, _, _, straightDeckLength = skyRailElevatedLayout(TrackGeometry.StraightLength)
	local deckLength = math.min(straightDeckLength, chordLength / SKYRAIL_CURVE_DECKS_PER_CHORD - 2)

	-- Column rest positions span the chasm minus one full stroke at each end, so
	-- the outermost column's outer edge lands exactly on the boundary at the end
	-- of its travel rather than sweeping through it.
	local laneSpan = chasmWidth
		- SKYRAIL_CURVE_EDGE_CLEARANCE * 2
		- deckWidth
		- SKYRAIL_CURVE_DECK_SWEEP * 2
	local chasmMidX = chasmOffsetX
	-- Decks sit level now: with the sweep doing the work there is no reason to
	-- bob them, and a flat deck is one the rider-carry can hold cleanly.
	local baseY = TrackGeometry.RoadThickness / 2 + 0.5

	for chordIndex, chordCFrame in chordCFrames do
		-- Barrier to barrier is a real drop — there is no strip of road left.
		TerrainGroundBuilder.CarveChasm(
			chordCFrame * CFrame.new(chasmOffsetX, 0, 0),
			chasmWidth,
			chordLength + CURVE_CHORD_FILL_OVERLAP
		)

		for laneIndex = 1, SKYRAIL_CURVE_LANE_COUNT do
			local laneAlpha = if SKYRAIL_CURVE_LANE_COUNT == 1
				then 0.5
				else (laneIndex - 1) / (SKYRAIL_CURVE_LANE_COUNT - 1)
			local laneX = chasmMidX + (laneAlpha - 0.5) * laneSpan

			for deckIndex = 1, SKYRAIL_CURVE_DECKS_PER_CHORD do
				local alongTrack = ((deckIndex - 0.5) / SKYRAIL_CURVE_DECKS_PER_CHORD - 0.5) * chordLength

				-- Phase comes from the position ALONG THE TRACK, not from the
				-- lane — so every deck in a row shares it and the row sweeps as a
				-- single rank, while the next row down the segment opposes it.
				local rowIndex = (chordIndex - 1) * SKYRAIL_CURVE_DECKS_PER_CHORD + deckIndex
				local rowPhase = (rowIndex % 2) * 0.5

				createMovingPlatform(
					pieceModel,
					chordCFrame * CFrame.new(laneX, baseY, alongTrack),
					Vector3.new(deckWidth, 1, deckLength),
					-- LATERAL travel: across the racing line, not up and down.
					Vector3.new(SKYRAIL_CURVE_DECK_SWEEP, 0, 0),
					SKYRAIL_CURVE_TRAVEL_SECONDS,
					rowPhase
				)
			end
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
-- Matches Volcanic's rank: three bars evenly spread through one travel cycle,
-- all running against the racer.
local DESERT_SWEEPER_COUNT = 3

-- ===== Blown noobs =====
--
-- The theme's own wind, made visible and physical. Figures are picked up at the
-- FAR end of the segment and blown back down it into oncoming racers — the same
-- direction DesertWindService's headwind blows, so the storm and the slow-down
-- read as one thing rather than two unrelated effects.
--
-- Built on the pieces that already work rather than a new mechanic: elastic
-- physics bodies like the IceFrost snowballs (so they bounce off road and
-- barriers and never take the same line twice), pushPlayer for the shove, and
-- the same phaseable collision group, so PhaseSelf is an answer here too.
-- Deliberately NOT registered with ZoneHazardMonitor — like the snowballs, these
-- cost distance, not a life.
local NOOB_SPAWN_INTERVAL_SECONDS = 2.5
local NOOB_LIFETIME_SECONDS = 7
-- Figures come in threes rather than singly. One at a time was a thing to
-- side-step; a group arriving together across the road is something to pick a
-- line through, which is what the lateral scatter on launch is already for.
local NOOB_PER_GUST = 3
local NOOB_LAUNCH_SPEED = 90
-- Upward kick on launch, so a figure tumbles down the segment rather than
-- sliding along it.
local NOOB_LAUNCH_LIFT = 22
local NOOB_PUSH_STUDS = 14
local NOOB_PUSH_SECONDS = 0.45
local NOOB_TORSO_SIZE = Vector3.new(4, 4, 2)
local NOOB_HEAD_SIZE = Vector3.new(2, 2, 2)
-- Light, so the wind actually owns them. Density was 0.6, which made a figure
-- heavy enough that the launch was all it ever got — measured, they covered only
-- 38-70 studs of a 180-stud segment before stopping, so a racer never met one
-- unless they were already near the far end.
local NOOB_PHYSICAL_PROPERTIES = PhysicalProperties.new(0.2, 0.2, 0.8, 1, 40)
-- ...and a sustained shove for the whole flight, rather than a single throw.
-- This is the "carried by the wind" half: a launch alone decays against friction
-- and every bounce, while a constant force keeps a figure coming the entire
-- length of the segment. Expressed as an ACCELERATION and multiplied by the
-- assembly's own mass at spawn, so retuning the density does not silently change
-- how far they travel.
local NOOB_WIND_ACCELERATION = 45

-- A crude two-part noob: torso plus a stock Head mesh, welded into one assembly
-- so it tumbles as a body. Kept to two parts on purpose — these spawn every few
-- seconds on every Desert segment, and a six-limb figure would multiply that.
local function buildBlownNoob(parent: Instance, spawnCFrame: CFrame) : BasePart
	local torso = Instance.new("Part")
	torso.Anchored = false
	torso.CanCollide = true
	torso.Material = Enum.Material.SmoothPlastic
	torso.Color = Color3.fromRGB(0, 162, 255)
	torso.Size = NOOB_TORSO_SIZE
	torso.CFrame = spawnCFrame
	torso.Name = "BlownNoob"
	torso.CustomPhysicalProperties = NOOB_PHYSICAL_PROPERTIES
	CollisionTags.MarkPhaseable(torso)
	torso.Parent = parent

	local head = Instance.new("Part")
	head.Anchored = false
	head.CanCollide = false
	head.Massless = true
	head.Material = Enum.Material.SmoothPlastic
	head.Color = Color3.fromRGB(245, 205, 48)
	head.Size = NOOB_HEAD_SIZE
	head.CFrame = spawnCFrame * CFrame.new(0, NOOB_TORSO_SIZE.Y / 2 + NOOB_HEAD_SIZE.Y / 2, 0)
	head.Name = "BlownNoobHead"
	local headMesh = Instance.new("SpecialMesh")
	headMesh.MeshType = Enum.MeshType.Head
	headMesh.Parent = head
	head.Parent = parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = head
	weld.Parent = torso

	return torso
end

-- `sourceCFrame` sits at the segment's far end, facing the way a racer travels;
-- figures are launched backwards along it. `spanWidth` is how far across the
-- road they can be picked up from.
local function createNoobStorm(pieceModel: Model, sourceCFrame: CFrame, spanWidth: number)
	-- One figure, launched. Split out so a gust can send several at once without
	-- them sharing a lateral offset, a lift or a spin — a rank of identical
	-- figures would be one wide obstacle rather than a group to pick a line
	-- through.
	local function launchNoob()
			local lateral = (math.random() - 0.5) * spanWidth
			local spawnCFrame = sourceCFrame * CFrame.new(lateral, 6 + math.random() * 6, 0)
			local noob = buildBlownNoob(pieceModel, spawnCFrame)

			-- Server-owned: what this hits decides whether a racer loses ground.
			pinPhysicsToServer(noob)

			-- Backwards along the track (see the LookVector note on the ice
			-- current — LookVector is the way the RACER goes), with lift and a
			-- little lateral scatter so no two arrive on the same line.
			local windDirection = -sourceCFrame.LookVector
			local across = sourceCFrame.RightVector * (math.random() - 0.5) * 20
			noob.AssemblyLinearVelocity = windDirection * NOOB_LAUNCH_SPEED + across + Vector3.new(0, NOOB_LAUNCH_LIFT, 0)
			noob.AssemblyAngularVelocity = Vector3.new(math.random() * 6 - 3, math.random() * 6 - 3, math.random() * 6 - 3)

			-- The wind itself, held for the whole flight. Force is mass * the
			-- acceleration we actually want, read off the assembly so it stays
			-- right if the figure's size or density is ever retuned.
			local windAttachment = Instance.new("Attachment")
			windAttachment.Parent = noob

			local wind = Instance.new("VectorForce")
			wind.Attachment0 = windAttachment
			wind.ApplyAtCenterOfMass = true
			wind.RelativeTo = Enum.ActuatorRelativeTo.World
			wind.Force = windDirection * (noob.AssemblyMass * NOOB_WIND_ACCELERATION)
			wind.Parent = noob

			local spent = false
			local touchConnection: RBXScriptConnection
			touchConnection = noob.Touched:Connect(function(otherPart: BasePart)
				if spent then
					return
				end
				local hitPlayer = ZoneHazardMonitor.PlayerFromTouch(otherPart)
				if hitPlayer == nil then
					return
				end
				spent = true
				touchConnection:Disconnect()

				pushPlayer(hitPlayer, -sourceCFrame.LookVector, NOOB_PUSH_STUDS, NOOB_PUSH_SECONDS)
				SoundDirector.PlayAtPart(noob, "BlockImpact")
				VisualEffectsService.ShowImpactBurst(noob.Position, noob.Color)
				noob:Destroy()
			end)

			task.delay(NOOB_LIFETIME_SECONDS, function()
				if noob.Parent ~= nil then
					noob:Destroy()
				end
			end)
	end

	task.spawn(function()
		while pieceModel.Parent ~= nil do
			task.wait(NOOB_SPAWN_INTERVAL_SECONDS + math.random())
			if pieceModel.Parent == nil then
				break
			end

			for _ = 1, NOOB_PER_GUST do
				launchNoob()
			end
		end
	end)
end

-- ===== The sandstorm you can see =====
--
-- DesertWindService already swings WalkSpeed by +/-60%, which is a big effect
-- with nothing on screen to explain it. These emitters give the wind a body:
-- sand streaming back down the segment, against the direction of travel, so the
-- slow-down reads as running into a storm rather than as the controls being
-- broken.
--
-- Purely cosmetic — CanCollide and CanQuery off, and nothing reads them.
local DESERT_SAND_EMITTERS = 3

local function addSandstorm(parent: Instance, centerCFrame: CFrame, spanWidth: number, spanLength: number)
	for i = 1, DESERT_SAND_EMITTERS do
		local alongTrack = ((i - 0.5) / DESERT_SAND_EMITTERS - 0.5) * spanLength

		local anchor = Instance.new("Part")
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(spanWidth, 1, 1)
		anchor.CFrame = centerCFrame * CFrame.new(0, 8, alongTrack)
		anchor.Name = "SandstormEmitter"
		anchor.Parent = parent

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.Color = ColorSequence.new(Color3.fromRGB(214, 186, 130), Color3.fromRGB(180, 150, 100))
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.55),
			NumberSequenceKeypoint.new(0.8, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new(14, 26)
		emitter.Lifetime = NumberRange.new(1.2, 2.0)
		emitter.Rate = 26
		emitter.Speed = NumberRange.new(38, 60)
		emitter.SpreadAngle = Vector2.new(18, 10)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-40, 40)
		emitter.LightEmission = 0.15
		-- Blows the way the wind does: back down the track, into the racer.
		emitter.EmissionDirection = Enum.NormalId.Front
		emitter.Parent = anchor
	end
end

local function buildDesert(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	if segment.SegmentType == "Straight" then
		-- One-way now, like Volcanic's: every bar travels AGAINST the racer and
		-- teleports back to the far end rather than turning round, so none of them
		-- ever overtakes from behind.
		createSweeperRank(
			pieceModel,
			entryCFrame,
			exitCFrame,
			TrackGeometry.StraightLength * 0.8,
			DESERT_SWEEPER_COUNT,
			true
		)

		local center = midpoint(entryCFrame, exitCFrame)
		addSandstorm(pieceModel, center, TrackGeometry.SegmentWidth, TrackGeometry.StraightLength)
		-- Figures are picked up at the segment's exit and blown back at the racer.
		createNoobStorm(pieceModel, exitCFrame, TrackGeometry.SegmentWidth * 0.8)
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

		-- The curve gets the arc equivalent of the straight's one-way rank: bars
		-- pivoting about the circle's centre, sweeping against the racer and
		-- teleporting back at the end of the stroke. Same helper Volcanic uses.
		createCurveSweeperRank(pieceModel, entryCFrame, DESERT_SWEEPER_COUNT)

		-- Sand and blown figures follow the arc rather than a straight line, so
		-- both are placed from the curve's own centre and exit.
		local arcPose = makeCurveArcPoser(entryCFrame)
		local arcLength = TrackGeometry.CurveRadius * math.rad(TrackGeometry.CurveArcDegrees)
		addSandstorm(pieceModel, arcPose(0.5), TrackGeometry.SegmentWidth, arcLength * 0.6)
		createNoobStorm(pieceModel, arcPose(0.95), TrackGeometry.SegmentWidth * 0.8)
	end
end

-- NeonCircuit: the telegraphed drop is the theme's whole identity, so
-- createFallingBlockField above IS this builder — but it now does two things
-- rather than one.
--
-- Eight blocks a wave, up from three. The drops are all this segment has, so a
-- wave has to fill the road rather than sprinkle it; at three, long stretches of
-- a 126-stud field had nothing in them and a racer could walk a straight line
-- through most waves.
--
-- And half of all landings blast sideways (see emitLandingGust). That is the
-- second mechanic this theme was missing: with only drops, every block was an
-- independent dodge, and a racer who found a safe gap simply stood in it. A gust
-- moves them out of the gap they chose, into the path of the next block.
--
-- Both variants get identical treatment. The curve's field is shorter because
-- the arc is already a handling test, and that is the only difference.
local NEON_BLOCKS_PER_WAVE = 8
local NEON_BLOCK_SIZE = 8
local NEON_GUST_CHANCE = 0.5

local function buildNeonCircuit(pieceModel: Model, segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, exitCFrame: CFrame)
	local center = segmentCenter(segment, entryCFrame, exitCFrame)
	local spanLength = if segment.SegmentType == "Straight" then TrackGeometry.StraightLength * 0.7 else 60

	createFallingBlockField(pieceModel, center, spanLength, NEON_BLOCKS_PER_WAVE, NEON_BLOCK_SIZE)

	-- Segment-wide gust, entirely separate from the field above. It shoves every
	-- racer on the segment in or out; the blocks neither trigger it nor are
	-- affected by it.
	createNeonGust(pieceModel, center, spanLength, TrackGeometry.SegmentWidth, NEON_GUST_CHANCE)
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

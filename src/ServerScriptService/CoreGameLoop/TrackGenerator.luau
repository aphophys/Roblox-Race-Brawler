--!strict
--[[
	TrackGenerator
	Builds the 8-piece modular oval from ReplicatedStorage.Configs.
	TrackBlueprints by chaining TrackPieceBuilder pieces end-to-end, then
	drops in checkpoint trigger parts and rotating hazard bars.

	Checkpoints are plain transparent Parts tagged with a CheckpointOrdinal
	attribute, checked spatially by CheckpointValidator — never .Touched.
	Hazards use AssemblyAngularVelocity per the project's respawn-via-
	rotating-hazard design, not physics events.

	Checkpoint N sits at segment N's EXIT (not its entry) — so Checkpoint 1
	is reached after finishing segment 1, and Checkpoint 8 (the last one)
	is segment 8's exit, which is also segment 1's entry (the oval closes
	on itself there) — i.e. Checkpoint 8 IS the start/finish line. This
	means "reach Checkpoint 8" and "complete a lap" are the same physical
	event, with no separate wrap-around bookkeeping needed on top.

	Hazard placement is randomized on every generation (TrackBlueprints'
	per-segment HasHazard field is NOT read — kept in the type for
	documentation/future use, but overridden here), so calling Regenerate()
	after each Grand Prix gives a genuinely different layout each time.

	Track THEME is randomized the same way. The oval's 8 segments form 4
	fixed pairs (Side1 straights = segments 1-2, End1 curves = 3-4, Side2
	straights = 5-6, End2 curves = 7-8 — see TrackBlueprints). Each
	generation picks 2-4 distinct themes at random from ReplicatedStorage.
	Configs.TrackThemes' 8-entry pool and spreads them across those 4
	pairs (cycling through the chosen themes if fewer than 4 were picked),
	so the oval is always still ONE continuous track — never a different
	track per checkpoint (that was CourseSequence's superseded design,
	deleted) — just built from a themed mix of straight/curve segments.

	Each piece's geometry (Road/Barrier parts) is no longer built fresh
	from Parts every call — TrackPieceTemplates builds one Straight and one
	Curve model ONCE (at server start) and stores them under
	ReplicatedStorage.Assets.TrackPieceTemplates; buildPieceFromTemplate
	below just Clones + repositions (Model:PivotTo) whichever shape a
	segment needs, then recolors it to match the segment's theme. This
	means Regenerate() (called after every Grand Prix) no longer re-derives
	road/barrier geometry from scratch each time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackThemes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackThemes"))
local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))
local TrackPieceTemplates = require(script.Parent:WaitForChild("TrackPieceTemplates"))
local ThemeHazardBuilder = require(script.Parent:WaitForChild("ThemeHazardBuilder"))
local TerrainGroundBuilder = require(script.Parent:WaitForChild("TerrainGroundBuilder"))

-- Exactly one distinct theme per segment pair — never fewer. This used to
-- pick 2-4 themes and cycle them across the 4 pairs, which meant a
-- generation could easily land the same theme on two or three pairs; with
-- half the oval running the same hazard the lap reads as monotonous, which
-- is exactly what was reported. There are 8 themes in the pool, so 4
-- distinct is always satisfiable.
local THEME_COUNT = 4
-- The oval's 8 segments (SS-CC-SS-CC per TrackBlueprints) as 4 fixed pairs,
-- each pair sharing one theme.
local SEGMENT_PAIRS = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }

local TrackGenerator = {}

-- Pins each segment pair to a chosen theme instead of drawing at random.
-- nil (the shipping state) means "draw at random", so this costs nothing when
-- unused — it exists so a specific theme's straight AND curve can be put on the
-- oval on demand while a server is live, which is the only way to inspect or
-- tune one segment's hazards without regenerating until chance hands you the
-- theme you wanted. Set it, call Regenerate(), walk the segment.
local forcedPairThemeIds: { string }? = nil

-- Attribute the LIVE server watches to drive the override. Set it to a
-- comma-separated list of 4 theme ids (or clear it for random draws) and this
-- module regenerates the oval itself.
--
-- ## Why an attribute and not just calling SetForcedPairThemes from outside
--
-- Because calling in from a Studio command bar / MCP `execute_luau` session does
-- NOT reach this module. That context has its own require cache, so
-- `require(TrackGenerator)` there returns a whole FRESH copy of the dependency
-- graph — TrackGenerator, ThemeHazardBuilder, ZoneHazardMonitor,
-- PlayerStateService, all of them. Regenerate() called on that copy really does
-- build a real track into the real workspace, so it looks like it worked. But
-- every hazard it builds closes over the PHANTOM ZoneHazardMonitor, whose
-- PlayerStateService never saw the live EnterTrack — so those hazards read every
-- player as InLobby and can never take a life, and their zones are registered
-- with a monitor whose polling loop was never started.
--
-- That cost most of two sessions: the falling blocks were fine the whole time
-- and the test rig was spawning ghosts. Proven with module identities printed
-- from both sides — ArcadeManager saw table 0xabfc..., the block's own handler
-- saw table 0x3a65....
--
-- Setting an attribute crosses the boundary as DATA, so the reaction happens
-- inside the live server and everything it builds is wired to the live modules.
local FORCED_THEMES_ATTRIBUTE = "DevForcedPairThemes"

-- `themeIds` is one TrackThemes id per SEGMENT_PAIRS entry (4). Pass nil to go
-- back to random draws. Asserts rather than silently falling back: a typo'd
-- theme id that quietly regenerated a random track would look like the override
-- not working at all.
function TrackGenerator.SetForcedPairThemes(themeIds: { string }?)
	if themeIds == nil then
		forcedPairThemeIds = nil
		return
	end

	assert(
		#themeIds == #SEGMENT_PAIRS,
		`TrackGenerator.SetForcedPairThemes: expected {#SEGMENT_PAIRS} theme ids (one per segment pair), got {#themeIds}`
	)
	for _, themeId in themeIds do
		assert(TrackThemes[themeId] ~= nil, `TrackGenerator.SetForcedPairThemes: "{themeId}" is not a TrackThemes id`)
	end

	forcedPairThemeIds = table.clone(themeIds)
end

-- Picks THEME_COUNT distinct themes from the full TrackThemes pool and gives
-- one to each of the oval's 4 segment pairs. Returns a lookup from
-- SegmentIndex (1-8) to the TrackTheme for that segment.
local function pickOvalSegmentThemes() : { [number]: TrackThemes.TrackTheme }
	local allThemeIds: { string } = {}
	for themeId in TrackThemes do
		table.insert(allThemeIds, themeId)
	end

	for i = #allThemeIds, 2, -1 do
		local j = math.random(1, i)
		allThemeIds[i], allThemeIds[j] = allThemeIds[j], allThemeIds[i]
	end

	local themeCount = math.min(THEME_COUNT, #allThemeIds)
	local chosenThemeIds: { string } = {}
	for i = 1, themeCount do
		table.insert(chosenThemeIds, allThemeIds[i])
	end

	if forcedPairThemeIds ~= nil then
		chosenThemeIds = forcedPairThemeIds
	end

	local segmentThemes: { [number]: TrackThemes.TrackTheme } = {}
	for pairIndex, segmentIndices in SEGMENT_PAIRS do
		-- The modulo is now only a safety net for a hypothetically smaller
		-- theme pool; with the stock 8-theme pool every pair gets its own.
		local themeId = chosenThemeIds[((pairIndex - 1) % #chosenThemeIds) + 1]
		local theme = TrackThemes[themeId]
		for _, segmentIndex in segmentIndices do
			segmentThemes[segmentIndex] = theme
		end
	end

	return segmentThemes
end

-- Recolors a cloned template's Road/RoadChord_*/Barrier descendants to
-- match `theme` — a property set, not a rebuild, since the template's own
-- geometry (built once, no theme baked in) is shared by every clone.
local function applyThemeToPiece(pieceModel: Model, theme: TrackThemes.TrackTheme)
	for _, descendant in pieceModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Name == "Road" or descendant.Name:match("^RoadChord_") then
				descendant.Material = theme.RoadMaterial
				descendant.Color = theme.RoadColor
			elseif descendant.Name == "Barrier" then
				descendant.Color = theme.BarrierColor
			end
		end
	end
end

-- Builds one piece for `segment` at `entryCFrame`: clones + repositions the
-- matching TrackPieceTemplates model if one exists (the normal path),
-- falling back to building fresh via TrackPieceBuilder only if templates
-- somehow weren't built yet. Returns the piece Model and its exit CFrame.
local function buildPieceFromTemplate(segment: TrackBlueprints.SegmentBlueprint, entryCFrame: CFrame, theme: TrackThemes.TrackTheme) : (Model, CFrame)
	local template = TrackPieceTemplates.GetTemplate(segment.SegmentType)
	if template == nil then
		if segment.SegmentType == "Straight" then
			return TrackPieceBuilder.BuildStraight(entryCFrame, nil, theme)
		else
			return TrackPieceBuilder.BuildCurve(entryCFrame, nil, nil, nil, theme)
		end
	end

	local pieceModel = template:Clone()
	pieceModel:PivotTo(entryCFrame)

	local entryPivot = pieceModel:FindFirstChild("EntryPivot")
	if entryPivot ~= nil then
		entryPivot:Destroy()
	end
	pieceModel.PrimaryPart = pieceModel:FindFirstChild("Road") :: BasePart? or pieceModel:FindFirstChild("RoadChord_1") :: BasePart?

	applyThemeToPiece(pieceModel, theme)

	local exitCFrame: CFrame
	if segment.SegmentType == "Straight" then
		local _, straightExit = TrackPieceBuilder.SampleStraight(entryCFrame, TrackGeometry.StraightLength, 1)
		exitCFrame = straightExit
	else
		local _, curveExit = TrackPieceBuilder.SampleCurve(entryCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, 1)
		exitCFrame = curveExit
	end

	return pieceModel, exitCFrame
end

-- Y-size for checkpoint trigger volumes — taller than TrackGeometry.
-- BarrierHeight (10) so SkyRail's elevated bridges (players can be up to
-- ~10 studs above ground level while crossing) still fall inside the
-- trigger's vertical band. Applying this uniformly to every checkpoint
-- (not just ones after a SkyRail segment) is deliberate: a taller Y band
-- only makes detection MORE permissive for every other theme, never less
-- — no functional change for themes that stay at ground level.
local CHECKPOINT_TRIGGER_HEIGHT = 40

local function addCheckpointTrigger(parent: Instance, pieceExitCFrame: CFrame, ordinal: number)
	local trigger = Instance.new("Part")
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.Transparency = 1
	trigger.Name = `CheckpointTrigger_{ordinal}`
	trigger.Size = Vector3.new(TrackGeometry.SegmentWidth, CHECKPOINT_TRIGGER_HEIGHT, TrackGeometry.CheckpointTriggerThickness)
	trigger.CFrame = pieceExitCFrame
	trigger:SetAttribute("CheckpointOrdinal", ordinal)
	trigger.Parent = parent
end

-- Builds the oval under `parent`, returns the folder containing all pieces.
-- Every segment now gets its assigned theme's own real hazard (see
-- ThemeHazardBuilder) instead of a random generic sprinkle.
--
-- TerrainGroundBuilder.Rebuild() runs FIRST, before any piece exists: Terrain
-- is a single global instance, not scoped to this Track folder, so laying
-- fresh ground over the whole map footprint is also what wipes the previous
-- generation's water pools and SkyRail chasms (one FillBlock rewrites
-- material and occupancy for every voxel it covers). Hazards then carve back
-- into that clean ground as they build. Order matters — running it after the
-- pieces would fill in the very holes they just cut.
function TrackGenerator.GenerateOval(parent: Instance) : Folder
	TerrainGroundBuilder.Rebuild()

	local segmentThemes = pickOvalSegmentThemes()

	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "Track"

	local checkpointsFolder = Instance.new("Folder")
	checkpointsFolder.Name = "Checkpoints"
	checkpointsFolder.Parent = trackFolder

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local theme = segmentThemes[segment.SegmentIndex]
		local pieceModel, exitCFrame = buildPieceFromTemplate(segment, currentCFrame, theme)

		addCheckpointTrigger(checkpointsFolder, exitCFrame, segment.CheckpointOrdinal)

		pieceModel.Name = segment.SegmentName
		pieceModel:SetAttribute("ThemeId", theme.Id)
		pieceModel:SetAttribute("SegmentIndex", segment.SegmentIndex)
		pieceModel.Parent = trackFolder

		local hazardBuilder = ThemeHazardBuilder.HAZARD_BUILDERS[theme.Id]
		if hazardBuilder ~= nil then
			hazardBuilder(pieceModel, segment, currentCFrame, exitCFrame)
		end

		currentCFrame = exitCFrame
	end

	trackFolder.Parent = parent
	return trackFolder
end

-- Destroys the existing Track (if any) and rebuilds it with freshly
-- randomized hazards — called by GrandPrixManager after each Grand Prix
-- ends, so the next race is a "new experience."
function TrackGenerator.Regenerate(parent: Instance) : Folder
	local existingTrack = parent:FindFirstChild("Track")
	if existingTrack ~= nil then
		existingTrack:Destroy()
	end
	return TrackGenerator.GenerateOval(parent)
end

-- Studio's default new-place template leaves a real, solid "Baseplate" Part
-- (2048x16x2048, top surface at Y=0) sitting under the entire map. It isn't
-- referenced anywhere in this codebase (not Rojo-managed either — Workspace
-- isn't in default.project.json) — pure leftover scaffolding. It's harmless
-- everywhere the Road is intact (hidden underneath), but it silently
-- defeats every hazard that depends on a real gap at ground level: a
-- WaterDock/IceFrost pool's Road gets cut so players should fall into the
-- Terrain water below, and a SkyRail bridge gap should drop a player until
-- TrackBoundaryMonitor's fall-out check catches them — the Baseplate's
-- Y=0 surface just catches them first instead, standing them on dry land
-- in the middle of what's supposed to be water/a fall.
--
-- Relocated far below the play area rather than destroyed outright: it's
-- still the last-resort floor under TerrainGroundBuilder's SkyRail chasms,
-- and the safety net for players who aren't InRace (TrackBoundaryMonitor's
-- fall-out check only runs for InRace players — someone wandering the Hub/
-- FanBox area who walks off built geometry has nothing else catching them).
-- Kept just below TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD (-40) so an
-- InRace player always triggers the proper checkpoint-respawn violation
-- before ever landing on it.
--
-- What it is NOT anymore is the map's visible ground. That was the actual
-- "map is above ground" bug: this Part was simultaneously the only ground in
-- the place AND the thing that had to stay far below the track to avoid
-- plugging the hazards, so the entire world (Y ~ 0..23) hung ~47 studs over
-- open air. TerrainGroundBuilder now owns visible ground, which frees this
-- Part to be purely a safety floor — hidden underneath the terrain slab
-- rather than being the surface players look down at. Done here (not left as
-- a one-off manual Studio edit) so it can't silently reappear at Y=0 from an
-- unsaved session or a fresh place file and reintroduce the interference.
local BASEPLATE_SAFETY_Y = -55

-- Also resized to the ground's own footprint. At its stock 2048x2048 it
-- sticks out well past the terrain on every side, and a bare grey plane 47
-- studs below the edge of the grass reads as exactly the same "floating
-- island" problem the terrain was added to fix — just moved to the map's
-- outer boundary. Matching the footprints means the terrain fully hides it.
local function fitLegacyBaseplate()
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate == nil or not baseplate:IsA("BasePart") then
		return
	end

	local groundCFrame, groundSize = TerrainGroundBuilder.GetGroundVolume()
	baseplate.Size = Vector3.new(groundSize.X, baseplate.Size.Y, groundSize.Z)
	baseplate.CFrame = CFrame.new(groundCFrame.Position.X, BASEPLATE_SAFETY_Y, groundCFrame.Position.Z)
end

-- Applies whatever FORCED_THEMES_ATTRIBUTE currently says and rebuilds. Studio
-- only: this is a development inspection aid, and a live game should never have
-- its layout driven by a workspace attribute.
local function applyForcedThemesAttribute()
	local raw = workspace:GetAttribute(FORCED_THEMES_ATTRIBUTE)

	if raw == nil or raw == "" then
		TrackGenerator.SetForcedPairThemes(nil)
	else
		local themeIds: { string } = {}
		for id in tostring(raw):gmatch("[^,%s]+") do
			table.insert(themeIds, id)
		end
		-- A single id is shorthand for "put this theme on the whole oval", which
		-- is what inspecting one theme's straight AND curve at once needs.
		if #themeIds == 1 then
			for _ = 2, #SEGMENT_PAIRS do
				table.insert(themeIds, themeIds[1])
			end
		end
		TrackGenerator.SetForcedPairThemes(themeIds)
	end

	TrackGenerator.Regenerate(workspace)
end

function TrackGenerator.Init()
	fitLegacyBaseplate()
	TrackPieceTemplates.BuildAll()
	TrackGenerator.GenerateOval(workspace)

	if RunService:IsStudio() then
		workspace:GetAttributeChangedSignal(FORCED_THEMES_ATTRIBUTE):Connect(applyForcedThemesAttribute)
	end
end

return TrackGenerator

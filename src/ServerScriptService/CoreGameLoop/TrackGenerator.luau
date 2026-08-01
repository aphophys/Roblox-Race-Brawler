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

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackThemes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackThemes"))
local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))
local TrackPieceTemplates = require(script.Parent:WaitForChild("TrackPieceTemplates"))

local HAZARD_SEGMENT_COUNT = 2
local MIN_THEME_COUNT = 2
local MAX_THEME_COUNT = 4
-- The oval's 8 segments (SS-CC-SS-CC per TrackBlueprints) as 4 fixed pairs,
-- each pair sharing one theme.
local SEGMENT_PAIRS = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }

local TrackGenerator = {}

-- Picks HAZARD_SEGMENT_COUNT random segments to host a hazard bar. Safe to
-- pick from every segment even though every segment is also a checkpoint
-- now — the hazard sits at the segment's MIDPOINT while the checkpoint
-- trigger sits at its EXIT, so they never overlap; a respawned racer
-- won't be dropped straight into a hazard.
local function pickRandomHazardSegments() : { [number]: boolean }
	local eligible: { number } = {}
	for _, segment in TrackBlueprints.OvalSegments do
		table.insert(eligible, segment.SegmentIndex)
	end

	for i = #eligible, 2, -1 do
		local j = math.random(1, i)
		eligible[i], eligible[j] = eligible[j], eligible[i]
	end

	local chosen: { [number]: boolean } = {}
	for i = 1, math.min(HAZARD_SEGMENT_COUNT, #eligible) do
		chosen[eligible[i]] = true
	end
	return chosen
end

-- Picks 2-4 distinct themes from the full TrackThemes pool and assigns one
-- to each of the oval's 4 segment pairs (cycling through the chosen themes
-- if fewer than 4 were picked, so every pair still gets one). Returns a
-- lookup from SegmentIndex (1-8) to the TrackTheme for that segment.
local function pickOvalSegmentThemes() : { [number]: TrackThemes.TrackTheme }
	local allThemeIds: { string } = {}
	for themeId in TrackThemes do
		table.insert(allThemeIds, themeId)
	end

	for i = #allThemeIds, 2, -1 do
		local j = math.random(1, i)
		allThemeIds[i], allThemeIds[j] = allThemeIds[j], allThemeIds[i]
	end

	local themeCount = math.min(math.random(MIN_THEME_COUNT, MAX_THEME_COUNT), #allThemeIds)
	local chosenThemeIds: { string } = {}
	for i = 1, themeCount do
		table.insert(chosenThemeIds, allThemeIds[i])
	end

	local segmentThemes: { [number]: TrackThemes.TrackTheme } = {}
	for pairIndex, segmentIndices in SEGMENT_PAIRS do
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

local function addCheckpointTrigger(parent: Instance, pieceExitCFrame: CFrame, ordinal: number)
	local trigger = Instance.new("Part")
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.Transparency = 1
	trigger.Name = `CheckpointTrigger_{ordinal}`
	trigger.Size = Vector3.new(TrackGeometry.SegmentWidth, TrackGeometry.BarrierHeight, TrackGeometry.CheckpointTriggerThickness)
	trigger.CFrame = pieceExitCFrame
	trigger:SetAttribute("CheckpointOrdinal", ordinal)
	trigger.Parent = parent
end

-- Per project spec, hazards spin via AssemblyAngularVelocity (not a
-- HingeConstraint motor). The part stays unanchored so the angular velocity
-- actually has visible effect, and an AlignPosition constraint holds it at
-- its spawn point so it spins in place instead of falling under gravity.
-- Collision with players is plain rigid-body contact, not a .Touched
-- listener, so it doesn't violate the no-.Touched detection rule.
--
-- Reported repeatedly as ending up visibly misplaced despite the spawn
-- CFrame itself being verified correct (re-derived twice, no bug found in
-- the placement math) — the remaining plausible explanation is PHYSICS
-- DRIFT: this part is unanchored + CanCollide = true, so every player hit
-- imparts a real impulse/torque. AlignPosition being force-based (not a
-- hard constraint) meant enough repeated or fast hits could out-pace its
-- restoring force before the next frame, and nothing was ever re-asserting
-- AssemblyAngularVelocity after creation, so a hit could also tip the spin
-- axis or change its rate permanently, with no correction. Two changes
-- directly close both gaps: RigidityEnabled makes the position hold a hard
-- constraint (snaps back immediately, not spring-based, so it can't drift
-- position at all regardless of hit frequency/force), and a Heartbeat loop
-- continuously re-asserts the intended spin so a hit can never leave it
-- tumbling on the wrong axis or spinning at the wrong rate. Disconnects via
-- Destroying so it doesn't leak across TrackGenerator.Regenerate() calls.
local function addHazardBar(parent: Instance, pieceCenterCFrame: CFrame)
	local pivotCFrame = pieceCenterCFrame * CFrame.new(0, TrackGeometry.BarrierHeight / 2, 0)
	local targetAngularVelocity = Vector3.new(0, math.rad(TrackGeometry.HazardSpinDegreesPerSecond), 0)

	local hazard = Instance.new("Part")
	hazard.Anchored = false
	hazard.CanCollide = true
	hazard.Material = Enum.Material.Neon
	hazard.Color = Color3.fromRGB(255, 140, 0)
	hazard.Name = "HazardBar"
	hazard.Size = Vector3.new(TrackGeometry.HazardBarLength, 1, 1)
	hazard.CFrame = pivotCFrame

	local attachment = Instance.new("Attachment")
	attachment.Parent = hazard

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = pivotCFrame.Position
	alignPosition.MaxForce = 1e6 -- large-but-finite; math.huge can destabilize Roblox's physics solver
	alignPosition.Responsiveness = 200
	alignPosition.RigidityEnabled = true -- hard position lock, not spring-based — cannot drift under repeated collisions
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
end

-- Builds the oval under `parent`, returns the folder containing all pieces.
-- Hazard segments are re-randomized on every call — see module docstring.
function TrackGenerator.GenerateOval(parent: Instance) : Folder
	local hazardSegments = pickRandomHazardSegments()
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
		pieceModel.Parent = trackFolder

		if hazardSegments[segment.SegmentIndex] then
			local pieceMidpointCFrame = currentCFrame:Lerp(exitCFrame, 0.5)
			addHazardBar(pieceModel, pieceMidpointCFrame)
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

function TrackGenerator.Init()
	TrackPieceTemplates.BuildAll()
	TrackGenerator.GenerateOval(workspace)
end

return TrackGenerator

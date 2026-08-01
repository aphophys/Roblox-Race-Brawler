--!strict
--[[
	TrackGenerator
	Builds the 8-piece modular oval from ReplicatedStorage.Configs.
	TrackBlueprints by chaining TrackPieceBuilder pieces end-to-end, then
	drops in checkpoint trigger parts and rotating hazard bars.

	Checkpoints are plain transparent Parts tagged with a CheckpointOrdinal
	attribute, queried spatially (workspace:GetPartsInPart) by
	CheckpointValidator — never .Touched. Hazards use AssemblyAngularVelocity
	per the project's respawn-via-rotating-hazard design, not physics events.

	Hazard placement is randomized on every generation (TrackBlueprints'
	per-segment HasHazard field is NOT read — kept in the type for
	documentation/future use, but overridden here), so calling Regenerate()
	after each Grand Prix gives a genuinely different layout each time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

local HAZARD_SEGMENT_COUNT = 2

local TrackGenerator = {}

-- Picks HAZARD_SEGMENT_COUNT random non-checkpoint segments to host a
-- hazard bar (checkpoint segments stay clear so respawn points never spawn
-- a player straight into a hazard).
local function pickRandomHazardSegments() : { [number]: boolean }
	local eligible: { number } = {}
	for _, segment in TrackBlueprints.OvalSegments do
		if not segment.IsCheckpoint then
			table.insert(eligible, segment.SegmentIndex)
		end
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

local function addCheckpointTrigger(parent: Instance, pieceEntryCFrame: CFrame, ordinal: number)
	local trigger = Instance.new("Part")
	trigger.Anchored = true
	trigger.CanCollide = false
	trigger.Transparency = 1
	trigger.Name = `CheckpointTrigger_{ordinal}`
	trigger.Size = Vector3.new(TrackGeometry.SegmentWidth, TrackGeometry.BarrierHeight, TrackGeometry.CheckpointTriggerThickness)
	trigger.CFrame = pieceEntryCFrame
	trigger:SetAttribute("CheckpointOrdinal", ordinal)
	trigger.Parent = parent
end

-- Per project spec, hazards spin via AssemblyAngularVelocity (not a
-- HingeConstraint motor). The part stays unanchored so the angular velocity
-- actually has visible effect, and an AlignPosition constraint holds it at
-- its spawn point so it spins in place instead of falling under gravity.
-- Collision with players is plain rigid-body contact, not a .Touched
-- listener, so it doesn't violate the no-.Touched detection rule.
local function addHazardBar(parent: Instance, pieceCenterCFrame: CFrame)
	local pivotCFrame = pieceCenterCFrame * CFrame.new(0, TrackGeometry.BarrierHeight / 2, 0)

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
	alignPosition.Parent = hazard

	hazard.AssemblyAngularVelocity = Vector3.new(0, math.rad(TrackGeometry.HazardSpinDegreesPerSecond), 0)

	hazard.Parent = parent
end

-- Builds the oval under `parent`, returns the folder containing all pieces.
-- Hazard segments are re-randomized on every call — see module docstring.
function TrackGenerator.GenerateOval(parent: Instance) : Folder
	local hazardSegments = pickRandomHazardSegments()

	local trackFolder = Instance.new("Folder")
	trackFolder.Name = "Track"

	local checkpointsFolder = Instance.new("Folder")
	checkpointsFolder.Name = "Checkpoints"
	checkpointsFolder.Parent = trackFolder

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local pieceModel: Model
		local exitCFrame: CFrame

		if segment.IsCheckpoint then
			addCheckpointTrigger(checkpointsFolder, currentCFrame, segment.CheckpointOrdinal :: number)
		end

		if segment.SegmentType == "Straight" then
			pieceModel, exitCFrame = TrackPieceBuilder.BuildStraight(currentCFrame)
		else
			pieceModel, exitCFrame = TrackPieceBuilder.BuildCurve(currentCFrame)
		end

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
	TrackGenerator.GenerateOval(workspace)
end

return TrackGenerator

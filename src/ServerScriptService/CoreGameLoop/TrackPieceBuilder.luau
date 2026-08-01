--!strict
--[[
	TrackPieceBuilder
	Procedurally builds Straight and Curve oval track pieces from plain
	Parts. This exists because there's no Roblox Toolbox/marketplace access
	available to source or place hand-built models — every piece is
	generated at runtime instead. Treat the output as placeholder-quality
	greybox geometry: correct shape and connectivity, not final art.

	Both builders take an *entry* CFrame (where the piece starts, facing its
	direction of travel along -LookVector) and return the piece's Model plus
	its *exit* CFrame — the entry CFrame for whatever piece comes next. This
	lets TrackGenerator chain pieces end-to-end without hand-measuring
	positions: only piece dimensions (TrackGeometry) matter.

	The Sample* functions expose the same entry/exit chaining math without
	building Parts, so other generators (e.g. FanBoxGenerator) can walk the
	identical oval path to place things alongside the track.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))

local ROAD_COLOR = Color3.fromRGB(70, 70, 78)
local BARRIER_COLOR = Color3.fromRGB(150, 40, 40)

local TrackPieceBuilder = {}

-- Returns `sampleCount` evenly-spaced center CFrames along a straight run
-- of `length` studs starting at entryCFrame, plus the exit CFrame.
function TrackPieceBuilder.SampleStraight(entryCFrame: CFrame, length: number, sampleCount: number) : ({ CFrame }, CFrame)
	local samples: { CFrame } = {}
	for i = 1, sampleCount do
		local fraction = (i - 0.5) / sampleCount
		table.insert(samples, entryCFrame * CFrame.new(0, 0, -fraction * length))
	end

	local exitCFrame = entryCFrame * CFrame.new(0, 0, -length)
	return samples, exitCFrame
end

-- Returns `sampleCount` evenly-spaced center CFrames along a `arcDegrees`
-- curve of `radius` studs starting at entryCFrame, plus the exit CFrame.
-- Each sample is rotated symmetrically about its own midpoint (half-step
-- rotate, translate, half-step rotate) so the polygon hugs the true arc.
function TrackPieceBuilder.SampleCurve(entryCFrame: CFrame, radius: number, arcDegrees: number, sampleCount: number) : ({ CFrame }, CFrame)
	local anglePerStepRad = math.rad(arcDegrees / sampleCount)
	local chordLength = 2 * radius * math.sin(math.abs(anglePerStepRad) / 2)
	local halfStepRotation = CFrame.Angles(0, anglePerStepRad / 2, 0)

	local samples: { CFrame } = {}
	local currentCFrame = entryCFrame

	for _ = 1, sampleCount do
		currentCFrame = currentCFrame * halfStepRotation
		table.insert(samples, currentCFrame * CFrame.new(0, 0, -chordLength / 2))
		currentCFrame = currentCFrame * CFrame.new(0, 0, -chordLength) * halfStepRotation
	end

	return samples, currentCFrame
end

local function addBarriers(model: Model, centerCFrame: CFrame, roadLength: number)
	local halfWidth = TrackGeometry.SegmentWidth / 2
	local barrierSize = Vector3.new(TrackGeometry.BarrierThickness, TrackGeometry.BarrierHeight, roadLength)

	for _, side in { -1, 1 } do
		local barrier = Instance.new("Part")
		barrier.Anchored = true
		barrier.Size = barrierSize
		barrier.Color = BARRIER_COLOR
		barrier.Name = "Barrier"
		barrier.CFrame = centerCFrame
			* CFrame.new(side * (halfWidth + TrackGeometry.BarrierThickness / 2), TrackGeometry.BarrierHeight / 2, 0)
		barrier.Parent = model
	end
end

local function addRoadSlab(model: Model, centerCFrame: CFrame, length: number, partName: string) : Part
	local road = Instance.new("Part")
	road.Anchored = true
	road.Material = Enum.Material.Concrete
	road.Color = ROAD_COLOR
	road.Size = Vector3.new(TrackGeometry.SegmentWidth, TrackGeometry.RoadThickness, length)
	road.CFrame = centerCFrame
	road.Name = partName
	road.Parent = model

	addBarriers(model, centerCFrame, length)

	return road
end

-- Builds one straight slab. Returns the Model and the exit CFrame.
function TrackPieceBuilder.BuildStraight(entryCFrame: CFrame, length: number?) : (Model, CFrame)
	local pieceLength = length or TrackGeometry.StraightLength

	local model = Instance.new("Model")
	model.Name = "StraightPiece"

	local samples, exitCFrame = TrackPieceBuilder.SampleStraight(entryCFrame, pieceLength, 1)
	local road = addRoadSlab(model, samples[1], pieceLength, "Road")
	model.PrimaryPart = road

	return model, exitCFrame
end

-- Approximates a `arcDegrees`-of-turn curve at `radius` studs using
-- `subdivisions` straight chords. Always turns left (positive Y rotation);
-- TrackBlueprints relies on 4 curve pieces (2 ends x 2 pieces) summing to
-- 360° to close the oval loop.
function TrackPieceBuilder.BuildCurve(entryCFrame: CFrame, radius: number?, arcDegrees: number?, subdivisions: number?) : (Model, CFrame)
	local curveRadius = radius or TrackGeometry.CurveRadius
	local totalArcDegrees = arcDegrees or TrackGeometry.CurveArcDegrees
	local stepCount = subdivisions or TrackGeometry.CurveSubdivisions

	local model = Instance.new("Model")
	model.Name = "CurvePiece"

	local chordSamples, exitCFrame = TrackPieceBuilder.SampleCurve(entryCFrame, curveRadius, totalArcDegrees, stepCount)
	local chordLength = 2 * curveRadius * math.sin(math.abs(math.rad(totalArcDegrees / stepCount)) / 2)

	for stepIndex, centerCFrame in chordSamples do
		addRoadSlab(model, centerCFrame, chordLength, `RoadChord_{stepIndex}`)
	end

	return model, exitCFrame
end

return TrackPieceBuilder

--!strict
--[[
	TrackBlueprints
	Declares the 8-segment core oval as an ordered list of Straight/Curve
	pieces: two consecutive Straights per side, two consecutive Curves per
	end (each Curve piece turns TrackGeometry.CurveArcDegrees, so two in a
	row = a full end-of-oval turn). TrackGenerator walks this list in order
	and asks TrackPieceBuilder to build+chain each piece — CFrames are
	computed from piece dimensions at build time, not authored by hand here.

	Exactly ONE segment is a checkpoint: per the "8 checkpoints total, one per
	track type" rule, the Oval is a single stop in ReplicatedStorage.Configs.
	CourseSequence (8 stops = 8 checkpoints, whole-course numbering) — it
	doesn't get its own internal checkpoints. This CheckpointOrdinal is that
	stop's CourseSequence.CheckpointOrdinal (currently 1), not a local count.
]]

export type SegmentType = "Straight" | "Curve"

export type SegmentBlueprint = {
	SegmentIndex: number, -- 1..8, build order around the oval
	SegmentName: string,
	SegmentType: SegmentType,
	IsCheckpoint: boolean,
	CheckpointOrdinal: number?, -- nil unless IsCheckpoint
	HasHazard: boolean, -- NOT read by TrackGenerator (it randomizes hazard placement every generation instead, see its docstring) — kept here for schema documentation only
}

export type TrackBlueprintsType = {
	OvalSegments: { SegmentBlueprint },
}

local TrackBlueprints: TrackBlueprintsType = {
	OvalSegments = {
		{ SegmentIndex = 1, SegmentName = "Side1_Straight_A", SegmentType = "Straight", IsCheckpoint = true, CheckpointOrdinal = 1, HasHazard = false },
		{ SegmentIndex = 2, SegmentName = "Side1_Straight_B", SegmentType = "Straight", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = true },
		{ SegmentIndex = 3, SegmentName = "End1_Curve_A", SegmentType = "Curve", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = false },
		{ SegmentIndex = 4, SegmentName = "End1_Curve_B", SegmentType = "Curve", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = false },
		{ SegmentIndex = 5, SegmentName = "Side2_Straight_A", SegmentType = "Straight", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = false },
		{ SegmentIndex = 6, SegmentName = "Side2_Straight_B", SegmentType = "Straight", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = true },
		{ SegmentIndex = 7, SegmentName = "End2_Curve_A", SegmentType = "Curve", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = false },
		{ SegmentIndex = 8, SegmentName = "End2_Curve_B", SegmentType = "Curve", IsCheckpoint = false, CheckpointOrdinal = nil, HasHazard = false },
	},
}

return TrackBlueprints

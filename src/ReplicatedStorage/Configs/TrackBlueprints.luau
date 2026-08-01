--!strict
--[[
	TrackBlueprints
	Declares the 8-segment core oval as an ordered list of Straight/Curve
	pieces: two consecutive Straights per side, two consecutive Curves per
	end (each Curve piece turns TrackGeometry.CurveArcDegrees, so two in a
	row = a full end-of-oval turn). TrackGenerator walks this list in order
	and asks TrackPieceBuilder to build+chain each piece — CFrames are
	computed from piece dimensions at build time, not authored by hand here.

	Every segment is a checkpoint (CheckpointOrdinal == SegmentIndex),
	placed at that segment's EXIT — so Checkpoint 1 is reached on
	completing segment 1, Checkpoint 2 on completing segment 2, ..., and
	Checkpoint 8 (segment 8's exit) is ALSO segment 1's entry, since the
	oval closes on itself there — Checkpoint 8 IS the start/finish line, and
	reaching it is what completes a lap (no separate "back to Checkpoint 1"
	step needed). CheckpointValidator enforces passing them in strict order
	(1, 2, 3, ..., 8, 1, ...) — skipping ahead or approaching from the wrong
	direction doesn't count. Deliberately independent of segment
	identity/content (just position-in-sequence), since segments may be
	randomized later.
]]

export type SegmentType = "Straight" | "Curve"

export type SegmentBlueprint = {
	SegmentIndex: number, -- 1..8, build order around the oval
	SegmentName: string,
	SegmentType: SegmentType,
	CheckpointOrdinal: number, -- always == SegmentIndex; every segment is a checkpoint
	HasHazard: boolean, -- NOT read by TrackGenerator (it randomizes hazard placement every generation instead, see its docstring) — kept here for schema documentation only
}

export type TrackBlueprintsType = {
	OvalSegments: { SegmentBlueprint },
}

local TrackBlueprints: TrackBlueprintsType = {
	OvalSegments = {
		{ SegmentIndex = 1, SegmentName = "Side1_Straight_A", SegmentType = "Straight", CheckpointOrdinal = 1, HasHazard = false },
		{ SegmentIndex = 2, SegmentName = "Side1_Straight_B", SegmentType = "Straight", CheckpointOrdinal = 2, HasHazard = true },
		{ SegmentIndex = 3, SegmentName = "End1_Curve_A", SegmentType = "Curve", CheckpointOrdinal = 3, HasHazard = false },
		{ SegmentIndex = 4, SegmentName = "End1_Curve_B", SegmentType = "Curve", CheckpointOrdinal = 4, HasHazard = false },
		{ SegmentIndex = 5, SegmentName = "Side2_Straight_A", SegmentType = "Straight", CheckpointOrdinal = 5, HasHazard = false },
		{ SegmentIndex = 6, SegmentName = "Side2_Straight_B", SegmentType = "Straight", CheckpointOrdinal = 6, HasHazard = true },
		{ SegmentIndex = 7, SegmentName = "End2_Curve_A", SegmentType = "Curve", CheckpointOrdinal = 7, HasHazard = false },
		{ SegmentIndex = 8, SegmentName = "End2_Curve_B", SegmentType = "Curve", CheckpointOrdinal = 8, HasHazard = false },
	},
}

return TrackBlueprints

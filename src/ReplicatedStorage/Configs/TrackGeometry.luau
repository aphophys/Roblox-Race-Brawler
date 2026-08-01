--!strict
--[[
	TrackGeometry
	Tunable dimensions for procedurally-built oval track pieces
	(TrackPieceBuilder). Read by both server (generation) and, if needed
	later, client-side prediction — kept in ReplicatedStorage for that
	reason even though only the server currently builds geometry.

	Scaled ~4.5x linear from the original values to hit the requested
	"~20x bigger" map — area scales with length squared, so 4.5x linear ≈
	20x footprint (4.5² ≈ 20.25), rather than a literal 20x on every
	dimension (which would make a single straight piece 800 studs long).
	If a literal 20x linear scale was actually intended, multiply these by
	~4.44 again.
]]

export type TrackGeometryType = {
	SegmentWidth: number,
	RoadThickness: number,
	StraightLength: number,
	CurveRadius: number,
	CurveArcDegrees: number, -- per curve piece; 2 consecutive curve pieces = 180° end of the oval
	CurveSubdivisions: number, -- number of straight chords approximating the arc
	BarrierHeight: number,
	BarrierThickness: number,
	CheckpointTriggerThickness: number,
	HazardBarLength: number,
	HazardSpinDegreesPerSecond: number,
}

local TrackGeometry: TrackGeometryType = {
	SegmentWidth = 72,
	RoadThickness = 2,
	StraightLength = 180,
	CurveRadius = 180,
	CurveArcDegrees = 90,
	CurveSubdivisions = 8, -- bumped from 6: a bigger radius needs more chords to still read as a smooth curve
	BarrierHeight = 10,
	BarrierThickness = 3,
	CheckpointTriggerThickness = 6,
	HazardBarLength = 60,
	HazardSpinDegreesPerSecond = 120, -- rotational speed, not spatial — unchanged by the scale-up
}

return TrackGeometry

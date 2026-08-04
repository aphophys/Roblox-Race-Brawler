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
	-- Must stay <= SegmentWidth - 2 (ThemeHazardBuilder asserts this). Was 60
	-- against a 72-stud road: a bar spinning about the road's centreline swept
	-- a circle of radius 30, which left a 6-stud lane against each barrier that
	-- the bar could never reach — so the signature Classic hazard was avoided
	-- for free by anyone who simply ran along the wall. 70 sweeps to within a
	-- stud of each barrier, which no character fits through.
	HazardBarLength = 70,
	HazardSpinDegreesPerSecond = 120, -- rotational speed, not spatial — unchanged by the scale-up
}

return TrackGeometry

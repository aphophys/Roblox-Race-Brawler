--!strict
--[[
	FanBoxTiers
	The 8 crowd tiers for a player's Dynamic Fan Box, keyed to their
	TotalFans count (was 5 — expanded per explicit request: "add 3 more
	layers and adjust graduation, may increase number"). Tier 1 ("Empty")
	is also what every pod is built as by default before a player is
	assigned (FanBoxGenerator/FanBoxSlotManager swap in the tier matching a
	player's actual fan count on assignment, and again live as it grows —
	see FanBoxCrowdTemplates).

	Thresholds were reworked, not just padded with 3 more steps at the old
	spacing — the original 5-tier curve (0 / 101 / 1,001 / 10,001 / 100,001)
	jumped by ~10x/100x per step, which would have left the 3 new tiers
	either bunched at the bottom or requiring an awkwardly huge final
	number. Retuned to a smoother, still-increasing curve across 8 tiers
	instead, roughly 4-5x per step early on, widening at the top so
	"Superstar Crowd" still feels like a real endgame milestone.

	Tiers are visually distinguished by CROWD DENSITY (how many noob
	figures stand on the stand's steps — see FanBoxCrowdTemplates.
	NOOBS_PER_STEP_BY_TIER), not by resizing a single shape — an earlier
	version scaled a shared mesh via tier.MeshScale, which visibly lifted/
	sank the whole crowd off the ground (the mesh's natural bounding box
	never matched PodBaseSize, so even "1x scale" was a distorting resize).
	MeshScale was removed for that reason; PodBaseSize is still read by
	FanBoxCrowdTemplates for the stand's fixed footprint (width for
	spacing figures, not for scaling anything).
]]

export type FanBoxTier = {
	MinFans: number,
	DisplayName: string,
}

export type FanBoxTiersType = {
	PodBaseSize: Vector3, -- fixed stand footprint — identical for every tier. X = depth (6 steps x 6-stud STEP_DEPTH), Y = nominal max height (fallback-block only), Z = width, both for spacing figures across each step AND read by FanBoxGenerator to size/space pods for the "almost connected" stadium-wall look around the track.
	Tiers: { FanBoxTier },
}

local FanBoxTiers: FanBoxTiersType = {
	-- Widened this round (24,18,14 -> 40,23,35): figures are now full
	-- avatar scale and there are 6 steps instead of 3 (see
	-- FanBoxCrowdTemplates), and the stand itself needed to be much wider
	-- so adjacent pods sit almost touching instead of reading as isolated
	-- islands (see FanBoxGenerator.computePodsPerPiece).
	PodBaseSize = Vector3.new(40, 23, 35),
	Tiers = {
		{ MinFans = 0, DisplayName = "Empty" },
		{ MinFans = 50, DisplayName = "First Fans" },
		{ MinFans = 250, DisplayName = "Small Crowd" },
		{ MinFans = 1_000, DisplayName = "Growing Crowd" },
		{ MinFans = 5_000, DisplayName = "Solid Crowd" },
		{ MinFans = 25_000, DisplayName = "Big Crowd" },
		{ MinFans = 100_000, DisplayName = "Packed House" },
		{ MinFans = 500_000, DisplayName = "Superstar Crowd" },
	},
}

return FanBoxTiers

--!strict
--[[
	FanBoxTiers
	The 5 crowd tiers for a player's Dynamic Fan Box, keyed to their
	TotalFans count. Tier 1 ("Empty") is also what every pod is built as by
	default before a player is assigned (FanBoxGenerator/FanBoxSlotManager
	swap in the tier matching a player's actual fan count on assignment,
	and again live as it grows — see FanBoxCrowdTemplates).

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
	PodBaseSize: Vector3, -- fixed stand footprint (width used to space figures across each step) — identical for every tier.
	Tiers: { FanBoxTier },
}

local FanBoxTiers: FanBoxTiersType = {
	PodBaseSize = Vector3.new(24, 18, 14),
	Tiers = {
		{ MinFans = 0, DisplayName = "Empty" },
		{ MinFans = 101, DisplayName = "Small Crowd" },
		{ MinFans = 1001, DisplayName = "Growing Crowd" },
		{ MinFans = 10001, DisplayName = "Big Crowd" },
		{ MinFans = 100001, DisplayName = "Superstar Crowd" },
	},
}

return FanBoxTiers

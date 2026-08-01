--!strict
--[[
	FanBoxTiers
	The 5 crowd-size tiers for a player's Dynamic Fan Box, keyed to their
	TotalFans count. Tier 1 is also what an unoccupied fan box looks like
	(FanBoxGenerator builds every pod at Tiers[1] scale by default).

	PodBaseSize sized up to read as "100+ NPCs" at a glance while still
	being a single Part/mesh (no Toolbox access to source or place actual
	crowd character models) — a big block stand, not a literal crowd.
]]

export type FanBoxTier = {
	MinFans: number,
	DisplayName: string,
	MeshScale: Vector3,
}

export type FanBoxTiersType = {
	PodBaseSize: Vector3, -- unscaled CrowdMesh size, before any tier's MeshScale is applied. Shared by FanBoxGenerator (server, initial build) and FansBoxRenderer (client, tween target) so both compute the same absolute size independently.
	Tiers: { FanBoxTier },
}

local FanBoxTiers: FanBoxTiersType = {
	PodBaseSize = Vector3.new(24, 18, 14),
	Tiers = {
		{ MinFans = 0, DisplayName = "Empty", MeshScale = Vector3.new(1, 1, 1) },
		{ MinFans = 101, DisplayName = "Small Crowd", MeshScale = Vector3.new(1.3, 1.3, 1.3) },
		{ MinFans = 1001, DisplayName = "Growing Crowd", MeshScale = Vector3.new(1.6, 1.6, 1.6) },
		{ MinFans = 10001, DisplayName = "Big Crowd", MeshScale = Vector3.new(2, 2, 2) },
		{ MinFans = 100001, DisplayName = "Superstar Crowd", MeshScale = Vector3.new(2.5, 2.5, 2.5) },
	},
}

return FanBoxTiers

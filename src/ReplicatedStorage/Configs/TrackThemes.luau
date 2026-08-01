--!strict
--[[
	TrackThemes
	8 lightweight visual/material reskins for the oval track's Straight and
	Curve pieces — NOT the original 7-entry hazard-biome catalog this file
	used to hold (bespoke floating-platform/maze/tsunami geometry that
	didn't fit inside the existing piece-chaining oval at all, and was
	never built). Superseded per direct instruction to go back to building
	on the single oval track: every theme here works through the SAME
	TrackPieceBuilder.BuildStraight/BuildCurve contract as the plain
	default look — only RoadColor/RoadMaterial/BarrierColor change — so any
	theme can be dropped onto any segment of the oval with no special-case
	geometry. TrackGenerator picks 2-4 of these at random per generation
	and spreads them across the oval's 4 straight/curve pairs (see its
	docstring).

	WalkSpeedModifier is real config data but NOT wired to live gameplay
	yet — there's no terrain-zone spatial-query system reading it (that
	would be a real, separate feature: detect which theme's road segment a
	player is standing on and apply the multiplier via MovementModifier).
	Flagged here rather than silently ignored so it's clear this is a
	planned hook, not a bug.
]]

export type TrackTheme = {
	Id: string,
	DisplayName: string,
	RoadColor: Color3,
	RoadMaterial: Enum.Material,
	BarrierColor: Color3,
	WalkSpeedModifier: number, -- ambient multiplier while standing on this theme's road; see module docstring
	HazardTag: string, -- flavor identifier, for future theme-specific hazard behavior
}

export type TrackThemesType = { [string]: TrackTheme }

local TrackThemes: TrackThemesType = {
	Classic = {
		Id = "Classic",
		DisplayName = "Classic Oval",
		RoadColor = Color3.fromRGB(70, 70, 78),
		RoadMaterial = Enum.Material.Concrete,
		BarrierColor = Color3.fromRGB(150, 40, 40),
		WalkSpeedModifier = 1.0,
		HazardTag = "None",
	},
	HillMud = {
		Id = "HillMud",
		DisplayName = "Hill & Mud",
		RoadColor = Color3.fromRGB(92, 64, 38),
		RoadMaterial = Enum.Material.Mud,
		BarrierColor = Color3.fromRGB(64, 46, 30),
		WalkSpeedModifier = 0.85,
		HazardTag = "Mud",
	},
	IceFrost = {
		Id = "IceFrost",
		DisplayName = "Ice & Frost",
		RoadColor = Color3.fromRGB(196, 226, 240),
		RoadMaterial = Enum.Material.Ice,
		BarrierColor = Color3.fromRGB(120, 170, 200),
		WalkSpeedModifier = 1.1,
		HazardTag = "Slippery",
	},
	Volcanic = {
		Id = "Volcanic",
		DisplayName = "Volcanic Ridge",
		RoadColor = Color3.fromRGB(120, 45, 20),
		RoadMaterial = Enum.Material.CrackedLava,
		BarrierColor = Color3.fromRGB(60, 30, 20),
		WalkSpeedModifier = 0.9,
		HazardTag = "Heat",
	},
	WaterDock = {
		Id = "WaterDock",
		DisplayName = "Water & Docks",
		RoadColor = Color3.fromRGB(150, 110, 70),
		RoadMaterial = Enum.Material.WoodPlanks,
		BarrierColor = Color3.fromRGB(70, 140, 160),
		WalkSpeedModifier = 0.9,
		HazardTag = "Slippery",
	},
	SkyRail = {
		Id = "SkyRail",
		DisplayName = "Sky Rail",
		RoadColor = Color3.fromRGB(210, 210, 218),
		RoadMaterial = Enum.Material.Metal,
		BarrierColor = Color3.fromRGB(120, 120, 130),
		WalkSpeedModifier = 1.0,
		HazardTag = "Height",
	},
	Desert = {
		Id = "Desert",
		DisplayName = "Desert Dunes",
		RoadColor = Color3.fromRGB(214, 186, 130),
		RoadMaterial = Enum.Material.Sand,
		BarrierColor = Color3.fromRGB(150, 120, 80),
		WalkSpeedModifier = 0.8,
		HazardTag = "Heat",
	},
	NeonCircuit = {
		Id = "NeonCircuit",
		DisplayName = "Neon Circuit",
		RoadColor = Color3.fromRGB(120, 40, 200),
		RoadMaterial = Enum.Material.Neon,
		BarrierColor = Color3.fromRGB(255, 0, 200),
		WalkSpeedModifier = 1.05,
		HazardTag = "FastLane",
	},
}

return TrackThemes

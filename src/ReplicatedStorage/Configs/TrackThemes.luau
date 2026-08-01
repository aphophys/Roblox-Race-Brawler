--!strict
--[[
	TrackThemes
	Catalog of the requested hazard/biome variants beyond the core oval.
	This is a PLANNING artifact — schema + design data are real and locked,
	but no geometry exists yet (see ThemedTrackBuilder, which is a stub).
	Each theme is scoped to layer onto the same piece-chaining approach as
	the core oval (TrackPieceBuilder) rather than being hand-placed, since
	there's no Toolbox/marketplace access to place hand-built models with.
]]

export type MovementStat = "WalkSpeed" | "ClimbSpeed" | "SwimSpeed"

export type TrackTheme = {
	Id: string,
	DisplayName: string,
	DifficultyTier: number, -- 1 (easiest) .. 5 (hardest)
	HazardTags: { string },
	AmbientStatModifiers: { [string]: number }, -- MovementStat -> multiplier while standing in themed terrain
	FallIsLethal: boolean, -- true: falling off costs a life immediately (GrandPrixManager.HandleRacerDown), not just a knockback
	BuildNotes: string, -- what TrackGenerator/ThemedTrackBuilder still needs to do
}

export type TrackThemesType = { [string]: TrackTheme }

local TrackThemes: TrackThemesType = {
	HillMud = {
		Id = "HillMud",
		DisplayName = "Hill & Mud",
		DifficultyTier = 2,
		HazardTags = { "Mud", "Incline" },
		AmbientStatModifiers = { WalkSpeed = 0.6 },
		FallIsLethal = false,
		BuildNotes = "Sloped Straight pieces (tilt the road slab) + a mud material zone that applies AmbientStatModifiers on entry/exit (spatial query, not .Touched).",
	},
	DeathPitFloating = {
		Id = "DeathPitFloating",
		DisplayName = "Death Pit (Floating Blocks)",
		DifficultyTier = 4,
		HazardTags = { "FloatingPlatforms", "Pit", "Timing" },
		AmbientStatModifiers = {},
		FallIsLethal = true,
		BuildNotes = "No road slab — replace with a chain of small floating platforms (some moving via TweenService loops) over a bottomless pit; missing a jump = fall = lethal.",
	},
	HighTracks = {
		Id = "HighTracks",
		DisplayName = "High Tracks",
		DifficultyTier = 4,
		HazardTags = { "Height", "NarrowPath" },
		AmbientStatModifiers = {},
		FallIsLethal = true,
		BuildNotes = "Same Straight/Curve pieces as the core oval but elevated well above baseplate and narrowed (reduce TrackGeometry.SegmentWidth for this theme specifically); no safety net below.",
	},
	WaterIsland = {
		Id = "WaterIsland",
		DisplayName = "Water & Islands",
		DifficultyTier = 3,
		HazardTags = { "Water", "Swimming", "Islands" },
		AmbientStatModifiers = { SwimSpeed = 1.0, WalkSpeed = 0.9 },
		FallIsLethal = false,
		BuildNotes = "Terrain water region connecting small island platforms (road-slab islands); relies on MovementModifier reading SwimSpeed while Humanoid.FloorMaterial/state indicates swimming.",
	},
	Tsunami = {
		Id = "Tsunami",
		DisplayName = "Tsunami",
		DifficultyTier = 5,
		HazardTags = { "Water", "MovingHazard", "Timing" },
		AmbientStatModifiers = { SwimSpeed = 0.8 },
		FallIsLethal = false,
		BuildNotes = "Periodic wave hazard: a moving wall of Terrain water (or a fast-moving invisible push-volume) that sweeps the track on a timer and displaces racers; needs its own timer loop, not built yet.",
	},
	EasyMaze = {
		Id = "EasyMaze",
		DisplayName = "Easy Maze",
		DifficultyTier = 1,
		HazardTags = { "Maze", "NoTimer" },
		AmbientStatModifiers = {},
		FallIsLethal = false,
		BuildNotes = "Grid of low walls forming a branching path back to the main oval; no fall risk, intended as a breather/exploration segment rather than a hazard.",
	},
	ClimbSlide = {
		Id = "ClimbSlide",
		DisplayName = "Climb & Slide",
		DifficultyTier = 3,
		HazardTags = { "Climbing", "Sliding" },
		AmbientStatModifiers = { ClimbSpeed = 0.8 },
		FallIsLethal = false,
		BuildNotes = "Vertical TrussPart or ladder-tagged climb section up, then a frictionless slide (low-friction Part ramp) back down; ClimbSpeed modifier applies only while Humanoid:GetState() == Climbing.",
	},
}

return TrackThemes

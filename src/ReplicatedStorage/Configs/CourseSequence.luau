--!strict
--[[
	CourseSequence
	The whole Grand Prix course is 8 track types played in order — the core
	Oval plus the 7 themed tracks in TrackThemes — with exactly one
	checkpoint per type, cleared on finishing it. 8 types, 8 checkpoints,
	CheckpointOrdinal 1-8 spans the WHOLE course, not just one track type
	(TrackBlueprints' internal segment ordering is a different, smaller
	numbering scope — see its CheckpointOrdinal comment).

	Order below is a placeholder difficulty ramp (Oval as an easy opener,
	Tsunami last as the hardest per TrackThemes.DifficultyTier) — reorder
	freely, nothing else depends on this specific sequence yet. Only the
	Oval stop has real geometry today; the rest point at TrackThemes entries
	that are still design-only (see ThemedTrackBuilder).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackThemes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackThemes"))

export type CourseStop = {
	Order: number, -- 1..8, play order
	TrackThemeId: string?, -- key into the TrackThemes module; nil for the core Oval, which isn't a "theme"
	DisplayName: string,
	CheckpointOrdinal: number, -- equals Order; separate field so call sites read intent, not position
}

export type CourseSequenceType = {
	Stops: { CourseStop },
}

local CourseSequence: CourseSequenceType = {
	Stops = {
		{ Order = 1, TrackThemeId = nil, DisplayName = "Oval", CheckpointOrdinal = 1 },
		{ Order = 2, TrackThemeId = "EasyMaze", DisplayName = TrackThemes.EasyMaze.DisplayName, CheckpointOrdinal = 2 },
		{ Order = 3, TrackThemeId = "HillMud", DisplayName = TrackThemes.HillMud.DisplayName, CheckpointOrdinal = 3 },
		{ Order = 4, TrackThemeId = "ClimbSlide", DisplayName = TrackThemes.ClimbSlide.DisplayName, CheckpointOrdinal = 4 },
		{ Order = 5, TrackThemeId = "WaterIsland", DisplayName = TrackThemes.WaterIsland.DisplayName, CheckpointOrdinal = 5 },
		{ Order = 6, TrackThemeId = "HighTracks", DisplayName = TrackThemes.HighTracks.DisplayName, CheckpointOrdinal = 6 },
		{ Order = 7, TrackThemeId = "DeathPitFloating", DisplayName = TrackThemes.DeathPitFloating.DisplayName, CheckpointOrdinal = 7 },
		{ Order = 8, TrackThemeId = "Tsunami", DisplayName = TrackThemes.Tsunami.DisplayName, CheckpointOrdinal = 8 },
	},
}

return CourseSequence

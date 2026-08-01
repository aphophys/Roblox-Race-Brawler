--!strict
--[[
	ThemedTrackBuilder
	Dispatch stub for the 7 hazard biomes cataloged in ReplicatedStorage.
	Configs.TrackThemes. Not wired into Init() yet — the core oval
	(TrackGenerator) is the only thing that actually builds geometry today.
	Each theme's BuildNotes field describes what its Build* function needs.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackThemes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackThemes"))

local ThemedTrackBuilder = {}

local function buildHillMud(parent: Instance)
	-- TODO: see TrackThemes.HillMud.BuildNotes
end

local function buildDeathPitFloating(parent: Instance)
	-- TODO: see TrackThemes.DeathPitFloating.BuildNotes
end

local function buildHighTracks(parent: Instance)
	-- TODO: see TrackThemes.HighTracks.BuildNotes
end

local function buildWaterIsland(parent: Instance)
	-- TODO: see TrackThemes.WaterIsland.BuildNotes
end

local function buildTsunami(parent: Instance)
	-- TODO: see TrackThemes.Tsunami.BuildNotes
end

local function buildEasyMaze(parent: Instance)
	-- TODO: see TrackThemes.EasyMaze.BuildNotes
end

local function buildClimbSlide(parent: Instance)
	-- TODO: see TrackThemes.ClimbSlide.BuildNotes
end

local themeBuilders: { [string]: (Instance) -> () } = {
	HillMud = buildHillMud,
	DeathPitFloating = buildDeathPitFloating,
	HighTracks = buildHighTracks,
	WaterIsland = buildWaterIsland,
	Tsunami = buildTsunami,
	EasyMaze = buildEasyMaze,
	ClimbSlide = buildClimbSlide,
}

function ThemedTrackBuilder.Build(themeId: string, parent: Instance)
	local builder = themeBuilders[themeId]
	if builder == nil then
		error(`ThemedTrackBuilder: no builder registered for theme "{themeId}"`)
	end

	assert(TrackThemes[themeId] ~= nil, `ThemedTrackBuilder: "{themeId}" is not in TrackThemes`)
	builder(parent)
end

return ThemedTrackBuilder

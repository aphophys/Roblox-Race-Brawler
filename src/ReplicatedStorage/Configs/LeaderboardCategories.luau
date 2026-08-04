--!strict
--[[
	LeaderboardCategories
	The four stadium boards, in one config: what each ranks, which profile
	field feeds it, and how a value is rendered.

	Shared (ReplicatedStorage) rather than server-only because the board
	renderer needs the titles and value formatting, and the server needs the
	field names and sort direction — keeping them in one table is what stops
	a board being captioned "RICHEST" while showing fan counts.
]]

export type LeaderboardCategory = {
	Id: string,
	-- The epithet on the board. These are deliberately titles a player would
	-- want to hold rather than descriptions of a statistic.
	Title: string,
	Subtitle: string,
	-- Field on ProfileData that feeds this board.
	ProfileField: string,
	-- true = a LOWER value is better (fastest lap). Everything else is
	-- "more is better". This one flag drives both the OrderedDataStore sort
	-- direction and which end of the list is rank 1.
	LowerIsBetter: boolean,
	-- Values of 0 are excluded. Matters most for the lap-time board, where a
	-- player with no timed lap would otherwise rank first with a time of 0.
	ExcludeZero: boolean,
	AccentColor: Color3,
	ValueSuffix: string,
	-- "Number" = thousands-separated integer. "LapTime" = milliseconds
	-- rendered as m:ss.mmm.
	ValueFormat: "Number" | "LapTime",
}

export type LeaderboardCategoriesType = {
	Ordered: { LeaderboardCategory },
	ById: { [string]: LeaderboardCategory },
}

local ordered: { LeaderboardCategory } = {
	{
		Id = "Laps",
		-- The user's own suggestion, kept: it sits in the same register as
		-- the other three (an epithet for the person, not a label for the
		-- number). "Lap Legend" was the alternative considered.
		Title = "THE MARATHONER",
		Subtitle = "MOST LAPS COMPLETED",
		ProfileField = "TotalLapsCompleted",
		LowerIsBetter = false,
		ExcludeZero = true,
		AccentColor = Color3.fromRGB(90, 210, 255),
		ValueSuffix = " laps",
		ValueFormat = "Number",
	},
	{
		Id = "Fans",
		Title = "THE MOST FAMOUS",
		Subtitle = "MOST FANS EARNED",
		ProfileField = "TotalFans",
		LowerIsBetter = false,
		ExcludeZero = true,
		AccentColor = Color3.fromRGB(255, 105, 180),
		ValueSuffix = " fans",
		ValueFormat = "Number",
	},
	{
		Id = "Gold",
		Title = "THE RICHEST",
		Subtitle = "MOST GOLD HELD",
		ProfileField = "Gold",
		LowerIsBetter = false,
		ExcludeZero = true,
		AccentColor = Color3.fromRGB(255, 205, 60),
		ValueSuffix = " gold",
		ValueFormat = "Number",
	},
	{
		Id = "BestLap",
		Title = "THE FASTEST MAN ALIVE",
		Subtitle = "QUICKEST SINGLE LAP",
		ProfileField = "BestLapTimeMs",
		LowerIsBetter = true,
		ExcludeZero = true,
		AccentColor = Color3.fromRGB(80, 230, 120),
		ValueSuffix = "",
		ValueFormat = "LapTime",
	},
}

local byId: { [string]: LeaderboardCategory } = {}
for _, category in ordered do
	byId[category.Id] = category
end

local LeaderboardCategories: LeaderboardCategoriesType = {
	Ordered = ordered,
	ById = byId,
}

return LeaderboardCategories

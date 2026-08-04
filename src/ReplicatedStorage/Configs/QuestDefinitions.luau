--!strict
--[[
	QuestDefinitions
	The daily quest / achievement ladders, in one config. Lives in
	ReplicatedStorage because the client has to RENDER them (names, targets,
	reward amounts, how far along you are) — but nothing here is trusted at
	claim time: QuestService re-reads this same module server-side and pays
	from its own copy, so a tampered client can only mislead its own UI.

	Five categories, each a ladder of ascending tiers:

	  Playtime   9 gold tiers    time logged in TODAY
	  Laps       5 fan tiers     laps completed TODAY
	  Poses      4 fan tiers     Fan Box poses performed TODAY
	  DailyLogin 7 gold tiers    consecutive days logged in
	  Invite     5 fan tiers     friends who joined on your invite (LIFETIME)

	## Why tiers are a ladder and not a set of independent flags

	Claim state is stored as a single number per category — the highest tier
	claimed so far — rather than a set of booleans. That makes the one rule
	that actually matters ("a reward is paid exactly once") a comparison
	instead of a bookkeeping exercise: a claim is legal only for tier
	`claimed + 1`, and only when progress has genuinely reached that tier's
	requirement. There is no way to claim out of order, no way to claim twice,
	and no way for a partially-written save to leave a gap. It also means
	tiers must stay in ASCENDING requirement order — see the assertion below,
	which runs on first require rather than trusting the author.

	## Daily reset

	Playtime, Laps and Poses reset every day; their claim counters reset with
	them, which is what makes them repeatable dailies. DailyLogin's ladder
	tracks a STREAK, so it resets only when the streak breaks. Invite never
	resets — it is an achievement, not a daily.
]]

export type QuestRewardCurrency = "Gold" | "Fans"

export type QuestTier = {
	Requirement: number, -- progress needed, in the category's own ProgressUnit
	Reward: number,
}

export type QuestCategory = {
	Id: string,
	DisplayName: string,
	Description: string,
	RewardCurrency: QuestRewardCurrency,
	-- true = progress AND claim state are wiped at the day boundary.
	ResetsDaily: boolean,
	-- Purely for the UI's progress line ("12 / 20 laps"). The server never
	-- reads it; it exists so the client doesn't have to hard-code a label per
	-- category and drift from the config.
	ProgressUnit: string,
	Tiers: { QuestTier },
}

export type QuestDefinitionsType = {
	Categories: { QuestCategory },
	ById: { [string]: QuestCategory },
	TotalTierCount: number,
}

local categories: { QuestCategory } = {
	{
		Id = "Playtime",
		DisplayName = "Time on Track",
		Description = "Stay in the game today. Rewards get bigger the longer you're here.",
		RewardCurrency = "Gold",
		ResetsDaily = true,
		ProgressUnit = "min",
		-- 9 tiers, per spec ("typical how long player logged incremental up to
		-- 9 rewards (gold)"). Front-loaded so a short session still pays
		-- something — the first reward lands after one minute, which is what
		-- makes a new player notice the system exists at all.
		Tiers = {
			{ Requirement = 1, Reward = 25 },
			{ Requirement = 3, Reward = 50 },
			{ Requirement = 5, Reward = 75 },
			{ Requirement = 10, Reward = 125 },
			{ Requirement = 15, Reward = 175 },
			{ Requirement = 20, Reward = 250 },
			{ Requirement = 30, Reward = 350 },
			{ Requirement = 45, Reward = 500 },
			{ Requirement = 60, Reward = 750 },
		},
	},
	{
		Id = "Laps",
		DisplayName = "Laps Today",
		Description = "Complete laps on the track. Resets daily.",
		RewardCurrency = "Fans",
		ResetsDaily = true,
		ProgressUnit = "laps",
		Tiers = {
			{ Requirement = 1, Reward = 20 },
			{ Requirement = 3, Reward = 50 },
			{ Requirement = 5, Reward = 100 },
			{ Requirement = 10, Reward = 200 },
			{ Requirement = 20, Reward = 400 },
		},
	},
	{
		Id = "Poses",
		DisplayName = "Play to the Crowd",
		Description = "Pose for your fans at your Fan Box. Resets daily.",
		-- Fans, not Gold: posing is the one activity that is explicitly about
		-- the crowd, and the Gold side of it is already covered by the
		-- ten-minute tip (EconomyRates.PoseRewardGold). Paying Gold here too
		-- would make one action pay the same currency twice from two systems.
		RewardCurrency = "Fans",
		ResetsDaily = true,
		ProgressUnit = "poses",
		-- Shallower than the Laps ladder on purpose. A pose costs nothing but
		-- a button press, so the ladder has to top out somewhere a player
		-- reaches by playing rather than by standing in their Fan Box pressing
		-- POSE — the 3-second cooldown in TeleportPoseService makes 15 poses
		-- about 45 seconds of pure spam, which is why the top tier is not
		-- worth farming that way.
		Tiers = {
			{ Requirement = 1, Reward = 25 },
			{ Requirement = 3, Reward = 50 },
			{ Requirement = 7, Reward = 100 },
			{ Requirement = 15, Reward = 200 },
		},
	},
	{
		Id = "DailyLogin",
		DisplayName = "Daily Login",
		Description = "Log in on consecutive days. Miss a day and the streak restarts.",
		RewardCurrency = "Gold",
		-- NOT ResetsDaily: the ladder tracks a streak, so it is reset by the
		-- streak breaking, not by the calendar. QuestService owns that rule.
		ResetsDaily = false,
		ProgressUnit = "days",
		Tiers = {
			{ Requirement = 1, Reward = 50 },
			{ Requirement = 2, Reward = 75 },
			{ Requirement = 3, Reward = 100 },
			{ Requirement = 4, Reward = 150 },
			{ Requirement = 5, Reward = 200 },
			{ Requirement = 6, Reward = 300 },
			{ Requirement = 7, Reward = 500 },
		},
	},
	{
		Id = "Invite",
		DisplayName = "Bring Your Friends",
		Description = "Invite friends to the race. 100 fans each, up to 5 friends.",
		RewardCurrency = "Fans",
		ResetsDaily = false,
		ProgressUnit = "friends",
		-- Flat 100 per successful invite, capped at 5 friends / 500 fans. A flat
		-- rate rather than an escalating ladder because the reward is per
		-- INVITE, not for reaching a milestone — the second friend is worth the
		-- same to the game as the first, and an escalating curve would tell
		-- players the opposite.
		Tiers = {
			{ Requirement = 1, Reward = 100 },
			{ Requirement = 2, Reward = 100 },
			{ Requirement = 3, Reward = 100 },
			{ Requirement = 4, Reward = 100 },
			{ Requirement = 5, Reward = 100 },
		},
	},
}

local byId: { [string]: QuestCategory } = {}
local totalTierCount = 0

for _, category in categories do
	byId[category.Id] = category
	totalTierCount += #category.Tiers

	-- The ladder invariant the whole claim rule rests on. A descending or
	-- equal pair would make "claim tier claimed+1 once progress >= its
	-- requirement" pay a later tier for less progress than an earlier one —
	-- i.e. a live economy exploit produced by a typo in a config. Cheaper to
	-- assert once on first require than to discover from a payout report.
	for index = 2, #category.Tiers do
		assert(
			category.Tiers[index].Requirement > category.Tiers[index - 1].Requirement,
			`QuestDefinitions: {category.Id} tier {index} requirement must exceed tier {index - 1}`
		)
	end
end

local QuestDefinitions: QuestDefinitionsType = {
	Categories = categories,
	ById = byId,
	TotalTierCount = totalTierCount,
}

return QuestDefinitions

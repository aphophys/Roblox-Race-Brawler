--!strict
--[[
	ProfileTemplate
	Default data shape for a new player's ProfileStore profile.

	Lives in ServerStorage (not ReplicatedStorage) on purpose: ProfileStore
	templates are the authoritative save schema and must never be reachable
	from the client. Anything the client needs to see should be replicated
	explicitly (e.g. via leaderstats or a filtered RemoteEvent payload) rather
	than by exposing this module directly.
]]

export type SkillData = {
	Level: number,
	Unlocked: boolean,
}

-- Everything the quest/achievement ladders need to survive a rejoin. Split
-- into its own sub-table rather than flattened into ProfileData so the whole
-- system can be reasoned about (and reset, and audited) as one unit.
export type QuestData = {
	-- Day number (os.time() // 86400) the daily categories were last rolled
	-- over. Compared against today on every join AND on a periodic tick, so a
	-- session left running across midnight rolls over too rather than only
	-- resetting for players who rejoin.
	LastResetDay: number,
	PlaytimeSecondsToday: number,
	LapsToday: number,
	-- Fan Box poses performed today, feeding the Poses quest ladder. Zeroed
	-- by the same daily reset as LapsToday. Distinct from
	-- ProfileData.LastPoseRewardWindow, which gates the ten-minute GOLD tip:
	-- one counts the action, the other rations the payment for it.
	PosesToday: number,

	-- Login streak. LastLoginDay is what makes the streak decidable without
	-- storing a history: same day = no change, yesterday = +1, anything older
	-- = the streak broke and restarts at 1.
	LoginStreakDays: number,
	LastLoginDay: number,

	-- Lifetime, never reset. InvitedUserIds is the dedupe set that stops the
	-- same friend being re-invited for repeat credit — without it the whole
	-- Invite ladder is farmable by two accounts rejoining each other.
	InvitesAccepted: number,
	InvitedUserIds: { [string]: boolean },

	-- QuestDefinitions category Id -> highest tier index already paid out.
	-- A single number per category, not a set of flags: see the claim rule in
	-- QuestDefinitions' docstring. Absent key means 0 claimed.
	ClaimedTierByCategory: { [string]: number },
	-- Category Id -> the day number that category's claim count belongs to.
	-- This is what makes a daily reward genuinely once-per-day: for a
	-- ResetsDaily category the claim count is only believed when its stamp is
	-- TODAY, so the ladder re-opens by the calendar rather than by a reset
	-- pass having successfully run. Without the stamp, a missed reset would
	-- leave yesterday's claims blocking today's rewards, and a double-applied
	-- one could re-open a ladder that was already paid.
	ClaimedDayByCategory: { [string]: number },

	-- Running audit totals of what the quest system has actually paid this
	-- profile, ever. Deliberately separate from Gold/TotalFans (which every
	-- other system also writes) so "did quests pay what they should have"
	-- stays an answerable question after the fact.
	LifetimeQuestGold: number,
	LifetimeQuestFans: number,
}

export type ProfileData = {
	Gold: number,
	TotalFans: number,
	Lives: number,
	-- Daily cap on free (Gold) extra-life revives — resets when
	-- GoldRevivesLastResetDay falls behind the current day number (see
	-- EconomyRates.ExtraLifeGoldDailyLimit / ArcadeManager). Robux revives
	-- are NOT tracked here — unlimited, per spec.
	GoldRevivesUsedToday: number,
	GoldRevivesLastResetDay: number,
	LastCheckpointOrdinal: number,
	TotalLapsCompleted: number, -- incremented by CheckpointValidator whenever checkpoint 8 -> 1 (a full lap)
	-- Best (lowest) single-lap time in MILLISECONDS, across both Arcade and
	-- Grand Prix — whichever produced the faster lap. Milliseconds rather
	-- than seconds because the leaderboard is an OrderedDataStore, and those
	-- only accept integers; storing 87.42s as 87420 keeps the precision that
	-- makes a lap-time board worth reading.
	-- 0 means "no timed lap yet" and must be excluded from the board, or an
	-- untimed player would rank first on a fastest-lap board.
	BestLapTimeMs: number,
	-- Utils.GlobalWindowIndex values, one per periodic bonus: the last window
	-- in which this player was paid it. Persisted rather than kept in memory
	-- precisely BECAUSE the reward is generous — an in-memory record would be
	-- cleared by a rejoin, which turns "5x once every ten minutes" into "5x
	-- whenever you feel like reconnecting". 0 means never paid, and since no
	-- real window index is ever 0 that reads as eligible on a fresh profile,
	-- the same convention GoldRevivesLastResetDay uses.
	LastDepositBonusWindow: number,
	LastPoseRewardWindow: number,
	-- Day number (os.time() // 86400) the DailyBonus game pass last paid this
	-- profile. Same "actual wall-clock day" basis every other daily reward here
	-- uses (GoldRevivesLastResetDay, Quests.LastResetDay/LastLoginDay), so the
	-- reward lands on a real calendar boundary rather than N hours after
	-- whenever the player happened to last collect it.
	--
	-- Persisted, and that is the entire anti-farm mechanism: an in-memory record
	-- would reset on rejoin, turning "once a day" into "once per reconnect".
	-- 0 = never paid, which reads as due on a fresh profile — the same
	-- convention as LastDepositBonusWindow above.
	LastDailyPassRewardDay: number,
	Skills: { [string]: SkillData },
	-- Fixed 3-slot loadout — which owned skill Skill1/2/3 casts while
	-- InRace. nil slot = empty. LoadoutService enforces no skill occupying
	-- two slots at once.
	EquippedSkills: { string? },
	Inventory: { string },
	Settings: {
		MusicEnabled: boolean,
		SfxEnabled: boolean,
	},
	-- Has this player been shown the first-run tutorial. A persisted flag
	-- rather than something inferred from progress (TotalLapsCompleted == 0 and
	-- the like): a player who watches the tutorial and then logs off before
	-- finishing a lap must not be shown it again, and a player who deliberately
	-- skipped it must not have it forced back on them next session.
	TutorialCompleted: boolean,
	-- Keyed by receiptInfo.PurchaseId. ProcessReceiptManager checks this
	-- before granting anything, so a retried/duplicate receipt (Roblox
	-- redelivers until ProcessReceipt returns PurchaseGranted) never grants
	-- twice.
	GrantedPurchaseIds: { [string]: boolean },

	Quests: QuestData,
}

local ProfileTemplate: ProfileData = {
	Gold = 0,
	TotalFans = 0,
	Lives = 3,
	GoldRevivesUsedToday = 0,
	GoldRevivesLastResetDay = 0, -- 0 forces ArcadeManager's day-rollover check to reset on first use for a brand-new profile, same as any other day boundary
	LastCheckpointOrdinal = 1,
	TotalLapsCompleted = 0,
	BestLapTimeMs = 0,
	LastDepositBonusWindow = 0,
	LastPoseRewardWindow = 0,
	LastDailyPassRewardDay = 0,
	-- The 3 basic skills every player starts with, per spec: Position Swap,
	-- Reverse Control, Dash. Pre-equipped in the same order.
	Skills = {
		PositionSwap = { Level = 1, Unlocked = true },
		ReverseControlTarget = { Level = 1, Unlocked = true },
		DashSelf = { Level = 1, Unlocked = true },
	},
	EquippedSkills = { "PositionSwap", "ReverseControlTarget", "DashSelf" },
	Inventory = {},
	Settings = {
		MusicEnabled = true,
		SfxEnabled = true,
	},
	-- false on a brand-new profile, which is exactly what makes the tutorial
	-- fire once. ProfileStore back-fills this default onto profiles saved
	-- before the field existed, so returning players are treated as new for
	-- the tutorial only — a one-off, and the cheapest correct behaviour.
	TutorialCompleted = false,
	GrantedPurchaseIds = {},

	Quests = {
		-- 0 forces the day-rollover check to fire on a brand-new profile's
		-- first tick, exactly like GoldRevivesLastResetDay above.
		LastResetDay = 0,
		PlaytimeSecondsToday = 0,
		LapsToday = 0,
		PosesToday = 0,
		LoginStreakDays = 0,
		LastLoginDay = 0,
		InvitesAccepted = 0,
		InvitedUserIds = {},
		ClaimedTierByCategory = {},
		ClaimedDayByCategory = {},
		LifetimeQuestGold = 0,
		LifetimeQuestFans = 0,
	},
}

return ProfileTemplate

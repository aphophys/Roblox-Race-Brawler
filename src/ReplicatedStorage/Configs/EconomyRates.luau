--!strict
--[[
	EconomyRates
	Single source of truth for currency conversion: Fan deposit payouts and
	Commercial Hub upgrade costs. Read by ProfileManager / HubShoppingManager.
]]

export type UpgradeCost = {
	Level: number,
	GoldCost: number,
}

-- One payout tier. Index in the list IS the place (1 = best).
export type PlacementReward = {
	Gold: number,
	Fans: number,
}

-- Keyed by SkillTrees.SkillCastType. Spelled out as its own type rather than
-- { [string]: number } so a typo in a key is a type error here rather than a
-- silent nil (and therefore a silently unpaid) reward at the call site.
export type SkillCastFanRewardTable = {
	Self: number,
	Target: number,
	Global: number,
}

export type EconomyRatesType = {
	FanDepositGoldPerFan: number,
	FanDepositBonusThreshold: number,
	FanDepositBonusMultiplier: number,
	LapCompletionGoldReward: number, -- granted once per completed lap (checkpoint 8 -> back to 1), by CheckpointValidator
	LapCompletionFanReward: number,
	-- Granted for EVERY checkpoint crossed (1-7; the 8th is the lap and pays
	-- the lap reward instead, so a lap is never paid twice). Small on
	-- purpose: it exists so progress feels continuous rather than arriving in
	-- one lump at the finish line.
	CheckpointFanReward: number,

	-- Fans paid to the CASTER for a skill that successfully goes off, keyed by
	-- the skill's own CastType so the lookup cannot drift out of step with
	-- SkillTrees (SkillDefinition.CastType is exactly these three strings).
	--
	-- Scaled by how much of the field the cast reaches, not by how hard it is
	-- to land: a Self buff helps one racer, a Target debuff has to be aimed at
	-- somebody and lands on two people's races, and a Global hits everyone
	-- still running. Paid by SkillRewardService, which is also where "success"
	-- is defined per cast type — see its docstring.
	SkillCastFanRewards: SkillCastFanRewardTable,

	-- Passive income: every FanIncomeIntervalSeconds, each player earns
	-- FanIncomeGoldPerFan gold for each fan they hold. Fans are the long-term
	-- stat and Gold is the spendable one, so this is what makes accumulating
	-- fans worth doing beyond the fan-box crowd size.
	--
	-- PROVISIONAL, like the Grand Prix ladders: 0.02 means 1 gold per 50 fans
	-- every 5 minutes. Deliberately a rate rather than a flat trickle so it
	-- scales with the stat it is rewarding, and deliberately small because it
	-- compounds against a total that only ever grows.
	FanIncomeGoldPerFan: number,
	FanIncomeIntervalSeconds: number,

	-- ===== Periodic bonuses, gated on Utils.GlobalWindowIndex =====
	--
	-- Both of these pay out at most once per wall-clock window rather than
	-- once per N seconds since the player last claimed. See the long note on
	-- Utils.GlobalWindowIndex for why: a per-player elapsed-time check is a
	-- private clock, and a private clock restarts when a player rejoins.
	--
	-- Carrying a fan payload the whole way to a deposit zone is the longest
	-- uninterrupted risk in the game — it can be lost to any hazard, any
	-- shove, and any Shock cast the entire way — and it previously paid the
	-- same as picking one up next to the zone. This makes the trip worth
	-- making, while the window stops it becoming the only thing anyone does.
	DepositBonusMultiplier: number,
	DepositBonusIntervalSeconds: number,

	-- Posing in your Fan Box: a flat Gold tip from the crowd, once per window.
	-- Flat rather than scaled by fans, because unlike FanIncome this rewards
	-- an ACTION, and an action should pay a beginner the same as a veteran.
	PoseRewardGold: number,
	PoseRewardIntervalSeconds: number,

	SpeedUpgradeCosts: { UpgradeCost },
	CarryCapacityUpgradeCosts: { UpgradeCost },

	-- Revive-on-elimination (ArcadeManager) — Robux revives (MonetizationConfigs.
	-- DeveloperProducts.ExtraLife) are unlimited, per spec; Gold revives are
	-- capped per real-world day.
	ExtraLifeGoldCost: number,
	ExtraLifeGoldDailyLimit: number,
	EliminationTimeoutSeconds: number, -- how long the revive-choice window stays open before auto-returning to the Hub

	-- MonetizationConfigs.GamePasses.DoubleFans ("Double Gain Fans and
	-- Gold") — applied to fan-deposit and lap-completion rewards wherever
	-- MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") is true.
	DoubleGainMultiplier: number,

	-- MonetizationConfigs.GamePasses.DailyBonus — paid once per calendar day
	-- to anyone who owns that pass, by DailyPassRewardService.
	--
	-- Deliberately NOT multiplied by DoubleGainMultiplier even for a player who
	-- also owns DoubleFans. That pass says it doubles what you EARN, and this
	-- is not earned — it is the other pass paying out. Stacking two passes into
	-- a single automatic daily payment is a pricing decision, not a reward rule,
	-- and it should be made deliberately rather than fall out of the fact that
	-- both happen to touch Gold and Fans.
	DailyPassGoldReward: number,
	DailyPassFanReward: number,

	-- Grand Prix payouts (GrandPrixManager.enterEnded). Two independent
	-- ladders, both 5 places deep, and a racer can legitimately draw from
	-- BOTH — winning the race and also being among the last standing is one
	-- performance, not two competing ones, so it pays twice on purpose.
	-- PROVISIONAL VALUES: set as placeholders to get the loop running and
	-- payable end to end; they have not been balanced against Gold/Fan sinks.
	GrandPrixFinisherRewards: { PlacementReward }, -- by finishing order (1st past GrandPrixLapsToFinish laps = index 1)
	GrandPrixSurvivorRewards: { PlacementReward }, -- by how long they lasted (still alive at the end ranks above anyone eliminated)
}

local EconomyRates: EconomyRatesType = {
	FanDepositGoldPerFan = 1,
	FanDepositBonusThreshold = 100,
	FanDepositBonusMultiplier = 1.5,
	LapCompletionGoldReward = 10,
	LapCompletionFanReward = 5,
	CheckpointFanReward = 2,

	SkillCastFanRewards = {
		Self = 1,
		Target = 2, -- the offensive skills: everything you aim at another racer
		Global = 4,
	},

	FanIncomeGoldPerFan = 0.02,
	FanIncomeIntervalSeconds = 300,

	DepositBonusMultiplier = 5,
	DepositBonusIntervalSeconds = 600, -- 10 minutes
	PoseRewardGold = 50,
	PoseRewardIntervalSeconds = 600, -- 10 minutes

	SpeedUpgradeCosts = {
		{ Level = 1, GoldCost = 100 },
		{ Level = 2, GoldCost = 250 },
		{ Level = 3, GoldCost = 500 },
	},

	CarryCapacityUpgradeCosts = {
		{ Level = 1, GoldCost = 150 },
		{ Level = 2, GoldCost = 400 },
	},

	ExtraLifeGoldCost = 100,
	ExtraLifeGoldDailyLimit = 3,
	EliminationTimeoutSeconds = 10,

	DoubleGainMultiplier = 2,
	DailyPassGoldReward = 100,
	DailyPassFanReward = 50,

	GrandPrixFinisherRewards = {
		{ Gold = 500, Fans = 250 },
		{ Gold = 350, Fans = 175 },
		{ Gold = 250, Fans = 125 },
		{ Gold = 150, Fans = 75 },
		{ Gold = 100, Fans = 50 },
	},

	GrandPrixSurvivorRewards = {
		{ Gold = 300, Fans = 150 },
		{ Gold = 220, Fans = 110 },
		{ Gold = 160, Fans = 80 },
		{ Gold = 100, Fans = 50 },
		{ Gold = 60, Fans = 30 },
	},
}

return EconomyRates

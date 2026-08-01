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

export type EconomyRatesType = {
	FanDepositGoldPerFan: number,
	FanDepositBonusThreshold: number,
	FanDepositBonusMultiplier: number,
	SpeedUpgradeCosts: { UpgradeCost },
	CarryCapacityUpgradeCosts: { UpgradeCost },
}

local EconomyRates: EconomyRatesType = {
	FanDepositGoldPerFan = 1,
	FanDepositBonusThreshold = 100,
	FanDepositBonusMultiplier = 1.5,

	SpeedUpgradeCosts = {
		{ Level = 1, GoldCost = 100 },
		{ Level = 2, GoldCost = 250 },
		{ Level = 3, GoldCost = 500 },
	},

	CarryCapacityUpgradeCosts = {
		{ Level = 1, GoldCost = 150 },
		{ Level = 2, GoldCost = 400 },
	},
}

return EconomyRates

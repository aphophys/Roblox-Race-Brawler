--!strict
--[[
	MonetizationConfigs
	SINGLE PLACE TO PASTE REAL ROBUX IDs. Every `Id = 0` below is a
	placeholder — create the matching Developer Product / Game Pass on the
	Creator Dashboard and paste its numeric ID in here. Nothing else in the
	codebase should hardcode a product/pass ID; everything reads from here.

	ServerScriptService.Monetization.ProcessReceiptManager refuses to grant
	anything for an Id still at 0, so leaving these blank is safe — it just
	means purchases can't be tested end-to-end until real IDs are filled in.
]]

export type DeveloperProductEntry = {
	Id: number,
	Name: string,
	GrantCurrency: "Gold" | "TotalFans",
	GrantAmount: number,
}

export type GamePassEntry = {
	Id: number,
	Name: string,
	Description: string,
}

export type MonetizationConfigsType = {
	DeveloperProducts: {
		GoldSmall: DeveloperProductEntry,
		GoldMedium: DeveloperProductEntry,
		GoldLarge: DeveloperProductEntry,
		FanBoost: DeveloperProductEntry,
	},
	GamePasses: {
		ExclusivePoseBundle: GamePassEntry,
		DoubleFans: GamePassEntry,
	},
}

local MonetizationConfigs: MonetizationConfigsType = {
	DeveloperProducts = {
		GoldSmall = { Id = 0, Name = "GoldSmall", GrantCurrency = "Gold", GrantAmount = 100 },
		GoldMedium = { Id = 0, Name = "GoldMedium", GrantCurrency = "Gold", GrantAmount = 550 },
		GoldLarge = { Id = 0, Name = "GoldLarge", GrantCurrency = "Gold", GrantAmount = 1200 },
		FanBoost = { Id = 0, Name = "FanBoost", GrantCurrency = "TotalFans", GrantAmount = 250 },
	},
	GamePasses = {
		ExclusivePoseBundle = { Id = 0, Name = "ExclusivePoseBundle", Description = "Unlocks the exclusive pose set for Fan Box visits." },
		DoubleFans = { Id = 0, Name = "DoubleFans", Description = "Doubles Fan Payload deposit value while owned." },
	},
}

return MonetizationConfigs

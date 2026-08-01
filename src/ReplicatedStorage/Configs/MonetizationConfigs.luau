--!strict
--[[
	MonetizationConfigs
	SINGLE PLACE TO PASTE REAL ROBUX IDs. Nothing else in the codebase
	should hardcode a product/pass ID; everything reads from here.

	ServerScriptService.Monetization.ProcessReceiptManager refuses to grant
	anything for an Id still at 0, so leaving an entry at 0 is safe — it
	just means that purchase can't be tested end-to-end until a real ID is
	filled in. All 5 entries below now have real, live Creator Dashboard IDs.

	ExclusivePoseBundle (the pose-unlock game pass) is deliberately not
	defined here right now — pulled from the Robux Shop UI and out of this
	config per explicit instruction to hide pose monetization for now.
	PoseUIController's pose list has no real content to gate behind it yet
	anyway (still just a single hardcoded "Wave"). Re-add a GamePassEntry
	here (and the matching button in default.project.json's RobuxShopPanel/
	ShopUIController.GAME_PASS_BUTTONS) whenever that's revisited.
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
		DoubleFans: GamePassEntry,
	},
}

local MonetizationConfigs: MonetizationConfigsType = {
	DeveloperProducts = {
		-- 100 Gold — 30 Robux
		GoldSmall = { Id = 3612671273, Name = "GoldSmall", GrantCurrency = "Gold", GrantAmount = 100 },
		-- 550 Gold — 150 Robux
		GoldMedium = { Id = 3612671406, Name = "GoldMedium", GrantCurrency = "Gold", GrantAmount = 550 },
		-- 1200 Gold — 300 Robux
		GoldLarge = { Id = 3612671461, Name = "GoldLarge", GrantCurrency = "Gold", GrantAmount = 1200 },
		-- 250 Fans — 300 Robux
		FanBoost = { Id = 3612671585, Name = "FanBoost", GrantCurrency = "TotalFans", GrantAmount = 250 },
	},
	GamePasses = {
		-- "Rocket Fans and Gold" — 500 Robux, doubles Fan Payload deposit value while owned.
		DoubleFans = { Id = 1933401103, Name = "Rocket Fans and Gold", Description = "Doubles Fan Payload deposit value while owned." },
	},
}

return MonetizationConfigs

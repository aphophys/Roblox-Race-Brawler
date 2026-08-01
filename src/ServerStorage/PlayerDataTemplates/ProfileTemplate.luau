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

export type ProfileData = {
	Gold: number,
	TotalFans: number,
	Lives: number,
	LastCheckpointOrdinal: number,
	Skills: { [string]: SkillData },
	Inventory: { string },
	Settings: {
		MusicEnabled: boolean,
		SfxEnabled: boolean,
	},
	-- Keyed by receiptInfo.PurchaseId. ProcessReceiptManager checks this
	-- before granting anything, so a retried/duplicate receipt (Roblox
	-- redelivers until ProcessReceipt returns PurchaseGranted) never grants
	-- twice.
	GrantedPurchaseIds: { [string]: boolean },
}

local ProfileTemplate: ProfileData = {
	Gold = 0,
	TotalFans = 0,
	Lives = 3,
	LastCheckpointOrdinal = 1,
	-- Starter kit matches ControlMapper's default Skill1/2/3 HUD loadout
	-- (PositionSwap/SlowGlobal/DashSelf) so a fresh playtester can
	-- actually exercise all 3 CastType categories - Target, Global, and
	-- Self - without needing the shop, which is still a stub.
	Skills = {
		PositionSwap = { Level = 1, Unlocked = true },
		SlowGlobal = { Level = 1, Unlocked = true },
		DashSelf = { Level = 1, Unlocked = true },
	},
	Inventory = {},
	Settings = {
		MusicEnabled = true,
		SfxEnabled = true,
	},
	GrantedPurchaseIds = {},
}

return ProfileTemplate

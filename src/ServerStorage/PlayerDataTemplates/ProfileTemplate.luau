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
	TotalLapsCompleted: number, -- incremented by CheckpointValidator whenever checkpoint 8 -> 1 (a full lap)
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
	TotalLapsCompleted = 0,
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
	GrantedPurchaseIds = {},
}

return ProfileTemplate

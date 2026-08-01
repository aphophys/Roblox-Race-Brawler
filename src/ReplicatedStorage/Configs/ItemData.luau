--!strict
--[[
	ItemData
	Schema + data for track pickup effects and Fan Payload types.
]]

export type PickupEffect = {
	Id: string,
	DisplayName: string,
	DurationSeconds: number,
}

export type FanPayloadType = {
	Id: string,
	DisplayName: string,
	FanValue: number,
}

export type ItemDataType = {
	PickupEffects: { [string]: PickupEffect },
	FanPayloadTypes: { [string]: FanPayloadType },
	-- How long the "PickingUp" channel (CarryItemService.startFanPickupChannel)
	-- takes, in seconds. Shared here (not a CarryItemService-local constant)
	-- so the client can animate a matching progress fill on the action
	-- button without needing a remote round-trip to ask the server how long
	-- to wait.
	FanPickupChannelSeconds: number,
}

local ItemData: ItemDataType = {
	PickupEffects = {
		SpeedBoost = { Id = "SpeedBoost", DisplayName = "Speed Boost", DurationSeconds = 5 },
		Shield = { Id = "Shield", DisplayName = "Shield", DurationSeconds = 6 },
	},
	FanPayloadTypes = {
		Standard = { Id = "Standard", DisplayName = "Standard Fan Crate", FanValue = 10 },
		Golden = { Id = "Golden", DisplayName = "Golden Fan Crate", FanValue = 50 },
	},
	FanPickupChannelSeconds = 3,
}

return ItemData

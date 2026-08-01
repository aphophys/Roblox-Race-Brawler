--!strict
--[[
	CarryItemType
	What (if anything) a player is currently carrying. CarryItemService
	enforces at most one non-None slot per player.
]]

export type CarryItemTypeName = "None" | "FanPayload" | "TrackSkill"

export type CarryItemTypeEnum = {
	None: CarryItemTypeName,
	FanPayload: CarryItemTypeName,
	TrackSkill: CarryItemTypeName,
}

local CarryItemType: CarryItemTypeEnum = table.freeze({
	None = "None",
	FanPayload = "FanPayload",
	TrackSkill = "TrackSkill",
}) :: CarryItemTypeEnum

return CarryItemType

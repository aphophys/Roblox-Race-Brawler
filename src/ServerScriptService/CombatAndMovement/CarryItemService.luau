--!strict
--[[
	CarryItemService
	Enforces the "max 1 carried item" rule (Fan Payload or Track Skill item)
	per player, per ReplicatedStorage.Enums.CarryItemType.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CarryItemType = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("CarryItemType"))

local CarryItemService = {}

local carriedItems: { [Player]: string } = {}

function CarryItemService.TryPickup(player: Player, itemType: string) : boolean
	local current = carriedItems[player] or CarryItemType.None
	if current ~= CarryItemType.None then
		return false -- already carrying something; reject
	end

	carriedItems[player] = itemType
	-- TODO: attach carry visual, notify client via Network.
	return true
end

function CarryItemService.Release(player: Player)
	carriedItems[player] = CarryItemType.None
	-- TODO: detach carry visual, resolve deposit/use effect.
end

function CarryItemService.GetCarriedType(player: Player) : string
	return carriedItems[player] or CarryItemType.None
end

function CarryItemService.Init()
	-- TODO: clear carriedItems[player] on Players.PlayerRemoving.
end

return CarryItemService

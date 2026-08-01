--!strict
--[[
	HubShoppingManager
	Server-authoritative purchase resolution for the Commercial Hub store
	(skills/upgrades bought with Gold). Reads costs from ReplicatedStorage.
	Configs.EconomyRates / SkillTrees; writes through ProfileManager.
]]

local HubShoppingManager = {}

function HubShoppingManager.TryPurchase(player: Player, itemId: string) : boolean
	-- TODO: look up cost from EconomyRates/SkillTrees, check
	-- ProfileManager.GetProfile(player).Data.Gold, deduct + grant on success.
	return false
end

function HubShoppingManager.Init()
	-- TODO: connect Network.Economy.PurchaseItem.OnServerEvent and
	-- Network.Economy.EquipSkill.OnServerEvent.
end

return HubShoppingManager

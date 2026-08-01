--!strict
--[[
	HubShoppingManager
	Server-authoritative purchase resolution for the Commercial Hub store —
	spending Gold on a skill. `itemId` (Network.Economy.PurchaseItem's
	payload) is a skillId, and one of two things happens depending on
	whether the player already owns it:

	- Not owned (no entry in profile.Data.Skills, or Unlocked == false):
	  this is an UNLOCK purchase. Costs SkillTrees[itemId].UnlockGoldCost;
	  on success creates/overwrites the Skills entry at { Level = 1,
	  Unlocked = true }. Doesn't auto-equip it into a loadout slot — that's
	  still a separate, explicit LoadoutService.EquipSkill action.
	- Already owned: this is an UPGRADE purchase, unchanged from before —
	  costs SkillTrees[itemId].Levels[currentLevel + 1].UpgradeGoldCost.

	(EconomyRates.SpeedUpgradeCosts/CarryCapacityUpgradeCosts are a
	different, still-unbuilt upgrade track, not read here.)

	PurchaseItem is a fire-and-forget RemoteEvent (not a RemoteFunction), so
	the client can't get a direct return value — success/failure is
	communicated back via the shared Network.Track.ShowNotification toast,
	and the client-side Skill Shop panel re-renders itself off the Gold/
	SkillLevel_<id> attributes ProfileManager.SyncAttributes updates on a
	successful purchase.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))

local HubShoppingManager = {}

local function tryUnlock(player: Player, profile, itemId: string, skillDefinition) : boolean
	if profile.Data.Gold < skillDefinition.UnlockGoldCost then
		Network.Track.ShowNotification:FireClient(player, "NOT ENOUGH GOLD!")
		return false
	end

	profile.Data.Gold -= skillDefinition.UnlockGoldCost
	profile.Data.Skills[itemId] = { Level = 1, Unlocked = true }
	ProfileManager.SyncAttributes(player)
	Network.Track.ShowNotification:FireClient(player, `{skillDefinition.DisplayName:upper()} UNLOCKED!`)
	return true
end

local function tryUpgrade(player: Player, profile, skillData, skillDefinition) : boolean
	if skillData.Level >= skillDefinition.MaxLevel then
		return false -- already maxed
	end

	local nextLevel = skillData.Level + 1
	local levelData = skillDefinition.Levels[nextLevel]
	if levelData == nil then
		return false
	end

	if profile.Data.Gold < levelData.UpgradeGoldCost then
		Network.Track.ShowNotification:FireClient(player, "NOT ENOUGH GOLD!")
		return false
	end

	profile.Data.Gold -= levelData.UpgradeGoldCost
	skillData.Level = nextLevel
	ProfileManager.SyncAttributes(player)
	Network.Track.ShowNotification:FireClient(player, `{skillDefinition.DisplayName:upper()} UPGRADED!`)
	return true
end

function HubShoppingManager.TryPurchase(player: Player, itemId: string) : boolean
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return false
	end

	local skillDefinition = SkillTrees[itemId]
	if skillDefinition == nil then
		return false
	end

	local skillData = profile.Data.Skills[itemId]
	if skillData == nil or not skillData.Unlocked then
		return tryUnlock(player, profile, itemId, skillDefinition)
	end

	return tryUpgrade(player, profile, skillData, skillDefinition)
end

function HubShoppingManager.Init()
	Network.Economy.PurchaseItem.OnServerEvent:Connect(function(player: Player, itemId: unknown)
		if typeof(itemId) ~= "string" then
			return
		end
		HubShoppingManager.TryPurchase(player, itemId)
	end)
end

return HubShoppingManager

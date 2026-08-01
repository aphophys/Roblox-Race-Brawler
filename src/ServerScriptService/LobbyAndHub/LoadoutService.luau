--!strict
--[[
	LoadoutService
	New module (not in the original directory tree) — backs the skill
	selection ribbon: GetOwnedSkills (RemoteFunction) returns the caller's
	unlocked skill ids; EquipSkill (RemoteFunction) sets one of their 3
	loadout slots, enforcing the no-duplicate-across-slots rule, and
	returns whether it succeeded so the ribbon UI knows to confirm or not.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))

local LoadoutService = {}

local function getOwnedSkills(player: Player) : { string }
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return {}
	end

	local owned: { string } = {}
	for skillId, skillData in profile.Data.Skills do
		if skillData.Unlocked then
			table.insert(owned, skillId)
		end
	end
	return owned
end

-- slotIndex: 1-3. skillId: nil clears the slot. Returns true on success.
local function equipSkill(player: Player, slotIndex: number, skillId: string?) : boolean
	if slotIndex ~= 1 and slotIndex ~= 2 and slotIndex ~= 3 then
		return false
	end

	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return false
	end

	if skillId ~= nil then
		local skillData = profile.Data.Skills[skillId]
		if skillData == nil or not skillData.Unlocked then
			return false -- doesn't own this skill
		end
		if SkillTrees[skillId] == nil then
			return false -- unknown skill id
		end

		for otherSlot = 1, 3 do
			if otherSlot ~= slotIndex and profile.Data.EquippedSkills[otherSlot] == skillId then
				return false -- already equipped in another slot
			end
		end
	end

	profile.Data.EquippedSkills[slotIndex] = skillId
	ProfileManager.SyncAttributes(player)
	return true
end

function LoadoutService.Init()
	Network.Economy.GetOwnedSkills.OnServerInvoke = function(player: Player)
		return getOwnedSkills(player)
	end

	Network.Economy.EquipSkill.OnServerInvoke = function(player: Player, slotIndex: unknown, skillId: unknown)
		if typeof(slotIndex) ~= "number" then
			return false
		end
		if skillId ~= nil and typeof(skillId) ~= "string" then
			return false
		end
		return equipSkill(player, slotIndex, skillId :: string?)
	end
end

return LoadoutService

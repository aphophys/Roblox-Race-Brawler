--!strict
--[[
	SkillLoadoutController
	The skill-selection modal (StarterGui.MainHUD.SkillSelectPanel).
	ControlMapper calls Open(slotIndex) when a skill button is pressed while
	InLobby. Was a horizontal ribbon of owned skills only — with the Skill
	Shop now able to unlock all 17 skills (not just the 3 starters), a
	fixed-width non-scrolling row stopped being usable ("too many skills,
	not showing/intuitive"). Now a proper scrollable list of the FULL
	SkillTrees catalog, each row showing level data (reads the
	SkillLevel_<id> attribute ProfileManager.SyncAttributes replicates, same
	as SkillShopController), greyed out and non-clickable if not owned or
	already equipped in a different slot. Equips the picked skill via
	Network.Economy.EquipSkill.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))

local localPlayer = Players.LocalPlayer

local AVAILABLE_COLOR = Color3.fromRGB(77, 171, 247)
local ALREADY_EQUIPPED_COLOR = Color3.fromRGB(150, 150, 150)
local NOT_OWNED_COLOR = Color3.fromRGB(100, 100, 110)

local SkillLoadoutController = {}

local activeSlotIndex: number? = nil

local function getPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local panel = mainHud and mainHud:FindFirstChild("SkillSelectPanel")
	return panel :: Frame?
end

local function getSkillList() : Frame?
	local panel = getPanel()
	local card = panel and panel:FindFirstChild("Card")
	local skillList = card and card:FindFirstChild("SkillList")
	return skillList :: Frame?
end

function SkillLoadoutController.Close()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = false
	end
	activeSlotIndex = nil
end

local function isEquippedElsewhere(skillId: string, slotIndex: number) : boolean
	for otherSlot = 1, 3 do
		if otherSlot ~= slotIndex then
			local equipped = localPlayer:GetAttribute(`EquippedSkill{otherSlot}`)
			if equipped == skillId then
				return true
			end
		end
	end
	return false
end

local function onEntryClicked(skillId: string, slotIndex: number)
	local success = Network.Economy.EquipSkill:InvokeServer(slotIndex, skillId)
	if success then
		SkillLoadoutController.Close()
	end
end

function SkillLoadoutController.Open(slotIndex: number)
	local skillList = getSkillList()
	local entryTemplate = skillList and skillList:FindFirstChild("EntryTemplate")
	if skillList == nil or entryTemplate == nil then
		return
	end

	activeSlotIndex = slotIndex

	for _, child in skillList:GetChildren() do
		if child ~= entryTemplate and child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local sortedSkillIds: { string } = {}
	for skillId in SkillTrees do
		table.insert(sortedSkillIds, skillId)
	end
	table.sort(sortedSkillIds, function(a, b)
		return SkillTrees[a].DisplayName < SkillTrees[b].DisplayName
	end)

	for index, skillId in sortedSkillIds do
		local skillDefinition = SkillTrees[skillId]

		local entry = (entryTemplate :: TextButton):Clone()
		entry.Name = `Entry_{skillId}`
		entry.LayoutOrder = index
		entry.Visible = true
		entry.Parent = skillList

		local nameLabel = entry:WaitForChild("NameLabel") :: TextLabel
		local levelLabel = entry:WaitForChild("LevelLabel") :: TextLabel
		nameLabel.Text = skillDefinition.DisplayName

		local level = (localPlayer:GetAttribute(`SkillLevel_{skillId}`) :: number?) or 0

		if level == 0 then
			levelLabel.Text = "Not Owned — see Skill Shop"
			entry.BackgroundColor3 = NOT_OWNED_COLOR
			entry.AutoButtonColor = false
		elseif isEquippedElsewhere(skillId, slotIndex) then
			levelLabel.Text = `Level {level} / {skillDefinition.MaxLevel} — equipped elsewhere`
			entry.BackgroundColor3 = ALREADY_EQUIPPED_COLOR
			entry.AutoButtonColor = false
		else
			levelLabel.Text = `Level {level} / {skillDefinition.MaxLevel}`
			entry.BackgroundColor3 = AVAILABLE_COLOR
			entry.AutoButtonColor = true
			entry.Activated:Connect(function()
				onEntryClicked(skillId, slotIndex)
			end)
		end
	end

	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = true
	end
end

function SkillLoadoutController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local panel = mainHud:WaitForChild("SkillSelectPanel") :: TextButton
	local closeButton = (panel:WaitForChild("Card"):WaitForChild("CloseButton")) :: TextButton

	closeButton.Activated:Connect(SkillLoadoutController.Close)
	panel.Activated:Connect(SkillLoadoutController.Close) -- backdrop: click outside the card to close

	-- Close automatically if the player leaves the Hub (e.g. joins a race)
	-- while it's open.
	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(function()
		if activeSlotIndex ~= nil then
			SkillLoadoutController.Close()
		end
	end)
end

return SkillLoadoutController

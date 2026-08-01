--!strict
--[[
	SkillShopController
	New module — the "Skill Shop" modal (StarterGui.MainHUD.SkillShopPanel),
	opened from the left-side menu bar's SkillShopButton. Lists EVERY skill
	in SkillTrees (not just owned ones — the whole catalog, sorted by
	DisplayName), each row showing its current level (read from the
	SkillLevel_<id> attribute ProfileManager.SyncAttributes replicates;
	missing/unset means "not owned," shown as Level 0) and the Gold price
	of the next step:
	- Not owned (Level 0): SkillTrees[id].UnlockGoldCost.
	- Owned, below MaxLevel: SkillTrees[id].Levels[level + 1].UpgradeGoldCost.
	- Owned, at MaxLevel: no price, button reads "MAXED".

	Clicking the price button fires Network.Economy.PurchaseItem(skillId)
	either way — a fire-and-forget RemoteEvent, so the row re-renders off
	the Gold/SkillLevel_<id> attribute change rather than a direct return
	value; HubShoppingManager is the real (server-authoritative) purchase
	check, and decides unlock-vs-upgrade itself from the same ownership
	state this panel reads.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local localPlayer = Players.LocalPlayer

local AFFORDABLE_COLOR = Color3.fromRGB(77, 217, 100)
local UNAFFORDABLE_COLOR = Color3.fromRGB(180, 180, 180)
local MAXED_COLOR = Color3.fromRGB(150, 150, 150)

local SkillShopController = {}

type EntryRefs = {
	NameLabel: TextLabel,
	LevelLabel: TextLabel,
	UpgradeButton: TextButton,
}

local entriesBySkillId: { [string]: EntryRefs } = {}
local levelAttributeConnections: { RBXScriptConnection } = {}
local isOpen = false

local function getPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local panel = mainHud and mainHud:FindFirstChild("SkillShopPanel")
	return panel :: Frame?
end

local function getSkillList() : Frame?
	local panel = getPanel()
	local card = panel and panel:FindFirstChild("Card")
	local skillList = card and card:FindFirstChild("SkillList")
	return skillList :: Frame?
end

local function renderEntry(skillId: string)
	local refs = entriesBySkillId[skillId]
	local skillDefinition = SkillTrees[skillId]
	if refs == nil or skillDefinition == nil then
		return
	end

	-- Unset attribute (never owned) reads as Level 0, not Level 1 — Level 1
	-- is a real, meaningful state (owned, unlocked) that Gold-having players
	-- pay UnlockGoldCost to reach.
	local level = (localPlayer:GetAttribute(`SkillLevel_{skillId}`) :: number?) or 0
	refs.NameLabel.Text = skillDefinition.DisplayName

	if level >= skillDefinition.MaxLevel then
		refs.LevelLabel.Text = `Level {level} / {skillDefinition.MaxLevel} (MAX)`
		refs.UpgradeButton.Text = "MAXED"
		refs.UpgradeButton.BackgroundColor3 = MAXED_COLOR
		refs.UpgradeButton.AutoButtonColor = false
		return
	end

	local price: number
	if level == 0 then
		price = skillDefinition.UnlockGoldCost
	else
		local nextLevelData = skillDefinition.Levels[level + 1]
		if nextLevelData == nil then
			return
		end
		price = nextLevelData.UpgradeGoldCost
	end

	local gold = (localPlayer:GetAttribute("Gold") :: number?) or 0
	local canAfford = gold >= price

	refs.LevelLabel.Text = `Level {level} / {skillDefinition.MaxLevel}`
	refs.UpgradeButton.Text = `🪙 {Utils.FormatNumber(price)}`
	refs.UpgradeButton.BackgroundColor3 = if canAfford then AFFORDABLE_COLOR else UNAFFORDABLE_COLOR
	refs.UpgradeButton.AutoButtonColor = true
end

local function refreshAllEntries()
	if not isOpen then
		return
	end
	for skillId in entriesBySkillId do
		renderEntry(skillId)
	end
end

local function clearLevelAttributeConnections()
	for _, connection in levelAttributeConnections do
		connection:Disconnect()
	end
	levelAttributeConnections = {}
end

local function rebuildList()
	local skillList = getSkillList()
	local entryTemplate = skillList and skillList:FindFirstChild("EntryTemplate")
	if skillList == nil or entryTemplate == nil then
		return
	end

	for _, child in skillList:GetChildren() do
		if child ~= entryTemplate and child:IsA("Frame") then
			child:Destroy()
		end
	end
	entriesBySkillId = {}
	clearLevelAttributeConnections()

	local sortedSkillIds: { string } = {}
	for skillId in SkillTrees do
		table.insert(sortedSkillIds, skillId)
	end
	table.sort(sortedSkillIds, function(a, b)
		return SkillTrees[a].DisplayName < SkillTrees[b].DisplayName
	end)

	for index, skillId in sortedSkillIds do
		local entry = (entryTemplate :: Frame):Clone()
		entry.Name = `Entry_{skillId}`
		entry.LayoutOrder = index
		entry.Visible = true
		entry.Parent = skillList

		local nameLabel = entry:WaitForChild("NameLabel") :: TextLabel
		local levelLabel = entry:WaitForChild("LevelLabel") :: TextLabel
		local upgradeButton = entry:WaitForChild("UpgradeButton") :: TextButton

		entriesBySkillId[skillId] = {
			NameLabel = nameLabel,
			LevelLabel = levelLabel,
			UpgradeButton = upgradeButton,
		}

		upgradeButton.Activated:Connect(function()
			Network.Economy.PurchaseItem:FireServer(skillId)
		end)

		table.insert(levelAttributeConnections, localPlayer:GetAttributeChangedSignal(`SkillLevel_{skillId}`):Connect(function()
			renderEntry(skillId)
		end))

		renderEntry(skillId)
	end
end

function SkillShopController.Open()
	isOpen = true
	rebuildList()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = true
	end
end

function SkillShopController.Close()
	isOpen = false
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = false
	end
end

-- SkillShopButton's Icon child is a placeholder ("" Image) until a real one
-- is sourced — same fallback convention as SkillTrees.IconAssetId: falls
-- back to the button's own Text (already set in default.project.json) when
-- there's no icon to show instead.
local function applyIconFallback(button: TextButton)
	local icon = button:FindFirstChild("Icon") :: ImageLabel?
	if icon ~= nil and icon.Image ~= "" then
		icon.Visible = true
		button.TextTransparency = 1
	end
end

function SkillShopController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local leftMenuBar = mainHud:WaitForChild("LeftMenuBar")
	local skillShopButton = leftMenuBar:WaitForChild("SkillShopButton") :: TextButton
	local panel = mainHud:WaitForChild("SkillShopPanel") :: TextButton
	local closeButton = (panel:WaitForChild("Card"):WaitForChild("CloseButton")) :: TextButton

	applyIconFallback(skillShopButton)
	skillShopButton.Activated:Connect(SkillShopController.Open)
	closeButton.Activated:Connect(SkillShopController.Close)
	panel.Activated:Connect(SkillShopController.Close) -- backdrop: click outside the card to close

	localPlayer:GetAttributeChangedSignal("Gold"):Connect(refreshAllEntries)
end

return SkillShopController

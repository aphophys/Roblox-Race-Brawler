--!strict
--[[
	MainMenuController
	New module — the read-only "Player Menu" modal (StarterGui.MainHUD.
	MainMenuPanel), opened from the left-side menu bar's MenuButton. Shows
	player info, race stats, fans, gold, and equipped skills — everything
	it displays is already replicated as a player Attribute by
	ProfileManager.SyncAttributes, so this is pure display, no remotes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))

local localPlayer = Players.LocalPlayer

local MainMenuController = {}

local function getPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local panel = mainHud and mainHud:FindFirstChild("MainMenuPanel")
	return panel :: Frame?
end

local function equippedSkillsSummary() : string
	local names: { string } = {}
	for slotIndex = 1, 3 do
		local skillId = localPlayer:GetAttribute(`EquippedSkill{slotIndex}`) :: string?
		if skillId ~= nil and skillId ~= "" then
			local definition = SkillTrees[skillId]
			table.insert(names, if definition ~= nil then definition.DisplayName else skillId)
		end
	end
	if #names == 0 then
		return "Skills: -"
	end
	return `Skills: {table.concat(names, ", ")}`
end

local function refresh()
	local panel = getPanel()
	if panel == nil then
		return
	end

	local infoList = panel:FindFirstChild("Card") and (panel:FindFirstChild("Card") :: Instance):FindFirstChild("InfoList")
	if infoList == nil then
		return
	end

	local playerNameLabel = infoList:FindFirstChild("PlayerNameLabel") :: TextLabel?
	local livesLabel = infoList:FindFirstChild("LivesLabel") :: TextLabel?
	local checkpointLabel = infoList:FindFirstChild("CheckpointLabel") :: TextLabel?
	local lapsLabel = infoList:FindFirstChild("LapsLabel") :: TextLabel?
	local goldLabel = infoList:FindFirstChild("GoldLabel") :: TextLabel?
	local fansLabel = infoList:FindFirstChild("FansLabel") :: TextLabel?
	local skillsLabel = infoList:FindFirstChild("SkillsLabel") :: TextLabel?

	if playerNameLabel ~= nil then
		playerNameLabel.Text = localPlayer.Name
	end
	if livesLabel ~= nil then
		livesLabel.Text = `Lives: {(localPlayer:GetAttribute("Lives") :: number?) or 0}`
	end
	if checkpointLabel ~= nil then
		checkpointLabel.Text = `Checkpoint: {(localPlayer:GetAttribute("CheckpointOrdinal") :: number?) or 0} / 8`
	end
	if lapsLabel ~= nil then
		lapsLabel.Text = `Laps Completed: {(localPlayer:GetAttribute("TotalLapsCompleted") :: number?) or 0}`
	end
	if goldLabel ~= nil then
		goldLabel.Text = `🪙 Gold: {(localPlayer:GetAttribute("Gold") :: number?) or 0}`
	end
	if fansLabel ~= nil then
		fansLabel.Text = `🌟 Fans: {(localPlayer:GetAttribute("TotalFans") :: number?) or 0}`
	end
	if skillsLabel ~= nil then
		skillsLabel.Text = equippedSkillsSummary()
	end
end

function MainMenuController.Open()
	refresh()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = true
	end
end

function MainMenuController.Close()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = false
	end
end

-- MenuButton's Icon child is a placeholder ("" Image) until a real one is
-- sourced — same fallback convention as SkillTrees.IconAssetId: falls back
-- to the button's own Text (already set in default.project.json) when
-- there's no icon to show instead.
local function applyIconFallback(button: TextButton)
	local icon = button:FindFirstChild("Icon") :: ImageLabel?
	if icon ~= nil and icon.Image ~= "" then
		icon.Visible = true
		button.TextTransparency = 1
	end
end

function MainMenuController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local leftMenuBar = mainHud:WaitForChild("LeftMenuBar")
	local menuButton = leftMenuBar:WaitForChild("MenuButton") :: TextButton
	local panel = mainHud:WaitForChild("MainMenuPanel") :: TextButton
	local closeButton = (panel:WaitForChild("Card"):WaitForChild("CloseButton")) :: TextButton

	applyIconFallback(menuButton)
	menuButton.Activated:Connect(MainMenuController.Open)
	closeButton.Activated:Connect(MainMenuController.Close)
	panel.Activated:Connect(MainMenuController.Close) -- backdrop: click outside the card to close

	for _, attributeName in {
		"Lives",
		"CheckpointOrdinal",
		"TotalLapsCompleted",
		"Gold",
		"TotalFans",
		"EquippedSkill1",
		"EquippedSkill2",
		"EquippedSkill3",
	} do
		localPlayer:GetAttributeChangedSignal(attributeName):Connect(refresh)
	end
end

return MainMenuController

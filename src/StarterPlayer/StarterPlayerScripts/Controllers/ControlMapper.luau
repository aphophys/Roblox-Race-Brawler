--!strict
--[[
	ControlMapper
	Binds every input source — keyboard AND the on-screen HUD buttons
	(StarterGui.MainHUD.BottomRight) — to the same action dispatch.

	Jump and movement are deliberately NOT handled here — Roblox's standard
	jump button/thumbstick are used as-is; we only place the 3 skill
	buttons near them. Pose is handled by ActionButtonController (merged
	into the bottom-center button, context-sensitive on PlayerState).

	Skill1/2/3 are dual-purpose, gated on PlayerState:
	- InRace: casts whatever skill is equipped in that slot (read from the
	  EquippedSkill1/2/3 attributes ProfileManager.SyncAttributes sets).
	- InLobby: opens the skill-selection ribbon for that slot instead of
	  casting (SkillLoadoutController) — matches "can be changed anytime
	  while in commercial center."
	- AtFanBox: BottomRight itself is hidden, so these presses don't fire.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local CombatInputHandler = require(script.Parent:WaitForChild("CombatInputHandler"))
local SkillLoadoutController = require(script.Parent.Parent:WaitForChild("UI_And_Visuals"):WaitForChild("SkillLoadoutController"))

local localPlayer = Players.LocalPlayer

export type ControlAction = "Skill1" | "Skill2" | "Skill3" | "CarryRelease"

local ACTION_KEYBINDS: { [ControlAction]: { Enum.KeyCode } } = {
	Skill1 = { Enum.KeyCode.One },
	Skill2 = { Enum.KeyCode.Two },
	Skill3 = { Enum.KeyCode.Three },
	CarryRelease = { Enum.KeyCode.E },
}

local ControlMapper = {}

local function castEquippedSkill(slotIndex: number)
	local skillId = localPlayer:GetAttribute(`EquippedSkill{slotIndex}`) :: string?
	if skillId == nil or skillId == "" then
		return
	end

	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil then
		return
	end

	if skillDefinition.CastType == "Target" then
		CombatInputHandler.RequestTargetedSkill(skillId)
	elseif skillDefinition.CastType == "Global" then
		CombatInputHandler.RequestGlobalSkill(skillId)
	elseif skillDefinition.CastType == "Self" then
		CombatInputHandler.RequestSelfSkill(skillId)
	end
end

local function onSkillSlotPressed(slotIndex: number)
	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	if state == PlayerState.InLobby then
		SkillLoadoutController.Open(slotIndex)
	elseif state == PlayerState.InRace then
		castEquippedSkill(slotIndex)
	end
	-- AtFanBox: BottomRight is hidden; nothing to do even if this somehow fires.
end

local function dispatchAction(actionName: string)
	if actionName == "Skill1" then
		onSkillSlotPressed(1)
	elseif actionName == "Skill2" then
		onSkillSlotPressed(2)
	elseif actionName == "Skill3" then
		onSkillSlotPressed(3)
	elseif actionName == "CarryRelease" then
		CombatInputHandler.RequestCarryRelease()
	end
end

local function handleAction(actionName: string, inputState: Enum.UserInputState) : Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	dispatchAction(actionName)
	return Enum.ContextActionResult.Pass
end

-- IconAssetId is a placeholder ("") on every skill today (no Toolbox
-- access to source icons) — always falls back to DisplayName text. Once a
-- skill has a real IconAssetId, this is the one place to branch over to
-- setting an Image on the button instead (no ImageLabel exists on these
-- buttons yet since there's nothing to display there today).
local function skillButtonLabel(skillId: string?) : string
	if skillId == nil or skillId == "" then
		return "-"
	end

	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil then
		return "?"
	end

	return skillDefinition.DisplayName
end

local function refreshSkillButtonLabels()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local bottomRight = mainHud and mainHud:FindFirstChild("BottomRight")
	if bottomRight == nil then
		return
	end

	for slotIndex = 1, 3 do
		local button = bottomRight:FindFirstChild(`Skill{slotIndex}Button`)
		if button ~= nil then
			local skillId = localPlayer:GetAttribute(`EquippedSkill{slotIndex}`) :: string?
			local textButton = button :: TextButton
			textButton.Text = skillButtonLabel(skillId)
		end
	end
end

local function refreshBottomRightVisibility()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local bottomRight = mainHud and mainHud:FindFirstChild("BottomRight")
	if bottomRight == nil then
		return
	end

	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	local bottomRightFrame = bottomRight :: Frame
	bottomRightFrame.Visible = state ~= PlayerState.AtFanBox
end

local function bindHudButtons()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local bottomRight = mainHud:WaitForChild("BottomRight")

	local skill1Button = bottomRight:WaitForChild("Skill1Button") :: TextButton
	local skill2Button = bottomRight:WaitForChild("Skill2Button") :: TextButton
	local skill3Button = bottomRight:WaitForChild("Skill3Button") :: TextButton

	skill1Button.Activated:Connect(function()
		dispatchAction("Skill1")
	end)
	skill2Button.Activated:Connect(function()
		dispatchAction("Skill2")
	end)
	skill3Button.Activated:Connect(function()
		dispatchAction("Skill3")
	end)

	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(refreshBottomRightVisibility)
	refreshBottomRightVisibility()

	for slotIndex = 1, 3 do
		localPlayer:GetAttributeChangedSignal(`EquippedSkill{slotIndex}`):Connect(refreshSkillButtonLabels)
	end
	refreshSkillButtonLabels()
end

function ControlMapper.Init()
	for actionName, keys in ACTION_KEYBINDS do
		ContextActionService:BindAction(actionName, handleAction, false, table.unpack(keys))
	end

	bindHudButtons()
end

return ControlMapper

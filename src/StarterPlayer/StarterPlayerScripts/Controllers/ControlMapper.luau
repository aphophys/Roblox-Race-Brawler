--!strict
--[[
	ControlMapper
	Binds every input source — keyboard AND the on-screen HUD buttons
	(StarterGui.MainHUD.BottomRight) — to the same action dispatch, so
	keyboard and touch always do exactly the same thing.

	Jump and movement are deliberately NOT handled here — Roblox's standard
	jump button/thumbstick are used as-is; we only place the 3 skill
	buttons near them. Pose is handled by ActionButtonController (merged
	into the same button as Deposit Fans, context-sensitive on PlayerState),
	not here.

	Default loadout (matches ProfileTemplate's starter-unlocked skills):
	Skill1 = PositionSwap (Target), Skill2 = SlowGlobal (Global),
	Skill3 = DashSelf (Self). Not configurable yet — a real loadout/equip
	system is future work (HubShoppingManager.EquipSkill is still a stub).
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")

local CombatInputHandler = require(script.Parent:WaitForChild("CombatInputHandler"))

local localPlayer = Players.LocalPlayer

export type ControlAction = "Skill1" | "Skill2" | "Skill3" | "CarryRelease"

local ACTION_KEYBINDS: { [ControlAction]: { Enum.KeyCode } } = {
	Skill1 = { Enum.KeyCode.One },
	Skill2 = { Enum.KeyCode.Two },
	Skill3 = { Enum.KeyCode.Three },
	CarryRelease = { Enum.KeyCode.E },
}

local ControlMapper = {}

local function dispatchAction(actionName: string)
	if actionName == "Skill1" then
		CombatInputHandler.RequestTargetedSkill("PositionSwap")
	elseif actionName == "Skill2" then
		CombatInputHandler.RequestGlobalSkill("SlowGlobal")
	elseif actionName == "Skill3" then
		CombatInputHandler.RequestSelfSkill("DashSelf")
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

local function bindHudButtons()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local bottomRight = mainHud:WaitForChild("BottomRight")

	(bottomRight:WaitForChild("Skill1Button") :: TextButton).Activated:Connect(function()
		dispatchAction("Skill1")
	end)
	(bottomRight:WaitForChild("Skill2Button") :: TextButton).Activated:Connect(function()
		dispatchAction("Skill2")
	end)
	(bottomRight:WaitForChild("Skill3Button") :: TextButton).Activated:Connect(function()
		dispatchAction("Skill3")
	end)
end

function ControlMapper.Init()
	for actionName, keys in ACTION_KEYBINDS do
		ContextActionService:BindAction(actionName, handleAction, false, table.unpack(keys))
	end

	bindHudButtons()
end

return ControlMapper

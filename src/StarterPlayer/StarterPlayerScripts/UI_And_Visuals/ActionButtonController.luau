--!strict
--[[
	ActionButtonController
	Center-bottom HUD button, same row as the (Roblox-default) Jump button.
	Context-sensitive on PlayerState: shows/fires "POSE" while AtFanBox,
	"DEPOSIT FANS" otherwise. Binds to StarterGui.MainHUD.CenterAction.
	ActionButton.

	Deposit Fans isn't fully playable yet regardless of this button working
	correctly: nothing in the world spawns a pickup-able Fan Payload for
	CarryItemService to attach to, so there's nothing to actually carry to
	deposit. Pose fires a single hardcoded "Wave" — see PoseUIController.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local PoseUIController = require(script.Parent:WaitForChild("PoseUIController"))

local localPlayer = Players.LocalPlayer

local ActionButtonController = {}

local function getActionButton() : TextButton?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local centerAction = mainHud and mainHud:FindFirstChild("CenterAction")
	local actionButton = centerAction and centerAction:FindFirstChild("ActionButton")
	return actionButton :: TextButton?
end

local function refreshButtonLabel()
	local actionButton = getActionButton()
	if actionButton == nil then
		return
	end

	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	actionButton.Text = if state == PlayerState.AtFanBox then "POSE" else "DEPOSIT FANS"
end

local function onActionButtonClicked()
	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	if state == PlayerState.AtFanBox then
		PoseUIController.RequestPose("Wave")
	else
		Network.Economy.DepositFans:FireServer()
	end
end

function ActionButtonController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local centerAction = mainHud:WaitForChild("CenterAction")
	local actionButton = centerAction:WaitForChild("ActionButton") :: TextButton

	actionButton.Activated:Connect(onActionButtonClicked)
	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(refreshButtonLabel)
	refreshButtonLabel()
end

return ActionButtonController

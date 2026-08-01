--!strict
--[[
	LocationToggleController
	HUD button directly beneath the top-center StatsRow capsules. Context-sensitive on PlayerState:
	InLobby -> "FAN BOX" (fires TeleportToFanBox)
	AtFanBox -> "COMMERCIAL CENTER" (fires ReturnToHub)
	InRace -> "LEAVE RACE" (fires ReturnToHub — same remote as AtFanBox's
	          button; TeleportPoseService.ReturnToHub doesn't care what
	          state you were in, it just sends you to the Hub and sets
	          InLobby, which is exactly "leave race" semantics too)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local localPlayer = Players.LocalPlayer

local LocationToggleController = {}

local function getElements() : (Frame?, TextButton?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local locationToggle = mainHud and mainHud:FindFirstChild("LocationToggle")
	if locationToggle == nil then
		return nil, nil
	end
	local button = locationToggle:FindFirstChild("LocationToggleButton")
	return locationToggle :: Frame, button :: TextButton?
end

local function refresh()
	local locationToggle, button = getElements()
	if locationToggle == nil or button == nil then
		return
	end

	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby

	locationToggle.Visible = true
	if state == PlayerState.InRace then
		button.Text = "LEAVE RACE"
	elseif state == PlayerState.AtFanBox then
		button.Text = "COMMERCIAL CENTER"
	else
		button.Text = "FAN BOX"
	end
end

local function onButtonClicked()
	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	if state == PlayerState.InLobby then
		Network.Hub.TeleportToFanBox:FireServer()
	else
		-- AtFanBox or InRace: both just go back to the Hub.
		Network.Hub.ReturnToHub:FireServer()
	end
end

function LocationToggleController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local locationToggle = mainHud:WaitForChild("LocationToggle")
	local button = locationToggle:WaitForChild("LocationToggleButton") :: TextButton

	button.Activated:Connect(onButtonClicked)
	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(refresh)
	refresh()
end

return LocationToggleController

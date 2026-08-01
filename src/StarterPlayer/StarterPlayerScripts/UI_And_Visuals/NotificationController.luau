--!strict
--[[
	NotificationController
	Generalized pooled/stacking toast notification system (was a single
	dedicated "wrong direction" label — now the one system every notice
	goes through: wrong direction, fans picked up/dropped, skill activation
	text, currency gains). Listens for Network.Track.ShowNotification(text:
	string, style: string?), clones StarterGui.MainHUD.NotificationList.
	EntryTemplate, fades it in, holds, fades out, and destroys it. A
	UIListLayout on NotificationList handles the actual stacking — each
	active notification is just another child, reflowing automatically as
	entries are added/removed.

	style == "Pop" adds a bouncy scale-in/out on top of the usual fade (via
	EntryTemplate's UIScale child) — a "birthday popper" feel for currency
	gains (Gold/Fans), distinct from the flat fade every other notice uses.
	Any other style value (including nil, the default for existing callers)
	keeps the original plain-fade behavior — UIScale just never moves.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local FLASH_IN_INFO = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLASH_OUT_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local POP_IN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_OUT_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local POP_START_SCALE = 0.3
local HOLD_SECONDS = 1.2

local NotificationController = {}

local nextLayoutOrder = 0

local function getListAndTemplate() : (Frame?, TextLabel?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local list = mainHud and mainHud:FindFirstChild("NotificationList")
	if list == nil then
		return nil, nil
	end
	local template = list:FindFirstChild("EntryTemplate")
	return list :: Frame, template :: TextLabel?
end

local function onShowNotification(text: unknown, style: unknown)
	if typeof(text) ~= "string" then
		return
	end
	local isPop = style == "Pop"

	local list, template = getListAndTemplate()
	if list == nil or template == nil then
		return
	end

	local entry = template:Clone()
	nextLayoutOrder += 1
	entry.LayoutOrder = nextLayoutOrder
	entry.Text = text
	entry.TextTransparency = 1
	entry.Visible = true

	local uiScale = entry:FindFirstChildOfClass("UIScale")
	if uiScale ~= nil then
		uiScale.Scale = if isPop then POP_START_SCALE else 1
	end

	entry.Parent = list

	local flashIn = TweenService:Create(entry, FLASH_IN_INFO, { TextTransparency = 0 })
	if isPop and uiScale ~= nil then
		TweenService:Create(uiScale, POP_IN_INFO, { Scale = 1 }):Play()
	end

	flashIn.Completed:Connect(function()
		task.wait(HOLD_SECONDS)
		local flashOut = TweenService:Create(entry, FLASH_OUT_INFO, { TextTransparency = 1 })
		if isPop and uiScale ~= nil then
			TweenService:Create(uiScale, POP_OUT_INFO, { Scale = POP_START_SCALE }):Play()
		end
		flashOut.Completed:Connect(function()
			entry:Destroy()
		end)
		flashOut:Play()
	end)
	flashIn:Play()
end

function NotificationController.Init()
	Network.Track.ShowNotification.OnClientEvent:Connect(onShowNotification)
end

return NotificationController

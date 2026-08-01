--!strict
--[[
	CurrencyDisplay
	New module — top-right HUD quadrant: Gold/Fans labels. Binds to
	StarterGui.MainHUD.TopRight (default.project.json) and reads the Gold/
	TotalFans player attributes set once by ProfileManager.SyncAttributes
	on load. Live updates only happen if something calls SyncAttributes
	again server-side — nothing does yet (see ProfileManager's docstring),
	so today this shows accurate starting values but won't move during play.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local localPlayer = Players.LocalPlayer

local CurrencyDisplay = {}

local function getLabels() : (TextLabel?, TextLabel?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local topRight = mainHud and mainHud:FindFirstChild("TopRight")
	if topRight == nil then
		return nil, nil
	end

	local goldLabel = topRight:FindFirstChild("GoldLabel")
	local fansLabel = topRight:FindFirstChild("FansLabel")
	return goldLabel :: TextLabel?, fansLabel :: TextLabel?
end

local function updateGold()
	local goldLabel = getLabels()
	if goldLabel == nil then
		return
	end
	local gold = (localPlayer:GetAttribute("Gold") :: number?) or 0
	goldLabel.Text = `🪙 {Utils.FormatNumber(gold)}`
end

local function updateFans()
	local _, fansLabel = getLabels()
	if fansLabel == nil then
		return
	end
	local fans = (localPlayer:GetAttribute("TotalFans") :: number?) or 0
	fansLabel.Text = `🌟 {Utils.FormatNumber(fans)}`
end

function CurrencyDisplay.Init()
	localPlayer:GetAttributeChangedSignal("Gold"):Connect(updateGold)
	localPlayer:GetAttributeChangedSignal("TotalFans"):Connect(updateFans)
	updateGold()
	updateFans()
end

return CurrencyDisplay

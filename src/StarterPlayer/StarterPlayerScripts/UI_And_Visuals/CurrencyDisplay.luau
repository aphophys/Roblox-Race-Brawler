--!strict
--[[
	CurrencyDisplay
	Gold/Fans labels — each lives in its own pill-shaped capsule in the
	top-center StatsRow (StarterGui.MainHUD.StatsRow.GoldCapsule/
	FansCapsule, default.project.json). Reads the Gold/TotalFans player
	attributes set by ProfileManager.SyncAttributes. Live updates whenever
	those attributes change (fan deposits, HubShoppingManager purchases,
	etc. all call SyncAttributes again after mutating).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local localPlayer = Players.LocalPlayer

local CurrencyDisplay = {}

local function getLabels() : (TextLabel?, TextLabel?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local statsRow = mainHud and mainHud:FindFirstChild("StatsRow")
	if statsRow == nil then
		return nil, nil
	end

	local goldCapsule = statsRow:FindFirstChild("GoldCapsule")
	local fansCapsule = statsRow:FindFirstChild("FansCapsule")
	local goldLabel = goldCapsule and goldCapsule:FindFirstChild("GoldLabel")
	local fansLabel = fansCapsule and fansCapsule:FindFirstChild("FansLabel")
	return goldLabel :: TextLabel?, fansLabel :: TextLabel?
end

-- 💰 not 🪙 — confirmed via an in-Studio render test that Roblox's default
-- fonts don't have a glyph for the coin emoji (renders as an empty box);
-- money-bag is an older, universally-supported emoji. Same swap applied
-- everywhere else a Gold amount is shown.
local function updateGold()
	local goldLabel = getLabels()
	if goldLabel == nil then
		return
	end
	local gold = (localPlayer:GetAttribute("Gold") :: number?) or 0
	goldLabel.Text = `💰 {Utils.FormatNumber(gold)}`
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

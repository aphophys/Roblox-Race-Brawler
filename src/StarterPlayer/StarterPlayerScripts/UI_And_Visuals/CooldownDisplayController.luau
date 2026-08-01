--!strict
--[[
	CooldownDisplayController
	The skill-cooldown visual: on cast, the button instantly greys out and
	stays grey for the whole cooldown — no color tween running at the same
	time as anything else, one clear signal — while a thin bar along the
	button's bottom edge (CooldownFill, tinted the button's own normal
	color) fills from empty to full over the cooldown duration, like an HP
	bar recovering. The instant it finishes filling, the button pops back
	to full color and the bar disappears. (Two earlier attempts both read
	as "a rectangle rotating" — a rotating needle IS geometrically a
	rotating rectangle, however thin. A fill bar has no rotation to
	misread.)

	Listens for Network.Combat.SkillCastResult (server confirms a
	successful cast + its cooldown length) and finds which Skill1/2/3 slot
	currently has that skill equipped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local GREY_OUT_COLOR = Color3.fromRGB(120, 120, 120)
local FILL_HEIGHT_SCALE = 0.16

local CooldownDisplayController = {}

-- Cached the first time each button is seen cooling down, so we know what
-- color to pop back to and what color to tint the fill bar, regardless of
-- how many times it's been greyed.
local normalColorByButton: { [TextButton]: Color3 } = {}

local function findSlotForSkill(skillId: string) : number?
	for slotIndex = 1, 3 do
		if localPlayer:GetAttribute(`EquippedSkill{slotIndex}`) == skillId then
			return slotIndex
		end
	end
	return nil
end

local function getButtonAndFill(slotIndex: number) : (TextButton?, Frame?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local bottomRight = mainHud and mainHud:FindFirstChild("BottomRight")
	if bottomRight == nil then
		return nil, nil
	end

	local button = bottomRight:FindFirstChild(`Skill{slotIndex}Button`)
	if button == nil then
		return nil, nil
	end

	local fill = button:FindFirstChild("CooldownFill")
	return button :: TextButton, fill :: Frame?
end

local function onSkillCastResult(skillId: unknown, cooldownSeconds: unknown)
	if typeof(skillId) ~= "string" or typeof(cooldownSeconds) ~= "number" then
		return
	end

	local slotIndex = findSlotForSkill(skillId)
	if slotIndex == nil then
		return
	end

	local button, fill = getButtonAndFill(slotIndex)
	if button == nil or fill == nil then
		return
	end

	if normalColorByButton[button] == nil then
		normalColorByButton[button] = button.BackgroundColor3
	end
	local normalColor = normalColorByButton[button]

	button.BackgroundColor3 = GREY_OUT_COLOR
	fill.BackgroundColor3 = normalColor
	fill.Size = UDim2.new(0, 0, FILL_HEIGHT_SCALE, 0)
	fill.Visible = true

	local fillTween = TweenService:Create(fill, TweenInfo.new(cooldownSeconds, Enum.EasingStyle.Linear), {
		Size = UDim2.new(1, 0, FILL_HEIGHT_SCALE, 0),
	})

	fillTween.Completed:Connect(function()
		button.BackgroundColor3 = normalColor
		fill.Visible = false
		fill.Size = UDim2.new(0, 0, FILL_HEIGHT_SCALE, 0)
	end)

	fillTween:Play()
end

function CooldownDisplayController.Init()
	Network.Combat.SkillCastResult.OnClientEvent:Connect(onSkillCastResult)
end

return CooldownDisplayController

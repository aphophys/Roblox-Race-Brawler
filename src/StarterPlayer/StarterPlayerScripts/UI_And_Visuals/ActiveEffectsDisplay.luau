--!strict
--[[
	ActiveEffectsDisplay
	A small stack of countdown chips under the ADD FANS button, one per effect
	currently on the local player, each disappearing when its timer runs out.

	## Why the countdown is entirely client-side

	The server sends ONE message when an effect lands (Network.Combat.
	ActiveEffectChanged, carrying the effect id and its duration) and then says
	nothing more. Everything after that — the remaining seconds, the shrinking
	bar, removing the chip at zero — is computed here from `os.clock()`.

	The alternative, having the server push remaining-time updates, costs a
	remote per effect per tick per affected player, and a track-wide debuff
	(SlowGlobal, ScrambleGlobal) puts an effect on EVERYONE at once. At 10
	updates a second with 20 players carrying two effects each that is 400
	messages a second, forever, to tell clients something they can already work
	out. A countdown is a pure function of when it started and how long it runs,
	so the only thing the server actually knows that the client does not is
	those two numbers, and it sends them exactly once.

	The tradeoff is honest and small: the chip's clock is the client's, so it
	can drift from the server's by the message's latency (tens of milliseconds
	on a timer displayed to one decimal). Nothing is decided from this readout —
	the server owns whether an effect is actually active, via EffectStackManager
	— so a chip that lingers a frame too long is a cosmetic error, not an
	exploitable one. Which is also why it is safe for this to be client-side at
	all.

	Early clears (an immunity purge) DO get a message, with duration 0, because
	that is the one thing the client cannot derive.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local SkillEffects = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillEffects"))

local localPlayer = Players.LocalPlayer

-- Small, as specified. Wide enough for "Reverse Control 4.2s" at 11px.
local CHIP_SIZE = Vector2.new(138, 20)
local CHIP_GAP = 4
-- Clear of the ADD FANS button above it.
local STACK_TOP_GAP = 6
local GOOD_COLOR = Color3.fromRGB(76, 217, 100)
local BAD_COLOR = Color3.fromRGB(255, 90, 90)

local ActiveEffectsDisplay = {}

type Chip = {
	Frame: Frame,
	Label: TextLabel,
	Fill: Frame,
	ExpiresAt: number,
	Duration: number,
}

local container: Frame? = nil
local chipsByEffectId: { [string]: Chip } = {}

local function displayNameFor(effectId: string) : string
	local definition = SkillEffects.Catalog[effectId]
	return if definition ~= nil then definition.DisplayName else effectId
end

local function isGood(effectId: string) : boolean
	local definition = SkillEffects.Catalog[effectId]
	return definition ~= nil and definition.Polarity == "Good"
end

local function createChip(effectId: string) : Chip?
	if container == nil then
		return nil
	end

	local frame = Instance.new("Frame")
	frame.Name = `EffectChip_{effectId}`
	frame.Size = UDim2.fromOffset(CHIP_SIZE.X, CHIP_SIZE.Y)
	frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = if isGood(effectId) then GOOD_COLOR else BAD_COLOR
	stroke.Thickness = 2
	stroke.Parent = frame

	-- Drains left-to-right behind the text, so the chip reads at a glance
	-- without anyone having to read the number.
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = if isGood(effectId) then GOOD_COLOR else BAD_COLOR
	fill.BackgroundTransparency = 0.72
	fill.BorderSizePixel = 0
	fill.ZIndex = 1
	fill.Parent = frame

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(0.92, 0.85)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 11
	label.TextColor3 = Color3.fromRGB(45, 45, 55)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = 2
	label.Text = displayNameFor(effectId)
	label.Parent = frame

	return { Frame = frame, Label = label, Fill = fill, ExpiresAt = 0, Duration = 0 }
end

local function removeChip(effectId: string)
	local chip = chipsByEffectId[effectId]
	if chip == nil then
		return
	end
	chip.Frame:Destroy()
	chipsByEffectId[effectId] = nil
end

-- Re-stacks the chips top to bottom. Called on add/remove only, not per frame.
local function relayout()
	local index = 0
	for _, chip in chipsByEffectId do
		chip.Frame.Position = UDim2.fromOffset(0, index * (CHIP_SIZE.Y + CHIP_GAP))
		index += 1
	end
end

local function onEffectChanged(effectId: unknown, durationSeconds: unknown)
	if typeof(effectId) ~= "string" or typeof(durationSeconds) ~= "number" then
		return
	end

	-- 0 = cleared early.
	if durationSeconds <= 0 then
		removeChip(effectId)
		relayout()
		return
	end

	local chip = chipsByEffectId[effectId]
	if chip == nil then
		chip = createChip(effectId)
		if chip == nil then
			return
		end
		chipsByEffectId[effectId] = chip
	end
	-- Re-applying an effect that is already running refreshes it rather than
	-- stacking a second identical chip.
	chip.ExpiresAt = os.clock() + durationSeconds
	chip.Duration = durationSeconds
	relayout()
end

function ActiveEffectsDisplay.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD") :: ScreenGui
	local addFansButton = mainHud:WaitForChild("SpecialTaskButton") :: GuiObject

	local stack = Instance.new("Frame")
	stack.Name = "ActiveEffectsStack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(1, 0)
	stack.Size = UDim2.fromOffset(CHIP_SIZE.X, 0)
	stack.Parent = mainHud
	container = stack

	-- Anchored to the ADD FANS button's real rect rather than a guessed
	-- position, so it stays under it through the mobile layout and any future
	-- move of that button. AbsolutePosition is inset-relative while a
	-- ScreenGui with IgnoreGuiInset positions in true-screen coordinates, so
	-- the offset has to be converted or the stack lands one topbar-height too
	-- high.
	local guiService = game:GetService("GuiService")
	local function reposition()
		local inset = guiService:GetGuiInset()
		local right = addFansButton.AbsolutePosition.X + addFansButton.AbsoluteSize.X + inset.X
		local top = addFansButton.AbsolutePosition.Y + addFansButton.AbsoluteSize.Y + inset.Y + STACK_TOP_GAP
		stack.Position = UDim2.fromOffset(right, top)
	end
	reposition()
	addFansButton:GetPropertyChangedSignal("AbsolutePosition"):Connect(reposition)
	addFansButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(reposition)

	Network.Combat.ActiveEffectChanged.OnClientEvent:Connect(onEffectChanged)

	-- ONE loop for every chip, and it only runs while at least one exists.
	-- Heartbeat rather than a task.wait loop so the bar drains smoothly, and
	-- it does no work at all in the common case of no active effects.
	RunService.Heartbeat:Connect(function()
		if next(chipsByEffectId) == nil then
			return
		end
		local now = os.clock()
		local expired: { string } = {}
		for effectId, chip in chipsByEffectId do
			local remaining = chip.ExpiresAt - now
			if remaining <= 0 then
				table.insert(expired, effectId)
			else
				chip.Label.Text = `{displayNameFor(effectId)}  {string.format("%.1f", remaining)}s`
				chip.Fill.Size = UDim2.fromScale(math.clamp(remaining / math.max(chip.Duration, 0.001), 0, 1), 1)
			end
		end
		if #expired > 0 then
			for _, effectId in expired do
				removeChip(effectId)
			end
			relayout()
		end
	end)
end

-- Test surface.
function ActiveEffectsDisplay.GetActiveChips() : { string }
	local ids: { string } = {}
	for effectId in chipsByEffectId do
		table.insert(ids, effectId)
	end
	table.sort(ids)
	return ids
end

return ActiveEffectsDisplay

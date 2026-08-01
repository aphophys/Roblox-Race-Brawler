--!strict
--[[
	BubblyTextEngine
	Reusable tween-driven "bubbly" label effect (scale pop + settle) used
	for announcements, fan-gain popups, etc.
]]

local TweenService = game:GetService("TweenService")

local POP_TWEEN_INFO = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SETTLE_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local BubblyTextEngine = {}

function BubblyTextEngine.PlayPop(label: TextLabel)
	local originalSize = label.Size
	label.Size = originalSize * 0.5

	local popTween = TweenService:Create(label, POP_TWEEN_INFO, { Size = originalSize * 1.1 })
	popTween.Completed:Connect(function()
		TweenService:Create(label, SETTLE_TWEEN_INFO, { Size = originalSize }):Play()
	end)
	popTween:Play()
end

function BubblyTextEngine.ShowAnnouncement(parent: Instance, text: string)
	-- TODO: clone a template from ReplicatedStorage.Assets.UI_Templates,
	-- set .Text, parent under `parent`, call PlayPop, then fade + destroy.
end

return BubblyTextEngine

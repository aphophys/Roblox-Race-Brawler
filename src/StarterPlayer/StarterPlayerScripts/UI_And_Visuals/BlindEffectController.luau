--!strict
--[[
	BlindEffectController
	Client-side visual for BlindTarget (SkillEffects.Catalog.BlindTarget,
	ControlScrambleMode = "Blind"). The server fires
	Network.Combat.ApplyControlEffect with (mode, durationSeconds) whenever a
	control-scramble effect actually lands (see
	EffectStackManager.TryApplyEffect); this controller handles the "Blind"
	mode of that one remote and ignores the rest, while
	ControlScrambleController handles "Invert"/"Randomize".

	Uses a Lighting.BlurEffect rather than any ScreenGui overlay: a
	BlurEffect blurs the rendered 3D viewport only — every ScreenGui (HUD
	buttons, capsules, panels) composites on top of that already-blurred
	frame, so they stay perfectly sharp. That's exactly "blurs the
	background/world view, buttons and other elements stay visible" with no
	extra bookkeeping needed to exclude UI from the effect.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local BLUR_SIZE = 24

local BlindEffectController = {}

local activeBlur: BlurEffect? = nil
-- os.clock() timestamp the blur should be removed at — re-casting Blind on
-- an already-blinded player extends this rather than stacking a second
-- BlurEffect (which would just be redundant, not additively blurrier).
local expiresAt = 0

local function ensureBlur()
	if activeBlur ~= nil then
		return
	end
	local blur = Instance.new("BlurEffect")
	blur.Name = "SkillBlindBlur"
	blur.Size = BLUR_SIZE
	blur.Parent = Lighting
	activeBlur = blur
end

-- Scheduled once per Blind ApplyControlEffect, `durationSeconds` later. Only
-- actually removes the blur if nothing extended `expiresAt` in the
-- meantime (a fresh cast landing before this one's timer fires).
local function removeBlurIfExpired()
	if activeBlur ~= nil and os.clock() >= expiresAt then
		activeBlur:Destroy()
		activeBlur = nil
	end
end

function BlindEffectController.Init()
	Network.Combat.ApplyControlEffect.OnClientEvent:Connect(function(mode: unknown, durationSeconds: unknown)
		if mode ~= "Blind" then
			return
		end
		if typeof(durationSeconds) ~= "number" then
			return
		end

		-- Duration 0 = the server removed the effect early (Dispel, or the
		-- cap+1 immunity sweep). Drop the blur immediately rather than
		-- leaving the player blind past the effect they no longer have.
		if durationSeconds <= 0 then
			expiresAt = 0
			removeBlurIfExpired()
			return
		end

		expiresAt = math.max(expiresAt, os.clock() + durationSeconds)
		ensureBlur()
		task.delay(durationSeconds, removeBlurIfExpired)
	end)
end

return BlindEffectController

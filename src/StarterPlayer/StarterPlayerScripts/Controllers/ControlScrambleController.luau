--!strict
--[[
	ControlScrambleController
	Makes the two control-scramble debuffs actually do something to input:
	ReverseControlTarget (ControlScrambleMode = "Invert") and ScrambleGlobal
	("Randomize"). Both were declared in SkillEffects and applied by
	EffectStackManager, but nothing anywhere consumed the mode — casting
	either changed nothing a player could feel. The third mode, "Blind", is
	handled by BlindEffectController off the same remote.

	Driven by Network.Combat.ApplyControlEffect (mode, durationSeconds),
	which the server fires from EffectStackManager.TryApplyEffect the moment
	an effect is genuinely accepted.

	## Why this is client-side, and why it is not WalkSpeed

	The obvious server-side version — flip the sign of Humanoid.WalkSpeed, so
	that every input device reverses at once for free — does not work:
	**Roblox clamps Humanoid.WalkSpeed to a minimum of 0.** Assigning -16
	reads back as exactly 0.0 (measured live), so the player freezes instead
	of reversing, which is strictly worse than the effect doing nothing
	because it silently becomes a stun. That finding is also recorded in
	MovementModifier next to the speed write.

	## How the override works without fighting the default controls

	Roblox's PlayerModule binds its control update to RenderStep at
	Enum.RenderPriority.Input; BindToRenderStep runs bindings in ascending
	priority, so a binding at Enum.RenderPriority.Character runs immediately
	AFTER it, every frame. By then PlayerModule has already resolved the raw
	input (keyboard, gamepad, or mobile thumbstick — they all funnel through
	the same place) into a world-space Humanoid.MoveDirection. We read that,
	transform it, and re-issue Humanoid:Move.

	The reason this doesn't oscillate — read a direction, negate it, then
	next frame read the negated one and negate it back — is precisely that
	ordering: PlayerModule rewrites MoveDirection from raw input at the START
	of every frame, so the value this binding reads is always the
	untransformed one. Nothing accumulates.

	Deliberately NOT done by reading PlayerModule's own ControlModule
	(`PlayerModule:GetControls():GetMoveVector()`): that is internal API whose
	camera-relative convention has changed between PlayerModule versions,
	whereas Humanoid.MoveDirection is a documented property with a fixed
	meaning.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local RENDER_STEP_NAME = "ControlScrambleOverride"

-- How often "Randomize" picks a new rotation. Short enough that the player
-- can't settle into compensating for it (which is the whole point of
-- Randomize existing separately from Invert), long enough to still be
-- steerable rather than pure noise.
local SCRAMBLE_REROLL_SECONDS = 1.5
-- Quarter turns only, and never 0 — a 0 would be an invisible free window
-- where the debuff appears to have stopped working. Excluding it leaves
-- "strafes instead of running", "runs backwards", "strafes the other way".
local SCRAMBLE_ANGLES = { math.pi / 2, math.pi, math.pi * 3 / 2 }

local ControlScrambleController = {}

-- os.clock() expiry per mode, so an Invert and a Randomize landing together
-- each run out on their own schedule instead of the second one's expiry
-- cancelling the first. Only "Invert"/"Randomize" are ever stored here.
local expiresAtByMode: { [string]: number } = {}
local isBound = false

local currentScrambleAngle = SCRAMBLE_ANGLES[1]
local nextRerollAt = 0

-- Randomize is strictly the more disruptive of the two, so it wins while
-- both are live; there is no meaningful "inverted AND rotated" state to
-- express, since a rotation of pi already IS the inversion.
local function activeMode() : string?
	local now = os.clock()
	if (expiresAtByMode.Randomize or 0) > now then
		return "Randomize"
	end
	if (expiresAtByMode.Invert or 0) > now then
		return "Invert"
	end
	return nil
end

local function rotateAroundY(direction: Vector3, angle: number) : Vector3
	local cosine, sine = math.cos(angle), math.sin(angle)
	return Vector3.new(
		direction.X * cosine - direction.Z * sine,
		direction.Y,
		direction.X * sine + direction.Z * cosine
	)
end

local function onRenderStep()
	local mode = activeMode()
	if mode == nil then
		return
	end

	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local direction = humanoid.MoveDirection
	if direction.Magnitude < 0.05 then
		-- Standing still. Re-issuing a zero Move here would be harmless but
		-- pointless, and skipping it keeps the "did the override actually
		-- fire" question answerable from MoveDirection alone.
		return
	end

	local transformed: Vector3
	if mode == "Randomize" then
		local now = os.clock()
		if now >= nextRerollAt then
			currentScrambleAngle = SCRAMBLE_ANGLES[math.random(1, #SCRAMBLE_ANGLES)]
			nextRerollAt = now + SCRAMBLE_REROLL_SECONDS
		end
		transformed = rotateAroundY(direction, currentScrambleAngle)
	else
		transformed = -direction
	end

	-- relativeToCamera = false: MoveDirection is already world-space, and so
	-- is everything derived from it above.
	humanoid:Move(transformed, false)
end

local function unbindIfExpired()
	if isBound and activeMode() == nil then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		isBound = false
	end
end

local function bindIfNeeded()
	if isBound then
		return
	end
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Character.Value, onRenderStep)
	isBound = true
end

function ControlScrambleController.Init()
	Network.Combat.ApplyControlEffect.OnClientEvent:Connect(function(mode: unknown, durationSeconds: unknown)
		if mode ~= "Invert" and mode ~= "Randomize" then
			return
		end
		if typeof(durationSeconds) ~= "number" then
			return
		end

		local modeKey = mode :: string

		-- Duration 0 is the server's cancel signal, sent when the effect is
		-- removed EARLY — a Dispel, or the cap+1 immunity sweep. Without it
		-- the server would drop the effect while this side kept remapping
		-- input for the rest of the original duration, so a Dispel would
		-- visibly fail to cure Reverse Control.
		if durationSeconds <= 0 then
			expiresAtByMode[modeKey] = nil
			unbindIfExpired()
			return
		end
		-- Extend rather than replace: a second cast landing mid-effect should
		-- never be able to SHORTEN the debuff already running.
		expiresAtByMode[modeKey] = math.max(expiresAtByMode[modeKey] or 0, os.clock() + durationSeconds)
		-- Force an immediate re-roll so a fresh Randomize doesn't inherit
		-- however much of the previous 1.5s window was left.
		nextRerollAt = 0
		bindIfNeeded()

		task.delay(durationSeconds, unbindIfExpired)
	end)

	-- A respawn hands the player a brand-new Humanoid; the binding resolves
	-- the character every frame, so nothing to rebind, but a scramble should
	-- not survive the death that interrupted it.
	localPlayer.CharacterAdded:Connect(function()
		table.clear(expiresAtByMode)
		unbindIfExpired()
	end)
end

return ControlScrambleController

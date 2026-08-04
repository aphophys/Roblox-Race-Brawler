--!strict
--[[
	MovementModifier
	Applies EffectStackManager's net stat multipliers to each player's
	Humanoid. Roblox's Humanoid only exposes one WalkSpeed knob (no native
	separate climb/swim speed), so this picks which net multiplier applies
	based on the Humanoid's current state each tick.
]]

local Players = game:GetService("Players")

local EffectStackManager = require(script.Parent:WaitForChild("EffectStackManager"))

local BASE_WALK_SPEED = 16
local BASE_JUMP_POWER = 50
local RECOMPUTE_INTERVAL_SECONDS = 0.25

local MovementModifier = {}

-- os.clock() timestamp a player's WalkSpeed is scripted-owned until (e.g. by
-- DashSelf's forced run) — recomputeForPlayer skips the normal EffectStackManager-
-- driven WalkSpeed write while active, so the two don't fight over the same
-- frame (confirmed live: without this, the 0.25s recompute loop stomped a
-- one-off `humanoid.WalkSpeed = X` set within a fraction of a second).
local walkSpeedOverrideUntil: { [Player]: number } = {}

-- Environmental speed effects (today: the desert wind) — a MULTIPLIER that
-- participates in the normal recompute alongside every buff and debuff,
-- rather than an exclusive override that replaces them.
--
-- The distinction matters and was a real, measured bug. The wind originally
-- used SetWalkSpeedOverride, which is correct for DashSelf (a scripted run
-- that must hold one specific speed for a known window no matter what else
-- is active) but wrong for weather. Once the wind became CONSTANT rather
-- than an occasional 2.5s gust, its override was permanently active for
-- anyone on a Desert segment, and the early return below meant **every
-- effect-driven WalkSpeed change was silently ignored there — slows
-- included**. Observed directly: baseline read 9.6 (the headwind value) and
-- casting a slow on top changed nothing at all.
local environmentMultiplierByPlayer: { [Player]: { Multiplier: number, ExpiresAt: number } } = {}

-- Temporarily takes WalkSpeed away from the normal effect-driven recompute
-- and hands it to the caller for `durationSeconds`. For SCRIPTED FORCED
-- MOVEMENT only (DashSelf's run) — something that needs one specific, stable
-- speed for a known window regardless of what else is active.
--
-- If what you want is "this place/condition makes people faster or slower",
-- that is SetEnvironmentSpeedMultiplier instead: an override suppresses
-- buffs and debuffs entirely for as long as it lasts, which is only ever
-- correct for something that lasts a fraction of a second.
-- Exported so movement skills can sanity-check the speeds they derive against
-- the speed they are supposed to beat, instead of hard-coding 16 a second
-- time. See SelfSkillManager's startup assertion.
MovementModifier.BaseWalkSpeed = BASE_WALK_SPEED

function MovementModifier.SetWalkSpeedOverride(player: Player, speed: number, durationSeconds: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	humanoid.WalkSpeed = speed
	walkSpeedOverrideUntil[player] = os.clock() + durationSeconds
end

-- Multiplies into the recompute for `durationSeconds`. Re-applying replaces
-- the previous value rather than compounding with it — callers like the wind
-- re-apply on a short cycle to keep the effect continuous, and compounding
-- would make one second of standing in a headwind accelerate toward zero.
function MovementModifier.SetEnvironmentSpeedMultiplier(player: Player, multiplier: number, durationSeconds: number)
	environmentMultiplierByPlayer[player] = {
		Multiplier = multiplier,
		ExpiresAt = os.clock() + durationSeconds,
	}
end

local function environmentMultiplier(player: Player) : number
	local entry = environmentMultiplierByPlayer[player]
	if entry == nil then
		return 1
	end
	if entry.ExpiresAt <= os.clock() then
		environmentMultiplierByPlayer[player] = nil
		return 1
	end
	return entry.Multiplier
end

local function recomputeForPlayer(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	-- ShockTarget (IsStun=true) previously only reduced WalkSpeed via its
	-- near-zero magnitude multiplier — a hard stop only in the limit, and
	-- jump power was untouched, so a "stunned" player could still jump away.
	-- "Stuns and unavailable to move" means literally zero: skip the normal
	-- multiplier math entirely and force both to 0 while any active effect
	-- has IsStun set.
	if EffectStackManager.IsStunned(player) then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		return
	end

	humanoid.JumpPower = BASE_JUMP_POWER * EffectStackManager.GetNetStatMultiplier(player, "JumpPower")

	local overrideUntil = walkSpeedOverrideUntil[player]
	if overrideUntil ~= nil then
		if overrideUntil > os.clock() then
			-- A scripted forced run owns WalkSpeed outright for its window —
			-- that is the whole point of the override, and DashSelf's window
			-- is a fraction of a second. Nothing environmental uses this path
			-- any more (see SetEnvironmentSpeedMultiplier), so this can no
			-- longer be permanently active and can no longer swallow a slow.
			return
		end
		walkSpeedOverrideUntil[player] = nil
	end

	local state = humanoid:GetState()
	local speedStat: "WalkSpeed" | "ClimbSpeed" | "SwimSpeed"
	if state == Enum.HumanoidStateType.Swimming then
		speedStat = "SwimSpeed"
	elseif state == Enum.HumanoidStateType.Climbing then
		speedStat = "ClimbSpeed"
	else
		speedStat = "WalkSpeed"
	end

	-- NOTE on control scramble (ReverseControlTarget / ScrambleGlobal):
	-- a negative WalkSpeed was tried here as a device-agnostic way to reverse
	-- movement, on the theory that Roblox drives the character along
	-- MoveDirection * WalkSpeed. **It does not work — Roblox CLAMPS
	-- Humanoid.WalkSpeed to a minimum of 0.** Measured live: assigning -16
	-- read back as exactly 0.0, so the player froze instead of reversing,
	-- which is worse than the effect doing nothing. Reverted deliberately.
	-- Control scramble is now done client-side instead, by re-issuing
	-- Humanoid:Move() with a transformed MoveDirection each frame — see
	-- StarterPlayerScripts.Controllers.ControlScrambleController. Nothing in
	-- this module touches it.
	--
	-- Environment and effects MULTIPLY rather than one winning: standing in a
	-- headwind while slowed should be worse than either alone, which is what
	-- a player would expect, and it means neither system can silently erase
	-- the other.
	local speed = BASE_WALK_SPEED
		* EffectStackManager.GetNetStatMultiplier(player, speedStat)
		* environmentMultiplier(player)

	humanoid.WalkSpeed = speed
end

function MovementModifier.GetEffectiveSpeed(player: Player) : number
	return BASE_WALK_SPEED * EffectStackManager.GetNetStatMultiplier(player, "WalkSpeed")
end

function MovementModifier.Init()
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				recomputeForPlayer(player)
			end
			task.wait(RECOMPUTE_INTERVAL_SECONDS)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		walkSpeedOverrideUntil[player] = nil
		environmentMultiplierByPlayer[player] = nil
	end)
end

return MovementModifier

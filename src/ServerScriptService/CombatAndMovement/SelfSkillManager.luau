--!strict
--[[
	SelfSkillManager
	New module (not in the original directory tree) — handles every
	CastType == "Self" skill (Dash, ChargedJumpForward, SpeedBoostSelf,
	SwimBurstSelf, ClimbGripSelf, ShieldSelf, PhaseSelf, CleansePulse). Most
	route generically through EffectStackManager; ChargedJumpForward is a
	one-off physics impulse (no lingering effect, so nothing to route);
	CleansePulse is a special-cased defensive Dispel.

	Casting is gated on PlayerState == InRace: skills can only be cast
	while on track.

	CastSkillDirect is the test-cast entry point for a carried SkillPickup
	(CarryItemService.ReleaseTrackItem) — Level 1 stats, no ownership/
	cooldown check.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local CollisionTags = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("CollisionTags"))

local CooldownTracker = require(script.Parent:WaitForChild("CooldownTracker"))
local EffectStackManager = require(script.Parent:WaitForChild("EffectStackManager"))
local PlayerStateService = require(script.Parent:WaitForChild("PlayerStateService"))
local MovementModifier = require(script.Parent:WaitForChild("MovementModifier"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("VisualEffectsService"))

local JUMP_UPWARD_SPEED = 40
-- Roughly how long JUMP_UPWARD_SPEED keeps the caster airborne under default
-- gravity — how long the forward run below should take to complete.
--
-- Deliberately NOT doubled with SkillTrees.DURATION_MULTIPLIER: this is not a
-- balance dial, it is the measured airtime of JUMP_UPWARD_SPEED. Doubling it
-- would not make the jump bigger (the distance is RangeStuds, unchanged) — it
-- would spread the same distance over twice the time, so the caster would
-- keep gliding forward for 0.4s after they had already landed. If the jump
-- should carry further, raise RangeStuds; if it should hang longer, raise
-- JUMP_UPWARD_SPEED and re-derive this from the new airtime.
local JUMP_FLIGHT_DURATION_SECONDS = 0.4
local NETWORK_OWNERSHIP_RETURN_DELAY_SECONDS = 1 -- long enough for the impulse to actually land before handing input prediction back to the player

local SelfSkillManager = {}

-- A dash that is slower than walking is not a dash, and that is a real bug
-- this codebase has already shipped once: DashSelf derived its speed from
-- EffectDurationSeconds, so raising the global duration multiplier silently
-- dropped it to 10 studs/s against a base walk speed of 16 — and because
-- SetWalkSpeedOverride suppresses the effect recompute, the caster was LOCKED
-- there for the duration. Nothing about that is visible in the config; it only
-- shows up as "dash feels wrong".
--
-- So the invariant gets checked at server start, where a bad tune is a loud
-- failure during testing rather than a quiet one in production. Asserted at
-- every level, because the curves move range and time independently and it is
-- entirely possible for only the top of a ladder to go bad.
-- `false` rather than nil for "use the level's own TraversalSeconds": a nil
-- VALUE removes the key from the table entirely, which would have silently
-- skipped DashSelf — the one skill this assertion exists for.
local MOVEMENT_SKILL_TRAVERSAL_TIMES: { [string]: number | boolean } = {
	DashSelf = false,
	ChargedJumpForward = JUMP_FLIGHT_DURATION_SECONDS,
}

for skillId, fixedTime in MOVEMENT_SKILL_TRAVERSAL_TIMES do
	local definition = SkillTrees[skillId]
	if definition ~= nil then
		for _, levelData in definition.Levels do
			local seconds = if typeof(fixedTime) == "number" then fixedTime else levelData.TraversalSeconds
			local speed = if seconds > 0 then levelData.RangeStuds / seconds else math.huge
			assert(
				speed > MovementModifier.BaseWalkSpeed,
				`SelfSkillManager: {skillId} L{levelData.Level} moves at {string.format("%.1f", speed)} studs/s, `
					.. `at or below the base walk speed of {MovementModifier.BaseWalkSpeed} — it would be slower than walking`
			)
		end
	end
end

-- os.clock() timestamp each currently-phasing player's collision group
-- should revert at — guards against a re-cast landing before the FIRST
-- cast's scheduled revert fires: that revert checks its own capture of
-- this value before touching the group, so an overlapping second cast's
-- (later) revert is the one that actually restores "Default", not the
-- stale first one cutting the phase window short.
local phasingUntil: { [Player]: number } = {}

local function setCharacterCollisionGroup(character: Model, groupName: string)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

-- PhaseSelf's actual collision pass-through (the "Bad"-polarity immunity
-- grant below is a separate, pre-existing mechanic — general debuff
-- immunity — and doesn't touch physics at all). Switches every part of the
-- caster's character into CollisionTags.PhasingCollisionGroup, which
-- CollisionTags registers as non-collidable with CollisionTags.
-- HazardCollisionGroup (every part TrackGenerator tags via MarkPhaseable),
-- for `durationSeconds`, then reverts to "Default".
local function beginPhase(caster: Player, character: Model, durationSeconds: number)
	setCharacterCollisionGroup(character, CollisionTags.PhasingCollisionGroup)
	-- Translucency rides the exact same expiry guard as the collision group,
	-- so the look can never outlast (or end before) the actual pass-through.
	VisualEffectsService.SetPhased(character, true)

	local expiresAt = os.clock() + durationSeconds
	phasingUntil[caster] = expiresAt

	task.delay(durationSeconds, function()
		if phasingUntil[caster] == expiresAt and character.Parent ~= nil then
			setCharacterCollisionGroup(character, "Default")
			VisualEffectsService.SetPhased(character, false)
			phasingUntil[caster] = nil
		end
	end)
end

-- Roblox gotcha CONFIRMED LIVE (Task: skill exaggeration testing pass) —
-- a player's own character is network-owned by their own client by
-- default, so a server script setting AssemblyLinearVelocity on it gets
-- overridden within ~1 frame by the client's own physics simulation, which
-- never applied that change: verified this was true even for
-- ChargedJumpForward's pre-existing, shipped formula (zero displacement
-- over 1.5s of observation). Forcing server ownership immediately before
-- the write, then handing it back shortly after, is the standard fix.
--
-- This is ONLY for the real vertical launch now (ChargedJumpForward's
-- upward component) — CONFIRMED LIVE that vertical-only velocity survives
-- fine this way (no ragdoll, real airtime) without needing PlatformStand.
-- Both skills used to also route their HORIZONTAL component through this
-- + `Humanoid.PlatformStand = true` — CONFIRMED LIVE via actual playtest
-- (not just position deltas, which looked fine) that PlatformStand is
-- Roblox's ragdoll/prone toggle: the caster visually collapsed and fell
-- over instead of dashing/jumping. Removing PlatformStand fixed the
-- ragdoll but (also confirmed live) dropped the horizontal carry back to
-- ~0.3 studs — Humanoid's own controller zeroes raw horizontal velocity
-- almost immediately once PlatformStand isn't suppressing it. See
-- runForward below for the real fix to the horizontal component.
local function launchCaster(character: Model, rootPart: BasePart, velocity: Vector3)
	local originalOwner = rootPart:GetNetworkOwner()
	rootPart:SetNetworkOwner(nil)
	rootPart.AssemblyLinearVelocity = velocity
	task.delay(NETWORK_OWNERSHIP_RETURN_DELAY_SECONDS, function()
		if rootPart.Parent ~= nil then
			rootPart:SetNetworkOwner(originalOwner)
		end
	end)
end

-- The real fix for the horizontal component of both DashSelf and
-- ChargedJumpForward: normal Humanoid locomotion (Humanoid:MoveTo), not a
-- raw physics impulse — keeps the caster upright and animated (Dash) or
-- correctly airborne-and-carrying (Jump, called alongside launchCaster's
-- vertical impulse) instead of the ground friction/ragdoll problems above.
-- "Current forward" is read fresh at cast time from the caster's actual
-- facing, so this composes correctly even if ReverseControlTarget is also
-- active on them — neither skill is driven by WASD input at all, so
-- control-scramble effects (which only invert/randomize input handling)
-- don't affect either one either way. Speed is derived so the caster
-- arrives at exactly `distanceStuds` by the end of `durationSeconds` —
-- MovementModifier.SetWalkSpeedOverride is what stops the normal
-- effect-recompute loop from stomping that speed mid-run. CONFIRMED LIVE
-- (Dash): MoveTo alone (no NetworkOwner/PlatformStand needed) keeps
-- Humanoid state "Running" throughout and lands within a fraction of a
-- stud of the intended distance.
local function runForward(caster: Player, character: Model, rootPart: BasePart, distanceStuds: number, durationSeconds: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or durationSeconds <= 0 then
		return
	end

	local forward = rootPart.CFrame.LookVector
	local forwardFlat = Vector3.new(forward.X, 0, forward.Z)
	if forwardFlat.Magnitude > 0 then
		forwardFlat = forwardFlat.Unit
	end

	MovementModifier.SetWalkSpeedOverride(caster, distanceStuds / durationSeconds, durationSeconds)
	humanoid:MoveTo(rootPart.Position + forwardFlat * distanceStuds)
end

-- Shared by tryCast (owned skill, real level, cooldown-gated) and
-- CastSkillDirect (test cast, Level 1, no cooldown).
local function resolveAndApply(caster: Player, skillId: string, skillDefinition: SkillTrees.SkillDefinition, levelData: SkillTrees.SkillLevelData, atPeakLevel: boolean)
	-- Cast sound and burst live HERE rather than in tryCast, so the
	-- CastSkillDirect path (releasing a carried skill pickup) gets them too.
	-- Confirmed live that it previously got neither: a CastSkillDirect
	-- ShieldSelf produced the shield bubble — that part is in this shared
	-- function — but no sound and no burst, because those two were the only
	-- pieces sitting up in tryCast.
	SoundDirector.PlayAtCharacter(caster, "SkillSelf")
	if caster.Character ~= nil then
		VisualEffectsService.ShowCastBurst(caster.Character, VisualEffectsService.BuffColor)
	end

	if skillId == "ChargedJumpForward" then
		local character = caster.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if character == nil or rootPart == nil then
			return
		end
		launchCaster(character, rootPart, Vector3.new(0, JUMP_UPWARD_SPEED, 0)) -- vertical only; runForward below owns the horizontal distance
		runForward(caster, character, rootPart, levelData.RangeStuds, JUMP_FLIGHT_DURATION_SECONDS)
	elseif skillDefinition.DispelMode == "Defensive" then
		EffectStackManager.Dispel("Defensive", levelData.DispelCount or 1, caster, nil)
	elseif skillDefinition.LinkedEffectId ~= nil then
		-- DashSelf's own description ("Bursts forward a short distance with
		-- a brief speed boost") is two effects, not one — RangeStuds (the
		-- distance) was defined per-level but never read for this branch
		-- at all until this fix, so casting Dash produced zero displacement.
		-- See runForward's docstring for the fix itself.
		if skillId == "DashSelf" then
			local character = caster.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if character ~= nil and rootPart ~= nil then
				-- TraversalSeconds, NOT EffectDurationSeconds. runForward
				-- derives speed as distance/time, so feeding it the buff
				-- duration makes the dash SLOWER every time that duration is
				-- tuned upward — which is exactly what happened when
				-- DURATION_MULTIPLIER went 2 -> 4 and Dash dropped to 10
				-- studs/s against a base walk speed of 16. See the field's
				-- note in SkillTrees.
				runForward(caster, character, rootPart, levelData.RangeStuds, levelData.TraversalSeconds)
				-- The trail stays on the BUFF duration: the burst of movement
				-- is over in TraversalSeconds, but the speed boost it grants
				-- lasts the full effect, and the trail is what shows that.
				VisualEffectsService.ShowTrail(character, levelData.EffectDurationSeconds)
			end
		elseif skillId == "PhaseSelf" then
			local character = caster.Character
			if character ~= nil then
				beginPhase(caster, character, levelData.EffectDurationSeconds)
			end
		elseif skillId == "ShieldSelf" then
			local character = caster.Character
			if character ~= nil then
				VisualEffectsService.ShowShield(character, levelData.EffectDurationSeconds)
			end
		elseif skillId == "SpeedBoostSelf" then
			local character = caster.Character
			if character ~= nil then
				VisualEffectsService.ShowTrail(character, levelData.EffectDurationSeconds)
			end
		end

		EffectStackManager.TryApplyEffect(
			caster,
			skillDefinition.LinkedEffectId,
			"Self",
			levelData.EffectMagnitude,
			levelData.EffectDurationSeconds,
			atPeakLevel
		)
	end

	Network.Track.ShowNotification:FireClient(caster, skillDefinition.ActivationNoticeText)
end

local function tryCast(caster: Player, skillId: string)
	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Self" then
		return
	end

	if PlayerStateService.GetState(caster) ~= PlayerState.InRace then
		return
	end

	local profile = ProfileManager.GetProfile(caster)
	if profile == nil then
		return
	end

	local skillData = profile.Data.Skills[skillId]
	if skillData == nil or not skillData.Unlocked or skillData.Level < 1 then
		return
	end

	local levelData = skillDefinition.Levels[skillData.Level]
	if levelData == nil then
		return
	end

	if not CooldownTracker.TryConsume(caster, skillId, levelData.CooldownSeconds) then
		return
	end

	-- Sound/VFX are NOT here — they moved into resolveAndApply, which
	-- CastSkillDirect shares.
	Network.Combat.SkillCastResult:FireClient(caster, skillId, levelData.CooldownSeconds)

	local atPeakLevel = skillData.Level >= skillDefinition.MaxLevel
	resolveAndApply(caster, skillId, skillDefinition, levelData, atPeakLevel)
end

function SelfSkillManager.CastSkillDirect(caster: Player, skillId: string)
	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Self" then
		return
	end

	local levelData = skillDefinition.Levels[1]
	if levelData == nil then
		return
	end

	resolveAndApply(caster, skillId, skillDefinition, levelData, false)
end

function SelfSkillManager.Init()
	Network.Combat.FireSelfSkill.OnServerEvent:Connect(function(player: Player, skillId: unknown)
		if typeof(skillId) ~= "string" then
			return
		end
		tryCast(player, skillId)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		phasingUntil[player] = nil
	end)
end

return SelfSkillManager

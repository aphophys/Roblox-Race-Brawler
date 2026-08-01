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

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local CooldownTracker = require(script.Parent:WaitForChild("CooldownTracker"))
local EffectStackManager = require(script.Parent:WaitForChild("EffectStackManager"))
local PlayerStateService = require(script.Parent:WaitForChild("PlayerStateService"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))

local JUMP_UPWARD_SPEED = 40

local SelfSkillManager = {}

-- Shared by tryCast (owned skill, real level, cooldown-gated) and
-- CastSkillDirect (test cast, Level 1, no cooldown).
local function resolveAndApply(caster: Player, skillId: string, skillDefinition: SkillTrees.SkillDefinition, levelData: SkillTrees.SkillLevelData, atPeakLevel: boolean)
	if skillId == "ChargedJumpForward" then
		local character = caster.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart == nil then
			return
		end
		local forward = rootPart.CFrame.LookVector
		local forwardFlat = Vector3.new(forward.X, 0, forward.Z)
		if forwardFlat.Magnitude > 0 then
			forwardFlat = forwardFlat.Unit
		end
		rootPart.AssemblyLinearVelocity = forwardFlat * levelData.RangeStuds + Vector3.new(0, JUMP_UPWARD_SPEED, 0)
	elseif skillDefinition.DispelMode == "Defensive" then
		EffectStackManager.Dispel("Defensive", levelData.DispelCount or 1, caster, nil)
	elseif skillDefinition.LinkedEffectId ~= nil then
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
end

return SelfSkillManager

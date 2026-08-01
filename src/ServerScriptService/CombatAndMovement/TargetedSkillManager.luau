--!strict
--[[
	TargetedSkillManager
	Handles every CastType == "Target" skill in SkillTrees: PositionSwap
	(special-cased instant swap), SiphonPulse (special-cased offensive
	Dispel), and everything else generically via EffectStackManager.
	Target validity is resolved with workspace:GetPartBoundsInRadius around
	the caster — never .Touched.

	Casting is gated on PlayerState == InRace: skills can only be cast
	while on track.

	CastSkillDirect is the test-cast entry point for a carried SkillPickup
	(CarryItemService.ReleaseTrackItem) — Level 1 stats, no ownership/
	cooldown check (the single-carry-slot + pickup travel time is the
	limiting factor for test casts, not the skill's own cooldown).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local CooldownTracker = require(script.Parent:WaitForChild("CooldownTracker"))
local EffectStackManager = require(script.Parent:WaitForChild("EffectStackManager"))
local PlayerStateService = require(script.Parent:WaitForChild("PlayerStateService"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))

local TargetedSkillManager = {}

local function findNearestTarget(caster: Player, casterRootPart: BasePart, range: number) : Player?
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = if caster.Character then { caster.Character } else {}

	local parts = workspace:GetPartBoundsInRadius(casterRootPart.Position, range, overlapParams)

	local nearestPlayer: Player? = nil
	local nearestDistance = math.huge

	for _, part in parts do
		if part.Name ~= "HumanoidRootPart" then
			continue
		end

		local otherPlayer = Players:GetPlayerFromCharacter(part.Parent)
		if otherPlayer == nil or otherPlayer == caster then
			continue
		end

		local distance = (part.Position - casterRootPart.Position).Magnitude
		if distance < nearestDistance then
			nearestDistance = distance
			nearestPlayer = otherPlayer
		end
	end

	return nearestPlayer
end

-- Shared by tryCast (owned skill, real level, cooldown-gated) and
-- CastSkillDirect (test cast, Level 1, no cooldown).
local function resolveAndApply(caster: Player, skillId: string, skillDefinition: SkillTrees.SkillDefinition, levelData: SkillTrees.SkillLevelData, atPeakLevel: boolean)
	local character = caster.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart == nil then
		return
	end

	local target = findNearestTarget(caster, rootPart, levelData.RangeStuds)
	if target == nil then
		return
	end

	if skillId == "PositionSwap" then
		local targetCharacter = target.Character
		local targetRootPart = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if targetRootPart == nil then
			return
		end
		local casterCFrame, targetCFrame = rootPart.CFrame, targetRootPart.CFrame
		rootPart.CFrame = targetCFrame
		targetRootPart.CFrame = casterCFrame
	elseif skillDefinition.DispelMode == "Offensive" then
		EffectStackManager.Dispel("Offensive", levelData.DispelCount or 1, caster, target)
	elseif skillDefinition.LinkedEffectId ~= nil then
		EffectStackManager.TryApplyEffect(
			target,
			skillDefinition.LinkedEffectId,
			"Target",
			levelData.EffectMagnitude,
			levelData.EffectDurationSeconds,
			atPeakLevel
		)
	end

	-- Target skills notify whoever the effect actually landed on, not the caster.
	Network.Track.ShowNotification:FireClient(target, skillDefinition.ActivationNoticeText)
end

local function tryCast(caster: Player, skillId: string)
	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Target" then
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

	-- Fired as soon as the cooldown is consumed (even if no target is found
	-- below) so the client's cooldown visual always matches server truth.
	Network.Combat.SkillCastResult:FireClient(caster, skillId, levelData.CooldownSeconds)

	local atPeakLevel = skillData.Level >= skillDefinition.MaxLevel
	resolveAndApply(caster, skillId, skillDefinition, levelData, atPeakLevel)
end

-- Test-cast entry point for a carried SkillPickup — bypasses ownership and
-- cooldown, always uses Level 1 stats.
function TargetedSkillManager.CastSkillDirect(caster: Player, skillId: string)
	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Target" then
		return
	end

	local levelData = skillDefinition.Levels[1]
	if levelData == nil then
		return
	end

	resolveAndApply(caster, skillId, skillDefinition, levelData, false)
end

function TargetedSkillManager.Init()
	Network.Combat.FireTargetedSkill.OnServerEvent:Connect(function(player: Player, skillId: unknown)
		if typeof(skillId) ~= "string" then
			return
		end
		tryCast(player, skillId)
	end)
end

return TargetedSkillManager

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
local SkillRewardService = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("SkillRewardService"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("VisualEffectsService"))

-- Matches the requested ~0.5s purple lightning flash on PositionSwap.
local SWAP_ARC_SECONDS = 0.5
local SWAP_ARC_COLOR = Color3.fromRGB(190, 90, 255)
-- Wind-up before a Target cast resolves. This is a deliberate, requested
-- gameplay change ("maybe adding 0.5 second cast time before swap, or an
-- actual lightning or magical energy ball ... to arrive the player") and the
-- only one in this round: a cast now has a visible charge, a bolt that
-- travels, and lands when the bolt does, instead of resolving the instant the
-- button is pressed. The cooldown is still consumed up front, so the wind-up
-- can't be used to hold a cast open.
local CAST_WINDUP_SECONDS = 0.5

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

	-- Cast sound and burst live HERE, in the shared resolve, rather than in
	-- tryCast. They used to sit in tryCast, so CastSkillDirect — the "release
	-- a carried skill pickup" path — produced neither, and a pickup cast was
	-- almost completely silent. GlobalSkillStateMachine never had this problem
	-- precisely because its sound/VFX were already in its shared `activate`.
	SoundDirector.PlayAtCharacter(caster, if skillId == "PositionSwap" then "SkillSwap" else "SkillTarget")
	if caster.Character ~= nil then
		VisualEffectsService.ShowCastBurst(caster.Character, VisualEffectsService.DebuffColor)
		VisualEffectsService.ShowChargeUp(caster.Character, VisualEffectsService.DebuffColor, CAST_WINDUP_SECONDS)
	end
	SoundDirector.PlayAtCharacter(caster, "CastCharge")

	-- Wind-up, then a real projectile that flies to the target and lands
	-- before anything is applied. Both halves are what the effect actually
	-- being cast looks like, so the effect must wait for them: a debuff that
	-- lands before its own bolt arrives would make the bolt decorative.
	task.wait(CAST_WINDUP_SECONDS)

	-- Everything has to be re-read after the wait — half a second is plenty
	-- of time for either character to be respawned, or for the target to
	-- leave. Nothing below may assume the pre-wait state still holds.
	local casterRootPart = caster.Character and caster.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local targetRootPartNow = target.Character and target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if casterRootPart == nil or targetRootPartNow == nil then
		return
	end

	local travelSeconds = VisualEffectsService.ShowCastProjectile(
		casterRootPart,
		targetRootPartNow,
		if skillId == "PositionSwap" then SWAP_ARC_COLOR else VisualEffectsService.DebuffColor
	)
	task.wait(travelSeconds)

	if target.Parent == nil then
		return
	end
	SoundDirector.PlayAtCharacter(target, "ProjectileHit")

	-- Re-resolved a second time for the same reason as above: the projectile's
	-- own flight is another window in which a character can be replaced.
	rootPart = caster.Character and caster.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart == nil then
		return
	end

	if skillId == "PositionSwap" then
		local targetCharacter = target.Character
		local targetRootPart = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if targetRootPart == nil then
			return
		end
		-- Arc drawn BEFORE the swap, between where the two actually are, so
		-- it visibly connects the pair being exchanged rather than snapping
		-- to their post-swap positions.
		VisualEffectsService.ShowSwapArc(rootPart, targetRootPart, SWAP_ARC_SECONDS)
		local casterCFrame, targetCFrame = rootPart.CFrame, targetRootPart.CFrame
		rootPart.CFrame = targetCFrame
		targetRootPart.CFrame = casterCFrame
	elseif skillDefinition.DispelMode == "Offensive" then
		EffectStackManager.Dispel("Offensive", levelData.DispelCount or 1, caster, target)
	elseif skillDefinition.LinkedEffectId ~= nil then
		-- Every control-scramble mode (Blind / Invert / Randomize) is told to
		-- the affected client by EffectStackManager.TryApplyEffect itself, at
		-- the point the effect is accepted — see Network.Combat.
		-- ApplyControlEffect. This used to be a Blind-only special case right
		-- here, which is precisely why ScrambleGlobal, cast through
		-- GlobalSkillStateMachine rather than this manager, never reached any
		-- client.
		EffectStackManager.TryApplyEffect(
			target,
			skillDefinition.LinkedEffectId,
			"Target",
			levelData.EffectMagnitude,
			levelData.EffectDurationSeconds,
			atPeakLevel
		)
	end

	-- ATTRIBUTION — both halves of "who cast what on whom".
	--
	-- The victim used to be told only WHAT had landed ("BLINDED!"), with no way
	-- to know who did it, and the caster was told nothing at all beyond the
	-- cooldown starting — so a hit that connected and a hit that fizzled looked
	-- identical from the casting end. Both are now named events.
	--
	-- Deliberately sent to the two players INVOLVED and to nobody else, unlike
	-- the server-wide global announcement. Target cooldowns run 8-20s, so a
	-- full 40-player server casting on cooldown would produce roughly three of
	-- these per second; broadcast, that is not a rivalry, it is a wall of text
	-- that would bury the checkpoint and reward notices sharing the same toast
	-- stack.
	local skillName = string.upper(skillDefinition.DisplayName)
	Network.Track.ShowNotification:FireClient(
		target,
		`{skillDefinition.ActivationNoticeText} — {caster.DisplayName} CAST {skillName} ON YOU`
	)
	-- Dead branch today, kept as a guard rather than an assumption: EVERY route
	-- into this function (tryCast and CastSkillDirect both) resolves its target
	-- through findNearestTarget, which skips the caster — so caster and target
	-- cannot currently be the same player. That invariant lives in one function
	-- far from here, and the failure it would cause if it ever changed is the
	-- caster being told twice about a cast they aimed at themselves.
	if target ~= caster then
		Network.Track.ShowNotification:FireClient(caster, `🎯 YOU CAST {skillName} ON {target.DisplayName}`)
	end

	-- Only reached once the effect has actually LANDED on a target — past the
	-- range check, the wind-up and the projectile's flight, any of which can
	-- return early. A cast that fizzles pays nothing, which is why this is at
	-- the bottom of the resolve and not up beside the cooldown consumption.
	SkillRewardService.GrantCastReward(caster, skillDefinition.CastType)
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

	-- Target check BEFORE the cooldown is consumed. Previously the cooldown
	-- was burned first and resolveAndApply then silently returned when
	-- findNearestTarget came back nil — so casting with nobody in range cost
	-- the player the whole cooldown, did nothing, and told them nothing. A
	-- Target-cast skill with no target isn't a failed cast, it's a cast that
	-- must not happen.
	local character = caster.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart == nil then
		return
	end

	if findNearestTarget(caster, rootPart, levelData.RangeStuds) == nil then
		Network.Track.ShowNotification:FireClient(caster, "NO TARGET IN RANGE!")
		SoundDirector.PlayForPlayer(caster, "SkillBlocked")
		return
	end

	if not CooldownTracker.TryConsume(caster, skillId, levelData.CooldownSeconds) then
		return
	end

	-- Fired as soon as the cooldown is consumed so the client's cooldown
	-- visual always matches server truth. The cast's own sound and VFX are
	-- NOT here — they moved into resolveAndApply, which CastSkillDirect shares.
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

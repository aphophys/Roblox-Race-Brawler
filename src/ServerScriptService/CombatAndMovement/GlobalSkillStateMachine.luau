--!strict
--[[
	GlobalSkillStateMachine
	Handles every CastType == "Global" skill. Two gates stack here: a
	per-player CooldownTracker entry (can't spam-cast) AND a server-wide
	Idle/Active/Cooldown state (only one Global skill effect can be active
	map-wide at a time, regardless of who cast it) — the latter is what
	makes this its own module instead of folding into TargetedSkillManager.

	Casting is gated on the caster's PlayerState == InRace. The effect
	itself only applies to players who are currently InRace too — a Hub or
	Fan Box visitor shouldn't be slowed by a track-wide skill they're not
	part of.

	CastSkillDirect is the test-cast entry point for a carried SkillPickup
	(CarryItemService.ReleaseTrackItem) — Level 1 stats, no ownership/
	cooldown check, but STILL respects the Idle/Active/Cooldown gate (a
	test cast shouldn't be able to stack with or interrupt a real one).
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

export type GlobalSkillState = "Idle" | "Active" | "Cooldown"

local GlobalSkillStateMachine = {}

local currentState: GlobalSkillState = "Idle"
local activeSkillId: string? = nil

-- Shared by tryActivate (owned skill, real level) and CastSkillDirect
-- (test cast, Level 1). Assumes the Idle gate was already checked by the
-- caller.
local function activate(caster: Player, skillId: string, skillDefinition: SkillTrees.SkillDefinition, levelData: SkillTrees.SkillLevelData, atPeakLevel: boolean)
	currentState = "Active"
	activeSkillId = skillId

	Network.Combat.SkillCastResult:FireClient(caster, skillId, levelData.CooldownSeconds)
	SoundDirector.PlayAtCharacter(caster, "SkillGlobal")
	if caster.Character ~= nil then
		VisualEffectsService.ShowCastBurst(caster.Character, Color3.fromRGB(178, 102, 255))
	end

	-- Upper-cased to sit in the same register as ActivationNoticeText and the
	-- SegmentAnnouncer lines, which already shout their DisplayNames.
	local skillName = string.upper(skillDefinition.DisplayName)

	for _, player in Players:GetPlayers() do
		if PlayerStateService.GetState(player) ~= PlayerState.InRace then
			continue
		end
		EffectStackManager.TryApplyEffect(
			player,
			skillDefinition.LinkedEffectId :: string,
			"Global",
			levelData.EffectMagnitude,
			levelData.EffectDurationSeconds,
			atPeakLevel
		)

		-- ATTRIBUTION. The notice used to say only what had happened
		-- ("SLOWED DOWN!"), which made a global read as weather — something the
		-- track did to you. Naming the caster turns the same event into
		-- somebody's doing, which is the whole appeal of a sabotage racer.
		--
		-- Effect first, blame second: what just happened to you is the part you
		-- need in order to react, and the name is what you want a moment later.
		--
		-- Broadcasting this to every racer is affordable here and ONLY here: the
		-- state machine allows one global to be Active server-wide at a time and
		-- the cheapest global still has a 70s cooldown, so these arrive rarely by
		-- construction. The same broadcast for Target skills would be ~3 toasts a
		-- second on a full server — see TargetedSkillManager, which deliberately
		-- tells only the two players involved.
		local notice = if player == caster
			then `⚡ YOU CAST {skillName}!`
			else `{skillDefinition.ActivationNoticeText} — {caster.DisplayName} CAST {skillName}`
		Network.Track.ShowNotification:FireClient(player, notice)
	end

	-- The Idle gate let this through and the effect has gone out to the field,
	-- so the cast succeeded. Before the task.spawn below, which is only the
	-- Active -> Cooldown -> Idle wind-down.
	SkillRewardService.GrantCastReward(caster, skillDefinition.CastType)

	task.spawn(function()
		task.wait(levelData.EffectDurationSeconds)
		currentState = "Cooldown"
		task.wait(math.max(levelData.CooldownSeconds - levelData.EffectDurationSeconds, 0))
		currentState = "Idle"
		activeSkillId = nil
	end)
end

local function tryActivate(caster: Player, skillId: string) : boolean
	if currentState ~= "Idle" then
		return false
	end

	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Global" or skillDefinition.LinkedEffectId == nil then
		return false
	end

	if PlayerStateService.GetState(caster) ~= PlayerState.InRace then
		return false
	end

	local profile = ProfileManager.GetProfile(caster)
	if profile == nil then
		return false
	end

	local skillData = profile.Data.Skills[skillId]
	if skillData == nil or not skillData.Unlocked or skillData.Level < 1 then
		return false
	end

	local levelData = skillDefinition.Levels[skillData.Level]
	if levelData == nil then
		return false
	end

	if not CooldownTracker.TryConsume(caster, skillId, levelData.CooldownSeconds) then
		return false
	end

	local atPeakLevel = skillData.Level >= skillDefinition.MaxLevel
	activate(caster, skillId, skillDefinition, levelData, atPeakLevel)
	return true
end

function GlobalSkillStateMachine.CastSkillDirect(caster: Player, skillId: string)
	if currentState ~= "Idle" then
		return
	end

	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil or skillDefinition.CastType ~= "Global" or skillDefinition.LinkedEffectId == nil then
		return
	end

	local levelData = skillDefinition.Levels[1]
	if levelData == nil then
		return
	end

	activate(caster, skillId, skillDefinition, levelData, false)
end

function GlobalSkillStateMachine.GetState() : GlobalSkillState
	return currentState
end

function GlobalSkillStateMachine.Init()
	Network.Combat.FireGlobalSkill.OnServerEvent:Connect(function(player: Player, skillId: unknown)
		if typeof(skillId) ~= "string" then
			return
		end
		tryActivate(player, skillId)
	end)
end

return GlobalSkillStateMachine

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

export type GlobalSkillState = "Idle" | "Active" | "Cooldown"

local GlobalSkillStateMachine = {}

local currentState: GlobalSkillState = "Idle"
local activeSkillId: string? = nil

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

	currentState = "Active"
	activeSkillId = skillId

	local atPeakLevel = skillData.Level >= skillDefinition.MaxLevel
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
	end

	task.spawn(function()
		task.wait(levelData.EffectDurationSeconds)
		currentState = "Cooldown"
		task.wait(math.max(levelData.CooldownSeconds - levelData.EffectDurationSeconds, 0))
		currentState = "Idle"
		activeSkillId = nil
	end)

	return true
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

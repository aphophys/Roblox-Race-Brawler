--!strict
--[[
	EffectStackManager
	Runtime owner of every active buff/debuff, enforcing the rules in
	ReplicatedStorage.Configs.SkillEffects.StackingRules: per-polarity caps
	(3 normal / 5 at peak skill level), the "one-past-cap application grants
	immunity instead of stacking" rule, per-source concurrency (1 Global +
	2 Target + 2 Self by default), and Dispel. All skills that apply a
	lingering effect route through TryApplyEffect rather than writing
	directly to MovementModifier, so this logic exists exactly once.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkillEffects = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillEffects"))

export type EffectSource = "Global" | "Target" | "Self"

export type ActiveEffectInstance = {
	EffectId: string,
	Source: EffectSource,
	Magnitude: number, -- pre-resolved from the casting skill's level (SkillTrees.SkillLevelData.EffectMagnitude)
	ExpiresAt: number, -- os.clock()
}

export type PolarityImmunity = {
	Good: number, -- os.clock() timestamp immunity to that polarity expires at (0 = not immune)
	Bad: number,
}

local PURGE_INTERVAL_SECONDS = 1

local EffectStackManager = {}

local activeEffectsByPlayer: { [Player]: { ActiveEffectInstance } } = {}
local immunityByPlayer: { [Player]: PolarityImmunity } = {}

local function getOrCreateList(player: Player) : { ActiveEffectInstance }
	local list = activeEffectsByPlayer[player]
	if list == nil then
		list = {}
		activeEffectsByPlayer[player] = list
	end
	return list
end

local function purgeExpired(player: Player)
	local list = activeEffectsByPlayer[player]
	if list == nil then
		return
	end

	local now = os.clock()
	for i = #list, 1, -1 do
		if list[i].ExpiresAt <= now then
			table.remove(list, i)
		end
	end
end

local function isImmune(player: Player, polarity: SkillEffects.EffectPolarity) : boolean
	local immunity = immunityByPlayer[player]
	return immunity ~= nil and immunity[polarity] > os.clock()
end

local function grantImmunity(player: Player, polarity: SkillEffects.EffectPolarity)
	local immunity = immunityByPlayer[player]
	if immunity == nil then
		immunity = { Good = 0, Bad = 0 }
		immunityByPlayer[player] = immunity
	end
	immunity[polarity] = os.clock() + SkillEffects.StackingRules.ImmunityDurationSeconds
end

-- Attempts to apply `effectId` to `player`. Returns false if rejected
-- (immune, or over the per-source concurrency slot for this polarity —
-- the latter doesn't grant immunity, it's just a "no room" rejection).
-- On the (cap+1)th same-polarity application overall, this clears the
-- player's existing same-polarity stacks and grants immunity instead of
-- applying — that's the documented behavior for the "4th application"
-- rule (cap+1 so it scales correctly with the peak-level cap of 5).
function EffectStackManager.TryApplyEffect(
	player: Player,
	effectId: string,
	source: EffectSource,
	magnitude: number,
	durationSeconds: number,
	atPeakLevel: boolean
) : boolean
	local effectDefinition = SkillEffects.Catalog[effectId]
	if effectDefinition == nil then
		return false
	end

	local polarity = effectDefinition.Polarity

	if isImmune(player, polarity) then
		return false
	end

	purgeExpired(player)
	local list = getOrCreateList(player)

	local samePolarityCount = 0
	local sameSourceCount = 0
	for _, instance in list do
		local instanceDefinition = SkillEffects.Catalog[instance.EffectId]
		if instanceDefinition ~= nil and instanceDefinition.Polarity == polarity then
			samePolarityCount += 1
			if instance.Source == source then
				sameSourceCount += 1
			end
		end
	end

	local cap = if atPeakLevel then SkillEffects.StackingRules.MaxStackedPerPolarityAtPeakLevel else SkillEffects.StackingRules.MaxStackedPerPolarity
	local immunityTriggerCount = cap + 1

	if samePolarityCount + 1 >= immunityTriggerCount then
		for i = #list, 1, -1 do
			local instanceDefinition = SkillEffects.Catalog[list[i].EffectId]
			if instanceDefinition ~= nil and instanceDefinition.Polarity == polarity then
				table.remove(list, i)
			end
		end
		grantImmunity(player, polarity)
		return false
	end

	local sourceCap = SkillEffects.StackingRules.MaxConcurrentBySource[source]
	if sameSourceCount + 1 > sourceCap then
		return false
	end

	table.insert(list, {
		EffectId = effectId,
		Source = source,
		Magnitude = magnitude,
		ExpiresAt = os.clock() + durationSeconds,
	})

	return true
end

-- Net multiplier for `stat` across every active effect touching it — Good
-- and Bad effects on the same stat both contribute (product), so a slow
-- and a speed boost on the same player partially cancel out rather than
-- one unconditionally overriding the other.
function EffectStackManager.GetNetStatMultiplier(player: Player, stat: SkillEffects.MovementStat) : number
	purgeExpired(player)
	local list = activeEffectsByPlayer[player]
	if list == nil then
		return 1
	end

	local multiplier = 1
	for _, instance in list do
		local definition = SkillEffects.Catalog[instance.EffectId]
		if definition == nil then
			continue
		end
		for _, affectedStat in definition.AffectsStats do
			if affectedStat == stat then
				multiplier *= instance.Magnitude
				break
			end
		end
	end

	return multiplier
end

function EffectStackManager.IsControlsScrambled(player: Player) : SkillEffects.ControlScrambleMode?
	purgeExpired(player)
	local list = activeEffectsByPlayer[player]
	if list == nil then
		return nil
	end

	for _, instance in list do
		local definition = SkillEffects.Catalog[instance.EffectId]
		if definition ~= nil and definition.IsControlScramble then
			return definition.ControlScrambleMode
		end
	end

	return nil
end

-- mode == "Defensive": strips up to `count` of `player`'s own Bad effects.
-- mode == "Offensive": strips up to `count` of `targetPlayer`'s Good effects
-- (targetPlayer required in that case).
function EffectStackManager.Dispel(mode: "Offensive" | "Defensive", count: number, player: Player, targetPlayer: Player?)
	local victim = if mode == "Offensive" then targetPlayer else player
	if victim == nil then
		return
	end

	local targetPolarity: SkillEffects.EffectPolarity = if mode == "Offensive" then "Good" else "Bad"

	purgeExpired(victim)
	local list = activeEffectsByPlayer[victim]
	if list == nil then
		return
	end

	local removedCount = 0
	for i = #list, 1, -1 do
		if removedCount >= count then
			break
		end
		local definition = SkillEffects.Catalog[list[i].EffectId]
		if definition ~= nil and definition.Polarity == targetPolarity then
			table.remove(list, i)
			removedCount += 1
		end
	end
end

function EffectStackManager.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		activeEffectsByPlayer[player] = nil
		immunityByPlayer[player] = nil
	end)

	task.spawn(function()
		while true do
			for player in activeEffectsByPlayer do
				purgeExpired(player)
			end
			task.wait(PURGE_INTERVAL_SECONDS)
		end
	end)
end

return EffectStackManager

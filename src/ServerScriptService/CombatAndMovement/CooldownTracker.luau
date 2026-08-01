--!strict
--[[
	CooldownTracker
	Shared per-player-per-skill cooldown gate for TargetedSkillManager,
	GlobalSkillStateMachine, and SelfSkillManager — one map instead of three
	near-identical ones. Not an Init()-pattern module: it self-registers its
	PlayerRemoving cleanup at require time, which is safe because Luau
	caches modules (this file's top level only ever runs once no matter how
	many managers require it).
]]

local Players = game:GetService("Players")

local CooldownTracker = {}

local lastCastByPlayer: { [Player]: { [string]: number } } = {}

-- Returns true (and starts the cooldown) if `skillId` is off cooldown for
-- `player`; returns false without side effects if it's still cooling down.
function CooldownTracker.TryConsume(player: Player, skillId: string, cooldownSeconds: number) : boolean
	local playerCooldowns = lastCastByPlayer[player]
	if playerCooldowns == nil then
		playerCooldowns = {}
		lastCastByPlayer[player] = playerCooldowns
	end

	local now = os.clock()
	local lastCastAt = playerCooldowns[skillId]

	if lastCastAt ~= nil and (now - lastCastAt) < cooldownSeconds then
		return false
	end

	playerCooldowns[skillId] = now
	return true
end

Players.PlayerRemoving:Connect(function(player: Player)
	lastCastByPlayer[player] = nil
end)

return CooldownTracker

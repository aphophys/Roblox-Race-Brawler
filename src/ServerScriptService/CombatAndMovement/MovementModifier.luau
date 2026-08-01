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

local function recomputeForPlayer(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
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

	humanoid.WalkSpeed = BASE_WALK_SPEED * EffectStackManager.GetNetStatMultiplier(player, speedStat)
	humanoid.JumpPower = BASE_JUMP_POWER * EffectStackManager.GetNetStatMultiplier(player, "JumpPower")
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
end

return MovementModifier

--!strict
--[[
	CombatInputHandler
	Translates ControlMapper actions into Network remote calls. Client-side
	only fires intent; the server re-validates cooldowns/state/range.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local CombatInputHandler = {}

function CombatInputHandler.RequestTargetedSkill(skillId: string)
	Network.Combat.FireTargetedSkill:FireServer(skillId)
end

function CombatInputHandler.RequestGlobalSkill(skillId: string)
	Network.Combat.FireGlobalSkill:FireServer(skillId)
end

function CombatInputHandler.RequestSelfSkill(skillId: string)
	Network.Combat.FireSelfSkill:FireServer(skillId)
end

function CombatInputHandler.RequestCarryRelease()
	-- TODO: decide pickup vs release based on local carry state, fire the
	-- matching remote (UseTrackItem / DepositFans).
end

function CombatInputHandler.Init()
	-- TODO: wire ControlMapper action callbacks to the Request* functions
	-- above once ControlMapper exposes a signal/callback registry.
end

return CombatInputHandler

--!strict
--[[
	PoseUIController
	Emote wheel shown when a player visits their Fan Box, tied to
	Network.Hub.PerformPose.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local PoseUIController = {}

function PoseUIController.OpenWheel()
	-- TODO: show radial emote-select UI.
end

function PoseUIController.CloseWheel()
	-- TODO: hide radial emote-select UI.
end

function PoseUIController.RequestPose(poseId: string)
	Network.Hub.PerformPose:FireServer(poseId)
end

function PoseUIController.Init()
	-- TODO: connect to AtFanBox PlayerState entry/exit to show/hide the wheel.
end

return PoseUIController

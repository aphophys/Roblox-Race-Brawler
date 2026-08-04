--!strict
--[[
	PoseUIController
	Drives Network.Hub.PerformPose from the POSE button that
	ActionButtonController already shows while a player is AtFanBox.

	## Why there is no wheel

	The original plan here was a radial emote-select UI, and it stayed a TODO
	for as long as the server had no handler. Now that PerformPose does
	something, the cheapest thing that makes the button WORK is to cycle the
	free built-in emotes (Configs.PoseEmotes) on successive presses: one tap
	poses, another tap poses differently, and there is no second UI layer to
	open, aim and dismiss on a touchscreen while standing in a crowd.

	A wheel can be added later without touching the server — RequestPose
	already takes an explicit id, and OpenWheel/CloseWheel are still here as
	the hooks for it.

	## The server does not trust any of this

	The cycle only decides which id to ASK for. TeleportPoseService re-reads
	PoseEmotes, refuses anything not in it, refuses a player who is not
	actually at their Fan Box, and enforces its own anti-spam cooldown — so
	the worst a tampered client can do is request a different free emote than
	the one this cycle would have picked.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PoseEmotes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("PoseEmotes"))

local PoseUIController = {}

local nextPoseIndex = 1

function PoseUIController.OpenWheel()
	-- Intentionally empty: see the docstring. Kept as the hook a radial
	-- selector would fill, rather than deleted, because ControlMapper and
	-- ActionButtonController both document the pose flow in terms of it.
end

function PoseUIController.CloseWheel()
end

-- Fires the remote for a specific pose. Callers that don't care which pose
-- (the POSE button) should use CycleAndRequestPose instead.
function PoseUIController.RequestPose(poseId: string)
	Network.Hub.PerformPose:FireServer(poseId)
end

-- Advances to the next emote in PoseEmotes.Ordered and asks for it. Wraps, so
-- holding a Fan Box session open long enough walks the whole list and starts
-- again.
function PoseUIController.CycleAndRequestPose()
	local emote = PoseEmotes.Ordered[nextPoseIndex]
	if emote == nil then
		return
	end
	nextPoseIndex = (nextPoseIndex % #PoseEmotes.Ordered) + 1
	PoseUIController.RequestPose(emote.Id)
end

function PoseUIController.Init()
end

return PoseUIController

--!strict
--[[
	Network
	Typed wrapper over the RemoteEvent tree declared in default.project.json
	(ReplicatedStorage.RemoteEvents.*). Callers get compile-time checked
	Fire/On signatures instead of raw WaitForChild strings scattered around.

	Usage:
		local Network = require(ReplicatedStorage.Modules.Network)
		Network.Combat.FireTargetedSkill:FireServer(targetPlayer, skillId)
		Network.Combat.FireTargetedSkill.OnServerEvent:Connect(handler)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remoteEventsRoot = ReplicatedStorage:WaitForChild("RemoteEvents")

local function bindFolder(folderName: string) : { [string]: RemoteEvent }
	local folder = remoteEventsRoot:WaitForChild(folderName)
	local bound: { [string]: RemoteEvent } = {}

	for _, child in folder:GetChildren() do
		if child:IsA("RemoteEvent") then
			bound[child.Name] = child
		end
	end

	return bound
end

export type CombatRemotes = {
	FireTargetedSkill: RemoteEvent,
	FireGlobalSkill: RemoteEvent,
	FireSelfSkill: RemoteEvent,
	UseTrackItem: RemoteEvent,
}

export type EconomyRemotes = {
	DepositFans: RemoteEvent,
	PurchaseItem: RemoteEvent,
	EquipSkill: RemoteEvent,
}

export type HubRemotes = {
	TeleportToFanBox: RemoteEvent,
	ReturnToHub: RemoteEvent,
	PerformPose: RemoteEvent,
	EnterTrack: RemoteEvent,
}

export type TrackRemotes = {
	CheckpointPassed: RemoteEvent,
	UpdateRaceStandings: RemoteEvent,
}

local Network = {
	Combat = bindFolder("Combat") :: CombatRemotes,
	Economy = bindFolder("Economy") :: EconomyRemotes,
	Hub = bindFolder("Hub") :: HubRemotes,
	Track = bindFolder("Track") :: TrackRemotes,
}

return Network

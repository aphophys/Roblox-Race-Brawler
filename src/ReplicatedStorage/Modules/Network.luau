--!strict
--[[
	Network
	Typed wrapper over the RemoteEvent/RemoteFunction tree declared in
	default.project.json (ReplicatedStorage.RemoteEvents.*). Callers get
	compile-time checked Fire/Invoke signatures instead of raw WaitForChild
	strings scattered around.

	Usage:
		local Network = require(ReplicatedStorage.Modules.Network)
		Network.Combat.FireTargetedSkill:FireServer(targetPlayer, skillId)
		Network.Combat.FireTargetedSkill.OnServerEvent:Connect(handler)
		Network.Economy.EquipSkill:InvokeServer(slotIndex, skillId) -- RemoteFunction
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remoteEventsRoot = ReplicatedStorage:WaitForChild("RemoteEvents")

-- Binds every RemoteEvent AND RemoteFunction child of a folder — most
-- folders are RemoteEvent-only, but Economy mixes in a couple of
-- RemoteFunctions (GetOwnedSkills/EquipSkill) for request/response calls.
local function bindFolder(folderName: string) : { [string]: RemoteEvent | RemoteFunction }
	local folder = remoteEventsRoot:WaitForChild(folderName)
	local bound: { [string]: RemoteEvent | RemoteFunction } = {}

	for _, child in folder:GetChildren() do
		if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
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
	SkillCastResult: RemoteEvent, -- server -> client only: (skillId: string, cooldownSeconds: number)
}

export type EconomyRemotes = {
	DepositFans: RemoteEvent,
	PickupItem: RemoteEvent,
	DropItem: RemoteEvent,
	PurchaseItem: RemoteEvent,
	GetOwnedSkills: RemoteFunction,
	EquipSkill: RemoteFunction,
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
	ShowNotification: RemoteEvent, -- server -> client only: (text: string, style: string? — "Pop" for a bouncy scale-in on currency gains, nil/anything else for the plain fade the pooled/stacking toast system used originally)
	GrandPrixStateChanged: RemoteEvent, -- server -> client only: (state: string, matches GrandPrixManager.RaceState)
}

local Network = {
	Combat = bindFolder("Combat") :: CombatRemotes,
	Economy = bindFolder("Economy") :: EconomyRemotes,
	Hub = bindFolder("Hub") :: HubRemotes,
	Track = bindFolder("Track") :: TrackRemotes,
}

return Network

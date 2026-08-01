--!strict
--[[
	TeleportPoseService
	Teleports a player to their personal Fan Box pod (assigned by
	FanBoxSlotManager) and back to the Hub (HubGenerator's computed
	center) — real CFrame teleports, not physics-based movement. Also
	updates PlayerState accordingly (AtFanBox / InLobby) since these are
	exactly the state transitions they represent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local HubGenerator = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("HubGenerator"))

local FAN_BOX_STAND_OFFSET = CFrame.new(0, 5, 15) -- in front of / above the pod's CrowdMesh
local HUB_SPAWN_OFFSET = CFrame.new(0, 10, 0)

local TeleportPoseService = {}

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function TeleportPoseService.TeleportToFanBox(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local fanBoxFolder = workspace:FindFirstChild("FanBoxes")
	local pod = fanBoxFolder and fanBoxFolder:FindFirstChild(player.Name)
	local crowdMesh = pod and pod:FindFirstChild("CrowdMesh")
	if crowdMesh == nil then
		return -- no assigned slot (FanBoxSlotManager hasn't run, or all 20 are taken)
	end

	rootPart.CFrame = (crowdMesh :: BasePart).CFrame * FAN_BOX_STAND_OFFSET
	PlayerStateService.SetState(player, PlayerState.AtFanBox)
end

function TeleportPoseService.ReturnToHub(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local hubCFrame = HubGenerator.GetHubCFrame()
	if hubCFrame == nil then
		return
	end

	rootPart.CFrame = hubCFrame * HUB_SPAWN_OFFSET
	PlayerStateService.SetState(player, PlayerState.InLobby)
end

function TeleportPoseService.Init()
	Network.Hub.TeleportToFanBox.OnServerEvent:Connect(function(player: Player)
		TeleportPoseService.TeleportToFanBox(player)
	end)

	Network.Hub.ReturnToHub.OnServerEvent:Connect(function(player: Player)
		TeleportPoseService.ReturnToHub(player)
	end)

	-- PerformPose: TODO — no fan-gain-over-time system exists yet for a
	-- "pose bonus" to multiply, so this remote isn't handled server-side.
end

return TeleportPoseService

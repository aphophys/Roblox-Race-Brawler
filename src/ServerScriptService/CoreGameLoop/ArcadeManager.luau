--!strict
--[[
	ArcadeManager
	The 24/7 "always on" free-run track — join/leave at will, no lives, no
	roster, no relation to GrandPrixManager's scheduled event. This is what
	"enter the track" / "player may choose to leave" (from the Hub) means
	in practice: GrandPrixManager's own Countdown/roster join flow is still
	a TODO stub, so this is currently the only real way onto the track.

	No HUD button fires Network.Hub.EnterTrack yet — the wireframe didn't
	define one. Trigger it manually (or wire a button) to test.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local TeleportPoseService = require(script.Parent.Parent:WaitForChild("LobbyAndHub"):WaitForChild("TeleportPoseService"))

local TRACK_START_CFRAME = CFrame.new(0, 0, 0)
local TRACK_START_STAND_HEIGHT = 5

local ArcadeManager = {}

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function ArcadeManager.EnterTrack(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	rootPart.CFrame = TRACK_START_CFRAME * CFrame.new(0, TrackGeometry.RoadThickness / 2 + TRACK_START_STAND_HEIGHT, 0)
	PlayerStateService.SetState(player, PlayerState.InRace)
end

function ArcadeManager.LeaveTrack(player: Player)
	TeleportPoseService.ReturnToHub(player)
end

function ArcadeManager.Init()
	Network.Hub.EnterTrack.OnServerEvent:Connect(function(player: Player)
		ArcadeManager.EnterTrack(player)
	end)
end

return ArcadeManager

--!strict
--[[
	ArcadeManager
	The 24/7 "always on" free-run track — join/leave at will, no roster, no
	relation to GrandPrixManager's scheduled event. This is what "enter the
	track" / "player may choose to leave" means in practice today:
	GrandPrixManager's own Countdown/roster join flow is still a TODO stub,
	so this is currently the only real way onto the track. Owns the lives
	consequence (TrackBoundaryMonitor calls HandleTrackViolation), since
	it's the thing that actually put the player on the track in the first
	place; checkpoint position itself comes from CheckpointValidator, which
	is the actual source of truth for "where did this player last reach."

	TRACK_START_CFRAME is identity (no rotation), so its LookVector is -Z —
	that's deliberately the same direction TrackPieceBuilder's chain starts
	facing (see its docstring: pieces extend along -LookVector from their
	entry CFrame), so a player spawned here is already facing the correct
	clockwise direction of travel without any extra rotation math.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local CarryItemService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("CarryItemService"))
local TeleportPoseService = require(script.Parent.Parent:WaitForChild("LobbyAndHub"):WaitForChild("TeleportPoseService"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local CheckpointValidator = require(script.Parent.Parent:WaitForChild("Security"):WaitForChild("CheckpointValidator"))

local TRACK_START_CFRAME = CFrame.new(0, 0, 0)
local TRACK_START_STAND_HEIGHT = 5
local MAX_LIVES = 3

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
	CheckpointValidator.ResetPlayer(player)
end

function ArcadeManager.LeaveTrack(player: Player)
	CarryItemService.Drop(player) -- don't let a player keep "holding" something after leaving
	TeleportPoseService.ReturnToHub(player)
end

-- Called by TrackBoundaryMonitor when an InRace player leaves the track
-- boundary (jumped/fell out) or falls below the fall-out height (pit).
-- Costs one life; at 0 lives, refills to MAX_LIVES and sends them back to
-- the Hub (matches the original "0 lives = teleport back to Hub" design);
-- otherwise respawns them at their actual last-passed checkpoint (via
-- CheckpointValidator) and they stay InRace.
function ArcadeManager.HandleTrackViolation(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	profile.Data.Lives -= 1

	if profile.Data.Lives <= 0 then
		profile.Data.Lives = MAX_LIVES
		ProfileManager.SyncAttributes(player)
		ArcadeManager.LeaveTrack(player)
		return
	end

	ProfileManager.SyncAttributes(player)
	CarryItemService.Drop(player) -- losing a life drops whatever was being carried

	local rootPart = getRootPart(player)
	if rootPart ~= nil then
		local checkpointCFrame = CheckpointValidator.GetCheckpointCFrameForPlayer(player)
		rootPart.CFrame = checkpointCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 + TRACK_START_STAND_HEIGHT, 0)
	end
end

function ArcadeManager.Init()
	Network.Hub.EnterTrack.OnServerEvent:Connect(function(player: Player)
		ArcadeManager.EnterTrack(player)
	end)
end

return ArcadeManager

--!strict
--[[
	TeleportPoseService
	Teleports a player to their personal Fan Box pod (assigned by
	FanBoxSlotManager) and back to the Hub (HubGenerator's computed
	center) — real CFrame teleports, not physics-based movement. Also
	updates PlayerState accordingly (AtFanBox / InLobby) since these are
	exactly the state transitions they represent.

	## Posing

	PerformPose is no longer a stub. Pressing POSE at your Fan Box plays a
	free built-in emote (Configs.PoseEmotes), sets the crowd off — cheering,
	confetti poppers and a balloon release — counts toward the Poses quest
	ladder, and tips the player Gold once per ten-minute wall-clock window.

	Three rules the implementation is built around:

	  1. **The emote is best-effort, the reward is not.** Humanoid:PlayEmote
	     is R15-only and can refuse for reasons this game does not control.
	     A refused emote must not cost the player their reward, so the payout
	     and the crowd reaction do not depend on it.
	  2. **The window is claimed before it is paid.** Same ordering as the
	     deposit bonus in CarryItemService, for the same reason.
	  3. **The client picks the emote, the server picks whether it counts.**
	     An unknown pose id is refused outright rather than silently paying
	     for a pose nobody saw.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local PoseEmotes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("PoseEmotes"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local HubGenerator = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("HubGenerator"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("VisualEffectsService"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local QuestService = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("QuestService"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))

-- originCFrame's local +X is "toward the track" (the crowd's own
-- LookVector is aimed along it — see FanBoxCrowdTemplates), and every step
-- of the stand is built into local -X, so +10 clears the frontmost step
-- and stands the player between the crowd and the track. Yaw +90 turns
-- the player's LookVector from -Z (originCFrame's along-track forward) to
-- -X, i.e. back toward the crowd.
local FAN_BOX_STAND_OFFSET = CFrame.new(10, 5, 0) * CFrame.Angles(0, math.rad(90), 0)
local HUB_SPAWN_OFFSET = CFrame.new(0, 10, 0)

-- Rate limit on the POSE button itself, separate from the ten-minute reward
-- window. Without it a held/spammed button would fire the balloon release and
-- the cheer several times a second — the reward would still be paid once, but
-- the stand would fill with hundreds of tweening parts. This is about the
-- world, not the economy, so it is a cheap in-memory clock rather than a
-- profile field.
local POSE_COOLDOWN_SECONDS = 3

local TeleportPoseService = {}

local lastPoseAt: { [Player]: number } = {}

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getFanBoxOrigin(player: Player) : CFrame?
	local fanBoxFolder = workspace:FindFirstChild("FanBoxes")
	local pod = fanBoxFolder and fanBoxFolder:FindFirstChild(player.Name)
	local originCFrame = pod and pod:GetAttribute("OriginCFrame")
	if typeof(originCFrame) ~= "CFrame" then
		return nil
	end
	return originCFrame :: CFrame
end

function TeleportPoseService.TeleportToFanBox(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local originCFrame = getFanBoxOrigin(player)
	if originCFrame == nil then
		return -- no assigned slot (FanBoxSlotManager hasn't run, or all pods are taken)
	end

	rootPart.CFrame = originCFrame * FAN_BOX_STAND_OFFSET
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

-- Best-effort by design — see rule 1 in the module docstring. pcall because
-- PlayEmote THROWS on a rig that cannot play emotes rather than returning
-- false, and a thrown error here would abandon the payout below.
local function tryPlayEmote(player: Player, emoteName: string)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end
	pcall(function()
		(humanoid :: Humanoid):PlayEmote(emoteName)
	end)
end

-- Returns the Gold paid, or 0 when this player has already been tipped in the
-- current window.
local function payPoseReward(player: Player) : number
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return 0
	end

	local window = Utils.GlobalWindowIndex(EconomyRates.PoseRewardIntervalSeconds)
	if profile.Data.LastPoseRewardWindow == window then
		return 0
	end
	profile.Data.LastPoseRewardWindow = window

	local reward = EconomyRates.PoseRewardGold
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		-- "Double Gain Fans and Gold" — this is Gold gain, so it applies, the
		-- same as at every other payout site.
		reward *= EconomyRates.DoubleGainMultiplier
	end

	profile.Data.Gold += reward
	ProfileManager.SyncAttributes(player)
	return reward
end

function TeleportPoseService.PerformPose(player: Player, poseId: unknown)
	-- Posing is a Fan Box activity. Gating on the state rather than on
	-- proximity means it cannot be fired from the track or the Hub by a
	-- client that simply sends the remote itself.
	if PlayerStateService.GetState(player) ~= PlayerState.AtFanBox then
		return
	end

	if typeof(poseId) ~= "string" then
		return
	end
	local emote = PoseEmotes.ById[poseId]
	if emote == nil then
		return
	end

	local now = os.clock()
	local last = lastPoseAt[player]
	if last ~= nil and now - last < POSE_COOLDOWN_SECONDS then
		return
	end
	lastPoseAt[player] = now

	local originCFrame = getFanBoxOrigin(player)
	if originCFrame == nil then
		return
	end

	tryPlayEmote(player, emote.EmoteName)

	-- The crowd reacts whether or not the emote rendered.
	VisualEffectsService.ShowCrowdCelebration(originCFrame)
	local rootPart = getRootPart(player)
	if rootPart ~= nil then
		SoundDirector.PlayAtPart(rootPart, "CrowdCheer")
	end

	QuestService.RecordPose(player)

	local reward = payPoseReward(player)
	if reward > 0 then
		Network.Track.ShowNotification:FireClient(player, `THE CROWD LOVES IT! +{Utils.FormatNumber(reward)} 💰`, "Pop")
		SoundDirector.PlayForPlayer(player, "GoldGain")
	end
end

function TeleportPoseService.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastPoseAt[player] = nil
	end)

	Network.Hub.TeleportToFanBox.OnServerEvent:Connect(function(player: Player)
		TeleportPoseService.TeleportToFanBox(player)
	end)

	Network.Hub.ReturnToHub.OnServerEvent:Connect(function(player: Player)
		TeleportPoseService.ReturnToHub(player)
	end)

	Network.Hub.PerformPose.OnServerEvent:Connect(function(player: Player, poseId: unknown)
		TeleportPoseService.PerformPose(player, poseId)
	end)
end

return TeleportPoseService

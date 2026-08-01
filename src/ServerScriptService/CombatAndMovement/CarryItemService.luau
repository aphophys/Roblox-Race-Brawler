--!strict
--[[
	CarryItemService
	Enforces the "max 1 carried item" rule and drives pickup/drop/deposit/
	release for real — Fan Payloads AND test-Skill pickups share the same
	single carry slot. Proximity is spatial-distance (never .Touched),
	gated on PlayerState == InRace.

	Fan Payload pickup takes a 3-second channel (NearbyInteraction =
	"PickingUp" during the wait, re-validated after — still in range, still
	empty-handed, pickup still available — before granting) and attaches a
	visible carried-payload part (WeldConstraint to the HumanoidRootPart) for
	the "carrying" visual. Skill pickups are fully automatic instead: the
	periodic proximity loop grants one the moment an empty-handed InRace
	player is close enough — no button press — gated by
	SKILL_PICKUP_COOLDOWN_SECONDS after their last cast so pick->cast->
	pick->cast can't be spammed.

	Fan Payloads never simply vanish when dropped: DropAtLocation spawns a
	new persistent, pickup-able marker at the drop point via
	TrackPickupSpawner.SpawnDroppedPickup — used for the voluntary DROP FANS
	button, a track violation, a stun landing, and PlayerRemoving alike, so
	every drop path shares one rule.

	Replicates CarryItemType, CarriedSkillId, and NearbyInteraction
	("Pickup"/"PickingUp"/"Deposit"/"") attributes so the client's action
	button can react without polling the server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CarryItemType = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("CarryItemType"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local PlayerStateService = require(script.Parent:WaitForChild("PlayerStateService"))
local EffectStackManager = require(script.Parent:WaitForChild("EffectStackManager"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local TrackPickupSpawner = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("TrackPickupSpawner"))
local SkillPickupSpawner = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SkillPickupSpawner"))

local TargetedSkillManager = require(script.Parent:WaitForChild("TargetedSkillManager"))
local GlobalSkillStateMachine = require(script.Parent:WaitForChild("GlobalSkillStateMachine"))
local SelfSkillManager = require(script.Parent:WaitForChild("SelfSkillManager"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local ItemData = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("ItemData"))

local PROXIMITY_CHECK_INTERVAL_SECONDS = 0.5
-- Shared with the client (ItemData.FanPickupChannelSeconds) so
-- ActionButtonController can animate a matching progress fill without a
-- remote round-trip.
local FAN_PICKUP_CHANNEL_SECONDS = ItemData.FanPickupChannelSeconds
local SKILL_PICKUP_COOLDOWN_SECONDS = 5
local CARRY_VISUAL_SIZE = Vector3.new(2, 2, 2)
local CARRY_VISUAL_OFFSET = CFrame.new(0, 3, -2)

local CarryItemService = {}

local carriedItems: { [Player]: string } = {}
local carriedSkillId: { [Player]: string? } = {}
local pickupChannelInProgress: { [Player]: boolean } = {}
local carryVisualByPlayer: { [Player]: BasePart? } = {}
-- os.clock() timestamp of each player's last successful skill cast (via
-- ReleaseTrackItem) — a new skill pickup won't auto-grant within
-- SKILL_PICKUP_COOLDOWN_SECONDS of it, so pick->cast->pick->cast can't spam.
local lastSkillCastAt: { [Player]: number } = {}

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function attachCarryVisual(player: Player)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if character == nil or rootPart == nil then
		return
	end

	local visual = Instance.new("Part")
	visual.Name = "CarriedFanPayload"
	visual.Anchored = false
	visual.CanCollide = false
	visual.CanQuery = false
	visual.Massless = true
	visual.Shape = Enum.PartType.Ball
	visual.Material = Enum.Material.Neon
	visual.Color = Color3.fromRGB(255, 215, 0)
	visual.Size = CARRY_VISUAL_SIZE
	visual.CFrame = rootPart.CFrame * CARRY_VISUAL_OFFSET
	visual.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = rootPart
	weld.Part1 = visual
	weld.Parent = visual

	carryVisualByPlayer[player] = visual
end

local function removeCarryVisual(player: Player)
	local visual = carryVisualByPlayer[player]
	if visual ~= nil then
		visual:Destroy()
		carryVisualByPlayer[player] = nil
	end
end

local function setCarriedType(player: Player, itemType: string)
	carriedItems[player] = itemType
	player:SetAttribute("CarryItemType", itemType)
end

function CarryItemService.GetCarriedType(player: Player) : string
	return carriedItems[player] or CarryItemType.None
end

local function grantFanPayload(player: Player, pickupIndex: number)
	TrackPickupSpawner.ConsumePickup(pickupIndex)
	setCarriedType(player, CarryItemType.FanPayload)
	attachCarryVisual(player)
	Network.Track.ShowNotification:FireClient(player, "PICKED UP FANS!")
end

local function startFanPickupChannel(player: Player, pickupIndex: number)
	pickupChannelInProgress[player] = true
	player:SetAttribute("NearbyInteraction", "PickingUp")

	task.spawn(function()
		task.wait(FAN_PICKUP_CHANNEL_SECONDS)
		pickupChannelInProgress[player] = nil

		if player.Parent == nil then
			return
		end
		if PlayerStateService.GetState(player) ~= PlayerState.InRace then
			return
		end
		if CarryItemService.GetCarriedType(player) ~= CarryItemType.None then
			return
		end
		if not TrackPickupSpawner.IsPickupAvailable(pickupIndex) then
			return
		end

		local rootPart = getRootPart(player)
		if rootPart == nil then
			return
		end
		-- Must still be closest to THIS specific pickup (not just any).
		if TrackPickupSpawner.GetNearbyPickup(rootPart.Position) ~= pickupIndex then
			return
		end

		grantFanPayload(player, pickupIndex)
	end)
end

-- Fails silently (returns false) if not InRace, already carrying/mid-
-- channel, or not actually near a Fan Payload pickup — all real server-side
-- checks. Starts a 3-second channel; the actual grant happens later, async.
-- (Skill pickups are no longer requested this way — see
-- tryAutoGrantSkillPickup, which the periodic proximity loop drives.)
function CarryItemService.TryPickup(player: Player) : boolean
	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		return false
	end
	if CarryItemService.GetCarriedType(player) ~= CarryItemType.None then
		return false
	end
	if pickupChannelInProgress[player] then
		return false
	end

	local rootPart = getRootPart(player)
	if rootPart == nil then
		return false
	end

	local fanPickupIndex = TrackPickupSpawner.GetNearbyPickup(rootPart.Position)
	if fanPickupIndex ~= nil then
		startFanPickupChannel(player, fanPickupIndex)
		return true
	end

	return false
end

-- Called every proximity tick for an empty-handed InRace player who isn't
-- mid Fan-Payload channel. Grants a nearby Skill pickup instantly (no
-- button) unless they cast one within the last SKILL_PICKUP_COOLDOWN_SECONDS.
local function tryAutoGrantSkillPickup(player: Player, rootPart: BasePart)
	local lastCast = lastSkillCastAt[player]
	if lastCast ~= nil and (os.clock() - lastCast) < SKILL_PICKUP_COOLDOWN_SECONDS then
		return
	end

	local skillPickupIndex, skillId = SkillPickupSpawner.GetNearbySkillPickup(rootPart.Position)
	if skillPickupIndex == nil or skillId == nil then
		return
	end

	SkillPickupSpawner.ConsumePickup(skillPickupIndex)
	carriedSkillId[player] = skillId
	player:SetAttribute("CarriedSkillId", skillId)
	setCarriedType(player, CarryItemType.TrackSkill)
end

-- Drops whatever the player is carrying. Fan Payloads never simply vanish —
-- dropping one (voluntarily, via a track violation, a stun, or leaving the
-- game) spawns a new persistent, pickup-able marker at `position` (defaults
-- to the player's current position) so another racer can grab it. Skill
-- carries still just clear; skills were never meant to litter the track.
function CarryItemService.DropAtLocation(player: Player, position: Vector3?)
	local carried = CarryItemService.GetCarriedType(player)
	if carried == CarryItemType.None then
		return
	end

	if carried == CarryItemType.FanPayload then
		local rootPart = getRootPart(player)
		local dropPosition = position or (rootPart and rootPart.Position)
		if dropPosition ~= nil then
			TrackPickupSpawner.SpawnDroppedPickup(dropPosition)
		end
		removeCarryVisual(player)
		Network.Track.ShowNotification:FireClient(player, "DROPPED FANS!")
	end

	carriedSkillId[player] = nil
	player:SetAttribute("CarriedSkillId", "")
	setCarriedType(player, CarryItemType.None)
end

-- Voluntary drop (DROP FANS button / "E") — same persistence rule as any
-- other drop; see DropAtLocation.
function CarryItemService.Drop(player: Player)
	CarryItemService.DropAtLocation(player)
end

function CarryItemService.TryDeposit(player: Player) : boolean
	if CarryItemService.GetCarriedType(player) ~= CarryItemType.FanPayload then
		return false
	end

	local rootPart = getRootPart(player)
	if rootPart == nil or not TrackPickupSpawner.IsNearDepositZone(rootPart.Position) then
		return false
	end

	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return false
	end

	local fanValue = TrackPickupSpawner.GetFanPayloadValue()
	profile.Data.TotalFans += fanValue
	ProfileManager.SyncAttributes(player)
	Network.Track.ShowNotification:FireClient(player, `+{Utils.FormatNumber(fanValue)} 🌟 FANS!`, "Pop")
	removeCarryVisual(player)
	setCarriedType(player, CarryItemType.None)
	return true
end

-- Actually casts the carried test-skill now (previously a TODO stub with
-- nothing to release, since no TrackSkill pickups existed). Dispatches to
-- whichever of the 3 skill managers owns that skill's CastType, at Level 1
-- (a test cast, not tied to the player's own profile-owned skill level).
function CarryItemService.ReleaseTrackItem(player: Player)
	if CarryItemService.GetCarriedType(player) ~= CarryItemType.TrackSkill then
		return
	end

	local skillId = carriedSkillId[player]
	carriedSkillId[player] = nil
	player:SetAttribute("CarriedSkillId", "")
	setCarriedType(player, CarryItemType.None)

	if skillId == nil then
		return
	end

	local skillDefinition = SkillTrees[skillId]
	if skillDefinition == nil then
		return
	end

	lastSkillCastAt[player] = os.clock()

	if skillDefinition.CastType == "Target" then
		TargetedSkillManager.CastSkillDirect(player, skillId)
	elseif skillDefinition.CastType == "Global" then
		GlobalSkillStateMachine.CastSkillDirect(player, skillId)
	elseif skillDefinition.CastType == "Self" then
		SelfSkillManager.CastSkillDirect(player, skillId)
	end
end

local function updateNearbyInteraction(player: Player)
	if pickupChannelInProgress[player] then
		return -- leave "PickingUp" alone; the channel coroutine owns this attribute until it resolves
	end

	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		player:SetAttribute("NearbyInteraction", "")
		return
	end

	local rootPart = getRootPart(player)
	if rootPart == nil then
		player:SetAttribute("NearbyInteraction", "")
		return
	end

	local carried = CarryItemService.GetCarriedType(player)
	if carried == CarryItemType.None then
		tryAutoGrantSkillPickup(player, rootPart)
		-- Re-check: the auto-grant above may have just filled the slot.
		if CarryItemService.GetCarriedType(player) ~= CarryItemType.None then
			return
		end
		local nearFan = TrackPickupSpawner.GetNearbyPickup(rootPart.Position) ~= nil
		player:SetAttribute("NearbyInteraction", if nearFan then "Pickup" else "")
	elseif carried == CarryItemType.FanPayload then
		if EffectStackManager.IsStunned(player) then
			CarryItemService.DropAtLocation(player, rootPart.Position)
			player:SetAttribute("NearbyInteraction", "")
			return
		end
		local nearDeposit = TrackPickupSpawner.IsNearDepositZone(rootPart.Position)
		player:SetAttribute("NearbyInteraction", if nearDeposit then "Deposit" else "")
	else
		player:SetAttribute("NearbyInteraction", "")
	end
end

function CarryItemService.Init()
	Players.PlayerAdded:Connect(function(player: Player)
		player:SetAttribute("CarryItemType", CarryItemType.None)
		player:SetAttribute("CarriedSkillId", "")
		player:SetAttribute("NearbyInteraction", "")
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		-- Character/rootPart are usually still around at this point, so a
		-- carried Fan Payload can still be dropped in place for others.
		CarryItemService.DropAtLocation(player)

		carriedItems[player] = nil
		carriedSkillId[player] = nil
		pickupChannelInProgress[player] = nil
		carryVisualByPlayer[player] = nil
		lastSkillCastAt[player] = nil
	end)

	Network.Economy.PickupItem.OnServerEvent:Connect(function(player: Player)
		CarryItemService.TryPickup(player)
	end)
	Network.Economy.DropItem.OnServerEvent:Connect(function(player: Player)
		CarryItemService.Drop(player)
	end)
	Network.Economy.DepositFans.OnServerEvent:Connect(function(player: Player)
		CarryItemService.TryDeposit(player)
	end)
	Network.Combat.UseTrackItem.OnServerEvent:Connect(function(player: Player)
		CarryItemService.ReleaseTrackItem(player)
	end)

	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				updateNearbyInteraction(player)
			end
			task.wait(PROXIMITY_CHECK_INTERVAL_SECONDS)
		end
	end)
end

return CarryItemService

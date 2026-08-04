--!strict
--[[
	ActionButtonController
	The single bottom-center action button — deliberately one button with
	one active meaning at a time, driven by state (PlayerState +
	CarryItemType + NearbyInteraction attributes), not several buttons:

	AtFanBox            -> "POSE"
	InLobby              -> "JOIN RACE"
	InRace, carrying nothing, near a fan pickup   -> "PICK UP" (fans only —
	                                                  skill pickups are automatic,
	                                                  no button press needed)
	InRace, carrying nothing, 3-second channel in progress -> "PICKING UP..." (not clickable)
	InRace, carrying nothing, not near one    -> hidden
	InRace, carrying FanPayload, near deposit zone -> "DEPOSIT FANS"
	InRace, carrying FanPayload, elsewhere          -> "DROP FANS"
	InRace, carrying TrackSkill                     -> the carried skill's
	                                                    DisplayName (falls back
	                                                    to "RELEASE SPELL" only
	                                                    if the id can't be
	                                                    resolved)

	TriggerCurrentAction() is exposed so both this button's click AND the
	"E" keybind (CombatInputHandler.RequestCarryRelease) fire the exact
	same logic — there is only one active action at a time, by design.

	During the "PickingUp" 3-second channel, a PickupFill bar (bottom edge
	of the button, same pooled "HP bar" pattern CooldownDisplayController
	uses for skill cooldowns) fills from empty to full — see
	updatePickupFill.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local CarryItemType = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("CarryItemType"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local ItemData = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("ItemData"))

local PoseUIController = require(script.Parent:WaitForChild("PoseUIController"))

local localPlayer = Players.LocalPlayer

type ButtonMode = "Pose" | "JoinRace" | "PickUp" | "PickingUp" | "Deposit" | "Drop" | "ReleaseSpell" | "Hidden"

local PICKUP_FILL_HEIGHT_SCALE = 0.18

local ActionButtonController = {}

local activePickupTween: Tween? = nil

local function getActionButton() : (Frame?, TextButton?)
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local centerAction = mainHud and mainHud:FindFirstChild("CenterAction")
	if centerAction == nil then
		return nil, nil
	end
	local actionButton = centerAction:FindFirstChild("ActionButton")
	return centerAction :: Frame, actionButton :: TextButton?
end

local function resolveMode() : ButtonMode
	local playerState = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby

	if playerState == PlayerState.AtFanBox then
		return "Pose"
	elseif playerState == PlayerState.InLobby then
		return "JoinRace"
	end

	-- InRace.
	local carried = (localPlayer:GetAttribute("CarryItemType") :: string?) or CarryItemType.None
	local nearby = (localPlayer:GetAttribute("NearbyInteraction") :: string?) or ""

	if carried == CarryItemType.None then
		if nearby == "Pickup" then
			return "PickUp"
		elseif nearby == "PickingUp" then
			return "PickingUp"
		end
		return "Hidden"
	elseif carried == CarryItemType.FanPayload then
		return if nearby == "Deposit" then "Deposit" else "Drop"
	elseif carried == CarryItemType.TrackSkill then
		return "ReleaseSpell"
	end

	return "Hidden"
end

local MODE_LABELS: { [ButtonMode]: string } = {
	Pose = "POSE",
	-- Free-run arcade entry, and only that. Grand Prix enrolment is a
	-- separate, explicitly toggleable button in LeftMenuBar
	-- (GrandPrixJoinController) — briefly merged into this one, then split
	-- back out because "put me on the track now" and "sign me up for the
	-- race in 20 minutes" are different intentions, and a momentary button
	-- has no way to express opting back OUT of the second one.
	JoinRace = "JOIN RACE",
	PickUp = "PICK UP",
	PickingUp = "PICKING UP...",
	Deposit = "DEPOSIT FANS",
	Drop = "DROP FANS",
	ReleaseSpell = "RELEASE SPELL",
	Hidden = "",
}

-- ReleaseSpell shows the carried skill's own name — falls back to this if
-- the carried skill's id can't be resolved.
local function resolveReleaseSpellLabel() : string
	local carriedSkillId = localPlayer:GetAttribute("CarriedSkillId") :: string?
	if carriedSkillId == nil or carriedSkillId == "" then
		return MODE_LABELS.ReleaseSpell
	end

	local definition = SkillTrees[carriedSkillId]
	if definition == nil then
		return MODE_LABELS.ReleaseSpell
	end

	return definition.DisplayName
end

-- Only the ReleaseSpell mode (carrying a picked-up track skill) shows an
-- icon on the button's left side, via the dedicated Icon/SpellLabel pair —
-- every other mode (including carrying a Fan Payload) keeps using the
-- button's own centered Text untouched, since a fan payload has no
-- per-item icon to show.
local function refreshIconAndSpellLabel(actionButton: TextButton, mode: ButtonMode)
	local icon = actionButton:FindFirstChild("Icon") :: ImageLabel?
	local spellLabel = actionButton:FindFirstChild("SpellLabel") :: TextLabel?
	if icon == nil or spellLabel == nil then
		return
	end

	local iconAssetId = ""
	if mode == "ReleaseSpell" then
		local carriedSkillId = localPlayer:GetAttribute("CarriedSkillId") :: string?
		local definition = carriedSkillId ~= nil and carriedSkillId ~= "" and SkillTrees[carriedSkillId] or nil
		iconAssetId = definition ~= nil and definition.IconAssetId or ""
	end

	if iconAssetId ~= "" then
		icon.Image = iconAssetId
		icon.Visible = true
		spellLabel.Text = resolveReleaseSpellLabel()
		spellLabel.Visible = true
		actionButton.TextTransparency = 1
	else
		icon.Visible = false
		spellLabel.Visible = false
		actionButton.TextTransparency = 0
	end
end

local function refresh()
	local centerAction, actionButton = getActionButton()
	if centerAction == nil or actionButton == nil then
		return
	end

	local mode = resolveMode()
	centerAction.Visible = mode ~= "Hidden"
	actionButton.Text = if mode == "ReleaseSpell" then resolveReleaseSpellLabel() else MODE_LABELS[mode]
	refreshIconAndSpellLabel(actionButton, mode)
end

-- Fills PickupFill (a thin bar along the button's bottom edge, same "HP
-- bar" pattern as the skill cooldown fill) from empty to full over the
-- 3-second Fan Payload pickup channel, so picking up a fan gets the same
-- visual progress feedback casting a skill does. Driven purely by
-- NearbyInteraction flipping to/from "PickingUp" — ItemData.
-- FanPickupChannelSeconds is shared with the server so this always matches
-- CarryItemService's actual channel duration without a remote round-trip.
local function updatePickupFill()
	local _, actionButton = getActionButton()
	local fill = actionButton and actionButton:FindFirstChild("PickupFill")
	if fill == nil then
		return
	end
	local fillFrame = fill :: Frame

	if activePickupTween ~= nil then
		activePickupTween:Cancel()
		activePickupTween = nil
	end

	local nearby = (localPlayer:GetAttribute("NearbyInteraction") :: string?) or ""
	if nearby ~= "PickingUp" then
		fillFrame.Visible = false
		fillFrame.Size = UDim2.new(0, 0, PICKUP_FILL_HEIGHT_SCALE, 0)
		return
	end

	fillFrame.Size = UDim2.new(0, 0, PICKUP_FILL_HEIGHT_SCALE, 0)
	fillFrame.Visible = true

	local tween = TweenService:Create(
		fillFrame,
		TweenInfo.new(ItemData.FanPickupChannelSeconds, Enum.EasingStyle.Linear),
		{ Size = UDim2.new(1, 0, PICKUP_FILL_HEIGHT_SCALE, 0) }
	)
	activePickupTween = tween
	tween.Completed:Connect(function()
		fillFrame.Visible = false
	end)
	tween:Play()
end

-- Shared by the button click and the "E" keybind.
function ActionButtonController.TriggerCurrentAction()
	local mode = resolveMode()

	if mode == "PickingUp" or mode == "Hidden" then
		return
	elseif mode == "Pose" then
		-- Cycles the free built-in emotes rather than always waving, so
		-- pressing POSE twice does two different things. See PoseUIController.
		PoseUIController.CycleAndRequestPose()
	elseif mode == "JoinRace" then
		Network.Hub.EnterTrack:FireServer()
	elseif mode == "PickUp" then
		Network.Economy.PickupItem:FireServer()
	elseif mode == "Deposit" then
		Network.Economy.DepositFans:FireServer()
	elseif mode == "Drop" then
		Network.Economy.DropItem:FireServer()
	elseif mode == "ReleaseSpell" then
		Network.Combat.UseTrackItem:FireServer()
	end
end

function ActionButtonController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local centerAction = mainHud:WaitForChild("CenterAction")
	local actionButton = centerAction:WaitForChild("ActionButton") :: TextButton

	actionButton.Activated:Connect(ActionButtonController.TriggerCurrentAction)

	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("CarryItemType"):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("NearbyInteraction"):Connect(refresh)
	localPlayer:GetAttributeChangedSignal("NearbyInteraction"):Connect(updatePickupFill)
	localPlayer:GetAttributeChangedSignal("CarriedSkillId"):Connect(refresh)
	refresh()
	updatePickupFill()
end

return ActionButtonController

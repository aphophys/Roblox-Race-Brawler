--!strict
--[[
	ServerScriptService bootstrap.
	This is a plain named Script — a child of ServerScriptService, NOT the
	init.server.luau folder-becomes-the-service trick. That trick doesn't
	work here: ServerScriptService is a real built-in Roblox service and
	its ClassName can't be overridden to "Script", so Rojo silently failed
	to make anything run (confirmed via `rojo build` -> .rbxlx inspection:
	it was emitting a raw <Item class="Script" name="ServerScriptService">
	that Studio can't apply to the actual service). Everything below is a
	sibling Folder of this script, not a child of it — hence
	`script.Parent.X`, not `script.X`.
]]

local ProfileManager = require(script.Parent.EconomyAndData.ProfileManager)
local LeaderboardManager = require(script.Parent.EconomyAndData.LeaderboardManager)

local ProcessReceiptManager = require(script.Parent.Monetization.ProcessReceiptManager)

local PlayerStateService = require(script.Parent.CombatAndMovement.PlayerStateService)
local EffectStackManager = require(script.Parent.CombatAndMovement.EffectStackManager)
local MovementModifier = require(script.Parent.CombatAndMovement.MovementModifier)
local CarryItemService = require(script.Parent.CombatAndMovement.CarryItemService)
local TargetedSkillManager = require(script.Parent.CombatAndMovement.TargetedSkillManager)
local GlobalSkillStateMachine = require(script.Parent.CombatAndMovement.GlobalSkillStateMachine)
local SelfSkillManager = require(script.Parent.CombatAndMovement.SelfSkillManager)

local FanBoxGenerator = require(script.Parent.LobbyAndHub.FanBoxGenerator)
local FanBoxSlotManager = require(script.Parent.LobbyAndHub.FanBoxSlotManager)
local HubShoppingManager = require(script.Parent.LobbyAndHub.HubShoppingManager)
local TeleportPoseService = require(script.Parent.LobbyAndHub.TeleportPoseService)

local AntiCheat = require(script.Parent.Security.AntiCheat)
local CheckpointValidator = require(script.Parent.Security.CheckpointValidator)

local TrackGenerator = require(script.Parent.CoreGameLoop.TrackGenerator)
local HubGenerator = require(script.Parent.CoreGameLoop.HubGenerator)
local ArcadeManager = require(script.Parent.CoreGameLoop.ArcadeManager)
local GrandPrixManager = require(script.Parent.CoreGameLoop.GrandPrixManager)

-- Data first: everything else assumes profiles can be loaded.
ProfileManager.Init()
ProcessReceiptManager.Init()
LeaderboardManager.Init()

-- World geometry next, ahead of anything player-facing: HubGenerator places
-- the SpawnLocation, so it needs to exist before any player's character
-- could possibly spawn. FanBoxGenerator must build pods before
-- FanBoxSlotManager (further below) can assign any.
TrackGenerator.Init()
HubGenerator.Init()
FanBoxGenerator.Init()

-- Player/combat state next: track + hub logic reads from these.
PlayerStateService.Init()
EffectStackManager.Init()
MovementModifier.Init()
CarryItemService.Init()
TargetedSkillManager.Init()
GlobalSkillStateMachine.Init()
SelfSkillManager.Init()

-- Hub.
FanBoxSlotManager.Init()
HubShoppingManager.Init()
TeleportPoseService.Init()

-- Security.
AntiCheat.Init()
CheckpointValidator.Init()

-- Core loop remainder: race scheduling / free-run track.
ArcadeManager.Init()
GrandPrixManager.Init()

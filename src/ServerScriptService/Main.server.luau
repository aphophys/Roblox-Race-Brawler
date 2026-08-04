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

local Players = game:GetService("Players")

-- Held off only until Track+Hub generation finishes (see the release point
-- below, right after HubGenerator.Init()) — NOT the full Init() sequence.
-- First attempt gated on everything (including FanBoxGenerator, which at
-- the time still did a UnionAsync per pod), and that backfired: a
-- player's PlayerGui only receives its first StarterGui clone (MainHUD,
-- ResetOnSpawn or not) once their character has spawned at least once, so
-- holding character spawn hostage to the SLOWEST systems left
-- ControlMapper's `PlayerGui:WaitForChild("MainHUD")` hanging long enough
-- to trip Roblox's "Infinite yield possible" warning. Track+Hub existing
-- (so there's an actual floor and a real SpawnLocation) is the only part
-- that's genuinely unsafe to spawn before; FanBoxes/pickups/hazards
-- finishing a moment later while the player is still standing at the Hub
-- reading the UI is fine.
Players.CharacterAutoLoads = false

local ProfileManager = require(script.Parent.EconomyAndData.ProfileManager)
local LeaderboardManager = require(script.Parent.EconomyAndData.LeaderboardManager)
local QuestService = require(script.Parent.EconomyAndData.QuestService)
local FanIncomeService = require(script.Parent.EconomyAndData.FanIncomeService)

local ProcessReceiptManager = require(script.Parent.Monetization.ProcessReceiptManager)
local MonetizationService = require(script.Parent.Monetization.MonetizationService)
local DailyPassRewardService = require(script.Parent.Monetization.DailyPassRewardService)

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
local LoadoutService = require(script.Parent.LobbyAndHub.LoadoutService)

local AntiCheat = require(script.Parent.Security.AntiCheat)
local CheckpointValidator = require(script.Parent.Security.CheckpointValidator)
local TrackBoundaryMonitor = require(script.Parent.Security.TrackBoundaryMonitor)

local TrackGenerator = require(script.Parent.CoreGameLoop.TrackGenerator)
local HubGenerator = require(script.Parent.CoreGameLoop.HubGenerator)
local HubAmenitiesBuilder = require(script.Parent.CoreGameLoop.HubAmenitiesBuilder)
local LeaderboardBuilder = require(script.Parent.CoreGameLoop.LeaderboardBuilder)
local StadiumBlimp = require(script.Parent.CoreGameLoop.StadiumBlimp)
local TrackPickupSpawner = require(script.Parent.CoreGameLoop.TrackPickupSpawner)
local SkillPickupSpawner = require(script.Parent.CoreGameLoop.SkillPickupSpawner)
local ZoneHazardMonitor = require(script.Parent.CoreGameLoop.ZoneHazardMonitor)
local DesertWindService = require(script.Parent.CoreGameLoop.DesertWindService)
local ArcadeManager = require(script.Parent.CoreGameLoop.ArcadeManager)
local GrandPrixManager = require(script.Parent.CoreGameLoop.GrandPrixManager)
local SegmentAnnouncer = require(script.Parent.CoreGameLoop.SegmentAnnouncer)
local PracticeDummyService = require(script.Parent.CoreGameLoop.PracticeDummyService)

-- Data first: everything else assumes profiles can be loaded.
ProfileManager.Init()
ProcessReceiptManager.Init()
-- Before anything that checks pass ownership: this is what hooks the purchase
-- event that clears a stale "does not own" cache entry.
MonetizationService.Init()
-- After ProfileManager, same reason QuestService is: it polls GetProfile for
-- each joining player before it can pay them.
DailyPassRewardService.Init()
LeaderboardManager.Init()
-- After ProfileManager: QuestService polls GetProfile for each joining player
-- and would otherwise race the very first join in a fresh server.
QuestService.Init()
FanIncomeService.Init()

-- World geometry next, ahead of anything player-facing: HubGenerator places
-- the SpawnLocation, so it needs to exist before any player's character
-- could possibly spawn.
TrackGenerator.Init()
HubGenerator.Init()
-- All three depend on HubGenerator.GetHubCFrame(), which is only populated
-- once GenerateHub has run — so they must come after it, not merely near it.
HubAmenitiesBuilder.Init()
LeaderboardBuilder.Init()
StadiumBlimp.Init()

-- Track+Hub exist now — safe for characters to spawn, and (just as
-- important in practice) this is what unblocks PlayerGui's first StarterGui
-- clone, so client controllers waiting on MainHUD stop hanging. Covers
-- both players who were already connected while this script was still
-- running (held back by CharacterAutoLoads = false above) and everyone who
-- joins from here on (CharacterAutoLoads stays off permanently;
-- LoadCharacter is just called explicitly on every join from now on).
for _, player in Players:GetPlayers() do
	player:LoadCharacter()
end

Players.PlayerAdded:Connect(function(player: Player)
	player:LoadCharacter()
end)

-- Everything else keeps building in the background — a player standing at
-- the Hub reading the UI for even a couple of seconds while these finish
-- is normal, not a race with anything they could actually reach yet.
TrackPickupSpawner.Init()
SkillPickupSpawner.Init()
ZoneHazardMonitor.Init()
DesertWindService.Init()
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
LoadoutService.Init()

-- Security.
AntiCheat.Init()
CheckpointValidator.Init()
TrackBoundaryMonitor.Init()

-- Core loop remainder: race scheduling / free-run track.
ArcadeManager.Init()
GrandPrixManager.Init()
-- After CheckpointValidator.Init() above (it registers a handler on it).
SegmentAnnouncer.Init()
-- Needs the Track to exist (it follows the checkpoint ring as waypoints).
PracticeDummyService.Init()

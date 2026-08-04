--!strict
--[[
	StarterPlayerScripts bootstrap.
	Plain named child LocalScript, not the init.client.luau folder-becomes-
	the-container trick — same reasoning as ServerScriptService's Main.
	server.luau: StarterPlayerScripts is a fixed Roblox object with a
	required ClassName that can't be overridden, so that trick silently
	produced nothing runnable. Controllers/UI_And_Visuals are siblings of
	this script, not children of it — hence `script.Parent.X`.
]]

local ControlMapper = require(script.Parent.Controllers.ControlMapper)
local PlayerStateController = require(script.Parent.Controllers.PlayerStateController)
local CombatInputHandler = require(script.Parent.Controllers.CombatInputHandler)
local ControlScrambleController = require(script.Parent.Controllers.ControlScrambleController)
local MobileJumpButton = require(script.Parent.Controllers.MobileJumpButton)

local BubblyTextEngine = require(script.Parent.UI_And_Visuals.BubblyTextEngine)
local LiveRaceHUD = require(script.Parent.UI_And_Visuals.LiveRaceHUD)
local CurrencyDisplay = require(script.Parent.UI_And_Visuals.CurrencyDisplay)
local ActionButtonController = require(script.Parent.UI_And_Visuals.ActionButtonController)
local ShopUIController = require(script.Parent.UI_And_Visuals.ShopUIController)
local MainMenuController = require(script.Parent.UI_And_Visuals.MainMenuController)
local SkillShopController = require(script.Parent.UI_And_Visuals.SkillShopController)
local PoseUIController = require(script.Parent.UI_And_Visuals.PoseUIController)
local LocationToggleController = require(script.Parent.UI_And_Visuals.LocationToggleController)
local SkillLoadoutController = require(script.Parent.UI_And_Visuals.SkillLoadoutController)
local CooldownDisplayController = require(script.Parent.UI_And_Visuals.CooldownDisplayController)
local NotificationController = require(script.Parent.UI_And_Visuals.NotificationController)
local EliminationPromptController = require(script.Parent.UI_And_Visuals.EliminationPromptController)
local BlindEffectController = require(script.Parent.UI_And_Visuals.BlindEffectController)
local GrandPrixJoinController = require(script.Parent.UI_And_Visuals.GrandPrixJoinController)
local SoundController = require(script.Parent.UI_And_Visuals.SoundController)
local MusicController = require(script.Parent.UI_And_Visuals.MusicController)
local QuestUIController = require(script.Parent.UI_And_Visuals.QuestUIController)
local CapsuleButtonFX = require(script.Parent.UI_And_Visuals.CapsuleButtonFX)
local CountdownCameraController = require(script.Parent.UI_And_Visuals.CountdownCameraController)
local TutorialController = require(script.Parent.UI_And_Visuals.TutorialController)
local ResponsiveLayoutController = require(script.Parent.UI_And_Visuals.ResponsiveLayoutController)
local PanelExclusivityController = require(script.Parent.UI_And_Visuals.PanelExclusivityController)
local ActiveEffectsDisplay = require(script.Parent.UI_And_Visuals.ActiveEffectsDisplay)

-- State/input first: UI reacts to state, not the other way around.
PlayerStateController.Init()
ControlMapper.Init()
CombatInputHandler.Init()
ControlScrambleController.Init()

-- Visuals/UI.
LiveRaceHUD.Init()
CurrencyDisplay.Init()
ActionButtonController.Init()
ShopUIController.Init()
MainMenuController.Init()
SkillShopController.Init()
PoseUIController.Init()
LocationToggleController.Init()
SkillLoadoutController.Init()
CooldownDisplayController.Init()
NotificationController.Init()
EliminationPromptController.Init()
BlindEffectController.Init()
GrandPrixJoinController.Init()
SoundController.Init()
MusicController.Init()
QuestUIController.Init()
CountdownCameraController.Init()
-- Before the tutorial and the button FX: both read geometry off MainHUD, and
-- this is what decides that geometry on a phone.
-- After every panel-owning controller above has run its Init (each of them
-- WaitForChilds its own panel), so all five panels exist to be watched.
PanelExclusivityController.Init()
-- Anchors its chip stack to the ADD FANS button's live rect, so it does not
-- care whether it runs before or after the responsive layout moves things.
ActiveEffectsDisplay.Init()
ResponsiveLayoutController.Init()
-- Immediately after ResponsiveLayoutController: it asks that module both
-- whether this is a phone and where the platform's jump button belongs, so the
-- layout verdict has to exist first.
MobileJumpButton.Init()
-- Before CapsuleButtonFX below, but its card is built asynchronously after the
-- profile loads, so its two buttons are picked up by that module's
-- DescendantAdded watcher rather than by the initial walk.
TutorialController.Init()

-- LAST on purpose: its Init() walks MainHUD and decorates every GuiButton it
-- finds, so anything a controller above cloned during its own Init() is
-- already parented and gets picked up by the walk. Everything cloned after
-- this point is caught by its DescendantAdded watcher instead.
CapsuleButtonFX.Init()

-- BubblyTextEngine exposes stateless helpers only (PlayPop/ShowAnnouncement) — no Init().

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

local BubblyTextEngine = require(script.Parent.UI_And_Visuals.BubblyTextEngine)
local FansBoxRenderer = require(script.Parent.UI_And_Visuals.FansBoxRenderer)
local LiveRaceHUD = require(script.Parent.UI_And_Visuals.LiveRaceHUD)
local CurrencyDisplay = require(script.Parent.UI_And_Visuals.CurrencyDisplay)
local ActionButtonController = require(script.Parent.UI_And_Visuals.ActionButtonController)
local ShopUIController = require(script.Parent.UI_And_Visuals.ShopUIController)
local PoseUIController = require(script.Parent.UI_And_Visuals.PoseUIController)

-- State/input first: UI reacts to state, not the other way around.
PlayerStateController.Init()
ControlMapper.Init()
CombatInputHandler.Init()

-- Visuals/UI.
FansBoxRenderer.Init()
LiveRaceHUD.Init()
CurrencyDisplay.Init()
ActionButtonController.Init()
ShopUIController.Init()
PoseUIController.Init()

-- BubblyTextEngine exposes stateless helpers only (PlayPop/ShowAnnouncement) — no Init().

--!strict
--[[
	PanelExclusivityController
	Enforces one open pop-out panel at a time. Opening any menu panel closes
	whichever one was already open.

	Five controllers each own a panel and each set `panel.Visible = true` on
	their own button, with no knowledge of the other four — so clicking Quests
	and then Skills left both stacked on screen, overlapping.

	## Why this watches Visible instead of editing the five controllers

	The rule is "only one of these is on screen", which is a statement about the
	panels, not about any one controller. Implemented as a listener on each
	panel's Visible property, it is one file that needs no cooperation from the
	controllers, and — the part that matters for a pre-release change — it
	cannot introduce a dead click, because it never touches the controllers'
	own open/close paths. A future panel gets the behaviour by being added to
	the list below, not by remembering to call into a manager.

	This is safe against the controllers' own state because none of them toggles
	off a stale private flag: QuestUIController derives its toggle from
	`panel.Visible` (so an external close is already handled correctly), while
	MainMenuController, ShopUIController, SkillShopController and
	SkillLoadoutController bind Open and Close to separate buttons rather than
	toggling. Verified before writing this — a controller that toggled off a
	private boolean WOULD desync into a dead first click, which is exactly the
	bug a change like this is prone to.

	No recursion guard is needed: hiding the others sets Visible = false, and the
	handler only acts when a panel becomes VISIBLE.
]]

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

-- Menu panels the player opens deliberately. Mutually exclusive with each
-- other.
local EXCLUSIVE_PANELS = {
	"MainMenuPanel",
	"RobuxShopPanel",
	"SkillShopPanel",
	"SkillSelectPanel",
	"QuestPanel",
}

-- Panels that close the menus when they appear but are never closed BY one.
-- EliminationPanel is a timed prompt the game forces on the player rather than
-- something they opened; a menu must not be able to sit on top of it, and it
-- must not be dismissed by one either — its own timeout owns when it goes away.
--
-- Deliberately NOT listed anywhere here: StandingsPanel, which is a live race
-- readout rather than a pop-out, and is expected to share the screen.
local PREEMPTIVE_PANELS = {
	"EliminationPanel",
}

local PanelExclusivityController = {}

local watchedPanels: { [string]: GuiObject } = {}
local preemptivePanels: { [string]: GuiObject } = {}

local function closeOthers(exceptName: string)
	for name, panel in watchedPanels do
		if name ~= exceptName and panel.Visible then
			panel.Visible = false
		end
	end
end

-- True while a forced prompt owns the screen.
local function preemptivePanelOpen() : GuiObject?
	for _, panel in preemptivePanels do
		if panel.Visible then
			return panel
		end
	end
	return nil
end

local function watch(mainHud: ScreenGui, panelName: string, isExclusive: boolean)
	local panel = mainHud:FindFirstChild(panelName) :: GuiObject?
	if panel == nil then
		-- Not fatal: a panel can legitimately be absent from a build. Being
		-- silent here is deliberate — this module is a UI nicety and must not
		-- be able to stop the client booting over a missing optional panel.
		return
	end

	if isExclusive then
		watchedPanels[panelName] = panel
	else
		preemptivePanels[panelName] = panel
	end

	panel:GetPropertyChangedSignal("Visible"):Connect(function()
		if not panel.Visible then
			return
		end
		-- A forced prompt outranks a menu in BOTH directions. Letting a menu
		-- merely sit on top of the elimination prompt would recreate the exact
		-- overlap this module exists to remove, and on the one panel where it
		-- costs something real: that prompt is a ten-second revive choice, so
		-- covering it can lose the player a life. Closing the prompt instead
		-- would be worse still, so the menu is what gives way.
		if isExclusive and preemptivePanelOpen() ~= nil then
			panel.Visible = false
			return
		end
		closeOthers(panelName)
	end)
end

function PanelExclusivityController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD") :: ScreenGui

	for _, panelName in EXCLUSIVE_PANELS do
		watch(mainHud, panelName, true)
	end
	for _, panelName in PREEMPTIVE_PANELS do
		watch(mainHud, panelName, false)
	end

	-- A panel left visible in the declared layout would otherwise sit there
	-- until something else opened. Close everything at startup so the HUD
	-- always begins in a known state.
	closeOthers("")
end

-- Test surface: which watched panels are open right now.
function PanelExclusivityController.GetOpenPanels() : { string }
	local open: { string } = {}
	for name, panel in watchedPanels do
		if panel.Visible then
			table.insert(open, name)
		end
	end
	table.sort(open)
	return open
end

return PanelExclusivityController

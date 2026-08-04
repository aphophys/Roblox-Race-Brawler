--!strict
--[[
	ResponsiveLayoutController
	Two layouts from one HUD. `default.project.json` declares the DESKTOP
	layout and is the single source of truth for it; this module rewrites a
	small set of properties at runtime, on touch devices only, to produce the
	phone layout.

	## Why an override layer instead of two HUDs

	A second declared ScreenGui would double every future UI change and let the
	two drift — every controller that does `mainHud.LeftMenuBar.QuestButton`
	would need to know which one it was talking to. Here the instance tree is
	identical on both platforms; only geometry differs. Nothing else in the
	codebase has to know this module exists.

	## What actually differs on a phone

	Desktop has a mouse (pixel-accurate) and a tall window. A phone has a thumb
	(~44px minimum) and a SHORT landscape window with THREE no-go areas: the
	Roblox topbar above y=76, the thumbstick at the bottom left, and — the one
	this file used to miss — Roblox's own JUMP BUTTON at the bottom right. The
	usable band between them is about 150px, and five stacked 44px buttons need
	240px — so the vertical menu bar cannot survive contact with a phone. It
	becomes a compact 2-column grid of small square-ish cells instead.

	## The jump button, and why the skill cluster had to move

	This file used to say the action button and the three skill buttons were
	"deliberately NOT changed on mobile ... they are where a thumb expects
	them." That was the bug: where a thumb expects them is exactly where Roblox
	already puts the jump button, and the desktop geometry does not survive a
	phone viewport at all. Measured from the declared layout:

	  * BottomRight is positioned at x = 0.815 * width and is 170px wide (its
	    UISizeConstraint floor), so on a landscape phone it runs OFF THE RIGHT
	    EDGE — by 64px on a 568-wide viewport, 51px at 640, 46px at 667. The
	    third skill button was partly off-screen on every phone.
	  * What was left cleared the jump button by 6px at 568x320 and 18px at
	    640x360 — visually merged with it, and one Roblox layout revision away
	    from covering it outright.

	The jump button is NOT moved or restyled: it stays at Roblox's default
	position, which is what players' muscle memory expects and what the platform
	guarantees. Instead the three skill buttons are placed on an ARC around it,
	the way a mobile action game arranges abilities around a primary button, and
	the arc radius is DERIVED from Roblox's own TouchJump geometry (see
	jumpButtonRect) rather than hand-tuned, so it stays clear on every viewport
	including tablets, where that button is 120px instead of 70px.

	## Testing

	Studio reports TouchEnabled == false, so the phone path cannot be reached by
	running Play. Setting the player attribute `ForceMobileLayout` to true (or
	false) re-applies either layout live, which is how both were verified.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer

local ResponsiveLayoutController = {}

-- ===== Phone geometry =====

-- Below this the Roblox topbar overlaps MainHUD, which ignores the GUI inset.
local TOPBAR_SAFE_Y = 76
-- Comfortable thumb target. Everything a finger must hit is at least this.
local TAP_MIN = 44

-- The menu grid: two columns of narrow cells. Narrow on purpose — the
-- complaint about the first attempt was footprint, and at 2 x 163px the bar
-- ate a third of the screen width. 78px cells halve that while keeping every
-- cell a legal tap target.
local MENU_CELL = Vector2.new(104, TAP_MIN)
local MENU_PAD = Vector2.new(6, 6)

-- Shorter captions for the four buttons whose text is STATIC. The Grand Prix
-- button and the timer are deliberately absent: GrandPrixJoinController
-- rewrites both every tick ("JOINED - TAP TO LEAVE", "NEXT GP 29:07"), so
-- anything set here would be clobbered within the second.
local MOBILE_LABELS: { [string]: string } = {
	MenuButton = "MENU",
	SkillShopButton = "SKILLS",
	RobuxShopButton = "ROBUX",
	QuestButton = "QUESTS",
}

-- The Fan Box toggle and the Grand Prix timer are NOT peers of the menu
-- buttons and must not look like them. The toggle is a secondary control and
-- the timer is not a control at all — it is a readout. Sized accordingly:
-- the toggle stays small but reachable, the timer stays text-height.
-- Close to the desktop toggle's own proportions (216 x 19). It gets a little
-- taller for a thumb, but NOT wider and NOT menu-button height — enlarging it
-- to a full tap target made it read as a primary button, which it is not.
local FANBOX_WIDTH_SCALE = 0.22
local FANBOX_HEIGHT = 30
local GP_TIMER_HEIGHT = 20

-- ===== The jump-button exclusion zone =====
--
-- Reproduced from Roblox's own PlayerModule/TouchJump, which is the only thing
-- that decides where that button actually is. It switches on a SMALL-screen
-- threshold, and both branches matter: a phone gets a 70px button and a tablet
-- a 120px one, so a single hand-tuned offset that clears it on a phone sits
-- right on top of it on an iPad.
local JUMP_SMALL_SCREEN_MAX_HEIGHT = 500
local JUMP_SIZE_SMALL, JUMP_SIZE_LARGE = 70, 120
-- Distance from the screen's right/bottom edges to the button's own right/
-- bottom edges, i.e. TouchJump's Position offsets resolved against its Size.
local JUMP_INSET_SMALL = Vector2.new(25, 20)
local JUMP_INSET_LARGE = Vector2.new(70, 50)

-- Skill buttons keep their 58px square (already a legal tap target) and sit on
-- an arc around the jump button at these angles, measured anticlockwise from
-- screen-right — so 180 is directly left of the jump button, 90 directly above.
-- Left-to-top matches the order a right thumb sweeps through them.
local SKILL_BUTTON = 58
local SKILL_ARC_ANGLES = { Skill1Button = 180, Skill2Button = 135, Skill3Button = 90 }
-- Empty space between the jump button's edge and a skill button's edge.
local SKILL_ARC_GAP = 10

-- The context action button ("DEPOSIT FANS" / "ENTER TRACK" / ...) has to give
-- ground for the arc: at its desktop 240px floor, centred, its right edge
-- reaches 71% of a 568px viewport while the arc's leftmost button starts at
-- 66%, so the two genuinely overlap. Narrower keeps it centred and clear of
-- BOTH the arc on its right and the thumbstick on its left.
local ACTION_MOBILE_SIZE = Vector2.new(160, 44)
local ACTION_MOBILE_TEXT_SIZE = 14

local currentlyMobile: boolean? = nil

-- Rect of Roblox's jump button, in the same screen coordinates MainHUD uses
-- (it sets IgnoreGuiInset, so its origin is the true top-left of the screen —
-- the same origin TouchGui uses). Returns centre and half-extent.
local function jumpButtonRect(viewport: Vector2) : (Vector2, number)
	local isSmall = viewport.Y <= JUMP_SMALL_SCREEN_MAX_HEIGHT
	local size = if isSmall then JUMP_SIZE_SMALL else JUMP_SIZE_LARGE
	local inset = if isSmall then JUMP_INSET_SMALL else JUMP_INSET_LARGE
	local centre = Vector2.new(
		viewport.X - inset.X - size / 2,
		viewport.Y - inset.Y - size / 2
	)
	return centre, size / 2
end

local function hud() : ScreenGui?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	return (playerGui and playerGui:FindFirstChild("MainHUD")) :: ScreenGui?
end

-- Desktop values, captured from the instance the FIRST time a layout is
-- applied. Read from the live tree rather than duplicated as constants here,
-- so default.project.json stays the only place the desktop layout is authored
-- — retuning it there cannot leave a stale copy in this file.
local desktopSnapshot: { [Instance]: { [string]: any } } = {}

-- Merges per PROPERTY, not per instance. An earlier version bailed out if the
-- instance had been seen at all, which silently dropped every property saved
-- by a LATER call — the menu buttons kept their shortened mobile captions
-- ("SKILLS", "ROBUX") after switching back to desktop, because Text was
-- remembered on a second call that never ran. Only the first value seen for
-- each property is kept, so re-applying a layout twice cannot overwrite the
-- desktop original with a mobile one.
local function remember(instance: Instance, properties: { string })
	local saved = desktopSnapshot[instance]
	if saved == nil then
		saved = {}
		desktopSnapshot[instance] = saved
	end
	for _, property in properties do
		if saved[property] == nil then
			saved[property] = (instance :: any)[property]
		end
	end
end

local function restore(instance: Instance)
	local saved = desktopSnapshot[instance]
	if saved == nil then
		return
	end
	for property, value in saved do
		(instance :: any)[property] = value
	end
end

-- ===== Mobile layout =====

local function applyMobile(mainHud: ScreenGui)
	local bar = mainHud:FindFirstChild("LeftMenuBar") :: Frame?
	if bar ~= nil then
		remember(bar, { "Size", "Position" })
		bar.Size = UDim2.fromOffset(
			MENU_CELL.X * 2 + MENU_PAD.X,
			MENU_CELL.Y * 3 + MENU_PAD.Y * 2
		)
		bar.Position = UDim2.new(0, 14, 0, TOPBAR_SAFE_Y)

		-- Swap the vertical list for a grid. The list is destroyed rather than
		-- disabled because two layout objects on one frame fight each other.
		local list = bar:FindFirstChildOfClass("UIListLayout")
		if list ~= nil then
			list:Destroy()
		end
		if bar:FindFirstChildOfClass("UIGridLayout") == nil then
			local grid = Instance.new("UIGridLayout")
			grid.SortOrder = Enum.SortOrder.LayoutOrder
			grid.FillDirectionMaxCells = 2
			grid.CellSize = UDim2.fromOffset(MENU_CELL.X, MENU_CELL.Y)
			grid.CellPadding = UDim2.fromOffset(MENU_PAD.X, MENU_PAD.Y)
			grid.Parent = bar
		end

		-- Small cells need text that shrinks to fit rather than a fixed size
		-- that overflows. "JOIN GRAND PRIX" in 78px is the binding case.
		for _, child in bar:GetChildren() do
			if child:IsA("TextButton") or child:IsA("TextLabel") then
				local isTimer = child.Name == "GrandPrixTimerLabel"

				remember(child, { "TextScaled", "TextSize", "BackgroundTransparency" })
				child.TextScaled = true

				-- The Grand Prix timer is a READOUT, not a control, and a grid
				-- gives it the same cell as a button. It cannot be moved out of
				-- the bar — GrandPrixJoinController looks it up as a direct
				-- child of LeftMenuBar — so instead it loses the thing that
				-- makes a cell look pressable: its background. What is left is
				-- small text floating in the grid, which is what a timer should
				-- look like next to five buttons.
				if isTimer then
					child.BackgroundTransparency = 1
				end

				local shortLabel = MOBILE_LABELS[child.Name]
				if shortLabel ~= nil then
					remember(child, { "Text" })
					child.Text = shortLabel
				end

				if child:FindFirstChildOfClass("UITextSizeConstraint") == nil then
					local constraint = Instance.new("UITextSizeConstraint")
					constraint.MaxTextSize = if isTimer then 11 else 13
					constraint.MinTextSize = 7
					constraint.Parent = child
				end
			end
		end
	end

	-- Fan Box toggle: kept visually small — it is a secondary control, and
	-- blowing it up to full tap size made it read as a primary button.
	local toggle = mainHud:FindFirstChild("LocationToggle") :: Frame?
	if toggle ~= nil then
		remember(toggle, { "Size", "Position" })
		toggle.Size = UDim2.new(FANBOX_WIDTH_SCALE, 0, 0, FANBOX_HEIGHT)
		toggle.Position = UDim2.new(0.5, 0, 0, TOPBAR_SAFE_Y - 34)
	end

	-- ===== Skill buttons: an arc around Roblox's jump button =====
	--
	-- BottomRight stops being a positioned column and becomes a ZERO-SIZE anchor
	-- at the screen's top-left, so each button can be placed at a real screen
	-- coordinate derived from where the jump button actually is. Keeping the
	-- frame (rather than reparenting the buttons) matters: ControlMapper toggles
	-- its .Visible to hide the cluster at the Fan Box, and CooldownDisplayController
	-- looks the buttons up through it. Children are not clipped to a parent's
	-- bounds (ClipsDescendants is false), so a 0x0 frame positions them fine.
	--
	-- Zero-size rather than the obvious full-screen container: an arc CANNOT be
	-- bounded by a rectangle that excludes the jump button (measured, the arc's
	-- bounding box overlaps that rect by 64x64px), so a container sized to hold
	-- the buttons would necessarily lie across Roblox's jump button. A
	-- BackgroundTransparency=1, Active=false Frame does not consume input, so
	-- that would very likely have worked — but "very likely" is not a good
	-- enough reason to lay one of our frames over the platform's own touch
	-- control. A 0x0 anchor covers nothing at all and needs no such argument.
	local viewport = workspace.CurrentCamera.ViewportSize
	local jumpCentre, jumpHalf = jumpButtonRect(viewport)

	-- The radius has to clear the jump button on the DIAGONAL too. These are
	-- axis-aligned squares, not circles: two squares miss each other only when
	-- their centres are far enough apart on one whole axis, so the 135-degree
	-- button needs radius * cos(45) of separation per axis, not just radius.
	-- Sizing off the straight-line clearance alone is what would let the
	-- diagonal button clip the corner of the jump button.
	local axisClearance = jumpHalf + SKILL_BUTTON / 2 + SKILL_ARC_GAP
	local arcRadius = axisClearance / math.cos(math.rad(45))

	local bottomRight = mainHud:FindFirstChild("BottomRight") :: Frame?
	if bottomRight ~= nil then
		remember(bottomRight, { "Size", "Position", "AnchorPoint" })
		bottomRight.AnchorPoint = Vector2.new(0, 0)
		bottomRight.Position = UDim2.fromScale(0, 0)
		bottomRight.Size = UDim2.fromOffset(0, 0)

		-- The frame's own UISizeConstraint floor (170x186) would clamp it
		-- straight back to a real, screen-covering rectangle otherwise.
		local floor = bottomRight:FindFirstChildOfClass("UISizeConstraint")
		if floor ~= nil then
			remember(floor, { "MinSize" })
			floor.MinSize = Vector2.zero
		end

		for buttonName, angleDegrees in SKILL_ARC_ANGLES do
			local button = bottomRight:FindFirstChild(buttonName) :: GuiObject?
			if button ~= nil then
				remember(button, { "Size", "Position", "AnchorPoint" })
				local angle = math.rad(angleDegrees)
				-- Screen Y grows downward, so "up" on the arc is a NEGATIVE
				-- offset — the sine is subtracted, not added.
				local centre = jumpCentre + Vector2.new(math.cos(angle), -math.sin(angle)) * arcRadius
				button.AnchorPoint = Vector2.new(0.5, 0.5)
				button.Size = UDim2.fromOffset(SKILL_BUTTON, SKILL_BUTTON)
				button.Position = UDim2.fromOffset(centre.X, centre.Y)
			end
		end
	end

	-- The context action button, narrowed so the arc has room. Its own
	-- UISizeConstraint floor is what actually decides its width, so that has to
	-- move too — setting Size alone would be silently clamped straight back.
	local centerAction = mainHud:FindFirstChild("CenterAction") :: Frame?
	if centerAction ~= nil then
		remember(centerAction, { "Size", "Position" })
		centerAction.Size = UDim2.fromOffset(ACTION_MOBILE_SIZE.X, ACTION_MOBILE_SIZE.Y)

		local floor = centerAction:FindFirstChildOfClass("UISizeConstraint")
		if floor ~= nil then
			remember(floor, { "MinSize" })
			floor.MinSize = ACTION_MOBILE_SIZE
		end

		-- ===== The portrait trap =====
		--
		-- This button is bottom-CENTRE, and in landscape that is nowhere near the
		-- jump button. In PORTRAIT it is directly on top of it: a tall viewport
		-- takes Roblox's non-small-screen branch, which makes the jump button
		-- 120px and moves it to x = width-190..width-70 — and on a 375-wide phone
		-- that is the middle of the screen, exactly where this button sits.
		-- Measured against the declared layout: 120x64px of overlap on a 375x812
		-- iPhone, and the jump button is 120 wide, so it was covered across its
		-- ENTIRE width. Worse than hidden — ActionButton is a real TextButton with
		-- Active = true, so it swallowed the taps as well.
		--
		-- StarterGui.ScreenOrientation is now LandscapeSensor, so portrait should
		-- never happen. This clamp stays anyway: an orientation setting is a
		-- request to the device, this is the thing that actually guarantees we are
		-- not sitting on the platform's jump control. It is a no-op in landscape.
		--
		-- The escape is UPWARDS, not sideways. On a 375-wide portrait screen the
		-- jump button spans x 185..305, so clearing it horizontally would mean
		-- shoving a 160px button's right edge below x=185 — i.e. into the
		-- thumbstick. There is plenty of room above it.
		local actionCentreX = viewport.X / 2
		local actionCentreY = viewport.Y * 0.87
		local actionHalf = ACTION_MOBILE_SIZE / 2
		local jumpTop = jumpCentre.Y - jumpHalf
		local overlapsX = math.abs(actionCentreX - jumpCentre.X) < (actionHalf.X + jumpHalf)
		local overlapsY = math.abs(actionCentreY - jumpCentre.Y) < (actionHalf.Y + jumpHalf)
		if overlapsX and overlapsY then
			actionCentreY = jumpTop - SKILL_ARC_GAP - actionHalf.Y
		end
		centerAction.Position = UDim2.fromOffset(actionCentreX, actionCentreY)

		local actionButton = centerAction:FindFirstChild("ActionButton") :: TextButton?
		if actionButton ~= nil then
			-- A fixed smaller size rather than TextScaled: TextScaled on a 44px
			-- button gives 44px text, and the alternative (a UITextSizeConstraint)
			-- would be a new instance applyDesktop has to know to remove.
			remember(actionButton, { "TextSize" })
			actionButton.TextSize = ACTION_MOBILE_TEXT_SIZE
		end
	end

	-- Panel close buttons are the one control a mis-tap really costs, because
	-- missing one leaves a modal covering the game.
	for _, descendant in mainHud:GetDescendants() do
		if descendant:IsA("GuiButton") and descendant.Name == "CloseButton" then
			remember(descendant, { "Size" })
			descendant.Size = UDim2.fromOffset(TAP_MIN, TAP_MIN)
		end
	end
end

local function applyDesktop(mainHud: ScreenGui)
	-- Everything mobile touched is restored from the snapshot; the grid is
	-- removed and the list rebuilt with the padding the project file declares.
	for instance in desktopSnapshot do
		if instance.Parent ~= nil then
			restore(instance)
		end
	end

	local bar = mainHud:FindFirstChild("LeftMenuBar") :: Frame?
	if bar ~= nil then
		local grid = bar:FindFirstChildOfClass("UIGridLayout")
		if grid ~= nil then
			grid:Destroy()
		end
		if bar:FindFirstChildOfClass("UIListLayout") == nil then
			local list = Instance.new("UIListLayout")
			list.SortOrder = Enum.SortOrder.LayoutOrder
			list.Padding = UDim.new(0, 8)
			list.Parent = bar
		end
		for _, child in bar:GetChildren() do
			local constraint = child:FindFirstChildOfClass("UITextSizeConstraint")
			if constraint ~= nil then
				constraint:Destroy()
			end
		end
	end
end

-- ===== Public =====

-- Where Roblox's jump button sits, as (centre, halfExtent), in MainHUD's own
-- offset space. Exposed because MobileJumpButton has to put its stand-in in
-- exactly the hole this file's arc reserves — two copies of this arithmetic
-- that drifted apart would put the fallback button under a skill button.
function ResponsiveLayoutController.GetJumpButtonRect(viewport: Vector2) : (Vector2, number)
	return jumpButtonRect(viewport)
end

function ResponsiveLayoutController.Apply(isMobile: boolean)
	local mainHud = hud()
	if mainHud == nil or currentlyMobile == isMobile then
		return
	end
	currentlyMobile = isMobile
	if isMobile then
		applyMobile(mainHud)
	else
		applyDesktop(mainHud)
	end
end

function ResponsiveLayoutController.IsMobile() : boolean
	local forced = localPlayer:GetAttribute("ForceMobileLayout")
	if typeof(forced) == "boolean" then
		return forced
	end
	if not UserInputService.TouchEnabled then
		return false
	end
	-- Touch AND no mouse, in production. A Windows laptop with a touchscreen
	-- reports TouchEnabled true while still being driven with a mouse, and it
	-- should keep the desktop layout.
	--
	-- In STUDIO that same "has a mouse" test is wrong, and wrong in the one
	-- place it matters most: the device emulator reports TouchEnabled = true
	-- but MouseEnabled stays true too (you are still driving it with a mouse),
	-- so emulating a phone showed the DESKTOP layout. That is not a cosmetic
	-- gap — it means the mobile layout could not be seen or tested in the only
	-- tool available for looking at it, and it was mistaken for the phone
	-- layout being broken. Inside Studio, touch means the emulator.
	return not UserInputService.MouseEnabled or RunService:IsStudio()
end

function ResponsiveLayoutController.Init()
	localPlayer:WaitForChild("PlayerGui"):WaitForChild("MainHUD")
	ResponsiveLayoutController.Apply(ResponsiveLayoutController.IsMobile())

	-- Live re-apply, for the test override and for a device that gains or
	-- loses a mouse mid-session.
	localPlayer:GetAttributeChangedSignal("ForceMobileLayout"):Connect(function()
		ResponsiveLayoutController.Apply(ResponsiveLayoutController.IsMobile())
	end)

	-- The mobile layout is now computed FROM the viewport (the jump button it
	-- has to avoid is 70px on a phone and 120px on a tablet, at different
	-- insets), so a viewport change invalidates it. That happens on rotation, on
	-- a window resize, and every time Studio's device emulator is switched to a
	-- different phone — which is how this layout gets looked at in the first
	-- place, so without this it would be verified at one size and shipped at
	-- another. Apply() cannot do this itself: it short-circuits when the
	-- mobile/desktop verdict has not changed, which on a resize it has not.
	-- applyMobile is idempotent (remember() only ever keeps the first, desktop,
	-- value for a property), so re-running it just re-solves the geometry.
	local function watchCamera(camera: Camera?)
		if camera == nil then
			return
		end
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			local mainHud = hud()
			if currentlyMobile == true and mainHud ~= nil then
				applyMobile(mainHud)
			end
		end)
	end
	watchCamera(workspace.CurrentCamera)
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		watchCamera(workspace.CurrentCamera)
	end)
end

return ResponsiveLayoutController

--!strict
--[[
	CapsuleButtonFX
	Every clickable button in MainHUD gets the same press personality: it
	squashes, rounds into a glossy CAPSULE, a specular highlight sweeps
	across it, and it springs back on release.

	Applied by WALKING MainHUD rather than by editing eight controllers.
	Buttons here are created three different ways — declared in
	default.project.json, cloned from templates at runtime (skill shop rows,
	quest rows, skill-select entries), and looked up by name from controllers
	— so the only place that sees all of them is the descendant tree itself.
	A DescendantAdded watcher covers the cloned ones, which is why this needs
	no cooperation from the controller that does the cloning.

	## Why the sheen is a child Frame and not the button's own UIGradient

	A UIGradient parented to a TextButton tints its TEXT as well as its
	background, so sweeping a transparency band across the button's own
	gradient would also flicker the label. The sheen is therefore its own
	Frame (`_CapsuleShine`), sized to the button, carrying its own UICorner
	tweened in lockstep so the highlight is clipped to the same capsule
	silhouette. `Active` is left false, so it never eats the click it is
	decorating.

	Its ZIndex is button.ZIndex + 1 — above the background and the label
	(a TextButton draws its text at its own ZIndex, and a child at the same
	ZIndex draws over it), but below the icons/badges/fills that existing
	controllers put at ZIndex 2-7. The highlight passes over the button, not
	over the quest badge or the pickup fill.

	## Why the glow stroke lives on the sheen, not on the button

	Roblox honours one UIStroke per GuiObject, and some buttons already have
	one from the project file. Putting the press glow on the sheen Frame —
	identical size, identical corner radius — renders as a border glow on the
	button while being physically incapable of fighting a stroke the button
	already owns.

	## Opting out

	Full-screen modal BACKDROPS are TextButtons too (MainMenuPanel,
	SkillShopPanel, RobuxShopPanel, SkillSelectPanel — each is a dimmed sheet
	whose Activated closes the modal). Capsule-ing a backdrop would scale and
	round the entire screen. They are recognised structurally, by the `Card`
	child every one of them has, rather than by a name list that would go
	stale the moment a fifth modal is added. `NoCapsuleFX` as an attribute is
	the manual escape hatch.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UITheme = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("UITheme"))

local localPlayer = Players.LocalPlayer

local CapsuleButtonFX = {}

-- ===== Tuning =====

-- Snappy rather than smooth on the way down: the press has to read as
-- CAUSED by the finger, and anything past ~0.15s reads as the UI deciding
-- on its own.
local PRESS_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Back/Out on the way up is the overshoot that makes it feel springy — the
-- same easing NotificationController already uses for its "Pop" style, so
-- the whole HUD bounces with one personality.
local RELEASE_INFO = TweenInfo.new(0.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
-- The corner radius releases on Quint instead, because Back OVERSHOOTS its
-- goal and a corner radius has nowhere to overshoot TO: measured live,
-- releasing a 12px button on Back drove CornerRadius.Scale to -0.05 before
-- settling. Roblox clamps that to square so nothing breaks, but on a button
-- whose rest radius is already large the undershoot is a visible corner
-- flicker. The springiness belongs to the SCALE, which has room to bounce;
-- the geometry just needs to arrive quickly.
local RELEASE_RADIUS_INFO = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local GLOW_OUT_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SHINE_INFO = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_INFO = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local PRESSED_SCALE = 0.93
local HOVER_SCALE = 1.035
local REST_SCALE = 1

-- A perfect pill. Roblox clamps CornerRadius to half the shorter side, so
-- 0.5 scale is exactly "as round as this rectangle can be" at any size —
-- which matters because these buttons range from a 30px square close button
-- to a full-width bar.
local CAPSULE_RADIUS = UDim.new(0.5, 0)

local GLOW_THICKNESS = 3
local GLOW_TRANSPARENCY = 0.25

-- Offsets past ±1 so the band starts and finishes fully outside the button
-- instead of popping in at the edge.
local SHINE_START_OFFSET = Vector2.new(-1.3, 0)
local SHINE_END_OFFSET = Vector2.new(1.3, 0)
local SHINE_ROTATION = 20 -- diagonal, the way light actually catches a glossy surface

-- A bright core with a soft falloff either side, rather than the single hard
-- keypoint the first version used. A one-stop band reads as a grey rectangle
-- sliding across; a falloff reads as light.
local SHINE_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.30, 1),
	NumberSequenceKeypoint.new(0.42, 0.72),
	NumberSequenceKeypoint.new(0.50, 0.12),
	NumberSequenceKeypoint.new(0.58, 0.72),
	NumberSequenceKeypoint.new(0.70, 1),
	NumberSequenceKeypoint.new(1, 1),
})

-- ===== Permanent gloss =====
--
-- The press sweep is an EVENT; this is the button's resting FINISH. Without
-- it a button is a flat coloured rectangle that briefly becomes interesting
-- when touched — the sheen was doing all the work and only while being
-- clicked. This is the always-on highlight that makes it look like moulded
-- candy at rest, which is the look the palette (UITheme's "kid-friendly
-- glossy candy") was already asking for.
--
-- Vertical: a bright crown across the top third fading to nothing by the
-- middle, then a faint bounce-light near the bottom edge.
local GLOSS_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.45),
	NumberSequenceKeypoint.new(0.16, 0.62),
	NumberSequenceKeypoint.new(0.48, 1),
	NumberSequenceKeypoint.new(0.86, 1),
	NumberSequenceKeypoint.new(1, 0.88),
})
local GLOSS_ROTATION = 90 -- top-to-bottom
-- Pressed buttons dim their crown: real glossy things lose their highlight as
-- they tilt away from you, and it sells the squash.
local GLOSS_PRESSED_TRANSPARENCY = 0.55

-- ===== Idle shimmer =====
--
-- Every button catches the light on a slow cycle even when nothing is
-- happening, so the HUD reads as glossy rather than static. Randomised phase
-- per button — a synchronised flash across fifteen buttons looks like a
-- rendering fault, not a highlight.
local SHIMMER_PERIOD = 7
local SHIMMER_JITTER = 5
local SHIMMER_INFO = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

-- Activated also fires for gamepad/keyboard/AccessibilityService activation,
-- which produce no InputBegan on the button. It fires on mouse-up too, so a
-- real click would double-trigger without this guard.
local SYNTHETIC_PRESS_HOLD = 0.09
local RECENT_PRESS_WINDOW = 0.3

-- ===== State =====

type ButtonFX = {
	Button: GuiButton,
	Corner: UICorner,
	Scale: UIScale,
	Shine: Frame,
	ShineGradient: UIGradient,
	ShineCorner: UICorner,
	Gloss: Frame,
	GlossGradient: UIGradient,
	GlossCorner: UICorner,
	Glow: UIStroke,
	RestRadius: UDim,
	IsPressed: boolean,
	IsHovered: boolean,
	LastPressClock: number,
	NextShimmerClock: number,
	-- Held on its own rather than in Active: the sweep re-fires on hover and on
	-- every idle shimmer, and appending each one to a list that is only cleared
	-- by a PRESS meant a button nobody ever clicked accumulated a dead tween
	-- every few seconds for the life of the session.
	ShineTween: Tween?,
	Active: { Tween },
}

-- Weak keys: an entry disappears with the button it decorates, which matters
-- because cloned rows are created and destroyed constantly. Deliberately NOT
-- an attribute — attributes are copied by Clone(), so a cloned button would
-- claim to be hooked while carrying none of the connections.
local hooked: { [Instance]: ButtonFX } = setmetatable({}, { __mode = "k" }) :: any

-- ===== Helpers =====

local function cancelActive(fx: ButtonFX)
	for _, tween in fx.Active do
		tween:Cancel()
	end
	table.clear(fx.Active)
end

local function play(fx: ButtonFX, instance: Instance, info: TweenInfo, goal: { [string]: any })
	local tween = TweenService:Create(instance, info, goal)
	table.insert(fx.Active, tween)
	tween:Play()
	return tween
end

-- A lighter, more saturated relative of the button's own colour, so the glow
-- reads as THIS button lighting up rather than as a generic white halo
-- pasted over five different palette colours.
local function glowColorFor(button: GuiButton) : Color3
	local base = if button:IsA("TextButton") or button:IsA("ImageButton")
		then button.BackgroundColor3
		else UITheme.Primary
	local h, s, v = base:ToHSV()
	return Color3.fromHSV(h, math.max(0, s * 0.55), math.min(1, v * 0.35 + 0.65))
end

-- Full-screen modal backdrops are TextButtons whose whole job is to be
-- clicked to dismiss. Every one of them wraps a `Card`; that is the
-- structural signature, and it stays true for modals added later.
local function isBackdrop(button: GuiButton) : boolean
	return button:FindFirstChild("Card") ~= nil
end

local function shouldDecorate(instance: Instance) : boolean
	if not instance:IsA("GuiButton") then
		return false
	end
	if instance:GetAttribute("NoCapsuleFX") == true then
		return false
	end
	if isBackdrop(instance :: GuiButton) then
		return false
	end
	return true
end

-- ===== Build =====

local function ensureCorner(button: GuiButton) : (UICorner, UDim)
	local corner = button:FindFirstChildOfClass("UICorner")
	if corner == nil then
		corner = Instance.new("UICorner")
		-- Square at rest, so a button that had no UICorner keeps the look it
		-- shipped with and only rounds while it is being pressed.
		corner.CornerRadius = UDim.new(0, 0)
		corner.Parent = button
	end

	-- Stored on the UICorner rather than recomputed, so that a button pressed
	-- twice in quick succession (or a template cloned mid-tween) restores the
	-- radius it was AUTHORED with, not whatever the interrupted tween had
	-- reached. Attributes survive Clone(), which is exactly what is wanted for
	-- this one — unlike the hooked marker above.
	local stored = corner:GetAttribute("CapsuleRestRadius")
	if typeof(stored) ~= "UDim" then
		stored = corner.CornerRadius
		corner:SetAttribute("CapsuleRestRadius", stored)
	end

	return corner, stored :: UDim
end

local function ensureScale(button: GuiButton) : UIScale
	local scale = button:FindFirstChildOfClass("UIScale")
	if scale == nil then
		scale = Instance.new("UIScale")
		scale.Parent = button
	end
	return scale
end

local function ensureShine(button: GuiButton, restRadius: UDim) : (Frame, UIGradient, UIStroke)
	local shine = button:FindFirstChild("_CapsuleShine") :: Frame?
	if shine == nil then
		shine = Instance.new("Frame")
		shine.Name = "_CapsuleShine"
		shine.Size = UDim2.fromScale(1, 1)
		shine.BackgroundColor3 = UITheme.GlossHighlight
		shine.BackgroundTransparency = 0 -- the gradient below is what makes it invisible at rest
		shine.BorderSizePixel = 0
		shine.Visible = false
		shine.Active = false -- must never intercept the click it is decorating
		shine.ZIndex = button.ZIndex + 1
		shine.Parent = button
	end

	local corner = shine:FindFirstChildOfClass("UICorner")
	if corner == nil then
		corner = Instance.new("UICorner")
		corner.Parent = shine
	end
	corner.CornerRadius = restRadius

	local gradient = shine:FindFirstChildOfClass("UIGradient")
	if gradient == nil then
		gradient = Instance.new("UIGradient")
		gradient.Parent = shine
	end
	gradient.Transparency = SHINE_TRANSPARENCY
	gradient.Rotation = SHINE_ROTATION
	gradient.Offset = SHINE_START_OFFSET

	local glow = shine:FindFirstChildOfClass("UIStroke")
	if glow == nil then
		glow = Instance.new("UIStroke")
		glow.Parent = shine
	end
	glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border -- Contextual would outline the TEXT, not the capsule
	glow.Color = glowColorFor(button)
	glow.Thickness = GLOW_THICKNESS
	glow.Transparency = 1

	return shine, gradient, glow
end

-- The always-on crown highlight. A separate frame from the sweep because the
-- two have different lifetimes and different gradients: this one never moves
-- and is never hidden, the sweep is transient and travels. Sits BELOW the
-- sweep (one ZIndex lower) so a passing sheen reads as light crossing over
-- the gloss rather than under it.
local function ensureGloss(button: GuiButton, restRadius: UDim) : (Frame, UIGradient, UICorner)
	local gloss = button:FindFirstChild("_CapsuleGloss") :: Frame?
	if gloss == nil then
		gloss = Instance.new("Frame")
		gloss.Name = "_CapsuleGloss"
		gloss.Size = UDim2.fromScale(1, 1)
		gloss.BackgroundColor3 = UITheme.GlossHighlight
		gloss.BackgroundTransparency = 0
		gloss.BorderSizePixel = 0
		gloss.Active = false
		gloss.ZIndex = button.ZIndex
		gloss.Parent = button
	end

	local corner = gloss:FindFirstChildOfClass("UICorner")
	if corner == nil then
		corner = Instance.new("UICorner")
		corner.Parent = gloss
	end
	corner.CornerRadius = restRadius

	local gradient = gloss:FindFirstChildOfClass("UIGradient")
	if gradient == nil then
		gradient = Instance.new("UIGradient")
		gradient.Parent = gloss
	end
	gradient.Transparency = GLOSS_TRANSPARENCY
	gradient.Rotation = GLOSS_ROTATION

	return gloss, gradient, corner
end

-- ===== Animation =====

local function playShine(fx: ButtonFX, info: TweenInfo?)
	-- Two tweens on one property fight; the previous sweep is always retired.
	if fx.ShineTween ~= nil then
		fx.ShineTween:Cancel()
	end
	fx.ShineGradient.Offset = SHINE_START_OFFSET
	fx.Shine.Visible = true

	local sweep = TweenService:Create(fx.ShineGradient, info or SHINE_INFO, { Offset = SHINE_END_OFFSET })
	fx.ShineTween = sweep
	sweep.Completed:Connect(function(state: Enum.PlaybackState)
		-- Only hide on a sweep that actually finished. A cancelled sweep means
		-- a second press already restarted it, and hiding here would blank the
		-- highlight the new press just turned on.
		if state == Enum.PlaybackState.Completed then
			fx.Shine.Visible = false
		end
	end)
	sweep:Play()
end

local function applyPress(fx: ButtonFX)
	cancelActive(fx)
	fx.LastPressClock = os.clock()

	play(fx, fx.Corner, PRESS_INFO, { CornerRadius = CAPSULE_RADIUS })
	play(fx, fx.ShineCorner, PRESS_INFO, { CornerRadius = CAPSULE_RADIUS })
	play(fx, fx.GlossCorner, PRESS_INFO, { CornerRadius = CAPSULE_RADIUS })
	play(fx, fx.Scale, PRESS_INFO, { Scale = PRESSED_SCALE })
	play(fx, fx.Glow, PRESS_INFO, { Transparency = GLOW_TRANSPARENCY })
	-- Crown dims as the button "tilts away" under the thumb.
	play(fx, fx.Gloss, PRESS_INFO, { BackgroundTransparency = GLOSS_PRESSED_TRANSPARENCY })
	playShine(fx)
end

local function applyRelease(fx: ButtonFX)
	cancelActive(fx)

	-- Back to hovered rather than to rest when the pointer is still over the
	-- button, or the button would visibly drop out of its hover state under a
	-- cursor that never left.
	local targetScale = if fx.IsHovered then HOVER_SCALE else REST_SCALE

	play(fx, fx.Corner, RELEASE_RADIUS_INFO, { CornerRadius = fx.RestRadius })
	play(fx, fx.ShineCorner, RELEASE_RADIUS_INFO, { CornerRadius = fx.RestRadius })
	play(fx, fx.GlossCorner, RELEASE_RADIUS_INFO, { CornerRadius = fx.RestRadius })
	play(fx, fx.Scale, RELEASE_INFO, { Scale = targetScale })
	play(fx, fx.Glow, GLOW_OUT_INFO, { Transparency = 1 })
	play(fx, fx.Gloss, RELEASE_INFO, { BackgroundTransparency = 0 })
end

-- ===== Public =====

function CapsuleButtonFX.Decorate(button: GuiButton)
	if hooked[button] ~= nil then
		return
	end
	if not shouldDecorate(button) then
		return
	end

	local corner, restRadius = ensureCorner(button)
	local scale = ensureScale(button)
	local shine, gradient, glow = ensureShine(button, restRadius)
	local gloss, glossGradient, glossCorner = ensureGloss(button, restRadius)

	local fx: ButtonFX = {
		Button = button,
		Corner = corner,
		Scale = scale,
		Shine = shine,
		ShineGradient = gradient,
		ShineCorner = shine:FindFirstChildOfClass("UICorner") :: UICorner,
		Gloss = gloss,
		GlossGradient = glossGradient,
		GlossCorner = glossCorner,
		Glow = glow,
		RestRadius = restRadius,
		IsPressed = false,
		IsHovered = false,
		LastPressClock = 0,
		-- Random phase so the HUD twinkles instead of strobing in unison.
		NextShimmerClock = os.clock() + math.random() * SHIMMER_JITTER,
		ShineTween = nil,
		Active = {},
	}
	hooked[button] = fx

	local function isPointerInput(input: InputObject) : boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	button.InputBegan:Connect(function(input: InputObject)
		if not isPointerInput(input) or fx.IsPressed then
			return
		end
		fx.IsPressed = true
		applyPress(fx)
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if not isPointerInput(input) or not fx.IsPressed then
			return
		end
		fx.IsPressed = false
		applyRelease(fx)
	end)

	button.MouseEnter:Connect(function()
		fx.IsHovered = true
		if fx.IsPressed then
			return
		end
		play(fx, fx.Scale, HOVER_INFO, { Scale = HOVER_SCALE })
		-- Hovering catches the light too. On desktop this is most of the
		-- glossiness a player ever sees, since they are pointing at buttons far
		-- more often than clicking them.
		playShine(fx)
		-- Don't let the idle shimmer fire on top of the hover sweep.
		fx.NextShimmerClock = os.clock() + SHIMMER_PERIOD
	end)

	button.MouseLeave:Connect(function()
		fx.IsHovered = false
		-- Dragging off a held button never produces an InputEnded on it, so
		-- without this the button would be left stuck squashed and capsuled.
		if fx.IsPressed then
			fx.IsPressed = false
			applyRelease(fx)
			return
		end
		play(fx, fx.Scale, HOVER_INFO, { Scale = REST_SCALE })
	end)

	button.Activated:Connect(function()
		-- Only for activations that produced no pointer press of their own —
		-- gamepad, keyboard, accessibility. A mouse click has already animated
		-- by the time Activated fires.
		if fx.IsPressed or (os.clock() - fx.LastPressClock) < RECENT_PRESS_WINDOW then
			return
		end
		applyPress(fx)
		task.delay(SYNTHETIC_PRESS_HOLD, function()
			if fx.Button.Parent ~= nil and not fx.IsPressed then
				applyRelease(fx)
			end
		end)
	end)
end

function CapsuleButtonFX.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")

	for _, descendant in mainHud:GetDescendants() do
		if descendant:IsA("GuiButton") then
			CapsuleButtonFX.Decorate(descendant)
		end
	end

	-- Covers every button cloned from a template after startup — quest rows,
	-- skill shop rows, skill-select entries — without any of those controllers
	-- knowing this module exists.
	mainHud.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("GuiButton") then
			CapsuleButtonFX.Decorate(descendant)
		end
	end)

	-- ONE loop for every button, not one thread each. Thirty-odd buttons with
	-- their own task.wait loops would be thirty schedulable threads doing
	-- nothing for seven seconds at a time; this is a single pass that only
	-- touches buttons whose shimmer is actually due.
	--
	-- Gated on being visibly on screen: a button inside a closed panel has no
	-- reason to be running a tween, and the panels here stay parented while
	-- hidden, so `Visible` is the only thing that distinguishes them.
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for _, fx in hooked do
				if now < fx.NextShimmerClock then
					continue
				end
				fx.NextShimmerClock = now + SHIMMER_PERIOD + math.random() * SHIMMER_JITTER
				local button = fx.Button
				if button.Parent == nil or fx.IsPressed or not button.Visible then
					continue
				end
				-- A hidden ancestor makes AbsoluteSize stay non-zero, so check
				-- the rendered chain rather than the button's own flag alone.
				if button.AbsoluteSize.X <= 0 or not button:IsDescendantOf(mainHud) then
					continue
				end
				playShine(fx, SHIMMER_INFO)
			end
		end
	end)
end

return CapsuleButtonFX

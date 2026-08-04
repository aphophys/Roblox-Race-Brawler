--!strict
--[[
	TutorialController
	The first-run tutorial: six short cards, shown once, ever.

	## Built in code, not in default.project.json

	Every other panel is declared in the project file, which is the right call
	for UI that other controllers look up by name. Nothing looks this up — it
	appears once in a player's lifetime and then never exists again — so
	declaring it would add ~120 lines of JSON to a 1,700-line file for a thing
	that is invisible 99.9% of the time. Building it here also lets the copy
	adapt to the input device, which JSON cannot do.

	## Shown once, from a PERSISTED flag

	Gated on `TutorialCompleted`, mirrored onto the player as an attribute by
	ProfileManager.SyncAttributes. Deliberately not inferred from progress
	("TotalLapsCompleted == 0" and similar): a player who watches the tutorial
	and logs off before finishing a lap must not be shown it again, and a
	player who skipped it must not have it forced back on them.

	The flag is read as a tri-state. `false` means new player, show it. `true`
	means done. `nil` means the profile has not loaded yet — or failed to —
	and in that case the tutorial is silently skipped rather than shown,
	because a tutorial that cannot record having been seen would run again on
	every single join.

	## Mobile first

	Phones are the majority of this game's audience, so the card is sized in
	SCALE with a pixel cap, the body text is TextScaled inside a
	UITextSizeConstraint (so it shrinks to fit a small screen but never grows
	into a billboard on desktop), and both buttons are 52px tall — above the
	~44px minimum comfortable tap target. The buttons sit at the BOTTOM of the
	card, which on a phone is the half of the screen a thumb actually reaches.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UITheme = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("UITheme"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local TutorialController = {}

-- How long to wait for the profile to load before giving up and not showing
-- the tutorial at all. Generous: a cold DataStore read on a busy server is
-- occasionally slow, and showing nothing is only a missed tutorial, whereas
-- showing it without a loaded profile means showing it again forever.
local PROFILE_WAIT_SECONDS = 20

local CARD_WIDTH_SCALE = 0.86
local CARD_MAX_WIDTH = 520
-- Height is a SCALE with a pixel cap, not a fixed 320px. A fixed height
-- overflows a landscape phone: measured at a 306px-tall viewport the card's
-- top edge landed at y = -6.8, i.e. the title was off the top of the screen.
-- Landscape phones are SHORT, and that is the orientation this game is played
-- in, so vertical space is the scarce axis and the one that has to flex.
local CARD_HEIGHT_SCALE = 0.82
local CARD_MAX_HEIGHT = 320
local CARD_MIN_HEIGHT = 190
local BUTTON_HEIGHT = 52

type Step = {
	Title: string,
	Body: string,
}

-- Six cards. Written for a nine-year-old: one idea each, second person, and
-- the reward stated before the mechanic wherever possible.
local function buildSteps() : { Step }
	-- Touch and desktop get different control copy. Telling a phone player to
	-- press Space is how a tutorial teaches somebody that it is not for them.
	local moveText = if UserInputService.TouchEnabled
		then "Drag the joystick on the left to run. Tap the jump button to jump."
		else "Use W A S D to run. Press Space to jump."

	return {
		{
			Title = "WELCOME TO RACE BRAWLER!",
			Body = "40 racers. One track. Nobody plays fair.\n\nThis takes 30 seconds — then you're racing.",
		},
		{
			Title = "1. GET MOVING",
			Body = moveText .. "\n\nThe track changes every single race, so there's nothing to memorise.",
		},
		{
			Title = "2. RUIN SOMEBODY'S DAY",
			Body = "You start with 3 skills on the right of your screen.\n\nSWAP places with someone ahead. REVERSE their controls. DASH forward.\n\nUsing them is the whole point.",
		},
		{
			Title = "3. COLLECT YOUR FANS",
			Body = "Grab fan crates on the track and carry them to a deposit zone.\n\nFans build the crowd in YOUR stand — everyone in the server can see how big it is.",
		},
		{
			Title = "4. STAY ALIVE",
			Body = "Pass all 8 checkpoints to finish a lap.\n\nHazards and falls cost you a life. You get 3.",
		},
		{
			Title = "5. THE GRAND PRIX",
			Body = "On the hour and half-hour, the whole server races for real prizes.\n\nThe clock on the left shows the next one. Tap JOIN GRAND PRIX to enter. Good luck!",
		},
	}
end

local currentIndex = 1
local steps: { Step } = {}
local backdrop: Frame? = nil
local titleLabel: TextLabel? = nil
local bodyLabel: TextLabel? = nil
local progressLabel: TextLabel? = nil
local nextButton: TextButton? = nil
local hasFinished = false

local function finish()
	if hasFinished then
		return
	end
	hasFinished = true

	-- Told to the server BEFORE the UI is torn down: if the player closes the
	-- client during the fade, the flag is already on its way.
	Network.Track.CompleteTutorial:FireServer()

	local root = backdrop
	if root == nil then
		return
	end
	backdrop = nil

	local card = root:FindFirstChild("Card") :: Frame?
	local fade = TweenService:Create(root, TweenInfo.new(0.25), { BackgroundTransparency = 1 })
	if card ~= nil then
		local scale = card:FindFirstChildOfClass("UIScale")
		if scale ~= nil then
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0.7 }):Play()
		end
	end
	fade.Completed:Connect(function()
		root:Destroy()
	end)
	fade:Play()
end

local function render()
	local step = steps[currentIndex]
	if step == nil then
		finish()
		return
	end
	if titleLabel ~= nil then
		titleLabel.Text = step.Title
	end
	if bodyLabel ~= nil then
		bodyLabel.Text = step.Body
	end
	if progressLabel ~= nil then
		progressLabel.Text = `{currentIndex} / {#steps}`
	end
	if nextButton ~= nil then
		nextButton.Text = if currentIndex >= #steps then "LET'S RACE!" else "NEXT"
	end
end

local function advance()
	currentIndex += 1
	if currentIndex > #steps then
		finish()
		return
	end
	render()
end

local function build(parent: ScreenGui)
	-- A Frame, not a TextButton: a mistapped backdrop must not skip the
	-- tutorial. Skipping is an explicit button.
	local root = Instance.new("Frame")
	root.Name = "TutorialOverlay"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = Color3.fromRGB(10, 12, 22)
	root.BackgroundTransparency = 0.35
	root.BorderSizePixel = 0
	root.ZIndex = 200
	root.Active = true -- swallows taps on the game behind it while it is up
	root.Parent = parent
	backdrop = root

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(CARD_WIDTH_SCALE, 0, CARD_HEIGHT_SCALE, 0)
	card.BackgroundColor3 = UITheme.PanelBackground
	card.BorderSizePixel = 0
	card.ZIndex = 201
	card.Parent = root

	-- Scale on a phone, capped on a desktop — without this the card is either
	-- unreadably narrow on a 4-inch screen or absurdly wide on a monitor.
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MaxSize = Vector2.new(CARD_MAX_WIDTH, CARD_MAX_HEIGHT)
	-- Floor as well as cap: below this the body text would be shrinking past
	-- readable rather than the card getting smaller.
	sizeConstraint.MinSize = Vector2.new(0, CARD_MIN_HEIGHT)
	sizeConstraint.Parent = card

	local cardCorner = Instance.new("UICorner")
	cardCorner.CornerRadius = UDim.new(0, 20)
	cardCorner.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = UITheme.Primary
	cardStroke.Thickness = 3
	cardStroke.Parent = card

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 18)
	padding.PaddingBottom = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 18)
	padding.PaddingRight = UDim.new(0, 18)
	padding.Parent = card

	local title = Instance.new("TextLabel")
	title.Name = "TitleLabel"
	title.Size = UDim2.new(1, 0, 0, 34)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextColor3 = UITheme.Primary
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 202
	title.Parent = card
	titleLabel = title

	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = 26
	titleSize.MinTextSize = 14
	titleSize.Parent = title

	local body = Instance.new("TextLabel")
	body.Name = "BodyLabel"
	body.Position = UDim2.new(0, 0, 0, 44)
	body.Size = UDim2.new(1, 0, 1, -(44 + BUTTON_HEIGHT + 14))
	body.BackgroundTransparency = 1
	body.Font = Enum.Font.Gotham
	body.TextColor3 = UITheme.TextPrimary
	body.TextScaled = true
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.ZIndex = 202
	body.Parent = card
	bodyLabel = body

	-- TextScaled alone would blow the body up to fill the box on short cards.
	-- The constraint is what keeps every card's text the same readable size.
	local bodySize = Instance.new("UITextSizeConstraint")
	bodySize.MaxTextSize = 18
	-- 10, not 11: on the shortest landscape phones the longest card (step 2)
	-- needs the extra point of headroom to wrap inside the body box instead of
	-- clipping its last line.
	bodySize.MinTextSize = 10
	bodySize.Parent = body

	local skip = Instance.new("TextButton")
	skip.Name = "SkipButton"
	skip.AnchorPoint = Vector2.new(0, 1)
	skip.Position = UDim2.new(0, 0, 1, 0)
	skip.Size = UDim2.new(0.34, -6, 0, BUTTON_HEIGHT)
	skip.BackgroundColor3 = Color3.fromRGB(225, 228, 236)
	skip.BorderSizePixel = 0
	skip.Font = Enum.Font.GothamBold
	skip.Text = "SKIP"
	skip.TextColor3 = UITheme.TextPrimary
	skip.TextSize = 15
	skip.AutoButtonColor = true
	skip.ZIndex = 202
	skip.Parent = card

	local skipCorner = Instance.new("UICorner")
	skipCorner.CornerRadius = UITheme.CornerRadius
	skipCorner.Parent = skip

	local nextBtn = Instance.new("TextButton")
	nextBtn.Name = "NextButton"
	nextBtn.AnchorPoint = Vector2.new(1, 1)
	nextBtn.Position = UDim2.new(1, 0, 1, 0)
	nextBtn.Size = UDim2.new(0.66, -6, 0, BUTTON_HEIGHT)
	nextBtn.BackgroundColor3 = UITheme.Success
	nextBtn.BorderSizePixel = 0
	nextBtn.Font = Enum.Font.GothamBold
	nextBtn.Text = "NEXT"
	nextBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	nextBtn.TextSize = 17
	nextBtn.AutoButtonColor = true
	nextBtn.ZIndex = 202
	nextBtn.Parent = card
	nextButton = nextBtn

	local nextCorner = Instance.new("UICorner")
	nextCorner.CornerRadius = UITheme.CornerRadius
	nextCorner.Parent = nextBtn

	local progress = Instance.new("TextLabel")
	progress.Name = "ProgressLabel"
	progress.AnchorPoint = Vector2.new(1, 0)
	progress.Position = UDim2.new(1, 0, 0, 4)
	progress.Size = UDim2.new(0, 54, 0, 20)
	progress.BackgroundTransparency = 1
	progress.Font = Enum.Font.GothamBold
	progress.TextColor3 = UITheme.Secondary
	progress.TextSize = 14
	progress.TextXAlignment = Enum.TextXAlignment.Right
	progress.ZIndex = 203
	progress.Parent = card
	progressLabel = progress

	local cardScale = Instance.new("UIScale")
	cardScale.Scale = 0.7
	cardScale.Parent = card
	TweenService:Create(cardScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	skip.Activated:Connect(finish)
	nextBtn.Activated:Connect(advance)
end

function TutorialController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD") :: ScreenGui

	task.spawn(function()
		-- Tri-state wait: false = new player, true = done, nil = not loaded.
		local deadline = os.clock() + PROFILE_WAIT_SECONDS
		while localPlayer:GetAttribute("TutorialCompleted") == nil and os.clock() < deadline do
			task.wait(0.25)
		end

		if localPlayer:GetAttribute("TutorialCompleted") ~= false then
			return
		end

		steps = buildSteps()
		currentIndex = 1
		build(mainHud)
		render()
	end)
end

return TutorialController

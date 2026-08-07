--!strict
--[[
	LeaderboardBuilder
	The four stadium leaderboards standing around the Commercial Hub, and the
	code that draws top-10 rows onto them.

	## Placement

	The hub floor is a STADIUM covering the whole infield (HubGenerator): half
	-width 130 across the straights, running out to 310 toward the curve ends,
	against a track whose inner paved edge is 144 out along the straights. One
	board per cardinal direction, each ROTATED TO FACE THE HUB CENTRE. Facing
	inward is what makes opposite pairs face each other across the infield,
	and it means every board is readable from the middle of the hub where
	players spawn. The two radii are per-direction and are NOT interchangeable
	— see the constants below.

	## Grand Prix takeover

	While a Grand Prix is running, all four boards drop their all-time
	category and show the SAME live race standings — from the countdown
	grid, through the race, to the final result — then revert. Pushed in by
	GrandPrixManager via SetGrandPrixMode; see the constants beside it, and
	RESULT_HOLD_SECONDS there for why the final result outlives the "Ended"
	state. The on-screen standings panel is hidden for the duration
	(LiveRaceHUD), so the boards are the only place the race is shown.

	## Two faces, one set of numbers

	Each board carries a SurfaceGui on BOTH its Front and Back faces, filled
	from the same data in the same pass. A player walking round the back sees
	the same standings rather than a blank slab.

	## Climbable

	The legs are real TrussParts, so Roblox's own character controller enters
	the Climbing state on contact — same mechanism HillMud's climb walls use,
	no custom state code. A catwalk runs along the bottom edge of the screen
	so climbing up actually arrives somewhere.

	TrussPart hard-clamps its X/Y size to 2 studs regardless of what is set,
	and its long axis is local Z, so a vertical leg is a truss rotated 90°
	about X — the same construction ThemeHazardBuilder.createClimbWall uses.

	## Avatars

	Rows use `rbxthumb://type=AvatarHeadShot&id=<UserId>&w=150&h=150`, which
	Roblox resolves without any web call of ours. Building the GUIs on the
	SERVER means they replicate to every client for free and cannot disagree
	between viewers — the same reasoning VisualEffectsService documents.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardCategories = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("LeaderboardCategories"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local LeaderboardManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("LeaderboardManager"))
local HubGenerator = require(script.Parent:WaitForChild("HubGenerator"))

-- ===== Why the four boards are NOT all at the same radius =====
--
-- `TrackBoundaryMonitor.ON_TRACK_MARGIN` puts a ring around the track
-- CENTERLINE, and an InLobby player inside it is teleported straight back to
-- the Hub. The oval is not a circle, so that ring is a very different distance
-- from the hub centre depending on which way you walk. The measurements below
-- were taken when the margin was 49 studs; it has since been tightened to 39
-- (SegmentWidth/2 + BarrierThickness — see that constant for why), which moves
-- every bite point 10 studs FURTHER OUT and so only widens the clearance the
-- radii below were chosen to get. They are left exactly as measured:
--
--   toward a STRAIGHT — its centerline is only CurveRadius = 180 from the
--     centre, so the boundary bites at radius 131. Measured live: at r = 128
--     the centerline is just 54 studs away, and the catwalk+railing reached
--     r = 135 — INSIDE the margin. That is exactly why climbing those two
--     boards bounced players back to the Hub (reported from play).
--   toward a CURVE END — the nearest centerline is 180 studs away even at
--     r = 128, and nothing bites until r = 260 (both measured live).
--
-- So the straight-side pair moves IN and the curve-side pair moves OUT, and
-- the radius is chosen per direction rather than shared. The ring space the
-- curve pair vacates is where the vendor stands go (HubAmenitiesBuilder).
--
-- These two numbers are NOT free to change. They were each measured against
-- the boundary ring above, and an earlier attempt to cure the boards
-- "floating" by pulling them in to 100/118 was fixing the wrong side of the
-- problem: the floating was that they stood at the hub floor's top face (Y+2)
-- while the ground beneath them was terrain at Y ~ 0, i.e. the FLOOR did not
-- reach them. HubGenerator's floor is now a stadium covering the whole
-- infield (half-width 130 across the straights, reaching 310 toward the curve
-- ends), so both pairs stand on pavement exactly where the boundary
-- measurements put them.
local STRAIGHT_SIDE_RADIUS = 112
local CURVE_SIDE_RADIUS = 190

local BOARD_WIDTH = 86
local BOARD_HEIGHT = 38
local BOARD_THICKNESS = 2
-- Bottom edge of the screen. Tall enough to read from across the infield and
-- to clear the crowd/benches, short enough that the truss climb is a real
-- (but not punishing) climb.
local BOARD_BASE_HEIGHT = 26
-- Structural legs, spread across the span. The first version used a single
-- pair at ±34 on an 86-wide board, which left the outer thirds visibly
-- unsupported — reported from play as the boards "floating".
local SUPPORT_LEG_OFFSETS = { -40, -16, 16, 40 }
-- The two climbing towers sit just BEYOND the board's ends, at the catwalk's
-- depth, and finish slightly above it. Climbing an interior leg would end
-- underneath the catwalk with nowhere to go; ending beside its edge means a
-- player steps straight on.
local CLIMB_TOWER_LATERAL = 30
-- Each tower is a LADDER, not a pole. The first version was a single 2x2
-- truss column per side, and a character walking into it just slid along the
-- face and never entered Climbing (measured live: 16 studs of sideways drift,
-- zero height gained, no Climbing state). Roblox's auto-climb needs a face
-- broad enough for the capsule to stay in contact with, which is why
-- ThemeHazardBuilder's climb walls are rows of touching poles rather than
-- single posts. Same construction here: poles at CLIMB_POLE_SPACING so
-- adjacent ones touch, leaving no gap to slip through.
local CLIMB_POLE_SPACING = 2
local CLIMB_TOWER_POLES = 4 -- 4 x 2 studs = an 8-stud-wide ladder face
-- Tall enough to top out ABOVE the railing (deck 28.5, railing top 29.5), so
-- the last move onto the ledge is a step down rather than a scramble up.
local CLIMB_TOWER_OVERSHOOT = 10
local CATWALK_DEPTH = 6
-- Wide enough that the deck reaches past both climbing ladders.
local CATWALK_OVERHANG = (CLIMB_TOWER_LATERAL - BOARD_WIDTH / 2) * 2 + CLIMB_TOWER_POLES * CLIMB_POLE_SPACING + 4

local ROW_COUNT = 10
local HEADER_HEIGHT_FRACTION = 0.20

local LeaderboardBuilder = {}

-- category id -> every SurfaceGui showing it (front and back of one board).
local surfacesByCategoryId: { [string]: { SurfaceGui } } = {}

local function formatValue(category: LeaderboardCategories.LeaderboardCategory, value: number) : string
	if category.ValueFormat == "LapTime" then
		local totalSeconds = value / 1000
		local minutes = math.floor(totalSeconds / 60)
		local seconds = totalSeconds - minutes * 60
		if minutes > 0 then
			return string.format("%d:%06.3f", minutes, seconds)
		end
		return string.format("%.3fs", seconds)
	end
	return Utils.FormatNumber(value) .. category.ValueSuffix
end

-- Builds the row scaffolding once. Rows are created empty and then filled by
-- renderInto on every refresh, rather than being destroyed and rebuilt — a
-- rebuild would make every avatar image re-request on each refresh.
local function buildSurface(parent: BasePart, face: Enum.NormalId, category: LeaderboardCategories.LeaderboardCategory) : SurfaceGui
	local surface = Instance.new("SurfaceGui")
	surface.Name = `Board_{category.Id}_{face.Name}`
	surface.Face = face
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 24
	surface.LightInfluence = 0
	surface.Parent = parent

	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
	background.BorderSizePixel = 0
	background.Parent = surface

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.fromScale(1, HEADER_HEIGHT_FRACTION)
	header.BackgroundColor3 = category.AccentColor
	header.BorderSizePixel = 0
	header.Parent = background

	-- Named so the Grand Prix takeover can retitle them in place. Rebuilding
	-- the GUI to change a caption would drop every avatar image the board has
	-- already loaded, which is exactly the cost buildSurface/renderInto were
	-- split up to avoid.
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(1, 0.62)
	title.BackgroundTransparency = 1
	title.Text = category.Title
	title.TextColor3 = Color3.fromRGB(16, 18, 26)
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.Parent = header

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.fromScale(1, 0.34)
	subtitle.Position = UDim2.fromScale(0, 0.64)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = category.Subtitle
	subtitle.TextColor3 = Color3.fromRGB(40, 44, 56)
	subtitle.Font = Enum.Font.GothamBold
	subtitle.TextScaled = true
	subtitle.Parent = header

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Size = UDim2.fromScale(0.96, 1 - HEADER_HEIGHT_FRACTION - 0.03)
	rows.Position = UDim2.fromScale(0.02, HEADER_HEIGHT_FRACTION + 0.01)
	rows.BackgroundTransparency = 1
	rows.Parent = background

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = rows

	for index = 1, ROW_COUNT do
		local row = Instance.new("Frame")
		row.Name = `Row{index}`
		row.LayoutOrder = index
		row.Size = UDim2.fromScale(1, 1 / ROW_COUNT - 0.004)
		-- Alternating banding: ten identical dark rows at stadium scale are
		-- genuinely hard to track across from a distance.
		row.BackgroundColor3 = if index % 2 == 0 then Color3.fromRGB(26, 29, 40) else Color3.fromRGB(34, 38, 52)
		row.BorderSizePixel = 0
		row.Parent = rows

		local rank = Instance.new("TextLabel")
		rank.Name = "Rank"
		rank.Size = UDim2.fromScale(0.08, 1)
		rank.BackgroundTransparency = 1
		rank.Text = `{index}`
		rank.TextColor3 = category.AccentColor
		rank.Font = Enum.Font.GothamBlack
		rank.TextScaled = true
		rank.Parent = row

		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.Size = UDim2.fromScale(0.9, 0.9)
		avatar.SizeConstraint = Enum.SizeConstraint.RelativeYY
		avatar.Position = UDim2.fromScale(0.09, 0.05)
		avatar.BackgroundColor3 = Color3.fromRGB(60, 66, 84)
		avatar.BorderSizePixel = 0
		avatar.Image = ""
		avatar.Parent = row

		local name = Instance.new("TextLabel")
		name.Name = "PlayerName"
		name.Size = UDim2.fromScale(0.52, 1)
		name.Position = UDim2.fromScale(0.17, 0)
		name.BackgroundTransparency = 1
		name.Text = "—"
		name.TextColor3 = Color3.fromRGB(235, 238, 248)
		name.Font = Enum.Font.GothamBold
		name.TextScaled = true
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Parent = row

		local value = Instance.new("TextLabel")
		value.Name = "Value"
		value.Size = UDim2.fromScale(0.30, 1)
		value.Position = UDim2.fromScale(0.69, 0)
		value.BackgroundTransparency = 1
		value.Text = ""
		value.TextColor3 = category.AccentColor
		value.Font = Enum.Font.GothamBlack
		value.TextScaled = true
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.Parent = row
	end

	return surface
end

-- ===== Grand Prix takeover =====
--
-- While a Grand Prix is running, all four boards drop their all-time category
-- and show the SAME live race standings, from the countdown through to the
-- winner and rewards, then revert. Four copies of one list rather than four
-- different lists on purpose: a racer glances at whichever board is in front
-- of them, and there is only one thing worth knowing during a race.
--
-- The takeover is PUSHED in by GrandPrixManager rather than polled: this
-- module already redraws only when LeaderboardManager signals a change, and a
-- poll would either lag the countdown or spin for the 20+ minutes between
-- races. `grandPrixRows == nil` means "no race" and is the only condition
-- that decides which of the two renderers runs — there is no second flag that
-- could disagree with it.
export type GrandPrixRow = {
	UserId: number,
	DisplayName: string,
	LapsCompleted: number,
	CheckpointOrdinal: number,
	LivesRemaining: number,
	IsEliminated: boolean,
	FinishPlace: number?,
}

local GRAND_PRIX_TITLE = "GRAND PRIX"
local GRAND_PRIX_ACCENT = Color3.fromRGB(255, 145, 40)

local grandPrixRows: { GrandPrixRow }? = nil
local grandPrixSubtitle = ""

-- What a racer actually needs off a board mid-race, in the order it matters:
-- have they finished, are they out, otherwise how far round are they.
local function formatGrandPrixRow(row: GrandPrixRow) : string
	if row.FinishPlace ~= nil then
		return `P{row.FinishPlace}`
	elseif row.IsEliminated then
		return "OUT"
	end
	return `L{row.LapsCompleted + 1} · CP{row.CheckpointOrdinal}`
end

local function renderInto(surface: SurfaceGui, category: LeaderboardCategories.LeaderboardCategory)
	local background = surface:FindFirstChild("Background")
	if background == nil then
		return
	end
	local rowsFrame = background:FindFirstChild("Rows")
	if rowsFrame == nil then
		return
	end

	local raceRows = grandPrixRows
	local accent = if raceRows ~= nil then GRAND_PRIX_ACCENT else category.AccentColor

	-- Header first, so a board can never show race standings under an
	-- all-time epithet (or the reverse) even for one frame.
	local header = background:FindFirstChild("Header") :: Frame?
	if header ~= nil then
		header.BackgroundColor3 = accent
		local title = header:FindFirstChild("Title") :: TextLabel?
		local subtitle = header:FindFirstChild("Subtitle") :: TextLabel?
		if title ~= nil then
			title.Text = if raceRows ~= nil then GRAND_PRIX_TITLE else category.Title
		end
		if subtitle ~= nil then
			subtitle.Text = if raceRows ~= nil then grandPrixSubtitle else category.Subtitle
		end
	end

	local entries = if raceRows == nil then LeaderboardManager.GetTop(category.Id) else nil

	for index = 1, ROW_COUNT do
		local row = rowsFrame:FindFirstChild(`Row{index}`)
		if row == nil then
			continue
		end
		local avatar = row:FindFirstChild("Avatar") :: ImageLabel
		local nameLabel = row:FindFirstChild("PlayerName") :: TextLabel
		local valueLabel = row:FindFirstChild("Value") :: TextLabel
		local rankLabel = row:FindFirstChild("Rank") :: TextLabel?
		if rankLabel ~= nil then
			rankLabel.TextColor3 = accent
		end
		valueLabel.TextColor3 = accent

		if raceRows ~= nil then
			local raceRow = raceRows[index]
			if raceRow == nil then
				avatar.Image = ""
				nameLabel.Text = "—"
				nameLabel.TextTransparency = 0.6
				valueLabel.Text = ""
			else
				avatar.Image = `rbxthumb://type=AvatarHeadShot&id={raceRow.UserId}&w=150&h=150`
				nameLabel.Text = raceRow.DisplayName
				-- An eliminated racer stays on the board (they are part of the
				-- story of the race) but greys out, so the live field reads
				-- first.
				nameLabel.TextTransparency = if raceRow.IsEliminated then 0.55 else 0
				valueLabel.Text = formatGrandPrixRow(raceRow)
			end
			continue
		end

		local entry = (entries :: any)[index]
		if entry == nil then
			-- Empty slots stay visible rather than collapsing, so the board
			-- reads as "10 places, 3 taken" instead of looking broken.
			avatar.Image = ""
			nameLabel.Text = "—"
			nameLabel.TextTransparency = 0.6
			valueLabel.Text = ""
		else
			avatar.Image = `rbxthumb://type=AvatarHeadShot&id={entry.UserId}&w=150&h=150`
			nameLabel.Text = entry.DisplayName
			nameLabel.TextTransparency = 0
			valueLabel.Text = formatValue(category, entry.Value)
		end
	end
end

function LeaderboardBuilder.Refresh()
	for categoryId, surfaces in surfacesByCategoryId do
		local category = LeaderboardCategories.ById[categoryId]
		if category == nil then
			continue
		end
		for _, surface in surfaces do
			renderInto(surface, category)
		end
	end
end

-- Called by GrandPrixManager on every state change and every standings
-- update. Pass nil for `rows` to hand the boards back to the all-time
-- categories — that is the ONLY way out of Grand Prix mode, so a race that
-- ends (for any reason, including everyone leaving) always reverts.
function LeaderboardBuilder.SetGrandPrixMode(rows: { GrandPrixRow }?, subtitle: string?)
	grandPrixRows = rows
	grandPrixSubtitle = subtitle or ""
	LeaderboardBuilder.Refresh()
end

local function buildBoard(parent: Instance, category: LeaderboardCategories.LeaderboardCategory, baseCFrame: CFrame)
	local model = Instance.new("Model")
	model.Name = `Leaderboard_{category.Id}`

	local screen = Instance.new("Part")
	screen.Name = "Screen"
	screen.Anchored = true
	screen.CanCollide = true
	screen.Material = Enum.Material.SmoothPlastic
	screen.Color = Color3.fromRGB(16, 18, 26)
	screen.Size = Vector3.new(BOARD_WIDTH, BOARD_HEIGHT, BOARD_THICKNESS)
	screen.CFrame = baseCFrame * CFrame.new(0, BOARD_BASE_HEIGHT + BOARD_HEIGHT / 2, 0)
	screen.Parent = model

	-- Front is the face along the part's own LookVector, which baseCFrame has
	-- already aimed at the hub centre; Back is the outward side toward the
	-- track. Both get the same content.
	surfacesByCategoryId[category.Id] = {
		buildSurface(screen, Enum.NormalId.Front, category),
		buildSurface(screen, Enum.NormalId.Back, category),
	}

	local function addTruss(name: string, lateralOffset: number, depthOffset: number, height: number)
		local leg = Instance.new("TrussPart")
		leg.Name = name
		leg.Anchored = true
		leg.Size = Vector3.new(2, 2, height)
		leg.CFrame = baseCFrame
			* CFrame.new(lateralOffset, height / 2, depthOffset)
			* CFrame.Angles(math.rad(90), 0, 0)
		leg.Parent = model
	end

	-- Structural legs across the span, so the board is visibly held up rather
	-- than hanging in the air.
	for _, lateralOffset in SUPPORT_LEG_OFFSETS do
		for _, depthOffset in { -1.5, 1.5 } do
			addTruss("BoardTruss", lateralOffset, depthOffset, BOARD_BASE_HEIGHT)
		end
	end

	local catwalkDepthCentre = BOARD_THICKNESS / 2 + CATWALK_DEPTH / 2

	-- Two climbing LADDERS, each rising through a HOLE cut in the viewing
	-- ledge above it.
	--
	-- The first version ran the ladder through solid deck: measured live, the
	-- climber rose to Y = 26.5 and stopped dead with 7 studs of ladder still
	-- above them, because their head was against the deck's underside. A hole
	-- (rather than moving the ladder off the deck entirely) keeps the climb
	-- and the ledge in the same place, so a player emerges standing ON the
	-- ledge instead of having to cross a gap at height.
	local ladderDepth = BOARD_THICKNESS / 2 + CATWALK_DEPTH - 1

	for _, towerCentre in { -CLIMB_TOWER_LATERAL, CLIMB_TOWER_LATERAL } do
		for poleIndex = 0, CLIMB_TOWER_POLES - 1 do
			local lateralOffset = towerCentre + (poleIndex - (CLIMB_TOWER_POLES - 1) / 2) * CLIMB_POLE_SPACING
			-- Two rows deep so the ladder can be approached from either the
			-- hub side or the deck side and still present a full face.
			-- ONE row of poles, i.e. a flat ladder face — exactly the shape
			-- ThemeHazardBuilder's climb walls use. A two-row version was
			-- tried and measured: the character wedged in the gap between the
			-- rows and crawled 4.5 studs in 14 seconds, against 21.8 studs in
			-- 9 seconds for a single face. Depth is not what makes a ladder
			-- climbable; width is.
			--
			-- Height deliberately overshoots the deck by
			-- CLIMB_TOWER_OVERSHOOT: a ladder ending level with the deck
			-- leaves the climber's FEET below it, so stepping off is a
			-- ~2.5-stud step UP, right at the edge of Roblox's auto-step.
			-- Overshooting turns it into a step down.
			-- Near the deck's OUTER edge in depth, not its centre. At the
			-- centre the ladder sits only ~3 studs from the screen's face, and
			-- the screen starts at exactly BOARD_BASE_HEIGHT — measured live,
			-- the climb plateaued dead at Y = 27 (1.5 studs under the ledge)
			-- and would not go further however long W was held, because the
			-- climber was pinched between the ladder and the screen. Out here
			-- there is 5 studs of clear air in front of the board.
			addTruss("BoardClimbTower", lateralOffset, ladderDepth, BOARD_BASE_HEIGHT + CLIMB_TOWER_OVERSHOOT)
		end
	end

	-- The viewing ledge, built as SPANS with a gap over each ladder rather
	-- than one slab — those gaps are the climb-through holes.
	local totalWidth = BOARD_WIDTH + CATWALK_OVERHANG
	local holeHalfWidth = (CLIMB_TOWER_POLES * CLIMB_POLE_SPACING) / 2 + 1
	local edges = {
		-totalWidth / 2,
		-CLIMB_TOWER_LATERAL - holeHalfWidth,
		-CLIMB_TOWER_LATERAL + holeHalfWidth,
		CLIMB_TOWER_LATERAL - holeHalfWidth,
		CLIMB_TOWER_LATERAL + holeHalfWidth,
		totalWidth / 2,
	}

	-- Pairs (1,2), (3,4), (5,6) are the solid spans; the two gaps between
	-- them are the holes. Derived from the ladder positions, so moving a
	-- ladder moves its hole with it and they can never drift apart.
	for spanIndex = 1, #edges - 1, 2 do
		local spanStart, spanEnd = edges[spanIndex], edges[spanIndex + 1]
		local spanWidth = spanEnd - spanStart
		if spanWidth <= 0 then
			continue
		end
		local spanCentre = (spanStart + spanEnd) / 2

		local deck = Instance.new("Part")
		deck.Name = "BoardCatwalk"
		deck.Anchored = true
		deck.CanCollide = true
		deck.Material = Enum.Material.DiamondPlate
		deck.Color = Color3.fromRGB(120, 124, 136)
		deck.Size = Vector3.new(spanWidth, 1, CATWALK_DEPTH)
		deck.CFrame = baseCFrame * CFrame.new(spanCentre, BOARD_BASE_HEIGHT, catwalkDepthCentre)
		deck.Parent = model

		local railing = Instance.new("Part")
		railing.Name = "BoardRailing"
		railing.Anchored = true
		railing.CanCollide = true
		railing.Material = Enum.Material.Metal
		railing.Color = Color3.fromRGB(90, 94, 106)
		railing.Size = Vector3.new(spanWidth, 3, 0.5)
		railing.CFrame = baseCFrame * CFrame.new(spanCentre, BOARD_BASE_HEIGHT + 2, BOARD_THICKNESS / 2 + CATWALK_DEPTH)
		railing.Parent = model
	end

	model.Parent = parent
end

function LeaderboardBuilder.Build(parent: Instance)
	local existing = parent:FindFirstChild("Leaderboards")
	if existing ~= nil then
		existing:Destroy()
	end
	surfacesByCategoryId = {}

	local hubCFrame = HubGenerator.GetHubCFrame() or CFrame.new(0, 0, 0)

	local folder = Instance.new("Folder")
	folder.Name = "Leaderboards"
	folder.Parent = parent

	-- One per cardinal direction, each turned to look back at the hub centre.
	-- All four face inward, so the two opposite pairs face each other — that
	-- arrangement falls out of the geometry rather than needing per-board
	-- angles, and it survives the two pairs being at different radii.
	for index, category in LeaderboardCategories.Ordered do
		local angle = math.rad(90 * (index - 1))
		local outward = Vector3.new(math.sin(angle), 0, math.cos(angle))
		-- index 1/3 point along ±Z at the CURVE ends; 2/4 along ±X at the
		-- STRAIGHTS. Measured live, not assumed — see the radius constants.
		local isStraightSide = index % 2 == 0
		local radius = if isStraightSide then STRAIGHT_SIDE_RADIUS else CURVE_SIDE_RADIUS
		local position = hubCFrame.Position + outward * radius
		-- The disc's own top face, read from HubGenerator rather than assumed.
		-- The previous hard-coded "+2" was only correct INSIDE the disc; the
		-- boards were outside it, standing over terrain at Y ~ 0.
		local groundY = hubCFrame.Position.Y + HubGenerator.FloorTopY
		local lookAt = Vector3.new(hubCFrame.Position.X, groundY, hubCFrame.Position.Z)
		local baseCFrame = CFrame.lookAt(Vector3.new(position.X, groundY, position.Z), lookAt)
		buildBoard(folder, category, baseCFrame)
	end

	LeaderboardBuilder.Refresh()
end

function LeaderboardBuilder.Init()
	LeaderboardBuilder.Build(workspace)
	-- Redraw when the cache actually changes rather than on a timer of our
	-- own, so the boards can never show something the manager has already
	-- replaced.
	LeaderboardManager.Changed:Connect(function()
		LeaderboardBuilder.Refresh()
	end)
end

return LeaderboardBuilder

--!strict
--[[
	FanBoxRecordsBoard
	The small board standing on each Fan Box pod, showing whose pod it is —
	their avatar face — and their records.

	## Created lazily, from the slot manager

	The board is attached when a pod is claimed rather than when the ring is
	generated, and `attach` re-creates it if it has gone missing. That is
	deliberate: `FanBoxGenerator.SwapPodTier` replaces a pod's crowd mesh
	whenever its occupant graduates a fan tier, and a board built once at ring
	generation would be at the mercy of whatever that swap does to the pod's
	children. Re-attaching on demand costs nothing and cannot desync.

	## Both faces again

	Pods ring the whole oval, so which way any given pod faces depends on
	where it sits. Rather than compute a facing direction per pod, the board
	carries the same content on its Front and Back — the same answer the
	stadium leaderboards use, for the same reason.

	## Values come from attributes, not the profile

	ProfileManager.SyncAttributes already mirrors Gold/TotalFans/laps onto the
	Player, and the slot manager already listens to the TotalFans attribute to
	graduate tiers. Reading the same attributes here means the board updates
	from the signal that is already firing, instead of adding a second source
	of truth that could disagree with the crowd size standing next to it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FanBoxTiers = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("FanBoxTiers"))

local HubGenerator = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("HubGenerator"))

-- Stadium-scale, not a plaque. The first version was 12x7 and read as a
-- postage stamp against a 40x35 stand.
local BOARD_WIDTH = 30
local BOARD_HEIGHT = 16
-- Clear of the top row rather than embedded in the crowd: the pod's own
-- height is where the fans stand, so the board's bottom edge starts above it.
local BOARD_ABOVE_CROWD = 2
-- Behind the back of the stand. The crowd tiers rise AWAY from the track, so
-- "behind the topmost row" is the far side of the pod from the stadium centre.
local BOARD_BEHIND_STAND = FanBoxTiers.PodBaseSize.X / 2 + 3

local FanBoxRecordsBoard = {}

local function formatLapTime(milliseconds: number) : string
	if milliseconds <= 0 then
		return "—"
	end
	local totalSeconds = milliseconds / 1000
	local minutes = math.floor(totalSeconds / 60)
	local seconds = totalSeconds - minutes * 60
	if minutes > 0 then
		return string.format("%d:%06.3f", minutes, seconds)
	end
	return string.format("%.3fs", seconds)
end

local function formatNumber(value: number) : string
	local text = tostring(math.floor(value))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function buildSurface(board: BasePart, face: Enum.NormalId) : SurfaceGui
	local surface = Instance.new("SurfaceGui")
	surface.Name = `Records_{face.Name}`
	surface.Face = face
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 40
	surface.LightInfluence = 0
	surface.Parent = board

	local background = Instance.new("Frame")
	background.Name = "Background"
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = Color3.fromRGB(20, 22, 32)
	background.BorderSizePixel = 0
	background.Parent = surface

	local avatar = Instance.new("ImageLabel")
	avatar.Name = "Avatar"
	avatar.Size = UDim2.fromScale(0.30, 0.72)
	avatar.Position = UDim2.fromScale(0.04, 0.14)
	avatar.BackgroundColor3 = Color3.fromRGB(48, 52, 66)
	avatar.BorderSizePixel = 0
	avatar.Parent = background

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "PlayerName"
	nameLabel.Size = UDim2.fromScale(0.60, 0.22)
	nameLabel.Position = UDim2.fromScale(0.37, 0.10)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = "UNCLAIMED POD"
	nameLabel.TextColor3 = Color3.fromRGB(240, 242, 250)
	nameLabel.Font = Enum.Font.GothamBlack
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = background

	local statNames = { "Fans", "Gold", "Laps", "BestLap" }
	for index, statName in statNames do
		local stat = Instance.new("TextLabel")
		stat.Name = statName
		stat.Size = UDim2.fromScale(0.60, 0.15)
		stat.Position = UDim2.fromScale(0.37, 0.32 + (index - 1) * 0.16)
		stat.BackgroundTransparency = 1
		stat.Text = ""
		stat.TextColor3 = Color3.fromRGB(180, 186, 205)
		stat.Font = Enum.Font.GothamBold
		stat.TextScaled = true
		stat.TextXAlignment = Enum.TextXAlignment.Left
		stat.Parent = background
	end

	return surface
end

-- Returns the pod's board, creating it if absent.
local function attach(pod: Model) : BasePart?
	local existing = pod:FindFirstChild("RecordsBoard")
	if existing ~= nil then
		return existing :: BasePart
	end

	local originCFrame = pod:GetAttribute("OriginCFrame")
	if typeof(originCFrame) ~= "CFrame" then
		-- OriginCFrame is the one true ground-level reference FanBoxGenerator
		-- stamps on every pod; without it there is no correct height to place
		-- the board at, and guessing would put boards through the crowd.
		return nil
	end

	-- Measured from the pod's ACTUAL bounding box, taken before the board is
	-- added so the board never measures itself. A pod's height depends on
	-- which crowd tier is currently swapped in, so a hard-coded height would
	-- be wrong for most tiers.
	local podCFrame, podSize = pod:GetBoundingBox()
	local podTopY = podCFrame.Position.Y + podSize.Y / 2

	-- The pods ring the outside of the track and the stadium centre is the
	-- hub centre, so "toward the centre" is the direction the crowd faces and
	-- "behind the top row" is the opposite one.
	--
	-- The pod's own OriginCFrame is NOT that direction: measured live, its
	-- LookVector runs along the track (dot 0.55 with the direction to the
	-- centre) while its RightVector points mostly inward (dot 0.83). Building
	-- the board off the origin's rotation is exactly why it faced sideways.
	local centre = (HubGenerator.GetHubCFrame() or CFrame.new()).Position
	local podFlat = Vector3.new(podCFrame.Position.X, podTopY, podCFrame.Position.Z)
	local centreFlat = Vector3.new(centre.X, podTopY, centre.Z)
	local awayFromCentre = (podFlat - centreFlat)
	awayFromCentre = if awayFromCentre.Magnitude > 0.01 then awayFromCentre.Unit else Vector3.new(0, 0, 1)

	local boardPosition = podFlat
		+ awayFromCentre * BOARD_BEHIND_STAND
		+ Vector3.new(0, BOARD_HEIGHT / 2 + BOARD_ABOVE_CROWD, 0)

	local board = Instance.new("Part")
	board.Name = "RecordsBoard"
	board.Anchored = true
	board.CanCollide = false
	board.CanQuery = false
	board.Size = Vector3.new(BOARD_WIDTH, BOARD_HEIGHT, 0.6)
	board.Material = Enum.Material.SmoothPlastic
	board.Color = Color3.fromRGB(20, 22, 32)
	-- Front face aimed squarely at the stadium centre.
	board.CFrame = CFrame.lookAt(boardPosition, Vector3.new(centre.X, boardPosition.Y, centre.Z))
	board.Parent = pod

	buildSurface(board, Enum.NormalId.Front)
	buildSurface(board, Enum.NormalId.Back)

	return board
end

FanBoxRecordsBoard.Attach = attach

local function applyToSurfaces(board: BasePart, apply: (Frame) -> ())
	for _, child in board:GetChildren() do
		if child:IsA("SurfaceGui") then
			local background = child:FindFirstChild("Background")
			if background ~= nil then
				apply(background :: Frame)
			end
		end
	end
end

function FanBoxRecordsBoard.Render(pod: Model, player: Player)
	local board = attach(pod)
	if board == nil then
		return
	end

	local fans = (player:GetAttribute("TotalFans") :: number?) or 0
	local gold = (player:GetAttribute("Gold") :: number?) or 0
	local laps = (player:GetAttribute("TotalLapsCompleted") :: number?) or 0
	local bestLapMs = (player:GetAttribute("BestLapTimeMs") :: number?) or 0

	-- Every child resolved into a named local before assignment: a statement
	-- STARTING with "(" directly after another is Luau's ambiguous-syntax
	-- trap, and `rojo build` does not catch it.
	applyToSurfaces(board, function(background)
		local avatar = background:FindFirstChild("Avatar") :: ImageLabel
		local nameLabel = background:FindFirstChild("PlayerName") :: TextLabel
		local fansLabel = background:FindFirstChild("Fans") :: TextLabel
		local goldLabel = background:FindFirstChild("Gold") :: TextLabel
		local lapsLabel = background:FindFirstChild("Laps") :: TextLabel
		local bestLapLabel = background:FindFirstChild("BestLap") :: TextLabel

		avatar.Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
		nameLabel.Text = player.DisplayName
		fansLabel.Text = `🌟 {formatNumber(fans)} fans`
		goldLabel.Text = `💰 {formatNumber(gold)} gold`
		lapsLabel.Text = `🏁 {formatNumber(laps)} laps`
		bestLapLabel.Text = `⏱ best lap {formatLapTime(bestLapMs)}`
	end)
end

function FanBoxRecordsBoard.Clear(pod: Model)
	local board = pod:FindFirstChild("RecordsBoard") :: BasePart?
	if board == nil then
		return
	end

	applyToSurfaces(board, function(background)
		local avatar = background:FindFirstChild("Avatar") :: ImageLabel
		local nameLabel = background:FindFirstChild("PlayerName") :: TextLabel
		avatar.Image = ""
		nameLabel.Text = "UNCLAIMED POD"
		for _, statName in { "Fans", "Gold", "Laps", "BestLap" } do
			local statLabel = background:FindFirstChild(statName) :: TextLabel
			statLabel.Text = ""
		end
	end)
end

return FanBoxRecordsBoard

--!strict
--[[
	HubAmenitiesBuilder
	Furnishes the Commercial Hub: a rubber jogging track, a playground,
	tiered spectator stands and benches.

	Purely decorative/ambient — nothing here is registered with
	ZoneHazardMonitor, none of it is a SpawnLocation, and none of it sits in
	the path of the existing hub fixtures. It exists to make the infield read
	as a place people spend time rather than a green disc with a spawn pad.

	## Placement rules everything here obeys

	1. Radii are fractions of HubGenerator's HUB_RADIUS (derived from
	   TrackGeometry), so a change to track dimensions moves the furniture
	   with the hub instead of leaving it floating over the road.
	2. Nothing is placed within CENTRE_KEEP_CLEAR_STUDS of the hub centre —
	   that is the spawn pad, and players must never materialise inside a
	   bench.
	3. Everything stands on the pavement, checked against
	   HubGenerator.IsOnPavement rather than against a radius copied to here.
	   The hub floor is a STADIUM, not a disc, so "distance from centre" is
	   not a containment test in the first place.
	4. The vendor stands sit at radius 124 flanking the curve directions; the
	   leaderboards are at 112 (straight sides) and 190 (curve ends), so the
	   two sets never share a bearing at a shared radius.

	All parts are anchored and CanCollide stays true only where a player is
	meant to stand on or be stopped by something; decorative trim is
	non-collidable so it can never wedge anyone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HubGenerator = require(script.Parent:WaitForChild("HubGenerator"))

-- Read from HubGenerator rather than re-derived. It used to be a duplicated
-- copy of the same formula, and the moment the disc's radius changed the two
-- disagreed about where the floor ends — which is exactly how the vendor
-- stands ended up standing on air.
local HUB_RADIUS = HubGenerator.HubRadius
local FLOOR_TOP_Y = HubGenerator.FloorTopY

local CENTRE_KEEP_CLEAR_STUDS = 22

local JOG_TRACK_INNER_RADIUS = HUB_RADIUS * 0.62
local JOG_TRACK_WIDTH = 14
local JOG_TRACK_SEGMENTS = 64

local HubAmenitiesBuilder = {}

local function newPart(parent: Instance, name: string, size: Vector3, cframe: CFrame, colour: Color3, material: Enum.Material, canCollide: boolean?) : BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = if canCollide == nil then true else canCollide
	part.Size = size
	part.CFrame = cframe
	part.Color = colour
	part.Material = material
	part.Parent = parent
	return part
end

-- A ring approximated by JOG_TRACK_SEGMENTS chords, the same way the track's
-- own curves are built from RoadChord parts. Each chord is sized to close the
-- gap with its neighbour exactly (the chord length of one step), so the ring
-- reads as continuous rather than as a dotted line of tangents.
local function buildJoggingTrack(parent: Instance, hubCFrame: CFrame)
	local centreRadius = JOG_TRACK_INNER_RADIUS + JOG_TRACK_WIDTH / 2
	local stepAngle = (math.pi * 2) / JOG_TRACK_SEGMENTS
	local chordLength = 2 * centreRadius * math.sin(stepAngle / 2) + 0.5

	for index = 0, JOG_TRACK_SEGMENTS - 1 do
		local angle = stepAngle * index
		local offset = Vector3.new(math.sin(angle) * centreRadius, 0, math.cos(angle) * centreRadius)
		local chordCFrame = hubCFrame
			* CFrame.new(offset + Vector3.new(0, FLOOR_TOP_Y + 0.1, 0))
			* CFrame.Angles(0, angle, 0)

		newPart(
			parent,
			"JogTrackChord",
			Vector3.new(JOG_TRACK_WIDTH, 0.2, chordLength),
			chordCFrame,
			Color3.fromRGB(178, 68, 52),
			Enum.Material.Pebble,
			false -- flush with the floor; collision would only add a lip to trip on
		)

		-- Lane stripe down the middle, every other chord, so the ring reads as
		-- a running track and not a red band.
		if index % 2 == 0 then
			newPart(
				parent,
				"JogTrackStripe",
				Vector3.new(0.6, 0.22, chordLength * 0.6),
				chordCFrame * CFrame.new(0, 0.02, 0),
				Color3.fromRGB(240, 240, 240),
				Enum.Material.SmoothPlastic,
				false
			)
		end
	end
end

local function buildBench(parent: Instance, cframe: CFrame)
	local bench = Instance.new("Model")
	bench.Name = "Bench"

	newPart(bench, "Seat", Vector3.new(10, 0.6, 3), cframe * CFrame.new(0, 2.5, 0), Color3.fromRGB(160, 110, 60), Enum.Material.WoodPlanks)
	newPart(bench, "Back", Vector3.new(10, 3, 0.6), cframe * CFrame.new(0, 4, -1.4), Color3.fromRGB(160, 110, 60), Enum.Material.WoodPlanks)
	for _, x in { -4.2, 4.2 } do
		newPart(bench, "Leg", Vector3.new(0.6, 2.5, 2.8), cframe * CFrame.new(x, 1.25, 0), Color3.fromRGB(70, 74, 82), Enum.Material.Metal)
	end

	bench.Parent = parent
end

-- Benches ring the jogging track, each turned to face the hub centre so they
-- look out over the infield rather than at the grass behind them.
local function buildBenches(parent: Instance, hubCFrame: CFrame)
	local benchCount = 10
	local radius = JOG_TRACK_INNER_RADIUS - 10
	for index = 0, benchCount - 1 do
		local angle = (math.pi * 2 / benchCount) * index
		local offset = Vector3.new(math.sin(angle) * radius, FLOOR_TOP_Y, math.cos(angle) * radius)
		local position = (hubCFrame * CFrame.new(offset)).Position
		local centre = Vector3.new(hubCFrame.Position.X, position.Y, hubCFrame.Position.Z)
		buildBench(parent, CFrame.lookAt(position, centre))
	end
end

-- Four banks of 5 rising tiers, on the far side of the hub from the
-- playground so the two do not compete for the same ground.
local function buildStands(parent: Instance, hubCFrame: CFrame)
	local tierCount = 5
	local tierHeight = 3
	local tierDepth = 5
	local standWidth = 46
	local baseRadius = HUB_RADIUS * 0.80

	for bankIndex = 0, 3 do
		local bankAngle = math.rad(45 + 90 * bankIndex)
		local stand = Instance.new("Model")
		stand.Name = "SpectatorStand"

		for tier = 0, tierCount - 1 do
			-- Each tier steps BACK as it rises, which is what gives a stand
			-- its rake and stops the row in front blocking the view.
			local radius = baseRadius + tier * tierDepth
			local offset = Vector3.new(math.sin(bankAngle) * radius, FLOOR_TOP_Y, math.cos(bankAngle) * radius)
			local position = (hubCFrame * CFrame.new(offset)).Position
			local centre = Vector3.new(hubCFrame.Position.X, position.Y, hubCFrame.Position.Z)
			local tierCFrame = CFrame.lookAt(position, centre)

			newPart(
				stand,
				"StandTier",
				Vector3.new(standWidth, tierHeight, tierDepth),
				tierCFrame * CFrame.new(0, tier * tierHeight + tierHeight / 2, 0),
				Color3.fromRGB(200, 200, 210),
				Enum.Material.Concrete
			)
			-- Seat strip along the front lip of each tier, alternating colours
			-- the way real stadium seating blocks do.
			newPart(
				stand,
				"StandSeats",
				Vector3.new(standWidth - 2, 0.8, 1.6),
				tierCFrame * CFrame.new(0, tier * tierHeight + tierHeight + 0.4, -tierDepth / 2 + 1),
				if tier % 2 == 0 then Color3.fromRGB(70, 130, 220) else Color3.fromRGB(240, 180, 60),
				Enum.Material.SmoothPlastic,
				false
			)
		end

		stand.Parent = parent
	end
end

local function buildPlayground(parent: Instance, hubCFrame: CFrame)
	local playground = Instance.new("Model")
	playground.Name = "Playground"

	local baseOffset = Vector3.new(-HUB_RADIUS * 0.34, FLOOR_TOP_Y, HUB_RADIUS * 0.34)
	local base = hubCFrame * CFrame.new(baseOffset)

	-- Sand pit floor.
	newPart(playground, "SandPit", Vector3.new(46, 0.4, 40), base * CFrame.new(0, 0.2, 0), Color3.fromRGB(226, 205, 152), Enum.Material.Sand, false)

	-- Slide: a climbable tower with a chute that actually meets its deck.
	--
	-- The chute's geometry is DERIVED from the deck rather than eyeballed:
	-- rise is the deck height, run is chosen, and the length and pitch fall
	-- out of them. A hand-picked angle is how the first version ended up
	-- sloping the wrong way and starting in mid-air — rotating about +X by a
	-- POSITIVE angle tilts the part's +Z end DOWN (right-hand rule: +Z -> -Y),
	-- and the first attempt used a negative one, which ramped it up into the
	-- sky instead of down to the sand.
	local towerHeight = 14
	local deckSize = 8
	local deckX, deckZ = -14, -10
	newPart(playground, "SlideTowerDeck", Vector3.new(deckSize, 0.8, deckSize), base * CFrame.new(deckX, towerHeight, deckZ), Color3.fromRGB(220, 90, 90), Enum.Material.SmoothPlastic)
	for _, x in { deckX - 3, deckX + 3 } do
		local post = Instance.new("TrussPart")
		post.Name = "SlideLadder"
		post.Anchored = true
		post.Size = Vector3.new(2, 2, towerHeight)
		post.CFrame = base * CFrame.new(x, towerHeight / 2, deckZ) * CFrame.Angles(math.rad(90), 0, 0)
		post.Parent = playground
	end

	local chuteRise = towerHeight - 0.5
	local chuteRun = 18
	local chuteLength = math.sqrt(chuteRise * chuteRise + chuteRun * chuteRun)
	local chutePitch = math.atan2(chuteRise, chuteRun)
	-- Starts at the deck's front edge and ends on the sand.
	local chuteStartZ = deckZ + deckSize / 2
	local chuteCentre = base * CFrame.new(deckX, 0.5 + chuteRise / 2, chuteStartZ + chuteRun / 2)
	local chute = newPart(
		playground,
		"Slide",
		Vector3.new(6, 0.6, chuteLength),
		chuteCentre * CFrame.Angles(chutePitch, 0, 0),
		Color3.fromRGB(240, 190, 70),
		Enum.Material.SmoothPlastic
	)
	chute.TopSurface = Enum.SurfaceType.Smooth
	-- Side rails, so it reads as a slide rather than as a ramp.
	for _, railX in { -3.2, 3.2 } do
		newPart(
			playground,
			"SlideRail",
			Vector3.new(0.5, 2, chuteLength),
			chuteCentre * CFrame.Angles(chutePitch, 0, 0) * CFrame.new(railX, 1, 0),
			Color3.fromRGB(220, 150, 50),
			Enum.Material.SmoothPlastic,
			false
		)
	end

	-- Swing set.
	local swingHeight = 12
	for _, x in { 8, 22 } do
		newPart(playground, "SwingPost", Vector3.new(1, swingHeight, 1), base * CFrame.new(x, swingHeight / 2, -8), Color3.fromRGB(80, 140, 210), Enum.Material.Metal)
	end
	newPart(playground, "SwingBeam", Vector3.new(15, 1, 1), base * CFrame.new(15, swingHeight, -8), Color3.fromRGB(80, 140, 210), Enum.Material.Metal)
	for _, x in { 11, 15, 19 } do
		newPart(playground, "SwingRope", Vector3.new(0.25, 6, 0.25), base * CFrame.new(x, swingHeight - 3, -8), Color3.fromRGB(60, 60, 60), Enum.Material.Fabric, false)
		newPart(playground, "SwingSeat", Vector3.new(3, 0.4, 1.4), base * CFrame.new(x, swingHeight - 6, -8), Color3.fromRGB(50, 50, 55), Enum.Material.SmoothPlastic)
	end

	-- Climbing frame: a truss cube, genuinely climbable for the same reason
	-- the leaderboard legs are.
	local frameSize = 12
	for _, corner in { Vector2.new(-1, -1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(1, 1) } do
		local post = Instance.new("TrussPart")
		post.Name = "ClimbFrame"
		post.Anchored = true
		post.Size = Vector3.new(2, 2, frameSize)
		post.CFrame = base
			* CFrame.new(corner.X * frameSize / 2 + 6, frameSize / 2, corner.Y * frameSize / 2 + 12)
			* CFrame.Angles(math.rad(90), 0, 0)
		post.Parent = playground
	end
	newPart(playground, "ClimbFrameTop", Vector3.new(frameSize + 2, 0.6, frameSize + 2), base * CFrame.new(6, frameSize, 12), Color3.fromRGB(120, 200, 130), Enum.Material.SmoothPlastic)

	playground.Parent = parent
end

-- ===== Vendor stands =====
--
-- Built from parts rather than inserted Creator Store models, for the same
-- reason StadiumBlimp is: this whole world is regenerated from code on every
-- server start, so an inserted model would sit outside Rojo's control, would
-- not survive a fresh place build, and is one moderation action away from
-- disappearing. Free ice-cream/hot-dog/balloon/flower models do exist and can
-- be swapped in later if a higher-fidelity look is wanted.
--
-- 124: the ring the curve-side leaderboards vacated when they moved out to
-- 190. Held at a literal rather than derived from HUB_RADIUS because it is a
-- LAYOUT decision about where the stands sit relative to the boards, not a
-- statement about where the pavement ends — deriving it is what previously
-- dragged the stands inward to 118 when the floor's half-width changed.
-- HubAmenitiesBuilder.Build asserts it stays on the pavement.
local STAND_RING_RADIUS = 124

type StandStyle = {
	Name: string,
	Sign: string,
	CounterColor: Color3,
	CanopyColor: Color3,
	Topper: "Cone" | "Umbrella" | "Balloons" | "Flowers",
}

local STAND_STYLES: { StandStyle } = {
	{ Name = "IceCreamStand", Sign = "ICE CREAM", CounterColor = Color3.fromRGB(250, 220, 235), CanopyColor = Color3.fromRGB(255, 145, 190), Topper = "Cone" },
	{ Name = "HotDogStand", Sign = "HOT DOGS", CounterColor = Color3.fromRGB(225, 70, 60), CanopyColor = Color3.fromRGB(250, 235, 210), Topper = "Umbrella" },
	{ Name = "BalloonStand", Sign = "BALLOONS", CounterColor = Color3.fromRGB(90, 160, 230), CanopyColor = Color3.fromRGB(120, 205, 240), Topper = "Balloons" },
	{ Name = "FlowerStand", Sign = "FLOWERS", CounterColor = Color3.fromRGB(150, 110, 70), CanopyColor = Color3.fromRGB(120, 200, 130), Topper = "Flowers" },
}

local BALLOON_COLORS = {
	Color3.fromRGB(235, 70, 70),
	Color3.fromRGB(250, 200, 60),
	Color3.fromRGB(80, 180, 240),
	Color3.fromRGB(140, 220, 130),
	Color3.fromRGB(200, 120, 235),
}

local FLOWER_COLORS = {
	Color3.fromRGB(240, 90, 120),
	Color3.fromRGB(250, 215, 90),
	Color3.fromRGB(180, 120, 235),
	Color3.fromRGB(250, 250, 250),
}

local function buildStandTopper(stand: Model, base: CFrame, style: StandStyle)
	if style.Topper == "Cone" then
		local cone = newPart(stand, "GiantCone", Vector3.new(4, 7, 4), base * CFrame.new(0, 13.5, 0), Color3.fromRGB(215, 165, 100), Enum.Material.Sand, false)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		-- Roblox's stock cone mesh; falls back to a block if unavailable,
		-- which is still a readable "something on top of the stand".
		mesh.MeshId = "rbxassetid://1033714"
		mesh.Scale = Vector3.new(4, 7, 4)
		mesh.Parent = cone
		newPart(stand, "Scoop", Vector3.new(4.5, 4.5, 4.5), base * CFrame.new(0, 18, 0), Color3.fromRGB(250, 220, 235), Enum.Material.SmoothPlastic, false).Shape = Enum.PartType.Ball
	elseif style.Topper == "Umbrella" then
		newPart(stand, "UmbrellaPole", Vector3.new(0.5, 6, 0.5), base * CFrame.new(0, 13, 0), Color3.fromRGB(80, 80, 88), Enum.Material.Metal, false)
		for index = 0, 5 do
			local angle = math.rad(60 * index)
			newPart(
				stand,
				"UmbrellaPanel",
				Vector3.new(7, 0.4, 3.4),
				base * CFrame.new(0, 15.6, 0) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -3.2) * CFrame.Angles(math.rad(-18), 0, 0),
				if index % 2 == 0 then Color3.fromRGB(225, 70, 60) else Color3.fromRGB(250, 235, 210),
				Enum.Material.Fabric,
				false
			)
		end
	elseif style.Topper == "Balloons" then
		for index, colour in BALLOON_COLORS do
			local angle = math.rad(72 * index)
			local offset = base * CFrame.new(math.sin(angle) * 2.2, 15 + (index % 3), math.cos(angle) * 2.2)
			newPart(stand, "BalloonString", Vector3.new(0.15, 5, 0.15), offset * CFrame.new(0, -3, 0), Color3.fromRGB(60, 60, 60), Enum.Material.Fabric, false)
			local balloon = newPart(stand, "Balloon", Vector3.new(3, 3.6, 3), offset, colour, Enum.Material.SmoothPlastic, false)
			balloon.Shape = Enum.PartType.Ball
		end
	else
		for index, colour in FLOWER_COLORS do
			local x = -3 + (index - 1) * 2
			newPart(stand, "FlowerStem", Vector3.new(0.3, 4, 0.3), base * CFrame.new(x, 12, 1), Color3.fromRGB(80, 150, 80), Enum.Material.Grass, false)
			local bloom = newPart(stand, "FlowerBloom", Vector3.new(2.2, 2.2, 2.2), base * CFrame.new(x, 14.2, 1), colour, Enum.Material.SmoothPlastic, false)
			bloom.Shape = Enum.PartType.Ball
		end
	end
end

local function buildStand(parent: Instance, base: CFrame, style: StandStyle)
	local stand = Instance.new("Model")
	stand.Name = style.Name

	-- Counter, closed at the back so it reads as a kiosk from every angle.
	newPart(stand, "Counter", Vector3.new(12, 5, 6), base * CFrame.new(0, 2.5, 0), style.CounterColor, Enum.Material.WoodPlanks)
	newPart(stand, "CounterTop", Vector3.new(13, 0.6, 7), base * CFrame.new(0, 5.3, 0), Color3.fromRGB(240, 240, 245), Enum.Material.SmoothPlastic)

	for _, x in { -5.5, 5.5 } do
		newPart(stand, "CanopyPost", Vector3.new(0.6, 7, 0.6), base * CFrame.new(x, 9, -2.5), Color3.fromRGB(90, 94, 106), Enum.Material.Metal)
	end

	-- Striped awning.
	for index = 0, 5 do
		newPart(
			stand,
			"CanopyStripe",
			Vector3.new(2.2, 0.5, 8),
			base * CFrame.new(-5.5 + index * 2.2, 12.4, -0.5),
			if index % 2 == 0 then style.CanopyColor else Color3.fromRGB(250, 250, 250),
			Enum.Material.Fabric,
			false
		)
	end

	local signBoard = newPart(stand, "SignBoard", Vector3.new(12, 3, 0.4), base * CFrame.new(0, 14.6, -0.5), Color3.fromRGB(30, 32, 42), Enum.Material.SmoothPlastic, false)
	-- Both faces, so the sign is legible whichever side a player walks up on
	-- — same reasoning as the leaderboards and the fan box boards.
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local surface = Instance.new("SurfaceGui")
		surface.Face = face
		surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surface.PixelsPerStud = 40
		surface.LightInfluence = 0
		surface.Parent = signBoard

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = style.Sign
		label.TextColor3 = style.CanopyColor
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.Parent = surface
	end

	buildStandTopper(stand, base, style)
	stand.Parent = parent
end

-- Placed in pairs flanking each CURVE direction (±Z), which is the ring the
-- leaderboards vacated. The straight directions (±X) are left clear: the
-- straight-side boards moved INWARD to radius 112 and would collide.
local function buildVendorStands(parent: Instance, hubCFrame: CFrame)
	local placements = { 20, -20, 160, 200 }
	for index, degrees in placements do
		local angle = math.rad(degrees)
		local offset = Vector3.new(math.sin(angle) * STAND_RING_RADIUS, FLOOR_TOP_Y, math.cos(angle) * STAND_RING_RADIUS)
		local position = (hubCFrame * CFrame.new(offset)).Position
		local centre = Vector3.new(hubCFrame.Position.X, position.Y, hubCFrame.Position.Z)
		buildStand(parent, CFrame.lookAt(position, centre), STAND_STYLES[index])
	end
end

function HubAmenitiesBuilder.Build(parent: Instance)
	local existing = parent:FindFirstChild("HubAmenities")
	if existing ~= nil then
		existing:Destroy()
	end

	local hubCFrame = HubGenerator.GetHubCFrame()
	if hubCFrame == nil then
		-- The hub has not been generated yet; without its centre every
		-- placement below would be relative to the world origin, which is a
		-- corner of the track rather than the infield.
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "HubAmenities"
	folder.Parent = parent

	buildJoggingTrack(folder, hubCFrame)
	buildBenches(folder, hubCFrame)
	buildStands(folder, hubCFrame)
	buildPlayground(folder, hubCFrame)
	buildVendorStands(folder, hubCFrame)

	-- Assertion rather than a comment: nothing may end up sitting on the
	-- spawn pad. Cheap to check once at build time, and the failure mode it
	-- prevents (spawning inside a bench) is one players would report as
	-- teleport bugs rather than as furniture.
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("BasePart") then
			local flat = Vector3.new(
				descendant.Position.X - hubCFrame.Position.X,
				0,
				descendant.Position.Z - hubCFrame.Position.Z
			)
			assert(
				flat.Magnitude >= CENTRE_KEEP_CLEAR_STUDS,
				`HubAmenitiesBuilder: {descendant.Name} is {math.floor(flat.Magnitude)} studs from the hub centre, inside the spawn keep-clear`
			)
			-- The other half of the same rule: furniture placed off the
			-- pavement stands at the floor's top face over terrain 2 studs
			-- below it, which is exactly the "floating" this hub has been
			-- reported for twice. Asked of HubGenerator so there is one
			-- definition of where the floor ends.
			assert(
				HubGenerator.IsOnPavement(descendant.Position),
				`HubAmenitiesBuilder: {descendant.Name} is off the hub pavement and would float`
			)
		end
	end
end

function HubAmenitiesBuilder.Init()
	HubAmenitiesBuilder.Build(workspace)
end

return HubAmenitiesBuilder

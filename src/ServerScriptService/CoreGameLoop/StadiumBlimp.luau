--!strict
--[[
	StadiumBlimp
	An advertising blimp circling high above the stadium.

	Built from parts rather than an inserted free model on purpose: a
	Creator Store model is one moderation action away from vanishing, and the
	audio pass earlier in this project already had to work around exactly that
	risk. A hull, a tail and two gondola fins are enough to read as a blimp at
	the distance it is actually seen from.

	## Anchored, moved by CFrame — not physics

	The blimp is `Anchored = true` and its whole model is re-pivoted every
	Heartbeat. An unanchored version would need constraints to hold altitude,
	would be shovable by any player who reached it, and would drift — the same
	class of problem the hazard bars needed AlignPosition/AlignOrientation to
	solve. Nothing about this needs to be physical, so it is not.

	It flies well above every piece of geometry in the world (the tallest
	things are the leaderboards at ~64 studs and the fan stands at ~23), so
	there is nothing for it to intersect and it never needs collision.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))

local HubGenerator = require(script.Parent:WaitForChild("HubGenerator"))

-- Outside the track (its outer edge is CurveRadius + SegmentWidth/2 = 216 at
-- current values) so the blimp circles the whole stadium rather than cutting
-- across the infield.
local ORBIT_RADIUS = TrackGeometry.CurveRadius + TrackGeometry.SegmentWidth / 2 + 90
local ORBIT_HEIGHT = 170
local ORBIT_PERIOD_SECONDS = 120
-- Gentle vertical bob, so it reads as flying rather than as a part on a rail.
local BOB_AMPLITUDE = 6
local BOB_PERIOD_SECONDS = 17

local StadiumBlimp = {}

local heartbeatConnection: RBXScriptConnection? = nil

local function buildBlimpModel(parent: Instance) : Model
	local model = Instance.new("Model")
	model.Name = "StadiumBlimp"

	local function newPart(name: string, size: Vector3, offset: CFrame, colour: Color3, shape: Enum.PartType?) : BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.Size = size
		part.CFrame = offset
		part.Color = colour
		part.Material = Enum.Material.SmoothPlastic
		if shape ~= nil then
			part.Shape = shape
		end
		part.Parent = model
		return part
	end

	local hull = newPart("Hull", Vector3.new(28, 28, 78), CFrame.new(), Color3.fromRGB(230, 70, 70), Enum.PartType.Ball)
	-- A Ball ignores non-uniform Size, so the cigar shape comes from a
	-- SpecialMesh scale instead.
	local hullMesh = Instance.new("SpecialMesh")
	hullMesh.MeshType = Enum.MeshType.Sphere
	hullMesh.Scale = Vector3.new(1, 1, 2.8)
	hullMesh.Parent = hull

	newPart("NoseCone", Vector3.new(10, 10, 10), CFrame.new(0, 0, -40), Color3.fromRGB(245, 245, 250), Enum.PartType.Ball)

	local gondola = newPart("Gondola", Vector3.new(10, 6, 20), CFrame.new(0, -17, 4), Color3.fromRGB(60, 64, 76))
	local gondolaCorner = Instance.new("SpecialMesh")
	gondolaCorner.MeshType = Enum.MeshType.Sphere
	gondolaCorner.Scale = Vector3.new(1, 0.8, 1)
	gondolaCorner.Parent = gondola

	-- Tail fins: vertical and horizontal, at the back.
	newPart("TailFinTop", Vector3.new(1.5, 18, 16), CFrame.new(0, 16, 36), Color3.fromRGB(245, 245, 250))
	newPart("TailFinLeft", Vector3.new(18, 1.5, 16), CFrame.new(-12, 0, 36), Color3.fromRGB(245, 245, 250))
	newPart("TailFinRight", Vector3.new(18, 1.5, 16), CFrame.new(12, 0, 36), Color3.fromRGB(245, 245, 250))

	-- Banner on both flanks, so the blimp says something from either side —
	-- the same both-faces reasoning the leaderboards use.
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local surface = Instance.new("SurfaceGui")
		surface.Name = `Banner_{face.Name}`
		surface.Face = face
		surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surface.PixelsPerStud = 20
		surface.LightInfluence = 0
		surface.Parent = hull

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "RACE BRAWLER"
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.Parent = surface
	end

	model.PrimaryPart = hull
	model.Parent = parent
	return model
end

function StadiumBlimp.Build(parent: Instance)
	local existing = parent:FindFirstChild("StadiumBlimp")
	if existing ~= nil then
		existing:Destroy()
	end
	if heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end

	local centre = (HubGenerator.GetHubCFrame() or CFrame.new(0, 0, 0)).Position
	local model = buildBlimpModel(parent)

	local startClock = os.clock()
	heartbeatConnection = RunService.Heartbeat:Connect(function()
		if model.Parent == nil then
			return
		end
		local elapsed = os.clock() - startClock
		local angle = (elapsed / ORBIT_PERIOD_SECONDS) * math.pi * 2
		local height = ORBIT_HEIGHT + math.sin((elapsed / BOB_PERIOD_SECONDS) * math.pi * 2) * BOB_AMPLITUDE
		local position = centre + Vector3.new(math.sin(angle) * ORBIT_RADIUS, height, math.cos(angle) * ORBIT_RADIUS)

		-- Face along the direction of travel: the tangent to the circle,
		-- which is the orbit position derivative — a quarter turn ahead of the
		-- radius vector.
		local tangent = Vector3.new(math.cos(angle), 0, -math.sin(angle))
		model:PivotTo(CFrame.lookAt(position, position + tangent))
	end)

	model.Destroying:Connect(function()
		if heartbeatConnection ~= nil then
			heartbeatConnection:Disconnect()
			heartbeatConnection = nil
		end
	end)
end

function StadiumBlimp.Init()
	StadiumBlimp.Build(workspace)
end

return StadiumBlimp

--!strict
--[[
	PracticeDummyService
	Spawns a few classic-noob rigs that run the oval like racers, so a solo
	session has something to aim at.

	Why this exists: every Target-cast skill needs another racer in range, and
	a solo Studio session has none — which has meant the targeting/acquisition
	step of the skill pipeline is the one part that has never been exercised
	for real. An earlier round worked around it by calling the effect
	application directly and skipping acquisition entirely, which proved the
	effects but not the aiming.

	These are real Humanoid rigs, not Parts with a Humanoid bolted on: R6
	geometry with proper Motor6D joints, so Roblox's own animator drives them
	and they walk, and so anything that reasons about a character (targeting
	radius, HumanoidRootPart lookups, collision) sees what it expects.

	They are deliberately NOT Players. Roblox has no way to fabricate a
	Player instance, so anything Player-keyed (ProfileManager,
	PlayerStateService, EffectStackManager, remotes) can never apply to them.
	That boundary is handled in the targeting layer — see
	TargetedSkillManager — rather than pretended away here.

	DUMMY_COUNT is the knob; set it to 0 to disable them entirely.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))

-- 0 = no dummies spawn, which is the shipped state. They exist purely as a
-- solo-testing rig (a Target-cast skill needs another racer in range and a
-- solo session has none), and were used to eyeball the cast VFX. Leaving
-- summoned NPCs in a live race would be wrong — they'd clutter the track and
-- read as real racers — so the spawn is off by default. Set to 2-3 to bring
-- them back for a testing session.
local DUMMY_COUNT = 0
local DUMMY_TAG = "PracticeDummy"
local DUMMY_WALK_SPEED = 12
local DUMMY_FOLDER_NAME = "PracticeDummies"
-- Below this the dummy has fallen off the track (or through a SkyRail gap)
-- and is respawned at the start line rather than left falling forever.
local DUMMY_RESET_Y = -30
local WAYPOINT_REACHED_STUDS = 18

-- Unstick thresholds. Humanoid:MoveTo is pure "walk toward this point" — it
-- has no pathfinding, so any real obstacle stops a dummy dead: confirmed
-- immediately on the first live run, where two of three walked into a
-- WaterDock pool and sat there in the Swimming state making no progress.
-- Rather than teach them to solve eight different themed hazards, they get a
-- two-stage escape: jump (clears ledges, pool rims and low walls), then, if
-- still pinned, skip to the next waypoint outright. They exist to be shot
-- at, not to race well.
local STUCK_MOVE_THRESHOLD_STUDS = 1
local STUCK_JUMP_AFTER_SECONDS = 2
local STUCK_SKIP_AFTER_SECONDS = 6

local PracticeDummyService = {}

local SKIN_COLOR = Color3.fromRGB(245, 205, 48)
local SHIRT_COLORS = {
	Color3.fromRGB(13, 105, 172),
	Color3.fromRGB(196, 40, 28),
	Color3.fromRGB(75, 151, 75),
}
local PANTS_COLOR = Color3.fromRGB(40, 127, 71)

local function makePart(name: string, size: Vector3, color: Color3, parent: Instance) : BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeJoint(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = part0
end

-- A standard R6 rig. The C0/C1 values are the stock Roblox R6 joint offsets;
-- getting them right is what makes the Humanoid actually animate rather than
-- sliding around as a rigid lump.
local function buildNoob(dummyIndex: number) : Model
	local model = Instance.new("Model")
	model.Name = `PracticeDummy_{dummyIndex}`

	local shirtColor = SHIRT_COLORS[((dummyIndex - 1) % #SHIRT_COLORS) + 1]

	local rootPart = makePart("HumanoidRootPart", Vector3.new(2, 2, 1), SKIN_COLOR, model)
	rootPart.Transparency = 1
	rootPart.CanCollide = false

	local torso = makePart("Torso", Vector3.new(2, 2, 1), shirtColor, model)
	local head = makePart("Head", Vector3.new(2, 1, 1), SKIN_COLOR, model)
	local leftArm = makePart("Left Arm", Vector3.new(1, 2, 1), SKIN_COLOR, model)
	local rightArm = makePart("Right Arm", Vector3.new(1, 2, 1), SKIN_COLOR, model)
	local leftLeg = makePart("Left Leg", Vector3.new(1, 2, 1), PANTS_COLOR, model)
	local rightLeg = makePart("Right Leg", Vector3.new(1, 2, 1), PANTS_COLOR, model)

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	local headMesh = Instance.new("SpecialMesh")
	headMesh.MeshType = Enum.MeshType.Head
	headMesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	headMesh.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.WalkSpeed = DUMMY_WALK_SPEED
	humanoid.DisplayName = `Racer {dummyIndex}`
	humanoid.Parent = model

	local halfPi = math.pi / 2
	makeJoint("RootJoint", rootPart, torso,
		CFrame.new(0, 0, 0) * CFrame.Angles(-halfPi, 0, math.pi),
		CFrame.new(0, 0, 0) * CFrame.Angles(-halfPi, 0, math.pi))
	makeJoint("Neck", torso, head,
		CFrame.new(0, 1, 0) * CFrame.Angles(-halfPi, 0, math.pi),
		CFrame.new(0, -0.5, 0) * CFrame.Angles(-halfPi, 0, math.pi))
	makeJoint("Right Shoulder", torso, rightArm,
		CFrame.new(1, 0.5, 0) * CFrame.Angles(0, halfPi, 0),
		CFrame.new(-0.5, 0.5, 0) * CFrame.Angles(0, halfPi, 0))
	makeJoint("Left Shoulder", torso, leftArm,
		CFrame.new(-1, 0.5, 0) * CFrame.Angles(0, -halfPi, 0),
		CFrame.new(0.5, 0.5, 0) * CFrame.Angles(0, -halfPi, 0))
	makeJoint("Right Hip", torso, rightLeg,
		CFrame.new(1, -1, 0) * CFrame.Angles(0, halfPi, 0),
		CFrame.new(0.5, 1, 0) * CFrame.Angles(0, halfPi, 0))
	makeJoint("Left Hip", torso, leftLeg,
		CFrame.new(-1, -1, 0) * CFrame.Angles(0, -halfPi, 0),
		CFrame.new(-0.5, 1, 0) * CFrame.Angles(0, -halfPi, 0))

	model.PrimaryPart = rootPart
	CollectionService:AddTag(model, DUMMY_TAG)
	model:SetAttribute("IsPracticeDummy", true)
	return model
end

-- The checkpoint triggers double as a ready-made waypoint ring: they sit at
-- every segment exit, in order, on the real generated track. Reading them
-- rather than re-deriving a path means the dummies automatically follow
-- whatever TrackGenerator last built.
local function waypointCFrames() : { CFrame }
	local waypoints: { CFrame } = {}
	local track = workspace:FindFirstChild("Track")
	local checkpoints = track and track:FindFirstChild("Checkpoints")
	if checkpoints == nil then
		return waypoints
	end

	for ordinal = 1, #TrackBlueprints.OvalSegments do
		local trigger = checkpoints:FindFirstChild(`CheckpointTrigger_{ordinal}`)
		if trigger ~= nil and trigger:IsA("BasePart") then
			waypoints[ordinal] = trigger.CFrame
		end
	end

	return waypoints
end

local function spawnCFrameFor(dummyIndex: number) : CFrame
	-- Spread across the track's width at the start line so they don't spawn
	-- inside each other (the same clustering problem the Grand Prix start
	-- grid solves for real players).
	local lateral = (dummyIndex - (DUMMY_COUNT + 1) / 2) * 10
	return CFrame.new(lateral, TrackGeometry.RoadThickness / 2 + 4, -8)
end

function PracticeDummyService.Init()
	if DUMMY_COUNT <= 0 then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = DUMMY_FOLDER_NAME
	folder.Parent = workspace

	type DummyRecord = {
		Model: Model,
		Humanoid: Humanoid,
		Root: BasePart,
		Waypoint: number,
		LastPosition: Vector3,
		StuckSeconds: number,
	}
	local dummies: { DummyRecord } = {}

	for index = 1, DUMMY_COUNT do
		local model = buildNoob(index)
		model.Parent = folder
		model:PivotTo(spawnCFrameFor(index))
		local root = model.PrimaryPart :: BasePart
		table.insert(dummies, {
			Model = model,
			Humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid,
			Root = root,
			-- Staggered so they don't run in lockstep.
			Waypoint = ((index - 1) % #TrackBlueprints.OvalSegments) + 1,
			LastPosition = root.Position,
			StuckSeconds = 0,
		})
	end

	-- Driven on a slow loop rather than Heartbeat: Humanoid:MoveTo already
	-- steers every frame on its own, so this only has to hand it the next
	-- waypoint when the current one is reached.
	task.spawn(function()
		while true do
			local waypoints = waypointCFrames()
			if #waypoints > 0 then
				for _, dummy in dummies do
					if dummy.Root.Parent == nil then
						continue
					end

					if dummy.Root.Position.Y < DUMMY_RESET_Y then
						dummy.Model:PivotTo(spawnCFrameFor(1))
						continue
					end

					local target = waypoints[dummy.Waypoint]
					if target == nil then
						continue
					end

					if (dummy.Root.Position - target.Position).Magnitude <= WAYPOINT_REACHED_STUDS then
						dummy.Waypoint = if dummy.Waypoint >= #waypoints then 1 else dummy.Waypoint + 1
						target = waypoints[dummy.Waypoint]
					end

					-- Stuck detection, measured between ticks.
					local moved = (dummy.Root.Position - dummy.LastPosition).Magnitude
					dummy.LastPosition = dummy.Root.Position
					if moved < STUCK_MOVE_THRESHOLD_STUDS then
						dummy.StuckSeconds += 0.5
					else
						dummy.StuckSeconds = 0
					end

					if dummy.StuckSeconds >= STUCK_SKIP_AFTER_SECONDS then
						-- Jumping didn't free it; hand it the next waypoint and
						-- put it there, so it can't sit in a pool forever.
						dummy.Waypoint = if dummy.Waypoint >= #waypoints then 1 else dummy.Waypoint + 1
						dummy.Model:PivotTo(waypoints[dummy.Waypoint] * CFrame.new(0, 5, 0))
						dummy.StuckSeconds = 0
						continue
					elseif dummy.StuckSeconds >= STUCK_JUMP_AFTER_SECONDS then
						dummy.Humanoid.Jump = true
					end

					dummy.Humanoid:MoveTo(target.Position)
				end
			end
			task.wait(0.5)
		end
	end)
end

function PracticeDummyService.GetDummyTag() : string
	return DUMMY_TAG
end

return PracticeDummyService

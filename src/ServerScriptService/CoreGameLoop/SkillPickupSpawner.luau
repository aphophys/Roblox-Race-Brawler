--!strict
--[[
	SkillPickupSpawner
	New module (not in the original directory tree) — spawns 3 test-skill
	pickup markers at each of the 8 checkpoints (24 total), letting players
	try skills they don't own. Picking one up uses the same single carry
	slot as Fan Payloads (CarryItemService), is instant (only Fan Payloads
	got the 3-second spec), and casts the skill at Level 1 on release
	(CarryItemService.ReleaseTrackItem -> the relevant manager's
	CastSkillDirect).

	Each marker gets a freshly-random skill assigned every time it
	respawns (30s after being taken), for variety across attempts.
	Independently walks the same TrackBlueprints/TrackGeometry chain as
	the other generators (not reading TrackGenerator's built output), so
	it stays correct if segments are randomized later.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

local PICKUPS_PER_CHECKPOINT = 3
local PICKUP_INTERACT_RADIUS = 9
local PICKUP_VISUAL_SIZE = Vector3.new(3, 3, 3)
local LATERAL_SPACING = 6 -- studs between the 3 pickups at one checkpoint
local RESPAWN_SECONDS = 30

export type SkillPickupEntry = {
	Part: BasePart,
	Position: Vector3,
	Available: boolean,
	SkillId: string,
}

local SkillPickupSpawner = {}

local pickups: { SkillPickupEntry } = {}
local allSkillIds: { string } = {}

local function pickRandomSkillId() : string
	return allSkillIds[math.random(1, #allSkillIds)]
end

local function surfaceOffsetY() : number
	return TrackGeometry.RoadThickness / 2 + PICKUP_VISUAL_SIZE.Y / 2 + 1
end

local COLOR_BY_CAST_TYPE: { [string]: Color3 } = {
	Target = Color3.fromRGB(77, 171, 247),
	Global = Color3.fromRGB(178, 102, 255),
	Self = Color3.fromRGB(76, 217, 100),
}

local function buildMarker(parent: Instance, entryCFrame: CFrame, lateralIndex: number) : SkillPickupEntry
	local skillId = pickRandomSkillId()
	local skillDefinition = SkillTrees[skillId]

	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.Shape = Enum.PartType.Cylinder
	marker.Material = Enum.Material.Neon
	marker.Color = COLOR_BY_CAST_TYPE[skillDefinition.CastType] or Color3.fromRGB(255, 255, 255)
	marker.Size = PICKUP_VISUAL_SIZE
	marker.CFrame = entryCFrame
		* CFrame.new((lateralIndex - 2) * LATERAL_SPACING, surfaceOffsetY(), 0)
		* CFrame.Angles(0, 0, math.rad(90)) -- Cylinder's default axis is local X; stand it upright
	marker.Name = `SkillPickup_{skillId}`
	marker.Parent = parent

	return { Part = marker, Position = marker.CFrame.Position, Available = true, SkillId = skillId }
end

-- Returns (index, skillId) of the nearest available skill pickup within
-- range, or (nil, nil).
function SkillPickupSpawner.GetNearbySkillPickup(position: Vector3) : (number?, string?)
	for index, entry in pickups do
		if entry.Available and (entry.Position - position).Magnitude <= PICKUP_INTERACT_RADIUS then
			return index, entry.SkillId
		end
	end
	return nil, nil
end

function SkillPickupSpawner.ConsumePickup(index: number)
	local entry = pickups[index]
	if entry == nil or not entry.Available then
		return
	end

	entry.Available = false
	entry.Part.Transparency = 1
	entry.Part.CanCollide = false

	task.delay(RESPAWN_SECONDS, function()
		if entry.Part.Parent == nil then
			return
		end
		-- Re-roll the skill on respawn for variety across attempts.
		entry.SkillId = pickRandomSkillId()
		entry.Part.Name = `SkillPickup_{entry.SkillId}`
		local skillDefinition = SkillTrees[entry.SkillId]
		entry.Part.Color = COLOR_BY_CAST_TYPE[skillDefinition.CastType] or Color3.fromRGB(255, 255, 255)
		entry.Part.Transparency = 0
		entry.Available = true
	end)
end

function SkillPickupSpawner.Generate(parent: Instance) : Folder
	pickups = {}
	allSkillIds = {}
	for skillId in SkillTrees do
		table.insert(allSkillIds, skillId)
	end

	local existing = parent:FindFirstChild("SkillPickups")
	if existing ~= nil then
		existing:Destroy()
	end

	local pickupsFolder = Instance.new("Folder")
	pickupsFolder.Name = "SkillPickups"

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		for lateralIndex = 1, PICKUPS_PER_CHECKPOINT do
			table.insert(pickups, buildMarker(pickupsFolder, currentCFrame, lateralIndex))
		end

		if segment.SegmentType == "Straight" then
			local _, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, 1)
			currentCFrame = exitCFrame
		else
			local _, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, 1)
			currentCFrame = exitCFrame
		end
	end

	pickupsFolder.Parent = parent
	return pickupsFolder
end

function SkillPickupSpawner.Init()
	SkillPickupSpawner.Generate(workspace)
end

return SkillPickupSpawner

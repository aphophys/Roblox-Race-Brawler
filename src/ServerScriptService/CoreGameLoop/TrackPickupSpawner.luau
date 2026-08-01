--!strict
--[[
	TrackPickupSpawner
	New module (not in the original directory tree) — spawns real, visible
	Fan Payload pickup markers (one per non-deposit Straight segment) and
	one Fan Drop Zone, with real consume/respawn state: a picked-up marker
	hides and becomes unavailable for RESPAWN_SECONDS, then reappears.

	Fixed this round: the deposit zone was built at Y = 0.5 with height 1,
	which put it entirely inside/co-planar with the road slab's top surface
	(RoadThickness/2 = 1) — effectively invisible, embedded in the road.
	Now built clearly above the surface, same pattern as pickup markers.

	Proximity is spatial-distance based (checked by CarryItemService's
	periodic loop), not .Touched, per project convention.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local ItemData = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("ItemData"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))

local PICKUP_INTERACT_RADIUS = 10
local DEPOSIT_INTERACT_RADIUS = 18
local PICKUP_VISUAL_SIZE = Vector3.new(4, 4, 4)
local DEPOSIT_ZONE_VISUAL_SIZE = Vector3.new(TrackGeometry.SegmentWidth * 0.8, 1, 20)
local RESPAWN_SECONDS = 30

export type PickupEntry = {
	Part: BasePart,
	Position: Vector3,
	Available: boolean,
}

local TrackPickupSpawner = {}

local pickups: { PickupEntry } = {}
local depositZonePosition: Vector3? = nil
local pickupsFolder: Folder? = nil

local function surfaceOffsetY(visualHeight: number) : number
	return TrackGeometry.RoadThickness / 2 + visualHeight / 2 + 1
end

local function buildPickupMarker(parent: Instance, roadPosition: Vector3) : PickupEntry
	local marker = Instance.new("Part")
	marker.Anchored = true
	marker.CanCollide = false
	marker.Shape = Enum.PartType.Ball
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(255, 215, 0)
	marker.Size = PICKUP_VISUAL_SIZE
	marker.Position = roadPosition + Vector3.new(0, surfaceOffsetY(PICKUP_VISUAL_SIZE.Y), 0)
	marker.Name = "FanPayloadPickup"
	marker.Parent = parent

	return { Part = marker, Position = marker.Position, Available = true }
end

local function buildDepositZone(parent: Instance, entryCFrame: CFrame)
	local zone = Instance.new("Part")
	zone.Anchored = true
	zone.CanCollide = false
	zone.Transparency = 0.3
	zone.Material = Enum.Material.Neon
	zone.Color = Color3.fromRGB(80, 220, 255)
	zone.Size = DEPOSIT_ZONE_VISUAL_SIZE
	zone.CFrame = entryCFrame * CFrame.new(0, surfaceOffsetY(DEPOSIT_ZONE_VISUAL_SIZE.Y), 0)
	zone.Name = "FanDropZone"
	zone.Parent = parent

	depositZonePosition = zone.Position
end

-- Returns the index of the nearest AVAILABLE pickup within range, or nil.
-- Pass the returned index to ConsumePickup on a successful pickup.
function TrackPickupSpawner.GetNearbyPickup(position: Vector3) : number?
	for index, entry in pickups do
		if entry.Available and (entry.Position - position).Magnitude <= PICKUP_INTERACT_RADIUS then
			return index
		end
	end
	return nil
end

-- True if `index` is still available (re-check after any waiting period —
-- e.g. CarryItemService's 3-second pickup channel — in case someone else
-- took it or it respawned mid-wait in a way that matters).
function TrackPickupSpawner.IsPickupAvailable(index: number) : boolean
	local entry = pickups[index]
	return entry ~= nil and entry.Available
end

-- Marks a pickup taken: hides it and schedules it to reappear after
-- RESPAWN_SECONDS.
function TrackPickupSpawner.ConsumePickup(index: number)
	local entry = pickups[index]
	if entry == nil or not entry.Available then
		return
	end

	entry.Available = false
	entry.Part.Transparency = 1
	entry.Part.CanCollide = false

	task.delay(RESPAWN_SECONDS, function()
		if entry.Part.Parent ~= nil then
			entry.Available = true
			entry.Part.Transparency = 0
		end
	end)
end

-- Spawns a brand-new, always-available pickup marker at `position` and adds
-- it to the same registry the static markers live in — so a dropped Fan
-- Payload (kicked out of bounds, stunned, or the carrier left the game)
-- behaves exactly like any other pickup from then on: available immediately,
-- pick-able by anyone, and follows the normal consume/respawn cycle once
-- someone takes it. Used by CarryItemService.DropAtLocation.
function TrackPickupSpawner.SpawnDroppedPickup(position: Vector3)
	if pickupsFolder == nil then
		return
	end
	table.insert(pickups, buildPickupMarker(pickupsFolder, position))
end

function TrackPickupSpawner.IsNearDepositZone(position: Vector3) : boolean
	if depositZonePosition == nil then
		return false
	end
	return (depositZonePosition - position).Magnitude <= DEPOSIT_INTERACT_RADIUS
end

function TrackPickupSpawner.GetFanPayloadValue() : number
	return ItemData.FanPayloadTypes.Standard.FanValue
end

function TrackPickupSpawner.Generate(parent: Instance) : Folder
	pickups = {}
	depositZonePosition = nil
	pickupsFolder = nil

	local existing = parent:FindFirstChild("TrackPickups")
	if existing ~= nil then
		existing:Destroy()
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = "TrackPickups"

	local currentCFrame = CFrame.new(0, 0, 0)
	local isFirstStraight = true

	for _, segment in TrackBlueprints.OvalSegments do
		if segment.SegmentType == "Straight" then
			local samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, 1)
			if isFirstStraight then
				buildDepositZone(newFolder, currentCFrame)
				isFirstStraight = false
			else
				table.insert(pickups, buildPickupMarker(newFolder, samples[1].Position))
			end
			currentCFrame = exitCFrame
		else
			local _, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, 1)
			currentCFrame = exitCFrame
		end
	end

	newFolder.Parent = parent
	pickupsFolder = newFolder
	return newFolder
end

function TrackPickupSpawner.Init()
	TrackPickupSpawner.Generate(workspace)
end

return TrackPickupSpawner

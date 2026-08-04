--!strict
--[[
	ZoneHazardMonitor
	New module — shared "standing inside this volume costs a life" registry,
	used by Volcanic magma pools and NeonCircuit's landed electric blocks
	(ThemeHazardBuilder). One polling loop instead of a bespoke loop per
	hazard instance, so an arbitrary number of zones across all 8 track
	segments stays cheap.

	Detection is the same pure CFrame-space point-in-box test
	CheckpointValidator.isInsideTrigger already uses — no physics query, so
	nothing about a zone Part's CanCollide/CanQuery (or any other part in
	the world) affects the result. Duplicated locally rather than shared
	via a new util module: it's 6 lines and CheckpointValidator has no
	reason to expose it.

	No extra per-zone cooldown is needed: ArcadeManager.HandleTrackViolation
	respawns the player at their last checkpoint immediately
	(synchronously), so by the next 0.5s poll they're already gone from the
	zone — the exact same self-limiting behavior TrackBoundaryMonitor
	already relies on for its own violation trigger.
]]

local Players = game:GetService("Players")

local ArcadeManager = require(script.Parent:WaitForChild("ArcadeManager"))
local SoundDirector = require(script.Parent:WaitForChild("SoundDirector"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local CHECK_INTERVAL_SECONDS = 0.5

local ZoneHazardMonitor = {}

local registeredZones: { [BasePart]: boolean } = {}

local function isInsideZone(position: Vector3, zonePart: BasePart) : boolean
	local localPosition = zonePart.CFrame:PointToObjectSpace(position)
	local halfSize = zonePart.Size / 2
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y
		and math.abs(localPosition.Z) <= halfSize.Z
end

-- Registers `part` as a life-costing zone. Safe to call on a part that's
-- CanCollide = false / Transparency = 1 — detection is pure CFrame math,
-- not a physics query.
function ZoneHazardMonitor.RegisterZone(part: BasePart)
	registeredZones[part] = true
	part.Destroying:Connect(function()
		registeredZones[part] = nil
	end)
end

function ZoneHazardMonitor.UnregisterZone(part: BasePart)
	registeredZones[part] = nil
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function checkPlayer(player: Player)
	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		return
	end

	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local position = rootPart.Position
	for zonePart in registeredZones do
		if zonePart.Parent ~= nil and isInsideZone(position, zonePart) then
			-- The burn is what distinguishes "the magma/the block got me" from
			-- the other way to lose a life (falling off the track), which
			-- HandleTrackViolation cannot tell apart from in there. 3D and on
			-- the zone, so other racers hear where it happened and get a
			-- second-hand warning about that spot.
			SoundDirector.PlayAtPart(zonePart, "HazardBurn")
			ArcadeManager.HandleTrackViolation(player)
			return
		end
	end
end

function ZoneHazardMonitor.Init()
	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				checkPlayer(player)
			end
			task.wait(CHECK_INTERVAL_SECONDS)
		end
	end)
end

return ZoneHazardMonitor

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

	Two detection routes, because one is not enough for a hazard that MOVES:

	- The 0.5s poll below ("are you standing in it"), which is all a static
	  zone like Volcanic's magma ever needed.
	- ReportContact ("it hit you"), for the falling blocks. A block is
	  CanCollide, so the physics solver ejects a player the instant it lands
	  on them — they are genuinely inside the zone for well under one poll
	  interval. Measured on the shipped hazard before any change: a block
	  landing squarely on a stationary player cost a life 0 times out of 4,
	  while dwelling inside an already-landed one cost a life 2 times out of
	  4. Being hit was the LEAST reliable way to lose a life, on both
	  NeonCircuit and Classic, which is the opposite of what the hazard reads
	  as.

	A cooldown is therefore now required, where the docstring used to say it
	was not. That old reasoning (HandleTrackViolation respawns synchronously,
	so the next poll finds the player gone) holds for polling and only for
	polling. Contact fires once per LIMB — measured ~20 events in a single
	frame — so without VIOLATION_COOLDOWN_SECONDS one block drains every life
	at once, eliminates the player, times out, refills them and returns them
	to the Hub, which looks exactly like the hazard doing nothing.
]]

local Players = game:GetService("Players")

local ArcadeManager = require(script.Parent:WaitForChild("ArcadeManager"))
local SoundDirector = require(script.Parent:WaitForChild("SoundDirector"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local CHECK_INTERVAL_SECONDS = 0.5

-- One hazard event costs ONE life, however many contacts it generates. See the
-- module docstring for the measured ~20-events-per-impact this exists to absorb.
-- Long enough to also cover the respawn that HandleTrackViolation performs, so
-- the player is never charged again for the block they were just moved away from.
local VIOLATION_COOLDOWN_SECONDS = 1.5

local ZoneHazardMonitor = {}

local registeredZones: { [BasePart]: boolean } = {}
local lastViolationClock: { [Player]: number } = {}

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

-- The single place a hazard volume takes a life. Both detection routes funnel
-- through here so the InRace gate, the burn and the cooldown cannot drift apart
-- between them — and so a block that both hits you AND is polled while you are
-- inside it still only costs one life.
local function registerViolation(player: Player, sourcePart: BasePart)
	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		return
	end

	local now = os.clock()
	local last = lastViolationClock[player]
	if last ~= nil and now - last < VIOLATION_COOLDOWN_SECONDS then
		return
	end
	lastViolationClock[player] = now

	-- The burn is what distinguishes "the magma/the block got me" from the
	-- other way to lose a life (falling off the track), which
	-- HandleTrackViolation cannot tell apart from in there. 3D and on the
	-- hazard, so other racers hear where it happened and get a second-hand
	-- warning about that spot.
	SoundDirector.PlayAtPart(sourcePart, "HazardBurn")
	ArcadeManager.HandleTrackViolation(player)
end

local function checkPlayer(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local position = rootPart.Position
	for zonePart in registeredZones do
		if zonePart.Parent ~= nil and isInsideZone(position, zonePart) then
			registerViolation(player, zonePart)
			return
		end
	end
end

-- Event-driven route, for a hazard that can HIT a player rather than only be
-- stood in. Call from a hazard's own .Touched handler; everything about whether
-- it actually costs a life is decided here, not at the call site.
function ZoneHazardMonitor.ReportContact(player: Player, sourcePart: BasePart)
	-- Same player object, same instant, both sources of truth.
	registerViolation(player, sourcePart)
end

-- Resolves whatever a .Touched handler was handed to the player it belongs to,
-- or nil for scenery. Lives here so every hazard that wants contact detection
-- agrees on what counts as hitting a player.
function ZoneHazardMonitor.PlayerFromTouch(touchedPart: BasePart) : Player?
	local character = touchedPart:FindFirstAncestorOfClass("Model")
	if character == nil or character:FindFirstChildOfClass("Humanoid") == nil then
		return nil
	end
	return Players:GetPlayerFromCharacter(character)
end

function ZoneHazardMonitor.Init()
	Players.PlayerRemoving:Connect(function(player: Player)
		lastViolationClock[player] = nil
	end)

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

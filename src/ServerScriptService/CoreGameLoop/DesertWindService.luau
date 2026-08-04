--!strict
--[[
	DesertWindService
	Desert theme's wind: it "will either push (speed up player if from
	behind) or slow down if from the front."

	The wind is CONSTANT while you are on a Desert segment — it used to be an
	occasional gust every 10-20s, which meant most crossings had no wind at
	all and the theme played identically to a plain road. What varies now is
	the DIRECTION: normally a headwind opposing the direction of travel (so
	racers are slowed), periodically reversing for a few seconds into a
	tailwind that speeds them up.

	Deliberately does NOT apply a raw AssemblyLinearVelocity impulse: this
	session already discovered (SelfSkillManager's DashSelf/
	ChargedJumpForward) that Humanoid's own movement controller continuously
	re-drives HORIZONTAL velocity toward MoveDirection * WalkSpeed every
	physics step, stomping a one-off raw velocity write within a fraction
	of a second — the exact same problem a wind push would hit. Instead
	this goes through MovementModifier — the proven-reliable mechanism, not a
	new one.

	It uses SetEnvironmentSpeedMultiplier, NOT SetWalkSpeedOverride. It did
	originally use the override, copying DashSelf, and that was a real bug
	once the wind became constant: an override suppresses the whole
	effect-driven recompute for as long as it lasts, so **every buff and
	debuff was silently ignored for anyone on a Desert segment** — a slow cast
	on a player in a headwind did nothing at all. An override is only ever
	right for something lasting a fraction of a second, like Dash's forced
	run. Weather is a multiplier.

	The "from behind" / "from the front" read: wind always blows along a
	Desert segment's own fixed travel direction (its forward vector, same
	source TrackBoundaryMonitor already samples from TrackPieceBuilder).
	Comparing that against the player's OWN current facing (LookVector)
	via dot product gives the tailwind/headwind sign — same-direction
	(running with the wind) boosts, opposing (running into it) slows.

	Discovers which live segments are currently Desert-themed by scanning
	workspace.Track for the ThemeId/SegmentIndex attributes TrackGenerator
	sets on every piece (see ThemeHazardBuilder) — no coupling to
	TrackGenerator's internal random-theme-picking state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local TrackPieceBuilder = require(script.Parent:WaitForChild("TrackPieceBuilder"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local MovementModifier = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("MovementModifier"))

-- The wind is now CONSTANT, not an occasional gust: a Desert segment should
-- feel like a Desert segment the whole time you're on it, and a gust every
-- 10-20s meant most crossings had no wind at all. The loop re-applies on a
-- short cycle (shorter than WIND_DURATION_SECONDS, so the override never
-- lapses between applications and the effect reads as continuous rather
-- than pulsing).
local WIND_REAPPLY_SECONDS = 1
local WIND_DURATION_SECONDS = 2.5

-- What changes over time is the DIRECTION, not whether there's wind. Most of
-- the time it blows against the direction of travel (a headwind, so racers
-- are slowed); every so often it reverses for REVERSAL_DURATION_SECONDS and
-- becomes a tailwind that speeds them up instead. Whether any individual
-- player is sped up or slowed still comes from their own facing vs the wind
-- (see applyGust), so running backwards through a headwind still pushes you.
local WIND_REVERSAL_MIN_INTERVAL_SECONDS = 12
local WIND_REVERSAL_MAX_INTERVAL_SECONDS = 22
local WIND_REVERSAL_DURATION_SECONDS = 5

-- Multipliers, not absolute speeds. Same felt strength as the old
-- 16*1.6 / 16*0.6, but expressed as a factor so a slow, a speed boost and
-- the wind all compose instead of the last writer winning.
local WIND_TAILWIND_MULTIPLIER = 1.6
local WIND_HEADWIND_MULTIPLIER = 0.6
local GUST_RADIUS_STUDS = 100

local DesertWindService = {}

-- SegmentIndex -> {Center: CFrame, Forward: Vector3}, built once from the
-- same deterministic segment walk TrackGenerator/TrackBoundaryMonitor use
-- (segment positions are fixed; only which theme lands where is
-- randomized per generation).
local segmentGeometryByIndex: { [number]: { Center: CFrame, Forward: Vector3 } } = {}

local function buildSegmentGeometry()
	segmentGeometryByIndex = {}
	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local exitCFrame: CFrame
		if segment.SegmentType == "Straight" then
			local _, exit = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, 1)
			exitCFrame = exit
		else
			local _, exit = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, 1)
			exitCFrame = exit
		end

		local center = currentCFrame:Lerp(exitCFrame, 0.5)
		segmentGeometryByIndex[segment.SegmentIndex] = { Center = center, Forward = center.LookVector }
		currentCFrame = exitCFrame
	end
end

-- Live Desert-themed segment indices this generation, read off
-- workspace.Track's piece attributes (set by ThemeHazardBuilder's caller
-- in TrackGenerator).
local function findLiveDesertSegmentIndices() : { number }
	local indices: { number } = {}
	local track = workspace:FindFirstChild("Track")
	if track == nil then
		return indices
	end

	for _, piece in track:GetChildren() do
		if piece:GetAttribute("ThemeId") == "Desert" then
			local segmentIndex = piece:GetAttribute("SegmentIndex")
			if typeof(segmentIndex) == "number" then
				table.insert(indices, segmentIndex)
			end
		end
	end

	return indices
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function applyGust(center: CFrame, forward: Vector3)
	for _, player in Players:GetPlayers() do
		if PlayerStateService.GetState(player) ~= PlayerState.InRace then
			continue
		end

		local rootPart = getRootPart(player)
		if rootPart == nil then
			continue
		end

		if (rootPart.Position - center.Position).Magnitude > GUST_RADIUS_STUDS then
			continue
		end

		local alignment = rootPart.CFrame.LookVector:Dot(forward)
		local windMultiplier = if alignment >= 0 then WIND_TAILWIND_MULTIPLIER else WIND_HEADWIND_MULTIPLIER
		MovementModifier.SetEnvironmentSpeedMultiplier(player, windMultiplier, WIND_DURATION_SECONDS)
	end
end

-- true while the wind is temporarily blowing WITH the direction of travel.
local isReversed = false

-- Owns nothing but the direction flag, on its own cycle, so the constant
-- wind loop below never has to care when a reversal starts or ends.
local function reversalLoop()
	while true do
		task.wait(WIND_REVERSAL_MIN_INTERVAL_SECONDS + math.random() * (WIND_REVERSAL_MAX_INTERVAL_SECONDS - WIND_REVERSAL_MIN_INTERVAL_SECONDS))
		isReversed = true
		task.wait(WIND_REVERSAL_DURATION_SECONDS)
		isReversed = false
	end
end

-- Applies to EVERY live Desert segment every cycle, not one random one:
-- with a constant wind there's no reason a player on one Desert segment
-- should be becalmed because the coin came up for the other.
local function windLoop()
	while true do
		task.wait(WIND_REAPPLY_SECONDS)

		local desertIndices = findLiveDesertSegmentIndices()
		if #desertIndices == 0 then
			continue
		end

		for _, segmentIndex in desertIndices do
			local geometry = segmentGeometryByIndex[segmentIndex]
			if geometry ~= nil then
				local windDirection = if isReversed then geometry.Forward else -geometry.Forward
				applyGust(geometry.Center, windDirection)
			end
		end
	end
end

function DesertWindService.Init()
	buildSegmentGeometry()
	task.spawn(windLoop)
	task.spawn(reversalLoop)
end

return DesertWindService

--!strict
--[[
	TrackBoundaryMonitor
	New module (not in the original directory tree). Spatial-distance
	boundary enforcement (never .Touched), on a periodic check loop:

	- InLobby/AtFanBox player physically ends up on the track (jumped the
	  barrier instead of using EnterTrack) -> bounced back to the Hub, no
	  penalty. This is prevention, not punishment.
	- InRace player ends up off the track (jumped/knocked over a barrier,
	  or up ON one — the wall top is a lap-long catwalk over every hazard,
	  and the ground outside it is now flat and walkable, see
	  ON_TRACK_MARGIN) or falls below the world (a "pit") ->
	  ArcadeManager.HandleTrackViolation (costs a life, respawns at the
	  checkpoint).
	- InRace player moves against the track's direction of travel for more
	  than WRONG_DIRECTION_THRESHOLD_STUDS (cumulative, resets when they
	  move the right way again) -> fires a client-side warning.

	The track's centerline is sampled ONCE into a dense point cloud at
	Init() (each sample CFrame's own LookVector doubles as "the correct
	direction of travel there," since TrackPieceBuilder's samples are
	already oriented along the chain) rather than recomputed every check.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local TrackPieceBuilder = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("TrackPieceBuilder"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local ArcadeManager = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("ArcadeManager"))
local TeleportPoseService = require(script.Parent.Parent:WaitForChild("LobbyAndHub"):WaitForChild("TeleportPoseService"))

local CHECK_INTERVAL_SECONDS = 0.5
local STRAIGHT_SAMPLES_PER_SEGMENT = 6

-- How far SIDEWAYS of the centreline a racer may be: exactly to the outer face
-- of the barriers, and not a stud further.
--
-- Was SegmentWidth/2 + BarrierThickness + 10 = 49, i.e. 10 studs of legal
-- ground BEYOND the wall. That slack was harmless while there was nothing out
-- there to stand on — anyone who hopped a barrier fell to the Baseplate at
-- Y = -47, cleared FALL_OUT_Y_THRESHOLD, and lost a life for it. TerrainGround-
-- Builder removed that consequence: the ground it lays sits at Y = 0, one stud
-- UNDER the road's top face, and runs GROUND_MARGIN_STUDS (320) past the oval
-- in every direction. So the 10-stud slack turned into a flat, hazard-free
-- service road running the entire lap, level with the track and immediately
-- outside the wall — every obstacle bypassed at full walking speed, which is
-- exactly how it was reported from play.
--
-- The barrier is the boundary, so the barrier's outer face is the number. No
-- extra tolerance on top: this is a BRAWLER, players shove each other into the
-- wall constantly, and a shove has to be able to bury a character in the
-- barrier without costing them a life. Those 3 studs of BarrierThickness are
-- that allowance — a racer pinned against the wall measures ~35 (the root part
-- cannot pass the road edge at 36), so there are 4 studs of headroom before
-- anything fires.
local ON_TRACK_MARGIN = TrackGeometry.SegmentWidth / 2 + TrackGeometry.BarrierThickness

-- How far ABOVE the centreline a player may legitimately be.
--
-- This exists because the on-track test used to measure a single 3D distance
-- from the nearest centreline sample, and those samples sit at road level. Any
-- height therefore ate into the same budget as sideways travel: at
-- ON_TRACK_MARGIN = 49, a player standing directly over the centreline was
-- ruled OFF the track — and charged a life — the moment they got 49 studs up.
-- That is not a hypothetical. HillMud's climb walls are 60 studs tall, so
-- reaching the top of the intended, designed route cost a life every time. The
-- older 30-stud walls only escaped it by being under half the budget, and even
-- then a player 30 up AND 35 to the side measured 46 of the 49 available.
--
-- Height and sideways displacement are different questions and now get
-- different answers: horizontal distance still has to stay inside the barriers
-- plus margin, while vertical gets its own, deliberately generous ceiling.
--
-- Derivation, with leeway for high jumpers as requested:
--   60  tallest climbable structure on the track (HillMud straight wall)
--  + 3  a character's own height standing on top of it
--  +26  a jump from up there with JumpPower boosted to 2x base
--       (height = JumpPower^2 / 2g, so 100^2 / 392.4 ~ 25.5)
--  +31  headroom, so a future taller hazard or a bigger boost does not
--       silently start costing lives again
--  ---
--   120
-- Nothing legitimate reaches this, and anything that does is flying, so the
-- check still catches what it is for.
local MAX_HEIGHT_ABOVE_TRACK = 120
-- Comfortably below any legitimate hazard depth (deepest is WaterDock/
-- IceFrost's 8-stud water) and below SkyRail's 10-stud bridge height, so a
-- player who genuinely falls through a SkyRail gap still gets a real,
-- visible ~50-stud fall before the violation fires — not shrunk so far
-- that a splash into deep water could false-trigger it. Was -100: that
-- forced TrackGenerator's void-safety floor (see BASEPLATE_SAFETY_Y) 100+
-- studs below the track, which read as "the whole map is floating in the
-- air" when a player looked over any edge. Lower now so the map can sit
-- much closer to solid ground without breaking the fall-to-violation
-- mechanic SkyRail (and everything else's off-track fall-out) depends on.
local FALL_OUT_Y_THRESHOLD = -40
local WRONG_DIRECTION_THRESHOLD_STUDS = 20
local WRONG_DIRECTION_DOT_THRESHOLD = -0.3
-- A single check tick shouldn't see a legitimate racer move further than
-- this (even boosted); anything bigger is a teleport (EnterTrack, checkpoint
-- respawn, ReturnToHub, ...) and must not be counted as "moved backward."
local TELEPORT_JUMP_THRESHOLD_STUDS = 40

-- Standing on TOP of a barrier is off the track, and no sideways-distance test
-- can say so on its own: the wall spans 36..39 studs out, so its top surface is
-- inside ON_TRACK_MARGIN by construction — and it has to be, because that same
-- 3-stud band is the shove allowance described above. Tightening the margin to
-- exclude the wall top would mean charging a life for being body-checked into a
-- wall, which is a core mechanic.
--
-- So the wall top gets asked a different question: what is the player standing
-- on? A barrier is 3 studs wide and 10 tall, which makes it a perfectly good
-- catwalk running the whole lap above every hazard, and the answer "a Barrier"
-- is unambiguous — no legitimate route places a racer on one. Barriers are the
-- only parts named "Barrier" (TrackPieceBuilder.addBarriers), and every hazard
-- that legitimately gets a player off the road keeps them well inside it:
-- HillMud's wall-top pads sit at 12 studs lateral, jump/bridge platforms are
-- asserted to stay within SegmentWidth/2, and SkyRail's decks are 10 studs wide
-- on the centreline.
local BARRIER_STAND_PROBE_STUDS = 6

local TrackBoundaryMonitor = {}

-- The centreline as a chain of finite SEGMENTS, not a cloud of points: each
-- pose is the midpoint of a run of centreline that extends +/- its half-length
-- along its own -Z. See findNearestTrackSample for why the difference matters.
local trackPoses: { CFrame } = {}
local trackHalfLengths: { number } = {}

local lastPositionByPlayer: { [Player]: Vector3 } = {}
local backwardAccumByPlayer: { [Player]: number } = {}
local wrongDirectionNotifiedByPlayer: { [Player]: boolean } = {}

local function buildTrackPointCloud()
	trackPoses = {}
	trackHalfLengths = {}

	-- Each sample covers an equal share of its own piece, so the runs butt up
	-- end to end and their union is the whole centreline with no gaps: a
	-- straight's samples sit at the centres of STRAIGHT_SAMPLES_PER_SEGMENT
	-- equal sub-runs, and a curve's sit at the midpoints of the very chords the
	-- road is built from (TrackPieceBuilder.BuildCurve lays one slab per chord).
	local straightHalfLength = TrackGeometry.StraightLength / (2 * STRAIGHT_SAMPLES_PER_SEGMENT)
	local curveHalfLength = TrackGeometry.CurveRadius
		* math.sin(math.abs(math.rad(TrackGeometry.CurveArcDegrees / TrackGeometry.CurveSubdivisions)) / 2)

	local currentCFrame = CFrame.new(0, 0, 0)

	for _, segment in TrackBlueprints.OvalSegments do
		local samples: { CFrame }
		local exitCFrame: CFrame
		local halfLength: number

		if segment.SegmentType == "Straight" then
			samples, exitCFrame = TrackPieceBuilder.SampleStraight(currentCFrame, TrackGeometry.StraightLength, STRAIGHT_SAMPLES_PER_SEGMENT)
			halfLength = straightHalfLength
		else
			samples, exitCFrame = TrackPieceBuilder.SampleCurve(currentCFrame, TrackGeometry.CurveRadius, TrackGeometry.CurveArcDegrees, TrackGeometry.CurveSubdivisions)
			halfLength = curveHalfLength
		end

		for _, sampleCFrame in samples do
			table.insert(trackPoses, sampleCFrame)
			table.insert(trackHalfLengths, halfLength)
		end

		currentCFrame = exitCFrame
	end
end

-- Returns the index of the nearest track-centerline sample and the
-- distance to it. Used for both "are we on track" and "which way should
-- we be facing here."
-- Returns the nearest sample's index, the HORIZONTAL distance to the centreline
-- there, and how far the player is above it. Nearest is judged horizontally on
-- purpose: which bit of track you are over is a map-plane question, and letting
-- height decide it would pick a sample on the far side of the oval for anyone
-- up a wall.
--
-- The distance is to the centreline RUN each sample stands for, not to the
-- sample point — measured in the sample's own frame, so it comes out as true
-- lateral offset, directly comparable to the road's half-width. Distance to the
-- nearest POINT is what the old version measured, and it is not the same thing:
-- samples are 30 studs apart on a straight and 35.3 on a curve, so a racer
-- standing dead centre midway between two of them already measured 15-17.7
-- studs "off" the track for no reason but sampling. That error is why the
-- margin had to carry +10 studs of slack it could not distinguish from the
-- genuine article, and shrinking the margin without fixing this would have
-- started charging lives to anyone taking a curve on the outside line:
-- measured at the old margin, the true lateral allowance swung between 44 and
-- 49 studs depending only on where along the piece you were standing.
local function findNearestTrackSample(position: Vector3) : (number?, number, number)
	local bestIndex: number? = nil
	local bestDistance = math.huge
	local bestHeightAbove = 0

	for index, pose in trackPoses do
		-- Pieces only ever yaw (no pitch or roll anywhere in the chain), so the
		-- local Y offset is the world height difference unchanged, and X/Z stay
		-- a purely horizontal measurement.
		local localPosition = pose:PointToObjectSpace(position)
		local halfLength = trackHalfLengths[index]
		local pastEnd = localPosition.Z - math.clamp(localPosition.Z, -halfLength, halfLength)
		local distance = math.sqrt(localPosition.X * localPosition.X + pastEnd * pastEnd)

		if distance < bestDistance then
			bestDistance = distance
			bestHeightAbove = localPosition.Y
			bestIndex = index
		end
	end

	return bestIndex, bestDistance, bestHeightAbove
end

-- See BARRIER_STAND_PROBE_STUDS. RespectCanCollide so a decorative overhang
-- (SkyRail's railings are CanCollide = false) can never mask the wall a player
-- is actually standing on.
local function isStandingOnBarrier(rootPart: BasePart) : boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rootPart.Parent :: Instance }
	params.RespectCanCollide = true

	local result = workspace:Raycast(rootPart.Position, Vector3.new(0, -BARRIER_STAND_PROBE_STUDS, 0), params)
	return result ~= nil and result.Instance.Name == "Barrier"
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function resetWrongDirectionTracking(player: Player)
	backwardAccumByPlayer[player] = 0
	wrongDirectionNotifiedByPlayer[player] = false
end

local function checkWrongDirection(player: Player, position: Vector3, nearestIndex: number)
	local lastPosition = lastPositionByPlayer[player]
	lastPositionByPlayer[player] = position

	if lastPosition == nil then
		return
	end

	local delta = position - lastPosition
	local deltaMagnitude = delta.Magnitude

	if deltaMagnitude < 0.5 then
		return -- effectively stationary; don't let noise reset progress
	end

	if deltaMagnitude > TELEPORT_JUMP_THRESHOLD_STUDS then
		-- Almost certainly a teleport (EnterTrack/checkpoint respawn/
		-- ReturnToHub), not real movement — don't count it either way.
		resetWrongDirectionTracking(player)
		return
	end

	local expectedForward = trackPoses[nearestIndex].LookVector
	local dot = delta.Unit:Dot(expectedForward)

	if dot < WRONG_DIRECTION_DOT_THRESHOLD then
		local accumulated = (backwardAccumByPlayer[player] or 0) + deltaMagnitude
		backwardAccumByPlayer[player] = accumulated

		if accumulated > WRONG_DIRECTION_THRESHOLD_STUDS and not wrongDirectionNotifiedByPlayer[player] then
			Network.Track.ShowNotification:FireClient(player, "WRONG DIRECTION")
			wrongDirectionNotifiedByPlayer[player] = true
		end
	else
		resetWrongDirectionTracking(player)
	end
end

local function checkPlayer(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local state = PlayerStateService.GetState(player)
	local position = rootPart.Position
	local _, nearestDistance, heightAboveTrack = findNearestTrackSample(position)
	-- Two independent conditions, not one blended distance: you must be over the
	-- track, and not absurdly high above it. See MAX_HEIGHT_ABOVE_TRACK for why
	-- combining them charged a life for climbing the track's own walls.
	local withinTrackBounds = nearestDistance <= ON_TRACK_MARGIN and heightAboveTrack <= MAX_HEIGHT_ABOVE_TRACK
	-- The two branches below want different questions answered, so they get
	-- different answers. A racer must be on a legal racing surface, and the top
	-- of a barrier is not one. A lobby player just has to be OUT of the track's
	-- space, and perching on its wall is not out — so that branch takes the
	-- bounds test alone and bounces them either way.
	local onTrack = withinTrackBounds and not isStandingOnBarrier(rootPart)

	if state == PlayerState.InRace then
		local fellOut = position.Y < FALL_OUT_Y_THRESHOLD
		if fellOut or not onTrack then
			ArcadeManager.HandleTrackViolation(player)
			resetWrongDirectionTracking(player)
			lastPositionByPlayer[player] = nil -- next tick just re-baselines post-respawn
			return
		end

		local nearestIndex = select(1, findNearestTrackSample(position))
		if nearestIndex ~= nil then
			checkWrongDirection(player, position, nearestIndex)
		end
	elseif state == PlayerState.InLobby or state == PlayerState.AtFanBox then
		if withinTrackBounds then
			-- Jumped/climbed onto the track without going through
			-- EnterTrack — bounce back, no penalty.
			TeleportPoseService.ReturnToHub(player)
			lastPositionByPlayer[player] = nil
		end
	end
end

-- Re-samples the track centerline — must be called after
-- TrackGenerator.Regenerate(). The oval's own segment geometry (lengths/
-- angles) is deterministic so trackPoses/trackHalfLengths happen to still be
-- numerically correct even without this, but there is no reason to leave
-- a public API relying on that coincidence: call this whenever the Track
-- folder gets rebuilt, matching CheckpointValidator.RefreshCheckpoints.
function TrackBoundaryMonitor.RefreshTrackGeometry()
	buildTrackPointCloud()
end

function TrackBoundaryMonitor.Init()
	buildTrackPointCloud()

	Players.PlayerRemoving:Connect(function(player: Player)
		lastPositionByPlayer[player] = nil
		backwardAccumByPlayer[player] = nil
		wrongDirectionNotifiedByPlayer[player] = nil
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

return TrackBoundaryMonitor

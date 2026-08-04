--!strict
--[[
	CountdownCameraController
	The pre-race broadcast. During a Grand Prix countdown the camera leaves the
	player, sweeps around the track everyone is about to race on, cuts to the
	racers on the starting grid, and hands control back three seconds before the
	flag so nobody is fighting a cinematic when the lights go green.

		Countdown starts (15s)
		|<------- 7s track sweep ------->|<-- 5s grid --->|<- 3s back to you ->|
		                                                  ^ camera restored here

	Shown to EVERY player, not just entrants — the point of an appointment
	event is that the whole server looks up when it starts. Non-participants
	have already been cleared off the track by this point, so nobody is losing
	control of a character that is doing anything.

	## Entirely client-side

	No server change and no new remote: `GrandPrixStateChanged`,
	`GrandPrixTimer` and `UpdateRaceStandings` are already broadcast to every
	player for the HUD, and between them they carry everything this needs —
	when the countdown started, how long is genuinely left, and who is on the
	grid. The track itself is ordinary replicated geometry under
	`workspace.Track`.

	## Phases are derived from time REMAINING, never from a local stopwatch

	Every frame re-reads "how long until the flag" from a deadline that the
	server's own timer broadcast keeps correcting (it re-broadcasts every 5s).
	A local elapsed-time counter started at the state change would drift, and
	worse, would be simply wrong for a player who loaded in mid-countdown —
	they receive the state and the true remaining time on join, so they drop
	into whichever phase is actually current instead of starting a 15-second
	sequence with 4 seconds left.

	## Restoring is guarded, not assumed

	A scriptable camera that is never handed back is an unplayable client, so
	every exit path goes through one `stop()`: the countdown ending, the state
	changing to anything else, the character respawning mid-sequence, and the
	3-second handover itself. `stop()` is idempotent and only restores a camera
	this module actually took.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local CountdownCameraController = {}

-- ===== Tuning =====

-- Hand the camera back this long before the flag. The explicit requirement,
-- and the right one: a racer needs a moment to find their character and their
-- footing before they are allowed to move.
local RETURN_LEAD_SECONDS = 3
-- How long the grid section runs, immediately before the handover.
local GRID_SECONDS = 5
-- Below this, a racer gets too brief a glimpse to register as a person, so the
-- grid section shows the first few rather than flashing through forty.
local MIN_SECONDS_PER_RACER = 1.1

-- The sweep is an orbit rather than a path along the road: an orbit is
-- guaranteed to stay outside the geometry it is looking at, whereas a flight
-- down the track would need collision handling to avoid ending up inside a
-- hazard or under a SkyRail deck on a themed segment.
local SWEEP_RADIANS = math.rad(200) -- a bit over half a lap of arc
local SWEEP_START_ANGLE = math.rad(35)
local SWEEP_DISTANCE_START = 1.55 -- multiples of the track's own radius
local SWEEP_DISTANCE_END = 1.05
local SWEEP_HEIGHT_START = 0.80
local SWEEP_HEIGHT_END = 0.32

-- Per-racer hero shot: in front of them, slightly above eye line, pushing in.
local GRID_DISTANCE_START = 17
local GRID_DISTANCE_END = 11.5
local GRID_HEIGHT = 5.5
local GRID_LOOK_HEIGHT = 2

-- ===== State =====

-- os.clock() timestamp the countdown ends at, or nil when not counting down.
local countdownDeadline: number? = nil
-- The countdown's FULL length, as the server declared it on the state change.
-- Needed because the sweep's progress is "how far through the countdown are
-- we", and the only other thing available each frame is how much is LEFT.
-- Carried separately from the deadline because GrandPrixTimer's corrections
-- report the remainder without restating the total.
local countdownLength = 15
-- Player NAMES from the last standings push. Names rather than Player objects
-- because that is what UpdateRaceStandings carries, and a name is re-resolved
-- every frame anyway to survive a racer leaving mid-countdown.
local rosterNames: { string } = {}

local isActive = false
local renderConnection: RBXScriptConnection? = nil
local trackCentre: Vector3? = nil
local trackRadius = 0

-- ===== Helpers =====

-- Bounding box of the whole track, recomputed at the start of every countdown
-- because the track is regenerated after every race — a cached centre would
-- frame the previous oval.
local function measureTrack() : boolean
	local track = workspace:FindFirstChild("Track")
	if track == nil then
		return false
	end

	local minPoint: Vector3? = nil
	local maxPoint: Vector3? = nil
	for _, descendant in track:GetDescendants() do
		if descendant:IsA("BasePart") then
			local position = descendant.Position
			if minPoint == nil or maxPoint == nil then
				minPoint, maxPoint = position, position
			else
				minPoint = Vector3.new(
					math.min(minPoint.X, position.X),
					math.min(minPoint.Y, position.Y),
					math.min(minPoint.Z, position.Z)
				)
				maxPoint = Vector3.new(
					math.max(maxPoint.X, position.X),
					math.max(maxPoint.Y, position.Y),
					math.max(maxPoint.Z, position.Z)
				)
			end
		end
	end

	if minPoint == nil or maxPoint == nil then
		return false
	end

	local span = maxPoint - minPoint
	trackCentre = (minPoint + maxPoint) * 0.5
	-- Horizontal half-extent only. Including Y would let one tall SkyRail
	-- pillar inflate the framing distance and push the whole oval into the
	-- distance.
	trackRadius = math.max(span.X, span.Z) * 0.5
	return trackRadius > 1
end

-- Racers still present, resolved fresh each frame: someone can leave the
-- server mid-countdown, and a stale Player reference would frame a corpse.
local function currentRacers() : { Player }
	local racers: { Player } = {}
	for _, name in rosterNames do
		local player = Players:FindFirstChild(name)
		if player ~= nil and player:IsA("Player") then
			local character = player.Character
			if character ~= nil and character:FindFirstChild("HumanoidRootPart") ~= nil then
				table.insert(racers, player)
			end
		end
	end
	return racers
end

local function restoreCamera()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera.CameraType = Enum.CameraType.Custom
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		camera.CameraSubject = humanoid
	end
end

local function stop()
	if not isActive then
		return
	end
	isActive = false
	if renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end
	restoreCamera()
end

-- ===== Camera work =====

local function sweepCFrame(progress: number) : CFrame
	local centre = trackCentre :: Vector3
	local angle = SWEEP_START_ANGLE + progress * SWEEP_RADIANS
	local distance = trackRadius * (SWEEP_DISTANCE_START + (SWEEP_DISTANCE_END - SWEEP_DISTANCE_START) * progress)
	local height = trackRadius * (SWEEP_HEIGHT_START + (SWEEP_HEIGHT_END - SWEEP_HEIGHT_START) * progress)
	local position = centre + Vector3.new(math.cos(angle) * distance, height, math.sin(angle) * distance)
	return CFrame.lookAt(position, centre)
end

local function gridCFrame(racers: { Player }, phaseElapsed: number) : CFrame?
	-- Show as many racers as fit at a legible pace, in roster order, rather
	-- than cramming a 40-player grid into 5 seconds.
	local slots = math.max(1, math.min(#racers, math.floor(GRID_SECONDS / MIN_SECONDS_PER_RACER)))
	local secondsEach = GRID_SECONDS / slots
	local index = math.min(slots, math.floor(phaseElapsed / secondsEach) + 1)

	local racer = racers[index]
	if racer == nil then
		return nil
	end
	local character = racer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart == nil then
		return nil
	end

	-- 0..1 within this racer's own slot, driving a slow push-in so a held shot
	-- still has motion in it.
	local slotProgress = math.clamp((phaseElapsed - (index - 1) * secondsEach) / secondsEach, 0, 1)
	local distance = GRID_DISTANCE_START + (GRID_DISTANCE_END - GRID_DISTANCE_START) * slotProgress

	-- -Z is the character's forward, so a negative Z offset puts the camera in
	-- front of them looking back — the racer faces the lens.
	local anchor = rootPart.CFrame * CFrame.new(0, GRID_HEIGHT, -distance)
	return CFrame.lookAt(anchor.Position, rootPart.Position + Vector3.new(0, GRID_LOOK_HEIGHT, 0))
end

local function onRender()
	local deadline = countdownDeadline
	local camera = workspace.CurrentCamera
	if deadline == nil or camera == nil or trackCentre == nil then
		stop()
		return
	end

	local remaining = deadline - os.clock()
	if remaining <= RETURN_LEAD_SECONDS then
		stop()
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	local gridEndsAt = RETURN_LEAD_SECONDS + GRID_SECONDS
	if remaining <= gridEndsAt then
		local racers = currentRacers()
		local target = if #racers > 0 then gridCFrame(racers, gridEndsAt - remaining) else nil
		if target ~= nil then
			camera.CFrame = target
			return
		end
		-- Nobody joined, or every entrant lost their character. Rather than
		-- freeze on the last frame, let the sweep keep running to the handover
		-- — an empty grid is not worth showing.
	end

	-- Sweep phase. Progress is measured from the START of the countdown, which
	-- is not stored: it is derived from where `remaining` sits inside the
	-- sweep's own window, so a late joiner picks up mid-sweep instead of
	-- restarting it.
	local sweepStart = math.max(countdownLength, gridEndsAt + 0.001)
	local elapsedInSweep = math.max(0, sweepStart - remaining)
	local sweepDuration = math.max(0.001, sweepStart - gridEndsAt)
	camera.CFrame = sweepCFrame(math.clamp(elapsedInSweep / sweepDuration, 0, 1))
end

local function start()
	if isActive then
		return
	end
	local deadline = countdownDeadline
	if deadline == nil then
		return
	end
	-- Already past the handover (a player loading in during the last seconds).
	-- Starting here would take the camera only to hand it straight back.
	if deadline - os.clock() <= RETURN_LEAD_SECONDS then
		return
	end
	-- No track to show means no cinematic. Failing to normal camera is always
	-- better than pointing a scriptable camera at nothing.
	if not measureTrack() then
		return
	end

	isActive = true
	renderConnection = RunService.RenderStepped:Connect(onRender)
end

-- ===== Wiring =====

function CountdownCameraController.Init()
	Network.Track.UpdateRaceStandings.OnClientEvent:Connect(function(standings: unknown)
		if typeof(standings) ~= "table" then
			return
		end
		local names: { string } = {}
		for _, row in standings :: { any } do
			if typeof(row) == "table" and typeof(row.PlayerName) == "string" then
				table.insert(names, row.PlayerName)
			end
		end
		rosterNames = names
	end)

	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(function(state: unknown, countdownSeconds: unknown)
		if state == "Countdown" and typeof(countdownSeconds) == "number" then
			countdownLength = countdownSeconds
			countdownDeadline = os.clock() + countdownSeconds
			start()
		else
			countdownDeadline = nil
			stop()
		end
	end)

	-- The authoritative correction. Re-broadcast every few seconds, and sent
	-- on join, so this is what keeps the phases aligned with the server's real
	-- countdown rather than with this client's guess at it.
	Network.Track.GrandPrixTimer.OnClientEvent:Connect(function(state: unknown, secondsRemaining: unknown)
		if state ~= "Countdown" or typeof(secondsRemaining) ~= "number" then
			return
		end
		countdownDeadline = os.clock() + secondsRemaining
		start()
	end)

	-- Respawning mid-cinematic would otherwise leave the new character behind a
	-- scriptable camera that only the countdown's end would release.
	localPlayer.CharacterAdded:Connect(stop)
end

return CountdownCameraController

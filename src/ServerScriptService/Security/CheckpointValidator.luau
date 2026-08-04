--!strict
--[[
	CheckpointValidator
	Full-width wall checkpoint detection — spatial, never .Touched, via a
	direct CFrame-space point-in-box test against each checkpoint's trigger
	volume (not workspace:GetPartsInPart, which was the original approach —
	switched away from it after a reported "checkpoint doesn't register
	while carrying a Fan Payload" bug; see git history / prior
	PROJECT_STATE.md entries for that reasoning).

	Still reported as failing after that fix — the actual, numeric root
	cause: TrackGeometry.CheckpointTriggerThickness is 6 studs, the poll
	interval is 0.5s, and default Roblox walk speed is 16 studs/sec — fully
	crossing the trigger wall takes ~0.375s, comfortably UNDER one poll
	interval. A single "are you inside the wall right now" sample can
	legitimately never land while the player is inside a 6-stud band they
	cross in well under half a second; this was a real race condition on
	ANY player, not something carrying fans caused. It read as carry-
	specific because checkpoint triggers used to sit at each segment's
	ENTRY, the same spot TrackPickupSpawner.Generate anchors its Fan
	Payload pickups (`samples[1].Position`) — players would slow down/
	maneuver right at that spot to grab the payload, changing the timing/
	pattern of how they crossed the checkpoint plane relative to carriers
	just running straight through. (Checkpoints have since moved to segment
	EXITS instead — see below — so this specific co-location no longer
	exists either, though the underlying poll-vs-speed math this section
	describes is still the real fix and still applies to every checkpoint.)

	Fixed for real this time by tracking each player's last-polled position
	(same pattern TrackBoundaryMonitor already uses for wrong-direction
	detection) and checking whether the straight-line segment from last to
	current position crosses the trigger's thin axis — not just whether
	either single sample happens to land inside it.

	Enforces strict order (1, 2, 3, ..., 8, 1, ...): a player can only ever
	advance to lastOrdinal + 1, so skipping ahead doesn't register.

	Checkpoint N sits at segment N's EXIT (TrackGenerator places the
	trigger there, not at the entry — see its docstring), so Checkpoint 8
	is segment 8's exit, which is the SAME physical point as segment 1's
	entry (the oval closes on itself there) — Checkpoint 8 IS the
	start/finish line. Reaching Checkpoint 8 is therefore what completes a
	lap (TotalLapsCompleted +1, Gold/Fan reward from EconomyRates); no
	separate "come back around to Checkpoint 1" step is needed on top of
	that. (An earlier version placed checkpoints at segment ENTRIES
	instead, which meant reaching "Checkpoint 8" only meant segments 1-7
	were done — a full segment short of an actual lap. Moving the trigger
	placement to segment EXITS, so the last checkpoint naturally coincides
	with the finish line, fixed it at the source instead of special-casing
	the reward trigger.)

	"Wrong direction" isn't separately re-checked here — walking the whole
	lap backward to re-enter checkpoint 1 from behind takes exactly as long
	as running it forward, so it isn't an exploit worth guarding against on
	its own; TrackBoundaryMonitor's cumulative-backward-movement warning
	already covers the player-facing "you're going the wrong way" signal.

	Trigger Parts are read from whatever TrackGenerator actually built
	(workspace.Track.Checkpoints), not recomputed independently — stays
	correct even if segments get randomized later, since it just reads
	positions off the real geometry rather than assuming a fixed layout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
-- Safe direction: QuestService requires ProfileManager but never
-- CheckpointValidator, so this is not a cycle.
local QuestService = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("QuestService"))
local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("VisualEffectsService"))

local CHECK_INTERVAL_SECONDS = 0.5
local CHECKPOINT_COUNT = 8
-- A single poll-to-poll move bigger than this is almost certainly a
-- teleport (EnterTrack, a checkpoint-violation respawn, ReturnToHub, ...),
-- not real movement — same guard pattern TrackBoundaryMonitor uses for its
-- own last-position tracking. Without this, a teleport landing on the far
-- side of a checkpoint's thin plane from where the player teleported FROM
-- would look like a (bogus) crossing.
local TELEPORT_JUMP_THRESHOLD_STUDS = 40

local CheckpointValidator = {}

local checkpointParts: { [number]: BasePart } = {}
local lastOrdinalByPlayer: { [Player]: number } = {} -- 0 = none passed yet this attempt
local lastPositionByPlayer: { [Player]: Vector3 } = {}

-- os.clock() when the player last crossed checkpoint 1, i.e. when their
-- current lap started. nil = no lap is being timed.
--
-- Timing starts at checkpoint 1 rather than at track entry on purpose: entry
-- drops a player at the start line, but they might stand there, get
-- teleported by a Grand Prix start, or join mid-lap. Checkpoint 1 is the only
-- moment we know a lap genuinely began, and checkpoint 8 is the only moment we
-- know one genuinely ended, so the interval between them is the only honest
-- lap time available.
--
-- Cleared (not just ignored) whenever a lap can no longer be trusted — a
-- respawn or a track exit resets progress to ordinal 0, so the next
-- checkpoint 1 starts a fresh clock.
local lapStartClockByPlayer: { [Player]: number } = {}

-- Optional observer for "this player just completed a lap." GrandPrixManager
-- registers one so it can count laps toward its 2-lap finish condition.
--
-- Deliberately a registered callback rather than a require: GrandPrixManager
-- already requires THIS module (for RefreshCheckpoints after a regeneration),
-- so requiring it back would be a genuine cycle. A callback keeps the
-- dependency one-directional and leaves this module usable with no race
-- manager present at all (which is exactly the Arcade free-run case).
local lapCompletedHandler: ((Player) -> ())? = nil

-- Same pattern, but for EVERY checkpoint rather than only the lap-closing
-- one. SegmentAnnouncer registers here to announce the segment a player is
-- about to enter. Kept separate from lapCompletedHandler so a consumer can
-- take one without the other.
local checkpointReachedHandler: ((Player, number) -> ())? = nil

local function cacheCheckpointParts()
	checkpointParts = {}

	local track = workspace:FindFirstChild("Track")
	local checkpointsFolder = track and track:FindFirstChild("Checkpoints")
	if checkpointsFolder == nil then
		return
	end

	for _, child in checkpointsFolder:GetChildren() do
		if child:IsA("BasePart") then
			local ordinal = child:GetAttribute("CheckpointOrdinal")
			if typeof(ordinal) == "number" then
				checkpointParts[ordinal] = child
			end
		end
	end
end

-- Re-reads workspace.Track.Checkpoints — must be called after
-- TrackGenerator.Regenerate(), which destroys the old Track folder
-- (including every checkpoint trigger Part) and builds a brand new one.
-- Without this, checkpointParts keeps holding references to destroyed
-- instances forever: Destroy() only sets Parent = nil, it doesn't clear
-- property reads, so a stale reference silently keeps "working" — this
-- was a real, previously-undetected bug (checkpointParts was only ever
-- populated once, in Init()) that a live Studio session can't easily
-- surface since the oval's geometry is deterministic and stale positions
-- happen to still line up; it's the reference going stale, not the
-- geometry, that's the actual defect.
function CheckpointValidator.RefreshCheckpoints()
	cacheCheckpointParts()
end

-- See lapCompletedHandler above. Fires AFTER the lap's own Gold/Fan reward
-- has been granted, once per completed lap, only for players actually InRace.
function CheckpointValidator.SetLapCompletedHandler(handler: (Player) -> ())
	lapCompletedHandler = handler
end

-- Fires with (player, ordinal) every time a checkpoint is legitimately
-- passed, including the lap-closing one.
function CheckpointValidator.SetCheckpointReachedHandler(handler: (Player, number) -> ())
	checkpointReachedHandler = handler
end

-- Resets a player to "no checkpoint passed yet" — call when they freshly
-- join the track (ArcadeManager.EnterTrack).
function CheckpointValidator.ResetPlayer(player: Player)
	lastOrdinalByPlayer[player] = 0
	lastPositionByPlayer[player] = nil
	player:SetAttribute("CheckpointOrdinal", 0)
end

function CheckpointValidator.GetLastOrdinal(player: Player) : number
	return lastOrdinalByPlayer[player] or 0
end

-- World CFrame to respawn a violated racer at: their last passed
-- checkpoint, or the start/finish line if they haven't passed any yet.
-- Checkpoint 1 is now segment 1's EXIT (not the start line — see the
-- module docstring), so "haven't passed any checkpoint" falls back to
-- Checkpoint 8 instead: segment 8's exit is the same physical point as
-- segment 1's entry, i.e. the actual start line. Falling back to
-- Checkpoint 1 here would respawn a player who violated partway through
-- segment 1 PAST all of segment 1 for free.
function CheckpointValidator.GetCheckpointCFrameForPlayer(player: Player) : CFrame
	local ordinal = lastOrdinalByPlayer[player] or 0
	local lookupOrdinal = if ordinal == 0 then CHECKPOINT_COUNT else ordinal
	local part = checkpointParts[lookupOrdinal]
	if part == nil then
		return CFrame.new(0, 0, 0)
	end
	return part.CFrame
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Pure CFrame-space geometry check: is `position` inside `triggerPart`'s
-- oriented bounding box? No physics query involved, so nothing about
-- CanQuery/CanCollide or any other part (carried, dropped, or otherwise)
-- anywhere in the world can affect the result.
local function isInsideTrigger(position: Vector3, triggerPart: BasePart) : boolean
	local localPosition = triggerPart.CFrame:PointToObjectSpace(position)
	local halfSize = triggerPart.Size / 2
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y
		and math.abs(localPosition.Z) <= halfSize.Z
end

-- Did the player cross the trigger's thin Z-axis between `lastPosition` and
-- `currentPosition`? Catches fast movement through the (only 6-stud-thick)
-- wall that a single per-poll "are you inside it right now" sample can miss
-- entirely — see the module docstring. Only the Z axis (the wall's
-- thickness) needs this treatment: X/Y span the full track width/height,
-- nobody crosses those between one 0.5s poll and the next.
local function crossedTriggerPlane(lastPosition: Vector3, currentPosition: Vector3, triggerPart: BasePart) : boolean
	if (currentPosition - lastPosition).Magnitude > TELEPORT_JUMP_THRESHOLD_STUDS then
		return false -- teleport, not real movement — don't trust it as a crossing
	end

	local lastLocal = triggerPart.CFrame:PointToObjectSpace(lastPosition)
	local currentLocal = triggerPart.CFrame:PointToObjectSpace(currentPosition)

	if (lastLocal.Z > 0) == (currentLocal.Z > 0) then
		return false -- never crossed the plane at all
	end

	local halfSize = triggerPart.Size / 2
	return math.abs(currentLocal.X) <= halfSize.X and math.abs(currentLocal.Y) <= halfSize.Y
end

-- Closes the timing window opened at checkpoint 1 and records a new personal
-- best if this lap beat it. Returns the lap time in ms, or nil when this lap
-- was not timeable (no checkpoint 1 this attempt — e.g. the player respawned
-- mid-lap, which resets progress).
local function recordLapTime(player: Player, profile) : number?
	local startClock = lapStartClockByPlayer[player]
	lapStartClockByPlayer[player] = nil
	if startClock == nil then
		return nil
	end

	local lapMs = math.floor((os.clock() - startClock) * 1000)
	-- A sub-second "lap" is not a lap; it is a symptom (a teleport that
	-- happened to trip both planes, or two checkpoints refreshed under the
	-- player by a regeneration). Refusing it here keeps a nonsense record off
	-- the fastest-lap board permanently, which is the one board where a
	-- single bad row is unfixable from inside the game.
	if lapMs < 1000 then
		return nil
	end

	if profile.Data.BestLapTimeMs == 0 or lapMs < profile.Data.BestLapTimeMs then
		profile.Data.BestLapTimeMs = lapMs
		return lapMs
	end
	return lapMs
end

-- Paid for checkpoints 1-7 only; the 8th IS the lap and pays the lap reward
-- instead, so no crossing is ever paid twice.
--
-- Reached only through checkPlayer's own geometric validation (a real
-- in-trigger test or a real plane crossing, with teleports explicitly
-- rejected), so there is no client input anywhere in this path — the client
-- cannot ask for a checkpoint, only be observed passing one.
local function grantCheckpointReward(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local fanReward = EconomyRates.CheckpointFanReward
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		fanReward *= EconomyRates.DoubleGainMultiplier
	end

	profile.Data.TotalFans += fanReward
	ProfileManager.SyncAttributes(player)
	Network.Track.ShowNotification:FireClient(player, `+{Utils.FormatNumber(fanReward)} 🌟`, "Pop")
end

local function grantLapReward(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local goldReward = EconomyRates.LapCompletionGoldReward
	local fanReward = EconomyRates.LapCompletionFanReward
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		goldReward *= EconomyRates.DoubleGainMultiplier
		fanReward *= EconomyRates.DoubleGainMultiplier
	end

	profile.Data.TotalLapsCompleted += 1
	-- The daily lap count is the same fact as the lifetime one with a
	-- different lifetime, so it is recorded at the same moment rather than
	-- inferred later from a separate poll that could drift.
	QuestService.RecordLap(player)

	local previousBestMs = profile.Data.BestLapTimeMs
	local lapMs = recordLapTime(player, profile)
	local isNewBest = lapMs ~= nil and profile.Data.BestLapTimeMs == lapMs and lapMs ~= previousBestMs

	profile.Data.Gold += goldReward
	profile.Data.TotalFans += fanReward
	ProfileManager.SyncAttributes(player)
	SoundDirector.PlayForPlayer(player, "GoldGain")
	SoundDirector.PlayForPlayer(player, "FanGain")
	if player.Character ~= nil then
		VisualEffectsService.ShowLapBurst(player.Character)
		-- Confetti ON TOP of the gold lap burst, not instead of it: the burst
		-- is the information (which progress event fired, told by colour), the
		-- confetti is the celebration. A lap is the biggest thing that happens
		-- in a race lap-to-lap and should look like it.
		local rootPart = player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if rootPart ~= nil then
			VisualEffectsService.ShowConfettiBurst(rootPart.Position)
			-- 3D, so everyone nearby hears the crowd react to THEIR lap, not
			-- just the player who ran it.
			SoundDirector.PlayAtPart(rootPart, "CrowdCheer")
		end
	end
	Network.Track.ShowNotification:FireClient(
		player,
		`LAP COMPLETE! +{Utils.FormatNumber(goldReward)} 💰 +{Utils.FormatNumber(fanReward)} 🌟`,
		"Pop"
	)

	if lapMs ~= nil then
		local seconds = lapMs / 1000
		if isNewBest then
			Network.Track.ShowNotification:FireClient(player, `NEW PERSONAL BEST — {string.format("%.2f", seconds)}s!`, "Pop")
		else
			Network.Track.ShowNotification:FireClient(player, `LAP TIME {string.format("%.2f", seconds)}s`)
		end
	end
end

local function checkPlayer(player: Player)
	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		lastPositionByPlayer[player] = nil
		-- Leaving the track abandons any lap in progress. Without this, a
		-- player who returned to the Hub, wandered for ten minutes and came
		-- back would close the old timing window on their next checkpoint 8
		-- and post a ten-minute "lap".
		lapStartClockByPlayer[player] = nil
		return
	end

	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	local currentPosition = rootPart.Position
	local lastPosition = lastPositionByPlayer[player]
	lastPositionByPlayer[player] = currentPosition

	local nextOrdinal = (lastOrdinalByPlayer[player] or 0) + 1
	if nextOrdinal > CHECKPOINT_COUNT then
		nextOrdinal = 1
	end

	local triggerPart = checkpointParts[nextOrdinal]
	if triggerPart == nil then
		return
	end

	local reached = isInsideTrigger(currentPosition, triggerPart)
		or (lastPosition ~= nil and crossedTriggerPlane(lastPosition, currentPosition, triggerPart))

	if not reached then
		return
	end

	lastOrdinalByPlayer[player] = nextOrdinal
	player:SetAttribute("CheckpointOrdinal", nextOrdinal)

	-- Checkpoint 1 opens the timing window; checkpoint 8 closes it in
	-- grantLapReward. Reassigning unconditionally (rather than only when the
	-- clock is nil) is deliberate: crossing checkpoint 1 always means a fresh
	-- lap is starting, whatever happened to the previous one.
	if nextOrdinal == 1 then
		lapStartClockByPlayer[player] = os.clock()
	end

	-- Seven of every eight checkpoints used to pass in complete silence: only
	-- number 8 (the lap) made any noise, and the segment notice only fires on
	-- a theme change. Feedback on every one of them is the point — a racer
	-- should never have to check the HUD to know a checkpoint counted.
	-- The lap gets its own bigger burst below instead of this one, so the
	-- eighth doesn't fire two overlapping effects.
	if nextOrdinal ~= CHECKPOINT_COUNT then
		SoundDirector.PlayForPlayer(player, "CheckpointPassed")
		if player.Character ~= nil then
			VisualEffectsService.ShowCheckpointBurst(player.Character)
		end
		grantCheckpointReward(player)
	end

	if checkpointReachedHandler ~= nil then
		checkpointReachedHandler(player, nextOrdinal)
	end

	-- Checkpoint 8 IS the finish line (see module docstring) — reaching it
	-- completes the lap outright, no separate wrap-to-1 step needed.
	if nextOrdinal == CHECKPOINT_COUNT then
		lastOrdinalByPlayer[player] = 0 -- next expected is 1 again
		grantLapReward(player)

		if lapCompletedHandler ~= nil then
			lapCompletedHandler(player)
		end
	end
end

function CheckpointValidator.Init()
	cacheCheckpointParts()

	Players.PlayerRemoving:Connect(function(player: Player)
		lastOrdinalByPlayer[player] = nil
		lastPositionByPlayer[player] = nil
		lapStartClockByPlayer[player] = nil
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

return CheckpointValidator

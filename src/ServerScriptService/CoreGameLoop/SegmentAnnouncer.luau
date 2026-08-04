--!strict
--[[
	SegmentAnnouncer
	Tells a racer what they're running into. Every generation mixes 2-4
	themes across the oval's 4 segment pairs and each theme has its own
	hazard, so without this a player meets a climbing wall, a chasm or a
	pond with no warning and no idea which of the eight it is.

	ONCE PER SEGMENT PER RUN, deliberately. The oval is a loop and a Grand
	Prix is two laps, so announcing on every entry would fire the same eight
	notices twice — noise by the second lap, when the player already knows
	the track. The set of already-announced segments is cleared whenever a
	player starts a fresh run (their PlayerState becomes InRace), which
	covers arcade entry, a Grand Prix start, and a re-entry after being
	returned to the Hub.

	Entry is derived from checkpoints rather than from a spatial poll of its
	own: checkpoint N sits at segment N's EXIT (see TrackGenerator), so
	passing checkpoint N is exactly the moment of entering segment N+1
	(wrapping 8 -> 1). CheckpointValidator already does that detection, and
	already handles the fast-crossing/teleport edge cases, so this hooks its
	SetCheckpointReachedHandler instead of re-deriving any of it.

	Themes are read off the live workspace.Track piece attributes that
	TrackGenerator stamps (ThemeId/SegmentIndex), NOT from any copy of the
	random theme-pick — so a Regenerate() between runs is picked up for free.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrackBlueprints = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackBlueprints"))
local TrackThemes = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackThemes"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local CheckpointValidator = require(script.Parent.Parent:WaitForChild("Security"):WaitForChild("CheckpointValidator"))

local CHECKPOINT_COUNT = #TrackBlueprints.OvalSegments

-- One line each, describing what the player actually has to DO — the theme's
-- DisplayName alone ("Ice & Frost") says nothing about the wall in front of
-- them. Lives here rather than in TrackThemes because it's presentation copy
-- about this project's hazards, and TrackThemes is a pure visual reskin
-- config shared by anything that builds a piece.
local HAZARD_HINTS: { [string]: string } = {
	Classic = "spinning bars — time your run",
	HillMud = "climb the wall or hop the platforms",
	IceFrost = "ice wall — climb it, no phasing",
	Volcanic = "lava patches + sweeper bars",
	WaterDock = "water crossing — swim or take the planks",
	SkyRail = "elevated rails — mind the gaps",
	Desert = "headwind — watch for the reversal",
	NeonCircuit = "falling blocks — watch the markers",
}

local SegmentAnnouncer = {}

-- player -> set of segment indices already announced this run.
local announcedByPlayer: { [Player]: { [number]: boolean } } = {}

local function themeForSegment(segmentIndex: number) : TrackThemes.TrackTheme?
	local track = workspace:FindFirstChild("Track")
	if track == nil then
		return nil
	end

	for _, piece in track:GetChildren() do
		if piece:GetAttribute("SegmentIndex") == segmentIndex then
			local themeId = piece:GetAttribute("ThemeId")
			if typeof(themeId) == "string" then
				return TrackThemes[themeId]
			end
		end
	end

	return nil
end

-- `isRunStart` bypasses the same-as-previous check: on the first segment of a
-- run the player has just arrived and hasn't been told anything yet, so
-- there is no "previous segment" of theirs to be redundant with.
local function announceSegment(player: Player, segmentIndex: number, isRunStart: boolean?)
	if PlayerStateService.GetState(player) ~= PlayerState.InRace then
		return
	end

	local announced = announcedByPlayer[player]
	if announced == nil then
		announced = {}
		announcedByPlayer[player] = announced
	end
	if announced[segmentIndex] then
		return
	end

	local theme = themeForSegment(segmentIndex)
	if theme == nil then
		return -- track mid-regeneration; nothing truthful to say
	end

	-- Nothing has changed, so there's nothing to warn about. The oval's
	-- segments are themed in PAIRS (1-2, 3-4, 5-6, 7-8 — see TrackGenerator),
	-- so crossing from the first half of a pair into the second would
	-- otherwise re-announce the identical hazard one checkpoint later. Mark
	-- it announced anyway: the player HAS been told about this hazard, and
	-- not marking it would leave it eligible to fire later in the lap.
	local previousSegment = if segmentIndex <= 1 then CHECKPOINT_COUNT else segmentIndex - 1
	local previousTheme = themeForSegment(previousSegment)
	announced[segmentIndex] = true
	if not isRunStart and previousTheme ~= nil and previousTheme.Id == theme.Id then
		return
	end

	local hint = HAZARD_HINTS[theme.Id]
	local text = if hint ~= nil
		then `SEGMENT {segmentIndex}/{CHECKPOINT_COUNT} — {string.upper(theme.DisplayName)}: {hint}`
		else `SEGMENT {segmentIndex}/{CHECKPOINT_COUNT} — {string.upper(theme.DisplayName)}`

	Network.Track.ShowNotification:FireClient(player, text)
end

local function startNewRun(player: Player)
	announcedByPlayer[player] = {}
	-- Segment 1 has no preceding checkpoint to trigger off, so the run's
	-- first announcement has to come from entering the track itself.
	announceSegment(player, 1, true)
end

function SegmentAnnouncer.Init()
	CheckpointValidator.SetCheckpointReachedHandler(function(player: Player, ordinal: number)
		-- Checkpoint N is segment N's exit, so it's segment N+1 they're
		-- entering; checkpoint 8 wraps back round to segment 1.
		local enteringSegment = if ordinal >= CHECKPOINT_COUNT then 1 else ordinal + 1
		announceSegment(player, enteringSegment)
	end)

	local function watchPlayer(player: Player)
		player:GetAttributeChangedSignal("PlayerState"):Connect(function()
			if player:GetAttribute("PlayerState") == PlayerState.InRace then
				startNewRun(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		announcedByPlayer[player] = nil
	end)
end

return SegmentAnnouncer

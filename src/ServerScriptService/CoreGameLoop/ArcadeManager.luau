--!strict
--[[
	ArcadeManager
	The 24/7 "always on" free-run track — join/leave at will, no roster, no
	relation to GrandPrixManager's scheduled event. This is what "enter the
	track" / "player may choose to leave" means in practice today:
	GrandPrixManager's own Countdown/roster join flow is still a TODO stub,
	so this is currently the only real way onto the track. Owns the lives
	consequence (TrackBoundaryMonitor calls HandleTrackViolation), since
	it's the thing that actually put the player on the track in the first
	place; checkpoint position itself comes from CheckpointValidator, which
	is the actual source of truth for "where did this player last reach."

	TRACK_START_CFRAME is identity (no rotation), so its LookVector is -Z —
	that's deliberately the same direction TrackPieceBuilder's chain starts
	facing (see its docstring: pieces extend along -LookVector from their
	entry CFrame), so a player spawned here is already facing the correct
	clockwise direction of travel without any extra rotation math.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))
local TrackGeometry = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("TrackGeometry"))
local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))

local PlayerStateService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("PlayerStateService"))
local CarryItemService = require(script.Parent.Parent:WaitForChild("CombatAndMovement"):WaitForChild("CarryItemService"))
local TeleportPoseService = require(script.Parent.Parent:WaitForChild("LobbyAndHub"):WaitForChild("TeleportPoseService"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local CheckpointValidator = require(script.Parent.Parent:WaitForChild("Security"):WaitForChild("CheckpointValidator"))
local SoundDirector = require(script.Parent:WaitForChild("SoundDirector"))
local VisualEffectsService = require(script.Parent:WaitForChild("VisualEffectsService"))

local TRACK_START_CFRAME = CFrame.new(0, 0, 0)
local TRACK_START_STAND_HEIGHT = 5
local MAX_LIVES = 3

-- Elimination-pending state (Task: revive-on-death purchase flow). A
-- player with 0 lives is NOT instantly returned to the Hub anymore — they
-- stay InRace (deliberately no new PlayerState.Eliminated: adding one would
-- mean re-auditing every InRace gate across the skill managers/CarryItemService
-- for a state that only ever lasts EconomyRates.EliminationTimeoutSeconds)
-- while a countdown on the client offers a revive purchase. This table is
-- the only record that a player is currently in that window; its presence
-- is also what GrantExtraLife checks to decide whether a purchase should
-- resolve the pending timeout or just bank a life for later.
local eliminationTimers: { [Player]: thread } = {}

-- Set by GrandPrixManager (see SetTrackClosedCheck): returns true while a
-- Grand Prix owns the track, so free-run JOIN RACE presses are refused
-- instead of dropping a non-participant into a live race.
--
-- A registered predicate rather than a require, for the same reason
-- CheckpointValidator's lap handler is: GrandPrixManager already requires
-- THIS module (for EnterTrack/LeaveTrack), so requiring it back would be a
-- real cycle. It also keeps the arcade fully functional with no race manager
-- present at all.
local trackClosedCheck: (() -> boolean)? = nil

local ArcadeManager = {}

function ArcadeManager.SetTrackClosedCheck(check: () -> boolean)
	trackClosedCheck = check
end

function ArcadeManager.IsTrackClosedForFreeRun() : boolean
	return trackClosedCheck ~= nil and trackClosedCheck()
end

local function currentDayNumber() : number
	return math.floor(os.time() / 86400)
end

local function getRootPart(player: Player) : BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function respawnAtCheckpoint(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end
	local checkpointCFrame = CheckpointValidator.GetCheckpointCFrameForPlayer(player)
	rootPart.CFrame = checkpointCFrame * CFrame.new(0, TrackGeometry.RoadThickness / 2 + TRACK_START_STAND_HEIGHT, 0)

	-- Rematerialising is a hard cut with no transition, so without this the
	-- player's only clue about what happened is that the scenery changed.
	SoundDirector.PlayForPlayer(player, "Respawn")
	if player.Character ~= nil then
		VisualEffectsService.ShowRespawnBurst(player.Character)
	end
end

-- Timeout fired: no purchase came in within EconomyRates.EliminationTimeoutSeconds
-- — refill to MAX_LIVES (same convention the instant-leave design always
-- used) and auto-return to the Hub, exactly like the pre-revive-flow
-- behavior.
local function onEliminationTimeout(player: Player)
	eliminationTimers[player] = nil

	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	profile.Data.Lives = MAX_LIVES
	ProfileManager.SyncAttributes(player)
	ArcadeManager.LeaveTrack(player)
	Network.Track.EliminationResolved:FireClient(player, false)
end

function ArcadeManager.EnterTrack(player: Player)
	local rootPart = getRootPart(player)
	if rootPart == nil then
		return
	end

	rootPart.CFrame = TRACK_START_CFRAME * CFrame.new(0, TrackGeometry.RoadThickness / 2 + TRACK_START_STAND_HEIGHT, 0)
	PlayerStateService.SetState(player, PlayerState.InRace)
	CheckpointValidator.ResetPlayer(player)
end

function ArcadeManager.LeaveTrack(player: Player)
	CarryItemService.Drop(player) -- don't let a player keep "holding" something after leaving
	TeleportPoseService.ReturnToHub(player)
end

-- Called by TrackBoundaryMonitor when an InRace player leaves the track
-- boundary (jumped/fell out) or falls below the fall-out height (pit).
-- Costs one life; at 0 lives, this used to instantly refill to MAX_LIVES
-- and send them back to the Hub. Per explicit clarification ("pause means
-- allow player to be able to choose or auto transport to commercial when
-- expire, not pause game"), 0 lives now opens a revive-purchase window
-- instead: the player stays InRace, a countdown starts
-- (onEliminationTimeout runs the old instant-leave behavior if it expires
-- unanswered), and PlayerEliminated tells the client to show the prompt.
-- A second violation while already pending is ignored — profile.Data.Lives
-- must not go negative while the choice is still open.
function ArcadeManager.HandleTrackViolation(player: Player)
	if eliminationTimers[player] ~= nil then
		return
	end

	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	profile.Data.Lives -= 1

	-- Losing a life is the most significant thing that can happen to a racer
	-- and it used to be completely silent — no sound, no VFX, not even a
	-- notification. Fired HERE rather than at each of the things that can
	-- cause it (fall-out, magma, a landed block) for the same reason the
	-- control-scramble notification lives in EffectStackManager: this is the
	-- one place every cause converges, so no route can be missed and none can
	-- double-fire. The burst goes first, before respawnAtCheckpoint moves the
	-- character, so it appears where the player actually died.
	SoundDirector.PlayForPlayer(player, "LifeLost")
	if player.Character ~= nil then
		VisualEffectsService.ShowLifeLostBurst(player.Character)
	end
	Network.Track.ShowNotification:FireClient(
		player,
		`LIFE LOST! {math.max(0, profile.Data.Lives)} LEFT`,
		"Pop"
	)

	if profile.Data.Lives <= 0 then
		profile.Data.Lives = 0
		ProfileManager.SyncAttributes(player)
		CarryItemService.Drop(player)
		-- Whatever caused the violation (fell off the track, pit, etc.) is
		-- still in effect — without this, a player who fell into open space
		-- would free-fall for the entire countdown and hit Roblox's own
		-- FallenPartsDestroyHeight cleanup (default -500 studs) well before
		-- EconomyRates.EliminationTimeoutSeconds is up, destroying their
		-- HumanoidRootPart and silently breaking both the revive respawn
		-- and the timeout's return-to-Hub (confirmed via live Studio
		-- testing: rootPart went nil, PlayerState got stuck on InRace).
		respawnAtCheckpoint(player)

		if profile.Data.GoldRevivesLastResetDay < currentDayNumber() then
			profile.Data.GoldRevivesUsedToday = 0
			profile.Data.GoldRevivesLastResetDay = currentDayNumber()
		end
		local goldRevivesRemainingToday = math.max(0, EconomyRates.ExtraLifeGoldDailyLimit - profile.Data.GoldRevivesUsedToday)

		eliminationTimers[player] = task.delay(EconomyRates.EliminationTimeoutSeconds, onEliminationTimeout, player)
		Network.Track.PlayerEliminated:FireClient(
			player,
			EconomyRates.EliminationTimeoutSeconds,
			EconomyRates.ExtraLifeGoldCost,
			goldRevivesRemainingToday
		)
		return
	end

	ProfileManager.SyncAttributes(player)
	CarryItemService.Drop(player) -- losing a life drops whatever was being carried
	respawnAtCheckpoint(player)
end

-- Grants exactly one extra life. Called by ProcessReceiptManager for the
-- Robux ExtraLife product (unlimited — always honors the purchase, pending
-- elimination or not) and by the BuyExtraLifeWithGold handler below (only
-- after it has already verified + deducted Gold and the daily cap). If the
-- player is currently in the elimination-pending window, this is what
-- resolves it: cancels the auto-return timeout and respawns them at their
-- last checkpoint instead of banking the life for a race that already
-- ended.
function ArcadeManager.GrantExtraLife(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local pendingThread = eliminationTimers[player]
	if pendingThread ~= nil then
		task.cancel(pendingThread)
		eliminationTimers[player] = nil
	end

	profile.Data.Lives += 1
	ProfileManager.SyncAttributes(player)

	if pendingThread ~= nil then
		respawnAtCheckpoint(player)
		Network.Track.EliminationResolved:FireClient(player, true)
	end
end

function ArcadeManager.Init()
	Network.Hub.EnterTrack.OnServerEvent:Connect(function(player: Player)
		-- Gate the REMOTE, not EnterTrack itself: GrandPrixManager's own
		-- Countdown calls EnterTrack to put its racers on the start line, and
		-- that must keep working while the track is "closed" to free-run.
		if ArcadeManager.IsTrackClosedForFreeRun() then
			Network.Track.ShowNotification:FireClient(player, "GRAND PRIX IN PROGRESS — JOIN THE NEXT ONE!", "Pop")
			return
		end
		ArcadeManager.EnterTrack(player)
	end)

	Network.Track.BuyExtraLifeWithGold.OnServerEvent:Connect(function(player: Player)
		if eliminationTimers[player] == nil then
			return -- no pending elimination to resolve — ignore stray/late fires
		end

		local profile = ProfileManager.GetProfile(player)
		if profile == nil then
			return
		end

		if profile.Data.GoldRevivesLastResetDay < currentDayNumber() then
			profile.Data.GoldRevivesUsedToday = 0
			profile.Data.GoldRevivesLastResetDay = currentDayNumber()
		end

		if profile.Data.GoldRevivesUsedToday >= EconomyRates.ExtraLifeGoldDailyLimit then
			Network.Track.ShowNotification:FireClient(player, "NO GOLD REVIVES LEFT TODAY!")
			return
		end

		if profile.Data.Gold < EconomyRates.ExtraLifeGoldCost then
			Network.Track.ShowNotification:FireClient(player, "NOT ENOUGH GOLD!")
			return
		end

		profile.Data.Gold -= EconomyRates.ExtraLifeGoldCost
		profile.Data.GoldRevivesUsedToday += 1
		ArcadeManager.GrantExtraLife(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local pendingThread = eliminationTimers[player]
		if pendingThread ~= nil then
			task.cancel(pendingThread)
			eliminationTimers[player] = nil
		end
	end)
end

return ArcadeManager

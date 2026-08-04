--!strict
--[[
	GrandPrixJoinController
	The JOIN GRAND PRIX toggle in StarterGui.MainHUD.LeftMenuBar (below
	ROBUX SHOP) plus the on-screen countdown that replaces its label while a
	Grand Prix is starting.

	Why a separate, toggleable button instead of the bottom-centre action
	button: that one is momentary and state-driven ("do the one thing that
	makes sense right now"), which can express "put me on the track" but has
	no way to express "actually, take me back OFF the sign-up list." Grand
	Prix enrolment is a standing choice a player makes minutes before the
	race, so it needs somewhere it can show its own current state and be
	pressed again to undo. The centre button therefore went back to plain
	"JOIN RACE" (free-run arcade entry, unchanged).

	The client never decides whether it is joined. It fires
	Network.Hub.ToggleGrandPrixEntry with no arguments and renders whatever
	boolean the server fires back — so a refused opt-out (mid-race) or a
	server-side roster wipe (every enterWaiting) can't leave the button
	claiming something the roster disagrees with.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

local JOINED_COLOR = Color3.fromRGB(60, 190, 90)
local NOT_JOINED_COLOR = Color3.fromRGB(255, 140, 38)

local GrandPrixJoinController = {}

local isJoined = false
local currentRaceState = "Waiting"
local countdownEndsAt: number? = nil

-- The timer label's own clock. The server sends a fresh remaining-seconds
-- figure every few seconds (GrandPrixTimer); between those this counts down
-- locally off os.clock(), which is monotonic and client-local — so the digits
-- move every second without a remote fire per second per player, and each
-- server update silently corrects any drift.
local timerDeadline: number? = nil
local timerState = "Waiting"
-- The next Grand Prix as a wall-clock reading in THIS player's time zone
-- ("20:30"), formatted once when the server sends the timestamp rather than on
-- every frame of the render loop. nil until the first timer broadcast arrives,
-- and whenever formatting failed — renderTimer falls back to the plain
-- countdown, so the label degrades to what it showed before rather than to an
-- error.
local nextRaceClockText: string? = nil

local function getButton() : TextButton?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local leftMenuBar = mainHud and mainHud:FindFirstChild("LeftMenuBar")
	local button = leftMenuBar and leftMenuBar:FindFirstChild("JoinGrandPrixButton")
	return button :: TextButton?
end

local function getTimerLabel() : TextLabel?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local leftMenuBar = mainHud and mainHud:FindFirstChild("LeftMenuBar")
	local label = leftMenuBar and leftMenuBar:FindFirstChild("GrandPrixTimerLabel")
	return label :: TextLabel?
end

local function formatClock(totalSeconds: number) : string
	local clamped = math.max(0, math.floor(totalSeconds))
	return string.format("%d:%02d", math.floor(clamped / 60), clamped % 60)
end

-- The same label serves all three phases, which is the point of it doubling
-- as the event clock: whatever the Grand Prix is currently counting down to
-- is what it shows.
local function renderTimer()
	local label = getTimerLabel()
	if label == nil then
		return
	end

	if timerDeadline == nil then
		label.Text = "NEXT GP --:--"
		return
	end

	local remaining = timerDeadline - os.clock()
	if timerState == "Waiting" then
		-- Both readings, because they answer different questions: the clock
		-- time is what a player plans around ("I'll be back for the 20:30"),
		-- the countdown is what tells them to stop what they're doing now.
		label.Text = if nextRaceClockText ~= nil
			then `NEXT GP {nextRaceClockText} · {formatClock(remaining)}`
			else `NEXT GP  {formatClock(remaining)}`
	elseif timerState == "Countdown" then
		label.Text = `STARTS  {formatClock(remaining)}`
	elseif timerState == "Racing" then
		label.Text = `TIME LEFT  {formatClock(remaining)}`
	else
		label.Text = "FINISHING..."
	end
end

-- One renderer for both inputs (joined-ness and race state) so they can never
-- half-apply: the countdown takes the label over while it's running, and the
-- join state always owns the colour.
local function render()
	renderTimer()

	local button = getButton()
	if button == nil then
		return
	end

	button.BackgroundColor3 = if isJoined then JOINED_COLOR else NOT_JOINED_COLOR

	if countdownEndsAt ~= nil and currentRaceState == "Countdown" then
		local remaining = math.max(0, math.ceil(countdownEndsAt - os.clock()))
		button.Text = if isJoined
			then `GRAND PRIX IN {remaining}...`
			else `STARTS IN {remaining} — NOT JOINED`
	elseif currentRaceState == "Racing" then
		button.Text = if isJoined then "RACING — GOOD LUCK!" else "GRAND PRIX IN PROGRESS"
	else
		button.Text = if isJoined then "JOINED ✓ — TAP TO LEAVE" else "JOIN GRAND PRIX"
	end
end

local function onToggleReply(joined: unknown)
	if typeof(joined) ~= "boolean" then
		return
	end
	isJoined = joined
	render()
end

local function onGrandPrixStateChanged(state: unknown, countdownSeconds: unknown)
	if typeof(state) ~= "string" then
		return
	end
	currentRaceState = state

	-- os.clock() (monotonic, client-local) rather than trusting a server
	-- timestamp: only the DURATION crosses the wire, so there's no clock-skew
	-- to reconcile and the worst case is one round-trip of drift.
	if state == "Countdown" and typeof(countdownSeconds) == "number" then
		countdownEndsAt = os.clock() + countdownSeconds
	else
		countdownEndsAt = nil
	end

	render()
end

-- 24-hour on purpose: it is compact enough to sit beside the countdown in a
-- 22px label, and it needs no am/pm to be unambiguous.
--
-- FormatLocalTime resolves the PLAYER's time zone, which is the only reason
-- this is done client-side at all — the server schedules in UTC and has no way
-- to know that a 19:30 UTC race is 20:30 to someone in Berlin. pcall'd because
-- it is a formatting call that can throw on a locale the client can't resolve,
-- and a throw here would take out the render loop that draws the whole label.
local function formatWallClock(unixTime: number) : string?
	local ok, text = pcall(function()
		return DateTime.fromUnixTimestamp(unixTime):FormatLocalTime("HH:mm", "en-us")
	end)
	return if ok then text else nil
end

local function onTimerUpdate(state: unknown, secondsRemaining: unknown, nextRaceStartTime: unknown)
	if typeof(state) ~= "string" or typeof(secondsRemaining) ~= "number" then
		return
	end
	timerState = state
	timerDeadline = os.clock() + secondsRemaining

	-- Optional third argument: an older server (or a replayed older client)
	-- simply leaves the label showing the countdown alone.
	nextRaceClockText = if typeof(nextRaceStartTime) == "number"
		then formatWallClock(nextRaceStartTime)
		else nil

	renderTimer()
end

function GrandPrixJoinController.Init()
	local button = getButton()
	if button ~= nil then
		button.Activated:Connect(function()
			Network.Hub.ToggleGrandPrixEntry:FireServer()
		end)
	end

	Network.Hub.ToggleGrandPrixEntry.OnClientEvent:Connect(onToggleReply)
	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(onGrandPrixStateChanged)
	Network.Track.GrandPrixTimer.OnClientEvent:Connect(onTimerUpdate)

	-- Drives the two local clocks (the button's start countdown and the timer
	-- label). Everything else in render() is event-driven.
	task.spawn(function()
		while true do
			if countdownEndsAt ~= nil then
				render()
			else
				renderTimer()
			end
			task.wait(0.25)
		end
	end)

	render()
end

return GrandPrixJoinController

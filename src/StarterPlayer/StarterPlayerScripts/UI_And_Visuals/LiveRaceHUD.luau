--!strict
--[[
	LiveRaceHUD
	Grand Prix standings list (StarterGui.MainHUD.StandingsPanel, right
	side) + the checkpoint/lap counter (its own capsule in the top-center
	StatsRow, StarterGui.MainHUD.StatsRow.CheckpointCapsule.LapLabel).
	Clones EntryTemplate per standing.

	StandingsPanel starts Visible = false (default.project.json) and now
	STAYS hidden — during a Grand Prix the four stadium leaderboards show
	the live race standings instead (LeaderboardBuilder.SetGrandPrixMode),
	so an on-screen copy of the same list would just cover the race with
	information the player can already read off the boards. The list is
	still populated from UpdateRaceStandings, so re-showing the panel is a
	one-line change in onGrandPrixStateChanged if it is ever wanted back.

	NOTE: the checkpoint counter reads a "CheckpointOrdinal" player
	attribute — CheckpointValidator sets it server-side and
	ProfileManager.SyncAttributes replicates it.

	LivesCapsule (StatsRow, beside CheckpointCapsule) shows the player's
	current Lives count, but only while actually racing — unlike
	CheckpointCapsule, which stays visible everywhere. Gated on PlayerState
	rather than shown unconditionally since "Lives" is meaningless outside
	a race (ArcadeManager only spends them InRace).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local localPlayer = Players.LocalPlayer

export type StandingEntry = {
	PlayerName: string,
	LivesRemaining: number,
	CheckpointOrdinal: number,
	-- Added with the real Grand Prix lifecycle (GrandPrixManager). Optional
	-- so an entry built by anything that predates them still renders.
	LapsCompleted: number?,
	IsEliminated: boolean?,
	FinishPlace: number?,
}

local LiveRaceHUD = {}

local function getStandingsPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local standingsPanel = mainHud and mainHud:FindFirstChild("StandingsPanel")
	return standingsPanel :: Frame?
end

-- A 2-lap race with lives makes "3. SomeName" nearly useless on its own —
-- what a racer wants at a glance is whether the name above them has already
-- finished, is out, or is simply a lap ahead. Every field is optional (see
-- StandingEntry), so an entry missing them just renders the bare name.
local function suffixForEntry(entry: StandingEntry) : string
	if entry.FinishPlace ~= nil then
		return ` — FINISHED P{entry.FinishPlace}`
	elseif entry.IsEliminated then
		return " — OUT"
	elseif entry.LapsCompleted ~= nil then
		return ` — lap {entry.LapsCompleted + 1}, cp {entry.CheckpointOrdinal}`
	end
	return ""
end

local function onStandingsUpdated(standings: { StandingEntry })
	local standingsPanel = getStandingsPanel()
	local standingsList = standingsPanel and standingsPanel:FindFirstChild("StandingsList")
	local entryTemplate = standingsList and standingsList:FindFirstChild("EntryTemplate")
	if standingsList == nil or entryTemplate == nil then
		return
	end

	for _, child in standingsList:GetChildren() do
		if child ~= entryTemplate and child:IsA("TextLabel") then
			child:Destroy()
		end
	end

	for index, entry in standings do
		local label = (entryTemplate :: TextLabel):Clone()
		label.Name = `Entry_{index}`
		label.Text = `{index}. {entry.PlayerName}{suffixForEntry(entry)}`
		label.LayoutOrder = index
		label.Visible = true
		label.Parent = standingsList
	end
end

-- The on-screen standings panel is now permanently hidden: during a Grand
-- Prix the four stadium leaderboards take the live standings over
-- (LeaderboardBuilder.SetGrandPrixMode), and a second copy of the same list
-- pinned over the race was the one the player was asked to stop looking at.
--
-- Kept as a call rather than deleted so the panel can't drift back into view:
-- the state broadcast repeats on a cycle, so this re-asserts hidden on every
-- one of them, and onStandingsUpdated below still fills the list in case the
-- panel is ever wanted back (flip this to the state test again and it works).
local function onGrandPrixStateChanged(state: unknown)
	if typeof(state) ~= "string" then
		return
	end
	local standingsPanel = getStandingsPanel()
	if standingsPanel ~= nil then
		standingsPanel.Visible = false
	end
end

local function updateLapLabel()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local statsRow = mainHud and mainHud:FindFirstChild("StatsRow")
	local checkpointCapsule = statsRow and statsRow:FindFirstChild("CheckpointCapsule")
	local lapLabel = checkpointCapsule and checkpointCapsule:FindFirstChild("LapLabel")
	if lapLabel == nil then
		return
	end

	local ordinal = (localPlayer:GetAttribute("CheckpointOrdinal") :: number?) or 0
	local lapLabelText = lapLabel :: TextLabel
	lapLabelText.Text = `Checkpoint {ordinal} / 8`
end

local function updateLivesCapsule()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local statsRow = mainHud and mainHud:FindFirstChild("StatsRow")
	local livesCapsule = statsRow and statsRow:FindFirstChild("LivesCapsule")
	if livesCapsule == nil then
		return
	end

	local livesFrame = livesCapsule :: Frame
	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	livesFrame.Visible = state == PlayerState.InRace

	local livesLabel = livesFrame:FindFirstChild("LivesLabel") :: TextLabel?
	if livesLabel ~= nil then
		local lives = (localPlayer:GetAttribute("Lives") :: number?) or 0
		livesLabel.Text = `Lives: {lives}`
	end
end

function LiveRaceHUD.Init()
	Network.Track.UpdateRaceStandings.OnClientEvent:Connect(onStandingsUpdated)
	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(onGrandPrixStateChanged)
	localPlayer:GetAttributeChangedSignal("CheckpointOrdinal"):Connect(updateLapLabel)
	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(updateLivesCapsule)
	localPlayer:GetAttributeChangedSignal("Lives"):Connect(updateLivesCapsule)
	updateLapLabel()
	updateLivesCapsule()
end

return LiveRaceHUD

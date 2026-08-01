--!strict
--[[
	LiveRaceHUD
	Grand Prix standings list (StarterGui.MainHUD.StandingsPanel, right
	side) + the checkpoint/lap counter (its own capsule in the top-center
	StatsRow, StarterGui.MainHUD.StatsRow.CheckpointCapsule.LapLabel).
	Clones EntryTemplate per standing.

	StandingsPanel starts Visible = false (default.project.json) and is
	only shown while GrandPrixManager reports an actual Grand Prix in
	progress (Countdown/Racing) — via the new Network.Track.
	GrandPrixStateChanged broadcast — instead of always showing an empty
	panel outside of Grand Prix hours.

	NOTE: the checkpoint counter reads a "CheckpointOrdinal" player
	attribute that nothing sets yet — GrandPrixManager tracks it in
	server-side RacerStatus but doesn't replicate it. Will show
	"Checkpoint 0 / 8" until that's wired up.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))

local localPlayer = Players.LocalPlayer

export type StandingEntry = {
	PlayerName: string,
	LivesRemaining: number,
	CheckpointOrdinal: number,
}

local LiveRaceHUD = {}

local function getStandingsPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local standingsPanel = mainHud and mainHud:FindFirstChild("StandingsPanel")
	return standingsPanel :: Frame?
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
		label.Text = `{index}. {entry.PlayerName}`
		label.LayoutOrder = index
		label.Visible = true
		label.Parent = standingsList
	end
end

local function onGrandPrixStateChanged(state: unknown)
	if typeof(state) ~= "string" then
		return
	end
	local standingsPanel = getStandingsPanel()
	if standingsPanel ~= nil then
		standingsPanel.Visible = state == "Countdown" or state == "Racing"
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

function LiveRaceHUD.Init()
	Network.Track.UpdateRaceStandings.OnClientEvent:Connect(onStandingsUpdated)
	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(onGrandPrixStateChanged)
	localPlayer:GetAttributeChangedSignal("CheckpointOrdinal"):Connect(updateLapLabel)
	updateLapLabel()
end

return LiveRaceHUD

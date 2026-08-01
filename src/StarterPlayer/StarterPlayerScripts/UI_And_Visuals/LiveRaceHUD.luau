--!strict
--[[
	LiveRaceHUD
	Top-left HUD quadrant: Grand Prix standings list + checkpoint/lap
	counter. Binds to StarterGui.MainHUD.TopLeft (declared in
	default.project.json), cloning EntryTemplate per standing.

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

local function onStandingsUpdated(standings: { StandingEntry })
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local topLeft = mainHud and mainHud:FindFirstChild("TopLeft")
	local standingsList = topLeft and topLeft:FindFirstChild("StandingsList")
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

local function updateLapLabel()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local topLeft = mainHud and mainHud:FindFirstChild("TopLeft")
	local lapLabel = topLeft and topLeft:FindFirstChild("LapLabel")
	if lapLabel == nil then
		return
	end

	local ordinal = (localPlayer:GetAttribute("CheckpointOrdinal") :: number?) or 0
	(lapLabel :: TextLabel).Text = `Checkpoint {ordinal} / 8`
end

function LiveRaceHUD.Init()
	Network.Track.UpdateRaceStandings.OnClientEvent:Connect(onStandingsUpdated)
	localPlayer:GetAttributeChangedSignal("CheckpointOrdinal"):Connect(updateLapLabel)
	updateLapLabel()
end

return LiveRaceHUD

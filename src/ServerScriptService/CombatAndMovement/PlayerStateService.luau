--!strict
--[[
	PlayerStateService
	Authoritative owner of each player's PlayerState (see ReplicatedStorage.
	Enums.PlayerState) — the state machine gating where a player is allowed
	to be doing what: InLobby (Hub), InRace (on track), AtFanBox. Skill
	casting is gated on InRace here (see TargetedSkillManager/
	GlobalSkillStateMachine/SelfSkillManager, which all check GetState
	before allowing a cast).

	Replicates via a "PlayerState" attribute so client UI (PlayerStateController,
	ActionButtonController) can react without a remote round-trip.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local PlayerStateService = {}

local currentStates: { [Player]: string } = {}

function PlayerStateService.SetState(player: Player, state: string)
	currentStates[player] = state
	player:SetAttribute("PlayerState", state)
end

function PlayerStateService.GetState(player: Player) : string
	return currentStates[player] or PlayerState.InLobby
end

local function onPlayerAdded(player: Player)
	PlayerStateService.SetState(player, PlayerState.InLobby)
end

local function onPlayerRemoving(player: Player)
	currentStates[player] = nil
end

function PlayerStateService.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PlayerStateService

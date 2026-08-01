--!strict
--[[
	PlayerStateController
	Client mirror of server-authoritative PlayerState (ReplicatedStorage.
	Enums.PlayerState). Locks/unlocks HUD buttons purely for UX — the server
	remains the source of truth and re-validates every action.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerState = require(ReplicatedStorage:WaitForChild("Enums"):WaitForChild("PlayerState"))

local localPlayer = Players.LocalPlayer

local PlayerStateController = {}

local function onStateChanged()
	local state = (localPlayer:GetAttribute("PlayerState") :: string?) or PlayerState.InLobby
	-- TODO: enable/disable skill + carry buttons based on `state`.
end

function PlayerStateController.Init()
	localPlayer:GetAttributeChangedSignal("PlayerState"):Connect(onStateChanged)
	onStateChanged()
end

return PlayerStateController

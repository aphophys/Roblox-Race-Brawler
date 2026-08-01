--!strict
--[[
	PlayerState
	Coarse player state used to gate skill casting, movement, and UI.
	PlayerStateService (server) is the sole writer; everyone else reads.
]]

export type PlayerStateName = "InLobby" | "InRace" | "AtFanBox"

export type PlayerStateEnum = {
	InLobby: PlayerStateName,
	InRace: PlayerStateName,
	AtFanBox: PlayerStateName,
}

local PlayerState: PlayerStateEnum = table.freeze({
	InLobby = "InLobby",
	InRace = "InRace",
	AtFanBox = "AtFanBox",
}) :: PlayerStateEnum

return PlayerState

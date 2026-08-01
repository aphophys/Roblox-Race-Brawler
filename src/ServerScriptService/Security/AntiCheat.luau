--!strict
--[[
	AntiCheat
	Server-side validation of client-reported movement: rejects/flags
	implausible speed or teleport-distance deltas between samples.
]]

export type PositionSample = {
	Position: Vector3,
	Timestamp: number, -- os.clock()
}

local MAX_STUDS_PER_SECOND = 40 -- generous headroom above BASE_WALK_SPEED + boosts

local AntiCheat = {}

local lastSample: { [Player]: PositionSample } = {}

function AntiCheat.ValidateMovement(player: Player, newPosition: Vector3) : boolean
	local previous = lastSample[player]
	local now = os.clock()

	if previous ~= nil then
		local elapsed = math.max(now - previous.Timestamp, 1 / 60)
		local studsPerSecond = (newPosition - previous.Position).Magnitude / elapsed

		if studsPerSecond > MAX_STUDS_PER_SECOND then
			-- TODO: flag/log; do not immediately kick on a single sample
			-- (false positives from legitimate teleports/lag).
			lastSample[player] = { Position = newPosition, Timestamp = now }
			return false
		end
	end

	lastSample[player] = { Position = newPosition, Timestamp = now }
	return true
end

function AntiCheat.Init()
	-- TODO: clear lastSample[player] on Players.PlayerRemoving.
end

return AntiCheat

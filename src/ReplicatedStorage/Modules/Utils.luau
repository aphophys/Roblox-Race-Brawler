--!strict
--[[
	Utils
	Generic, stateless helpers with no gameplay coupling. Add new pure
	functions here rather than duplicating math/formatting inline.
]]

local Utils = {}

function Utils.Round(value: number, decimals: number?) : number
	local multiplier = 10 ^ (decimals or 0)
	return math.floor(value * multiplier + 0.5) / multiplier
end

function Utils.Lerp(a: number, b: number, alpha: number) : number
	return a + (b - a) * alpha
end

function Utils.Clamp01(value: number) : number
	return math.clamp(value, 0, 1)
end

-- Abbreviates large numbers for HUD/leaderboard display, e.g. 12345 -> "12.3K".
function Utils.FormatNumber(value: number) : string
	local absValue = math.abs(value)
	local sign = value < 0 and "-" or ""

	if absValue >= 1_000_000_000 then
		return string.format("%s%.1fB", sign, absValue / 1_000_000_000)
	elseif absValue >= 1_000_000 then
		return string.format("%s%.1fM", sign, absValue / 1_000_000)
	elseif absValue >= 1_000 then
		return string.format("%s%.1fK", sign, absValue / 1_000)
	end

	return string.format("%s%d", sign, absValue)
end

return Utils

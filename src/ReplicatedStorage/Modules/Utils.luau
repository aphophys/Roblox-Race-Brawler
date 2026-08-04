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

-- Which `periodSeconds`-long slice of wall-clock time we are currently in.
--
-- This is how every "once every N minutes" reward in the game is gated, and
-- the reason is worth stating: the alternative — remembering when a player
-- last claimed and checking `now - last >= period` — starts a private clock
-- per player, and a private clock can be restarted. Rejoin, and an in-memory
-- timestamp is gone; even persisted, a player who claims at 09:59 and again
-- at 10:01 has legitimately waited two minutes, not ten.
--
-- A window INDEX has neither problem. It is derived from os.time() alone, so
-- it is identical for every player on every server, it needs no coroutine and
-- no bookkeeping to advance, and "have I already claimed in this window" is a
-- single integer comparison against a number in the profile. The cost is that
-- windows are shared rather than personal: claim at the end of one window and
-- the next opens sooner than `period` later. That is the intended trade —
-- generosity at the boundary in exchange for something that cannot be farmed
-- by reconnecting.
function Utils.GlobalWindowIndex(periodSeconds: number) : number
	return math.floor(os.time() / periodSeconds)
end

-- Inserts thousands-separator commas into a non-negative integer's digit
-- string, e.g. "1234567" -> "1,234,567".
local function withThousandsSeparators(digits: string) : string
	local formatted = digits
	while true do
		local newFormatted, replacements = formatted:gsub("^(%d+)(%d%d%d)", "%1,%2")
		formatted = newFormatted
		if replacements == 0 then
			break
		end
	end
	return formatted
end

-- Numbers up to 10 digits (< 10 billion) show in FULL, with thousands
-- separators, e.g. 1234567 -> "1,234,567" — no letter abbreviation at all
-- in that range. Only past 10 digits does it switch to letter suffixes
-- (B/T/Qa/...), to keep the display from growing unbounded for the rare
-- number that actually gets that large.
local DIGIT_LIMIT = 10
local ABBREVIATION_CUTOFF = 10 ^ DIGIT_LIMIT -- 10,000,000,000 — the first 11-digit value; everything below shows in full

local ABBREVIATIONS = {
	{ threshold = 1e33, divisor = 1e33, suffix = "De" }, -- Decillion
	{ threshold = 1e30, divisor = 1e30, suffix = "No" }, -- Nonillion
	{ threshold = 1e27, divisor = 1e27, suffix = "Oc" }, -- Octillion
	{ threshold = 1e24, divisor = 1e24, suffix = "Sp" }, -- Septillion
	{ threshold = 1e21, divisor = 1e21, suffix = "Sx" }, -- Sextillion
	{ threshold = 1e18, divisor = 1e18, suffix = "Qi" }, -- Quintillion
	{ threshold = 1e15, divisor = 1e15, suffix = "Qa" }, -- Quadrillion
	{ threshold = 1e12, divisor = 1e12, suffix = "T" }, -- Trillion
	{ threshold = ABBREVIATION_CUTOFF, divisor = 1e9, suffix = "B" }, -- Billion — still expressed in B units, just doesn't kick in until 10 digits
}

function Utils.FormatNumber(value: number) : string
	local absValue = math.abs(value)
	local sign = value < 0 and "-" or ""

	for _, entry in ABBREVIATIONS do
		if absValue >= entry.threshold then
			return string.format("%s%.1f%s", sign, absValue / entry.divisor, entry.suffix)
		end
	end

	return sign .. withThousandsSeparators(string.format("%d", absValue))
end

return Utils

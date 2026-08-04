--!strict
--[[
	MonetizationService
	Server-side game pass ownership checks. Wraps MarketplaceService:
	UserOwnsGamePassAsync with a pcall (it's a web request and can fail/
	throttle) and refuses to check any pass whose MonetizationConfigs Id is
	still 0.

	Passes checked through here today:
	- DoubleFans — CarryItemService.TryDeposit, CheckpointValidator's
	  checkpoint AND lap rewards, FanIncomeService, QuestService, GrandPrixManager
	  and TeleportPoseService all multiply by EconomyRates.DoubleGainMultiplier
	  when it returns true.
	- DailyBonus — DailyPassRewardService, once per calendar day.

	## Why the results are cached

	This was a plain pass-through to UserOwnsGamePassAsync on every call, and
	the call sites make that expensive in a way that is not obvious from any one
	of them. `grantCheckpointReward` runs on EVERY checkpoint — eight per lap,
	per player — so a 20-player server running laps was issuing well over a
	hundred ownership web requests a minute for an answer that cannot change.
	Each one is a yielding web call sitting in the middle of a reward path, so
	the cost is not just request budget: a throttled or slow response delays the
	reward itself, and a FAILED one silently returns false, i.e. quietly pays a
	pass holder the un-doubled amount.

	The cache is asymmetric on purpose, because the two answers have different
	risks if they go stale:
	- OWNED is cached for the whole session. Ownership is not revocable in any
	  way that matters mid-session, and being wrong here would mean underpaying
	  someone who paid.
	- NOT OWNED is re-checked after NEGATIVE_CACHE_SECONDS. A player can buy a
	  pass from the Roblox website mid-session, where no in-experience event
	  fires, so a permanent negative cache would leave them unpaid until they
	  rejoined. Five minutes bounds that without going back to per-checkpoint
	  requests.
	Purchases made through an in-experience prompt do fire an event, and that
	clears the entry immediately rather than waiting out the TTL.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))

local NEGATIVE_CACHE_SECONDS = 300

local MonetizationService = {}

type CacheEntry = {
	Owns: boolean,
	CheckedAt: number,
}

-- [UserId][passKey] -> entry. Keyed by UserId rather than by the Player
-- instance so a stale entry cannot pin a leaving player's object in memory.
local ownershipCache: { [number]: { [string]: CacheEntry } } = {}

local function cacheFor(userId: number) : { [string]: CacheEntry }
	local entries = ownershipCache[userId]
	if entries == nil then
		entries = {}
		ownershipCache[userId] = entries
	end
	return entries
end

function MonetizationService.PlayerOwnsGamePass(player: Player, passKey: string) : boolean
	local passEntry = MonetizationConfigs.GamePasses[passKey]
	if passEntry == nil or passEntry.Id == 0 then
		return false
	end

	local entries = cacheFor(player.UserId)
	local cached = entries[passKey]
	if cached ~= nil then
		if cached.Owns then
			return true
		end
		if os.clock() - cached.CheckedAt < NEGATIVE_CACHE_SECONDS then
			return false
		end
	end

	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passEntry.Id)
	end)

	if not success then
		-- Deliberately NOT cached. A failed request is not an answer, and
		-- storing it as "does not own" would hold a paying player at the
		-- un-doubled rate for the next five minutes over one dropped request.
		return false
	end

	entries[passKey] = { Owns = owns == true, CheckedAt = os.clock() }
	return owns == true
end

-- Drops a player's cached answer for one pass, so the next check re-queries.
-- Used when something happens that could genuinely have changed the answer.
function MonetizationService.InvalidateCache(userId: number, passKey: string?)
	local entries = ownershipCache[userId]
	if entries == nil then
		return
	end
	if passKey == nil then
		ownershipCache[userId] = nil
	else
		entries[passKey] = nil
	end
end

-- Maps a raw game pass Id back to its config key, so the purchase event (which
-- only reports an Id) can clear the right cache entry.
local function passKeyForId(gamePassId: number) : string?
	for key, entry in MonetizationConfigs.GamePasses do
		if entry.Id == gamePassId then
			return key
		end
	end
	return nil
end

function MonetizationService.Init()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamePassId: number, wasPurchased: boolean)
		if not wasPurchased then
			return
		end
		local passKey = passKeyForId(gamePassId)
		if passKey ~= nil then
			MonetizationService.InvalidateCache(player.UserId, passKey)
		end
	end)

	-- Without this the cache grows for the lifetime of the server, one entry
	-- per player who ever joined.
	Players.PlayerRemoving:Connect(function(player: Player)
		ownershipCache[player.UserId] = nil
	end)
end

return MonetizationService

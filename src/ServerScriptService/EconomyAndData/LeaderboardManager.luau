--!strict
--[[
	LeaderboardManager
	Cross-server top-10 for the four stadium boards
	(Configs.LeaderboardCategories). This module was a stub whose own TODO
	said real boards would need "a DataStore-backed ordered lookup". This is
	that lookup.

	## Why OrderedDataStore and not the profile store

	ProfileStore keys are per-player and readable only by the server holding
	that player's session lock, so there is no way to ask it "who has the most
	gold across the whole game". An OrderedDataStore is Roblox's only built-in
	answer to that question, so each category gets one, keyed by UserId with
	the ranked number as the value.

	## Write policy: only on change, on a fixed cadence

	Publishing on every profile mutation would mean a DataStore write per lap,
	per deposit, per purchase. Instead each player's four values are compared
	against what was last actually published for them and written only when
	one has moved, on a PUBLISH_INTERVAL_SECONDS cycle plus once on leave. In
	steady state most cycles write nothing.

	## Reads are cached server-wide, not per-viewer

	GetSortedAsync runs once per category per REFRESH_INTERVAL_SECONDS for the
	whole server; board rendering reads the cache. Eight board faces looking at
	the same data must not mean eight queries.

	Display names are resolved once per UserId and cached for the server's
	lifetime — GetNameFromUserIdAsync is a web call and names rarely change.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LeaderboardCategories = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("LeaderboardCategories"))

local ProfileManager = require(script.Parent:WaitForChild("ProfileManager"))

local TOP_N = 10
local REFRESH_INTERVAL_SECONDS = 60
local PUBLISH_INTERVAL_SECONDS = 120
-- Bumping this starts every board from empty. Only change it if a category's
-- MEANING changes (e.g. lap times switching units), never for a cosmetic edit.
local STORE_VERSION = "v1"

export type LeaderboardEntry = {
	UserId: number,
	DisplayName: string,
	Value: number,
}

local LeaderboardManager = {}

local storeByCategoryId: { [string]: OrderedDataStore } = {}
local cachedTopByCategoryId: { [string]: { LeaderboardEntry } } = {}
-- What was last actually WRITTEN for a player, per category — the thing new
-- values are compared against to decide whether a write is needed at all.
local publishedByPlayer: { [Player]: { [string]: number } } = {}
local displayNameByUserId: { [number]: string } = {}

-- Fires after every refresh, so board renderers redraw on a signal instead of
-- polling on their own timer and drifting out of step with the cache.
local changedSignal = Instance.new("BindableEvent")
LeaderboardManager.Changed = changedSignal.Event

function LeaderboardManager.GetTop(categoryId: string) : { LeaderboardEntry }
	return cachedTopByCategoryId[categoryId] or {}
end

local function resolveDisplayName(userId: number) : string
	local cached = displayNameByUserId[userId]
	if cached ~= nil then
		return cached
	end

	-- Someone already in this server needs no web call at all.
	local livePlayer = Players:GetPlayerByUserId(userId)
	if livePlayer ~= nil then
		displayNameByUserId[userId] = livePlayer.DisplayName
		return livePlayer.DisplayName
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	-- A failed lookup is cached as a placeholder ON PURPOSE. Without it, a
	-- deleted or throttled account would be re-queried on every refresh
	-- forever — which is how a decorative board quietly becomes a rate-limit
	-- generator.
	local resolved = if ok and typeof(name) == "string" then name else `Racer {userId}`
	displayNameByUserId[userId] = resolved
	return resolved
end

local function refreshCategory(category: LeaderboardCategories.LeaderboardCategory)
	local store = storeByCategoryId[category.Id]
	if store == nil then
		return
	end

	-- ascending = true puts the SMALLEST value first, which is what a
	-- fastest-lap board wants and the exact opposite of the other three.
	local ok, pages = pcall(function()
		return store:GetSortedAsync(category.LowerIsBetter, TOP_N)
	end)
	if not ok or pages == nil then
		return
	end

	local okPage, page = pcall(function()
		return pages:GetCurrentPage()
	end)
	if not okPage or page == nil then
		return
	end

	local entries: { LeaderboardEntry } = {}
	for _, row in page do
		local userId = tonumber(row.key)
		local value = tonumber(row.value)
		if userId ~= nil and value ~= nil and not (category.ExcludeZero and value <= 0) then
			table.insert(entries, {
				UserId = userId,
				DisplayName = resolveDisplayName(userId),
				Value = value,
			})
		end
	end

	cachedTopByCategoryId[category.Id] = entries
end

-- Publishes one player's current values, writing only what actually moved.
local function publishPlayer(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local published = publishedByPlayer[player]
	if published == nil then
		published = {}
		publishedByPlayer[player] = published
	end

	for _, category in LeaderboardCategories.Ordered do
		local raw = (profile.Data :: any)[category.ProfileField]
		if typeof(raw) ~= "number" then
			continue
		end
		-- OrderedDataStore values must be integers.
		local value = math.floor(raw)

		if category.ExcludeZero and value <= 0 then
			continue
		end
		if published[category.Id] == value then
			continue -- nothing moved since the last publish; no write
		end

		local store = storeByCategoryId[category.Id]
		if store == nil then
			continue
		end

		local ok = pcall(function()
			store:SetAsync(tostring(player.UserId), value)
		end)
		if ok then
			published[category.Id] = value
		end
	end
end

LeaderboardManager.PublishPlayer = publishPlayer

function LeaderboardManager.Init()
	-- An unpublished place (PlaceId 0) has no DataStore access at all and
	-- every call would throw. Boards then render empty, which is the right
	-- degradation for something informative but not load-bearing.
	if game.PlaceId ~= 0 then
		for _, category in LeaderboardCategories.Ordered do
			local ok, store = pcall(function()
				return DataStoreService:GetOrderedDataStore(`Leaderboard_{category.Id}_{STORE_VERSION}`)
			end)
			if ok then
				storeByCategoryId[category.Id] = store
			end
		end
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		-- Last chance to capture this session's progress for the boards; the
		-- profile is about to be released.
		publishPlayer(player)
		publishedByPlayer[player] = nil
	end)

	task.spawn(function()
		while true do
			for _, category in LeaderboardCategories.Ordered do
				refreshCategory(category)
			end
			changedSignal:Fire()
			task.wait(REFRESH_INTERVAL_SECONDS)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(PUBLISH_INTERVAL_SECONDS)
			for _, player in Players:GetPlayers() do
				publishPlayer(player)
			end
		end
	end)
end

return LeaderboardManager

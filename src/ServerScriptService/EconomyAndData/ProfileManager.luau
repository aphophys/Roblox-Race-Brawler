--!strict
--[[
	ProfileManager
	Loads, session-locks, and releases each player's ProfileStore profile.
	This is the single source of truth for in-memory profile access —
	other server modules must go through ProfileManager.GetProfile(), never
	require ProfileStore directly.

	Uses ProfileStore (github.com/MadStudioRoblox/ProfileStore), the
	actively-maintained successor to the older ProfileService library,
	installed via Wally as `lm-loleris/profilestore` (see wally.toml).
	Profile data lives at `profile.Data`, typed as ProfileData.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local ProfileStore = require(ServerScriptService:WaitForChild("Packages"):WaitForChild("ProfileStore"))
local ProfileTemplate = require(
	ServerStorage:WaitForChild("PlayerDataTemplates"):WaitForChild("ProfileTemplate")
) :: any

type ProfileData = typeof(ProfileTemplate)
type Profile = typeof(ProfileStore.New("", ProfileTemplate):StartSessionAsync())

local PROFILE_STORE_NAME = "PlayerData_v1"

local ProfileManager = {}

local playerStore = ProfileStore.New(PROFILE_STORE_NAME, ProfileTemplate)
local activeProfiles: { [Player]: Profile } = {}

-- Returns the loaded profile for a player, or nil if not yet loaded /
-- session-lock failed. Callers must nil-check before use. Access saved
-- data via profile.Data (typed as ProfileData).
function ProfileManager.GetProfile(player: Player) : Profile?
	return activeProfiles[player]
end

-- Copies the subset of profile.Data that client UI needs to display onto
-- player Attributes (Gold, TotalFans, Lives) — the only replication path
-- currently wired up. IMPORTANT: this is a one-shot copy, not a live
-- binding. Anything that mutates these fields on profile.Data later (shop
-- purchases, fan deposits, life loss) must call this again afterward, or
-- the client-facing attribute will silently go stale. No such mutation
-- exists yet (HubShoppingManager/fan deposit flow are still stubs), so
-- today this only ever reflects each player's starting values.
function ProfileManager.SyncAttributes(player: Player)
	local profile = activeProfiles[player]
	if profile == nil then
		return
	end

	player:SetAttribute("Gold", profile.Data.Gold)
	player:SetAttribute("TotalFans", profile.Data.TotalFans)
	player:SetAttribute("Lives", profile.Data.Lives)
end

local function onPlayerAdded(player: Player)
	local profile = playerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			-- Abort the session claim if the player leaves mid-load rather
			-- than holding a lock for someone who's already gone.
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		-- Session-lock could not be claimed (e.g. joined another server
		-- mid-swap); kick rather than let them play on stale/no data.
		player:Kick("Failed to load your data. Please rejoin.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile() -- fills in any keys added to ProfileTemplate since this save was created

	profile.OnSessionEnd:Connect(function()
		activeProfiles[player] = nil
		player:Kick("Your data session ended. Please rejoin.")
	end)

	if player.Parent ~= Players then
		-- Player left while the profile was loading.
		profile:EndSession()
		return
	end

	activeProfiles[player] = profile
	ProfileManager.SyncAttributes(player)

	-- TODO: fire a "ProfileReady" signal here for modules that need to react
	-- to a freshly loaded profile (e.g. leaderstats population).
end

local function onPlayerRemoving(player: Player)
	local profile = activeProfiles[player]
	if profile ~= nil then
		profile:EndSession()
	end
end

function ProfileManager.Init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return ProfileManager

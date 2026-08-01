--!strict
--[[
	LeaderboardManager
	Updates the 3D leaderboards placed in the Commercial Hub (Fans, Gold,
	Laps). Polls on an interval rather than per-write to keep SurfaceGui
	updates cheap.
]]

local LeaderboardManager = {}

local UPDATE_INTERVAL_SECONDS = 30

local function refreshBoards()
	-- TODO: query top N profiles (requires a DataStore-backed ordered
	-- lookup, or an in-memory cache updated as players deposit fans) and
	-- write to each board's SurfaceGui labels.
end

function LeaderboardManager.Init()
	task.spawn(function()
		while true do
			refreshBoards()
			task.wait(UPDATE_INTERVAL_SECONDS)
		end
	end)
end

return LeaderboardManager

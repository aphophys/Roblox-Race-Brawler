--!strict
--[[
	FanIncomeService
	Passive Gold income from Fans: every EconomyRates.FanIncomeIntervalSeconds
	(5 minutes), each player earns EconomyRates.FanIncomeGoldPerFan of Gold per
	Fan they hold.

	## Why this exists

	Fans were a stat that only fed the fan-box crowd size and the leaderboard.
	Gold is the spendable currency. This makes accumulating fans pay a return,
	so the two currencies relate to each other instead of being parallel
	scores.

	## Entirely server-owned

	The interval is a server task loop, the fan count is read from the
	server-held profile, and the Gold is written to that same profile. There
	is no remote, no client input, and nothing the client can call — a client
	cannot request a payout, accelerate the timer, or influence the amount.
	The only thing that crosses to the client is the resulting notification
	and the attribute refresh.

	## Why a single shared timer, not a per-player one

	One loop paying everyone on the same cadence means a player cannot farm
	partial intervals by rejoining: their next payment lands on the server's
	schedule regardless of when they arrived. It also keeps the cost flat at
	one pass per interval no matter how many players are in the server.

	Payments are floored to whole Gold, so a player below the threshold for a
	single Gold earns nothing rather than accumulating hidden fractions —
	which keeps the profile an integer store and the displayed number honest.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local ProfileManager = require(script.Parent:WaitForChild("ProfileManager"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))

local FanIncomeService = {}

-- Returns the Gold this player would be paid right now, or 0. Exposed so the
-- payout amount has exactly one definition — a UI that wants to preview
-- "your fans earn N gold every 5 minutes" must not compute it a second way.
function FanIncomeService.ComputePayout(player: Player) : number
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return 0
	end

	local payout = profile.Data.TotalFans * EconomyRates.FanIncomeGoldPerFan
	if MonetizationService.PlayerOwnsGamePass(player, "DoubleFans") then
		-- "Double Gain Fans and Gold" — this is Gold gain, so it applies, the
		-- same as at every other payout site.
		payout *= EconomyRates.DoubleGainMultiplier
	end
	return math.floor(payout)
end

local function payPlayer(player: Player)
	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return
	end

	local payout = FanIncomeService.ComputePayout(player)
	if payout <= 0 then
		-- Not enough fans to round up to a single Gold yet. Saying nothing is
		-- deliberate: a "+0" toast every five minutes would be noise.
		return
	end

	profile.Data.Gold += payout
	ProfileManager.SyncAttributes(player)
	SoundDirector.PlayForPlayer(player, "GoldGain")
	Network.Track.ShowNotification:FireClient(
		player,
		`FAN INCOME +{Utils.FormatNumber(payout)} 💰`,
		"Pop"
	)
end

function FanIncomeService.Init()
	task.spawn(function()
		while true do
			task.wait(EconomyRates.FanIncomeIntervalSeconds)
			for _, player in Players:GetPlayers() do
				payPlayer(player)
			end
		end
	end)
end

return FanIncomeService

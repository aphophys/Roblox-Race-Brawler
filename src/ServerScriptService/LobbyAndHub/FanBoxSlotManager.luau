--!strict
--[[
	FanBoxSlotManager
	Dynamically allocates one of the Outer Ring Fan Box pods (built by
	FanBoxGenerator) per active player and releases it back to the pool
	when they leave. Assignment works by renaming the pod's Model from
	"__EmptySlot_<n>" to the player's name and back. This is the whole
	requirement — unclaimed pods are NOT hidden (a pod always shows a
	crowd, Tier1 by default); the only real constraint is that each player
	holds exactly one pod for as long as they're in the server.

	AssignSlot discovers empty pods by walking the FanBoxes folder's actual
	children instead of looping a fixed slot count — FanBoxGenerator's pod
	count scales with Players.MaxPlayers, so a separate hardcoded slot
	count here would drift out of sync with whatever FanBoxGenerator
	actually built. Each pod's own "SlotIndex" attribute (set by
	FanBoxGenerator.buildPod) is the source of truth for its slot number.

	AssignSlot swaps in the tier template that actually matches the
	assigned player's current TotalFans; a live
	GetAttributeChangedSignal("TotalFans") connection (tracked per player,
	disconnected on release) keeps a pod's crowd graduating to a bigger
	tier template as its occupant's fan count grows. ReleaseSlot resets the
	pod back to Tier1 before returning it to the pool, so a freshly-vacated
	box doesn't keep showing the departed player's crowd size forever.
]]

local Players = game:GetService("Players")

local FanBoxGenerator = require(script.Parent:WaitForChild("FanBoxGenerator"))
local FanBoxCrowdTemplates = require(script.Parent:WaitForChild("FanBoxCrowdTemplates"))
local FanBoxRecordsBoard = require(script.Parent:WaitForChild("FanBoxRecordsBoard"))

local DEFAULT_TIER_INDEX = 1 -- "Empty" — what a pod resets to when released

local FanBoxSlotManager = {}

local slotIndexByPlayer: { [Player]: number } = {}
-- A LIST per player, not a single connection: the pod now reacts to four
-- attributes rather than one (the records board shows gold, laps and best lap
-- alongside fans). Storing one connection and overwriting it would silently
-- leak the previous three.
local podConnectionsByPlayer: { [Player]: { RBXScriptConnection } } = {}

-- Everything the pod's crowd size or records board is derived from. All four
-- are already mirrored onto the Player by ProfileManager.SyncAttributes, so
-- these listeners fire off the signal the rest of the game is already
-- producing rather than adding a poll.
local POD_ATTRIBUTES = { "TotalFans", "Gold", "TotalLapsCompleted", "BestLapTimeMs" }

local function getFanBoxFolder() : Folder?
	return workspace:FindFirstChild("FanBoxes") :: Folder?
end

local function updatePodTierForPlayer(player: Player, pod: Instance)
	local fanCount = (player:GetAttribute("TotalFans") :: number?) or 0
	local tierIndex = FanBoxCrowdTemplates.GetTierIndexForFanCount(fanCount)
	FanBoxGenerator.SwapPodTier(pod :: Model, tierIndex)
	-- Redrawn AFTER the tier swap, not before: SwapPodTier rebuilds the pod's
	-- crowd mesh, and the board is re-attached by Render if that pass removed
	-- it. Also means the numbers on the board and the size of the crowd
	-- standing next to them always change in the same frame.
	FanBoxRecordsBoard.Render(pod :: Model, player)
end

function FanBoxSlotManager.AssignSlot(player: Player) : number?
	local fanBoxFolder = getFanBoxFolder()
	if fanBoxFolder == nil then
		return nil
	end

	for _, pod in fanBoxFolder:GetChildren() do
		if pod.Name:sub(1, 12) == "__EmptySlot_" then
			local slotIndex = pod:GetAttribute("SlotIndex")
			if typeof(slotIndex) == "number" then
				pod.Name = player.Name
				updatePodTierForPlayer(player, pod)
				slotIndexByPlayer[player] = slotIndex

				local connections: { RBXScriptConnection } = {}
				for _, attributeName in POD_ATTRIBUTES do
					table.insert(connections, player:GetAttributeChangedSignal(attributeName):Connect(function()
						updatePodTierForPlayer(player, pod)
					end))
				end
				podConnectionsByPlayer[player] = connections

				return slotIndex
			end
		end
	end

	return nil -- every pod currently occupied
end

function FanBoxSlotManager.ReleaseSlot(player: Player)
	local slotIndex = slotIndexByPlayer[player]
	if slotIndex == nil then
		return
	end

	local connections = podConnectionsByPlayer[player]
	if connections ~= nil then
		for _, connection in connections do
			connection:Disconnect()
		end
		podConnectionsByPlayer[player] = nil
	end

	local fanBoxFolder = getFanBoxFolder()
	local occupiedPod = fanBoxFolder and fanBoxFolder:FindFirstChild(player.Name)
	if occupiedPod ~= nil then
		FanBoxGenerator.SwapPodTier(occupiedPod :: Model, DEFAULT_TIER_INDEX)
		FanBoxRecordsBoard.Clear(occupiedPod :: Model)
		occupiedPod.Name = `__EmptySlot_{slotIndex}`
	end

	slotIndexByPlayer[player] = nil
end

function FanBoxSlotManager.Init()
	Players.PlayerAdded:Connect(function(player: Player)
		FanBoxSlotManager.AssignSlot(player)
	end)

	Players.PlayerRemoving:Connect(FanBoxSlotManager.ReleaseSlot)

	for _, player in Players:GetPlayers() do
		FanBoxSlotManager.AssignSlot(player)
	end
end

return FanBoxSlotManager

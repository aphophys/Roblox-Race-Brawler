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

local DEFAULT_TIER_INDEX = 1 -- "Empty" — what a pod resets to when released

local FanBoxSlotManager = {}

local slotIndexByPlayer: { [Player]: number } = {}
local tierConnectionByPlayer: { [Player]: RBXScriptConnection } = {}

local function getFanBoxFolder() : Folder?
	return workspace:FindFirstChild("FanBoxes") :: Folder?
end

local function updatePodTierForPlayer(player: Player, pod: Instance)
	local fanCount = (player:GetAttribute("TotalFans") :: number?) or 0
	local tierIndex = FanBoxCrowdTemplates.GetTierIndexForFanCount(fanCount)
	FanBoxGenerator.SwapPodTier(pod :: Model, tierIndex)
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

				tierConnectionByPlayer[player] = player:GetAttributeChangedSignal("TotalFans"):Connect(function()
					updatePodTierForPlayer(player, pod)
				end)

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

	local connection = tierConnectionByPlayer[player]
	if connection ~= nil then
		connection:Disconnect()
		tierConnectionByPlayer[player] = nil
	end

	local fanBoxFolder = getFanBoxFolder()
	local occupiedPod = fanBoxFolder and fanBoxFolder:FindFirstChild(player.Name)
	if occupiedPod ~= nil then
		FanBoxGenerator.SwapPodTier(occupiedPod :: Model, DEFAULT_TIER_INDEX)
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

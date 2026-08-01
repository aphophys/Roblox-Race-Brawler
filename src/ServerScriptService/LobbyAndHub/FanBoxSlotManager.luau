--!strict
--[[
	FanBoxSlotManager
	Dynamically allocates one of the 20 Outer Ring Fan Box pods (built by
	FanBoxGenerator) per active player and releases it back to the pool
	when they leave. Assignment works by renaming the pod's Model from
	"__EmptySlot_<n>" to the player's name and back — FansBoxRenderer
	(client) looks up a player's pod by name, so no separate lookup table
	is needed there.
]]

local Players = game:GetService("Players")

local TOTAL_SLOTS = 20 -- matches FanBoxGenerator: 12 Straight + 8 Curve pods

local FanBoxSlotManager = {}

local slotIndexByPlayer: { [Player]: number } = {}

local function getFanBoxFolder() : Folder?
	return workspace:FindFirstChild("FanBoxes") :: Folder?
end

function FanBoxSlotManager.AssignSlot(player: Player) : number?
	local fanBoxFolder = getFanBoxFolder()
	if fanBoxFolder == nil then
		return nil
	end

	for slotIndex = 1, TOTAL_SLOTS do
		local emptyPod = fanBoxFolder:FindFirstChild(`__EmptySlot_{slotIndex}`)
		if emptyPod ~= nil then
			emptyPod.Name = player.Name
			slotIndexByPlayer[player] = slotIndex
			return slotIndex
		end
	end

	return nil -- all 20 slots occupied
end

function FanBoxSlotManager.ReleaseSlot(player: Player)
	local slotIndex = slotIndexByPlayer[player]
	if slotIndex == nil then
		return
	end

	local fanBoxFolder = getFanBoxFolder()
	local occupiedPod = fanBoxFolder and fanBoxFolder:FindFirstChild(player.Name)
	if occupiedPod ~= nil then
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

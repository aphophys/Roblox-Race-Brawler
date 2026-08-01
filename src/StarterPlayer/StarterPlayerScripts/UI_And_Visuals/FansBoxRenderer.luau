--!strict
--[[
	FansBoxRenderer
	Client-side visual scaffolding for the Outer Ring Dynamic Fan Boxes.
	Watches each player's replicated fan count and swaps/tweens the Part
	representing their box's crowd size. Deliberately mesh/CFrame driven —
	no Humanoid involved, keeps the outer ring cheap on mobile.

	Assumes TotalFans is replicated per-player via Player:GetAttribute
	("TotalFans") — set server-side once ProfileManager exposes a
	replication hook (TODO, not part of this scaffold).

	Structured as a ModuleScript (Init() pattern) rather than a bare
	LocalScript so it can be required from the single StarterPlayerScripts
	bootstrap alongside the rest of UI_And_Visuals, keeping one entry point
	on the client instead of many independently-running Scripts.

	Looks up a player's pod by name under workspace.FanBoxes — matches
	FanBoxSlotManager (server), which renames each pod's Model from
	"__EmptySlot_<n>" to the occupying player's name.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local FanBoxTiers = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("FanBoxTiers"))

local TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local FansBoxRenderer = {}

-- CrowdMesh is a plain Part (greybox placeholder — no Toolbox access to
-- source an actual mesh asset), not a MeshPart; check BasePart broadly so
-- this keeps working once/if it's swapped for a real MeshPart later.
local function findFanBoxCrowdPart(player: Player) : BasePart?
	local fanBoxFolder = workspace:FindFirstChild("FanBoxes")
	if fanBoxFolder == nil then
		return nil
	end

	local pod = fanBoxFolder:FindFirstChild(player.Name)
	if pod == nil then
		return nil
	end

	local crowdPart = pod:FindFirstChild("CrowdMesh")
	if crowdPart ~= nil and crowdPart:IsA("BasePart") then
		return crowdPart
	end

	return nil
end

local function tierForFanCount(fanCount: number)
	local selected = FanBoxTiers.Tiers[1]
	for _, tier in FanBoxTiers.Tiers do
		if fanCount >= tier.MinFans then
			selected = tier
		end
	end
	return selected
end

local function applyFanCountVisual(player: Player, fanCount: number)
	local crowdPart = findFanBoxCrowdPart(player)
	if crowdPart == nil then
		return
	end

	local tier = tierForFanCount(fanCount)

	-- TODO: swap to distinct crowd-density meshes per tier once
	-- Assets/VFX_Library / FanBox_Templates content exists; for now we only
	-- tween the scale as a placeholder visual signal. FanBoxTiers.PodBaseSize
	-- is the shared unscaled size FanBoxGenerator builds every pod at, so
	-- this computes the same absolute target size without reading back
	-- whatever scale the pod happens to be at right now.
	local tween = TweenService:Create(crowdPart, TWEEN_INFO, { Size = FanBoxTiers.PodBaseSize * tier.MeshScale })
	tween:Play()
end

local function bindPlayer(player: Player)
	applyFanCountVisual(player, (player:GetAttribute("TotalFans") :: number?) or 0)

	player:GetAttributeChangedSignal("TotalFans"):Connect(function()
		local fanCount = (player:GetAttribute("TotalFans") :: number?) or 0
		applyFanCountVisual(player, fanCount)
	end)
end

function FansBoxRenderer.Init()
	Players.PlayerAdded:Connect(bindPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(bindPlayer, player)
	end
end

return FansBoxRenderer

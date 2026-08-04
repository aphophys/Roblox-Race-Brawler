--!strict
--[[
	EliminationPromptController
	The revive-purchase prompt (StarterGui.MainHUD.EliminationPanel) shown
	when ArcadeManager.HandleTrackViolation takes a player's last life.
	Per explicit clarification ("pause means allow player to be able to
	choose or auto transport to commercial when expire, not pause game"),
	the game itself never pauses — this is purely a client-side countdown
	UI layered over a server-side timeout (ArcadeManager's
	eliminationTimers) that already runs regardless of what this panel
	does. If the player buys (either currency) or the timeout elapses,
	the server fires EliminationResolved and this panel just reacts.

	The countdown shown here is COSMETIC — it's seeded from the
	timeoutSeconds PlayerEliminated sends and ticks down locally, but the
	actual auto-return decision is made server-side by ArcadeManager's
	task.delay. A client-side hiccup here never desyncs the real outcome.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))

local localPlayer = Players.LocalPlayer

local EliminationPromptController = {}

local countdownThread: thread? = nil
local goldRevivesRemainingToday = 0

local function getPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local panel = mainHud and mainHud:FindFirstChild("EliminationPanel")
	return panel :: Frame?
end

local function getCard() : Frame?
	local panel = getPanel()
	local card = panel and panel:FindFirstChild("Card")
	return card :: Frame?
end

local function stopCountdown()
	if countdownThread ~= nil then
		task.cancel(countdownThread)
		countdownThread = nil
	end
end

local function updateGoldButton(goldCost: number)
	local card = getCard()
	local goldButton = card and card:FindFirstChild("GoldButton") :: TextButton?
	if goldButton == nil then
		return
	end

	if goldRevivesRemainingToday > 0 then
		goldButton.Text = `REVIVE — {goldCost} GOLD ({goldRevivesRemainingToday} left today)`
		goldButton.BackgroundColor3 = Color3.fromRGB(255, 199, 43)
		goldButton.AutoButtonColor = true
	else
		goldButton.Text = "NO GOLD REVIVES LEFT TODAY"
		goldButton.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
		goldButton.AutoButtonColor = false
	end
end

local function startCountdown(timeoutSeconds: number)
	stopCountdown()

	local card = getCard()
	local countdownLabel = card and card:FindFirstChild("CountdownLabel") :: TextLabel?
	if countdownLabel == nil then
		return
	end

	countdownThread = task.spawn(function()
		local remaining = timeoutSeconds
		while remaining > 0 do
			countdownLabel.Text = `Returning to Hub in {math.ceil(remaining)}s...`
			task.wait(0.5)
			remaining -= 0.5
		end
		countdownLabel.Text = "Returning to Hub..."
	end)
end

local function onPlayerEliminated(timeoutSeconds: unknown, goldCost: unknown, remainingToday: unknown)
	if typeof(timeoutSeconds) ~= "number" or typeof(goldCost) ~= "number" or typeof(remainingToday) ~= "number" then
		return
	end

	goldRevivesRemainingToday = remainingToday
	updateGoldButton(goldCost)
	startCountdown(timeoutSeconds)

	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = true
	end
end

local function onEliminationResolved(_revived: unknown)
	stopCountdown()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = false
	end
end

local function promptRobuxRevive()
	local product = MonetizationConfigs.DeveloperProducts.ExtraLife
	if product.Id == 0 then
		warn("EliminationPromptController: ExtraLife has no configured Product Id yet — add it in MonetizationConfigs.luau.")
		return
	end
	MarketplaceService:PromptProductPurchase(localPlayer, product.Id)
end

local function requestGoldRevive()
	if goldRevivesRemainingToday <= 0 then
		return
	end
	Network.Track.BuyExtraLifeWithGold:FireServer()
end

function EliminationPromptController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local panel = mainHud:WaitForChild("EliminationPanel") :: Frame
	local card = panel:WaitForChild("Card")
	local robuxButton = card:WaitForChild("RobuxButton") :: TextButton
	local goldButton = card:WaitForChild("GoldButton") :: TextButton

	robuxButton.Activated:Connect(promptRobuxRevive)
	goldButton.Activated:Connect(requestGoldRevive)

	Network.Track.PlayerEliminated.OnClientEvent:Connect(onPlayerEliminated)
	Network.Track.EliminationResolved.OnClientEvent:Connect(onEliminationResolved)
end

return EliminationPromptController

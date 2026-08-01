--!strict
--[[
	ShopUIController
	Commercial Hub buying interface. Reads prices from ReplicatedStorage.
	Configs (EconomyRates/SkillTrees) for display; server re-validates on
	purchase via Network.Economy.PurchaseItem.

	Also owns the Robux purchase prompts (developer products / game passes)
	— MarketplaceService:PromptProductPurchase/PromptGamePassPurchase are
	client-only calls, no remote round-trip needed for the prompt itself;
	only the grant (ProcessReceiptManager, server) needs to be trusted.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))

local localPlayer = Players.LocalPlayer

local ShopUIController = {}

function ShopUIController.Open()
	-- TODO: show shop frame, populate from EconomyRates/SkillTrees configs.
	-- No shop frame exists yet — SettingsButton calling this is currently a
	-- no-op until one is built.
end

function ShopUIController.Close()
	-- TODO: hide shop frame.
end

function ShopUIController.RequestPurchase(itemId: string)
	Network.Economy.PurchaseItem:FireServer(itemId)
end

-- Prompts a Robux purchase for a MonetizationConfigs.DeveloperProducts
-- entry. No-ops with a warning if that product's Id is still 0
-- (unconfigured placeholder) rather than sending Roblox an invalid prompt.
function ShopUIController.PromptRobuxProduct(productKey: string)
	local product = MonetizationConfigs.DeveloperProducts[productKey]
	if product == nil or product.Id == 0 then
		warn(`ShopUIController: "{productKey}" has no configured Product Id yet — add it in MonetizationConfigs.luau.`)
		return
	end
	MarketplaceService:PromptProductPurchase(localPlayer, product.Id)
end

-- Prompts a Robux purchase for a MonetizationConfigs.GamePasses entry.
function ShopUIController.PromptGamePassPurchase(passKey: string)
	local pass = MonetizationConfigs.GamePasses[passKey]
	if pass == nil or pass.Id == 0 then
		warn(`ShopUIController: "{passKey}" has no configured Game Pass Id yet — add it in MonetizationConfigs.luau.`)
		return
	end
	MarketplaceService:PromptGamePassPurchase(localPlayer, pass.Id)
end

function ShopUIController.Init()
	-- TODO: connect Hub trigger (proximity prompt / zone) to Open/Close.

	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local topRight = mainHud:WaitForChild("TopRight")
	local settingsButton = topRight:WaitForChild("SettingsButton") :: TextButton

	settingsButton.Activated:Connect(ShopUIController.Open)
end

return ShopUIController

--!strict
--[[
	ShopUIController
	The Robux Shop modal (StarterGui.MainHUD.RobuxShopPanel), opened from
	the left-side menu bar's RobuxShopButton. Lists every
	MonetizationConfigs.DeveloperProducts / GamePasses entry as a fixed,
	pre-named button (only 6 total today, so no clone-template needed) —
	each one labeled with its human-friendly name/grant amount and wired to
	the matching Prompt call below.

	Owns the Robux purchase prompts themselves — MarketplaceService:
	PromptProductPurchase/PromptGamePassPurchase are client-only calls, no
	remote round-trip needed for the prompt; only the grant
	(ProcessReceiptManager, server) needs to be trusted.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))
local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))

local localPlayer = Players.LocalPlayer

local ShopUIController = {}

local function getPanel() : Frame?
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	local panel = mainHud and mainHud:FindFirstChild("RobuxShopPanel")
	return panel :: Frame?
end

function ShopUIController.Open()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = true
	end
end

function ShopUIController.Close()
	local panel = getPanel()
	if panel ~= nil then
		panel.Visible = false
	end
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

-- productKey/passKey <-> the fixed button names declared in
-- default.project.json's RobuxShopPanel.Card.ProductList.
local DEVELOPER_PRODUCT_BUTTONS = { "GoldSmall", "GoldMedium", "GoldLarge", "FanBoost" }
-- ExclusivePoseBundle deliberately excluded — see MonetizationConfigs'
-- docstring; it isn't defined there right now, so listing it here would
-- just no-op (MonetizationConfigs.GamePasses[key] would be nil).
local GAME_PASS_BUTTONS = { "DoubleFans" }

local function labelForProduct(productKey: string) : string
	local product = MonetizationConfigs.DeveloperProducts[productKey]
	local currencyEmoji = if product.GrantCurrency == "Gold" then "🪙" else "🌟"
	return `{currencyEmoji} {Utils.FormatNumber(product.GrantAmount)} {product.GrantCurrency}`
end

local function wireProductList(panel: Frame)
	local card = panel:FindFirstChild("Card")
	local productList = card and card:FindFirstChild("ProductList")
	if productList == nil then
		return
	end

	for _, productKey in DEVELOPER_PRODUCT_BUTTONS do
		local button = productList:FindFirstChild(`{productKey}Button`) :: TextButton?
		if button ~= nil then
			button.Text = labelForProduct(productKey)
			button.Activated:Connect(function()
				ShopUIController.PromptRobuxProduct(productKey)
			end)
		end
	end

	for _, passKey in GAME_PASS_BUTTONS do
		local button = productList:FindFirstChild(`{passKey}Button`) :: TextButton?
		if button ~= nil then
			local pass = MonetizationConfigs.GamePasses[passKey]
			button.Text = `{pass.Name} — {pass.Description}`
			button.Activated:Connect(function()
				ShopUIController.PromptGamePassPurchase(passKey)
			end)
		end
	end
end

-- RobuxShopButton's Icon child is a placeholder ("" Image) until a real one
-- is sourced — same fallback convention as SkillTrees.IconAssetId: falls
-- back to the button's own Text (already set in default.project.json) when
-- there's no icon to show instead.
local function applyIconFallback(button: TextButton)
	local icon = button:FindFirstChild("Icon") :: ImageLabel?
	if icon ~= nil and icon.Image ~= "" then
		icon.Visible = true
		button.TextTransparency = 1
	end
end

function ShopUIController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")
	local leftMenuBar = mainHud:WaitForChild("LeftMenuBar")
	local robuxShopButton = leftMenuBar:WaitForChild("RobuxShopButton") :: TextButton
	local panel = mainHud:WaitForChild("RobuxShopPanel") :: TextButton
	local closeButton = (panel:WaitForChild("Card"):WaitForChild("CloseButton")) :: TextButton

	wireProductList(panel :: Frame)

	applyIconFallback(robuxShopButton)
	robuxShopButton.Activated:Connect(ShopUIController.Open)
	closeButton.Activated:Connect(ShopUIController.Close)
	panel.Activated:Connect(ShopUIController.Close) -- backdrop itself: click outside the card to close
end

return ShopUIController

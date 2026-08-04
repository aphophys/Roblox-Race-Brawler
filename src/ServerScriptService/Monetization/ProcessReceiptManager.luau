--!strict
--[[
	ProcessReceiptManager
	Robux developer-product purchase verification. Owns the single
	MarketplaceService.ProcessReceipt callback for the whole game — do not
	set ProcessReceipt anywhere else.

	Grants are idempotent: every receiptInfo.PurchaseId is recorded on the
	buyer's profile before returning PurchaseGranted, so a redelivered
	receipt (Roblox retries until you confirm) never grants twice.

	Refuses to grant for any product whose MonetizationConfigs Id is still
	0 (unconfigured placeholder) — logs a warning and returns
	NotProcessedYet instead of guessing. Real IDs live in exactly one place:
	ReplicatedStorage.Configs.MonetizationConfigs.

	Fires the pooled/stacking toast (Network.Track.ShowNotification, "Pop"
	style — the bouncy currency-gain effect) on every successful grant, same
	as the other currency-gain sources (CarryItemService's fan deposit,
	CheckpointValidator's lap reward).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfigs = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("MonetizationConfigs"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))
local ProfileManager = require(script.Parent.Parent:WaitForChild("EconomyAndData"):WaitForChild("ProfileManager"))
local ArcadeManager = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("ArcadeManager"))
local SoundDirector = require(script.Parent.Parent:WaitForChild("CoreGameLoop"):WaitForChild("SoundDirector"))

local ProcessReceiptManager = {}

local function findProductByProductId(productId: number) : MonetizationConfigs.DeveloperProductEntry?
	for _, entry in MonetizationConfigs.DeveloperProducts do
		if entry.Id ~= 0 and entry.Id == productId then
			return entry
		end
	end
	return nil
end

local function processReceipt(receiptInfo: any) : Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		-- Not in this server (yet, or left) — Roblox will re-invoke later.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = ProfileManager.GetProfile(player)
	if profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = receiptInfo.PurchaseId :: string
	if profile.Data.GrantedPurchaseIds[purchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = findProductByProductId(receiptInfo.ProductId)
	if product == nil then
		warn(`ProcessReceiptManager: receipt for unconfigured ProductId {receiptInfo.ProductId} — no MonetizationConfigs entry has this Id (still 0?). Not granting.`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if product.GrantCurrency == "Gold" then
		profile.Data.Gold += product.GrantAmount
	elseif product.GrantCurrency == "TotalFans" then
		profile.Data.TotalFans += product.GrantAmount
	end
	-- ExtraLife doesn't touch profile.Data here — ArcadeManager.GrantExtraLife
	-- (called below) owns the Lives increment itself, since unlike Gold/Fans
	-- it also needs to resolve a pending elimination-prompt timeout.

	profile.Data.GrantedPurchaseIds[purchaseId] = true
	ProfileManager.SyncAttributes(player)
	SoundDirector.PlayForPlayer(player, "Purchase")
	if product.GrantCurrency == "Gold" then
		SoundDirector.PlayForPlayer(player, "GoldGain")
	elseif product.GrantCurrency == "TotalFans" then
		SoundDirector.PlayForPlayer(player, "FanGain")
	end

	if product.GrantCurrency == "ExtraLife" then
		ArcadeManager.GrantExtraLife(player)
		Network.Track.ShowNotification:FireClient(player, "+1 LIFE!", "Pop")
	else
		local currencyEmoji = if product.GrantCurrency == "Gold" then "💰" else "🌟" -- 🪙 has no glyph in Roblox's default fonts, renders as an empty box
		Network.Track.ShowNotification:FireClient(
			player,
			`+{Utils.FormatNumber(product.GrantAmount)} {currencyEmoji} {product.GrantCurrency == "Gold" and "GOLD" or "FANS"}!`,
			"Pop"
		)
	end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function ProcessReceiptManager.Init()
	MarketplaceService.ProcessReceipt = processReceipt
end

return ProcessReceiptManager

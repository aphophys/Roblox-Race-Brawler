--!strict
--[[
	QuestUIController
	Renders the quest/achievement ladders (Configs.QuestDefinitions) and
	drives the two entry points into them:

	  MainHUD.LeftMenuBar.QuestButton  — the full panel, all categories,
	                                     sits directly under ROBUX SHOP
	  MainHUD.SpecialTaskButton        — "ADD FANS", top right, opens the
	                                     panel filtered to the Invite ladder

	## Why the client holds no quest state of its own

	Everything rendered here comes from the server's QuestStateChanged
	payload (progress + how many tiers are already claimed, per category) laid
	over the shared QuestDefinitions config. The client never decides whether
	a tier is claimable and never computes a reward — it asks to claim a
	CATEGORY and re-renders whatever the server sends back. So a desynced or
	tampered panel can mislead only the person looking at it.

	## The ADD FANS button hides during a Grand Prix

	It sits at x = 0.72, which is exactly where MainHUD.StandingsPanel (the
	live Grand Prix standings) is anchored — deliberately the same slot, so
	the two take turns rather than overlapping. It is hidden for the whole
	Countdown/Racing window, driven off the same GrandPrixStateChanged remote
	the join button already uses, so the two can never disagree about whether
	a race is on.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local QuestDefinitions = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("QuestDefinitions"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local localPlayer = Players.LocalPlayer

type CategoryState = { Progress: number, ClaimedTiers: number }

local QuestUIController = {}

local questState: { [string]: CategoryState } = {}
-- nil = show every category; a category id = show only that one. This is the
-- only difference between the two buttons, so they share one panel instead
-- of duplicating the whole layout for a single-row variant.
local filterCategoryId: string? = nil

-- Has the player opened ADD FANS yet this session. Deliberately NOT persisted:
-- the badge is an attention cue for a button in a corner, and "reappears next
-- session" is the whole specified behaviour — a client-side flag reset by the
-- next join IS that behaviour, with no profile field and no DataStore cost.
local specialTaskSeenThisSession = false

local panel: Frame? = nil
local categoryList: ScrollingFrame? = nil
local entryTemplate: Frame? = nil
local entryByCategoryId: { [string]: Frame } = {}

local function stateFor(categoryId: string) : CategoryState
	return questState[categoryId] or { Progress = 0, ClaimedTiers = 0 }
end

-- The next unclaimed tier, or nil once a ladder is fully claimed. Mirrors
-- QuestService's own rule exactly — claim order is always claimed + 1 — so
-- the button the player sees corresponds to the claim the server will accept.
local function nextTier(category: QuestDefinitions.QuestCategory, state: CategoryState) : (QuestDefinitions.QuestTier?, number)
	local tierIndex = state.ClaimedTiers + 1
	return category.Tiers[tierIndex], tierIndex
end

local function isClaimable(category: QuestDefinitions.QuestCategory, state: CategoryState) : boolean
	local tier = nextTier(category, state)
	return tier ~= nil and state.Progress >= tier.Requirement
end

local function anyClaimable(onlyCategoryId: string?) : boolean
	for _, category in QuestDefinitions.Categories do
		if onlyCategoryId == nil or category.Id == onlyCategoryId then
			if isClaimable(category, stateFor(category.Id)) then
				return true
			end
		end
	end
	return false
end

local function refreshBadges()
	local playerGui = localPlayer:FindFirstChild("PlayerGui")
	local mainHud = playerGui and playerGui:FindFirstChild("MainHUD")
	if mainHud == nil then
		return
	end

	local questButton = mainHud:FindFirstChild("LeftMenuBar")
	questButton = questButton and questButton:FindFirstChild("QuestButton")
	local questBadge = questButton and questButton:FindFirstChild("ClaimBadge") :: TextLabel?
	if questBadge ~= nil then
		questBadge.Visible = anyClaimable(nil)
	end

	local specialButton = mainHud:FindFirstChild("SpecialTaskButton")
	local specialBadge = specialButton and specialButton:FindFirstChild("ClaimBadge") :: TextLabel?
	if specialBadge ~= nil then
		-- Two independent reasons to badge ADD FANS, OR'd rather than one
		-- replacing the other:
		--   * something is genuinely claimable on the Invite ladder — the
		--     original meaning, and a real signal that must not be silenced
		--     just because the player tapped the button once;
		--   * the player has not opened it yet THIS SESSION — a pure attention
		--     cue for a button that is easy to miss.
		-- Dismissing (below) only clears the second one, so a claimable reward
		-- keeps its badge for as long as it is actually claimable.
		specialBadge.Visible = anyClaimable("Invite") or not specialTaskSeenThisSession
	end
end

local function renderEntry(category: QuestDefinitions.QuestCategory, entry: Frame, layoutOrder: number)
	local state = stateFor(category.Id)
	local tier, tierIndex = nextTier(category, state)

	entry.LayoutOrder = layoutOrder
	entry.Visible = true

	-- Every child resolved into a named local first. A line that STARTS with
	-- "(" directly after another statement is Luau's ambiguous-syntax trap —
	-- it parses as a call on the previous line's value, and `rojo build` does
	-- not catch it. This module has no such line by construction.
	local nameLabel = entry:FindFirstChild("NameLabel") :: TextLabel
	local descriptionLabel = entry:FindFirstChild("DescriptionLabel") :: TextLabel
	local progressLabel = entry:FindFirstChild("ProgressLabel") :: TextLabel
	local claimButton = entry:FindFirstChild("ClaimButton") :: TextButton
	local progressBarBack = entry:FindFirstChild("ProgressBarBack")
	local fill = if progressBarBack ~= nil then progressBarBack:FindFirstChild("Fill") :: Frame? else nil

	nameLabel.Text = category.DisplayName
	descriptionLabel.Text = category.Description

	if tier == nil then
		-- Ladder complete. Deliberately still shows the final requirement
		-- rather than a bare "done", so a player can see what they finished.
		local finalTier = category.Tiers[#category.Tiers]
		progressLabel.Text = `ALL {#category.Tiers} REWARDS CLAIMED ({finalTier.Requirement} {category.ProgressUnit})`
		if fill ~= nil then
			fill.Size = UDim2.fromScale(1, 1)
		end
		claimButton.Text = "DONE"
		claimButton.BackgroundColor3 = Color3.fromRGB(170, 170, 180)
		claimButton.AutoButtonColor = false
		return
	end

	local currency = if category.RewardCurrency == "Gold" then "💰" else "🌟"
	progressLabel.Text = `TIER {tierIndex}/{#category.Tiers} — {math.min(state.Progress, tier.Requirement)}/{tier.Requirement} {category.ProgressUnit} → {Utils.FormatNumber(tier.Reward)} {currency}`

	if fill ~= nil then
		fill.Size = UDim2.fromScale(math.clamp(state.Progress / tier.Requirement, 0, 1), 1)
	end

	if state.Progress >= tier.Requirement then
		claimButton.Text = "CLAIM"
		claimButton.BackgroundColor3 = Color3.fromRGB(51, 191, 115)
		claimButton.AutoButtonColor = true
	else
		claimButton.Text = "LOCKED"
		claimButton.BackgroundColor3 = Color3.fromRGB(170, 170, 180)
		claimButton.AutoButtonColor = false
	end
end

local function renderAll()
	refreshBadges()

	if categoryList == nil or entryTemplate == nil then
		return
	end

	local layoutOrder = 0
	for _, category in QuestDefinitions.Categories do
		local shouldShow = filterCategoryId == nil or filterCategoryId == category.Id

		local entry = entryByCategoryId[category.Id]
		if entry == nil and shouldShow then
			entry = (entryTemplate :: Frame):Clone()
			entry.Name = `Quest_{category.Id}`
			entry.Parent = categoryList
			entryByCategoryId[category.Id] = entry

			-- Bound once per entry, not per render: rebinding on every push
			-- would stack a new connection each time the server ticks.
			local claimButton = entry:FindFirstChild("ClaimButton") :: TextButton
			claimButton.Activated:Connect(function()
				Network.Quests.ClaimQuestTier:FireServer(category.Id)
			end)
		end

		if entry ~= nil then
			if shouldShow then
				layoutOrder += 1
				renderEntry(category, entry, layoutOrder)
			else
				entry.Visible = false
			end
		end
	end
end

local function setPanelOpen(isOpen: boolean, onlyCategoryId: string?)
	filterCategoryId = onlyCategoryId
	if panel ~= nil then
		panel.Visible = isOpen
	end
	if isOpen then
		-- Ask for a fresh payload on open rather than trusting whatever the
		-- last push left behind: the panel is most likely to be opened
		-- precisely because something just changed.
		Network.Quests.RequestQuestState:FireServer()
		renderAll()
	end
end

function QuestUIController.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local mainHud = playerGui:WaitForChild("MainHUD")

	panel = mainHud:WaitForChild("QuestPanel") :: Frame
	categoryList = (panel :: Frame):WaitForChild("CategoryList") :: ScrollingFrame
	entryTemplate = (categoryList :: ScrollingFrame):WaitForChild("EntryTemplate") :: Frame

	local questButton = mainHud:WaitForChild("LeftMenuBar"):WaitForChild("QuestButton") :: TextButton
	local specialButton = mainHud:WaitForChild("SpecialTaskButton") :: TextButton
	local closeButton = (panel :: Frame):WaitForChild("CloseButton") :: TextButton

	questButton.Activated:Connect(function()
		local titleLabel = (panel :: Frame):FindFirstChild("TitleLabel") :: TextLabel
		titleLabel.Text = "QUESTS"
		setPanelOpen(not (panel :: Frame).Visible or filterCategoryId ~= nil, nil)
	end)

	specialButton.Activated:Connect(function()
		-- The attention cue has done its job the moment they press it. Set
		-- before the refresh so the badge state settles in the same frame.
		specialTaskSeenThisSession = true
		refreshBadges()
		local titleLabel = (panel :: Frame):FindFirstChild("TitleLabel") :: TextLabel
		titleLabel.Text = "ADD FANS"
		setPanelOpen(not (panel :: Frame).Visible or filterCategoryId == nil, "Invite")
	end)

	closeButton.Activated:Connect(function()
		setPanelOpen(false, nil)
	end)

	Network.Quests.QuestStateChanged.OnClientEvent:Connect(function(payload: unknown)
		if typeof(payload) ~= "table" then
			return
		end
		questState = payload :: any
		renderAll()
	end)

	-- Top-left belongs to the Grand Prix standings for the duration of a race.
	Network.Track.GrandPrixStateChanged.OnClientEvent:Connect(function(state: unknown)
		specialButton.Visible = state ~= "Countdown" and state ~= "Racing"
	end)

	-- Badge the button immediately, without waiting for the server's quest
	-- payload. The session cue is a purely client-side fact, and the whole
	-- point is that it is showing when the player first looks at the HUD.
	refreshBadges()

	Network.Quests.RequestQuestState:FireServer()
end

return QuestUIController

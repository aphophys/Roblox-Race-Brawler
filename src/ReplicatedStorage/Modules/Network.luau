--!strict
--[[
	Network
	Typed wrapper over the RemoteEvent/RemoteFunction tree declared in
	default.project.json (ReplicatedStorage.RemoteEvents.*). Callers get
	compile-time checked Fire/Invoke signatures instead of raw WaitForChild
	strings scattered around.

	Usage:
		local Network = require(ReplicatedStorage.Modules.Network)
		Network.Combat.FireTargetedSkill:FireServer(targetPlayer, skillId)
		Network.Combat.FireTargetedSkill.OnServerEvent:Connect(handler)
		Network.Economy.EquipSkill:InvokeServer(slotIndex, skillId) -- RemoteFunction
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remoteEventsRoot = ReplicatedStorage:WaitForChild("RemoteEvents")

-- Binds every RemoteEvent AND RemoteFunction child of a folder — most
-- folders are RemoteEvent-only, but Economy mixes in a couple of
-- RemoteFunctions (GetOwnedSkills/EquipSkill) for request/response calls.
local function bindFolder(folderName: string) : { [string]: RemoteEvent | RemoteFunction }
	local folder = remoteEventsRoot:WaitForChild(folderName)
	local bound: { [string]: RemoteEvent | RemoteFunction } = {}

	for _, child in folder:GetChildren() do
		if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
			bound[child.Name] = child
		end
	end

	return bound
end

export type CombatRemotes = {
	FireTargetedSkill: RemoteEvent,
	FireGlobalSkill: RemoteEvent,
	FireSelfSkill: RemoteEvent,
	UseTrackItem: RemoteEvent,
	SkillCastResult: RemoteEvent, -- server -> client only: (skillId: string, cooldownSeconds: number)
	-- server -> client only: (mode: SkillEffects.ControlScrambleMode,
	-- durationSeconds: number). Every effect with IsControlScramble set is a
	-- CLIENT-side thing by nature — it changes what the player's own input
	-- does — so the server's only job is to say which mode landed and for how
	-- long. Fired from exactly one place, EffectStackManager.TryApplyEffect,
	-- once the effect is genuinely accepted; that covers the Target, Global
	-- and Self cast paths at once instead of each manager special-casing it.
	-- Replaces the old ApplyBlindEffect, which only ever carried "Blind" and
	-- was fired from TargetedSkillManager, leaving ScrambleGlobal with no
	-- route to the client at all.
	ApplyControlEffect: RemoteEvent,
	-- server -> client only: (effectId: string, durationSeconds: number).
	-- Fired ONCE when an effect is accepted, and again with 0 if it is cleared
	-- EARLY (an immunity purge). Normal expiry sends nothing at all.
	--
	-- That is the whole design of the effects timer: the server states the
	-- duration one time and the client counts it down itself. A timer is a
	-- pure function of "when did it start" and "how long does it last", so
	-- streaming per-tick remaining-time updates for every active effect on
	-- every player would be a continuous cost for information the client can
	-- derive for free. This carries every effect, not just the control
	-- scrambles ApplyControlEffect handles, because a slow the player cannot
	-- see the timer for is a slow they think is a bug.
	ActiveEffectChanged: RemoteEvent,
}

export type EconomyRemotes = {
	DepositFans: RemoteEvent,
	PickupItem: RemoteEvent,
	DropItem: RemoteEvent,
	PurchaseItem: RemoteEvent,
	GetOwnedSkills: RemoteFunction,
	EquipSkill: RemoteFunction,
}

export type HubRemotes = {
	TeleportToFanBox: RemoteEvent,
	ReturnToHub: RemoteEvent,
	PerformPose: RemoteEvent,
	EnterTrack: RemoteEvent,
	-- Two-way: client fires it with no args to toggle Grand Prix enrolment
	-- on/off; server fires it back at that client with (isJoined: boolean)
	-- as the authoritative answer, which is what the button renders from.
	ToggleGrandPrixEntry: RemoteEvent,
}

export type TrackRemotes = {
	CheckpointPassed: RemoteEvent,
	UpdateRaceStandings: RemoteEvent,
	ShowNotification: RemoteEvent, -- server -> client only: (text: string, style: string? — "Pop" for a bouncy scale-in on currency gains, nil/anything else for the plain fade the pooled/stacking toast system used originally)
	-- client -> server only, NO ARGS. Fired once by TutorialController when the
	-- first-run tutorial is finished or skipped; ProfileManager flips the
	-- persisted TutorialCompleted flag. Carries nothing on purpose — the client
	-- can only report "seen", never choose what gets written.
	CompleteTutorial: RemoteEvent,
	GrandPrixStateChanged: RemoteEvent, -- server -> client only: (state: string matching GrandPrixManager.RaceState, countdownSeconds: number)
	-- server -> client only: (state: string, secondsRemaining: number,
	-- nextRaceStartTime: number) — what the current state is counting down TO,
	-- plus the UTC epoch second of the next scheduled Grand Prix (races run on
	-- real-world :00/:30 marks; the client renders it in the player's own time
	-- zone). Broadcast on a slow cycle; the client ticks between updates rather
	-- than the server sending per second.
	GrandPrixTimer: RemoteEvent,
	PlaySound: RemoteEvent, -- server -> client only: (soundKey: string, a key in Configs.SoundEffects) — the 2D/personal half of the sound system; 3D world sounds are made server-side on the part instead
	-- Revive-on-elimination (ArcadeManager / EliminationPromptController):
	PlayerEliminated: RemoteEvent, -- server -> client only: (timeoutSeconds: number, goldCost: number, goldRevivesRemainingToday: number) — opens the revive-choice prompt
	BuyExtraLifeWithGold: RemoteEvent, -- client -> server only, no args
	EliminationResolved: RemoteEvent, -- server -> client only: (revived: boolean) — closes the prompt either way (revived, or the timeout auto-returned them to the Hub)
}

export type QuestRemotes = {
	-- server -> client only: ({ [categoryId]: { Progress: number, ClaimedTiers: number } })
	-- Progress and claim counts ONLY — the client already has
	-- Configs.QuestDefinitions, so names/targets/rewards would be a constant
	-- re-sent on every push.
	QuestStateChanged: RemoteEvent,
	RequestQuestState: RemoteEvent, -- client -> server only, no args
	-- client -> server only: (categoryId: string). Deliberately carries NO
	-- tier, amount or currency: QuestService reads those from the config
	-- itself, so a tampered client can only ask for what it has already
	-- earned.
	ClaimQuestTier: RemoteEvent,
}

local Network = {
	Combat = bindFolder("Combat") :: CombatRemotes,
	Quests = bindFolder("Quests") :: QuestRemotes,
	Economy = bindFolder("Economy") :: EconomyRemotes,
	Hub = bindFolder("Hub") :: HubRemotes,
	Track = bindFolder("Track") :: TrackRemotes,
}

return Network

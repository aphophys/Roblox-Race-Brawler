--!strict
--[[
	SkillRewardService
	Pays the CASTER a small fan reward for a skill that successfully goes off,
	sized by the skill's CastType (EconomyRates.SkillCastFanRewards: Self 1,
	Target 2, Global 4).

	Why this is a module and not three copies of four lines: all three skill
	managers need it, and putting the grant in one function is what makes
	"casting pays fans" a single rule that can be retuned, disabled or audited
	in one place — the same reasoning ArcadeManager.HandleTrackViolation gives
	for owning every route to a lost life.

	## What "successful" means, per manager

	Deliberately NOT "the player pressed the button". Each manager already has
	exactly one point at which a cast is known to have gone off, and it is the
	end of the shared resolve path in every case — after every early return
	that represents a fizzle:

	- Self (SelfSkillManager.resolveAndApply) — the effect has been applied to
	  the caster. A Self skill cannot really miss, so this is just "it ran".
	- Target (TargetedSkillManager.resolveAndApply) — a target was found in
	  range, survived the wind-up AND the projectile flight, and the effect
	  landed on them. A cast into empty space pays NOTHING, which is the whole
	  reason the call sits at the bottom of that function rather than next to
	  the cooldown consumption at the top. "NO TARGET IN RANGE!" is not a cast.
	- Global (GlobalSkillStateMachine.activate) — the state machine accepted
	  the cast (it was Idle) and the effect has been broadcast to the field.

	Because the call sits in each manager's SHARED resolve, a skill released
	from a carried pickup (CastSkillDirect) pays exactly the same as one cast
	from the player's own bar. That is intended: both are the player getting a
	skill off, and the pickup route is already throttled by having to find and
	carry the pickup.

	## Gamepass interaction

	DoubleFans ("Double Gain Fans and Gold") applies, matching every other fan
	payout in the game — checkpoints, laps, deposits and passive fan income all
	double for pass owners, and a new earn source that silently ignored the
	pass would read as the pass being broken. Drop the PlayerOwnsGamePass block
	below to make these flat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyRates = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("EconomyRates"))
local SkillTrees = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("SkillTrees"))
local Network = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Network"))
local Utils = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Utils"))

local ProfileManager = require(script.Parent:WaitForChild("ProfileManager"))
local MonetizationService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("MonetizationService"))

local SkillRewardService = {}

-- Call at the moment a cast is known to have succeeded — see the docstring for
-- where that is in each manager. Safe to call for a player whose profile has
-- not loaded (or has already been released); it simply pays nothing.
function SkillRewardService.GrantCastReward(caster: Player, castType: SkillTrees.SkillCastType)
	local reward = EconomyRates.SkillCastFanRewards[castType]
	if reward == nil or reward <= 0 then
		return
	end

	local profile = ProfileManager.GetProfile(caster)
	if profile == nil then
		return
	end

	if MonetizationService.PlayerOwnsGamePass(caster, "DoubleFans") then
		reward *= EconomyRates.DoubleGainMultiplier
	end

	profile.Data.TotalFans += reward
	ProfileManager.SyncAttributes(caster)

	-- Same toast every other small, frequent fan gain uses (compare
	-- CheckpointValidator.grantCheckpointReward) so the two read as one
	-- currency arriving rather than two systems. Deliberately no FanGain
	-- sound: the cast already plays its own, and stacking a second cue on
	-- every cast would turn a reward into noise. Only the lap payout, which is
	-- rare and large, earns a sound.
	Network.Track.ShowNotification:FireClient(caster, `+{Utils.FormatNumber(reward)} 🌟`, "Pop")
end

return SkillRewardService

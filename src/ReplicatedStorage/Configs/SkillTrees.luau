--!strict
--[[
	SkillTrees
	Full skill roster: 6 skills as specified (PositionSwap, ReverseControl,
	SlowGlobal, SlowTarget, DashSelf, ChargedJumpForward) plus 11
	recommended additions to reach a well-rounded 17 (spec asked for
	15-20 and asked for recommendations to fill the gap) — see the
	"RECOMMENDED" markers below. Global skills cap at 3 levels; Target/Self
	skills (including the two Dispel skills) cap at 10, per spec.

	Per-level numbers are generated from a compact curve spec instead of
	hand-typing ~10 rows per skill (would be ~170 rows of near-duplicate
	data) — see `generateLevels`. Tune by editing the curve params, not the
	output.

	SoundId is a placeholder ("") on every skill: there's no Toolbox/
	marketplace access available to source free SFX, so these need to be
	filled in manually from Studio's Toolbox and pasted in as rbxassetid://
	strings.
]]

local SkillEffects = require(script.Parent:WaitForChild("SkillEffects"))

export type SkillCastType = "Global" | "Target" | "Self"
export type DispelMode = "Offensive" | "Defensive"

export type SkillLevelData = {
	Level: number,
	CooldownSeconds: number,
	RangeStuds: number, -- casting range (Target skills) or self-effect distance (e.g. Dash/Jump); 0 where meaningless
	EffectMagnitude: number, -- ALWAYS a direct multiplier on the affected stat: >1 = buff (e.g. 1.25 = +25%), <1 = debuff (e.g. 0.7 = -30%); 0/unused for control-scramble, immunity, and Dispel skills
	EffectDurationSeconds: number,
	DispelCount: number?, -- Dispel skills only: how many buffs/debuffs this strips, clamped to SkillEffects.StackingRules Dispel bounds
	UpgradeGoldCost: number,
}

export type SkillDefinition = {
	Id: string,
	DisplayName: string,
	Description: string,
	CastType: SkillCastType,
	MaxLevel: number,
	LinkedEffectId: string?, -- key into SkillEffects.Catalog; nil for pure-action skills (swap/dash/jump) with no lingering buff/debuff
	DispelMode: DispelMode?, -- set only for the two Dispel skills
	SoundId: string,
	Levels: { SkillLevelData },
}

export type SkillTreesType = { [string]: SkillDefinition }

type LevelCurveParams = {
	MaxLevel: number,
	BaseCooldown: number,
	CooldownStep: number,
	MinCooldown: number,
	BaseRange: number?,
	RangeStep: number?,
	BaseMagnitude: number?,
	MagnitudeStep: number?,
	BaseDuration: number?,
	DurationStep: number?,
	BaseDispelCount: number?,
	DispelCountStep: number?,
	MaxDispelCount: number?,
	BaseGoldCost: number,
	GoldCostStep: number,
}

local function generateLevels(params: LevelCurveParams) : { SkillLevelData }
	local levels: { SkillLevelData } = {}

	for level = 1, params.MaxLevel do
		local stepsPast1 = level - 1

		local dispelCount: number? = nil
		if params.BaseDispelCount ~= nil then
			local raw = params.BaseDispelCount + stepsPast1 * (params.DispelCountStep or 0)
			dispelCount = math.min(params.MaxDispelCount or params.BaseDispelCount, math.floor(raw + 0.5))
		end

		table.insert(levels, {
			Level = level,
			CooldownSeconds = math.max(params.MinCooldown, params.BaseCooldown - stepsPast1 * params.CooldownStep),
			RangeStuds = (params.BaseRange or 0) + stepsPast1 * (params.RangeStep or 0),
			EffectMagnitude = (params.BaseMagnitude or 0) + stepsPast1 * (params.MagnitudeStep or 0),
			EffectDurationSeconds = (params.BaseDuration or 0) + stepsPast1 * (params.DurationStep or 0),
			DispelCount = dispelCount,
			UpgradeGoldCost = level == 1 and 0 or math.floor(params.BaseGoldCost + stepsPast1 * params.GoldCostStep),
		})
	end

	return levels
end

local SkillTrees: SkillTreesType = {

	-- ===== Global (MaxLevel 3) =====

	SlowGlobal = {
		Id = "SlowGlobal", DisplayName = "Track-Wide Slow",
		Description = "Slows every racer's walk/climb/swim speed for a few seconds.",
		CastType = "Global", MaxLevel = 3, LinkedEffectId = SkillEffects.Catalog.SlowGlobal.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 3, BaseCooldown = 45, CooldownStep = 5, MinCooldown = 35,
			BaseMagnitude = 0.75, MagnitudeStep = -0.05, BaseDuration = 4, DurationStep = 1,
			BaseGoldCost = 300, GoldCostStep = 250,
		}),
	},
	ScrambleGlobal = { -- RECOMMENDED: second Global skill, control-scramble variant of SlowGlobal
		Id = "ScrambleGlobal", DisplayName = "Track-Wide Scramble",
		Description = "Randomizes every racer's controls for a few seconds.",
		CastType = "Global", MaxLevel = 3, LinkedEffectId = SkillEffects.Catalog.ScrambleGlobal.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 3, BaseCooldown = 60, CooldownStep = 5, MinCooldown = 50,
			BaseDuration = 3, DurationStep = 1, BaseGoldCost = 400, GoldCostStep = 300,
		}),
	},

	-- ===== Target (MaxLevel 10) =====

	PositionSwap = {
		Id = "PositionSwap", DisplayName = "Position Swap",
		Description = "Instantly swaps places with the nearest valid target in range.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = nil, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 12, CooldownStep = 0.4, MinCooldown = 8,
			BaseRange = 20, RangeStep = 1.5, BaseGoldCost = 100, GoldCostStep = 40,
		}),
	},
	ReverseControlTarget = {
		Id = "ReverseControlTarget", DisplayName = "Reverse Control",
		Description = "Target's forward/backward and left/right inputs are swapped.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.ReverseControlTarget.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 18, CooldownStep = 0.6, MinCooldown = 12,
			BaseRange = 18, RangeStep = 1, BaseDuration = 2.5, DurationStep = 0.3,
			BaseGoldCost = 150, GoldCostStep = 50,
		}),
	},
	SlowTarget = {
		Id = "SlowTarget", DisplayName = "Slow",
		Description = "Slows a single target's walk/climb/swim speed.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.SlowTarget.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 10, CooldownStep = 0.3, MinCooldown = 7,
			BaseRange = 22, RangeStep = 1.2, BaseMagnitude = 0.70, MagnitudeStep = -0.02,
			BaseDuration = 3, DurationStep = 0.2, BaseGoldCost = 120, GoldCostStep = 40,
		}),
	},
	WeightTarget = { -- RECOMMENDED: jump/climb-focused debuff, distinct from the speed-focused SlowTarget
		Id = "WeightTarget", DisplayName = "Weight Down",
		Description = "Reduces a target's jump power and climb speed.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.WeightTarget.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 14, CooldownStep = 0.4, MinCooldown = 10,
			BaseRange = 18, RangeStep = 1, BaseMagnitude = 0.65, MagnitudeStep = -0.02,
			BaseDuration = 3, DurationStep = 0.25, BaseGoldCost = 150, GoldCostStep = 45,
		}),
	},
	BlindTarget = { -- RECOMMENDED: control-scramble variant on a single target (vs. ReverseControl's invert)
		Id = "BlindTarget", DisplayName = "Blind",
		Description = "Obscures a target's view for a few seconds.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.BlindTarget.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 16, CooldownStep = 0.5, MinCooldown = 11,
			BaseRange = 16, RangeStep = 1, BaseDuration = 2, DurationStep = 0.25,
			BaseGoldCost = 140, GoldCostStep = 45,
		}),
	},
	ShockTarget = { -- RECOMMENDED: short, punchy near-stun; higher cooldown to offset strength
		Id = "ShockTarget", DisplayName = "Shock",
		Description = "Briefly stops a target in their tracks.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.ShockTarget.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 20, CooldownStep = 0.6, MinCooldown = 14,
			BaseRange = 14, RangeStep = 0.8, BaseMagnitude = 0.15, MagnitudeStep = -0.01,
			BaseDuration = 1, DurationStep = 0.15, BaseGoldCost = 200, GoldCostStep = 60,
		}),
	},
	SiphonPulse = { -- RECOMMENDED: offensive Dispel, per spec's "other special effect is dispel"
		Id = "SiphonPulse", DisplayName = "Siphon Pulse",
		Description = "Strips 1-3 positive effects from a target, scaling with level.",
		CastType = "Target", MaxLevel = 10, LinkedEffectId = nil, DispelMode = "Offensive", SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 25, CooldownStep = 0.8, MinCooldown = 16,
			BaseRange = 20, RangeStep = 1, BaseDispelCount = 1, DispelCountStep = 0.25,
			MaxDispelCount = SkillEffects.StackingRules.DispelMaxCount, BaseGoldCost = 250, GoldCostStep = 70,
		}),
	},

	-- ===== Self (MaxLevel 10) =====

	DashSelf = {
		Id = "DashSelf", DisplayName = "Dash",
		Description = "Bursts forward a short distance with a brief speed boost.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.DashBoost.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 8, CooldownStep = 0.3, MinCooldown = 4,
			BaseRange = 16, RangeStep = 1.2, BaseMagnitude = 1.5, MagnitudeStep = 0.03,
			BaseDuration = 0.4, DurationStep = 0.02, BaseGoldCost = 100, GoldCostStep = 35,
		}),
	},
	ChargedJumpForward = {
		Id = "ChargedJumpForward", DisplayName = "Charged Jump Forward",
		Description = "Hold to charge, release for a long forward jump.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = nil, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 6, CooldownStep = 0.25, MinCooldown = 3,
			BaseRange = 20, RangeStep = 1.5, BaseDuration = 1.2, DurationStep = -0.06,
			BaseGoldCost = 110, GoldCostStep = 35,
		}),
	},
	SpeedBoostSelf = { -- RECOMMENDED: baseline movement buy, mirrors SlowTarget's shape but Good/Self
		Id = "SpeedBoostSelf", DisplayName = "Speed Boost",
		Description = "Temporarily increases your own walk speed.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.SpeedBoostSelf.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 10, CooldownStep = 0.3, MinCooldown = 6,
			BaseMagnitude = 1.2, MagnitudeStep = 0.02, BaseDuration = 3, DurationStep = 0.2,
			BaseGoldCost = 100, GoldCostStep = 35,
		}),
	},
	SwimBurstSelf = { -- RECOMMENDED: pairs with the Water/Island and Tsunami track themes
		Id = "SwimBurstSelf", DisplayName = "Swim Burst",
		Description = "Temporarily increases your own swim speed.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.SwimBurstSelf.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 9, CooldownStep = 0.3, MinCooldown = 5,
			BaseMagnitude = 1.25, MagnitudeStep = 0.025, BaseDuration = 3, DurationStep = 0.2,
			BaseGoldCost = 100, GoldCostStep = 35,
		}),
	},
	ClimbGripSelf = { -- RECOMMENDED: pairs with the Hill/Mud and Climb/Slide track themes
		Id = "ClimbGripSelf", DisplayName = "Climb Grip",
		Description = "Temporarily increases your own climb speed.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.ClimbGripSelf.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 9, CooldownStep = 0.3, MinCooldown = 5,
			BaseMagnitude = 1.25, MagnitudeStep = 0.025, BaseDuration = 3, DurationStep = 0.2,
			BaseGoldCost = 100, GoldCostStep = 35,
		}),
	},
	ShieldSelf = { -- RECOMMENDED: the "becomes immune" mechanic as a proactive purchase, not just a stacking side-effect
		Id = "ShieldSelf", DisplayName = "Shield",
		Description = "Grants immunity to the next negative effect for a short window.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.ShieldSelf.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 30, CooldownStep = 1, MinCooldown = 18,
			BaseDuration = 3, DurationStep = 0.3, BaseGoldCost = 200, GoldCostStep = 60,
		}),
	},
	PhaseSelf = { -- RECOMMENDED: immunity to physical hazard knockback specifically, distinct from ShieldSelf's debuff immunity
		Id = "PhaseSelf", DisplayName = "Phase",
		Description = "Grants brief immunity to hazard and combat knockback.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = SkillEffects.Catalog.PhaseSelf.Id, DispelMode = nil, SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 35, CooldownStep = 1.2, MinCooldown = 20,
			BaseDuration = 2, DurationStep = 0.2, BaseGoldCost = 220, GoldCostStep = 65,
		}),
	},
	CleansePulse = { -- RECOMMENDED: defensive Dispel, the other half of the spec's dispel requirement
		Id = "CleansePulse", DisplayName = "Cleanse Pulse",
		Description = "Removes 1-3 of your own negative effects, scaling with level.",
		CastType = "Self", MaxLevel = 10, LinkedEffectId = nil, DispelMode = "Defensive", SoundId = "",
		Levels = generateLevels({
			MaxLevel = 10, BaseCooldown = 22, CooldownStep = 0.7, MinCooldown = 14,
			BaseDispelCount = 1, DispelCountStep = 0.25, MaxDispelCount = SkillEffects.StackingRules.DispelMaxCount,
			BaseGoldCost = 220, GoldCostStep = 60,
		}),
	},
}

return SkillTrees

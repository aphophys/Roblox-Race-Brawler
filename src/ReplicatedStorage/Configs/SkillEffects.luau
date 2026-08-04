--!strict
--[[
	SkillEffects
	Qualitative shape of every buff/debuff a skill can apply: what it
	touches (movement stats and/or controls) and whether it's Good or Bad.
	Quantitative per-level numbers (magnitude, duration, range, cooldown)
	live on the skill itself in SkillTrees.luau and scale the effect at
	cast time — this file only answers "what kind of thing is this."

	Also defines the global stacking rules referenced by EffectStackManager
	(ServerScriptService.CombatAndMovement) — the runtime piece that will
	actually apply/expire/net these effects. That module is a stub; this
	config is the locked contract it will read from.
]]

export type EffectPolarity = "Good" | "Bad"
export type MovementStat = "WalkSpeed" | "ClimbSpeed" | "SwimSpeed" | "JumpPower"
export type ControlScrambleMode = "Invert" | "Randomize" | "Blind"

export type EffectDefinition = {
	Id: string,
	DisplayName: string,
	Polarity: EffectPolarity,
	AffectsStats: { MovementStat }, -- multiplicative modifiers; empty if this effect doesn't touch movement stats
	IsControlScramble: boolean,
	ControlScrambleMode: ControlScrambleMode?, -- set only if IsControlScramble
	GrantsImmunity: boolean, -- true = this is a shield (suppresses the next incoming effect of a polarity), not a stat/control modifier
	IsStun: boolean, -- true = "briefly stops you in your tracks"; CarryItemService checks this to drop a carried Fan Payload when it lands
}

export type EffectsCatalogType = { [string]: EffectDefinition }

local Catalog: EffectsCatalogType = {
	SlowGlobal = {
		Id = "SlowGlobal", DisplayName = "Track-Wide Slow", Polarity = "Bad",
		AffectsStats = { "WalkSpeed", "ClimbSpeed", "SwimSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	ScrambleGlobal = {
		Id = "ScrambleGlobal", DisplayName = "Track-Wide Scramble", Polarity = "Bad",
		AffectsStats = {}, IsControlScramble = true, ControlScrambleMode = "Randomize", GrantsImmunity = false, IsStun = false,
	},
	SlowTarget = {
		Id = "SlowTarget", DisplayName = "Slow", Polarity = "Bad",
		AffectsStats = { "WalkSpeed", "ClimbSpeed", "SwimSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	ReverseControlTarget = {
		Id = "ReverseControlTarget", DisplayName = "Reverse Control", Polarity = "Bad",
		AffectsStats = {}, IsControlScramble = true, ControlScrambleMode = "Invert", GrantsImmunity = false, IsStun = false,
	},
	WeightTarget = {
		Id = "WeightTarget", DisplayName = "Weight Down", Polarity = "Bad",
		AffectsStats = { "JumpPower", "ClimbSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	BlindTarget = {
		Id = "BlindTarget", DisplayName = "Blind", Polarity = "Bad",
		AffectsStats = {}, IsControlScramble = true, ControlScrambleMode = "Blind", GrantsImmunity = false, IsStun = false,
	},
	ShockTarget = {
		Id = "ShockTarget", DisplayName = "Shock", Polarity = "Bad",
		AffectsStats = { "WalkSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = true,
	},
	DashBoost = {
		Id = "DashBoost", DisplayName = "Dash Momentum", Polarity = "Good",
		AffectsStats = { "WalkSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	SpeedBoostSelf = {
		Id = "SpeedBoostSelf", DisplayName = "Speed Boost", Polarity = "Good",
		AffectsStats = { "WalkSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	SwimBurstSelf = {
		Id = "SwimBurstSelf", DisplayName = "Swim Burst", Polarity = "Good",
		AffectsStats = { "SwimSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	ClimbGripSelf = {
		Id = "ClimbGripSelf", DisplayName = "Climb Grip", Polarity = "Good",
		AffectsStats = { "ClimbSpeed" }, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = false, IsStun = false,
	},
	ShieldSelf = {
		Id = "ShieldSelf", DisplayName = "Shield", Polarity = "Good",
		AffectsStats = {}, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = true, IsStun = false,
	},
	PhaseSelf = {
		Id = "PhaseSelf", DisplayName = "Phase", Polarity = "Good",
		AffectsStats = {}, IsControlScramble = false, ControlScrambleMode = nil, GrantsImmunity = true, IsStun = false,
	},
}

export type EffectStackingRulesType = {
	MaxStackedPerPolarity: number,
	MaxStackedPerPolarityAtPeakLevel: number,
	-- No separate "immunity trigger count" field: it's derived as
	-- (cap + 1) at apply time, where cap is MaxStackedPerPolarity or
	-- MaxStackedPerPolarityAtPeakLevel depending on the casting skill's
	-- level. A fixed trigger count would desync from the peak-level cap
	-- (e.g. a fixed 4 would trigger immunity *below* a peak cap of 5).
	ImmunityDurationSeconds: number,
	-- How many of the MaxStackedPerPolarity slots each cast-source can occupy
	-- concurrently. Global(1) + Target(2) = 3, matching the spec's "1 global
	-- and 2 target". Self isn't specified by the source spec; defaulted to 2
	-- (own buffs shouldn't be starved by incoming debuffs) — revisit if this
	-- needs tuning.
	MaxConcurrentBySource: { Global: number, Target: number, Self: number },
	DispelMinCount: number,
	DispelMaxCount: number,
}

local StackingRules: EffectStackingRulesType = {
	MaxStackedPerPolarity = 3,
	MaxStackedPerPolarityAtPeakLevel = 5,
	-- Doubled 5 -> 10 with SkillTrees.DURATION_MULTIPLIER. It is the fallback
	-- duration for the cap+1 immunity window (EffectStackManager), i.e. a
	-- skill-driven duration like every other one, so leaving it behind would
	-- have quietly halved immunity relative to the effects it protects against.
	ImmunityDurationSeconds = 10,
	MaxConcurrentBySource = { Global = 1, Target = 2, Self = 2 },
	DispelMinCount = 1,
	DispelMaxCount = 3,
}

local SkillEffects = {
	Catalog = Catalog,
	StackingRules = StackingRules,
}

return SkillEffects

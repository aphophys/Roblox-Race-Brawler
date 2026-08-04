--!strict
--[[
	SoundEffects
	Single source of truth for every sound effect id in the game, keyed by
	what the sound MEANS rather than what it is — call sites ask for
	"GoldGain", not for an asset id, so re-sourcing a clip is a one-line
	change here and nothing else moves.

	All ids are free Creator Store audio, found via the Studio asset search.

	IMPORTANT — audio permissions: Roblox only plays audio the experience is
	allowed to use. Free public audio normally works, but an asset can be
	moderated or have its permissions changed at any time, and a Sound whose
	id it can't load simply never fires. Both players (SoundDirector on the
	server, SoundController on the client) therefore treat a missing/blank id
	as "no sound" and carry on rather than erroring — a silent effect must
	never be able to break the gameplay it decorates.
]]

export type SoundDefinition = {
	AssetId: string,
	Volume: number,
	-- 3D sounds get parented to a part and roll off with distance; 2D ones
	-- play flat through SoundService for the one player they belong to.
	RollOffMaxDistance: number?,
}

export type SoundEffectsType = { [string]: SoundDefinition }

local SoundEffects: SoundEffectsType = {
	-- Economy (2D, played only for the player it happened to)
	Purchase = { AssetId = "rbxassetid://106979530295524", Volume = 0.55 },
	GoldGain = { AssetId = "rbxassetid://134810204798705", Volume = 0.5 }, -- cash register
	FanGain = { AssetId = "rbxassetid://105154404054447", Volume = 0.45 }, -- crowd cheering

	-- Skill casts (3D, parented to the caster so everyone nearby hears it)
	SkillSelf = { AssetId = "rbxassetid://88350532436520", Volume = 0.6, RollOffMaxDistance = 120 },
	SkillTarget = { AssetId = "rbxassetid://138132512434499", Volume = 0.6, RollOffMaxDistance = 140 },
	SkillGlobal = { AssetId = "rbxassetid://168586586", Volume = 0.6, RollOffMaxDistance = 200 },
	SkillSwap = { AssetId = "rbxassetid://102434178016995", Volume = 0.7, RollOffMaxDistance = 160 },
	SkillBlocked = { AssetId = "rbxassetid://84614228601392", Volume = 0.4 }, -- 2D "that didn't work" tick

	-- Cast telegraph (3D). CastCharge plays during the wind-up on the caster;
	-- ProjectileHit plays where the bolt/orb lands, which is the target's
	-- position, not the caster's — so it is a separate 3D sound rather than a
	-- second one on the caster.
	CastCharge = { AssetId = "rbxassetid://99963459517796", Volume = 0.5, RollOffMaxDistance = 120 },
	ProjectileHit = { AssetId = "rbxassetid://9119074309", Volume = 0.6, RollOffMaxDistance = 140 },

	-- Race progress (2D — these are about YOUR run, nobody else's business)
	CheckpointPassed = { AssetId = "rbxassetid://123903547626734", Volume = 0.4 },
	PickupItem = { AssetId = "rbxassetid://90035739456316", Volume = 0.5 },
	CountdownTick = { AssetId = "rbxassetid://601149073", Volume = 0.45 },
	CountdownGo = { AssetId = "rbxassetid://137757758936772", Volume = 0.6 },

	-- Setbacks (2D)
	LifeLost = { AssetId = "rbxassetid://110749657293389", Volume = 0.6 },
	Respawn = { AssetId = "rbxassetid://79353010924623", Volume = 0.45 },

	-- Fan Box crowd reacting to a pose (3D). Deliberately the SAME clip as
	-- FanGain rather than a new id: that one is already load-verified crowd
	-- cheering, and an unverified second id would be a silent effect at the
	-- exact moment the reward lands. It is a separate entry because it is a
	-- different KIND of sound here — 3D and heard by anyone near the stand,
	-- not a 2D ding for the poser alone — and because re-sourcing one of the
	-- two later must not silently change the other.
	CrowdCheer = { AssetId = "rbxassetid://105154404054447", Volume = 0.75, RollOffMaxDistance = 220 },

	-- Hazards (3D — a block landing or a magma pool is a world event, and the
	-- direction it comes from is exactly the information a racer needs)
	BlockImpact = { AssetId = "rbxassetid://9120270688", Volume = 0.7, RollOffMaxDistance = 180 },
	HazardBurn = { AssetId = "rbxassetid://107181997828307", Volume = 0.6, RollOffMaxDistance = 90 },
}

return SoundEffects

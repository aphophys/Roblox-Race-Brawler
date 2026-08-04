--!strict
--[[
	VisualEffectsService
	Every "you can see that something happened to this character" effect, in
	one place — phase translucency, the shield bubble, buff/debuff auras,
	speed trails, the swap arc, and cast bursts.

	Built server-side and NOT over remotes, deliberately. Highlight, Beam,
	Trail, ParticleEmitter and part Transparency all replicate to every client
	on their own, so creating them here gets all observers in sync for free —
	and, more importantly, means an effect can never disagree with the server
	state that caused it. A client-driven version would need one remote per
	effect plus its own expiry bookkeeping, and could drift.

	Everything is time-boxed and self-cleaning. Each helper captures its own
	expiry and checks it before tearing down, so a second cast landing while
	the first is still running extends the effect rather than the first one's
	timer cutting the second one short — the same guard pattern
	MovementModifier.walkSpeedOverrideUntil and SelfSkillManager's phase
	revert already use.
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local VisualEffectsService = {}

local BUFF_COLOR = Color3.fromRGB(80, 230, 120)
local DEBUFF_COLOR = Color3.fromRGB(240, 70, 70)
-- Race progress gets its own hue, deliberately not the buff green: a
-- checkpoint flare in green would read as "you just gained a buff", and the
-- two happen close enough together mid-race to be genuinely confusable.
local CHECKPOINT_COLOR = Color3.fromRGB(90, 210, 255)
local REWARD_COLOR = Color3.fromRGB(255, 205, 60)
local PHASE_TRANSPARENCY = 0.65

-- Latest expiry per character per effect, so overlapping casts extend rather
-- than truncate. Keyed by the character Model, cleared as each effect ends.
local auraExpiryByCharacter: { [Model]: number } = {}
local trailExpiryByCharacter: { [Model]: number } = {}

local function getRootPart(character: Model) : BasePart?
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- ===== Phase (PhaseSelf) =====

-- Translucent while phasing, so the caster and everyone else can see WHY
-- they're passing through hazards. Accessories and the HumanoidRootPart are
-- skipped: the root is already invisible, and re-showing an accessory that
-- was hidden for other reasons would be wrong.
function VisualEffectsService.SetPhased(character: Model, isPhased: boolean)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			if isPhased then
				-- Remember what it was, so restoring can't overwrite a part
				-- that was already partly transparent by design.
				if descendant:GetAttribute("PrePhaseTransparency") == nil then
					descendant:SetAttribute("PrePhaseTransparency", descendant.Transparency)
				end
				descendant.Transparency = PHASE_TRANSPARENCY
			else
				local original = descendant:GetAttribute("PrePhaseTransparency")
				if typeof(original) == "number" then
					descendant.Transparency = original
					descendant:SetAttribute("PrePhaseTransparency", nil)
				end
			end
		end
	end
end

-- ===== Shield bubble (ShieldSelf) =====

function VisualEffectsService.ShowShield(character: Model, durationSeconds: number)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end

	local existing = character:FindFirstChild("ShieldBubble")
	if existing ~= nil then
		existing:Destroy() -- re-cast restarts the bubble cleanly
	end

	local bubble = Instance.new("Part")
	bubble.Name = "ShieldBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.new(8, 8, 8)
	bubble.Material = Enum.Material.ForceField
	bubble.Color = Color3.fromRGB(90, 170, 255)
	bubble.Transparency = 0.4
	bubble.CanCollide = false
	bubble.CanQuery = false
	bubble.CanTouch = false
	bubble.Massless = true
	bubble.CFrame = rootPart.CFrame
	bubble.Parent = character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = bubble
	weld.Part1 = rootPart
	weld.Parent = bubble

	Debris:AddItem(bubble, durationSeconds)
end

-- ===== Buff / debuff aura =====

-- A Highlight rather than a particle cloud: it outlines the whole character
-- in one colour, stays readable at racing distance and through other
-- players, and costs one instance.
function VisualEffectsService.ShowEffectAura(character: Model, durationSeconds: number, isBuff: boolean)
	local expiresAt = os.clock() + durationSeconds
	auraExpiryByCharacter[character] = math.max(auraExpiryByCharacter[character] or 0, expiresAt)

	local highlight = character:FindFirstChild("EffectAura") :: Highlight?
	if highlight == nil then
		highlight = Instance.new("Highlight")
		;(highlight :: Highlight).Name = "EffectAura"
		;(highlight :: Highlight).FillTransparency = 0.75
		;(highlight :: Highlight).OutlineTransparency = 0.1
		;(highlight :: Highlight).Adornee = character
		;(highlight :: Highlight).Parent = character
	end

	local colour = if isBuff then BUFF_COLOR else DEBUFF_COLOR
	;(highlight :: Highlight).FillColor = colour
	;(highlight :: Highlight).OutlineColor = colour

	task.delay(durationSeconds, function()
		-- Only tear down if nothing re-applied in the meantime.
		if (auraExpiryByCharacter[character] or 0) > os.clock() then
			return
		end
		auraExpiryByCharacter[character] = nil
		local current = character:FindFirstChild("EffectAura")
		if current ~= nil then
			current:Destroy()
		end
	end)
end

-- ===== Speed trail =====

function VisualEffectsService.ShowTrail(character: Model, durationSeconds: number, colour: Color3?)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end

	local expiresAt = os.clock() + durationSeconds
	trailExpiryByCharacter[character] = math.max(trailExpiryByCharacter[character] or 0, expiresAt)

	if rootPart:FindFirstChild("SpeedTrail") == nil then
		-- A Trail needs two attachments to define the ribbon's width.
		local top = Instance.new("Attachment")
		top.Name = "TrailTop"
		top.Position = Vector3.new(0, 1.5, 0)
		top.Parent = rootPart

		local bottom = Instance.new("Attachment")
		bottom.Name = "TrailBottom"
		bottom.Position = Vector3.new(0, -1.5, 0)
		bottom.Parent = rootPart

		local trail = Instance.new("Trail")
		trail.Name = "SpeedTrail"
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Lifetime = 0.4
		trail.MinLength = 0.1
		trail.LightEmission = 1
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Color = ColorSequence.new(colour or Color3.fromRGB(120, 200, 255))
		trail.Parent = rootPart
	end

	task.delay(durationSeconds, function()
		if (trailExpiryByCharacter[character] or 0) > os.clock() then
			return
		end
		trailExpiryByCharacter[character] = nil
		local root = getRootPart(character)
		if root == nil then
			return
		end
		for _, name in { "SpeedTrail", "TrailTop", "TrailBottom" } do
			local instance = root:FindFirstChild(name)
			if instance ~= nil then
				instance:Destroy()
			end
		end
	end)
end

-- ===== PositionSwap arc =====

-- A purple energy arc between the two swapped players. Deliberately a
-- textureless Beam: an untextured Beam renders as a solid emissive ribbon,
-- and with CurveSize0/1 pushed out it whips like a lightning bolt — which
-- avoids depending on a third-party texture asset that could be moderated
-- (the same permissions risk the audio pass had to verify around).
function VisualEffectsService.ShowSwapArc(fromPart: BasePart?, toPart: BasePart?, durationSeconds: number)
	if fromPart == nil or toPart == nil then
		return
	end

	local fromAttachment = Instance.new("Attachment")
	fromAttachment.Name = "SwapArcFrom"
	fromAttachment.Parent = fromPart

	local toAttachment = Instance.new("Attachment")
	toAttachment.Name = "SwapArcTo"
	toAttachment.Parent = toPart

	local beam = Instance.new("Beam")
	beam.Name = "SwapArc"
	beam.Attachment0 = fromAttachment
	beam.Attachment1 = toAttachment
	beam.Color = ColorSequence.new(Color3.fromRGB(190, 90, 255))
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Width0 = 1.6
	beam.Width1 = 1.6
	beam.CurveSize0 = 14
	beam.CurveSize1 = -14
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	beam.Parent = fromPart

	Debris:AddItem(beam, durationSeconds)
	Debris:AddItem(fromAttachment, durationSeconds)
	Debris:AddItem(toAttachment, durationSeconds)
end

-- ===== Cast burst =====

-- Glowing orbs thrown off at the moment of a cast. One short emit rather
-- than a sustained emitter, so nothing has to be turned off later.
function VisualEffectsService.ShowCastBurst(character: Model, colour: Color3)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "CastBurst"
	attachment.Parent = rootPart

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colour)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.4),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.4, 0.7)
	emitter.Speed = NumberRange.new(9, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(28)

	Debris:AddItem(attachment, 2)
end

-- ===== Cast wind-up and projectile =====

-- Energy gathering at the caster during the wind-up, so a cast reads as
-- something being CHARGED rather than something that already happened. Unlike
-- ShowCastBurst this is a sustained emitter for a known window, so it has to
-- be switched off — Rate = 0 first, then destroyed a particle-lifetime later,
-- otherwise the last particles would be deleted in mid-air.
function VisualEffectsService.ShowChargeUp(character: Model, colour: Color3, durationSeconds: number)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "CastChargeUp"
	attachment.Position = Vector3.new(0, 0.5, -1.5)
	attachment.Parent = rootPart

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colour)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 1.1),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.25, 0.4)
	-- Negative speed: particles fly INWARD toward the attachment, which is
	-- what makes it read as gathering rather than as another burst.
	emitter.Speed = NumberRange.new(-14, -9)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 90
	emitter.Parent = attachment

	task.delay(durationSeconds, function()
		emitter.Rate = 0
		Debris:AddItem(attachment, 0.6)
	end)
end

local PROJECTILE_SPEED_STUDS = 220
local PROJECTILE_MAX_SECONDS = 1.5

-- The literal "magical energy ball" — a glowing orb with a trailing ribbon
-- that flies from the caster to the target and arrives before the effect
-- lands, so a debuff has a visible source and direction instead of appearing
-- out of nowhere on the victim's screen.
--
-- It HOMES: each frame it re-reads the target part's current position rather
-- than flying a straight line to where the target stood at launch. A racer
-- moves 16 studs a second, so a fixed line would visibly miss on any cast at
-- range, which reads as the projectile having nothing to do with the effect.
--
-- Returns the travel time so callers can align applying the effect with the
-- orb arriving. Anchored and CanCollide = false: it must never shove anyone,
-- which would be a real gameplay change rather than a visual one.
function VisualEffectsService.ShowCastProjectile(fromPart: BasePart?, toPart: BasePart?, colour: Color3) : number
	if fromPart == nil or toPart == nil then
		return 0
	end

	local startPosition = fromPart.Position + Vector3.new(0, 1.5, 0)
	local distance = (toPart.Position - startPosition).Magnitude
	local travelSeconds = math.clamp(distance / PROJECTILE_SPEED_STUDS, 0.12, PROJECTILE_MAX_SECONDS)

	local orb = Instance.new("Part")
	orb.Name = "CastProjectile"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(2.2, 2.2, 2.2)
	orb.Material = Enum.Material.Neon
	orb.Color = colour
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.CanTouch = false
	orb.CFrame = CFrame.new(startPosition)
	orb.Parent = workspace

	local trailFront = Instance.new("Attachment")
	trailFront.Position = Vector3.new(0, 0.8, 0)
	trailFront.Parent = orb
	local trailBack = Instance.new("Attachment")
	trailBack.Position = Vector3.new(0, -0.8, 0)
	trailBack.Parent = orb

	local trail = Instance.new("Trail")
	trail.Attachment0 = trailFront
	trail.Attachment1 = trailBack
	trail.Color = ColorSequence.new(colour)
	trail.LightEmission = 1
	trail.Lifetime = 0.35
	trail.FaceCamera = true
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = orb

	task.spawn(function()
		local startClock = os.clock()
		while true do
			local alpha = (os.clock() - startClock) / travelSeconds
			if alpha >= 1 or orb.Parent == nil or toPart.Parent == nil then
				break
			end
			orb.CFrame = CFrame.new(startPosition:Lerp(toPart.Position, alpha))
			RunService.Heartbeat:Wait()
		end
		-- Trail lifetime outlives the orb, so destroy the orb and let the
		-- ribbon fade on its own rather than snapping both off together.
		orb.Transparency = 1
		Debris:AddItem(orb, trail.Lifetime + 0.1)
	end)

	return travelSeconds
end

-- ===== Race-progress and hazard bursts =====

-- Shared shape for "something happened AT this spot" — a one-shot cone or
-- sphere of glowing particles at a world position rather than on a character.
-- Split out because six different call sites (checkpoint, lap, deposit,
-- pickup, life loss, respawn, block impact) all want exactly this and differ
-- only in colour, count and spread.
local function emitBurstAt(position: Vector3, colour: Color3, particleCount: number, speed: NumberRange, upwardOnly: boolean)
	local anchor = Instance.new("Part")
	anchor.Name = "EffectBurstAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(colour)
	emitter.LightEmission = 1
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.5, 1.0)
	emitter.Speed = speed
	emitter.SpreadAngle = if upwardOnly then Vector2.new(35, 35) else Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, if upwardOnly then -20 else 0, 0)
	emitter.Rate = 0
	emitter.Parent = attachment
	emitter:Emit(particleCount)

	-- The anchor outlives the emit by the particles' own max lifetime; killing
	-- it at emit time would delete the particles mid-flight.
	Debris:AddItem(anchor, 2.5)
end

-- Gate flare for crossing a checkpoint: a quick upward fountain at the
-- player's feet. Cyan rather than the buff/debuff palette on purpose —
-- progress is a third category, and reusing the green would read as "you got
-- a buff", which is the one thing it must not be confused with.
function VisualEffectsService.ShowCheckpointBurst(character: Model)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end
	emitBurstAt(rootPart.Position - Vector3.new(0, 2.5, 0), CHECKPOINT_COLOR, 26, NumberRange.new(14, 22), true)
end

-- Bigger, gold, for a completed lap — same shape as a checkpoint so the
-- relationship reads (it IS a checkpoint, the last one), scaled up so the
-- difference does too.
function VisualEffectsService.ShowLapBurst(character: Model)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end
	emitBurstAt(rootPart.Position - Vector3.new(0, 2.5, 0), REWARD_COLOR, 70, NumberRange.new(20, 34), true)
end

-- Gold fountain for banking fans or grabbing a pickup.
function VisualEffectsService.ShowRewardBurst(character: Model)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end
	emitBurstAt(rootPart.Position, REWARD_COLOR, 40, NumberRange.new(10, 20), true)
end

-- Losing a life. Omnidirectional and red — the visual opposite of the
-- upward progress fountains, so the two can't be mistaken for each other at
-- a glance mid-race.
function VisualEffectsService.ShowLifeLostBurst(character: Model)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end
	emitBurstAt(rootPart.Position, DEBUFF_COLOR, 55, NumberRange.new(16, 28), false)
end

-- Materialising back at a checkpoint after losing a life.
function VisualEffectsService.ShowRespawnBurst(character: Model)
	local rootPart = getRootPart(character)
	if rootPart == nil then
		return
	end
	emitBurstAt(rootPart.Position, CHECKPOINT_COLOR, 45, NumberRange.new(12, 24), false)
end

-- A falling block hitting the road. Takes a position, not a character:
-- nobody has to be standing there for the impact to be worth showing.
function VisualEffectsService.ShowImpactBurst(position: Vector3, colour: Color3?)
	emitBurstAt(position, colour or Color3.fromRGB(255, 210, 120), 60, NumberRange.new(18, 34), false)
end

-- ===== Fan Box crowd celebration =====
--
-- The crowd's answer to a pose: confetti poppers going off along the front of
-- the stand and balloons released over it. Takes the pod's OriginCFrame, so
-- everything is laid out in the stand's OWN frame — local +X is toward the
-- track and the crowd rows run along local Z (see FanBoxCrowdTemplates), which
-- is the same convention TeleportPoseService uses to stand the player up.
-- Placing this in world axes instead would put the confetti behind the stand
-- for half the pods on the oval.
local CELEBRATION_COLORS = {
	Color3.fromRGB(255, 90, 110),
	Color3.fromRGB(255, 205, 60),
	Color3.fromRGB(90, 210, 255),
	Color3.fromRGB(140, 235, 130),
	Color3.fromRGB(210, 130, 255),
}

local POPPER_COUNT = 5
local POPPER_SPACING_STUDS = 9
local BALLOON_COUNT = 10
local BALLOON_RISE_STUDS = 55
local BALLOON_RISE_SECONDS = 7
local BALLOON_SIZE = 3

function VisualEffectsService.ShowCrowdCelebration(originCFrame: CFrame)
	-- Poppers: one burst per popper, spread along the front row so the
	-- reaction reads as coming from the CROWD rather than from the player.
	for index = 1, POPPER_COUNT do
		local along = (index - (POPPER_COUNT + 1) / 2) * POPPER_SPACING_STUDS
		local colour = CELEBRATION_COLORS[((index - 1) % #CELEBRATION_COLORS) + 1]
		local position = (originCFrame * CFrame.new(2, 6, along)).Position
		emitBurstAt(position, colour, 55, NumberRange.new(22, 38), true)
	end

	-- Balloons: anchored so they cannot be batted around, shoved into the
	-- track, or left resting on someone's head — this is decoration, and
	-- decoration that participates in physics is decoration that eventually
	-- becomes a bug report. They rise, fade, and delete themselves.
	for index = 1, BALLOON_COUNT do
		local colour = CELEBRATION_COLORS[((index - 1) % #CELEBRATION_COLORS) + 1]
		local along = (index - (BALLOON_COUNT + 1) / 2) * (POPPER_SPACING_STUDS * 0.6)
		local lateral = if index % 2 == 0 then 4 else 0

		local balloon = Instance.new("Part")
		balloon.Name = "CrowdBalloon"
		balloon.Shape = Enum.PartType.Ball
		balloon.Anchored = true
		balloon.CanCollide = false
		balloon.CanQuery = false
		balloon.CanTouch = false
		balloon.Material = Enum.Material.SmoothPlastic
		balloon.Color = colour
		balloon.Size = Vector3.new(BALLOON_SIZE, BALLOON_SIZE * 1.2, BALLOON_SIZE)
		balloon.CFrame = originCFrame * CFrame.new(lateral, 7, along)
		balloon.Parent = workspace

		-- Each balloon drifts a slightly different way, so ten of them read as
		-- a release rather than as one object drawn ten times.
		local drift = originCFrame * CFrame.new(
			lateral + (index % 3) - 1,
			7 + BALLOON_RISE_STUDS,
			along + (index % 4) - 1.5
		)
		TweenService:Create(balloon, TweenInfo.new(BALLOON_RISE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = drift,
			Transparency = 1,
		}):Play()

		Debris:AddItem(balloon, BALLOON_RISE_SECONDS + 0.5)
	end
end

-- ===== Festive celebration effects =====
--
-- The progress bursts (checkpoint / lap / reward) were all single-colour
-- fountains distinguished only by hue and count, which reads as "a thing
-- happened" rather than as a crowd reacting to a race. These add the two
-- shapes a stadium actually uses to celebrate — confetti and fireworks —
-- built on the same emitBurstAt/Debris pattern as everything else so they
-- inherit its cleanup behaviour rather than inventing a second lifetime rule.
--
-- Deliberately additive: the existing bursts still fire, and these layer ON
-- TOP. A celebration that REPLACED the progress cue would trade information
-- the player uses (which of checkpoint/lap/reward just happened, told by
-- colour) for decoration, and that is a bad trade mid-race.

-- Confetti is the multi-colour version of the progress fountain: several
-- overlapping emits in different colours rather than one, because a
-- ParticleEmitter takes a single ColorSequence and a rainbow SEQUENCE would
-- make each particle cycle through every colour instead of the cloud
-- containing all of them.
function VisualEffectsService.ShowConfettiBurst(position: Vector3, intensity: number?)
	local scale = intensity or 1
	for index, colour in CELEBRATION_COLORS do
		emitBurstAt(
			position + Vector3.new(0, (index % 2) * 0.6, 0),
			colour,
			math.floor(18 * scale),
			NumberRange.new(16 * scale, 30 * scale),
			true
		)
	end
end

local FIREWORK_SHELL_COUNT = 7
local FIREWORK_RISE_STUDS = 90
local FIREWORK_RISE_SECONDS = 1.4
local FIREWORK_SPREAD_STUDS = 150

-- Shells that rise from around a centre point and burst at altitude. Anchored
-- and tweened rather than launched, for the same reason StadiumBlimp and the
-- Fan Box balloons are: this is decoration, and decoration that participates
-- in physics eventually becomes a bug report.
function VisualEffectsService.ShowFireworks(originCFrame: CFrame)
	for index = 1, FIREWORK_SHELL_COUNT do
		local colour = CELEBRATION_COLORS[((index - 1) % #CELEBRATION_COLORS) + 1]
		local angle = (index / FIREWORK_SHELL_COUNT) * math.pi * 2
		local ground = (originCFrame * CFrame.new(
			math.cos(angle) * FIREWORK_SPREAD_STUDS,
			0,
			math.sin(angle) * FIREWORK_SPREAD_STUDS
		)).Position

		task.delay((index - 1) * 0.35, function()
			local shell = Instance.new("Part")
			shell.Name = "FireworkShell"
			shell.Shape = Enum.PartType.Ball
			shell.Anchored = true
			shell.CanCollide = false
			shell.CanQuery = false
			shell.CanTouch = false
			shell.Material = Enum.Material.Neon
			shell.Color = colour
			shell.Size = Vector3.one * 2
			shell.CFrame = CFrame.new(ground)
			shell.Parent = workspace

			local peak = ground + Vector3.new(0, FIREWORK_RISE_STUDS, 0)
			TweenService:Create(shell, TweenInfo.new(FIREWORK_RISE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				CFrame = CFrame.new(peak),
			}):Play()

			task.delay(FIREWORK_RISE_SECONDS, function()
				shell:Destroy()
				-- The burst itself is omnidirectional (upwardOnly = false) —
				-- a firework that only throws sparks upward reads as a
				-- fountain, which is what the progress bursts already are.
				emitBurstAt(peak, colour, 90, NumberRange.new(26, 46), false)
				emitBurstAt(peak, Color3.fromRGB(255, 255, 255), 30, NumberRange.new(18, 34), false)
			end)
		end)
	end
end

VisualEffectsService.BuffColor = BUFF_COLOR
VisualEffectsService.DebuffColor = DEBUFF_COLOR
VisualEffectsService.CheckpointColor = CHECKPOINT_COLOR
VisualEffectsService.RewardColor = REWARD_COLOR

return VisualEffectsService

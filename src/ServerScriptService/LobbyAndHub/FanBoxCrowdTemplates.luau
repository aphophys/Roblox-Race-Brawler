--!strict
--[[
	FanBoxCrowdTemplates
	Builds the 5 FanBoxTiers crowd-stand models ONCE — not once per pod —
	and stores them under ReplicatedStorage.Assets.FanBoxCrowdTemplates,
	one child per tier ("Tier1".."Tier5"). FanBoxGenerator/FanBoxSlotManager
	just Clone() whichever tier matches a pod's current state instead of
	each independently building a fresh crowd from scratch.

	===== Tiers are DENSITY, not size-scale (this round's redesign) =====
	Previous version built ONE base crowd shape and produced the other 4
	tiers by cloning it with a different `.Size` baked in (a uniform
	rescale). That was wrong for this geometry and caused a real bug,
	reported back as "player fan box appears elevated": `.Size` on a
	`UnionOperation` scales the WHOLE mesh around the union's own natural
	centroid (wherever Roblox's CSG engine happens to place it), not around
	the ground plane the figures' feet are standing on — and the crowd's
	natural bounding box never matched `FanBoxTiers.PodBaseSize` in the
	first place (the old block-sized placeholder's footprint, not
	something the stepped-riser design was ever built to fill), so even
	"Tier1 at 1x scale" was forcibly distorting the shape. Any tier other
	than the one whose natural size happened to match would visibly lift
	or sink the whole crowd off the ground.

	Fixed by dropping size-rescaling entirely: each tier is now its own
	independently-built + unioned crowd, sharing the exact same STEP
	geometry (so grounding is always identical) but varying NOOBS_PER_STEP_
	BY_TIER — the number of figures standing on each step. Tier1 is 0 (bare
	steps, no crowd at all — this also directly answers "unoccupied fanbox
	looks full": since every pod starts at Tier1 and Tier1 now genuinely
	has no figures, an unclaimed pod looks empty by construction, with no
	need for any hide/show logic). Density then climbs tier over tier to a
	packed "full house" at Tier5 — exactly the "first tier no noobs, second
	tier a few noobs and far apart... until full house" progression asked
	for. This costs 5 real UnionAsync calls instead of 1, still far cheaper
	than the original per-pod design (pod count, which scales with
	Players.MaxPlayers).

	===== Repositioning is now PivotTo-based, not CFrame-composition (this
	round's fix — the density redesign above did NOT fully fix "elevated";
	it was reported as still floating, and higher, afterward) =====
	The previous version repositioned a tier clone by composing
	`desiredOriginCFrame * (the union result's own .CFrame, recorded once
	right after building)`, on the assumption that a UnionOperation's
	auto-assigned CFrame is a well-defined, composable offset from the
	identity frame it was built in. That assumption was never actually
	verified against Roblox's real CSG behavior — and evidently wrong, or
	at least not reliably so, since the bug persisted (and worsened) even
	after removing the separate `.Size`-rescale distortion.

	Fixed by sidestepping the question of what CFrame a union result gets
	entirely, using the same robust pattern already proven for track pieces
	(TrackPieceTemplates' EntryPivot): each tier's CrowdMesh part is
	wrapped in a Model alongside an invisible "GroundPivot" Part placed at
	the EXACT known ground/origin reference (CFrame.new(0,0,0)) used when
	building that tier's geometry, with GroundPivot set as the Model's
	PrimaryPart. Model:PivotTo(desiredOriginCFrame) then repositions the
	whole model as a rigid group based on the relative transform between
	GroundPivot and the target — correct regardless of whatever CFrame the
	CrowdMesh part itself ends up with, because PivotTo never needs to know
	or care what that is. FanBoxGenerator.cloneTierAt clones the Model,
	PivotTo's it into place, then extracts just the CrowdMesh part
	(discarding the temporary Model+GroundPivot wrapper) — every other
	piece of code downstream still just sees a plain CrowdMesh BasePart
	named "CrowdMesh", unchanged.

	Also made every tier's CrowdMesh CanCollide = true this round (was
	false) — a fan box stand should be something a player can walk up onto,
	not pass through.

	===== Full avatar scale + 6 steps + wider "stadium wall" (this round)
	=====
	Per direct feedback the figures "look small compared to avatar" —
	NOOB_SCALE went from 0.5 to 1.0, so a noob figure is now built at the
	SAME part sizes as a real Roblox R6 character (Head 2x1x1, Torso 2x2x1,
	Arm/Leg 1x2x1 — no scaling at all, not just "closer"). STEP_HEIGHTS grew
	from 3 to 6 ascending risers, and STEP_DEPTH from 4 to 6 studs (more
	comfortable footing at the now-doubled figure size). NOOBS_PER_STEP_BY_
	TIER keeps the same 8-value progression, just reapplied across 6 rows
	instead of 3 — roughly doubling total crowd size per tier, matching the
	now much larger stand. FanBoxGenerator widened PodBaseSize.Z and
	switched pod placement from a fixed straight:curve pod-count RATIO to
	an arc-length/target-width derivation, so adjacent pods sit almost
	touching and the straight/curve spacing is actually even (see that
	module for the full explanation) — the "connected stadium wall" look.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FanBoxTiers = require(ReplicatedStorage:WaitForChild("Configs"):WaitForChild("FanBoxTiers"))

-- Set to false locally to inspect the raw, un-unioned step/figure geometry
-- in Studio before trusting the union — dumps a full-density example into
-- workspace.FanBoxCrowdDebug (a fixed, visible spot) instead of building
-- any real templates. FanBoxGenerator falls back to a plain block per pod
-- while this is off, so the game doesn't break, it just has no crowds.
local BUILD_AS_SINGLE_MESH = true

-- Classic pre-Rthro Roblox default-avatar ("noob") colors. Arms share the
-- head's yellow (not a separate color) — matches the real default rig.
local NOOB_HEAD_COLOR = Color3.fromRGB(255, 216, 0)
local NOOB_TORSO_COLOR = Color3.fromRGB(0, 73, 173)
local NOOB_LIMB_COLOR = Color3.fromRGB(44, 170, 46) -- legs
local NOOB_ARM_COLOR = NOOB_HEAD_COLOR

-- Real classic-R6 default part sizes: Head (2,1,1), Torso (2,2,1), each
-- Arm/Leg (1,2,1) — NOOB_SCALE = 1 means these are used AS-IS, so a noob
-- figure is literally the same size as a real player's avatar (reported
-- back as "looks small compared to avatar" at the previous 0.5 scale).
local NOOB_SCALE = 1
local NOOB_HEAD_SIZE = Vector3.new(2, 1, 1) * NOOB_SCALE
local NOOB_TORSO_SIZE = Vector3.new(2, 2, 1) * NOOB_SCALE
local NOOB_LIMB_SIZE = Vector3.new(1, 2, 1) * NOOB_SCALE -- shared by arms and legs

-- 6 ascending bleacher-style risers (stadium steps, up from 3) — front
-- (shortest, closest to the track) to back (tallest, furthest from it).
-- Depth (local X thickness, away from the track) per step; PodBaseSize.X
-- must comfortably fit #STEP_HEIGHTS * STEP_DEPTH (36 studs — see
-- FanBoxGenerator). Fixed across every tier — density (not step size) is
-- what changes tier to tier.
local STEP_HEIGHTS = { 3, 6, 9, 12, 15, 18 }
local STEP_DEPTH = 6

-- Figures per step, indexed by tier (1 = "Empty" .. 8 = "Superstar Crowd"
-- in FanBoxTiers) — see module docstring. 0 at Tier1 means bare steps, no
-- union-of-figures at all for an unclaimed/brand-new pod. Same 8-value
-- progression as before the step count grew from 3 to 6 — reapplied
-- across twice as many rows now, so total crowd size roughly doubles per
-- tier, matching the much larger stand. Tops out at 9/step for Tier8
-- (columnSpacing = PodBaseSize.Z / 9 — figures are ~4 studs wide at full
-- avatar scale, so they overlap slightly at the very top tier, the same
-- "sold out, packed shoulder-to-shoulder" look most simplified crowd-
-- density systems lean on rather than a real bug).
local NOOBS_PER_STEP_BY_TIER = { 0, 1, 2, 3, 4, 5, 7, 9 }

local FanBoxCrowdTemplates = {}

-- One classic-proportioned "noob" figure (6 parts: head/torso/2 arms/2
-- legs) standing at `originCFrame * CFrame.new(localX, localY, localZ)`,
-- feet-first (localY/localZ let a figure stand on top of a riser step
-- instead of always at ground level). Anchored+non-colliding at creation —
-- the UnionAsync call below yields, and these parts sit parented in
-- workspace until it resolves, so gravity would move an unanchored part
-- mid-union and corrupt the merged geometry.
local function buildNoobFigureParts(originCFrame: CFrame, localX: number, localY: number, localZ: number) : { BasePart }
	local footPosition = (originCFrame * CFrame.new(localX, localY, localZ)).Position

	-- Face the track, not the direction along it. originCFrame's local +X
	-- is the direction that points back toward the track (see
	-- buildStepsAndCrowdParts — it's the same axis the steps ascend away
	-- from), so aim each figure's LookVector along it.
	local footCFrame = CFrame.lookAt(footPosition, footPosition + originCFrame.XVector, Vector3.new(0, 1, 0))

	local function newLimbOrTorso(name: string, size: Vector3, color: Color3, centerY: number, offsetX: number) : BasePart
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = color
		part.Size = size
		part.CFrame = footCFrame * CFrame.new(offsetX, centerY, 0)
		part.Name = name
		return part
	end

	local legsCenterY = NOOB_LIMB_SIZE.Y / 2
	local torsoCenterY = NOOB_LIMB_SIZE.Y + NOOB_TORSO_SIZE.Y / 2
	local armsCenterY = torsoCenterY -- arms hang alongside the torso, same height band
	local headCenterY = NOOB_LIMB_SIZE.Y + NOOB_TORSO_SIZE.Y + NOOB_HEAD_SIZE.Y / 2

	local legOffsetX = NOOB_LIMB_SIZE.X / 2
	local armOffsetX = NOOB_TORSO_SIZE.X / 2 + NOOB_LIMB_SIZE.X / 2

	local leftLeg = newLimbOrTorso("NoobLeftLeg", NOOB_LIMB_SIZE, NOOB_LIMB_COLOR, legsCenterY, -legOffsetX)
	local rightLeg = newLimbOrTorso("NoobRightLeg", NOOB_LIMB_SIZE, NOOB_LIMB_COLOR, legsCenterY, legOffsetX)
	local torso = newLimbOrTorso("NoobTorso", NOOB_TORSO_SIZE, NOOB_TORSO_COLOR, torsoCenterY, 0)
	local leftArm = newLimbOrTorso("NoobLeftArm", NOOB_LIMB_SIZE, NOOB_ARM_COLOR, armsCenterY, -armOffsetX)
	local rightArm = newLimbOrTorso("NoobRightArm", NOOB_LIMB_SIZE, NOOB_ARM_COLOR, armsCenterY, armOffsetX)
	local head = newLimbOrTorso("NoobHead", NOOB_HEAD_SIZE, NOOB_HEAD_COLOR, headCenterY, 0)

	-- Rounded classic-noob head silhouette instead of a plain cube. Built
	-- in (MeshType.Head is a stock Roblox mesh, no Toolbox asset needed).
	-- Stripped again before UnionAsync (stripSpecialMeshes) — CSG doesn't
	-- support SpecialMesh as a union primitive (confirmed via live
	-- playtest: "CSG: One of the primitives was of unknown type").
	local headMesh = Instance.new("SpecialMesh")
	headMesh.MeshType = Enum.MeshType.Head
	headMesh.Parent = head

	return { leftLeg, rightLeg, torso, leftArm, rightArm, head }
end

local function stripSpecialMeshes(parts: { BasePart })
	for _, part in parts do
		local mesh = part:FindFirstChildOfClass("SpecialMesh")
		if mesh ~= nil then
			mesh:Destroy()
		end
	end
end

-- Builds the 6 ascending step platforms plus `noobsPerStep` figures spread
-- evenly across each one (0 means bare steps, no figures at all), as plain
-- anchored Parts parented directly under `parent`. Returns every part
-- built. Step geometry is identical regardless of noobsPerStep — only
-- density (and therefore spacing, since figures always spread across the
-- same `podWidth`) changes tier to tier, so every tier stays grounded
-- exactly the same way. `podWidth` is passed in by the caller (ultimately
-- FanBoxGenerator) rather than read from FanBoxTiers.PodBaseSize.Z
-- directly — see BuildAll's docstring for why.
local function buildStepsAndCrowdParts(parent: Instance, originCFrame: CFrame, noobsPerStep: number, podWidth: number) : { BasePart }
	local allParts: { BasePart } = {}

	for stepIndex, stepHeight in STEP_HEIGHTS do
		-- Local +X points back toward the track (see the module built
		-- against a pod's actual originCFrame at use time); step 1
		-- (shortest) sits nearest X=0, tallest steps further into -X.
		local stepXCenter = -(stepIndex - 0.5) * STEP_DEPTH

		local step = Instance.new("Part")
		step.Anchored = true
		step.CanCollide = false
		step.Material = Enum.Material.Concrete
		step.Color = Color3.fromRGB(150, 150, 150)
		step.Size = Vector3.new(STEP_DEPTH, stepHeight, podWidth)
		step.CFrame = originCFrame * CFrame.new(stepXCenter, stepHeight / 2, 0)
		step.Name = `Step{stepIndex}`
		step.Parent = parent
		table.insert(allParts, step)

		if noobsPerStep > 0 then
			local columnSpacing = podWidth / noobsPerStep
			for column = 0, noobsPerStep - 1 do
				local localZ = (column - (noobsPerStep - 1) / 2) * columnSpacing
				for _, figurePart in buildNoobFigureParts(originCFrame, stepXCenter, stepHeight, localZ) do
					figurePart.Parent = parent
					table.insert(allParts, figurePart)
				end
			end
		end
	end

	return allParts
end

-- Fallback used only if UnionAsync itself fails — a plain block, so
-- BuildAll() always ends up with SOME usable template per tier.
local function buildFallbackBlock(podWidth: number) : BasePart
	local block = Instance.new("Part")
	block.Anchored = true
	block.CanCollide = true -- a fan box stand should be something a player can stand on, not pass through
	block.Material = Enum.Material.Fabric
	block.Color = Color3.fromRGB(60, 120, 200)
	block.Size = Vector3.new(FanBoxTiers.PodBaseSize.X, FanBoxTiers.PodBaseSize.Y, podWidth)
	block.CFrame = CFrame.new(0, FanBoxTiers.PodBaseSize.Y / 2, 0)
	return block
end

-- Builds + unions one tier's crowd shape, at CFrame.new(0,0,0), with
-- `noobsPerStep` figures on each of the 6 steps.
local function buildCrowdMeshForTier(noobsPerStep: number, podWidth: number) : BasePart
	local originCFrame = CFrame.new(0, 0, 0)

	local tempFolder = Instance.new("Folder")
	tempFolder.Name = "TempCrowdParts"
	tempFolder.Parent = workspace

	local allParts = buildStepsAndCrowdParts(tempFolder, originCFrame, noobsPerStep, podWidth)
	stripSpecialMeshes(allParts)

	local firstPart = table.remove(allParts, 1) :: BasePart
	local success, result = pcall(function()
		return firstPart:UnionAsync(allParts, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Automatic)
	end)

	local crowdMesh: BasePart
	if success then
		crowdMesh = result :: BasePart
		crowdMesh.Anchored = true
		crowdMesh.CanCollide = true -- a fan box stand should be something a player can stand on, not pass through
	else
		warn(`FanBoxCrowdTemplates: UnionAsync failed ({tostring(result)}) — using a plain block for this tier instead.`)
		crowdMesh = buildFallbackBlock(podWidth)
	end

	tempFolder:Destroy()

	return crowdMesh
end

-- See module docstring — the exact ground/origin reference every tier's
-- crowd geometry is built against, kept as an invisible Part inside each
-- tier's wrapper Model so Model:PivotTo can reposition a clone correctly
-- without needing to know anything about the CrowdMesh part's own CFrame.
local function addGroundPivot(model: Model) : Part
	local pivot = Instance.new("Part")
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.Transparency = 1
	pivot.Size = Vector3.new(1, 1, 1)
	pivot.CFrame = CFrame.new(0, 0, 0)
	pivot.Name = "GroundPivot"
	pivot.Parent = model
	model.PrimaryPart = pivot
	return pivot
end

local templatesFolder: Folder? = nil

-- Builds all 8 tier templates and stores them under ReplicatedStorage.
-- Assets.FanBoxCrowdTemplates, each as a small Model (CrowdMesh +
-- GroundPivot — see module docstring). Blocking (8 UnionAsync yields) —
-- meant to be called once, at server start, before any pod tries to clone
-- from it.
--
-- `podWidth` is the ACTUAL width to build every tier's steps/figure-
-- spacing at — passed in by FanBoxGenerator rather than read from
-- FanBoxTiers.PodBaseSize.Z directly, because that width isn't always the
-- same: FanBoxGenerator derives it (see computePodsPerPiece) from how many
-- pods actually need to fit the track for the current Players.MaxPlayers,
-- so pods stay non-overlapping and snugly "connected" even when a high
-- player cap needs more (and therefore narrower) pods than the nominal
-- FanBoxTiers.PodBaseSize.Z would allow without overlapping.
function FanBoxCrowdTemplates.BuildAll(podWidth: number) : Folder?
	if not BUILD_AS_SINGLE_MESH then
		local debugFolder = Instance.new("Folder")
		debugFolder.Name = "FanBoxCrowdDebug"
		buildStepsAndCrowdParts(debugFolder, CFrame.new(0, 0, 0), NOOBS_PER_STEP_BY_TIER[#NOOBS_PER_STEP_BY_TIER], podWidth)
		debugFolder.Parent = workspace
		return nil
	end

	local folder = Instance.new("Folder")
	folder.Name = "FanBoxCrowdTemplates"

	for tierIndex in FanBoxTiers.Tiers do
		local noobsPerStep = NOOBS_PER_STEP_BY_TIER[tierIndex] or NOOBS_PER_STEP_BY_TIER[#NOOBS_PER_STEP_BY_TIER]
		local tierCrowdMesh = buildCrowdMeshForTier(noobsPerStep, podWidth)
		tierCrowdMesh.Name = "CrowdMesh"

		local tierModel = Instance.new("Model")
		tierModel.Name = `Tier{tierIndex}`
		tierCrowdMesh.Parent = tierModel
		addGroundPivot(tierModel)
		tierModel.Parent = folder
	end

	local assetsFolder = ReplicatedStorage:FindFirstChild("Assets") :: Folder?
	if assetsFolder == nil then
		local newAssetsFolder = Instance.new("Folder")
		newAssetsFolder.Name = "Assets"
		newAssetsFolder.Parent = ReplicatedStorage
		assetsFolder = newAssetsFolder
	end
	folder.Parent = assetsFolder

	templatesFolder = folder
	return folder
end

-- Returns the tier's wrapper Model (CrowdMesh + GroundPivot) — callers
-- Clone() this, Model:PivotTo(desiredOriginCFrame) it into place, then
-- extract the CrowdMesh part (see FanBoxGenerator.cloneTierAt).
function FanBoxCrowdTemplates.GetTemplateForTier(tierIndex: number) : Model?
	if templatesFolder == nil then
		return nil
	end
	local tierModel = templatesFolder:FindFirstChild(`Tier{tierIndex}`)
	if tierModel ~= nil and tierModel:IsA("Model") then
		return tierModel
	end
	return nil
end

-- Highest tier whose MinFans the given fan count satisfies (Tiers is
-- ordered ascending by MinFans).
function FanBoxCrowdTemplates.GetTierIndexForFanCount(fanCount: number) : number
	local selectedIndex = 1
	for tierIndex, tier in FanBoxTiers.Tiers do
		if fanCount >= tier.MinFans then
			selectedIndex = tierIndex
		end
	end
	return selectedIndex
end

return FanBoxCrowdTemplates

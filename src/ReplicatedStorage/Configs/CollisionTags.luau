--!strict
--[[
	CollisionTags
	New module — shared tag/collision-group constants for the Phase
	mechanic (PhaseSelf) and any obstacle a phasing player should pass
	through: today just TrackGenerator's HazardBar, later also thin
	climbing-map walls. Any such obstacle should get BOTH, via MarkPhaseable
	below: a CollectionService tag (HazardTag — so it can be found/
	recognized as "a phaseable obstacle") AND CollisionGroup =
	HazardCollisionGroup (the actual physics mechanism that lets ONE
	phasing player pass through it without disabling collision for anyone
	else, which a plain `part.CanCollide = false` would do since that
	property isn't per-player).

	The two custom PhysicsService collision groups are registered here, at
	module top level (not inside a function) — this runs exactly once, the
	first time ANYTHING requires this module, since Luau caches modules; any
	other caller gets the same already-registered groups back regardless of
	require order. RegisterCollisionGroup errors if the group already
	exists, which is the only realistic failure mode here (a second require
	somehow re-running this file) — wrapped in pcall, safe to ignore.
]]

local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local CollisionTags = {
	HazardTag = "PhaseableHazard",
	HazardCollisionGroup = "Hazards",
	PhasingCollisionGroup = "PhasingPlayers",
	MovingPlatformCollisionGroup = "MovingPlatforms",
}

pcall(function()
	PhysicsService:RegisterCollisionGroup(CollisionTags.HazardCollisionGroup)
end)
pcall(function()
	PhysicsService:RegisterCollisionGroup(CollisionTags.PhasingCollisionGroup)
end)
pcall(function()
	PhysicsService:RegisterCollisionGroup(CollisionTags.MovingPlatformCollisionGroup)
end)
PhysicsService:CollisionGroupSetCollidable(CollisionTags.HazardCollisionGroup, CollisionTags.PhasingCollisionGroup, false)
-- Hazards must not collide with EACH OTHER. Several hazards are unanchored
-- parts held in place by a RigidityEnabled AlignPosition, and by design they
-- share space: a Volcanic/Desert sweeper rank is 4 bars sliding along the same
-- line that cross twice per cycle, and Classic's curve pair are two spinning
-- bars whose tips meet at the road's centreline. Two rigid constraints and a
-- solid contact between the same pair of parts is a fight the solver can only
-- resolve by displacing something — which is the drift these hazards keep
-- being patched for. Nothing about the mechanic wants hazard-on-hazard
-- collision; only hazard-on-PLAYER collision matters, and that is unaffected
-- (players are in the Default group).
PhysicsService:CollisionGroupSetCollidable(CollisionTags.HazardCollisionGroup, CollisionTags.HazardCollisionGroup, false)

-- Moving platforms need the same self-exemption as hazards, for the same
-- reason, but they must NOT share the Hazards group: a phasing player has to
-- keep colliding with a platform they might be standing on, or PhaseSelf drops
-- them through the deck into whatever the platform is spanning.
--
-- The overlap is real, not theoretical. SkyRail's curve puts a row of decks over
-- the chasm on each of two adjacent chords, and adjacent chords are rotated
-- against each other (a curve's floor is a polygon, not an arc), so deck corners
-- swing into one another — measured live at ~6% of samples once the two decks
-- come within a stud of the same height. Unanchored, rigidly-constrained, and
-- solid against each other is exactly the combination that makes a deck jitter
-- under a rider.
PhysicsService:CollisionGroupSetCollidable(CollisionTags.MovingPlatformCollisionGroup, CollisionTags.MovingPlatformCollisionGroup, false)

-- The one call site every current and future phaseable obstacle should
-- use, so the tag and the actual collision-group behavior can never drift
-- out of sync with each other.
function CollisionTags.MarkPhaseable(part: BasePart)
	CollectionService:AddTag(part, CollisionTags.HazardTag)
	part.CollisionGroup = CollisionTags.HazardCollisionGroup
end

-- Marks a rideable moving deck. Not phaseable, deliberately — see above.
function CollisionTags.MarkMovingPlatform(part: BasePart)
	part.CollisionGroup = CollisionTags.MovingPlatformCollisionGroup
end

return CollisionTags

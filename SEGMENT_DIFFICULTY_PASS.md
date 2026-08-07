# Segment difficulty pass — working process and state

Goal: make the game more challenging, one segment at a time. Core gameplay is
already fine; this pass only adds/tunes hazards.

## THE PROCESS — follow this exactly, every segment

1. **Reuse, don't invent.** Add difficulty by reusing an existing hazard. If a
   new hazard is genuinely needed, build it from the *same methods* the existing
   ones use (the shared helpers in `ThemeHazardBuilder`), not a parallel system.
   Reuse means reuse: take the existing thing as-is. Changing its size, count,
   timing or detection method on the way in is no longer reuse, and that is
   exactly what went wrong on the first attempt (see Session log below).
2. **Force the segment onto the map** so it can be inspected on demand instead of
   waiting for a random generation to produce it.
3. **Move the player to it**, then **stop and wait for the user's command.** Do
   not start editing.
4. Apply the requested edits.
5. **Test via the official route** — the player joins the race through the real
   game path, never a synthetic shortcut.
6. **Wait for the user's confirmation that it is okay** before moving to the next
   segment. Do not proceed on your own judgement.

## What "a segment" means here

Two axes, and only the second is worth iterating on:

- **8 blueprint slots** (`TrackBlueprints.OvalSegments`) — fixed shape/position
  only: slots 1-2 and 5-6 are Straights, 3-4 and 7-8 are Curves.
- **8 themes** (`TrackThemes`) — all the hazard content. `TrackGenerator` assigns
  4 random distinct themes to the fixed pairs `{1,2} {3,4} {5,6} {7,8}` every
  generation, so slot 3 has no stable identity.

So the real unit is **theme x {Straight, Curve} = 16 variants**, all built by
`ThemeHazardBuilder.HAZARD_BUILDERS[themeId]`. One theme per cycle covers both
its straight and its curve.

### The 16 variants as of this pass (all still original — see Status)

| Theme | Straight | Curve |
|---|---|---|
| Classic | 1 spinning bar, 70 long, 120 deg/s, centre Y=5 | 2 half-bars (35 each) meeting at centreline |
| HillMud | 1 phaseable truss wall h=30 + jump platforms | 2 phaseable walls h=15 at 34-stud end clearance + platforms |
| IceFrost | road split lengthwise: water swim lane + non-phaseable ice wall h=25 | full-width non-phaseable ice wall h=22 at arc middle |
| Volcanic | magma field 5 patches / 130 studs (life loss) + 4-bar sweeper rank | magma field 3 patches / 60 studs |
| WaterDock | coin flip: 135-stud swim pool, or 45-stud pool + zig-zag bridges | middle 2 chords cut out, full-width pond |
| SkyRail | steps up to Y=10, bridge / 2 vertical movers / bridge, steps down, chasm below | 12-stud outside ledge + 3 lanes of oscillating decks over a chasm |
| Desert | 4-bar sweeper rank + ambient `DesertWindService` headwind | 2 phaseable dune walls h=12 + jump platforms |
| NeonCircuit | falling blocks, 3 per wave, 8-stud cubes, span 126 | same, span 60 |

Only **Volcanic magma** and **NeonCircuit blocks** cost a life (via
`ZoneHazardMonitor`). Everything else is a physical obstacle or a slow-down.
`TrackThemes.WalkSpeedModifier` is config-only, not wired to gameplay.

## THE BIG ONE: never build game objects through `execute_luau`

`mcp__Roblox_Studio__execute_luau` has its own require cache. PROJECT_STATE.md
already warned that *reading* module state through it is unreliable. The far
worse case, which cost most of two sessions, is **calling a builder** through it.

`require(TrackGenerator)` from `execute_luau` returns a fresh copy of the ENTIRE
dependency graph: TrackGenerator, ThemeHazardBuilder, ZoneHazardMonitor,
PlayerStateService — all duplicated. `Regenerate()` on that copy builds a real,
visible track into the real workspace, so it looks like it worked. But every
hazard it creates closes over the PHANTOM ZoneHazardMonitor, whose
PlayerStateService never saw the live `EnterTrack`. Those hazards therefore read
every player as `InLobby` and can never take a life, and the zones they register
go into a monitor whose polling loop was never started.

Proven by printing module identity from both ends during one impact:

```
ArcadeManager      sees PlayerStateService = table: 0xabfcf817a0bcb2b3  readback InRace
ZoneHazardMonitor  sees PlayerStateService = table: 0x3a6523c5696ac833  GetState InLobby
```

Same ModuleScript (verified: exactly one in the DataModel), two instances, same
player object, same instant. Everything that looked like a broken hazard — across
two sessions — was this. The falling blocks were correct the whole time.

**Rule: `execute_luau` may READ the DataModel and SET attributes. It must never
`require` a module that builds or owns live gameplay objects.** Cross the
boundary as data and let the live server react.

## Harness — force a segment via attribute (current, correct)

`TrackGenerator.Init()` watches `workspace:GetAttribute("DevForcedPairThemes")`
(Studio only) and regenerates when it changes. Set it as a comma-separated list
of 4 theme ids, or a single id as shorthand for the whole oval:

```lua
-- Server datamodel, no require() at all:
workspace:SetAttribute("DevForcedPairThemes", "Classic")                      -- whole oval
workspace:SetAttribute("DevForcedPairThemes", "Classic,Classic,NeonCircuit,NeonCircuit")
workspace:SetAttribute("DevForcedPairThemes", "")                             -- back to random
```

Pairs are `{1,2} {3,4} {5,6} {7,8}` — so entries 1 and 3 are the straights,
2 and 4 the curves.

## Superseded harness notes (kept for context)

A dev override was added to `TrackGenerator` and then reverted with everything
else. If rebuilt, it was: `TrackGenerator.SetForcedPairThemes({id, id, id, id})`
pinning one theme per `SEGMENT_PAIRS` entry, nil to restore random draws, honored
inside `pickOvalSegmentThemes`. Passing the same id four times puts that theme's
straight AND curve on the oval at once.

Cycle that actually worked:

1. Server datamodel — set the forced themes, then `TrackGenerator.Regenerate(workspace)`.
2. Client datamodel — `ReplicatedStorage.RemoteEvents.Hub.EnterTrack:FireServer()`.
   This is the official route and it is **required**, not optional: an `InLobby`
   player standing on the track is bounced to the Hub by `TrackBoundaryMonitor`
   (see its `InLobby`/`AtFanBox` branch).
3. Client datamodel — `char:PivotTo(...)` to the target segment. Must be client
   side; the client owns the character.

Aiming the teleport: segment 1's entry is the world origin, **-Z is forward**
along any piece, straights are 180 studs so a straight's centre hazards sit at
Z = -90 from its entry. `CheckpointTrigger_N` sits at segment N's *exit*, which
is segment N+1's entry — the reliable way to find any other segment's entry.

## Environment gotchas that cost real time

- **`execute_luau` has its own `require` cache.** Modules required from it are
  fresh copies, so setting module state (`PlayerStateService.SetState`,
  `ArcadeManager.EnterTrack`, monkey-patching a function to trace callers) never
  reaches the live game. Writes straight to the DataModel are fine —
  `TrackGenerator.Regenerate` rebuilds the real `workspace.Track` correctly. To
  drive live server state, fire the real RemoteEvent from the Client datamodel.
- **Source edits need a play-session restart.** The running server caches modules
  at startup; Rojo syncing mid-session changes the script text but not the loaded
  module. Stop play, confirm the sync landed, then start play.
- **Rojo's push can lag a Play press.** Verify in the Edit datamodel before
  starting, or the session silently runs the old build.
- **`script_grep` during Play searches the CLIENT datamodel**, which never
  contains `ServerScriptService` — "no matches" there proves nothing about server
  scripts. Stop play, or read `ModuleScript.Source` from the Server datamodel.
- **Studio attestation (PREFLIGHT.md) expires** on a 20-minute TTL and on every
  `start_stop_play`, and must be re-run in the datamodel being used.

## Session log — first attempt at Classic, REVERTED

Attempted: reuse NeonCircuit's falling blocks on Classic. Extracted its spawner
to a shared `createFallingBlockField` and called it from `buildClassic` (8 per
wave, then 4 per wave at 6-stud cubes, kept outside the spinning bar's sweep),
plus the same field on the curve's flanking chords.

Reverted in full at the user's request. Patch preserved outside the repo at
`scratchpad/revert-backup/classic-pass.patch`.

**Why it was reverted:** blocks hit the player but never cost a life, across many
cycles. The mistakes worth not repeating:

- It was not pure reuse. Block size, count and a keep-out radius were changed on
  the way in, and a `.Touched` contact path was added that Neon's block never
  had. That pulled `ZoneHazardMonitor` and `PlayerStateService` into a change
  that was supposed to touch one theme's builder.
- The `.Touched` path fires **once per limb** — measured ~20 events in a single
  frame — so every impact was ~20 separate violations. That drained all 3 lives
  instantly, opened the elimination window, timed out, refilled to 3 and returned
  the player to the Hub, which looks identical to the hazard doing nothing.

**RESOLVED — both open questions, measured live on the original code.**

*NeonCircuit's block does cost a life.* Verified end to end via the official
join route on a Neon curve: 33 blocks entered, 215 samples with the
HumanoidRootPart genuinely inside a `NeonBlockZone`, and `Lives` dropped on
schedule. The shipped poll-based mechanic works. Nothing about it needed fixing.

*The `InLobby` "contradiction" was a misreading, not a bug.* There is no
divergence between `currentStates` and the `PlayerState` attribute. What actually
happens is the **elimination cycle**, and it is fast:

```
lose last life -> Lives = 0 -> elimination window opens (EconomyRates.
EliminationTimeoutSeconds = 10s) -> nobody buys a revive -> onEliminationTimeout
-> Lives refilled to MAX_LIVES (3) -> ArcadeManager.LeaveTrack -> ReturnToHub
-> PlayerState = InLobby
```

Measured: `LIVES -> 0` at 9.7s, then at 19.7s `LIVES -> 3` and `STATE -> InLobby`
in the same tick — exactly the 10s timeout. So a test that keeps a character
parked in hazards gets silently returned to the Hub with full lives, and every
subsequent hazard contact then correctly bails on the InRace check. Last session
that produced a console full of `blocked by state: InLobby` while a separately-
timed attribute read still said `InRace`; the two readings were simply taken at
different moments either side of an elimination.

**Two traps this creates for any future hazard test:**

- `Lives` **persists across sessions** (ProfileStore). This test began at
  `Lives = 1`, not 3, so elimination arrived after a single hit. Always read
  `Lives` before starting and account for it.
- A test loop longer than a few seconds will cross an elimination boundary and
  silently continue against an `InLobby` player. Assert `PlayerState == InRace`
  at the moment of each expected hit, not once at the start.

## Resolved issues worth not rediscovering

**`CFrame.LookVector` is FORWARD, not backward.** Track pieces chain with -Z as
forward, and LookVector is that axis — so it points the way the racer is going.
Both the IceFrost current and the snowball push shipped backwards first: measured,
a swimmer was carried 70 studs *forward* over 15s, i.e. the "current" was a free
ride down the fast route. Anything meant to push a player BACK needs
`-cframe.LookVector`.

**Pushing a player must be a CFrame translation, not an impulse.** The Humanoid
re-drives horizontal velocity toward `MoveDirection * WalkSpeed` every physics
step, so velocities and forces applied to a controlled character are erased within
a frame or two. `pushPlayer` writes the CFrame each frame instead. Same root cause
DesertWindService and the SkyRail curve both documented.

**A rigid `AlignPosition` DRAGS its part, it does not teleport it.** The first
curve clock-sweep retargeted its constraint across the arc on every wrap, which
asked the solver to haul a 70-stud bar the length of the curve through barriers
and road. Measured: the bar sat 145 studs from its own target at velocity 0.2 —
permanently wedged. Wraps must set `part.CFrame` directly (and zero the
velocities) rather than moving the constraint target.

**A curve's road is a ring of straight CHORDS, not an arc.** Anything swept along
the true circle overhangs the road between chord ends — measured at 1.9 studs
past the road edge, enough to bury a full-width bar in a barrier and jam it. Sweep
at `radius - sagitta`, where
`sagitta = R * (1 - cos(arcDegrees / subdivisions / 2))`.

**Derive a curve's handedness, never type it in.** `createCurveSweeperBar` finds
the centre of curvature one radius to the +X side of the entry, then works out
which way the angle advances by testing `(Y x radial) . entryForward`. Curve
handedness is wrong half the time when assumed.

**A curve's exit is a checkpoint, and on the last segment it is the START LINE.**
A hazard that begins on the exit plane shoves the entire field backwards the
instant a race starts. `CURVE_SWEEPER_START_CLEARANCE` (30 studs of arc) holds the
sweep back. The same rule already existed as HillMud/Desert's `endClearance`.
**Still open:** the sweep still reaches the curve's ENTRY, which is also a
checkpoint — a player respawning there can be shoved. Left deliberately, because
adding matching clearance costs ~30 studs of unswept arc at that end.

**The on-track test measured 3D distance to a road-level centreline sample.** So
height ate the same budget as sideways travel, and climbing above
`ON_TRACK_MARGIN` (49) cost a life — which meant reaching the top of HillMud's own
60-stud wall was fatal. Now horizontal distance and a separate
`MAX_HEIGHT_ABOVE_TRACK` (120, derived: 60 wall + 3 stand + 26 boosted jump + 31
headroom).

**Sweepers and magma answer different actions, on purpose.** Sweepers span the
full road (`HAZARD_SPAN_WIDTH`) and are beaten by JUMPING. Magma is never
full-width and is beaten by STEERING. Volcanic's asserts enforce both directions —
magma must always leave a walkable lane, and consecutive patches must be within a
walking player's lateral reach. That reach is the real limit on how irregular a
magma field can be: patches ~13 studs apart at 16 studs/s allow ~13 studs of
sideways movement, so consecutive offsets may differ by at most ~0.18 of the road
width. Truly random scatter would make the field jump-only.

**Verify direction and motion against something unambiguous.** Comparing a
hazard's movement to a road part's `LookVector` gave nonsense (a curve's parts are
rotated); comparing world X/Z separations on a curve falsely flagged correctly
spaced platforms as stacked, because a 10-stud gap at 45 degrees projects to 7.1
on both axes. Measure distance-from-entry, or transform into the part's own frame.

## Performance baseline (measured, single player, Studio)

Worst-case per-frame load is ~50 parts each holding one `RunService.Heartbeat`
connection (moving jump platforms, SkyRail decks, sweeper bars, bridge platforms).
Sleeping `task.spawn` loops number under ten. Projectile-heavy layouts spawn ~16
short-lived coroutines per second.

Server step time on both the platform-heaviest and projectile-heaviest layouts:
mean **16.66 ms — exactly the 60 Hz cap** — with p95 21-22 ms and worst 22-26 ms.
The server is idling at its ceiling, so nothing here is a performance problem yet.
If it ever becomes one, the cheapest win is consolidating those 50 individual
Heartbeat connections into one loop walking a list.

## Status

Four themes done, four to go. Nothing is committed.

| Theme | State |
|---|---|
| **Classic** | DONE — falling blocks reused from NeonCircuit: 4/wave, 6-stud cubes. Straight keeps its spinning bar with a 39-stud keep-out around it; curve gets 2+2 blocks on the chords flanking the bars. |
| **HillMud** | DONE — walls doubled (straight 60, curve 30) and one extra wall each. Serpentine staircase, upper rows drift toward the wall. 2 static pads on each wall top, sweeping bridge platforms between walls at wall-top height, count derived from jump reach. |
| **IceFrost** | DONE — straight has 2 walls and a periodic wave costing the swim route exactly what the climbs cost the road route. Curve keeps its wall and gains 2 snowball ramps off the wall top, launched at 45 studs/s, bouncy, phaseable, push-back not life-loss. |
| **Volcanic** | DONE — straight: 10 half-size magma patches (walkable) plus 3 one-way sweepers. Curve: 8 arc-placed patches plus a 3-bar clock sweep about the circle's centre. |
| WaterDock, SkyRail, Desert, NeonCircuit | not started |

Shared machinery added along the way, available for reuse by the remaining
themes: `createFallingBlockField`, `pushPlayer`, `addWallTopPads`,
`addBridgePlatforms`, `createSnowballRun`, `createCurveSweeperRank`,
`createCurveMagmaField`, and one-way/count parameters on `createSweeperRank`.

Deferred by user decision: making moving platforms carry their rider (lives in
the shared `createMovingPlatform`, so it would also change SkyRail), and applying
Classic's 6-stud / 4-per-wave block sizing to NeonCircuit.

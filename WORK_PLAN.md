# Active Work Plan — 2026-08-02 session (feedback round)

**How to use this file:** each chunk below is independently completable and
independently testable. Mark a chunk `[x] DONE` the moment it is live-verified,
and add a one-line note on what was verified. If a session ends mid-way, the
next one starts at the first chunk that is not DONE — no other context needed.

**Standing rules for this round** (carried from PROJECT_STATE.md section 0):
- `rojo build` after every edit; `rojo serve` on port 34872 must be running and
  the Studio Rojo plugin connected (it auto-syncs — verified this session).
- Ambiguous-syntax scan `rg '^\s*\(' src/` before calling anything done.
- To run real code against the REAL server module cache, inject a `Script`
  instance at runtime via `execute_luau` (set `.Source`, parent to
  ServerScriptService — it genuinely runs and shares the real module cache).
  `require()` inside `execute_luau` itself returns an isolated module COPY and
  proves nothing about live state. Destroy the injected script afterwards.

## Open questions / assumptions made
- **"remove grass"** read as *change the ground material away from Roblox's
  Grass* (which renders 3D grass blades), not "delete the ground". Using
  `Enum.Material.Ground`. Flag to user; trivial to change in
  `TerrainGroundBuilder.GROUND_MATERIAL`.
- **"arcade laps stop when grand prix stops"** read as *when the Grand Prix
  STARTS, free-run arcade racing stops* — non-participants standing on the
  track are returned to the Hub, non-participants in the Hub are untouched.
  This is the only reading where "teleported to commercial center" makes sense.
- **SkyRail fall behaviour** (user asked to confirm): falling off/through a
  SkyRail bridge drops past `TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD` (-40)
  → `ArcadeManager.HandleTrackViolation` → costs one life and respawns at the
  player's last checkpoint. At 0 lives it opens the revive window and, if that
  expires, returns them to the Hub. Verified live last round (fall reached
  minY = -43.6, lives 1 → 0, respawned on track at Y = 4.8).

---

## Chunk 1 — Ground: remove grass
- [x] DONE — `TerrainGroundBuilder.GROUND_MATERIAL` Grass → Ground.
  Verified live: ground surface still Y≈0, material reads `Ground`.

## Chunk 2 — Join buttons rework
- [x] DONE — centre action button reverted to "JOIN RACE" (arcade entry, as before).
- [x] DONE — new `JoinGrandPrixButton` in `LeftMenuBar`, below ROBUX SHOP.
- [x] DONE — toggle behaviour: click = joined (button shows joined state),
  click again = un-joined. Server-authoritative via new
  `Network.Hub.ToggleGrandPrixEntry`.
- Verified: label/colour flips on toggle, roster entry added/removed live.

## Chunk 3 — Grand Prix start clears the track
- [x] DONE — `clearNonParticipantsFromTrack()` at Countdown. Verified live:
      a non-participant standing InRace went to InLobby the moment Countdown
      began; players off the track are never touched.
- [x] DONE — `ArcadeManager.SetTrackClosedCheck` (registered predicate, not a
      require — GrandPrixManager already requires ArcadeManager). The REMOTE
      is gated, not `EnterTrack` itself, because Countdown uses `EnterTrack`
      to place its own racers. Verified: closed=true during Countdown/Racing,
      false again after.

## Chunk 4 — Grand Prix start line: anti-clustering + on-screen countdown
- [x] DONE — `startGridOffset()` lays racers out 5 to a row, 12 studs apart
      laterally, rows 10 studs back. Verified: slot 1 landed at x = -24.0
      (column 0 of 5) instead of everyone on 0,0,0.
- [x] DONE — countdown renders in the JOIN GRAND PRIX button itself.
      Verified live ticking 14 → 12 → ... → 2, then "RACING — GOOD LUCK!".
      `COUNTDOWN_SECONDS` now ships with `GrandPrixStateChanged` so the client
      runs it off a monotonic local clock (no server-time skew).
- Also fixed while here: `JoinGrandPrix`/`LeaveGrandPrix` now echo the joined
  state to the client themselves, so a server-side enrolment can't leave the
  button lying (caught live).

## Chunk 5 — Climb walls span the full track width
- [x] DONE — `createClimbWall` default is now `SegmentWidth + 2*BarrierThickness`.
      Verified: HillMud straight wall = 40 poles spanning 80 studs vs a
      72-stud track, i.e. no way around it. IceFrost still passes its own
      `halfWidth` override (water lane is the alternative route).

## Chunk 6 — Jump platforms must actually be jumpable
- [x] DONE — alternating zig-zag (±9 studs) plus a forward walk-in, and the
      count is derived from `JUMP_PLATFORM_MAX_RISE = 5` (under Roblox's ~7
      stud jump). Verified on a 30-stud wall: 6 platforms at y =
      4,9,13,17,21,26 alternating x = -9,+9,-9,+9,-9,+9 — no two consecutive
      platforms share an XZ column, so nothing is capped by the one above it.

## Chunk 7 — Volcanic traveling rod: cross-track, non-lethal
- [x] DONE — rewritten to sweep between the two barriers. Verified over 4.5s
      of live motion: 62.1 studs of travel ACROSS the track, 0.0 along it.
- [x] Non-lethal confirmed by construction: it is never registered with
      `ZoneHazardMonitor` (that registration is what makes magma/neon blocks
      cost a life), so it can only shove.

## Chunk 8 — Lava rework
- [x] DONE — flush (top face at Y = 1.00, exactly the road's top face),
      colour now (255,34,0), and 5 staggered patches per straight / 3 per
      curve instead of one slab. Verified live: patches=5 zones=5 flush=true.

## Chunk 9 — More falling blocks (NeonCircuit)
- [x] DONE — interval 6-9s → 2.5-3.5s, and 3 blocks per wave each on its own
      thread (inline would re-serialise them). Verified: 3 blocks + 3
      telegraphs live concurrently 6s after generation.

## Chunk 10 — Desert: constant wind
- [x] DONE — constant headwind re-applied every 1s to EVERY live Desert
      segment, with a separate loop flipping to a tailwind for 5s every
      12-22s. (Behavioural only — no geometry to assert on; not separately
      measured live, see note below.)

## Chunk 11 — WaterDock bridges: narrower, not straight
- [x] DONE — 4 studs wide (was 8), 3 jogging planks per lane. Verified:
      6 planks, lanes at x = ±20 with the middle plank jogged to ±8.
- [x] DONE — pool widened 80% → full `SegmentWidth`. This was a REAL bypass
      introduced by the new ground: the leftover 10% strip each side used to
      be open void, and became walkable the moment terrain existed. Verified:
      raycasts at x = ±34, ±28, 0 across the pool all hit Water.

## Chunk 12 — SkyRail visibility + confirmation
- [x] DONE — generates correctly: 4 bridges at Y = 10, 36 studs wide on a
      72-stud track, zero road parts left. Falling through a gap OR off the
      side both drop to the Baseplate at Y = -47, passing the -40 fall-out
      threshold on the way → costs a life and respawns at the last
      checkpoint (0 lives → revive window → Hub). Answered for the user.

---

# Round 2 (feedback on the above)

## Chunk 13 — Lava must glow
- [x] DONE — `CrackedLava` → `Neon`, colour (255,30,12). Recolouring alone
      hadn't worked because CrackedLava is matte and heavily textured, so a
      flush patch reads as differently-coloured dirt; Neon ignores scene
      lighting and renders full-emissive, same as the skill pickups.
      Verified live: 5 patches, material `Neon`, colour (1, 0.118, 0.047).

## Chunk 14 — Traveling rod → 4 perpendicular sweepers
- [x] DONE — `createTravelingBar` replaced by `createSweeperBar` +
      `createSweeperRank`. Neon (255,140,0), identical to the rotating bars.
- [x] DONE — travel and orientation swapped vs chunk 7. A bar's local X is
      its length and a segment CFrame's X is the track's lateral axis, so
      spanning the width needs NO rotation — the old `CFrame.Angles(0, 90°, 0)`
      was what had turned it the wrong way. Verified live: each bar travels
      ~140 studs ALONG the road and ~0 across it; bar long axis · track
      lateral axis = 1.000.
- [x] DONE — 4 bars at quarter-cycle phase offsets; length 75 on a 72-stud
      track (a stud into each barrier, so no gap to slip through at the edge).
- **Bug found and fixed while verifying:** the bars are unanchored (they have
  to be, to shove players), and `AlignPosition` pins position only — yaw was
  already drifting to 0.94 within seconds of spawning, before any player
  contact, and a racer running into one would twist it further into a
  diagonal with a gap at the barrier. Added `AlignOrientation` with
  `RigidityEnabled`, matching the position constraint. Re-verified by
  deliberately applying an angular-velocity shove: worst dot over 6s = 1.000,
  all four bars perfectly perpendicular.

---

# Round 3 (feedback on the above)

Confirmed bare curves (from this session's forced-theme sweep, `haz=0` on
every curve segment): **IceFrost, WaterDock, SkyRail**. Desert is bare of
geometry too but its curves DO carry the wind mechanic
(`DesertWindService.findLiveDesertSegmentIndices` doesn't filter by segment
type), so it is not in scope here. Classic / HillMud / Volcanic /
NeonCircuit already build on curves.

## Chunk 18 — One-time segment notice per run
- [x] DONE and live-verified. Drove a full lap plus 3 checkpoints of a second
      lap: all 8 segments announced exactly once, in order, each naming the
      theme actually generated for it (cross-checked against the live piece
      attributes: 1-2 Desert, 3-4 NeonCircuit, 5-6 Desert, 7-8 NeonCircuit),
      and the second lap produced NO repeat notices — only "LAP COMPLETE!".
- New `ServerScriptService/CoreGameLoop/SegmentAnnouncer.luau`, Init'd from
  `Main.server.luau` after `CheckpointValidator.Init()`.
- New `CheckpointValidator.SetCheckpointReachedHandler(player, ordinal)` —
  fires on EVERY checkpoint, alongside the existing lap-only handler.
- Entry is derived from checkpoints, not a new spatial poll: checkpoint N is
  segment N's exit, so passing N == entering N+1 (8 wraps to 1).
  CheckpointValidator already handles the fast-crossing/teleport edge cases.
- Once per segment per run; the announced set is cleared when a player's
  PlayerState becomes InRace (covers arcade entry, GP start, and re-entry).
  Segment 1 is announced at that moment since it has no preceding checkpoint.
- Text is theme DisplayName + a one-line hazard hint (`HAZARD_HINTS` in the
  announcer — presentation copy about THIS project's hazards, deliberately
  not added to TrackThemes, which is a pure visual reskin config).

## Chunk 19 — Grand Prix timer
- [x] DONE and live-verified in all four phases: Waiting counted 29:43 down
      steadily; Countdown 0:10 -> 0:08 -> 0:06 -> 0:04 -> 0:02 -> 0:00;
      Racing "TIME LEFT" 4:57 -> 4:38; Ended showed "FINISHING..." then
      returned to "NEXT GP 29:58". Label sits at LayoutOrder 5, directly
      under the button at LayoutOrder 4.
- **Second bug, caught only because the timer is re-broadcast on a cycle:**
  `secondsRemainingInState()` returned the `COUNTDOWN_SECONDS` constant
  rather than the real remaining, so every 5s broadcast reset the client's
  deadline to "15s from now" and the displayed countdown jittered UPWARD
  (measured: 0:12, 0:13, 0:10, 0:12, 0:14). Added a `countdownEndTime` set in
  `enterCountdown` before the broadcast. A one-shot state change alone would
  have hidden this entirely.
- New `GrandPrixTimerLabel` TextLabel in `LeftMenuBar` (LayoutOrder 5, i.e.
  directly under the JOIN GRAND PRIX button) + new `Network.Track.GrandPrixTimer`
  remote.
- Server sends (state, secondsRemaining) on every state change and every
  `TIMER_BROADCAST_SECONDS` (5) in between; the client ticks its own display
  down off monotonic `os.clock()` between updates, so digits move once a
  second without a remote fire per second per player.
- Doubles as the event clock: "NEXT GP m:ss" while Waiting, "STARTS m:ss"
  during Countdown, "TIME LEFT m:ss" while Racing.
- **Superseded in part by chunk 82 (2026-08-04):** the remote now sends
  (state, secondsRemaining, **nextRaceStartTime**) — races run on real-world
  :00/:30 marks, so the Waiting text is "NEXT GP 20:30 · 12:34", the mark
  (formatted client-side in the player's own time zone) alongside the
  countdown. The other three phases are unchanged.
- **Bug caught while writing this:** `broadcastState` called `broadcastTimer`
  before it was declared. A `local function` referenced above its declaration
  resolves to nil and `rojo build` does NOT catch it. Reordered.

### Note: Rojo died mid-round (resolved)
The `rojo serve` process died partway through this round, silently — chunks 18
and 19 were clean on disk and `rojo build` passed, but nothing reached Studio,
so the first verification attempt found the timer label simply absent. Worth
remembering as a failure mode: **a clean `rojo build` says nothing about
whether Studio actually has the code.** If a live check reports a brand-new
instance missing, check `http://localhost:34872/api/rojo` before debugging the
code. Restarting `rojo serve` creates a NEW session id, so the Studio plugin
also needs a manual Connect click after that.

## Chunk 15 — SkyRail straight: make the transition possible
- [x] DONE — route is now continuous: solid road -> walkable step flight up
      -> bridges + moving platforms -> step flight down -> solid road. Steps
      rise 1.6 studs each (under Roblox's ~2-stud auto-step, so they're
      walked not jumped). Only the elevated middle is carved underneath.
      Verified live, centreline height profile:
      z12:1 z24:2 z36:5 z48:8 z60:10 z72:10 z96:10 z120:10 z132:6 z144:3
      z156:1 z168:1 — a continuous ramp, no 9-stud step across a void.
- [x] DONE — bridges narrowed to 28% of track width (was 50%). Verified
      off-path at z=90, x=25 falls to the Baseplate at -47, while the
      approach (z=12) and exit (z=168) stay full-width solid road at Y=1.
- [x] DONE — 2 vertical movers mid-span, opposite phases. Verified: 9.6
      studs of vertical travel each.

## Chunk 16 — SkyRail curve (new — was completely bare)
- [x] DONE — new `removeMiddleCurveChords` helper (a Curve's floor is N
      separate `RoadChord_N` parts, not one slab, which is exactly why the
      themes that cut holes had skipped curves entirely). Chords 4 and 5 are
      removed; inner half rebuilt as a solid ledge, outer half carved to a
      drop with a laterally-sliding platform across it.
      Verified live: 19.0 studs of LATERAL travel, 0.0 vertical; inner half
      = rebuilt ledge at Y=1; outer half reads as a real drop to the
      Baseplate whenever the platform isn't covering that spot.

## Chunk 17 — IceFrost + WaterDock curves (were completely bare)
- [x] DONE — IceFrost curve: full-width gapless non-phaseable ice wall
      (40 truss poles). The "half water" exemption only ever applied to the
      straight; there's no water lane on a curve to be the alternative route.
- [x] DONE — WaterDock curve: real water via `removeMiddleCurveChords` +
      the same Air-then-Water fill. Verified live: chord centre AND both
      edges all read Terrain/Water at Y≈0, adjacent chord 3 still solid road.

---

# Round 4 — variety fix + "juice"

## Chunk 20 — exactly 4 distinct themes per build
- [x] DONE — `MIN/MAX_THEME_COUNT` (2..4) replaced with a flat
      `THEME_COUNT = 4`. Verified over 10 fresh generations: every one had 4
      distinct themes and intact pairs (1==2, 3==4, 5==6, 7==8).

## Chunk 21 — don't announce a segment identical to the one before it
- [x] DONE — `announceSegment` compares the entering segment's theme with the
      one just left and returns early if they match, while still MARKING it
      announced (the player has been told about that hazard; leaving it
      unmarked would let it fire later in the lap). Run-start bypasses the
      check via an `isRunStart` flag — on arrival there is no previous
      segment of the player's to be redundant with.
      Verified live over a full lap: 4 notices (segments 1/3/5/7) instead of
      8, one per themed pair.

## Chunk 22 — economy sounds
- [x] DONE. New `Configs/SoundEffects.luau` (ids keyed by MEANING, not by
      asset), `CoreGameLoop/SoundDirector.luau` (server), and
      `UI_And_Visuals/SoundController.luau` (client) + `Network.Track.PlaySound`.
- Split by nature, not by convenience: a skill cast is a world event so the
  Sound is created server-side ON the caster's part (spatialised + replicated
  for free, no remote); a cash-register ding is personal, so it goes over a
  remote and plays flat for that one client only.
- Wired: purchase (skill unlock AND upgrade, plus Robux receipts), GoldGain +
  FanGain (lap reward, Grand Prix payout, Robux grants), FanGain (fan deposit).
- **Verified all 8 asset ids actually LOAD** (`IsLoaded` + real `TimeLength`)
  before trusting them — Roblox audio permissions silently produce a Sound
  that never fires, and every id here is third-party Creator Store audio.
- Verified end to end: buying a skill upgrade produced `Purchase`; completing
  a lap produced `GoldGain` + `FanGain`.
- 3D path verified separately: `SFX_SkillSelf` appeared on the caster's
  HumanoidRootPart, playing, and self-destroyed once finished (1 -> 0).

## Chunk 23 — skill cast sounds
- [x] DONE — `SkillSelf` / `SkillTarget` / `SkillGlobal` / `SkillSwap` fired
      from the three skill managers at the point the cast is confirmed.

## Chunk 24 — gate target-required casts
- [x] DONE — and this was a REAL bug, not just a missing message: the
      cooldown was consumed BEFORE targeting, and `resolveAndApply` then
      silently returned when `findNearestTarget` came back nil. Casting with
      nobody in range cost the full cooldown, did nothing, and said nothing.
      The target check now runs before `CooldownTracker.TryConsume`.
- Verified live with no second player in the server: firing the real
  `FireTargetedSkill` remote produced "NO TARGET IN RANGE!" + the
  `SkillBlocked` sound, and **no `SkillCastResult`** — i.e. the cooldown was
  genuinely not burned.

## Chunk 25 — player state visuals
- [ ] PhaseSelf -> caster goes translucent.
- [ ] Shield -> visible bubble.
- [ ] Duration buffs/debuffs -> a visible marker for the duration.
- [ ] Movement trails.

## Chunk 26 — cast VFX
- [ ] PositionSwap -> ~0.5s purple lightning arc connecting the two players.
- [ ] General cast flourish (bolt / glowing orbs).

---

# Round 5 — HUD size, practice dummies, cast/effect testing

## Chunk 27 — HUD elements look smaller
- [x] DONE, but **the premise was wrong and this is worth knowing**. Nothing
      in the previous round touched `BottomRight`, the Skill1/2/3 buttons,
      their icons, or `CenterAction` — those are still at exactly the
      enlarged values from the earlier "bigger buttons" round
      (`BottomRight` 0.17x0.42 at 0.815/0.34, buttons 0.32 height, icon 0.85).
- The real cause: **every one of them is sized purely by SCALE**, and the
  Studio viewport had shrunk from 1143x573 to 984x384 between sessions.
  0.42 x 384 = 161 instead of 241, so the buttons rendered 51px instead of
  ~77px and the action button 30px instead of ~46px. A window resize, not a
  code change — so there was nothing to revert.
- Fixed properly instead with `UISizeConstraint` pixel floors: 76x76 on each
  skill button, 240x46 on `CenterAction`. Verified live at the 984x384
  viewport: skill button 51 -> 76, icon 43 -> 64, action button 216x30 ->
  240x46. This also makes them immune to the same problem on small screens.

## Chunk 28 — practice dummy noobs
- [x] DONE — new `CoreGameLoop/PracticeDummyService.luau`, `DUMMY_COUNT = 3`
      (set to 0 to disable). Real R6 rigs with proper Motor6D joints, not
      Parts with a Humanoid bolted on, so Roblox's animator drives them and
      anything reasoning about a character sees what it expects. They follow
      the live checkpoint ring as waypoints, so they automatically track
      whatever `TrackGenerator` last built.
- **Bug found on the first live run:** `Humanoid:MoveTo` has no pathfinding,
  so two of three walked into a WaterDock pool and sat there in the Swimming
  state making zero progress. Added two-stage unstick (jump after 2s pinned,
  skip to the next waypoint after 6s). Re-verified: all three now travel
  continuously — 246 / 303 / 362 studs over 30s, spread around the circuit.

## Chunk 31 — skill buttons overlapped / mobile jump corner
- [x] DONE. Chunk 27's 76x76 floor was a REGRESSION: the buttons sit in
      bands 0.33 of the frame apart, so at a 414px viewport the bands were
      57px while the buttons were forced to 76px — a measured 19px overlap.
- First correction (growing the frame to 240px tall) was **wrong for a second
  reason the user caught**: it grew DOWNWARD into the bottom-right corner,
  which on mobile is where Roblox draws its native jump button.
- Final shape: `BottomRight` is now anchored by its BOTTOM edge
  (`AnchorPoint {0,1}`, `Position Y 0.70`) so it grows upward, with floors
  sized to what actually fits — frame 170x186, buttons 58x58.
- Verified at 984x414: buttons 59px each (up from the original 51), 2px gaps,
  no overlap, stack starts at y=48 clear of the top HUD, and **184px (44% of
  screen height) left clear below it for the mobile jump button**.
- Lesson: a pixel floor on a child needs a matching floor on the parent that
  positions it, or the floor just makes children collide.

## Chunk 25-26 — player visuals + cast VFX  **[DONE, WIRED, TESTED]**
Wired and live-verified. Each helper measured individually, then again
through the real cast path:
- **Phase** -> torso transparency 0.65 while phasing, back to 0.00 after.
  Rides the exact same expiry guard as the collision-group revert, so the
  look can't outlast (or end before) the actual pass-through.
- **Shield** -> `ShieldBubble` ForceField ball, 8x8x8, welded, auto-expires.
- **Aura** -> `Highlight` on the character, red for debuff / green for buff.
  Fires ONLY after the effect is actually accepted into the list — every
  early return (unknown effect, immune, cap reached) must not light the
  player up or the aura would advertise a debuff that never landed.
- **Trail** -> `SpeedTrail` on DashSelf / SpeedBoostSelf.
- **Swap arc** -> purple `Beam`, width 1.6, drawn BEFORE the swap so it
  connects where the pair actually are rather than their post-swap spots.
  Textureless on purpose: an untextured Beam renders as a solid emissive
  ribbon and whips like lightning with CurveSize pushed out, which avoids
  depending on a third-party texture that could be moderated (the same
  permissions risk the audio pass had to verify around).
- **Cast burst** -> particle orbs at the caster, colour-coded per cast type.
- All six confirmed to self-clean after expiry (shield/aura/trail/arc all
  gone).

### Known gap (small, deliberate)
`ShowCastBurst` is wired into `tryCast` — the normal player-initiated cast —
but NOT into the three managers' `CastSkillDirect`, which is the separate
"release a carried skill pickup" path. Confirmed live: a `CastSkillDirect`
ShieldSelf produced the bubble but no burst. Not fixed here because it was
found with too little context left to edit AND re-verify, and an unverified
edit is worse than a documented gap.

## Chunk 32 — temporary VFX test scaffolding  **[ADDED, USED, REMOVED]**
- [x] Temporary `IsPracticeDummy` fallback in `findNearestTarget` added,
      used to eyeball the swap arc, then **removed** — grep-confirmed no
      `IsPracticeDummy` / `TEMPORARY` references remain in
      `TargetedSkillManager`.
- [x] **Practice dummy summons removed**: `DUMMY_COUNT` set to 0, so none
      spawn in the live game. Verified live: `dummies spawned = 0`. The
      module is retained (inert, one constant away from re-enabling) as the
      solo-testing rig chunk 29 will need; say the word to delete it outright.

## Chunk 25-26 — ORIGINAL PLAN (superseded by the entry above)
- [x] `CoreGameLoop/VisualEffectsService.luau` written: `SetPhased`,
      `ShowShield`, `ShowEffectAura`, `ShowTrail`, `ShowSwapArc`,
      `ShowCastBurst`. Built server-side rather than over remotes because
      Highlight/Beam/Trail/ParticleEmitter/Transparency all replicate on
      their own — every observer stays in sync for free and an effect can't
      disagree with the server state that caused it.
- [ ] **NOT WIRED to any call site yet, and NOT tested.** Next session:
      - `SelfSkillManager.beginPhase` -> `SetPhased(character, true/false)`
      - ShieldSelf -> `ShowShield`
      - all 3 skill managers -> `ShowCastBurst` (next to the existing
        SoundDirector calls, which are already at exactly the right spots)
      - `EffectStackManager.TryApplyEffect` -> `ShowEffectAura` (buff/debuff)
      - `TargetedSkillManager` PositionSwap -> `ShowSwapArc`
      - Dash/SpeedBoost -> `ShowTrail`

## Chunk 32 — temporary dummy targeting, for VFX testing only
- [ ] Per explicit instruction: in `findNearestTarget`, when
      `Players:GetPlayerFromCharacter` returns nil, fall back to targeting a
      practice dummy **purely so the visuals can be confirmed**, then REMOVE
      the fallback once checked. This is a test scaffold, not chunk 29.

## Chunk 29 — make dummies valid skill targets  **[NOT STARTED — READ THIS]**
Spawning them is not enough, and this is the real work:
- `TargetedSkillManager.findNearestTarget` resolves candidates via
  `Players:GetPlayerFromCharacter`, which returns nil for an NPC. **A dummy
  can never currently be acquired as a target.**
- `EffectStackManager`, `ProfileManager`, `PlayerStateService` and every
  `FireClient` are all Player-keyed, and Roblox gives no way to fabricate a
  Player. So the NPC path has to be explicit, not pretended away.
- Suggested shape: have targeting return the character MODEL (plus an
  optional Player), keep the existing Player path untouched, and give NPCs a
  reduced path — PositionSwap and direct Humanoid WalkSpeed/JumpPower
  changes work fine; profile/remote-dependent effects (Blind, rewards)
  simply don't apply to them.

## Chunk 30 — live test all casts and effects  **[BLOCKED on chunk 29]**
Target-cast skills cannot be meaningfully tested until dummies are
acquirable. Self and Global casts CAN be tested today.

---

# Round 6 — hazard feedback + a dead control-scramble path

## Chunk 33 — falling blocks must cost a life
- [x] **Confirmed the bug live first**: standing inside a landed
      NeonFallingBlock left lives at 3/3. Root cause — the block is
      `CanCollide = true`, so the physics solver shoves a player OUT of it
      the instant they overlap; `ZoneHazardMonitor` asks "is the rootpart
      inside this zone" and the answer is never yes when the 0.5s poll runs.
- [x] Fixed with a separate, larger, non-collidable `NeonBlockZone` welded to
      the block, registered in its place. Exactly the fix `MagmaZone`
      already needed alongside `MagmaPool`, for exactly the same reason.
- [ ] **NOT re-verified live after the fix** — ran out of context. First job
      next session: force NeonCircuit, stand under a landing block, confirm
      lives drop AND the player respawns at their last checkpoint.

## Chunk 34 — climb-wall step spacing / low-wall walls near checkpoints
- [x] DONE — jump platforms fixed at 4 on tall walls (was a max-rise
      calculation that produced 6, reading as a cramped ladder; 4 gives a
      6-stud rise, inside Roblox's ~7-stud jump, with visible air between).
      Verified live: straight = 4.
- [x] DONE — low (curve) walls get ONE platform per side. Verified live: 2
      total across the two sides.
- [x] DONE — **real bug fixed**: a curve's entry/exit CFrames are exactly
      where `TrackGenerator` puts its checkpoint triggers, so HillMud was
      building truss walls ON the checkpoint planes — a player respawning
      there materialised inside the wall. Walls now offset 34 studs along
      the arc. Verified live: nearest wall-to-checkpoint distance went from
      ~0 to 34.8 studs.

## Chunk 36 — negative-WalkSpeed inversion: TRIED, DOESN'T WORK, REVERTED
The idea was sound and would have been elegant: Roblox drives a character
along `MoveDirection * WalkSpeed`, so flipping the sign should reverse every
input device at once (keyboard AND mobile thumbstick, since both resolve to
MoveDirection) with no client input interception at all.
- **It does not work. Roblox CLAMPS `Humanoid.WalkSpeed` to a minimum of 0.**
  Measured live: assigning -16 read back as exactly **0.0**. The player
  freezes instead of reversing — strictly worse than the effect doing
  nothing, because it silently becomes a stun.
- Reverted deliberately, with the finding recorded in `MovementModifier`
  next to the speed write so nobody re-attempts it.
- Re-verified after reverting that Reverse Control is **inert, not frozen**:
  mode reports "Invert" while WalkSpeed stays 16.0.
- The workable approach stays client-side: re-issue `Humanoid:Move()` with a
  negated MoveDirection each frame while scrambled.

## Chunk 37 — negative buffs, live-tested end to end  **[DONE]**
All measured through the real `EffectStackManager` on the real character:
- **SlowTarget** 16.0 -> 6.4 (magnitude 0.4), debuff aura present, back to
  16.0 on expiry.
- **WeightTarget** JumpPower 50.0 -> 15.0 (magnitude 0.3).
- **ShockTarget** stunned = true, WalkSpeed 0.0 AND JumpPower 0.0, both
  fully restored on expiry.
- **ReverseControlTarget** applies and reports mode "Invert" — but has no
  movement effect (see chunk 36).

### Bug found while testing — desert wind swallows effect speed changes
`recomputeForPlayer` early-returns while `walkSpeedOverrideUntil` is active.
That was fine when the desert wind was an occasional 2.5s gust, but the wind
rework made it a CONSTANT override, so **any player standing on a Desert
segment has every effect-driven WalkSpeed change silently ignored** — slows
included. Observed directly: baseline read 9.6 (the wind's headwind value)
and a cast slow changed nothing. Not fixed — the real fix is for the wind to
be a multiplier participating in the recompute rather than an exclusive
override, which is a bigger change than there was context left for.

## Chunk 35 — control scramble is a DEAD PATH  **[ROOT CAUSE CONFIRMED]**
Answering "have we tried casting a negative buff to check controls actually
invert?" — **no, and it would have failed.**
- `SkillEffects` declares `ControlScrambleMode = "Invert"`
  (ReverseControlTarget) and `"Randomize"` (ScrambleGlobal).
- `EffectStackManager.IsControlsScrambled` exists to report it and has
  **zero callers** — grep-confirmed across all of `src/`.
- The only control-scramble mode ever actually wired is `"Blind"`, and even
  that bypasses this function entirely via its own dedicated remote
  (`ApplyBlindEffect` -> `BlindEffectController`).
- So ReverseControlTarget and ScrambleGlobal currently do NOTHING to input.
  Same class of dead config path that Blind itself was before it was fixed.
- Fix shape: a client controller that, while the server says this player is
  scrambled, overrides movement — for keyboard, negate the
  `Humanoid.MoveDirection` derived from input; for mobile/thumbstick the
  same negation applies since both funnel through the same MoveDirection.
  Needs a server->client remote carrying (mode, duration), mirroring how
  `ApplyBlindEffect` already does it.

---

# Round 7 — steps, rod speed, control scramble, and a full effects pass

User request for this round, verbatim:
1. "wall with steps fixed, having a step directly above player causes
   bouncing or being block by the step above it"
2. "speed of rods is too fast on the lava team, slow them down a bit"
3. "live testing of negative buffs on player especially reverse and scramble
   control"
4. "review effects, sound and vfx — there should be effect on every
   significant action while on race like crossing a checkpoint, finishing a
   lap, depositing fans, casting spells, falling blocks etc. Full review and
   addition of effects only, no change in game play aside from maybe adding
   0.5 second cast time before swap, or an actual lightning or magical energy
   ball representing whatever is casted to arrive the player."
5. "update one chunk at a time and save context for future sessions"

## Chunk 38 — jump-platform steps: no platform directly above another
- [x] DONE and live-verified. **Root cause: the ±9 alternating zig-zag from
      chunk 6 was itself the bug the user was reporting.** Alternating repeats
      every 2 steps, so platform 3 landed at the SAME lateral offset as
      platform 1, and the only other separation was `approach`, which differed
      by ~3 studs between them — on an 8x8 platform, that is a heavy overlap.
      Platform 1 therefore had a ceiling 12 studs above its take-off point:
      the original "jump into the underside of the next step" bug, moved two
      steps up the wall. Consecutive platforms also asked for an 18-stud
      lateral hop with a 6-stud rise, which no Roblox jump arc makes.
- [x] Replaced with a MONOTONIC staircase — each step advances the same
      direction across the wall, so a repeated offset is arithmetically
      impossible — at a constant approach z, 10-stud lateral advance (8-stud
      platforms, so a 2-stud gap), and a count derived from
      `JUMP_PLATFORM_MAX_RISE = 5` instead of a fixed 4.
- [x] `LOW_WALL_PLATFORM_COUNT = 1` override deleted: on a 15-stud curve wall
      its single platform sat at half wall height, i.e. a 7.5-stud first hop
      straight off the ground, right at the limit of Roblox's jump.
- Verified live (HillMud forced on all 8 segments):
  - straight (30-stud wall): 5 platforms, x = -20/-10/0/10/20, y =
    5/10/15/20/25, constant z. Max rise between steps 5.00, first step 4.00
    above the road.
  - curve (15-stud wall): 2 platforms per wall, y = 5/10, 4 per piece.
  - **Ceiling proof: raycast 14 studs straight up out of all 36 platforms —
    0 hit another platform.** Pairwise XZ-overlap check also NONE everywhere.

## Chunk 39 — Volcanic sweeper rods too fast
- [x] DONE and live-verified. `SWEEPER_TRAVEL_SECONDS` 3 -> 6. The sweep span
      is `StraightLength * 0.8` = 144 studs, so that constant is what actually
      sets the speed: 48 studs/s -> 24. **Measured live: 190.7 studs in 8.0s =
      23.8 studs/sec** (player WalkSpeed is 16). Still faster than a runner —
      it does still catch you — but slow enough to read and time.

## Chunk 40 — control scramble: implement Invert + Randomize  **[DONE]**
- [x] New client `Controllers/ControlScrambleController.luau`.
- [x] **One remote for all three modes, fired from ONE place.** The old
      `ApplyBlindEffect` is replaced by `Network.Combat.ApplyControlEffect`
      (mode, durationSeconds), fired from `EffectStackManager.TryApplyEffect`
      right next to `ShowEffectAura` — the single point where an effect is
      known to have genuinely landed. The Blind-only special case that used to
      sit in `TargetedSkillManager.resolveAndApply` is deleted. **That
      placement was the actual bug**: ScrambleGlobal is a Global cast, so it
      went through `GlobalSkillStateMachine` and never touched the manager
      that held the only client notification, i.e. it could not have reached a
      client no matter what the client did with it.
      `BlindEffectController` now listens on the same remote and filters for
      `mode == "Blind"`.
- [x] **How the input override works.** PlayerModule binds its control update
      to RenderStep at `Enum.RenderPriority.Input`; a binding at
      `Enum.RenderPriority.Character` therefore runs right after it, every
      frame, by which point the raw input (keyboard / gamepad / mobile
      thumbstick — all of them) has already been resolved into a world-space
      `Humanoid.MoveDirection`. Read it, transform it, re-issue
      `Humanoid:Move(transformed, false)`.
      **It cannot oscillate**, which is the obvious worry: PlayerModule
      rewrites MoveDirection from raw input at the start of every frame, so
      the value this binding reads is always the untransformed one.
      Deliberately NOT `PlayerModule:GetControls():GetMoveVector()` — internal
      API whose camera-relative convention has changed between versions.
- [x] Randomize rotates input by a random quarter turn, re-rolled every 1.5s,
      never 0 (a 0 would read as the debuff having stopped working).
- **Live-verified:**
  - **Invert, both axes**: W (normally 0° off camera-forward) -> 180°, D
    (normally 270°) -> 90°. Exactly reversed, same speed (24.0 studs in both
    the clean and inverted runs), stable across 90 consecutive frames.
  - **Randomize**: holding ONLY W for 6s, the per-frame yaw offset was
    90°/180°/270° in turn (50%/25%/25% of frames) — i.e. it re-rolled — and
    0° never occurred.
  - **Expiry**: after a 3s Invert ran out, 8 continuous seconds of 0°.
- [x] **Gap found and fixed while testing: Dispel didn't cancel it.** The
      scramble's behaviour lives on the client and runs off the client's own
      clock, so removing the entry from the server list left inputs remapped
      for the rest of the original duration — a Dispel would visibly fail to
      cure Reverse Control. Same hole in the cap+1 immunity sweep. Both now
      call a `notifyControlEffectCleared` helper that fires the same remote
      with duration 0, the agreed cancel signal (both client controllers treat
      any non-positive duration as "clear now").
      Verified live: a 300-second Invert, Dispelled at ~22s — inverted through
      t=13s, plain 0° from t=14s to t=30s, with 280s of nominal duration left.

## Chunk 41 — live-test negative buffs  **[DONE]**
All through the real `EffectStackManager` on the real character, each
measured at baseline / active / after expiry:
- **SlowTarget** (0.40): WalkSpeed 16.0 -> 6.4 -> 16.0
- **SlowGlobal** (0.50): WalkSpeed 16.0 -> 8.0 -> 16.0
- **WeightTarget** (0.30): JumpPower 50.0 -> 15.0 -> 50.0
- **ShockTarget**: stunned=true, WalkSpeed AND JumpPower both 0.0, both
  fully restored
- **BlindTarget**: mode reports "Blind" and the `SkillBlindBlur` BlurEffect
  was observed appearing in Lighting for its window and gone after
- **ReverseControlTarget / ScrambleGlobal**: see chunk 40 — these now
  genuinely move the character in the wrong direction.

### Still open from chunk 37, NOT fixed this round
`MovementModifier.recomputeForPlayer` early-returns while
`walkSpeedOverrideUntil` is active, and the desert wind rework made that
override CONSTANT — so **every effect-driven WalkSpeed change is silently
ignored for any player standing on a Desert segment**, slows included. The
sweep above was run in the infield, away from Desert, so it does not cover
this. Real fix is for the wind to be a multiplier participating in the
recompute rather than an exclusive override.

## Chunk 42 — audit effect/sound/VFX coverage  **[DONE — this is the gap list]**

Every call site of `SoundDirector.*` and `VisualEffectsService.*` in `src/`,
against every action a player can take or have happen to them in a race.

**Already covered (do not re-do):**
| Action | Sound | VFX | Notice |
|---|---|---|---|
| Cast Self (own skill) | `SkillSelf` | CastBurst, + Shield bubble / Trail / Phase | yes |
| Cast Target (own skill) | `SkillTarget` / `SkillSwap` | CastBurst, SwapArc | yes (to target) |
| Cast Global (own skill) | `SkillGlobal` | CastBurst | yes |
| Cast with no target in range | `SkillBlocked` | — | yes |
| Buff/debuff accepted | — | Highlight aura | — |
| Lap complete | `GoldGain`+`FanGain` | — | yes |
| Fan deposit | `FanGain` | — | yes |
| Grand Prix payout | `GoldGain`+`FanGain` | — | yes |
| Shop / Robux purchase | `Purchase` | — | yes |
| Falling block wind-up | — | red telegraph ring | — |

**Missing — nothing at all fires today:**
1. **Crossing a checkpoint (1-7).** `CheckpointValidator.checkPlayer` sets the
   attribute and returns. Only checkpoint 8 (the lap) makes any noise, and
   only the first segment of a themed pair shows a notice. Seven of every
   eight checkpoints are completely silent.
2. **Losing a life.** `ArcadeManager.HandleTrackViolation` decrements, drops
   the carry and respawns — no sound, no VFX, not even a notification. This
   is the single most significant negative event in the game.
3. **Respawning at a checkpoint.**
4. **Falling block IMPACT.** The telegraph ring is there; the landing itself
   is silent, as is standing in the block's kill zone.
5. **Magma / lava contact** (`ZoneHazardMonitor`'s other registrant).
6. **Picking up a Fan Payload, and picking up a skill.**
7. **Dropping fans** (notice only).
8. **Grand Prix countdown ticks and the GO.**
9. **Casting a CARRIED skill pickup** — `SelfSkillManager.CastSkillDirect` and
   `TargetedSkillManager.CastSkillDirect` fire neither the sound nor the
   burst. **This is wider than the gap recorded last round**, which only
   mentioned `ShowCastBurst`. `GlobalSkillStateMachine` is the exception and
   does both, because its sound/VFX live in the shared `activate` rather than
   in `tryActivate`. The fix is to move the other two managers' sound+burst
   into their shared `resolveAndApply` for the same reason.
10. **The cast itself is instantaneous** — there is no wind-up and no
    travelling projectile, which is what chunk 45 addresses.

## Chunks 43-46 — the effects pass  **[ALL DONE, live-verified]**

**10 new sound ids added to `Configs/SoundEffects.luau`, all verified to
actually load first** (`IsLoaded` + a real non-zero `TimeLength`) before being
trusted — Roblox audio permissions otherwise produce a Sound that silently
never fires, so this check is not optional for third-party Creator Store
audio. Measured lengths: BlockImpact 1.88s, CastCharge 2.38s,
CheckpointPassed 1.00s, CountdownGo 2.05s, CountdownTick 1.02s, HazardBurn
3.46s, LifeLost 0.67s, PickupItem 1.50s, ProjectileHit 2.28s, Respawn 2.73s.

**6 new VFX helpers in `VisualEffectsService`**, all built on one shared
`emitBurstAt(position, colour, count, speed, upwardOnly)`: ShowCheckpointBurst,
ShowLapBurst, ShowRewardBurst, ShowLifeLostBurst, ShowRespawnBurst,
ShowImpactBurst. Race progress gets its OWN hue (cyan / gold) deliberately
separate from the buff green — a green checkpoint flare would read as "you
gained a buff", and the two happen close enough together mid-race to be
genuinely confusable. Life loss is red and omnidirectional, i.e. the visual
opposite of the upward progress fountains.

### Chunk 43 — race progress
- Checkpoints 1-7: `CheckpointPassed` + cyan fountain. **Seven of every eight
  checkpoints previously passed in complete silence** — only number 8 (the
  lap) made any noise. Checkpoint 8 deliberately fires the bigger gold lap
  burst INSTEAD, not both.
- Lap: gold burst added alongside the existing GoldGain/FanGain.
- Fan deposit, Fan pickup, and skill pickup: `PickupItem` + gold burst. The
  skill pickup is the important one — it is granted automatically with no
  button press, so previously the only sign it had happened was the action
  button quietly changing mode.
- Grand Prix: `CountdownTick` for the last 3 seconds, `CountdownGo` on the
  Racing transition. The tick loop self-terminates on a state change rather
  than running blind, so beeps can't arrive after the lights go green.

### Chunk 44 — hazards
- **Life lost**: `LifeLost` + red burst + a "LIFE LOST! n LEFT" notice, fired
  from `ArcadeManager.HandleTrackViolation` — the one place every cause
  (fall-out, magma, a landed block) converges, so no route is missed and none
  double-fires. Burst goes BEFORE the respawn teleport so it appears where
  the player actually died.
- **Respawn**: `Respawn` + cyan burst in `respawnAtCheckpoint`.
- **Zone hazards**: `HazardBurn` 3D on the zone part itself, in
  `ZoneHazardMonitor` — this is what distinguishes "the magma got me" from
  "I fell off", which `HandleTrackViolation` can't tell apart from inside.
- **Falling blocks**: `BlockImpact` + impact burst on `block.Touched:Once`.
  Touched rather than a fixed delay because fall time depends on what it
  lands on; `:Once` so a bouncing block only crashes once.

### Chunk 45 — cast wind-up + travelling projectile
The one deliberate gameplay change this round, and the one the user
sanctioned. A Target cast now: charge-up particles + `CastCharge` on the
caster -> 0.5s wind-up -> a homing neon orb with a trail flies to the target
-> `ProjectileHit` at the target -> only THEN the effect/swap applies.
- The orb **homes**: it re-reads the target's current position every frame. A
  racer moves 16 studs/second, so a straight line to where they stood at
  launch would visibly miss on any cast at range, which reads as the
  projectile having nothing to do with the effect.
- Anchored, `CanCollide`/`CanQuery`/`CanTouch` all false — it must never
  shove anyone, which would be a real gameplay change rather than a visual.
- The cooldown is still consumed up front, so the wind-up can't hold a cast
  open. Everything is re-resolved after each yield: 0.5s is plenty of time
  for either character to be respawned or the target to leave.

### Chunk 46 — the CastSkillDirect gap, which was WIDER than recorded
Last round documented this as "`ShowCastBurst` isn't wired into
`CastSkillDirect`". It was actually the sound too, in **both**
`SelfSkillManager` and `TargetedSkillManager` — releasing a carried skill
pickup was almost entirely silent. `GlobalSkillStateMachine` never had the
problem because its sound/VFX already lived in its shared `activate` rather
than in `tryActivate`; the fix is to give the other two the same shape, so
both now fire from `resolveAndApply`.
Verified live: `CastSkillDirect(ShieldSelf)` now gives `SFX_SkillSelf` on the
character AND the CastBurst attachment AND the ShieldBubble (before the fix,
same test gave the bubble only), and the Sound self-destroys within 4s.

### Live verification of the whole pass
- All 6 burst helpers: each created its anchor with a live ParticleEmitter,
  and **0 EffectBurstAnchor instances leaked** — count returns to the
  hazard-driven steady state, not a growing number.
- `ShowChargeUp`: attachment present with Rate 90 during, gone after.
- `ShowCastProjectile`: 0.55s over 120 studs, 11 sampled frames, moved 116.7
  studs, ended 3.3 studs from the target, orb gone after arrival.
- Real gameplay run (EnterTrack, real checkpoint ring, real violation path) —
  client received, in order: `PickupItem`, `CheckpointPassed`, `LifeLost`,
  `Respawn`, `PickupItem`, plus the "LIFE LOST! 2 LEFT" notice. Lives 3 -> 2.
- Grand Prix countdown via the real join remote + `StartRaceNow`:
  `CountdownTick` at t+0, +1.0, +1.9, then `CountdownGo` at +3.2.
- **NOT live-tested: a real Target cast end to end** (wind-up -> orb -> effect
  landing on a victim). It needs a genuine second Player, which a solo Studio
  session can't provide — the same limit that blocks last-man-standing. Each
  piece was verified individually instead.

---

# Round 8 — desert wind fix + daily quests/achievements

User request: fix the outstanding desert-wind bug, then add categorized daily
quests/achievements (playtime up to 9 gold rewards, laps in 5 fan tiers, a
daily login ladder, and a special "invite 5" fans task), put the quest menu
below ROBUX SHOP with Grand Prix moved down, add a separate special-task
button, track rewards properly, and summarise the DataStore surface.
Mid-round corrections: special-task button to the TOP RIGHT and relabelled
**"ADD FANS"**; and **use the daily cycle in reward-progress tracking to
avoid duplicated rewards**.

## Chunk 47 — desert wind swallowed every effect speed change  **[DONE]**
- [x] Root cause was an API mismatch, not arithmetic. The wind called
      `MovementModifier.SetWalkSpeedOverride`, copying DashSelf — but an
      override SUPPRESSES the whole effect-driven recompute for its duration.
      Correct for Dash (a forced run lasting a fraction of a second), wrong
      for weather: once the wind became constant, its override was
      permanently active for anyone on a Desert segment and **every buff and
      debuff there was silently ignored**.
- [x] New `MovementModifier.SetEnvironmentSpeedMultiplier(player, mult, dur)`
      — a multiplier that participates in the recompute. Re-applying replaces
      rather than compounds, because the wind re-applies on a 1s cycle and
      compounding would accelerate a headwind toward zero. `DesertWindService`
      now passes 1.6 / 0.6 factors instead of absolute 16*1.6 / 16*0.6 speeds.
- [x] Also deleted a stale comment block in `MovementModifier` claiming
      control scramble was implemented there as a negative WalkSpeed — it
      contradicted the note directly above it and is now client-side.
- **Live-verified, every value exact:** baseline 16.00; headwind 9.60;
  **headwind + slow 3.84** (the bug: used to stay 9.60); slow dispelled 9.60;
  tailwind 25.60; tailwind + slow 10.24; wind expired 16.00; a Dash-style
  absolute override still wins outright at 42.00 and reverts to 16.00.

## Chunks 48-51 — daily quests / achievements  **[DONE]**

**Config** — new `Configs/QuestDefinitions.luau`, four ladders:
Playtime (9 gold tiers, 1..60 min), Laps (5 fan tiers, 1..20 laps),
DailyLogin (7 gold tiers, streak days), Invite (5 fan tiers, lifetime).
Tiers assert ascending requirements on first require — a descending pair
would pay a later tier for less progress, i.e. a live economy exploit
produced by a config typo.

**Claim state is a ladder, not a set of flags.** One number per category
(highest tier claimed) makes "paid exactly once" a comparison rather than
bookkeeping: only `claimed + 1` is claimable, and only once progress reaches
its requirement. No out-of-order claims, no double claims, no gaps.

**The daily cycle is DATE-DERIVED** (the mid-round correction). Each
category's claim count carries a `ClaimedDayByCategory` stamp, and for a
`ResetsDaily` category the count is believed **only when the stamp is
today**. So the ladder re-opens by the calendar, not by a reset pass having
run: a reset that never fired cannot leave yesterday's claims blocking today,
and one that fired twice cannot re-open a ladder already paid today. The
periodic loop now only zeroes progress counters and pushes UI — nothing about
"has this been paid" depends on it.

**Server-authoritative claims.** The client sends a category id and nothing
else — no tier, amount or currency. `QuestService` reads those from the
config itself, so a tampered client can only ask for what it already earned.

**Reward tracking** — `LifetimeQuestGold` / `LifetimeQuestFans` audit totals
are written in the same function as the payout, so "did quests pay what they
should have" is answerable from the save alone.

**Progress sources** — playtime tick loop; `CheckpointValidator.grantLapReward`
calls `QuestService.RecordLap` beside the existing `TotalLapsCompleted += 1`
(same fact, different lifetime, recorded at the same moment); login streak
computed on join; invites from `GetJoinData().ReferredByPlayerId`, deduped by
the joining player's user id so two accounts can't farm the ladder.
**Known limit, deliberate:** an inviter is credited only while still in the
server — crediting an absent one needs a cross-session store this ladder does
not justify yet.

**UI** — `QuestButton` (green, with a red "!" badge) sits directly under
ROBUX SHOP; JOIN GRAND PRIX and its timer moved down to LayoutOrder 5/6.
`SpecialTaskButton` — **"ADD FANS", top right at x = 0.72**, which is exactly
where `StandingsPanel` is anchored, so the two take turns rather than
overlapping; it opens the same panel filtered to the Invite ladder alone.

### Live verification
- Reconcile added `Quests` to the existing save; login streak and playtime
  accrual were already running on inspection.
- 5 real `ClaimQuestTier` fires (2 legitimate, 2 unearned, 1 bogus id):
  Gold 1000 -> **1150** (25+50 doubled by the DoubleFans pass),
  TotalFans unchanged at 1000, `LifetimeQuestGold` = **150** (matches),
  Playtime claimed = **2, not 3** — the unearned tier was refused with
  "NOT THERE YET!", the bogus id was silently ignored.
- `RecordLap` x3 -> `LapsToday` 3, and paid nothing on its own.
- **Daily rollover through the real 60s loop**: daily progress and claims
  wiped; Invite (lifetime) and DailyLogin (streak) counts untouched.
- **Date-derived cycle, the decisive test**: ageing ONLY the `Laps` day stamp
  by one day — no reset pass, no progress change — re-opened the ladder at
  tier 1 and a real claim paid 40 fans, while an `Invite` ladder with a
  30-day-stale stamp did **not** re-open (claim was a silent no-op).
- UI: badge logic correct (QUESTS badge on with a claimable tier, ADD FANS
  badge off with none); panel renders LOCKED/CLAIM/progress bars per
  category; ADD FANS opens titled "ADD FANS" showing only `Quest_Invite`.
- **ADD FANS hidden across a real Grand Prix**: 12 samples over 24s spanning
  Countdown and Racing, `addFans=false standings=true` throughout, both at
  x = 708.48.
- **UI position bug caught twice:** `MainHUD` sets `IgnoreGuiInset = true`,
  so a Y offset of 46 rendered at AbsolutePosition Y = **-12**, under
  Roblox's own topbar. Offset is now 76 (AbsolutePosition Y = 18).

## Chunk 52 — DataStore summary  **[DONE]**
Written up in `PROJECT_STATE.md` under "Persistence surface". Headline: one
store (`PlayerData_v1`, ProfileStore, session-locked, keyed by UserId);
gameplay code never writes to it; ProfileStore issues one `UpdateAsync` on
join, one per profile every **300s**, and one on leave — about **8 writes/min
on a 40-player server against a ~460/min budget**.

---

# Round 9 — leaderboards, hub build-out, prize sharing

User request: flatten the invite reward to 100 fans each up to 500; share a
Grand Prix's unclaimed prize among everyone still standing; four top-ten
stadium leaderboards facing each other near the track edge, on climbable
truss, double-sided, with player avatars; amenities inside the commercial
center; a blimp; and a records board on each fan box pod.

## Chunk 53 — invite reward  **[DONE]**
- [x] Flat 100 fans per invite × 5 = 500 (was an escalating
      100/200/350/550/1000 ladder). A flat rate because the reward is per
      INVITE, not for reaching a milestone — the second friend is worth the
      same to the game as the first.

## Chunk 54 — Grand Prix unclaimed prize sharing  **[DONE]**
- [x] The finisher ladder is 5 deep, but the race normally ends on the
      5-minute limit with nobody having driven the full 2 laps, so most of
      the prize pool used to simply evaporate. Now the unclaimed remainder is
      split **evenly** among everyone still on the field — never eliminated,
      never finished.
- [x] Evenly rather than ranked on purpose: this pool exists precisely
      because the race produced no finishing order, so ranking it by
      checkpoint progress would be dressing a tie up as a result.
- **Live-verified on two real 5-minute races that timed out with 0 finishers
  and 1 racer still standing** (lives 3/3, 0 laps driven):
  `Gold +3300, Fans +1650` both times — exactly the predicted
  (1350 + 300) x 2 gold and (675 + 150) x 2 fans, i.e. the whole unclaimed
  finisher pool plus survivor place 1, doubled by the DoubleFans pass.

## Chunk 55 — fastest lap + leaderboard data layer  **[DONE]**
- [x] `BestLapTimeMs` on the profile. Milliseconds because OrderedDataStore
      only takes integers and 87.42s must not become 87.
- [x] Timing runs checkpoint 1 -> checkpoint 8. Not from track entry: entry
      drops you on the start line, but you might stand there, be teleported
      by a Grand Prix start, or join mid-lap. Cleared on leaving the track,
      so a player who wandered off for ten minutes can't post a ten-minute
      lap. Sub-1s "laps" are rejected outright — a nonsense row on the
      fastest-lap board is the one thing unfixable from inside the game.
- [x] `LeaderboardManager` rewritten from its stub into four
      OrderedDataStores. Writes only when a value actually moved, on a 120s
      cycle plus on leave; reads once per category per 60s, cached
      server-wide. Names cached per UserId **including failures**, or a
      deleted account would be re-queried forever.
- **Live-verified:** one full checkpoint ring recorded
      **BestLapTimeMs = 3932 (3.93s)** against a 3.40s wall clock (the delta
      is the 0.5s validator poll), attribute synced, laps 137 -> 138, and a
      deliberately slower second lap left the record **unchanged**.

## Chunks 56-57 — the four stadium boards  **[DONE]**
- [x] Placed at radius 128 — outside the 104-stud hub disc, ~16 studs shy of
      the track's inner edge at 144 — one per cardinal direction, each
      rotated to face the hub centre. **Opposite boards therefore face each
      other exactly (measured look-vector dot = -1.00)**, which falls out of
      the geometry rather than needing per-board angles.
- [x] 86 x 38 studs, screen bottom at 26 studs up, on four climbable
      TrussParts each, with a catwalk and railing at the top of the climb.
- [x] A SurfaceGui on the Front AND Back face, filled in the same pass.
- [x] Rows carry rank, `rbxthumb` avatar headshot, name and value; empty
      places stay visible so the board reads "10 places, 1 taken" rather than
      looking broken.
- **Live-verified end to end through the real DataStore path**: published a
  player's four values -> `GetSortedAsync` -> cache -> both faces. Gold board
  showed `"aphophys" / "91,500 gold"`, BestLap board `"42.317s"`, identical
  on Front and Back, avatar URLs correct.

## Chunk 58 — commercial center amenities  **[DONE]**
- [x] Rubber jogging track (64 chords + lane stripes), 10 benches facing
      inward, 4 banks of 5 raked spectator tiers with alternating seat
      colours, and a playground (sand pit, slide tower, swings, truss
      climbing frame).
- [x] A build-time **assertion** that nothing lands within 22 studs of the
      hub centre — spawning inside a bench gets reported as a teleport bug,
      not as furniture.
- **Bug caught on the first live look:** the slide chute sloped UPWARD and
  started in mid-air. Rotating about +X by a POSITIVE angle tilts the +Z end
  DOWN (right-hand rule: +Z -> -Y) and the first version used a negative one.
  Chute geometry is now DERIVED from the deck (rise = deck height, run
  chosen, length and pitch computed) instead of eyeballed, so it meets the
  deck at one end and the sand at the other by construction.

## Chunk 59 — blimp  **[DONE]**
- [x] Built from parts, not an inserted free model — a Creator Store model is
      one moderation action away from vanishing, the same risk the audio pass
      had to verify around.
- [x] Anchored and re-pivoted every Heartbeat rather than physics-driven:
      nothing about it needs to be physical, and an unanchored version would
      need constraints, could be shoved, and would drift.
- **Live-measured:** 16.0 studs/s along a 306-stud orbit (track outer edge is
  216) at altitude 168, bobbing 8.1 studs.

## Chunk 60 — fan box records board  **[DONE]**
- [x] Attached lazily when a pod is claimed and re-attached on demand,
      because `FanBoxGenerator.SwapPodTier` rebuilds a pod's crowd mesh on
      every fan-tier graduation.
- [x] Reads Player **attributes**, which `SyncAttributes` already mirrors, so
      it updates from a signal already firing rather than becoming a second
      source of truth beside the crowd standing next to it.
- [x] The slot manager now listens to four attributes, not one — and holds a
      LIST of connections, since overwriting a single stored connection would
      have silently leaked the other three.
- **Live-verified:** `🌟 48,210 fans | 💰 91,500 gold | 🏁 137 laps |
  ⏱ best lap 42.317s`, identical on both faces, with the avatar URL set.

---

# Round 10 — board placement, climbing, fan box board, vendor stands

## Chunk 62-63 — the boards were inside the boundary ring  **[DONE]**
- [x] **Root cause of "climbing the straight-side boards teleports you back":**
      `TrackBoundaryMonitor.ON_TRACK_MARGIN` is SegmentWidth/2 +
      BarrierThickness + 10 = **49 studs from the track CENTERLINE**, and an
      InLobby player inside it is returned to the Hub. The oval is not a
      circle, so that ring sits at a very different radius depending on the
      direction — measured live from the same point cloud the monitor builds:

      | direction | centerline distance at r=128 | max safe radius |
      |---|---|---|
      | toward a STRAIGHT (±X) | 54 | **133** |
      | toward a CURVE end (±Z) | 180 | **260** |

      All four boards were at r=128, and the catwalk+railing reached r=135 —
      past the straights' 133 limit. That is what was bouncing players.
- [x] Radius is now chosen PER DIRECTION: straights **112**, curves **190**.
      Verified: worst clearance across every board part went 45 -> **61** on
      the straight pair, and is 128 on the curve pair. All SAFE.
- [x] The r=128 ring the curve pair vacated is where the vendor stands went.

## Chunk 64 — support truss + a climb that actually works  **[DONE]**
Three separate measured failures, each fixed:
- [x] **"Floating"** — a single leg pair at ±34 on an 86-wide board left the
      outer thirds unsupported. Now 4 leg columns (±16, ±40) = 8 truss.
- [x] **A single 2x2 pole is not climbable** — measured live: the character
      slid 16 studs sideways along it, gained 0 height, never entered
      Climbing. Roblox's auto-climb needs a face broad enough to stay in
      contact with, which is why the existing climb walls are rows of
      touching poles. Each tower is now a 4-pole, 8-stud-wide ladder.
      **After that change: 21.8 studs climbed in 9s, `Climbing` state
      confirmed.**
- [x] **Two rows of poles wedge the character** — a 2-stud gap between rows
      dropped the climb to 4.5 studs in 14s. One flat face only. Depth is not
      what makes a ladder climbable; width is.
- [x] **The ladder ran through the deck** — the climb plateaued dead at
      Y = 26.5 with 7 studs of ladder still above, because the climber's head
      was against the catwalk underside. Per the user's suggestion, the ledge
      is now built as **3 spans with a HOLE cut over each ladder**, derived
      from the ladder positions so they can never drift apart.
- [x] **The ladder was also pinching against the screen** — at the deck's
      depth centre it sat ~3 studs from the screen face, and the screen
      starts at exactly the deck height; the climb plateaued at Y = 27.0 and
      would not move however long W was held. Moved to the deck's outer
      depth edge: **5 studs of clear air in front of the board**, ladder top
      at Y = 38, i.e. **9.5 studs above the ledge**, so the last move is a
      step down. Verified: 8 poles, 3 deck spans, 2 holes, and every pole
      confirmed to sit in a hole rather than under a span.
- **NOT confirmed by a scripted climb: the final step from ladder to ledge.**
  Scripted input proved unreliable here — `W` is CAMERA-relative, and the
  PlayerModule reclaims a Scriptable camera, so two runs walked the character
  sideways past the ladder instead of into it. The geometry is measured and
  correct and the climb itself is confirmed (22 studs, `Climbing` state);
  the last 1.5 studs wants a human hand on the keyboard.

## Chunk 65 — fan box records board  **[DONE]**
- [x] **Why it faced sideways:** it was built off the pod's own
      `OriginCFrame` rotation, and that CFrame runs ALONG the track —
      measured live, its LookVector dots only 0.55 with the direction to the
      stadium centre while its RightVector dots 0.83. Now oriented with
      `CFrame.lookAt` at the centre: **dot = 1.00**.
- [x] Bigger: **30 x 16** (was 12 x 7).
- [x] Placed from the pod's ACTUAL bounding box (its height depends on which
      crowd tier is swapped in, so a fixed height would be wrong for most):
      **2.0 studs clear above the crowd's top row, 16.4 studs behind the
      stand's centre** — i.e. behind the topmost row, as asked.

## Chunk 66 — vendor stands  **[DONE]**
- [x] Ice cream, hot dog, balloon and flower stands at radius ~124, in pairs
      flanking each curve direction — the ring the leaderboards vacated. The
      straight directions are left clear because that pair moved INWARD to
      112 and would collide.
- [x] Each has a counter, a striped awning, a double-sided sign and a
      per-type topper (giant cone / parasol / balloon bunch / flower boxes).
- [x] **Built from parts, not inserted Creator Store models.** Free models do
      exist (searched), but this whole world is regenerated from code on every
      server start, so an inserted model sits outside Rojo's control, does not
      survive a fresh place build, and carries the same moderation risk the
      audio pass and the blimp already had to work around. Easy to swap later.

---

# Round 11 — hub floor, lava, checkpoint fans, fan income

## Chunk 68 — "still floating" was a height bug, not a support bug  **[DONE]**
- [x] The structures were placed at the hub floor's TOP FACE (a hard-coded
      `hubCFrame.Y + 2`) but stood at radii 112-190, OUTSIDE the 104-stud
      disc — where the real ground is terrain at Y ~ 0. So they hovered
      exactly 2 studs up. Adding more truss could never have fixed it.
- [x] `HUB_RADIUS` 104 -> **130** (safety margin 40 -> 14). The original 40
      was set because a spinning HazardBar at a SEGMENT midpoint reached into
      the hub — and segment midpoints are on the road, 36+ studs beyond this
      edge, so it does not apply to the disc's own rim.
- [x] `HubGenerator` now EXPORTS `HubRadius` and `FloorTopY`.
      `HubAmenitiesBuilder` had a duplicated copy of the radius formula, and
      the moment the disc changed size the two disagreed about where the floor
      ended — which is precisely how the stands ended up on air. One source.
- [x] Boards brought onto the pavement: straights 112 -> **100**, curves
      190 -> **118** (curve pair still further out than the straight pair).
- **Verified live:** disc radius 130; every leaderboard and vendor stand
  reports **ON THE DISC**; lowest truss bottom Y = **2.00** against a disc top
  of 2.00 (**gap 0.00**), and a raycast under a leg hits `HubFloor` at 2.00.

## Chunk 69 — lava glitter  **[DONE]**
- [x] The glitter was the THEME'S ROAD, not the hazard. Volcanic's
      `RoadMaterial` was `CrackedLava`, which renders animated
      self-illuminated cracks across the entire segment — and it competed
      with the actual hazard, since the magma patches are already flat
      emissive red (the same Neon treatment the skill pickups use).
      Now `Enum.Material.Slate`, matte and normally lit, so the only thing
      glowing on a Volcanic segment is the thing that costs a life.
      Verified live: road material reads `Slate`.

## Chunk 70 — fan reward per checkpoint  **[DONE]**
- [x] `EconomyRates.CheckpointFanReward = 2`, paid for checkpoints 1-7 only —
      the 8th IS the lap and pays the lap reward instead, so no crossing is
      ever paid twice.
- **Verified live**: +4 on each of checkpoints 1, 2, 3 and 4 (2 base, doubled
  by the DoubleFans pass), correct every time.

## Chunk 71 — passive gold income from fans  **[DONE]**
- [x] New `EconomyAndData/FanIncomeService.luau`. Every
      `FanIncomeIntervalSeconds` (300) each player earns
      `FanIncomeGoldPerFan` (0.02, PROVISIONAL) of Gold per Fan held —
      1 gold per 50 fans per 5 minutes. A rate rather than a flat trickle so
      it scales with the stat it rewards.
- [x] ONE shared server timer, not per-player: a player cannot farm partial
      intervals by rejoining, and the cost stays flat regardless of headcount.
      Payouts are floored to whole Gold so the profile stays an integer store.
- **Verified live**: 50,000 fans -> **2,000 gold** (50000 x 0.02 x 2), exactly
  as computed.

## Chunk 72 — server authority audit  **[DONE]**
Every site that INCREASES `Gold`/`TotalFans`, and what gates it:
| site | client involvement |
|---|---|
| `CheckpointValidator` checkpoint + lap | none — server's own 0.5s geometric poll; teleports explicitly rejected |
| `CarryItemService.TryDeposit` | client asks; server re-checks carried type AND `IsNearDepositZone` on the server-held position |
| `GrandPrixManager` payouts | none — server state machine only |
| `QuestService.tryClaim` | client sends a category id and nothing else; tier, amount and currency come from the server's config, gated on recorded progress |
| `ProcessReceiptManager` | Roblox receipt callback, deduped by `PurchaseId` |
| `FanIncomeService` | **no remote exists at all** |
- Confirmed live by enumerating every remote: the only gold-named one is
  `Track.BuyExtraLifeWithGold`, which SPENDS gold under server validation.
  There is no remote through which a client can request a payout.

---

# Remaining / not verified
- **The final ladder-to-ledge step** on the leaderboards — see chunk 64.
- **`FanIncomeGoldPerFan` is provisional** and unbalanced, like the Grand
  Prix ladders. It compounds against a total that only grows, so it wants a
  real balance pass before launch.
- **Quest UI on a real second player** — the Invite ladder's credit path
  needs a genuine second Player joining via an invite, which a solo Studio
  session cannot produce. The dedupe and crediting logic was reviewed and the
  ladder itself was claim-tested with progress set directly.
- **Last-man-standing race end** — needs a genuine second Player in the
  server; a solo Studio session cannot produce one. Logic reviewed only.
- **Desert wind** — implemented and builds clean, but its effect is a
  `WalkSpeed` override rather than geometry, so it was not separately
  measured live this round. Worth a real run-through on a Desert segment.
- **Grand Prix reward values** are placeholders, unbalanced, as requested.

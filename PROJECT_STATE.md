# Project State: Brawler-Racer

## Persistence surface — what is stored, and how often it is written

Two kinds of store: the **profile** (everything a player owns) and four
**OrderedDataStores** that exist only so the stadium leaderboards can rank
players across servers.

| | |
|---|---|
| Store name | `PlayerData_v1` |
| Library | ProfileStore (`lm-loleris/profilestore@1.0.3`), session-locked |
| Key | the player's `UserId`, one key per player |
| Schema | `ServerStorage/PlayerDataTemplates/ProfileTemplate.luau` |
| Written by | `EconomyAndData/ProfileManager` only |

| | |
|---|---|
| Store names | `Leaderboard_{Laps,Fans,Gold,BestLap}_v1` |
| Type | `OrderedDataStore` (the only Roblox primitive that can answer "who is top 10 across the whole game" — ProfileStore keys are per-player and readable only by the server holding that session lock) |
| Key | `UserId`; value is the ranked integer |
| Written by | `EconomyAndData/LeaderboardManager` only |

### Fields persisted

**Economy / progression** — `Gold`, `TotalFans`, `Lives`,
`TotalLapsCompleted`, `BestLapTimeMs` (best single lap in ms across Arcade
AND Grand Prix; 0 = no timed lap, and 0 is excluded from the board or an
untimed player would rank first on a fastest-lap board),
`LastCheckpointOrdinal`, `Skills` (per-skill `Level`/`Unlocked`),
`EquippedSkills` (3 slots), `Inventory`, `Settings`
(`MusicEnabled`/`SfxEnabled`).

**Anti-double-grant** — `GrantedPurchaseIds` keyed by `receiptInfo.PurchaseId`
(Roblox redelivers receipts until `PurchaseGranted`, so this is what stops a
retried receipt granting twice), and `GoldRevivesUsedToday` /
`GoldRevivesLastResetDay` for the daily free-revive cap.

**Quests (new)** — a `Quests` sub-table: `LastResetDay`,
`PlaytimeSecondsToday`, `LapsToday`, `LoginStreakDays`, `LastLoginDay`,
`InvitesAccepted`, `InvitedUserIds` (the dedupe set that stops the Invite
ladder being farmed by two accounts), `ClaimedTierByCategory`,
`ClaimedDayByCategory`, and the audit totals `LifetimeQuestGold` /
`LifetimeQuestFans`.

### Write frequency — this is the part that matters for budget

Gameplay code **never writes to the DataStore**. Every `profile.Data.X += n`
in the codebase (lap rewards, fan deposits, Grand Prix payouts, shop
purchases, life loss, quest claims — 26 such sites) mutates an **in-memory**
table. Only ProfileStore turns that into a DataStore request, and it does so
at exactly three moments:

1. **Session start** — one `UpdateAsync` per player join (loads + claims the
   session lock).
2. **Auto-save** — one `UpdateAsync` per active profile every
   `AUTO_SAVE_PERIOD = 300` seconds (5 minutes). This project does **not**
   call `ProfileStore.SetConstant`, so the library default stands.
3. **Session end** — one `UpdateAsync` when the player leaves.

So a full 40-player server costs roughly **40 writes per 5 minutes ≈ 8/min**
in steady state, against a Roblox `UpdateAsync` budget of
`60 + 10 × players` ≈ 460/min. Roughly 2% of budget; there is no throttling
risk from the quest system or anything else added so far.

**Leaderboards (OrderedDataStore) add:**
- **Writes** — `LeaderboardManager` publishes a player's four values every
  `PUBLISH_INTERVAL_SECONDS = 120`, and once more when they leave, but
  **only for categories whose value actually moved** since the last publish
  (each player's last-published values are kept in memory and compared). A
  player standing in the Hub writes nothing at all. The worst case — 40
  players all changing all four values every cycle — is 160 writes per 2 min
  = 80/min; the realistic case is a small fraction of that.
- **Reads** — one `GetSortedAsync` per category per
  `REFRESH_INTERVAL_SECONDS = 60`, i.e. **4/min for the whole server**,
  cached and shared by all eight board faces. Board rendering never queries.
- Display names are resolved with `GetNameFromUserIdAsync` once per UserId
  and cached for the server's lifetime, including failures — an uncached
  failure would re-query a deleted account on every refresh forever.
- An unpublished place (`PlaceId == 0`) skips store creation entirely and the
  boards simply render empty.

The practical consequence to remember: **up to 5 minutes of progress can be
lost to a server crash** (a clean leave always saves). That is the library's
intended trade and is why the quest audit totals live in the same profile as
the currency they explain — they can never disagree, because they are saved
by the same write.

### Not a DataStore, despite appearances
- `ReservedServerTokens` is an in-memory registry of TeleportService access
  codes only; nothing is persisted.
- The Fan Box records boards read Player **attributes**, not the profile or
  any store — `ProfileManager.SyncAttributes` already mirrors the four values
  they show, so they update off a signal that is already firing.


**Chunk 84 (2026-08-06) — VERSION 1. Boundary exploit fixed, skill curves
retuned, cast rewards added, Grand Prix to a 12-minute cadence. Stress tested
and live-verified. Nothing committed.**

**1. THE BOUNDARY EXPLOIT — players ran the whole lap outside the track.**
Reported from play: "able to walk outside the track and on the walls, rendering
all obstacles obsolete." Both halves were real and both are fixed in
`TrackBoundaryMonitor`.

- **The legal corridor was 13 studs wider than the road.** `ON_TRACK_MARGIN`
  was `SegmentWidth/2 + BarrierThickness + 10` = 49 against a road half-width
  of 36. Measured against the real sample cloud, the true allowance ran 44-49
  studs depending where you stood.
- **That corridor became walkable when TerrainGroundBuilder landed.** Raycast
  live: ground outside the wall is Terrain at **Y = 0.02 against a road top of
  Y = 1.00** — a one-stud step down onto a flat, hazard-free apron running the
  whole lap, 320 studs deep. Before terrain existed, hopping the barrier
  dropped you to the Baseplate at -47, past `FALL_OUT_Y_THRESHOLD`, and cost a
  life. Terrain silently removed the consequence. **This is the general
  lesson: adding scenery can delete a rule that was being enforced by the
  absence of scenery.**
- **Barrier tops were legal too** — 37.5 lateral is inside a 49 margin and 10
  studs up is far under `MAX_HEIGHT_ABOVE_TRACK`, so the wall was a catwalk
  over every hazard.

Three changes, and the first is what makes the second possible:

1. **Lateral distance is now measured to the centreline RUN each sample stands
   for, not to the sample POINT** — in the sample's own frame, so it comes out
   as true lateral offset. The old nearest-point measure was wrong by up to
   17.7 studs on a curve (samples are 30 studs apart on a straight, 35.3 on a
   curve), and *that error is what the +10 slack was paying for*. Swept every
   point of every road slab: worst reading anywhere is **36.000**, exact.
2. **`ON_TRACK_MARGIN` = `SegmentWidth/2 + BarrierThickness` = 39.** The
   barrier is the boundary. No tolerance on top on purpose — this is a
   brawler, players shove each other into the wall, and those 3 studs ARE the
   shove allowance (a racer pinned against the wall reads ~35).
3. **A downward ray identifies the wall top.** 37.5 is inside the margin by
   design, so distance alone cannot catch it; tightening the margin instead
   would charge a life for being body-checked. `RespectCanCollide` so
   SkyRail's non-collidable railings cannot mask it.

The two branches now ask different questions: a racer must be on a legal
racing surface (`onTrack`), a lobby player merely has to be out of the track's
space (`withinTrackBounds`) — so perching on the wall still bounces them.

Live-verified: apron at 44 lateral violated in 0.53s, barrier top in 0.67s,
and straight / mid-chord / **chord-join** outer road edges all held 4 ticks
with no life lost. The chord-join row is the regression guard — it is the
geometry the old measure read worst, and tightening the margin without fixing
the distance measure would have started charging lives to anyone taking a
curve on the outside line.

**Test-method trap worth keeping:** the first run anchored the root part on the
CLIENT and moved it. A client's CFrame writes to an ANCHORED part do not
replicate, so the server — which is what the monitor reads — never saw those
positions and the tests measured nothing. Hold a character with a per-frame
CFrame write on an UNANCHORED part instead (same approach as `pushPlayer`).

**2. Skill curves retuned (user-specified values).** `GOLD_COST_MULTIPLIER`
10 -> 1 and `DURATION_MULTIPLIER` 4 -> 1, so gold prices and durations are now
literally what each skill's curve params say. Per-skill bases/steps set for 16
skills. `COOLDOWN_MULTIPLIER` (2) and `MAGNITUDE_EXAGGERATION_MULTIPLIER` (2)
are unchanged — **the pass is no longer uniform, read each constant.**

**ShockTarget had no strength progression at all** and was the one real defect
found: `BaseMagnitude = 0.15` computes to **-0.7** through
`1 + (raw - 1) * 2`, a negative stat multiplier, so all ten levels were
rescued by the 0.05 floor clamp and were identical. `BaseMagnitude = 0.6`
gives 0.20 -> 0.05, real progression, and makes Shock the stronger debuff at
**9 of 10 levels** against SlowTarget (was 0). They tie at L10 where both
floor; closing that needs Slow's curve or the shared floor to move.

**3. Fan reward for a successful skill cast** — Self 1 / Target 2 / Global 4,
in `EconomyRates.SkillCastFanRewards` keyed by `CastType` so the lookup cannot
drift from `SkillTrees`. New `EconomyAndData/SkillRewardService`. **"Success"
is defined per manager and the placement is the whole point:** the call sits at
the BOTTOM of each manager's shared resolve, past every early return — so a
Target cast into empty space pays nothing ("NO TARGET IN RANGE!" is not a
cast), and because it is the *shared* resolve, a pickup cast pays the same as
an owned one. DoubleFans applies, matching every other fan payout.

**4. Grand Prix cadence 30 -> 12 minutes**, race limit 5 -> 4 minutes. 12
divides an hour, so the wall-clock marks stay clean: **:00 :12 :24 :36 :48**.
Tutorial card 5 and ten stale code comments updated to match.

**5. STRESS TEST — cycle and regeneration both clean.** Two full cycles via
the real `GrandPrixStateChanged` broadcast, payout exactly the documented
+3300 gold / +1650 fans. (A 1.2s second race is CORRECT, not a bug: the roster
empties at payout, so with no entrants it ends on "nobody left standing".) 26
regenerations: Hub **4** and FanBoxes **61** every sample, memory plateaus flat
at ~1916MB over a 24s idle window — no leak, same conclusion as chunk 83.

**Two baseline numbers in this file are now stale and were re-measured:**
- **Track parts by theme** (whole oval): NeonCircuit 116, Classic 128, SkyRail
  236, WaterDock 240, Volcanic 284, IceFrost 444, Desert 500, **HillMud 1148**
  — 3.6x the 316 max recorded in chunk 83, from the difficulty pass.
- **Loose workspace parts are no longer a constant 3.** They oscillate 3-17
  under rapid regeneration and settle back — transient hazard debris parented
  to `workspace` rather than to the Track model, so it survives a regeneration
  and relies on its own timer. Harmless live (one regeneration per race).
- Frame time 16.66 -> 17.5-19ms mean (same Studio setup, 1 player). It tracks
  **moving primitives, not part count** — NeonCircuit at 116 parts measured
  slower than HillMud at 1148, having 188 unanchored parts to HillMud's 107.

**6. 50-racer analysis — script CPU is NOT the bottleneck.** At 50 players:
`ZoneHazardMonitor` 3.06 ms/s (its 50 x 72 zones is the only super-linear
loop), `TrackBoundaryMonitor` 2.18 ms/s. ~5ms out of 1000. DataStore ~20% of
budget. `StreamingEnabled` is **true**, which removes the naive "1148 parts x
every client" concern. The unmeasurable-from-one-client risk is density: all
racers inside ~70 studs at the start grid, and the Hub between races.

**OPEN DEFECT — the start grid breaks at slot 41.** `startGridOffset` steps
straight back along +Z, but what sits behind the start line is segment 8, a
CURVE, so the straight grid diverges from the curved road. Verified all 40
slots: **no violation at 40**, but slot 36 sits at 36.40 — 0.4 studs past the
road edge, clipping the barrier band (physics nudges them back in, cosmetic).
Slot 41 measures 39.31 and slot 46 measures 43.20, both past the margin — an
off-road spawn and a life lost before the flag drops. Safe at 40, broken at
41, and **`Players.MaxPlayers` reads 60 in the place file.** Fix is to walk
the sample chain so the grid follows the curve, or cap rows at 8. Note the
interaction: under the old 49 margin those slots passed, so the boundary fix
is what makes this live.

**Chunk 82 (2026-08-04) — Grand Prix moved onto real-world wall-clock time.
Live-verified end to end.**

Per user: *"Grand Prix is every 30 mins but instead of a coroutine, use real
world time, e.g. 8:00 then 8:30 then 9:00."* The 30-minute cadence itself was
already correct; what was wrong was what it was measured **from**.

1. **The schedule was per-server and arbitrary.** `nextRaceStartTime` was
   `os.time() + RACE_INTERVAL_SECONDS` — 30 minutes counted from whenever
   *this* server last finished a race. A server booted at 8:07 ran at 8:37,
   9:07, ... while the one next door ran 8:22, 8:52. "When is the next Grand
   Prix" had no answer that held anywhere except the server you happened to be
   standing in, and none that could be advertised outside the game at all.
   - **Fix: new `nextScheduledStart(after)` in `GrandPrixManager`** returns the
     next real-world :00/:30 mark strictly after `after`. `os.time()` is UTC
     epoch seconds and the epoch itself falls on a :00, so whole multiples of
     the interval **are** the half-hour marks — no calendar arithmetic, and no
     DST edge case, because UTC has none. Strictly-after, not at-or-after:
     called with the current time, landing exactly on a mark would otherwise
     schedule a race for the instant that just passed and fire it immediately.
   - Called from both sites that ever set the schedule: module init and
     `enterWaiting()`. `enterWaiting()` **re-derives** from the wall clock
     rather than adding to the old value, so a race that ran early (via
     `StartRaceNow`) or late cannot push the rest of the day off the marks —
     the schedule is absolute and every Waiting period simply runs until the
     next one. `StartRaceNow()` is therefore now a one-off jump rather than a
     reschedule, and an off-schedule test race puts the server back on the
     marks by itself.
2. **The mark is now shown, not just counted down to** — the point of a
   wall-clock schedule is that players can plan around it, which a bare
   duration doesn't let them do. `Network.Track.GrandPrixTimer` gained a third
   argument, `nextRaceStartTime` as an absolute UTC timestamp, and the Waiting
   label reads `NEXT GP 20:30 · 12:34` — the mark **and** the countdown,
   because they answer different questions ("I'll come back for the 20:30" vs
   "stop what you're doing now").
   - **The client does the formatting, deliberately**, via
     `DateTime.fromUnixTimestamp():FormatLocalTime("HH:mm", "en-us")`, which
     resolves the *player's* time zone. The server schedules in UTC and has no
     way to know a 19:30 UTC race is 20:30 to someone in Berlin. 24-hour
     because it needs no am/pm to be unambiguous and fits the 22px label.
     `pcall`'d (a locale the client can't resolve would otherwise throw inside
     the render loop that draws the whole label) and the third argument is
     treated as optional, so either failure degrades to the old
     countdown-only text rather than to an error.
   - Width checked against the real GUI rather than assumed, since `MainHUD`
     lives in the place file and not in the Rojo project: `TextService` measures
     the new string at **97.6px in a 157.4px label** (`TextWrapped` false,
     `TextTruncate` None, so an overflow would have been silent clipping).
3. Tutorial card 5 now says "On the hour and half-hour" instead of "Every 30
   minutes", and points at the clock.

**Live-verified (Play session):** at 09:21:27 UTC the next race read
**09:30:00 UTC**, `nextStart % 1800 == 0`; the client HUD showed
`NEXT GP 17:30 · 8:11` — the same instant correctly rendered in the player's
UTC+8 local time — at 97.6px inside a 157.4px label, countdown ticking. A
forced off-schedule race driven through the **real** server module (injected
`Script`, since `execute_luau`'s `require` returns a phantom copy — confirmed
again this round: the real server took a client join the required copy could
not see) ran the full `Waiting > Countdown > Racing > Ended > Waiting` cycle
and `enterWaiting()` re-derived to **09:30:00, unchanged and still on the
mark** — i.e. the out-of-band race did not shift the schedule. Probe and its
attributes confirmed destroyed; `rojo build` clean.

**Chunk 81 (2026-08-03) — QA pass part 1: all 16 theme/segment combinations
audited. 2 real defects found and fixed; no impassable geometry anywhere.**

Method (reusable — the harness is worth rebuilding rather than eyeballing):
walk the piece chain for each segment's own frame, then for 24 slices x 17
lanes collect EVERY collidable surface in the column (repeated downward
raycasts, not just the first hit — the first version reported false
"19-stud rises" that were hazard bars floating over the road), and run a BFS
over (slice, lane, surface) with a 6.37-stud jump limit. Regenerate until all
16 theme/segment combinations have been seen.

1. **SkyRail's elevated pieces were wider across the track than long along
   it** — the reported "bridges are perpendicular to the track". Measured on a
   real generation: bridges **20.2 wide x 18.0 long**, moving platforms
   **20.2 x 8.0**. A bridge is a thing that is long in the direction you
   travel, so every deck read as a slab laid across the road.
   `SKYRAIL_PATH_WIDTH` is now `SegmentWidth * 0.14` = 10.1 (a genuine
   catwalk; a character is ~4 wide) and the elevated span is divided so every
   deck stays longer than it is wide: bridges **10.1 x 15.6** (ratio 1.55),
   movers **10.1 x 12.4** (1.23). Added non-collidable railings running the
   deck length, which is what makes it read as a bridge without removing the
   risk of falling. A build-time ASSERTION now fails loudly if any elevated
   deck is ever wider than it is long again.
   - Fairness checked, not assumed: the two opposite-phase movers are within
     jump range **68% of the cycle**, and the bridge-to-mover entry is
     reachable **100%** of it. A real timing challenge, not a wall.
   - Steps stay wider than deep (0.56) on purpose — that is what stairs are.
2. **Desert had NO hazards at all.** `buildDesert` was an empty function:
   3 parts on a straight (road + 2 barriers), 24 on a curve (chords +
   barriers). Two of the sixteen combinations were bare road, so the theme
   played as a gap in the race. Now sandstorm sweeper bars on straights
   (Volcanic's proven non-lethal shove) and dune climb-walls + jump platforms
   on curves (HillMud's pair, including its endClearance rule that keeps
   walls off the checkpoint/respawn plane). Built from helpers already proven
   live rather than a new mechanic — more interesting is not worth more
   likely to ship broken. Parts now 7 (straight) / 108 (curve).

3. **WaterDock's "narrow bridge" was three disconnected stepping stones.**
   Variant B builds two crossings of 3 planks each; measured, consecutive
   planks sat **12 studs apart laterally while being 4 studs wide**, sharing
   only 2 studs of Z — an **8-stud sideways gap over open water**, three times
   per crossing. The code comment asserted "the planks overlap end-to-end so
   the path is continuous"; they never did. Continuity depended on two
   independent numbers (jog and plank width) happening to agree, and they
   didn't. Planks are now built BETWEEN shared WAYPOINTS and rotated to face
   along their own span, so consecutive planks meet at a point they both
   derive from — continuity is structural and survives retuning the jog, the
   count or the pool length. Verified: continuous dry footing from entry road
   to exit road, narrowest point **4 studs per lane**.
   - Not caught by the crossability BFS, correctly: falling in is a swim, not
     a death, so the segment was always "crossable". The bridge is an optional
     fast route that did not work as a route — a class of defect the BFS
     cannot see by construction.

Verified after all three changes: **16/16 crossable, none blocked**, clean
console across ~10 regenerations.

**Scanner lesson worth keeping:** three separate false readings came from
stopping at the FIRST raycast hit — hazard bars floating over the road read as
"19-stud unjumpable rises", and the pool rim (`CanCollide = false`) hid the
road underneath it and read as a hole in the track. Any footing scan here must
walk PAST non-collidable hits down the column, not stop at them.

**Chunk 82 (2026-08-03) — QA pass part 2: sounds and VFX, "more alive,
festive". Live-verified, including cleanup.**

The progress bursts were all single-colour fountains distinguished only by
hue and count — they read as "an event fired", not as a crowd reacting to a
race. Added the two shapes a stadium actually uses, built on the existing
`emitBurstAt`/Debris pattern so they inherit its cleanup rather than inventing
a second lifetime rule:

- `ShowConfettiBurst(position, intensity?)` — five overlapping single-colour
  emits, not one rainbow ColorSequence (a sequence makes each PARTICLE cycle
  colours; what is wanted is a cloud that CONTAINS every colour).
- `ShowFireworks(originCFrame)` — 7 shells staggered 0.35s apart, rising 90
  studs on a tween and detonating into a coloured burst plus a white flash.
  Anchored and tweened, not launched: same reasoning as StadiumBlimp and the
  Fan Box balloons — decoration that participates in physics eventually
  becomes a bug report.

Wired ADDITIVELY, never replacing an existing cue — the coloured burst is
information the player uses (which of checkpoint/lap/reward fired), the
confetti is decoration, and trading the first for the second mid-race would
be a bad trade:
- **Lap complete** — confetti + a 3D `CrowdCheer` at the runner, so everyone
  nearby hears the crowd react to THEIR lap.
- **Grand Prix finish** (crossing for the final time) — confetti at 1.6x and a
  cheer, fired at the Hub where `LeaveTrack` has just put the player, so the
  celebration is somewhere they can see it rather than on a track they are no
  longer standing on. This moment previously had no effect of its own at all.
- **Grand Prix end** — fireworks over the infield for the whole server, timed
  to land inside the `RESULT_HOLD_SECONDS` window so they play while the four
  boards still show the final standings. Fired on the EVENT ending rather than
  on a winner, because a Grand Prix normally times out with nobody finishing —
  tying it to a winner would mean most races end in silence.

No new audio ids were invented: `CrowdCheer` reuses the one load-verified
crowd clip. Verified live: 5 confetti anchors, 4-of-7 shells airborne at
t=1.2s (correct stagger), 10 burst anchors at detonation, and **shells and
anchors both back to 0** after cleanup — no leaks. Clean console.

**Chunk 83 (2026-08-03) — QA pass part 3: Grand Prix / regeneration / arcade
stress test. NO data loss, NO leak, NO generation failure found.**

Method: `RACE_INTERVAL_SECONDS` 30min -> 15s, `RACE_TIME_LIMIT_SECONDS`
5min -> 25s, `COUNTDOWN_SECONDS` 15 -> 5, behind a single
`STRESS_TEST_MODE` flag so the production values stayed visible in the diff.
**Both restored and verified afterwards in the file AND in the running server
(next race reported 1800s).**

Results across ~40 regenerations and 7 full state cycles:
- **Cycle integrity** — Countdown -> Racing -> Ended -> Waiting ran cleanly 7
  times, each ending in a track regeneration. A clean natural cycle with a
  real entrant: 5s countdown, full 25s race, payout **+3300 gold / +1650
  fans** (the documented shared-remainder split), then `InLobby` and
  `Waiting`. Player state returns correctly.
- **No data loss** — gold / fans / laps identical across 4 consecutive
  regenerations, and payouts landed exactly as predicted.
- **No generation failure** — 20 back-to-back regenerations, then 12 paced,
  then 6 more: **zero errors**, always 9 pieces, clean console throughout.
- **No leak.** Memory plateaus (1799 -> 1801 -> 1801 MB after settling); the
  +42MB seen during the back-to-back burst was GC lag from 20 regenerations
  inside ~3s, which is not a condition a live server sees. Decisive test:
  parts per CONTAINER over 6 regenerations — Track swings
  166/208/178/130/316/292 purely with theme mix (HillMud curve is 108 parts,
  Classic straight is 4), while **Hub=4, FanBoxes=61 and loose parts=3 never
  move**. No orphans. The three Heartbeat-driven hazard types all disconnect
  on `Destroying`, and terrain does not creep because
  `TerrainGroundBuilder.Rebuild()` runs FIRST in `GenerateOval`, before any
  chasm is carved (measured 98.6% solid, the 1.4% air being the current
  generation's chasms).

**One false alarm, recorded so it isn't re-investigated:** mid-test a racer
appeared stuck `InRace` across several cycles. That was self-inflicted — the
hammer test called `TrackGenerator.Regenerate` DIRECTLY during a live race,
bypassing the `CheckpointValidator.RefreshCheckpoints()` /
`TrackBoundaryMonitor.RefreshTrackGeometry()` calls that `enterEnded` makes
straight after regenerating. That is precisely the stale-reference hazard
`enterEnded` documents. Re-tested on a clean session and the player returned
to `InLobby` correctly. **Never regenerate the track outside `enterEnded`
without those two refreshes.**

**Chunk 80 (2026-08-03) — DASH REGRESSION from chunk 75, fixed and
live-verified.**

Doubling `DURATION_MULTIPLIER` (2 -> 4) broke Dash, because `DashSelf` used
`EffectDurationSeconds` for TWO jobs: the buff duration AND the traversal time
in `SelfSkillManager.runForward`, which derives speed as `distance / time`.
Doubling the time halved the speed to **10 studs/s against a base walk speed
of 16** — a dash slower than walking, and `SetWalkSpeedOverride` suppresses
the effect recompute for its duration, so the caster was LOCKED there for
1.6-2.3s. The same coupling was correctly spotted and protected for
`ChargedJumpForward` (`JUMP_FLIGHT_DURATION_SECONDS`); Dash's copy of it was
missed.

Fix: `SkillLevelData.TraversalSeconds`, generated from the same curve but
multiplied by a **separate frozen `TRAVERSAL_DURATION_MULTIPLIER = 2`** — the
value `DURATION_MULTIPLIER` held when the dash distances were tuned. Buff
duration and movement speed can now be tuned independently, which is the
actual defect. Verified: dash speed 20.00 / 21.67 / 23.10 studs/s at L1/L5/L10
— identical to pre-break — while buff durations keep the doubled values.
Live cast at L10: WalkSpeed override **23.1** for the traversal, **25.8 studs**
displaced (range 26.8), then the DashBoost buff peaking at **40.64**, settling
back to exactly 16.00.

Guard added so this cannot ship again: `SelfSkillManager` asserts at server
start that every movement skill, at every level, derives a speed strictly
above `MovementModifier.BaseWalkSpeed` (newly exported rather than
hard-coding 16 a second time). A bad tune is now a loud startup failure.

**Two Studio-testing traps hit while verifying this:**
- Studio caches `require` results per ModuleScript INSTANCE, and Rojo edits
  Source in place — so an already-required module keeps its OLD result in the
  Edit DataModel even after syncing. Restart Play for a fresh cache.
- The first verification pass raced the Rojo push and read half-synced
  modules. Check a sentinel string in `.Source` before trusting a require.

**Previous round (2026-08-03) — chunks 73-79, all DONE and live-verified.**

1. **The hub floor is a STADIUM, not a disc.** Round 11 cured the "still
   floating" report by moving the boards and vendor stands INWARD onto the
   130-stud disc (straights 112->100, curves 190->118, stands 124->118).
   That was the wrong half to move: the positions had each been measured
   against `TrackBoundaryMonitor`'s margin in Round 10 and were not free to
   change, and the instruction was explicitly to extend the floor instead.
   A circle cannot do it — the track's inner edge is only 144 from the
   centroid along the straights, so no disc reaches the curve-side boards at
   190. Tracing the piece chain gives the real infield shape: straights run
   along Z with centrelines at X = ±180, and each end is a SEMICIRCLE whose
   two curve pieces share a centre at Z = ±180. So the floor is now a
   260-wide slab spanning Z ±180 plus two 130-radius end caps, reaching
   |Z| = 310. All original radii restored (112 / 190 / 124).
   - Verified live: pavement present at |Z| = 300, absent at 320; every
     board and stand raycasts onto `HubFloor`/`HubFloorEnd` with gap
     **0.00**; boundary clearance +12.0 studs (straight pair) and +91.6
     (curve pair) measured against the monitor's own 1440-point cloud.
   - New `HubGenerator.IsOnPavement` is the single definition of the
     outline, and `HubAmenitiesBuilder` now ASSERTS every part is on it at
     build time — the previous floating bugs were all some other module
     holding a stale copy of where the floor ends. 9/9 shape cases pass,
     including a corner case that distinguishes a stadium from a bounding box.
2. **Background music** — new `Configs/MusicTracks` + client
   `MusicController`: `110662907164248` (Arcade) and `114882049925780`
   (Grand Prix), both at volume **0.12** against effects at 0.4-0.7. Which
   bed plays is decided by the Grand Prix STATE alone, the same rule that
   drives the leaderboard takeover, so the two can never disagree about
   whether a race is happening. Cross-faded, and paused rather than stopped
   so the Arcade loop resumes mid-phrase after a race.
3. **Skill durations doubled again** — `DURATION_MULTIPLIER` 2 -> **4** in
   SkillTrees. It multiplies the whole `BaseDuration + steps * DurationStep`
   expression, so the per-level STEP doubles with the base and the curve
   keeps its shape. `ImmunityDurationSeconds` 5 -> 10 went with it.
   `JUMP_FLIGHT_DURATION_SECONDS` deliberately did NOT: it is the measured
   airtime of `JUMP_UPWARD_SPEED`, not a balance dial, and doubling it would
   spread the same distance over twice the time — the caster would glide
   forward for 0.4s after landing.
4. **Grand Prix takes over the four stadium boards** from the countdown grid
   to the final result, then reverts. All four show the SAME live standings
   (a racer reads whichever board is in front of them). Pushed in by
   `GrandPrixManager` from the same function that broadcasts standings, so
   the boards and the network standings are always the same data from the
   same moment. `RESULT_HOLD_SECONDS = 20` exists because "until the winner
   and rewards are announced" cannot be expressed as a state: the loop calls
   `enterWaiting()` one tick after `enterEnded()`, so the final result would
   otherwise be on screen for one second. A handoff token stops a new race's
   boards being wiped by the previous race's pending revert.
5. **The on-screen standings panel is gone** during races (`LiveRaceHUD`) —
   it is now permanently hidden, re-asserted on every state broadcast.
6. **The POSE button does something.** It was a TODO on both sides. Now:
   cycles the free built-in emotes (`Configs/PoseEmotes`, played via
   `Humanoid:PlayEmote`), sets the crowd off (cheer sound + confetti poppers
   + a balloon release, all laid out in the POD's frame so they land in front
   of the stand for every pod on the oval), counts toward a new **Poses**
   daily quest ladder, and tips **50 Gold once per ten-minute window**. The
   emote is best-effort (PlayEmote is R15-only and throws on rigs that can't
   emote) but the reward and the crowd reaction are not — a refused animation
   must not cost the player their tip. 3s anti-spam cooldown, server-side.
7. **Fan delivery is worth making** — depositing a carried fan payload now
   pays **5x, once per ten-minute window**.
8. **Both new periodic bonuses use `Utils.GlobalWindowIndex`**, not timers
   and not per-player elapsed checks. The window index is derived from
   `os.time()` alone: no coroutine, identical on every server, and "have I
   claimed this window" is one integer comparison. Both last-claimed windows
   are in the PROFILE — an in-memory record would be cleared by rejoining,
   which turns "5x every ten minutes" into "5x whenever you reconnect".
9. **Server authority holds for all of it**: the pose remote carries only an
   emote id (re-validated against the config, plus an AtFanBox state check),
   the deposit remote carries no arguments at all, and nothing added here
   lets a client name an amount.

**Evidence for this round:**
- 18 server modules + 5 client modules compiled; that also PROVES no require
  cycle, since `TeleportPoseService` now requires `QuestService` while
  `ArcadeManager`/`TrackBoundaryMonitor` require `TeleportPoseService`.
- Durations: SlowGlobal L1 8.00 -> **16.00s**, and the step contribution
  4.00 -> **8.00s** (the step doubled with the base, which is the half a
  flat "+N seconds" change would have missed). ImmunityDuration **10**.
- Music: `Music_Arcade` playing, volume **0.120**, correct asset id.
- Board takeover, driven on real boards in a scratch folder through all four
  states: header GRAND PRIX / LIVE STANDINGS, accent orange, rows rendering
  `L2 · CP5`, `OUT` (dimmed to 0.55), `P1`; reverts to THE MARATHONER /
  cyan; both faces agree.
- Pose, through the REAL remote on a live server: **+100 gold** (50 x the
  DoubleFans pass), **10 CrowdBalloon** parts spawned, a second pose in the
  same window paid **0**, a third inside the 3s cooldown was ignored
  entirely — and the quest counter read **2**, not 3, so the spam-blocked
  press correctly did not count while the gold and quest gates stayed
  independent.
- Deposit: first in the window **+100** (base 10 x5 bonus x2 pass), second
  in the same window **+20** (10 x2, no bonus). Both halves confirmed.

**Two traps worth remembering for the next session** (both cost time here):
1. `execute_luau`'s `require` returns a FRESH module instance, not the
   running server's. Anything holding state — `HubGenerator`'s cached hub
   CFrame, `GrandPrixManager`'s state machine — reads as empty/nil and
   mutating it does nothing. Drive real behaviour through the REMOTES from
   the Client DataModel instead, and read results off Player attributes.
2. Fan payload pickup is a timed CHANNEL, not instant. `PickupItem` needs
   ~3-5s and the character must not move; and an InRace player teleported
   more than a few studs gets pulled back, so walk to the pickup in <=28
   stud hops rather than one jump.

**Previous round (2026-08-03) — chunks 68-72, all DONE and live-verified. Full
evidence in `WORK_PLAN.md` under "Round 11":**

1. **"Still floating" was a HEIGHT bug, not a support bug.** Structures were
   placed at the hub floor's top face (`hubCFrame.Y + 2`) while standing at
   radii 112-190, outside the 104-stud disc, where the ground is terrain at
   Y ~ 0 — so they hovered exactly 2 studs. `HUB_RADIUS` is now **130**,
   `HubGenerator` EXPORTS `HubRadius`/`FloorTopY` (HubAmenitiesBuilder had a
   duplicate copy of the formula, which is how the two disagreed about where
   the floor ended), and the boards moved onto the pavement (straights 100,
   curves 118). Verified: lowest truss bottom Y = 2.00 vs disc top 2.00, gap
   **0.00**, raycast under a leg hits `HubFloor`.
2. **The lava glitter was the theme's ROAD**, not the hazard: Volcanic's
   `RoadMaterial` was `CrackedLava`, which renders animated self-illuminated
   cracks across the whole segment and competed with the magma patches (which
   are already flat emissive red). Now `Slate`.
3. **Checkpoint fan reward** — `CheckpointFanReward = 2`, checkpoints 1-7
   only (the 8th is the lap and pays the lap reward, so nothing is paid
   twice). Verified +4 per checkpoint with the DoubleFans pass.
4. **Passive gold income from fans** — new `FanIncomeService`: every 300s each
   player earns 0.02 Gold per Fan (PROVISIONAL). One shared server timer, not
   per-player, so partial intervals can't be farmed by rejoining. Verified
   50,000 fans -> 2,000 gold.
5. **Server-authority audit**: every Gold/Fan increase is server-gated, and
   there is no remote at all through which a client can request a payout. The
   only gold-named remote spends gold under validation.

**Previous round (2026-08-03) — chunks 62-67. Full evidence in `WORK_PLAN.md`
under "Round 10":**

1. **The leaderboards were inside the boundary ring.**
   `TrackBoundaryMonitor.ON_TRACK_MARGIN` is 49 studs from the track
   CENTERLINE and returns an InLobby player to the Hub. The oval is not a
   circle, so that ring sits at radius 133 toward a STRAIGHT but 260 toward a
   CURVE end (both measured live). All four boards were at 128 with catwalk
   reaching 135 — past the straights' limit, which is what bounced climbers.
   Radii are now per-direction: **straights 112, curves 190**; worst clearance
   45 -> 61.
2. **Climbing needed four separate fixes**, each measured: a single 2x2 pole
   is not climbable (character slides, 0 height, no Climbing state) — needs a
   wide ladder face; two rows of poles wedge the character; the ladder ran
   through the deck (climb plateaued with 7 studs of ladder left); and it
   pinched against the screen. Final shape: 4-pole ladder at the deck's outer
   depth edge, **holes cut in the ledge** over each ladder, top 9.5 studs
   above the ledge. Climb confirmed at 22 studs with the `Climbing` state.
3. **Fan box board** faced sideways because it was built off the pod's
   `OriginCFrame`, which runs ALONG the track (LookVector dots 0.55 with the
   direction to centre, RightVector 0.83). Now `CFrame.lookAt` at the centre
   (dot 1.00), 30x16 instead of 12x7, and placed from the pod's real bounding
   box — 2 studs above the crowd's top row, 16.4 behind the stand.
4. **Vendor stands** (ice cream / hot dog / balloon / flower) at radius 124,
   in the ring the curve boards vacated. Built from parts, not inserted
   models, for the same durability reason as the blimp.

**Previous round (2026-08-03) — chunks 53-61, all DONE and live-verified. Full
evidence in `WORK_PLAN.md` under "Round 9":**

1. **Invite reward flattened** to 100 fans each, 5 friends, 500 total (was an
   escalating ladder) — the reward is per invite, not for a milestone.
2. **Grand Prix unclaimed prize is now shared, not deleted.** The finisher
   ladder is 5 deep but the race normally times out with nobody finishing, so
   most of the pool used to evaporate. The remainder now splits EVENLY among
   everyone still on the field. Verified on two real timed-out races:
   **+3300 gold / +1650 fans** each, matching the prediction exactly.
3. **Fastest-lap tracking** — `BestLapTimeMs`, timed checkpoint 1 -> 8 (not
   from track entry, which can't tell a real lap start from a teleport or a
   mid-lap join), sub-1s laps rejected. Verified 3932ms against a 3.40s wall
   clock, and a slower second lap correctly left the record alone.
4. **Four stadium leaderboards**, replacing `LeaderboardManager`'s stub with
   real OrderedDataStores: THE MARATHONER / THE MOST FAMOUS / THE RICHEST /
   THE FASTEST MAN ALIVE. Radius 128 (outside the 104 hub disc, ~16 studs off
   the track edge), each facing the hub centre so **opposite pairs face each
   other exactly** (measured dot = -1.00), 86x38 studs on climbable truss with
   a catwalk, a SurfaceGui on BOTH faces, rows with `rbxthumb` avatar
   headshots. Verified end to end: publish -> `GetSortedAsync` -> cache -> both
   faces, e.g. `"aphophys" / "91,500 gold"` and `"42.317s"`.
5. **Commercial center furnished** — jogging track, 10 benches, 4 banks of 5
   raked stands, playground. A build-time assertion keeps everything 22+ studs
   off the spawn pad.
6. **Blimp** circling at 16 studs/s, radius 306, altitude 168 — anchored and
   re-pivoted per Heartbeat rather than physics-driven.
7. **Fan box records boards** — avatar plus fans/gold/laps/best lap on both
   faces of every claimed pod, driven off the Player attributes
   `SyncAttributes` already mirrors.

**Previous round (2026-08-03) — chunks 47-52, all DONE and live-verified. Full
evidence in `WORK_PLAN.md` under "Round 8":**

1. **Desert wind no longer swallows every buff and debuff.** The wind called
   `SetWalkSpeedOverride` (copied from DashSelf), and an override SUPPRESSES
   the effect-driven recompute for its duration — fine for a fraction-of-a-
   second forced run, wrong for constant weather. New
   `MovementModifier.SetEnvironmentSpeedMultiplier` participates in the
   recompute instead. Verified exact: headwind + slow now 3.84 (was stuck at
   the wind's 9.60), and Dash's absolute override still wins outright.
2. **Daily quests / achievements**: new `Configs/QuestDefinitions.luau`
   (Playtime 9 gold tiers / Laps 5 fan tiers / DailyLogin 7 / Invite 5),
   `EconomyAndData/QuestService.luau`, and `QuestUIController`.
   - **Claim state is a ladder, not flags** — one number per category, so
     "paid exactly once" is a comparison, not bookkeeping.
   - **The daily cycle is DATE-DERIVED**: a `ResetsDaily` category's claim
     count is believed only when its day stamp is today, so the ladder
     re-opens by the calendar rather than by a reset pass having run. Proven
     live by ageing only the stamp — no reset, no progress change — and
     watching the ladder re-open and pay, while a lifetime ladder with a
     30-day-stale stamp correctly did not.
   - Claims are server-authoritative (the client sends only a category id),
     and `LifetimeQuestGold`/`LifetimeQuestFans` audit totals are written in
     the same function as the payout.
3. **UI**: QUESTS under ROBUX SHOP with Grand Prix moved down; **"ADD FANS"
   top right at x = 0.72**, the exact slot `StandingsPanel` occupies, hidden
   for the whole Countdown/Racing window (verified over 24s of a real race).
   **`MainHUD` has `IgnoreGuiInset = true`** — a Y offset of 46 renders at
   AbsolutePosition -12, under Roblox's topbar. Anything anchored near the
   top needs ~76.
4. **Persistence documented** — see the "Persistence surface" section at the
   top of this file.

**Previous round (2026-08-03) — chunks 38-46, all DONE and live-verified. Full
per-chunk evidence in `WORK_PLAN.md` under "Round 7"; summarised here:**

1. **Stepped climb walls — the previous "fix" was the bug.** Chunk 6's
   alternating ±9 zig-zag repeats every 2 steps, so platform 3 landed at the
   SAME lateral offset as platform 1 with only ~3 studs of z between them on
   an 8x8 platform: platform 1 had a ceiling 12 studs over its take-off
   point. That is exactly the reported "bouncing / blocked by the step
   above", just moved two steps up the wall. Now a MONOTONIC staircase — each
   step advances the same direction, so a repeated offset is arithmetically
   impossible — at constant approach z, 10-stud lateral advance, count
   derived from `JUMP_PLATFORM_MAX_RISE = 5`. Verified live: raycast 14 studs
   up out of all 36 platforms, 0 hit another platform.
2. **Volcanic sweeper rods** 3s -> 6s per pass. That constant is what sets
   the speed over the 144-stud span: measured live 48 -> 23.8 studs/sec
   against a player's 16.
3. **Control scramble is no longer a dead path.** `ApplyBlindEffect` is
   replaced by `Network.Combat.ApplyControlEffect(mode, duration)`, fired
   from **`EffectStackManager.TryApplyEffect`** — one remote, one call site,
   all three modes. The old Blind-only special case in `TargetedSkillManager`
   was itself the reason ScrambleGlobal could never work: it's a Global cast,
   so it never went through that manager. New client
   `Controllers/ControlScrambleController.luau` re-issues `Humanoid:Move` at
   `RenderPriority.Character` (just after PlayerModule's `Input` binding);
   **it can't oscillate because PlayerModule rewrites MoveDirection from raw
   input at the start of every frame**. Verified live: W 0° -> 180°, D 270°
   -> 90°, Randomize re-rolling 90/180/270 and never 0.
   - **Gap found and fixed while testing:** Dispel (and the cap+1 immunity
     sweep) stripped the effect server-side while the client kept remapping
     input for the rest of the duration. Both now send a duration-0 cancel.
4. **All negative buffs re-measured live**: Slow 16->6.4, SlowGlobal 16->8,
   Weight JumpPower 50->15, Shock WalkSpeed AND JumpPower 0 + stunned, Blind
   blur present then gone — every one fully restored on expiry.
5. **Full effects/sound/VFX pass.** 10 new sound ids (all load-verified
   first), 6 new burst helpers, plus a cast wind-up and a homing energy orb.
   Newly noisy: every checkpoint (7 of 8 were silent), life loss (which had
   NO feedback of any kind), respawn, zone-hazard burns, falling-block
   impacts, all pickups, and the Grand Prix countdown.
   - **The documented `CastSkillDirect` gap was wider than recorded** — the
     sound was missing too, in both Self and Target managers. Fixed by giving
     them `GlobalSkillStateMachine`'s shape: sound/VFX in the shared
     `resolveAndApply`, not in `tryCast`.

**Still open after this round:** a real Target cast end to end (wind-up ->
orb -> effect landing) and last-man-standing both need a genuine second
Player; and the chunk-37 Desert-wind bug is NOT fixed —
`MovementModifier.recomputeForPlayer` early-returns while
`walkSpeedOverrideUntil` is active, and the wind is now a constant override,
so every effect-driven WalkSpeed change is silently ignored on Desert
segments.

**Process note worth keeping:** reading `StarterPlayer.StarterPlayerScripts`
through the **Edit** DataModel gives a stale, misleading picture — it showed
a months-old snapshot (missing a dozen modules, containing one that no longer
exists on disk) while the code was in fact syncing perfectly. Check the
**Client** DataModel during Play instead. A round of debugging and a
needless `rojo serve` restart went into that.

**Previous round (2026-08-02) (session: full live sweep + "map is above ground" root cause + real Grand Prix lifecycle, then a 12-chunk playtest-feedback round. **See `WORK_PLAN.md` for the chunk-by-chunk status of that round — it is the resume point if work is picked up mid-way.**)

**Newest round (2026-08-02) — playtest feedback, worked as 12 numbered chunks
with progress checkpointed to `WORK_PLAN.md` after each (explicit user
request: "divide work in smaller chunks and save progress so it will be easy
to continue later"). All 12 chunks DONE and live-verified; full per-chunk
evidence lives in `WORK_PLAN.md`, summarised here:**
1. **Ground** — `TerrainGroundBuilder.GROUND_MATERIAL` Grass → Ground (Roblox's Grass renders 3D blades that read as an open field, not a stadium apron).
2. **Join buttons split back apart** — centre action button reverted to plain "JOIN RACE" (arcade entry only); new `JoinGrandPrixButton` in `LeftMenuBar` below ROBUX SHOP, a real **toggle** (join / opt back out) via new `Network.Hub.ToggleGrandPrixEntry`. The client never decides its own joined-ness: it fires "toggle" with no args and renders the boolean the server fires back, so a refused mid-race opt-out or a roster wipe can't leave the button lying. Reason for the split: a momentary state-driven button can express "put me on the track now" but has no way to express opting back OUT of a sign-up.
3. **Grand Prix start now owns the track** — at Countdown, anyone `InRace` who did NOT join is returned to the Hub (`clearNonParticipantsFromTrack`); players off the track are untouched. Free-run entry is refused for the duration via `ArcadeManager.SetTrackClosedCheck` — a registered predicate, not a require, since GrandPrixManager already requires ArcadeManager. **The REMOTE is gated, not `EnterTrack` itself**, because Countdown uses `EnterTrack` to place its own racers.
4. **Start-line clustering fixed + on-screen countdown** — `startGridOffset()` lays racers 5 to a row, 12 studs apart, rows 10 studs back (everyone previously spawned on one identical CFrame and shoved each other off the line). Countdown renders in the JOIN GRAND PRIX button, driven off a monotonic client clock — `COUNTDOWN_SECONDS` now ships with `GrandPrixStateChanged` so there is no server-time skew to reconcile.
5. **Climb walls span the full track width** (`SegmentWidth + 2*BarrierThickness`) so climbing is forced; IceFrost keeps its `halfWidth` override since its water lane IS the alternative route.
6. **Jump platforms were an impossible route, not an optional one** — they sat in a single XZ column, so jumping from one hit the underside of the next. Now an alternating ±9 zig-zag with a forward walk-in, and the count derives from `JUMP_PLATFORM_MAX_RISE = 5` (under Roblox's ~7-stud jump).
7. **Volcanic rod now sweeps across the track** (barrier to barrier) instead of along it — travelling along the direction of travel meant it just drifted alongside runners. Confirmed non-lethal by construction: never registered with `ZoneHazardMonitor`, which is the thing that makes magma/neon blocks cost a life.
8. **Lava** — flush with the road's top face (was a 4-stud slab standing proud of it), colour (255,34,0), and 5 staggered patches per straight / 3 per curve instead of one slab, so it forces repeated direction changes.
9. **NeonCircuit** — interval 6-9s → 2.5-3.5s and 3 blocks per wave, each on its own thread (inline would re-serialise the wave, since `dropBlock` yields for its own telegraph).
10. **Desert wind is now constant**, re-applied every 1s to every live Desert segment, with a separate loop flipping it to a tailwind for 5s every 12-22s. Previously an occasional gust, which meant most crossings had no wind at all.
11. **WaterDock** — bridges 4 studs wide (was 8) and built from 3 jogging planks per lane instead of one straight slab. **Also closed a real bypass the new ground had introduced**: the pool was only 80% of the segment width, and the leftover 10% strip each side — harmless open void before terrain existed — had become walkable dry land. Pool widened to the full `SegmentWidth`.
12. **SkyRail** (user hadn't seen it) — confirmed generating: 4 bridges at Y=10, 36 studs wide on a 72-stud track, zero road left. Falling through a gap OR off the side drops to the Baseplate at Y=-47, crossing the -40 fall-out threshold on the way, so it costs a life and respawns at the last checkpoint (0 lives → revive window → Hub).

13. **Lava now GLOWS** — recolouring alone hadn't been enough ("still looks the same as ground"): `CrackedLava` is a matte, heavily-textured material, so a flush patch of it reads as differently-coloured dirt, and making it flush (the fix that made it play correctly) is what removed its last silhouette cue. Switched to `Neon` — the same full-emissive material the skill pickups use, so it reads as hot from any angle and distance — at (255,30,12).
14. **Traveling rod → a rank of 4 perpendicular sweepers.** Recoloured to match the rotating hazard bars exactly (Neon, (255,140,0)) since both are "solid moving thing that shoves you, costs nothing" and should teach the same lesson. Travel and orientation are now the opposite of what chunk 7 built: bars span the track WIDTH and slide ALONG the road. Key detail: a bar's local X is its length and a segment CFrame's X is the track's lateral axis, so spanning the width needs NO rotation — the old `CFrame.Angles(0, 90°, 0)` was exactly what had turned it the wrong way. Four bars at quarter-cycle phase offsets, 75 studs long on a 72-stud track (a stud into each barrier, so no edge gap).
    - **Bug found while verifying:** the bars must be unanchored to shove players, and `AlignPosition` pins position only — yaw was already drifting to 0.94 (vs 1.00 perpendicular) within seconds of spawning, with no player contact, and a collision would twist one into a diagonal with a gap at the barrier. Added `AlignOrientation` + `RigidityEnabled` alongside the existing position constraint. Re-verified with a deliberate angular-velocity shove: worst dot over 6s = 1.000 across all four.

15-17. **SkyRail rebuilt + the three bare-curve themes filled in.** The SkyRail straight's transition was genuinely impossible: the whole road was destroyed and bridges simply began at Y=10, so a player arriving at road level met a 9-stud rise across an 18-stud void. The route is now continuous — solid road, a walkable step flight (1.6-stud rises, under Roblox's ~2-stud auto-step), the elevated span, steps back down, solid road — with only the elevated middle carved underneath. Bridges narrowed 50% → 28% of track width, and 2 vertically-oscillating platforms sit mid-span. **IceFrost, WaterDock and SkyRail curves were completely bare** because a Curve's floor is N separate `RoadChord_N` parts rather than one slab, so `destroyRoadForRebuild` found nothing and those builders just returned early. New `removeMiddleCurveChords` helper makes curve road surgery possible: SkyRail curves get a half-width drop with a laterally-sliding platform and a solid ledge on the other half; WaterDock curves get real full-chord-width water; IceFrost curves get a full-width non-phaseable ice wall.
18. **One-time segment notice per run** (new `SegmentAnnouncer.luau`). Entry is derived from checkpoints rather than a new spatial poll — checkpoint N is segment N's exit, so passing N is exactly the moment of entering N+1 — via a new `CheckpointValidator.SetCheckpointReachedHandler`. Announced once per segment per run (cleared when PlayerState becomes InRace), because the oval is a loop and a 2-lap Grand Prix would otherwise fire the same eight notices twice.
19. **Grand Prix timer under the join button**, doubling as the event clock (next-GP wait / start countdown / remaining race time). Server broadcasts (state, secondsRemaining) every 5s and the client ticks locally between updates, so digits move once a second without a per-second remote fire per player.
    - **Two bugs caught here, neither of which `rojo build` can see.** (a) `broadcastState` called `broadcastTimer` before its `local function` declaration — resolves to nil at runtime, builds clean. (b) `secondsRemainingInState()` returned the `COUNTDOWN_SECONDS` constant instead of real remaining time, so every periodic broadcast reset the client deadline and the countdown jittered UPWARD (0:12, 0:13, 0:10, 0:12, 0:14). Only visible because the timer re-broadcasts on a cycle; a one-shot state change would have hidden it.
    - **Process note:** `rojo serve` died silently mid-round. Chunks 18/19 were clean on disk and built fine but never reached Studio, and the first live check just found the new label absent. A clean `rojo build` says nothing about whether Studio has the code — check `http://localhost:34872/api/rojo` first when a brand-new instance turns up missing.

20-24. **Variety fix + first half of the "juice" pass.** Theme picking forced from 2-4 to **exactly 4 distinct** (a generation could previously land the same theme on multiple pairs, which is what made a lap feel monotonous) — verified over 10 generations, all 4-distinct with pairs intact. Segment notices now skip a segment whose theme matches the one just left, so a lap gives 4 notices (one per themed pair) instead of 8. **Sound system**: new `Configs/SoundEffects.luau` (ids keyed by meaning), server `SoundDirector` and client `SoundController`, split by nature — a skill cast is a world event so its Sound is created server-side on the caster's part (spatialised + replicated free, no remote), while a cash-register ding is personal and goes over `Network.Track.PlaySound` to one client. All 8 third-party asset ids were **verified to actually load** (`IsLoaded` + real `TimeLength`) before being trusted, since Roblox audio permissions otherwise produce a Sound that silently never fires. **Target gating turned out to be a real bug, not just a missing message**: the cooldown was consumed before targeting and `resolveAndApply` then silently returned on a nil target, so casting with nobody in range cost the full cooldown, did nothing and said nothing. The check now precedes `CooldownTracker.TryConsume` — verified live that a target-less cast fires no `SkillCastResult` at all.

27-28. **HUD sizes + practice dummies.** The "icons and action buttons look smaller" report turned out NOT to be a code change — nothing in the previous round touched `BottomRight`, the skill buttons, their icons or `CenterAction`, and all are still at the enlarged values from the earlier "bigger buttons" round. They are sized purely by SCALE, and the Studio viewport had shrunk 1143x573 → 984x384 between sessions, so 0.42 × 384 gave 161px instead of 241px and the buttons rendered 51px instead of ~77px. There was nothing to revert; fixed properly with `UISizeConstraint` pixel floors (76x76 per skill button, 240x46 on CenterAction), verified restoring 51→76 / 43→64 / 216x30→240x46 at the small viewport, and now immune to the same issue on any small screen. New `PracticeDummyService` spawns 3 real R6 noob rigs (proper Motor6D joints, not a Part with a Humanoid bolted on) that follow the live checkpoint ring as waypoints. **First live run exposed that `Humanoid:MoveTo` has no pathfinding** — two of three walked into a WaterDock pool and sat there Swimming with zero progress; added a two-stage unstick (jump at 2s pinned, skip waypoint at 6s), after which all three travel continuously (246/303/362 studs in 30s).

**Critical for the next session — chunk 29 is the real work and is NOT started:** spawning dummies does not make them targetable. `TargetedSkillManager.findNearestTarget` resolves candidates through `Players:GetPlayerFromCharacter`, which returns nil for an NPC, so a dummy can never currently be acquired. `EffectStackManager`/`ProfileManager`/`PlayerStateService`/every `FireClient` are Player-keyed and Roblox offers no way to fabricate a Player, so the NPC path must be explicit. Suggested shape is in `WORK_PLAN.md`. Chunk 30 (live-testing all casts) is blocked on it for Target skills; Self and Global casts are testable today.

29-32. **Cast VFX wired and tested; all temporary summons removed.** New `CoreGameLoop/VisualEffectsService.luau` — phase translucency, shield bubble, buff/debuff Highlight aura, speed trails, the PositionSwap purple arc, and cast bursts. Built server-side rather than over remotes because Highlight/Beam/Trail/ParticleEmitter/Transparency all replicate on their own, so every observer stays in sync for free and an effect can't disagree with the server state that caused it. Two deliberate details: the phase translucency rides the *same* expiry guard as the collision-group revert (so the look can never outlast the actual pass-through), and the aura fires only after an effect is genuinely accepted into the stack — every early return (immune, capped, unknown) must not light the player up, or it would advertise a debuff that never landed. The swap arc is a textureless Beam on purpose, which sidesteps the third-party-asset moderation risk the audio pass had to verify around. All six verified individually and again through the real cast path, and all confirmed self-cleaning. **Temporary scaffolding removed**: the `IsPracticeDummy` targeting fallback is gone (grep-confirmed), and `PracticeDummyService.DUMMY_COUNT` is 0 so no dummies spawn (verified live). The module is retained but inert as the testing rig chunk 29 will need. **Also fixed a regression I introduced**: chunk 27's 76px button floor made the three skill buttons overlap by 19px, and the first correction grew the frame downward into the corner Roblox draws the mobile jump button in — `BottomRight` is now anchored by its bottom edge with floors sized to fit, leaving 44% of screen height clear below it.

**Known gap:** `ShowCastBurst` is wired into `tryCast` but not into the managers' `CastSkillDirect` (the "release a carried skill pickup" path) — confirmed live that a CastSkillDirect ShieldSelf gives the bubble but no burst.

**Superseded:** chunks 25-26 in `WORK_PLAN.md` — player state visuals (phase transparency, shield bubble, buff/debuff duration markers, trails) and cast VFX (the ~0.5s purple lightning arc for PositionSwap, plus bolt/orb flourishes).

**Still open after this round:** last-man-standing race end (needs a real second Player, impossible solo); Desert wind not separately measured live (it's a `WalkSpeed` override, no geometry to assert on); Grand Prix reward values are deliberate placeholders.

**Previous round (2026-08-02)** (session: the full live sweep the round below was waiting on — Studio MCP reconnected — plus the real root cause of "map is above ground", and a real Grand Prix race lifecycle.)

**Newest round (2026-08-02) — "live testing of track segment generation and
cycle through arcade and grand prix / check cause of issue where map is
above ground", then a follow-up decision to build the Grand Prix out for
real. Studio MCP is BACK; everything below is live-verified unless
explicitly flagged otherwise:**

1. **Closed the previous round's entire unverified backlog, live.** All 8 themes forced one at a time and inspected per segment: every theme builds without error, and **every hazard now sits on real paved road (worst off-road distance 0.0)** — the `segmentCenter` curve fix from the previous round is confirmed working. The only non-zero distances are `WaterDockBridge` (22.5) and `SkyRailBridge` (∞), both by design since those span gaps where `Road` was deliberately destroyed. The **checkpoint-refresh fix is also confirmed**: 3 back-to-back regenerations through the real singletons, checkpoints registering by real sub-threshold movement before and after each, `RefreshCheckpoints`/`RefreshTrackGeometry` repointing at the new instances every time (old ones confirmed `Parent = nil`).

2. **ROOT CAUSE of "map is above ground": the Baseplate was doing two contradictory jobs at once.** Measured live — everything built occupies Y ≈ 0..23 (road top +1, barriers +10, fan stands +23), and a raycast straight down anywhere off the track hit `Workspace.Baseplate` at **Y = -47**. A 47-stud empty void under the entire world, nothing in between. The chain: `TrackGenerator` has to keep the Baseplate far below the track or it plugs every hazard needing a real ground-level gap (WaterDock/IceFrost pools, SkyRail bridge gaps) — but that same Part was also the only ground in the place. The previous round's -150 → -55 pass shrank the void without removing it, and it was pinned there by `TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD = -40`.
   - **Fix: new `TerrainGroundBuilder.luau` gives the visible-ground job to real Terrain**, freeing the Baseplate to be purely a safety floor (now also resized to the ground's own footprint, since a stock 2048x2048 plate sticking out past the grass would just move the same floating-island look to the map's outer boundary). `Rebuild()` runs at the top of every `GenerateOval`, before any piece exists, and **replaces `ThemeHazardBuilder.ClearAllTerrainWater()` outright** — one `FillBlock` rewrites material AND occupancy for every voxel it covers, so it wipes the previous generation's water and chasms in the same pass that lays fresh ground (~0.03s measured, free to run every regeneration).
   - **Two measured Roblox Terrain gotchas, both of which cost a debugging round:** (a) a SOLID material renders its surface **2 studs above** the top face you hand `FillBlock` (calibrated across fill tops 0/-1/-2/-3/-4/-6 → 2.00/1.00/0.02/-0.98/-2.00/-3.98). First attempt put the ground at Y=2, one stud OVER the road's top face, burying the track edge in grass. **WATER is the exception** — it renders exactly at its own fill top (water topped at 0 measured 0.00 against adjacent grass at 0.02), so pools must NOT apply the correction. (b) **`FillBlock(..., Water)` into solid terrain is silently a complete no-op** — water is a separate per-voxel channel and a fully-occupied voxel has no room for it. The instant real ground existed, every WaterDock/IceFrost pool vanished. `fillWaterBlock` now clears its own volume to Air first, which carves the basin (surrounding grass becomes the walls, grass below becomes the floor) and gives the water somewhere to go.
   - **SkyRail is the one theme that has to carve the ground back out** (`TerrainGroundBuilder.CarveChasm`, full segment width so stepping off the side of a bridge drops you too) — otherwise the new ground would catch a gap-faller ~10 studs down and quietly delete the mechanic.
   - **All live-verified after the fix:** ground surface at Y = 0.02 (1 stud under road top) across infield/shoulder/outside-stands; WaterDock and IceFrost water surfaces at exactly 0.00, flush; player genuinely `Swimming` in a pool (12/12 samples); SkyRail gap-fall measured with a Heartbeat logger reaching **minY = -43.6**, crossing the -40 threshold, costing a life (1 → 0) and respawning back on track at Y = 4.8. Screenshots confirm the stadium sitting on grass to the horizon, no void.

3. **Grand Prix was never able to run at all — `enterEnded()` was defined but called from nowhere.** No Racing → Ended transition existed, so the race started (hourly) and stayed in Racing forever, and `TrackGenerator.Regenerate` inside `enterEnded` was unreachable in real play. Rebuilt per explicit spec ("5 mins time limit for 2 laps; or end immediately with last man standing, temporarily set rewards for last 5 standing and first 5 finishers; grand prix every 30 mins with existing button join race becomes join grand prix"):
   - Interval 60 → **30 minutes**; new `RACE_TIME_LIMIT_SECONDS = 5 * 60`, `GRAND_PRIX_LAPS = 2`. Race ends on ANY of: all remaining racers finished, last one standing (guarded on `rosterCount() > 1`), nobody left, or time up.
   - **Who is "standing" is deliberately NOT tracked separately.** ArcadeManager already owns lives, the revive window and the return-to-Hub; the single observable outcome of all of it is PlayerState leaving InRace, so `reapEliminatedRacers` just polls that. No new plumbing, and no way for two views of "eliminated" to disagree.
   - **Lap counting comes from `CheckpointValidator.SetLapCompletedHandler`** — a registered callback, not a require, because GrandPrixManager already requires CheckpointValidator for `RefreshCheckpoints` and requiring back would be a genuine cycle.
   - Two independent 5-deep reward ladders in `EconomyRates` (`GrandPrixFinisherRewards` / `GrandPrixSurvivorRewards`, **provisional values, not balanced**); a racer who both wins and outlasts everyone draws from both on purpose. Both now honor the DoubleFans game pass, matching the two pre-existing Gold/Fan reward sites.
   - `ActionButtonController`'s InLobby label → **"JOIN GRAND PRIX"** (mode/remote/ArcadeManager path all unchanged — pressing it now also enrols the player in the roster). `LiveRaceHUD` standings entries gained lap/eliminated/finish-place suffixes, all optional fields.
   - New `GrandPrixManager.StartRaceNow()` (server-only, on no remote) — a 30-minute cadence is otherwise untestable and unadministrable.
   - **Live-verified end to end:** real JOIN remote fired from the client enrolled the player AND put them InRace (both listeners); StartRaceNow → Countdown → Racing with `raceEndsIn = 299s`; 2 real laps driven checkpoint by checkpoint → `LapsCompleted = 2`, `FinishPlace = 1`, race auto-ended, payout **+840 Gold / +420 Fans** (500+300 placement, +40/20 doubled lap rewards — matches exactly once DoubleFans ownership was confirmed), state returned to Waiting with `nextRaceIn = 1799s`, track regenerated to 8 pieces / 8 checkpoints, roster cleared.
   - **NOT live-tested: the last-man-standing end condition** — it requires a genuine second Player in the server, which a solo Studio session can't provide. Logic reviewed only.

4. Validation: `rojo build` clean after every edit; ambiguous-syntax scan (`^\s*\(`) across `src/` found only the known doc-comment false positives plus 3 continuation lines inside a `CFrame.new(` call in `TerrainGroundBuilder`, none statement-initial. All temporary test scripts were runtime-injected `Script` instances (a better pattern than temp files on disk for this: they run in the REAL server VM and share the real module cache, then vanish with the session) — all confirmed destroyed, and a disk scan confirmed no `_TEMP_*` files were ever written.

**Previous round (2026-08-02)** (session: built real per-theme hazard geometry/mechanics for all 8 TrackThemes — previously cosmetic-only reskins — then found and fixed several real bugs the new geometry exposed, including a pre-existing, unrelated checkpoint-caching bug the user separately reported, and then a severe curve-placement bug ("map appears to be floating, hazards not on their segment") the user reported next. Live-testing was cut short by the Roblox Studio MCP connection dropping partway through the round and has NOT reconnected since — every fix below this point was done via static code review only, none re-confirmed live. This is the top priority next: a full live sweep of all 8 themes, the Arcade→GrandPrix→regenerate cycle, and the checkpoint-refresh fix, the moment Studio access returns.)

**Same-round follow-up (2026-08-02) — user report: "entire map appears to be
on the air, falling hazards are not falling on designated segment" — found
via code review (Studio still disconnected), NOT live-verified:**
1. **Root cause, severe: curve-segment hazards were positioned using a straight-line Lerp between entry/exit CFrames — correct for Straight segments, badly wrong for Curve ones.** A Curve segment's entry/exit CFrames are the two ends of a 90° arc; `CFrame:Lerp` between them cuts across the CHORD connecting those ends, not any point on the actual curved road. For this project's 180-stud-radius 90° curves that's a sagitta of ~53 studs — bigger than the road's own 36-stud half-width — so every hazard placed this way on a curve (Classic's 2 side-by-side bars, Volcanic's magma pool, NeonCircuit's block spawner) landed floating well off the visible paved `RoadChord_*` parts entirely. This is almost certainly the dominant cause of both symptoms: hazards visibly detached/"floating" off curve segments, and NeonCircuit blocks falling somewhere that reads as the wrong segment. `ThemeHazardBuilder.luau`'s new `segmentCenter(segment, entryCFrame, exitCFrame)` replaces the naive Lerp for these 3 call sites — for Curve segments it samples `TrackPieceBuilder.SampleCurve` (the exact function the curve's own `RoadChord_*` parts were built from) and takes the middle chord, guaranteeing the result sits exactly on real paved road. HillMud/WaterDock/IceFrost/SkyRail were already unaffected (HillMud's curve walls anchor directly off `entryCFrame`/`exitCFrame`, the real ends of the arc; the other three are Straight-only).
2. **Contributing factor: the Baseplate safety-net relocation from the previous round was too deep, reading as "the whole map is floating."** `TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD` lowered -100 → -40 (still comfortably below every real hazard's max depth — 8-stud water — and below SkyRail's 10-stud bridge height, so a fall through a SkyRail gap is still a genuine, visible ~50-stud drop before the violation fires) and `TrackGenerator.BASEPLATE_SAFETY_Y` correspondingly raised -150 → -55 (just below the new threshold, so an InRace player's fall-out violation still always fires before they'd ever reach it). Net effect: the map now sits much closer to its safety floor without weakening any hazard's actual fall-to-violation mechanic.
3. `rojo build` clean after these changes. **Not yet live-verified** — needs the same full 8-theme, per-segment sweep as the rest of this round once Studio reconnects.

**Newest round (2026-08-02) — critical update: real hazard mechanics for all
8 TrackThemes ("current spawning curve and straight version... use rojo
again, test each segment thoroughly, test respawning/replacement of track,
adjust and test onset of game (arcade) to grand prix then new track
generate for arcade to grandprix cycle of map generation"), plus a
separately-reported "checkpoint broke" bug found and fixed mid-round:**
1. **New modules**: `ZoneHazardMonitor.luau` (shared "standing in this volume costs a life" poll, reused by Volcanic's magma pool and NeonCircuit's landed blocks — both just call `ArcadeManager.HandleTrackViolation`, the same respawn path `TrackBoundaryMonitor` already uses), `ThemeHazardBuilder.luau` (one builder per theme, dispatched by `TrackGenerator.GenerateOval` for every segment instead of the old random-2-segment generic bar), `DesertWindService.luau` (periodic tailwind/headwind push via `MovementModifier.SetWalkSpeedOverride` — deliberately not a raw velocity impulse, since Humanoid's own controller stomps those within a frame, the same gotcha Dash/ChargedJump hit earlier this project).
2. **Per-theme mechanics, built to reuse Roblox's own state machine instead of new plumbing**: Climbing walls are real `TrussPart` rows (Roblox auto-enters `Humanoid.Climbing` on contact — confirmed live via real `Humanoid:MoveTo` movement into a wall, which is what finally resolved an earlier-session open question; a raw `Humanoid:ChangeState` call does NOT reliably trigger it, real movement input does). Water is real `Terrain:FillBlock(..., Water)` (Roblox auto-enters `Humanoid.Swimming`). Phaseable hazards reuse `CollisionTags.MarkPhaseable`. Classic/Volcanic bars reuse the project's established anti-drift pattern (`AlignPosition.RigidityEnabled` + Heartbeat-reasserted velocity/position).
3. **Bug found live-testing: WaterDock/IceFrost water was completely inert.** Terrain water and the cloned template's `Road` Part are two independent systems — pouring water under a still-intact full-segment Road slab is invisible to players, who just keep walking on the solid Road above it (confirmed: teleporting into a pool's exact XZ footprint landed the player standing on Road, terrain read Air not Water at that spot). Fixed by having both themes actually destroy the segment's `Road` and rebuild only the dry portions as separate strips around the water's footprint (mirroring how `buildSkyRail` already destroys+replaces Road for its bridge gaps). Live-confirmed after the fix: `Humanoid:GetState()` genuinely reports `Swimming` in both themes' water.
4. **Bug found live-testing: HillMud/IceFrost climb walls could be walked straight through.** `createClimbWall`'s poles (`TrussPart`'s X/Y are hard-clamped to 2 studs by the engine regardless of what's set — confirmed live) were spaced 4 studs apart, leaving a 2-stud open gap between each 2-stud-wide pole — enough for a player to walk through without ever climbing, defeating "climb only." Fixed by tightening `poleSpacing` to 2 (poles now touch/overlap, no gaps). IceFrost's wall was also widened to span its full half of the segment (was ~40% with dry strips on both sides a player could walk around through) — now split exactly 50/50 with the water lane, no way past either hazard undetected.
5. **Bug found live-testing: Volcanic's magma zone never actually caught a standing player.** `ZoneHazardMonitor`'s life-loss check tests whether the player's `HumanoidRootPart` position falls inside the zone Part's bounds — but the decorative magma pool Part was only 4 studs tall, positioned right at road height, while a standing player's rootpart sits several studs above their feet. The zone's own vertical band never actually reached rootpart height, so lives never dropped standing directly in the pool. Fixed by adding a separate, taller (40-stud) invisible zone Part registered with `ZoneHazardMonitor` instead of the visual pool itself — same generous-height fix pattern `TrackGenerator`'s own checkpoint triggers already use.
6. **Root cause found for water/gap hazards more broadly: a leftover Studio default `Baseplate` Part (2048x16x2048, top at Y=0, unreferenced anywhere in the codebase, not Rojo-managed) sat under the entire map, silently catching every fall-through hazard before players ever reached the intended water/void beneath.** Fixed durably in `TrackGenerator.Init()` (`relocateLegacyBaseplate`) — relocated (not destroyed) to Y=-150, well below `TrackBoundaryMonitor.FALL_OUT_Y_THRESHOLD` (-100), so it still exists as the map's fall-through-the-void safety net for non-InRace players wandering the Hub/FanBox area (which has no Y-based fall check of its own) while no longer interfering with any hazard's ground-level gap. Deliberately done as real source code, not a one-off manual Studio scene edit — the latter would silently revert on an unsaved session or fresh place file.
7. **Separately-reported "checkpoint broke" bug — root cause found via code review** (Studio disconnected before this could be live-replayed): `CheckpointValidator`/`TrackBoundaryMonitor` each cache their own reference to the Track's checkpoint parts / centerline point-cloud exactly once, in `Init()`, at server start — but `GrandPrixManager.enterEnded()` calls `TrackGenerator.Regenerate(workspace)` after every real Grand Prix, which destroys the whole `Track` folder (including every checkpoint Part) and builds a new one. Neither cache was ever told to refresh, so both silently kept validating against destroyed instances after the first Grand Prix — reads off a destroyed Roblox Instance don't error, `Destroy()` only sets `Parent = nil`, so this was "working" only by coincidence (the oval's geometry is deterministic/identical every regen). Fixed by adding `CheckpointValidator.RefreshCheckpoints()` / `TrackBoundaryMonitor.RefreshTrackGeometry()`, both called right after `TrackGenerator.Regenerate(workspace)` in `GrandPrixManager.enterEnded()`. This is a pre-existing bug independent of this round's theme-hazard work, not something the new hazards caused.
8. **`rojo build` clean after every edit this round** (checked repeatedly as fixes landed). **NOT yet re-verified**: a full live sweep of all 8 themes post-fix, an actual Arcade→GrandPrix→regenerate→Arcade cycle with the checkpoint-refresh fix exercised for real, PhaseSelf pass-through vs IceFrost's non-phaseable wall, and Desert/NeonCircuit/SkyRail's specific behaviors in motion — the Roblox Studio MCP connection dropped mid-round before these could be run. `rojo serve` is running (localhost:34872) so Studio can sync immediately once reconnected.

## 0. Start here
Standing risks from prior sessions, still true: (1) the Luau "ambiguous
syntax" bug (statement starting with `(` right after another statement) —
re-scan with `rg '^\s*\(' src/` before calling anything done, `rojo build`
does NOT catch this; none found this round (all matches were inside `--[[
]]` doc comments — checked by hand). (2) Nothing in this codebase has had a
confirmed, full, successful Play test since the Rojo root-cause fix —
that's still the top priority, now with even more surface area to verify
(see section 4). (3) `TrackPickupSpawner.GetNearbyPickup` (Fan Payloads — a SEPARATE module from SkillPickupSpawner, not touched this round) returned `nil` for every live `FanPayloadPickup` part in the workspace when tested directly last round — still not investigated; worth a real look before next relying on the Fan Payload pickup flow end-to-end. (4) Reconfirmed hard this round: `execute_luau`'s `require()` always returns an independently-initialized module copy, never the real running server/client instance — for ANY module with meaningful module-level state (a populated list, a `pickups`/`activeEffectsByPlayer` table, a `walkSpeedOverrideUntil` map), testing via a bare `execute_luau` call proves nothing about the real game; several dead-end "bug" investigations this round (see round below) turned out to be exactly this pitfall, not real bugs. The reliable pattern remains: write a genuine temporary `_TEMP_*.server.luau` file that syncs via `rojo serve` and runs as a real Script (shares the real module cache), or exercise the real code path via actual remotes/gameplay — then delete the temp file.

**Newest round (2026-08-02) — direct follow-up: "picking up skill gets the
one beside it instead on the one in front, move spawned skill further
apart and reduce event range for pick up to ensure you get skill in
front" / then implementing real behavior for 6 skills ahead of planned
water/climbing track additions — SwimBurstSelf, ClimbGripSelf, ShockTarget,
BlindTarget, WeightTarget, PhaseSelf:**
1. **Skill pickup mistargeting — the actual bug** (`SkillPickupSpawner.luau`): `GetNearbySkillPickup` returned the FIRST available pickup within `PICKUP_INTERACT_RADIUS` in table-iteration order, not the nearest, despite its own docstring already claiming "nearest" — with 3 pickups only `LATERAL_SPACING` (6 studs) apart and a 9-stud radius, standing at the middle pickup put a player in range of BOTH neighbors too, so whichever happened to sit earlier in the `pickups` array won regardless of which one was actually in front. Fixed the function to genuinely scan every in-range candidate and keep the closest. Also widened `LATERAL_SPACING` 6→12 and shrank `PICKUP_INTERACT_RADIUS` 9→5 so in practice at most one pickup is ever in range at all. Live-verified against the real running module (a temporary `_TEMP_PickupTargetingTest.server.luau`, deleted after): querying at each of 3 real markers' own positions returned exactly that marker's own skill every time, not a neighbor's.
2. **SwimBurstSelf / ClimbGripSelf / WeightTarget — already correct, verified by reading, no code change needed.** `MovementModifier.recomputeForPlayer` already branches on `Humanoid:GetState()` (`Swimming`→SwimSpeed, `Climbing`→ClimbSpeed, else→WalkSpeed) and only that one stat's net multiplier gets written to `Humanoid.WalkSpeed` (Roblox has no separate native swim/climb speed property) each tick — so SwimBurstSelf/ClimbGripSelf's buffs are already inert while walking and only kick in during the matching state, exactly as intended for future water/climbing tracks. `WeightTarget` already declares `AffectsStats = {JumpPower, ClimbSpeed}` in `SkillEffects.luau`, so its climb-speed reduction (not just jump power) was already wired — confirmed via code reading, not a gap.
3. **ShockTarget — now actually immobilizes.** Previously only reduced `WalkSpeed` via its own near-zero magnitude multiplier (a strong slow, not a hard stop) and never touched `JumpPower` at all, so a "stunned" player could still jump away. `MovementModifier.recomputeForPlayer` now checks `EffectStackManager.IsStunned(player)` FIRST, before any multiplier math, and forces `WalkSpeed = 0` and `JumpPower = 0` while true. Live-verified against the real module via a temporary test script + a diagnostic print inside the real recompute loop: `WalkSpeed`/`JumpPower` genuinely hit 0 for the stun's duration and cleanly revert after.
4. **BlindTarget — now shows a real screen blur.** `ControlScrambleMode = "Blind"` was declared in `SkillEffects.luau` but nothing ever replicated it to the affected client — a completely dead code path. Added `Network.Combat.ApplyBlindEffect` (server→client, `durationSeconds`), fired from `TargetedSkillManager.resolveAndApply` only when a Blind-mode effect actually lands (checked via `EffectStackManager.TryApplyEffect`'s own return value, so immune/capped casts correctly don't blind anyone). New client `BlindEffectController.luau` adds a `Lighting.BlurEffect` (Size 24) for the duration, extending rather than stacking a second one if re-cast before the first expires. Deliberately a `BlurEffect` and not a ScreenGui overlay: it blurs only the rendered 3D viewport — every HUD `ScreenGui` composites on top of the already-blurred frame, so buttons/capsules/panels stay perfectly sharp with zero extra bookkeeping to "exclude UI," exactly "blurs the background/view, buttons and other elements stay visible." Live-verified via `screen_capture` with a 60s test duration (short durations kept expiring between tool round-trips during debugging, which is what several of the dead-end investigations turned out to be, not real bugs — see section 0): world/ground/character clearly blurred, HUD elements crisp.
5. **PhaseSelf — now actually phases through hazards, not just a no-op immunity grant.** `PhaseSelf`'s `LinkedEffectId` has `GrantsImmunity = true`, so it only ever granted general "Bad" debuff immunity (via `EffectStackManager`'s existing immunity branch) — it never touched collision at all, so "phase through hazards" was pure flavor text. New `ReplicatedStorage.Configs.CollisionTags.luau`: registers two `PhysicsService` collision groups ("Hazards", "PhasingPlayers") as non-collidable with each other at module top level (runs once, first require, Luau-cached) and exports `MarkPhaseable(part)` — the one call site any current or future phaseable obstacle should use, tagging it with a `CollectionService` tag (`"PhaseableHazard"`, satisfying "must have proper tag so it can be recognized") AND setting `CollisionGroup = "Hazards"` (the actual physics mechanism — a plain `CanCollide = false` would disable collision for EVERY player, not just the phasing one). `TrackGenerator.addHazardBar` now calls `CollisionTags.MarkPhaseable(hazard)` on every spinning hazard bar. `SelfSkillManager` special-cases `PhaseSelf` (same pattern as the pre-existing `DashSelf` special-case): `beginPhase` switches every part of the caster's character to the `"PhasingPlayers"` group for the skill's `EffectDurationSeconds`, then reverts to `"Default"` — guarded against an overlapping re-cast reverting early via a captured `expiresAt` timestamp comparison, same pattern as `MovementModifier`'s `walkSpeedOverrideUntil`. Live-verified against the real module via a temporary test script: a sample character part's `CollisionGroup` genuinely went `Default` → `PhasingPlayers` → `Default` across the cast/expiry cycle.
6. Full validation pass: `rojo build` clean; paren/brace balance confirmed on every touched file (`SkillPickupSpawner.luau` 60/60 13/13, `MovementModifier.luau` 29/29 3/3, `TargetedSkillManager.luau` 57/57 3/3, `BlindEffectController.luau` 24/24 1/1, `CollisionTags.luau` 16/16 1/1, `TrackGenerator.luau` 109/109 19/19, `SelfSkillManager.luau` 95/95 3/3); ambiguous-syntax scan across `src/` found only known doc-comment false positives; both temporary test scripts (`_TEMP_StunPhaseTest.server.luau`, `_TEMP_PickupTargetingTest.server.luau`) confirmed deleted, none left in the tree.

**Previous round (2026-08-02) — 4-part visual follow-up: "square buttons a
bit too small, make them bigger" / "while on race, picked up skills, add
corresponding icon on left side (null or no icon when carrying [fans], so
no need to touch)" / "for fans, spawn actual humanoid noob then carry above
player instead of in front" / "powers, make them colored red for
offensive, green self and purple global, maintain same glowing effect":**
1. **Bigger Skill1/2/3 buttons.** `BottomRight`'s own frame grew from `{0.13,0}x{0.32,0}` to `{0.17,0}x{0.42,0}` of the screen (repositioned to `{0.815,0}x{0.34,0}` so it stays fully on-screen), and each button's height fraction grew from `0.28` to `0.32` of that bigger frame — combined, roughly a 50% increase in the actual square's absolute pixel size. Y-band centers recalculated (`0.17`/`0.50`/`0.83`) to keep each button centered in its slot. Live-confirmed via `screen_capture`: visibly larger squares, still perfectly square, icons undistorted.
2. **Carried-skill icon on the center action button.** `CenterAction.ActionButton` gained an `Icon` `ImageLabel` (left-aligned, rounded) and a `SpellLabel` `TextLabel` (positioned after it) in `default.project.json`. New `ActionButtonController.refreshIconAndSpellLabel`: only in `ReleaseSpell` mode (carrying a picked-up track skill) — and only when that skill's `IconAssetId` is non-empty — does it hide the button's native centered `Text`, show the icon + `SpellLabel` (skill's `DisplayName`) instead. Every other mode, INCLUDING carrying a Fan Payload (`Deposit`/`Drop`), is untouched — no icon there, exactly as requested ("no need to touch"). Live-confirmed via `screen_capture`: while carrying `ScrambleGlobal` picked up mid-race, the button showed the scatter-arrows icon + "Track-Wide Scramble" label, not the old bare text.
3. **Carried Fan Payload — real noob instead of a floating ball, carried above not in front.** `CarryItemService.attachCarryVisual` previously welded a single gold Neon ball to the carrier's `HumanoidRootPart` at a `CFrame.new(0, 3, -2)` offset (3 up, 2 **in front**). Replaced with `buildCarriedNoob`, a small (`CARRIED_NOOB_SCALE = 0.55`) standalone rigged model — Head/Torso/2 Arms/2 Legs/HumanoidRootPart/Humanoid, same classic-noob proportions and coloring as `FanBoxCrowdTemplates`' crowd figures but built fresh here (not unioned — this one needs to stay a live, weldable rig, not a static CSG mesh) — welded to the carrier at a purely-vertical `CFrame.new(0, 4.3, 0)` offset, no forward/backward component, so it rides directly above the player's head. `carryVisualByPlayer`'s type changed from `{ [Player]: BasePart? }` to `{ [Player]: Model? }` and `removeCarryVisual` now destroys the whole Model (previously would have orphaned five of the six body parts, since only one part was ever tracked). Live-confirmed via `screen_capture` (a manual replica of the exact same construction code run directly against the live player, since the real pickup-detection path turned out to be blocked by the pre-existing stale-position issue noted in section 0): a correctly-proportioned, correctly-colored mini noob sitting right above the character's head, no forward offset.
4. **Skill pickup marker colors.** `SkillPickupSpawner.COLOR_BY_CAST_TYPE`: `Target` (every Target-cast skill is a debuff aimed at another racer — "offensive") changed from blue `(77,171,247)` to red `(255,61,61)`; `Self` stays green `(76,217,100)`; `Global` stays purple `(178,102,255)`. Both places a marker's color gets set (`buildMarker` at spawn, and the respawn branch inside `ConsumePickup`) read from the same table, so both paths picked up the change automatically. `Material = Enum.Material.Neon` (the actual source of the "glow") was untouched — only the `Color3` changed, exactly as asked ("maintain same glowing effect"). Live-confirmed via `screen_capture`: a red marker visible on-track alongside green ones.
5. Full validation pass: `rojo build` clean; paren/brace balance confirmed on every touched file (`CarryItemService.luau` 201/201 13/13, `SkillPickupSpawner.luau` 59/59 13/13, `ActionButtonController.luau` 95/95 4/4); ambiguous-syntax scan on `CarryItemService.luau` (most heavily rewritten file this round) found one match, inside its own top doc-comment block, not real code.

**Previous round (2026-08-02) — direct follow-up correcting 5 wrong icon
matches from the previous round, plus 2 visual fixes: "circle button has
square image inside - update to square buttons with rounded corner to fit
image", "use same square image ... in skill shop and during skill selection
in commercial hub", "robux shop should follow similar, square rounded
corner image prior to the corresponding item name and price":**
1. **5 icon reassignments** in `SkillTrees.luau` (a straight rotation among the previous round's mismatches): WeightTarget 88134249299942→`73524748013524`, SlowTarget 132950600217600→`88134249299942`, SiphonPulse 73524748013524→`132950600217600`, DashSelf 76409714687307→`96022776767443`, SwimBurstSelf 96022776767443→`94538165629087` (now intentionally the same winged-shoe icon as SpeedBoostSelf, per explicit "same as speed boost" instruction — DashSelf's old icon is now unused/spare).
2. **Skill1/2/3 HUD buttons**: `CornerRadius` changed from `{1,0}` (full circle — the previous round's square icon looked wrong clipped inside a circle) to `{0,14}` (rounded square) on all 3 buttons in `default.project.json`.
3. **Skill Shop panel** (`SkillShopController.luau` + its `EntryTemplate`): added a 36x36 `Icon` `ImageLabel` (UICorner `{0,8}`, rounded-square) to the left of each row, `NameLabel`/`LevelLabel` shifted right by a 50px offset (`Position [[0.04, 50], ...]`, `Size [[0.5, -50], ...]`) to make room. `renderEntry` now sets `refs.Icon.Image = skillDefinition.IconAssetId` every refresh.
4. **Skill Select modal** (`SkillLoadoutController.luau` + `SkillSelectPanel`'s `EntryTemplate`): identical treatment — same icon, same offset math, `Open()` now sets `icon.Image = skillDefinition.IconAssetId` per entry.
5. **Robux Shop panel — required a real fix, not just cosmetic tuning.** First attempt (rounding the existing `Icon` corners + `TextXAlignment = "Left"` + `UIPadding` on the button) looked broken when live-tested: `screen_capture` showed the button's own native `Text` rendering ignoring the `UIPadding` inset entirely and starting from the button's literal left edge, so the icon visually painted over the first ~48px of text ("Double Gain Fans and Gold" rendered as "e Gain Fans and Gold" — the icon wasn't overlapping the WHOLE text, just its own width's worth from the true left edge). Confirmed via `execute_luau` inspection (`AbsolutePosition`/`AbsoluteSize`/`Text`/`TextXAlignment` all correct at the data level) that this was a rendering behavior, not a data bug — Roblox's `UIPadding` does not reliably inset a `TextButton`'s own built-in `Text` property the way it insets `UIListLayout`-managed children. **Real fix**: button's own `Text` set to `""`, added a dedicated `Label` `TextLabel` child positioned explicitly after the icon (`Position [[0, 48], [0, 0]]`, `Size [[1, -58], [1, 0]]`, `TextTruncate = "AtEnd"`) — the same "separate positioned label, not native button text" pattern already proven correct in the Skill Shop/Skill Select entries. `ShopUIController.luau`'s `wireProductList` now writes to `button.Label.Text` instead of `button.Text` for both the 5 `DEVELOPER_PRODUCT_BUTTONS` and the `DoubleFans` game pass button. Re-verified live after the fix: all 5 buttons show a clean rounded-square icon with fully-visible text alongside it.
6. Live-verified every change in Play mode via `execute_luau`-driven `.Open()` calls on the real client controllers (mouse-click automation on the LeftMenuBar buttons intermittently missed the hitbox — calling the controller's `Open()` directly is the reliable path) + `screen_capture`: HUD skill buttons (rounded-square, correct per-slot icons cross-checked against live `EquippedSkill1/2/3` attributes), Skill Shop list, Skill Select modal, Robux Shop panel — all confirmed correct by screenshot.
7. Full validation pass: `rojo build` clean; paren/brace balance confirmed on every touched file (`SkillTrees.luau` 62/62 44/44, `SkillShopController.luau` 90/90 19/19, `SkillLoadoutController.luau` 66/66 10/10, `ShopUIController.luau` 67/67 10/10).
8. **Same-turn follow-up: the rounded-square fix from step 2 wasn't actually square.** `BottomRight` (the HUD frame the 3 skill buttons live in) is `{0.13, 0} x {0.32, 0}` of the screen — non-square — and each button was `{0.9, 0} x {0.28, 0}` of THAT, i.e. roughly 150x64px on a typical viewport: a wide rectangle, so the 0.7x0.7 `Icon` inside it rendered visibly squashed. Root cause: scale-based `UDim2` sizing has no built-in aspect-ratio lock. Fixed by adding `UIAspectRatioConstraint` (`AspectRatio = 1`, `DominantAxis = "Height"`) to all 3 buttons, which derives a true square from the smaller (height) dimension; re-anchored each button to `AnchorPoint {0.5, 0.5}` centered within its old vertical band (`Position` Y recalculated as each band's center: 0.16 / 0.50 / 0.84) so the now-narrower button stays centered instead of hugging the old left edge. Icon size bumped from 0.7 to 0.85 (more of the now-square button is safe to fill) and given its own `UICorner {0, 10}` for polish. Per the user's explicit fallback instruction ("if you are unable to fit icon perfectly, make the background invisible instead"), `ControlMapper.applyIconFallback` now also sets `textButton.BackgroundTransparency = 1` whenever an icon is showing (was previously only hiding the text) — the colored capsule background is fully hidden behind the icon rather than risking any visible mismatch, restored to `0` in the text-fallback branch. Live-verified via `screen_capture`: all 3 buttons render as clean squares, undistorted icons, no visible background color.

**Previous round (2026-08-02) — "global negative also hit self, no change
needed if player cast shield then global negative debuff will allow player
to not be affected otherwise make it cash cast enemy only" + "scan and sort
image icons to match skills, items in shops; then add accordingly in
shops" + "for skills action button, use image but default to current text
if not available":**
1. **Shield/Phase immunity fix.** `SkillEffects.luau` declares `GrantsImmunity = true` on `ShieldSelf`/`PhaseSelf`, but grepping the whole codebase confirmed nothing ever read that field — `EffectStackManager.TryApplyEffect` just inserted them as an inert "Good"-polarity list entry with no stat effect, no control-scramble, no stun. Casting Shield did literally nothing protective, in any prior session. Fixed by adding an explicit branch at the top of `TryApplyEffect`: if `effectDefinition.GrantsImmunity`, call `grantImmunity(player, "Bad", durationSeconds)` (the skill's own level-scaled duration, not the generic 4th-stack rule's default) and return, instead of falling through to the normal stacking/list-insertion path. Since `isImmune(player, polarity)` is checked at the very top of `TryApplyEffect` for EVERY recipient — caster included — this correctly protects a player who shields themselves before a Global debuff, even one they cast on themselves (Global skills deliberately still hit their own caster; that behavior is unchanged and correct per the user's own "no change needed" instruction). Live-verified directly against the real running server singleton (not a `require()` copy): cast Shield → tried to apply `SlowGlobal` to the same player → rejected (`TryApplyEffect` returned `false`, `WalkSpeed` multiplier stayed `1`); waited out the 3s immunity window → tried the identical `SlowGlobal` application again → succeeded this time (`WalkSpeed` multiplier `0.4`, matching the magnitude passed) — proves the immunity is correctly time-limited, not a permanent block, and that the underlying debuff-application path still works normally outside the shield window.
2. **Icon identification.** The user provided a Studio Asset Manager folder ("racebrawlericons", folder ID 246906212725) containing 31 image assets, later pasting all 31 raw numeric asset IDs directly after establishing that folders aren't fetchable via the asset API and that `search_asset`-by-ID only returns generic placeholder names ("Game Pass Icon"), not useful for identification. Roblox's public `thumbnails.roblox.com` batch endpoint could only resolve 8/31 to public URLs — the other 23 are private to the uploader's account and returned `"PrivateImage"`, inaccessible to an unauthenticated browser session. Solved by building a temporary in-Play-mode `ScreenGui` grid (`IconViewer1`/`IconViewer2`, via `execute_luau` on the Client datamodel, never synced as real files) that renders every `rbxassetid://` through Roblox Studio's own authenticated Play session, then visually identifying each of the 31 by `screen_capture`. Both temporary ScreenGuis destroyed after use — nothing left in the Rojo tree or the live PlayerGui.
3. **Full mapping (23 of 31 icons matched with clear visual intent; 8 left unused — duplicate art styles for the same concept, e.g. a second "2x gold" icon and a second "VIP Access Pass" crown that doesn't correspond to any currently-defined shop entry since the pose-bundle VIP pass is deliberately excluded per `MonetizationConfigs`' own docstring):**
   - Skills (all 17, `SkillTrees.luau` `IconAssetId`): SlowGlobal→hourglass-on-track(105259325475493), ScrambleGlobal→scattering-arrows-with-?(104355322401857), PositionSwap→circular-swap-arrows(131927561687782), ReverseControlTarget→confused-running-figure(111761869818940), SlowTarget→red-tornado(132950600217600), WeightTarget→chained-boot(88134249299942), BlindTarget→eye-with-X(103250166969723), ShockTarget→lightning-bolt(99140041264819), SiphonPulse→shield-arrow-up(73524748013524), DashSelf→running-character-purple-burst(76409714687307), ChargedJumpForward→green-coil-lightning(86432790605790), SpeedBoostSelf→winged-shoe(94538165629087), SwimBurstSelf→blue-running-figure(96022776767443), ClimbGripSelf→fist-with-up-arrows(99035051232831), ShieldSelf→blue-shield(108778680567281), PhaseSelf→green-ghost-figure(88823425414339), CleansePulse→green-cross-red-daggers(83563047168324).
   - Shop items: GoldSmall→brown-coin-sack(73429786426365), GoldMedium→closed-treasure-chest(131951544409493), GoldLarge→crowned-chest-spilling-coins(81581292129939), FanBoost→coin-sack-with-megaphone(134101988537774), ExtraLife→pink-1UP-heart(137924809858708), DoubleFans (game pass)→2x-double-EXP-gold-coins(120298261990946).
4. **Wired into shops** (`default.project.json`): added an `Icon` `ImageLabel` child (small, left-aligned, `Image` pre-set to the matched asset — real icons now, not placeholders) to all 5 `RobuxShopPanel.ProductList` buttons (GoldSmall/GoldMedium/GoldLarge/FanBoost/DoubleFans) and both `EliminationPanel.Card` revive buttons (RobuxButton/GoldButton, both using the ExtraLife heart icon since both buttons grant the same 1-extra-life item via different currencies). Deliberately did NOT hide the button text for these — unlike the skill-button convention below, the price/amount text (`"💰 100 Gold"`, `"REVIVE — 30 ROBUX"`) is load-bearing information, so icon + text coexist rather than icon replacing text.
5. **Skill action buttons** (`ControlMapper.luau` + `default.project.json`'s `BottomRight.Skill1/2/3Button`): added an `Icon` `ImageLabel` child (placeholder `Image = ""`, matching the established `applyIconFallback` convention already used by `ShopUIController`/`MainMenuController`/`SkillShopController`) to all 3 HUD skill buttons. New `applyIconFallback(textButton, skillId)` in `ControlMapper.luau`, called every time `refreshSkillButtonLabels` runs (equip change or initial load): sets `icon.Image` from the equipped skill's `SkillTrees[skillId].IconAssetId`; if non-empty, shows the icon and sets `textButton.TextTransparency = 1` (hides the DisplayName text); if empty (or no skill equipped), hides the icon and restores `TextTransparency = 0` so the text fallback is visible — exactly the "use image but default to current text if not available" behavior requested. Live-verified via screenshot: all 3 equipped-skill buttons rendered their real icon images with text fully hidden underneath.
6. Full validation pass: `rojo build` clean, paren/brace balance confirmed on every touched file (`SkillTrees.luau` 62/62, 44/44; `EffectStackManager.luau` 55/55, 12/12; `ControlMapper.luau` 79/79, 12/12), ambiguous-syntax scan on `ControlMapper.luau` found one match but it's inside the file's own top doc-comment block (`(StarterGui.MainHUD.BottomRight)`), not real code.

**Newest round (2026-08-02) — "cosmetic and target update": shorten the
DoubleFans shop button text, "ensure it actually works when receiving gold
and fans reward."** The cosmetic ask surfaced a real functional bug:
1. `ShopUIController.wireProductList` built game-pass button text as `` `{pass.Name} — {pass.Description}` `` — that's the actual long string the user saw (the static text in `default.project.json` gets overwritten at runtime), not just a display-name issue. Changed to `button.Text = pass.Name` alone, and renamed `MonetizationConfigs.GamePasses.DoubleFans.Name` from "Rocket Fans and Gold" to "Double Gain Fans and Gold" — now shows exactly that, nothing appended. Also fixed a smaller adjacent cosmetic bug spotted in the same panel: developer-product buttons were showing the raw field name "TotalFans" (e.g. "250 TotalFans") instead of "Fans" — `labelForProduct` now maps `GrantCurrency` to a display label instead of interpolating it directly.
2. **"Ensure it actually works" — it didn't, at all.** `MonetizationService.PlayerOwnsGamePass` was fully implemented (wraps `MarketplaceService:UserOwnsGamePassAsync` in a pcall) but its own docstring admitted "Nothing calls this yet." Grepped the whole codebase to confirm: zero callers. The two real Gold/Fans reward sites — `CarryItemService.TryDeposit` (fan payload deposit) and `CheckpointValidator.grantLapReward` (lap completion, grants both Gold and Fans) — never checked game-pass ownership at all, so owning "Double Gain Fans and Gold" changed nothing.
3. Fixed by calling `MonetizationService.PlayerOwnsGamePass(player, "DoubleFans")` at both sites and multiplying by a new `EconomyRates.DoubleGainMultiplier = 2` when true. Updated `MonetizationService`'s docstring to name its actual callers instead of "nothing yet."
4. **Live-verified end-to-end**, not just by reading the diff: since genuinely owning a real Robux game pass isn't practical to simulate in a solo Studio session, temporarily monkey-patched `MonetizationService.PlayerOwnsGamePass` to force `true` for `"DoubleFans"` via a real synced `.server.luau` script (mutating the shared module table, not an `execute_luau` copy — same technique as the dummy-NPC harness two rounds ago), then ran the ACTUAL real pipeline: teleported next to a real `FanPayloadPickup`, clicked the real pickup button, waited out the real 3-second channel, teleported to the real deposit zone, clicked the real deposit button. `TotalFans` went 1120 → 1140 — exactly +20, double the base 10-per-payload value. Lap-completion reward uses the identical two-line pattern (same ownership check, same multiplier, applied to both Gold and Fans) but wasn't separately live-fired — that would need navigating all 8 checkpoints in order, which the deposit test's proof of the underlying mechanism makes low-risk to skip. Monkey-patch script deleted after; confirmed gone.

**Even newer round (2026-08-02) — direct user follow-up after playtesting the
previous round's Dash fix: "dashing only falls down."** Confirms a hard
lesson: a position-delta measurement is NOT the same as actually looking at
the result. The previous round's fix (below) was numerically correct
(position really did change) but `Humanoid.PlatformStand = true` — the
mechanism that let the horizontal velocity survive — is Roblox's ragdoll/
prone toggle, so the caster visually collapsed instead of dashing. Also
requested: exaggerate `EffectMagnitude` too (2x), and prove skill effects
actually land using summoned dummy NPCs plus reverse-direction testing, then
remove all of it.
1. **Real fix for Dash (and Jump's horizontal component)**: replaced the raw-velocity/PlatformStand technique with `Humanoid:MoveTo` — normal locomotion, keeps the caster upright and animated. Speed is derived so the caster covers exactly `RangeStuds` by the end of the skill's own `EffectDurationSeconds` (Dash) or a new `JUMP_FLIGHT_DURATION_SECONDS = 0.4` constant (Jump, since ChargedJumpForward's own duration field means charge-time, not flight-time). New `MovementModifier.SetWalkSpeedOverride(player, speed, duration)` takes `WalkSpeed` away from the normal effect-recompute loop for that window so the two don't fight (confirmed live: without this, the 0.25s recompute loop stomped a one-off `WalkSpeed` set within a fraction of a second). "Current forward direction" is still read fresh at cast time (`rootPart.CFrame.LookVector`) — neither skill is driven by WASD input, so it composes correctly regardless of ReverseControlTarget.
2. Removing `PlatformStand` fixed the ragdoll but (confirmed live) dropped Jump's horizontal carry back down to ~0.3 studs — Humanoid's own controller zeroes raw horizontal velocity almost immediately once nothing is suppressing it, same root cause as Dash originally had. Jump now uses a hybrid: `launchCaster`'s vertical-only velocity impulse (real jump arc, confirmed no ragdoll) plus the same `MoveTo`-based horizontal run, called together.
3. Live-confirmed both post-fix: Dash screenshot shows the caster standing normally (not collapsed) mid-cast; `Humanoid:GetState()` stays `"Running"` throughout Dash and correctly cycles `"Freefall"` during Jump; both land within a fraction of a stud of their intended `RangeStuds` at the correct ground height.
4. `SkillTrees.luau` — added `MAGNITUDE_EXAGGERATION_MULTIPLIER = 2`, applied as `1 + (rawMagnitude - 1) * 2` (doubles the delta from 1, NOT the raw number — a naive `*2` would flip a 0.7 debuff into a 1.4 buff). Skills with no `BaseMagnitude` (control-scramble/Dispel/immunity, magnitude=0 placeholder) are explicitly excluded from the formula. `MIN_EXAGGERATED_MAGNITUDE = 0.05` floor clamp stops an already-strong debuff from crossing zero into negative (verified: `ShockTarget`'s 0.15 near-stun would have doubled to -0.7 without the clamp; now correctly floors at 0.05, which — fittingly — makes it read as an actual full stop). Live-verified via a fresh `require()` (a stale Edit-mode module cache from earlier in the session initially masked this and returned pre-edit numbers — cloning the ModuleScript before requiring forces a true reload): `SpeedBoostSelf` 1.2→1.4, `SlowTarget` 0.7→0.4, `DashSelf` 1.5→2.0, `PositionSwap` stays 0/0 as expected.
5. Closed last round's honest gap ("Target-type skills not live-tested — no second real player available"): built a TEMPORARY test harness (`_TEMP_SkillTestHarness.server.luau` + 2 follow-up retest scripts, all deleted after) that ran as a REAL synced Script (not via `execute_luau`, whose `require()` doesn't share the live server's module cache) so it could call the actual running `EffectStackManager`/`MovementModifier`/`GlobalSkillStateMachine` singletons directly. Spawned 2 minimal dummy rigs (a `Model:Clone()` of the real player's character returned nil — some descendant is presumably `Archivable = false` — so used a plain built Part+Humanoid instead) and confirmed, with real before/after numbers: a Target-type debuff applied to a dummy actually changes its `WalkSpeed`/`JumpPower` (16→6.4, 50→15, exact matches); control-scramble flags register (`IsControlsScrambled` → `"Blind"`); the per-source concurrency cap correctly REJECTED a 3rd Target-sourced effect on the same dummy (a bonus confirmation the stacking rules work, not a bug); the reverse direction (an externally-applied debuff landing on the real player) flows through the actual live `MovementModifier` background loop and reverses correctly on expiry; `Dispel` actually removes an active debuff via that same real loop; and `GlobalSkillStateMachine.CastSkillDirect` correctly applies `SlowGlobal` to a real `InRace` player (16→8, matching `SlowGlobal`'s own exaggerated 0.5 magnitude) and reverses on expiry. All temporary scripts and dummy instances removed afterward — confirmed via `Edit`-mode inspection that nothing remains.
6. Practical lesson reconfirmed twice more this round: tool round-trip latency repeatedly beat short fixed `task.wait()` windows in the retest scripts (a "click Join Race" + immediate 1-10s check kept reading stale `InLobby`) — polling in a loop (`while state ~= InRace and waited < 20 do task.wait(1) end`) rather than a single timed check is the reliable pattern when a real client action needs to land before a server-side check.

**Newest round (2026-08-02) — "exaggerate skills" + mandatory live testing.
The live-testing instruction is what caught a real bug that pure code
review had missed for who knows how many prior sessions:**
1. `SkillTrees.luau` — added `GOLD_COST_MULTIPLIER = 10`, `COOLDOWN_MULTIPLIER = 2`, `DURATION_MULTIPLIER = 2` inside `generateLevels` (single point of truth — every skill funnels through it), applied to `CooldownSeconds`/`EffectDurationSeconds`/`UpgradeGoldCost`; `UnlockGoldCost` (not curve-generated) multiplied inline per skill (`N * GOLD_COST_MULTIPLIER`, all 17). Live-verified in Studio: e.g. SlowGlobal 45s→90s cooldown, 300→3000 unlock cost; PositionSwap level-2 upgrade 140→1400.
2. Live-tested `SpeedBoostSelf` (Skill1, already equipped on the test account) end-to-end with precise `RunService.Heartbeat`-timestamped measurement (naive polling was fooled by tool round-trip latency the first two attempts — see below): magnitude exactly 16→19.2 (1.2x, untouched by this round), cooldown exactly 20s (doubled from 10, confirmed via the real `SkillCastResult` remote payload), duration ≈5.98s (doubled from 3, confirmed via a `WalkSpeed`-change listener armed before casting). This is the trustworthy reference result for "did the exaggeration break anything" — answer: no.
3. **Found via testing DashSelf (equipped starter skill)**: its own description is "Bursts forward a short distance with a brief speed boost" but `SelfSkillManager.resolveAndApply`'s generic `LinkedEffectId` branch only ever applied the passive `WalkSpeed` multiplier — `levelData.RangeStuds` was defined per-level and never read for this skill, so casting Dash while not already holding a movement key produced literally zero displacement. Confirmed with a `RunService.Heartbeat` position/velocity logger: position never moved, velocity stayed exactly `(0,0,0)`.
4. **Root-caused as TWO separate, stacked Roblox gotchas, both confirmed by isolating them empirically, that also silently broke the pre-existing, shipped `ChargedJumpForward`** (its exact formula, unmodified, also produced zero displacement over 1.5s of direct observation — this was never actually working, in any prior session):
   - A player's own character is network-owned by their own client by default. A server script setting `AssemblyLinearVelocity` on it gets overridden within ~1 frame by the client's own physics simulation, which never received that change. Fix: `rootPart:SetNetworkOwner(nil)` immediately before the write, `:SetNetworkOwner(originalOwner)` back ~1s later (so normal input prediction resumes for everyday movement). **This part of the diagnosis held up and is still in use.**
   - Even WITH server ownership, Humanoid's own movement controller continuously re-drives horizontal velocity toward `MoveDirection * WalkSpeed` (zero, absent real input) every physics step, regardless of grounded/airborne state — confirmed by watching a 40 stud/s vertical impulse survive untouched while its horizontal component got zeroed within ~0.05s. Fix at the time: `Humanoid.PlatformStand = true` for a brief window (0.4s) suppressed that controller, letting the raw impulse carry through — position deltas confirmed real travel. **SUPERSEDED the same day, same session (see "Even newer round" above): PlatformStand is Roblox's ragdoll/prone toggle, so this "worked" numerically while visually collapsing the caster — a direct user playtest report caught what the position-delta check alone had missed. Replaced with `Humanoid:MoveTo`-based real locomotion.**
   - Both fixes lived in a shared `launchCaster(character, rootPart, velocity)` helper in `SelfSkillManager.luau` — **that helper is now vertical-only (Jump's arc); the horizontal component for both skills moved to a new `runForward` helper. See "Even newer round" above for the current, corrected implementation.**
   - Self-inflicted bug caught by the SAME live-testing discipline this task demanded: an early edit to `SelfSkillManager.luau` accidentally deleted `local SelfSkillManager = {}` while restructuring the file, which crashed the ENTIRE server bootstrap on the next `Init()` chain (`ProcessReceiptManager` → `ArcadeManager` → `CarryItemService` → `SelfSkillManager`) — `rojo build` does not catch this class of error (valid syntax, wrong runtime semantics); only restarting Play mode and reading the console surfaced it. Fixed, rebuilt, reverified clean.
5. Global/Target-type skills (SlowGlobal, SlowTarget, etc.) were NOT live-tested this round beyond the exaggerated-number confirmation above — `TargetedSkillManager`'s `findNearestTarget` requires an actual second player in the server, which a solo Studio session can't provide. **CLOSED same day (see "Even newer round" above) via a temporary dummy-NPC test harness** that called the real effect-application pipeline directly, bypassing only the targeting/acquisition step (which still hasn't been exercised with a genuine second Player — a real 2-player Team Test remains the one gap if that specific step matters before shipping).

**Latest round (2026-08-02) — 5-part request, ALL live-verified via Roblox Studio MCP (`execute_luau`/`user_mouse_input`/`screen_capture`), a first for this project — see section 1 for full detail on each:**
1. Fan box teleport now reads `pod:GetAttribute("OriginCFrame")` instead of the CSG-uncertain `CrowdMesh.CFrame`, with a corrected offset/rotation so the player lands ~10 studs toward the track from the stand's front step, facing back at the crowd — confirmed via a top-down `screen_capture` showing the player standing directly in front of the seating.
2. Fan box count/width formula (from a prior round) verified correct at `MaxPlayers=40` without any code change: natural capacity is ~53 pods at nominal width, which already exceeds 40, so it builds ~52 pods at near-full width rather than shrinking anything.
3. New `LivesCapsule` in `StatsRow`, beside `CheckpointCapsule`, visible ONLY while `PlayerState == InRace` (unlike `CheckpointCapsule`, which is always visible) — confirmed live.
4. Investigated "shop menu unclickable while racing" — could NOT reproduce. Live-tested: joined the race, opened Skill Shop, purchased a skill upgrade (Gold 280→95, level 1→2) with `PlayerState = InRace` throughout, screenshot-confirmed. No code in the shop/purchase path gates on `PlayerState` at all. Left as-is; flag to the user that a repro (device/resolution/exact steps) is needed to find whatever they actually hit.
5. Full revive-on-elimination purchase flow — see section 1. **Caught and fixed a real bug during live testing**: leaving an eliminated player exactly where they violated (mid-air, off the track) for the full countdown let Roblox's own `Workspace.FallenPartsDestroyHeight` (-500 studs) destroy their `HumanoidRootPart` during the fall, which silently broke both the revive-respawn and the timeout's return-to-Hub (`PlayerState` got stuck on `InRace` forever). Fixed by respawning the player at their last checkpoint immediately on elimination (same as the non-fatal violation path), before starting the countdown — confirmed via live test that `rootPart` stays valid and grounded (`Y ≈ 4.8`, unchanged) throughout.

**This round, another direct follow-up, still pre-Play-test**: the
checkpoint bug from last round's "fix" was still happening. The actual
numeric root cause this time: `CheckpointTriggerThickness` is 6 studs, the
poll interval is 0.5s, and default walk speed (16 studs/sec) crosses that
6-stud band in ~0.375s — comfortably under one poll. A single "are you
inside the wall right now" sample can legitimately miss the crossing
entirely; this was a real, general race condition on ANY player, not
something carrying fans caused (it read that way because checkpoint
triggers and Fan Payload pickups share the same segment-entry anchor, so
carriers linger/maneuver right at that spot). Fixed for real via last-
position plane-crossing detection (see section 2). Also this round: the
skill-selection ribbon (used when picking a skill for a Skill1/2/3 loadout
slot in the Hub) couldn't handle more than a handful of skills — rebuilt as
a proper scrollable modal, same pattern as the Skill Shop, showing the full
17-skill catalog with level data and greyed-out unavailable entries. Plus
more `TextScaled` -> fixed-`TextSize` cleanup on the location-toggle button
and the 3 skill cast buttons, matching the smaller-text convention
established for the left-menu buttons and modal panels.

**Same session, one more pass**: two more readability complaints on the
same "text too big/bold" theme — `CenterAction.ActionButton` ("DEPOSIT
FANS"/carried-skill-name/etc.) was still `TextScaled` + `GothamBold`, and
`LocationToggleButton` ("FAN BOX" etc.) was `GothamBold` even after last
round's size-only fix — both switched to fixed `TextSize` + `GothamMedium`
(regular-ish weight, not full bold). Also added a fan-pickup progress fill:
the 3-second "PickingUp" channel now shows the same HP-bar-style fill
pattern the skill cooldowns use, via a new shared `ItemData.
FanPickupChannelSeconds` constant (was a `CarryItemService`-local number the
client had no way to know) so the client-side tween duration always matches
the server's actual wait exactly.

**Same session, third pass**: `GothamMedium` turned out to still read as
"too thick/bold" once actually tested — `CenterAction.ActionButton` and
`LocationToggleButton` went one step further, to plain `Gotham` (matching
the already-fine-looking body text elsewhere, e.g. the modal panels' level
labels). Also added currency-gain notifications: every place a player
receives Gold or Fans (fan deposit, lap completion, Robux purchase grant)
now fires a toast through the existing pooled/stacking notification system,
with a new "birthday popper" bounce effect (`style = "Pop"` on `Network.
Track.ShowNotification`, additive — every other existing call site is
unaffected) instead of the plain fade every other notice uses.

**Same session, fourth pass — the ACTUAL root cause, found**: text on
`ActionButton`/`LocationToggleButton` was STILL reported too thick after 3
straight rounds of changing `Font` (Bold -> Medium -> plain Gotham). The
font was never the variable — both buttons had a `UIStroke` instance
(`Thickness = 2`) as a direct child. In Roblox, a `UIStroke` parented to a
`TextLabel`/`TextButton` outlines the rendered TEXT GLYPHS, not just the
button's border — a 2px outline on 14-16px text is a huge fraction of the
glyph's own stroke width, and reads as "thick/bold" regardless of which
`Font` is set underneath it, which is exactly why 3 rounds of font changes
had zero visible effect. Confirmed by comparison: `LeftMenuBar`'s 3 buttons
and the `Skill1/2/3` buttons have NO `UIStroke` and were never reported as
illegible. Removed the `UIStroke` from both buttons entirely (matching the
already-fine `LeftMenuBar`/`Skill1/2/3` convention) — this is believed to
be the actual, complete fix this specific complaint needed.

**Same session, fifth pass — real gameplay bug, lap completed a full
segment early, fixed twice (first attempt didn't work, per direct user
report — see sixth pass below for the actual fix)**: reported as "lap
completes on the 7th segment instead of 8th; immediately registering a lap
at onset." First attempt kept checkpoints at segment ENTRIES and instead
moved the reward trigger to "wrapped back around to checkpoint 1" — this
did NOT fix it in practice.

**Same session, sixth pass — fixed at the source instead of patched
around**: user's explicit instruction: "make checkpoint 1 at end of first
segment." This reframes the whole model — instead of trying to detect "did
we wrap back to checkpoint 1" as a special case, MOVE the checkpoints
themselves from each segment's ENTRY to its EXIT:
- `TrackGenerator.GenerateOval` — `addCheckpointTrigger` now called AFTER
  building each piece, with `exitCFrame` instead of `currentCFrame`
  (renamed the param to `pieceExitCFrame` for clarity). Checkpoint 1 is now
  segment 1's exit (= segment 2's entry) — literally what was asked.
  Checkpoint 8, as a direct consequence, is segment 8's exit, which is the
  SAME physical point as segment 1's entry (the oval closes on itself
  there) — Checkpoint 8 now just IS the start/finish line.
- `CheckpointValidator.checkPlayer` — reverted the fifth-pass `wrapsToStart`
  logic entirely, back to the original simple `nextOrdinal == CHECKPOINT_COUNT`
  check. This is now CORRECT (it wasn't before) because checkpoint 8's new
  physical position makes "reach checkpoint 8" and "complete the lap"
  the same event — no special-casing needed once the geometry itself is
  right.
- `CheckpointValidator.GetCheckpointCFrameForPlayer` — the "haven't passed
  any checkpoint yet" fallback (`ordinal == 0`) changed from Checkpoint 1
  to Checkpoint 8 (`CHECKPOINT_COUNT`), since Checkpoint 1 is no longer the
  start line — it's now a full segment IN, so falling back to it would
  respawn a player who violated inside segment 1 past all of segment 1 for
  free. Checkpoint 8 (start line) is the correct "nothing passed yet"
  fallback under the new model.
- `TrackBlueprints.luau` / `TrackGenerator.luau` docstrings updated to
  describe the new entry-vs-exit placement.
- Side effect, not required but worth noting: checkpoints and Fan Payload
  pickups (`TrackPickupSpawner`, still anchored at segment ENTRIES,
  untouched this round) are no longer co-located, which was the confound
  behind the "carrying fans breaks checkpoints" misdiagnosis 2 rounds ago.

**Same session, seventh pass — procedural track theming, a genuinely new
feature (not a bug fix)**: "going back to the original oval track design
[...] 8 tracktypes, each must have curve and straight designs [...] the 2
curves and 2 straights are from 2 to 4 different track theme types [...]
can you procedurally generate the themes." This explicitly re-confirms the
single-oval design (not `CourseSequence`'s superseded "8 different tracks
chained together" idea) — themed VARIETY within the one oval's segments,
not a different track per checkpoint.
- [ ] `TrackThemes.luau` rewritten from scratch: the old 7 entries were
  bespoke hazard-biome concepts (floating platforms over a pit, a branching
  maze, a climb-then-slide section, a periodic tsunami wave) that needed
  entirely different geometry than a chained Straight/Curve oval piece —
  none of them were ever actually built (`ThemedTrackBuilder` was a stub
  with only TODOs). Replaced with 8 lightweight reskins (`Classic`,
  `HillMud`, `IceFrost`, `Volcanic`, `WaterDock`, `SkyRail`, `Desert`,
  `NeonCircuit`) that only vary `RoadColor`/`RoadMaterial`/`BarrierColor`
  (all real, valid `Enum.Material` values — `Mud`, `Ice`, `CrackedLava`,
  `WoodPlanks`, `Metal`, `Sand`, `Neon`, `Concrete` — zero Toolbox/asset
  dependency) — so every theme fits the EXACT SAME piece shape/size/
  connectivity as the plain default, and can be dropped onto any oval
  segment with no special-case geometry.
- [ ] `TrackPieceBuilder.BuildStraight`/`BuildCurve` both gained an
  optional trailing `theme: TrackThemes.TrackTheme?` parameter, threaded
  through to `addRoadSlab`/`addBarriers`; omitted (nil) preserves the
  original plain grey-concrete look exactly as before, so nothing else
  that calls these (there's nothing else that does today, but the
  contract matters) breaks.
- [ ] `TrackGenerator.GenerateOval` — new `pickOvalSegmentThemes()`: shuffles
  the 8-theme pool, picks a random count between 2 and 4, and assigns those
  chosen themes across the oval's 4 fixed segment-pairs (Side1 straights =
  segments 1-2, End1 curves = 3-4, Side2 straights = 5-6, End2 curves = 7-8
  — matches `TrackBlueprints`' actual SS-CC-SS-CC layout), cycling through
  the chosen themes if fewer than 4 were picked so every pair still gets
  one. Re-rolled on every `GenerateOval` call, so `Regenerate()` (already
  called after each Grand Prix) gives a fresh theme mix each time, same as
  the existing hazard-segment randomization already did.
- [ ] `WalkSpeedModifier`/`HazardTag` are real config fields on each theme
  but NOT wired to live gameplay yet — there's no terrain-zone spatial
  query reading "which theme is this player standing on" and applying the
  multiplier via `MovementModifier`. Flagged explicitly in `TrackThemes`'
  own docstring rather than silently doing nothing; this is the natural
  next step if theme-driven movement effects are wanted, not required for
  the visual variety that was actually asked for this round.
- [ ] Deleted `ThemedTrackBuilder.luau` and `CourseSequence.luau` — both
  confirmed unused anywhere (grepped before deleting), both already
  self-documented as superseded/stub, and both would have referenced
  theme IDs that no longer exist after the `TrackThemes` rewrite (e.g.
  `CourseSequence` directly indexed `TrackThemes.EasyMaze.DisplayName`).
  Updated the one dangling comment reference in `GrandPrixManager.luau`
  (`HandleCheckpointReached`'s docstring, itself dead code — nothing calls
  this function yet) to stop citing the deleted file.

**Same session, eighth pass — Fan Boxes show an actual crowd now, not an
abstract block**: "update fans box, create box templates, [...] place
standard roblox noob avatar as fans [...] the entire fansbox should be
updated to become just one mesh." The original spec always wanted "100+
NPCs loaded as a single mesh"; the existing implementation was one plain
colored block standing in for that (explicitly flagged as a placeholder in
`FanBoxTiers`' own docstring). Built the real thing:
- [ ] `FanBoxGenerator.luau` — new `buildNoobFigureParts`: one small 3-part
  figure (Legs/Torso/Head) in the classic pre-Rthro Roblox default-avatar
  colors (bright yellow head, bright blue torso, bright green legs) —
  plain Parts, same "no Toolbox access" constraint as every other
  procedurally-built thing in this project. New `buildCrowdMesh`: arranges
  a 10x4 grid (40 figures, 120 parts) filling `FanBoxTiers.PodBaseSize`'s
  width/height footprint, then merges every part into ONE `BasePart` via
  `BasePart:UnionAsync` — a real, load-bearing CSG operation (not a
  render-time trick), so a pod with 40 visible fan figures still costs
  exactly one `BasePart` at runtime, same as the block it replaces. Falls
  back to the original plain block (wrapped in `pcall`) if `UnionAsync`
  itself fails for any reason, so a pod is never left without a
  `CrowdMesh`.
- [ ] Source figure parts are explicitly `Anchored = true` at creation,
  BEFORE being parented into a temp workspace folder for the union call —
  `UnionAsync` yields, and an unanchored Part would fall under gravity
  during that yield and corrupt the merged geometry. Caught by reasoning
  through the async call's timing, not by a runtime error.
- [ ] Zero changes needed to `FanBoxSlotManager`, `FansBoxRenderer`, or
  `FanBoxTiers` — the result is still a single `BasePart` named
  "CrowdMesh" (a `UnionOperation` IS-A `BasePart`), so every existing
  lookup-by-name and Size-tweening-by-tier code path keeps working
  unchanged. Updated their doc comments only, to stop describing the old
  "plain block placeholder" now that it's a real (if simple) crowd.
- [ ] Deliberately scoped DOWN from a literal "100+" figures to 40 per pod
  (10x4 grid) — `UnionAsync` is a genuinely expensive CSG operation, and
  20 pods x 100 figures x 3 parts = 6,000 parts unioned at Hub generation
  time risked a very slow (or failing) `Init()`. 40 figures x 20 pods =
  800 total source parts, a much safer number; tunable via
  `NOOB_GRID_COLUMNS`/`NOOB_GRID_ROWS` if Play-testing shows headroom.
- [ ] Explicitly NOT done: per-tier crowd density (a bigger `FanBoxTiers`
  tier still scales the SAME 40-figure mesh uniformly larger, not a denser
  figure grid) — flagged in `FansBoxRenderer`'s docstring as a real
  possible upgrade requiring either a live re-union per tier-change or 5
  pre-built meshes per pod, neither attempted this round.
- [ ] User confirmed the themed-oval geometry from last round "looks okay
  [...] we need to adjust it later as final task" — explicitly deferred,
  not an open bug, don't re-touch track theming until asked.

## 1. Completed Modules (Synced to Studio)
- [x] Everything through the last 12 sessions — see prior file history, not reproduced here. Still no confirmed successful Play test on record.

**2026-08-02, fourth round this day — see section 0's "Newest round" for full narrative detail:**
- [x] `ShopUIController.luau` — game-pass button text is now just `pass.Name` (was `` `{Name} — {Description}` ``, the actual source of the long text); `labelForProduct` now maps `GrantCurrency` to a display label ("Gold"/"Fans") instead of interpolating the raw field name ("TotalFans").
- [x] `MonetizationConfigs.luau` — `DoubleFans.Name` = "Double Gain Fans and Gold" (was "Rocket Fans and Gold").
- [x] `EconomyRates.luau` — new `DoubleGainMultiplier = 2`.
- [x] `MonetizationService.luau` — docstring corrected (was claiming "nothing calls this yet," no longer true); no code change, it was already correct, just unused.
- [x] `CarryItemService.luau` (`TryDeposit`) + `CheckpointValidator.luau` (`grantLapReward`) — both now call `MonetizationService.PlayerOwnsGamePass(player, "DoubleFans")` and multiply the Gold/Fans reward by `EconomyRates.DoubleGainMultiplier` when true. This is the FIRST time the DoubleFans pass has ever actually affected anything — live-verified via a temporary ownership monkey-patch + the real fan pickup→deposit pipeline: 1120→1140 `TotalFans` (exactly 2x the base 10). Lap-completion reward wasn't separately live-fired (would need a full 8-checkpoint lap) but uses the identical pattern.

**2026-08-02, third round this day — see section 0's "Even newer round" for full narrative detail:**
- [x] `SelfSkillManager.luau` — `launchCaster` is now vertical-only (Jump's arc, `SetNetworkOwner` still required). New `runForward(caster, character, rootPart, distanceStuds, durationSeconds)` uses `Humanoid:MoveTo` for the horizontal component of BOTH `DashSelf` and `ChargedJumpForward` (Jump calls both `launchCaster` for lift and `runForward` for distance, with a new `JUMP_FLIGHT_DURATION_SECONDS = 0.4` constant since ChargedJumpForward's own `EffectDurationSeconds` means charge-time, not flight-time). Replaces the PlatformStand approach below, which ragdolled the caster.
- [x] `MovementModifier.luau` — new `SetWalkSpeedOverride(player, speed, durationSeconds)` + a `walkSpeedOverrideUntil` table so the 0.25s effect-recompute loop doesn't stomp `runForward`'s scripted speed mid-run.
- [x] `SkillTrees.luau` — `MAGNITUDE_EXAGGERATION_MULTIPLIER = 2` in `generateLevels`, applied as `1 + (raw - 1) * 2` (preserves buff/debuff polarity) with a `MIN_EXAGGERATED_MAGNITUDE = 0.05` floor clamp on debuffs. Skills with no `BaseMagnitude` untouched. Live-verified via a forced-fresh `require()` (clone-then-require, since a stale Edit-mode cache from earlier in the session initially returned pre-edit numbers).
- [x] Built + fully removed a temporary dummy-NPC test harness (3 `.server.luau` files, 2 built dummy rigs) that ran as real synced Scripts (not `execute_luau`, to share the live module cache) to directly exercise `EffectStackManager`/`MovementModifier`/`GlobalSkillStateMachine` — confirmed Target-type debuffs land on non-Player recipients, control-scramble/stun flags register, the per-source concurrency cap correctly rejects over-cap effects, Dispel works, and Global skills apply to a real `InRace` player — all via the real live pipeline, not fresh/disconnected module copies. Nothing left behind — confirmed via `Edit`-mode inspection.

**2026-08-02, second round this day — see section 0's "Newest round" for full narrative detail (PARTS OF THIS ARE STALE — see the "third round" entry above and section 0's "Even newer round"):**
- [x] `SkillTrees.luau` — `GOLD_COST_MULTIPLIER=10`/`COOLDOWN_MULTIPLIER=2`/`DURATION_MULTIPLIER=2`, applied in `generateLevels` + per-skill `UnlockGoldCost`. Live-verified numerically correct for all 17 skills. (Still current — magnitude exaggeration was added on top later the same day, doesn't change these.)
- [x] `SelfSkillManager.luau` — fixed `DashSelf` (never actually displaced the caster — description said "bursts forward," code only applied a passive speed multiplier) and, in the process, discovered + fixed the SAME bug in the pre-existing `ChargedJumpForward` (also never worked, in any prior session). ~~New shared `launchCaster()` helper: forces server `NetworkOwner` (client owns characters by default; server velocity writes get silently overridden) + toggles `Humanoid.PlatformStand` briefly (Humanoid's own controller re-zeroes horizontal velocity every step otherwise, regardless of airborne state). Both skills live-confirmed producing real forward travel + correct landing height post-fix.~~ **PlatformStand secretly ragdolled the caster — see the "third round" entry above for the real fix.**

**2026-08-02 round — all 5 items live-verified in Play mode (first for this project):**
- [x] `TeleportPoseService.luau` — `TeleportToFanBox` now reads `pod:GetAttribute("OriginCFrame")` instead of `CrowdMesh.CFrame` (same anti-pattern class as the earlier fan-box-floating bug), with `FAN_BOX_STAND_OFFSET = CFrame.new(10, 5, 0) * CFrame.Angles(0, math.rad(90), 0)` — origin's local +X is "toward the track" (`FanBoxCrowdTemplates`'s own convention, crowd figures' `LookVector` aimed along it), steps are all built into local -X, so +10 clears the frontmost step; yaw +90 turns the player's `LookVector` from -Z (along-track) to -X (back at the crowd).
- [x] Verified (no code change) — `FanBoxGenerator.computePodsPerPiece`'s count/width formula at `MaxPlayers=40`: natural capacity (loop arc length / nominal 35-stud width) is 53 pods, already ≥ 40, so `podCount = max(53, 40) = 53`, `actualPodWidth ≈ 34.9` (barely shrunk from nominal). Confirmed by computing the exact formula against live `TrackGeometry`/`FanBoxTiers` values in Studio.
- [x] `LiveRaceHUD.luau` + `default.project.json` (`StatsRow.LivesCapsule`, new, `LayoutOrder=4`, red stroke, `Visible=false` by default) — new capsule bound to `PlayerState`/`Lives` attribute changes, `Visible = (PlayerState == InRace)`. `StatsRow` widened 0.46→0.58 and existing 3 capsules narrowed (0.30/0.30/0.36 → 0.22/0.22/0.28) to fit a 4th without crowding.
- [x] Investigated "shop menu unclickable while racing" — NOT reproducible. Live-tested opening `SkillShopPanel` and completing a real Gold purchase while `PlayerState = InRace`; worked correctly, screenshot-confirmed. No `PlayerState` gating exists anywhere in `ShopUIController`/`SkillShopController`/`HubShoppingManager`/the panel declarations. Needs a repro from the user (device, resolution, exact steps) to investigate further — may have been a stale client cache at the time it was reported.
- [x] Revive-on-elimination purchase flow (Robux unlimited / Gold 3x/day), honoring the clarified "pause" semantics (no engine freeze — a delayed, cancelable auto-return with a client countdown):
  - `MonetizationConfigs.luau` — `DeveloperProductEntry.GrantCurrency` gained a 3rd option, `"ExtraLife"` (kept the table homogeneous rather than inventing a parallel type). New `DeveloperProducts.ExtraLife = { Id = 3612751507, GrantCurrency = "ExtraLife", GrantAmount = 1 }`. Deliberately excluded from `ShopUIController.DEVELOPER_PRODUCT_BUTTONS` — only offered from the elimination prompt.
  - `ProfileTemplate.luau` — added `GoldRevivesUsedToday`/`GoldRevivesLastResetDay` (day-rollover cap tracking, `math.floor(os.time()/86400)` as the day number).
  - `EconomyRates.luau` — added `ExtraLifeGoldCost=100`, `ExtraLifeGoldDailyLimit=3`, `EliminationTimeoutSeconds=15`.
  - `Network.luau` + `default.project.json` (`RemoteEvents.Track`) — 3 new remotes: `PlayerEliminated` (server→client, opens the prompt), `BuyExtraLifeWithGold` (client→server), `EliminationResolved` (server→client, closes the prompt either way).
  - `ArcadeManager.luau` — `HandleTrackViolation`'s 0-lives branch no longer instantly refills+leaves: it immediately respawns the player at their last checkpoint (bug fix, see round summary above), starts a cancelable `task.delay(EliminationTimeoutSeconds, onEliminationTimeout, player)` tracked in a new `eliminationTimers` table, and fires `PlayerEliminated`. A repeat violation while already pending is a no-op (guard at the top of the function) — `TrackBoundaryMonitor` polls every 0.5s and would otherwise re-fire continuously. New `ArcadeManager.GrantExtraLife(player)` cancels the pending timer (if any), adds 1 life, and — only if it resolved a real pending elimination — respawns at checkpoint and fires `EliminationResolved(true)`; called by both the Gold-purchase remote handler (after deducting cost + incrementing the daily counter) and `ProcessReceiptManager` (Robux, unlimited, always honored even if not currently pending). `Players.PlayerRemoving` cancels any live timer to avoid a dangling thread.
  - `ProcessReceiptManager.luau` — `GrantCurrency == "ExtraLife"` branch calls `ArcadeManager.GrantExtraLife` instead of touching `profile.Data` directly (new `require` of `ArcadeManager`; confirmed one-directional, no circular require).
  - `EliminationPromptController.luau` (new) + `default.project.json` (`MainHUD.EliminationPanel`, non-dismissible backdrop, `ZIndex=60`) — shows a cosmetic local countdown (the real timeout is server-authoritative), a Robux button (`MarketplaceService:PromptProductPurchase`) and a Gold button (greys out + reads "NO GOLD REVIVES LEFT TODAY" once `goldRevivesRemainingToday` hits 0). Wired into `Main.client.luau`.
  - **Bug caught live, fixed same round**: originally left the eliminated player exactly where they violated for the whole countdown — if that was mid-air/off-track, they'd free-fall past `Workspace.FallenPartsDestroyHeight` (-500 studs, well within 15 seconds of gravity) and Roblox would destroy their `HumanoidRootPart`, silently breaking the revive respawn AND the timeout's `ReturnToHub` (confirmed live: `rootPart` went nil, `PlayerState` got stuck on `InRace` forever instead of flipping to `InLobby`). Fixed by calling the same checkpoint-respawn helper immediately on elimination, before the timer starts.
  - Live-tested both branches end-to-end: 3 violations draining Lives 3→0 kept `PlayerState = InRace` and the player grounded at the checkpoint each time; letting it time out naturally refilled Lives to 3, flipped `PlayerState` to `InLobby`, and physically returned the player to the Hub; the Gold-purchase path correctly rejected an insufficient-balance attempt (95 Gold < 100 cost) with no state change. The Gold/Robux SUCCESS grant path was not exercised with a real affordable balance (Studio can't complete real Robux receipts, and the test profile's Gold was insufficient) — it reuses the exact same `GrantExtraLife` function already proven via the timeout/respawn path, so this is a lower-confidence spot than everything else in this list if something still looks off.

## 2. In Progress / Pending QA (all new this round, none Play-tested yet)

**Text readability, round 3 — GothamMedium wasn't enough either:**
- [ ] `CenterAction.ActionButton` and `LocationToggleButton` — round 2 (this same session) had already moved these from `GothamBold` to `GothamMedium`, but on actual test that STILL read as "too thick/bold." Moved both to plain `Gotham` (matches the font already used for un-complained-about body text, e.g. `SkillShopPanel`'s `LevelLabel`). Corrected takeaway from round 2's note: it's not "GothamBold is bad, GothamMedium is fine" — for this project's small HUD button text, only plain `Gotham` reads as non-bold. Reserve `GothamMedium`/`GothamBold` for headings/titles only, not small interactive button labels.

**Currency-gain notifications — reuses the existing toast system, new "Pop" style:**
- [ ] `Network.Track.ShowNotification` gained an optional 2nd parameter, `style: string?` — purely additive, every existing call site (wrong direction, skill casts, fan pickup/drop) still works unchanged and defaults to the original plain-fade behavior.
- [ ] `NotificationController.luau` — `style == "Pop"` now also bounces a `UIScale` (new child on `NotificationList.EntryTemplate`, `Scale = 1` default so non-Pop notices are untouched) from `0.3 -> 1` with `Enum.EasingStyle.Back` easing (the overshoot-then-settle "birthday popper" bounce) alongside the usual text fade-in, and shrinks back down alongside the fade-out.
- [ ] Wired at all 3 places currency actually increases: `CarryItemService.TryDeposit` (fan payload deposit, "+N 🌟 FANS!"), `CheckpointValidator.grantLapReward` (lap completion, one combined "LAP COMPLETE! +N 🪙 +N 🌟" since both currencies grant together), `ProcessReceiptManager.processReceipt` (Robux purchase grant, "+N 🪙/🌟 GOLD!/FANS!"). All 3 use `Utils.FormatNumber` for the amount, matching how the currency capsules already display numbers.

**Text readability, round 2 — bold was the actual complaint, not just size:**
- [ ] `CenterAction.ActionButton` — was still `TextScaled: true` + `Font: GothamBold` (missed in the earlier text-size passes since attention was on the LeftMenuBar/toggle/skill buttons, not this one). This is the single button that shows "DEPOSIT FANS"/"DROP FANS"/"PICK UP"/the carried skill's `DisplayName`/"RELEASE SPELL" depending on state — switched to `TextSize: 16`, `Font: GothamMedium`, `TextWrapped: true` (skill names can be multi-word).
- [ ] `LocationToggleButton` — already had a fixed `TextSize: 14` from 2 rounds ago, but kept `GothamBold`; still reported unreadable. Switched to `GothamMedium`. Takeaway: for this project's small HUD buttons, `GothamBold` at small sizes reads as unreadable regardless of `TextSize` — prefer `GothamMedium` (or plain `Gotham`) for anything below ~18px, reserve Bold for headings/titles.

**Fan-pickup progress fill — same HP-bar pattern as skill cooldowns:**
- [ ] "Add similar effect when casting cooldown [to fan pickup] like hp bar" — the 3-second Fan Payload pickup channel had no visual progress indicator (just static "PICKING UP..." text). Added `PickupFill` (`CenterAction.ActionButton`'s child, same structure/pattern as the skill buttons' `CooldownFill`): a thin bar along the button's bottom edge that fills from empty to full over the channel duration.
- [ ] New shared `ItemData.FanPickupChannelSeconds = 3` (`ReplicatedStorage.Configs`) — previously `CarryItemService.FAN_PICKUP_CHANNEL_SECONDS` was a server-only local constant with no way for the client to know the real duration to animate against; `CarryItemService` now reads from `ItemData` too, so there's exactly one place this number lives and client/server can never drift out of sync.
- [ ] `ActionButtonController.updatePickupFill` — driven purely by the `NearbyInteraction` attribute flipping to/from `"PickingUp"` (no new remote): starts the fill tween on entry, cancels/hides on exit (success, cancellation, or walking away all naturally flip the attribute away from `"PickingUp"` server-side within one 0.5s poll).

**Checkpoint detection — the REAL fix this time (numeric root cause found):**
- [ ] `CheckpointValidator.luau` — last round's fix (GetPartsInPart -> a single-sample CFrame point-in-box check) was still not enough; the bug persisted. Root cause, confirmed numerically: `TrackGeometry.CheckpointTriggerThickness = 6` studs, `CHECK_INTERVAL_SECONDS = 0.5`, and Roblox's default walk speed is 16 studs/sec — a player crosses the full 6-stud trigger band in ~0.375s, which is LESS than one poll interval. A single "is the player inside the wall right now" sample taken every 0.5s can legitimately never land during that ~0.375s window. This was a real, general bug affecting any player at any checkpoint — it only *read* as fan-carrying-specific because checkpoint triggers and Fan Payload pickups are anchored at the exact same segment-entry point (`TrackPickupSpawner.Generate`'s `samples[1].Position` == `TrackGenerator`'s `pieceEntryCFrame`), so a player detouring to grab a payload lingers and maneuvers right at that spot instead of running straight through it, changing the timing pattern in a way that made misses feel consistent.
- [ ] Fixed by adding `lastPositionByPlayer: {[Player]: Vector3}` (same pattern `TrackBoundaryMonitor` already uses for its own wrong-direction tracking) and a new `crossedTriggerPlane(lastPosition, currentPosition, triggerPart)`: transforms both positions into the trigger's local space and checks whether local-Z changed sign between polls (crossed the thin axis) while X/Y stayed within the wall's width/height. A `TELEPORT_JUMP_THRESHOLD_STUDS = 40` guard (mirroring `TrackBoundaryMonitor`'s identical pattern) prevents a checkpoint respawn/EnterTrack/ReturnToHub teleport from registering as a bogus crossing. `checkPlayer` now reaches a checkpoint if EITHER the instantaneous point-in-box check passes (covers standing still inside it, e.g. right after a teleport) OR the crossing check passes (covers fast movement between polls). `lastPositionByPlayer` resets alongside `lastOrdinalByPlayer` in `ResetPlayer`/`PlayerRemoving`/leaving InRace state.
- [ ] This is now believed to be the real, complete fix — not another layer to peel back — since the mechanism is fully explained by concrete numbers (thickness/speed/interval), not a guess about physics-query semantics like last round's attempt was.

**Skill Select modal — the loadout picker couldn't handle the full catalog:**
- [ ] "Skill ribbon when setting skills on commercial; too many skills and not showing or intuitive" — `SkillRibbon` was a fixed-width horizontal `Frame` (no scrolling) sized for a handful of entries; with the Skill Shop now able to unlock all 17 skills, entries beyond what fit on screen were simply inaccessible. Replaced with `SkillSelectPanel` (`default.project.json`) — a modal following the exact same backdrop+Card+ScrollingFrame pattern as `MainMenuPanel`/`SkillShopPanel`/`RobuxShopPanel` (`Active: true` on the Card for the same click-outside-to-close reason documented in section 5).
- [ ] `SkillLoadoutController.luau` rewritten to match: `OpenRibbon`/`CloseRibbon` renamed to `Open`/`Close` (call site in `ControlMapper.luau` updated). Lists the FULL `SkillTrees` catalog sorted by `DisplayName` (not just owned skills via `GetOwnedSkills` — reads `SkillLevel_<id>` attributes directly instead, same as `SkillShopController`), each row showing level data. Three visual/interactive states per row: not owned (Level 0) -> dark grey, `AutoButtonColor = false`, not clickable, "Not Owned — see Skill Shop"; owned but equipped in a different slot -> medium grey, not clickable, "Level X / 10 — equipped elsewhere"; owned and available -> blue, clickable, equips into the slot via the existing `Network.Economy.EquipSkill` RemoteFunction.

**More TextScaled -> fixed TextSize cleanup:**
- [ ] "Make text on toggle join race and fan box and skills smaller like the ones on the menu" — `LocationToggleButton` (FAN BOX/COMMERCIAL CENTER/JOIN RACE/LEAVE RACE) and the 3 `BottomRight.SkillNButton`s (show the equipped skill's `DisplayName`, which can be several words — "Track-Wide Scramble" — and was filling the whole circular button via `TextScaled`) all switched from `TextScaled: true` to fixed `TextSize` (14 for the toggle, 13 + `TextWrapped: true` for the 3 skill buttons since their names are more likely to be multi-word on a small round button).

**HUD layout, pass 2 — capsules, visibility gating, and readability:**
- [ ] `default.project.json` — `StatsPanel` (one stacked card) replaced with `StatsRow`: 3 independent pill-shaped `Frame`s (`GoldCapsule`/`FansCapsule`/`CheckpointCapsule`, each `UICorner` radius `[1,0]` for the stadium shape), laid out horizontally via `UIListLayout`, centered top-of-screen (`AnchorPoint [0.5,0]`). `LocationToggle` moved from beneath the old left-side panel to directly beneath this row, still centered. `LeftMenuBar` moved from beneath the stats (where it started this "session") back to the actual top-left corner — then immediately had to move again (see below).
- [ ] `CurrencyDisplay.luau` / `LiveRaceHUD.luau` updated to the new nesting (`StatsRow.GoldCapsule.GoldLabel`, `StatsRow.FansCapsule.FansLabel`, `StatsRow.CheckpointCapsule.LapLabel`).
- [ ] **Grand Prix standings visibility** — `StandingsPanel` now starts `Visible: false` in `default.project.json`. New `Network.Track.GrandPrixStateChanged` RemoteEvent: `GrandPrixManager` broadcasts its `RaceState` ("Waiting"/"Countdown"/"Racing"/"Ended") to all clients on every state transition, plus catches up any player who joins mid-state via a new `Players.PlayerAdded` hook in `GrandPrixManager.Init()`. `LiveRaceHUD` listens and sets `StandingsPanel.Visible = state == "Countdown" or state == "Racing"`. Notable: this is the first thing to actually consume `GrandPrixManager`'s state machine, which turned out to already be real and time-driven (hourly cadence via `os.time()`) even though the roster/scoring parts around it are still stubs — nothing was faked to make this work.
- [ ] **LeftMenuBar text + placement, two separate fixes**: (a) the 3 buttons (`MenuButton`/`SkillShopButton`/`RobuxShopButton`) used `TextScaled: true`, which filled the whole pill — switched to fixed `TextSize: 14` (was reported "too large"). Each button also got a hidden `Icon` `ImageLabel` child (`Image: ""` placeholder) plus a small `applyIconFallback` helper duplicated identically in `MainMenuController`/`SkillShopController`/`ShopUIController` (each owns wiring for its own button) — same "icon if available, else fall back to the existing Text" convention `SkillTrees.IconAssetId` already established, so these 3 buttons are ready to switch to icons the moment real ones are sourced, with zero behavior change today (Image is still `""` everywhere). (b) Separately, `LeftMenuBar` at `Position Y = 0.03` sat directly on top of Roblox's own default top-bar icons (player thumbnail/leaderboard toggle, top-left) — moved down to `Y = 0.15`, clear of it. `StatsRow`/`LocationToggle` were NOT moved (only `LeftMenuBar` was reported as overlapping); flag if that turns out to need the same treatment.

**Skill Shop actually sells the whole catalog now, not just the 3 starters:**
- [ ] Root cause of "shop not showing skills that can be purchased": `SkillShopController` populated its list from `Network.Economy.GetOwnedSkills`, which — correctly, by its own contract — only returns skills the player already owns (the 3 starters). There was never a path to acquire a 4th+ skill. Fixed by having `SkillShopController` iterate the full `SkillTrees` catalog directly (client already requires that module) instead of calling the remote, sorted by `DisplayName`.
- [ ] `SkillTrees.SkillDefinition` gained `UnlockGoldCost: number` — the price to acquire a skill from scratch (Level 0 -> Level 1), distinct from `Levels[1].UpgradeGoldCost` (always 0, meaning "already owned at Level 1," true only for the 3 starters). All 17 skills got a value, reusing each skill's existing `BaseGoldCost` curve-generation parameter as the unlock price (100-400 depending on skill) rather than inventing new numbers.
- [ ] `SkillShopController.renderEntry` now reads `SkillLevel_<id>` as Level 0 (not 1) when the attribute is unset — Level 0 renders "Level 0 / 10" with the `UnlockGoldCost` price; Level 1+ uses the existing upgrade-cost path; `MaxLevel` still shows "MAXED".
- [ ] `HubShoppingManager.TryPurchase` now branches: no owned entry (or `Unlocked == false`) -> `tryUnlock` (spends `UnlockGoldCost`, creates `profile.Data.Skills[itemId] = { Level = 1, Unlocked = true }`, does NOT auto-equip into a loadout slot); owned -> `tryUpgrade` (unchanged logic from last round). Both paths share the same `Network.Track.ShowNotification` feedback pattern ("X UNLOCKED!" / "X UPGRADED!" / "NOT ENOUGH GOLD!").

**All 3 modal panels are real ScrollingFrames now, with smaller fixed text:**
- [ ] `MainMenuPanel.Card.InfoList`, `SkillShopPanel.Card.SkillList`, `RobuxShopPanel.Card.ProductList` — all converted from plain `Frame` to `ScrollingFrame` (`AutomaticCanvasSize: "Y"`, `ScrollBarThickness: 6`). This was already latent breakage waiting to happen for the Skill Shop specifically (17 rows now, was 3) — a fixed-height `Frame` with no scrolling would have clipped most of the list.
- [ ] Every `TextScaled: true` label/button across all 3 panels (titles, close buttons, info rows, skill rows, product buttons) switched to fixed `TextSize` (18 for titles, 13-16 for body/buttons) per explicit "smaller text" feedback.

**Checkpoint detection rewritten — real gameplay bug, not just cosmetic:**
- [ ] Reported: checkpoint passes stop registering while carrying a Fan Payload. `CheckpointValidator.checkPlayer` used `workspace:GetPartsInPart(triggerPart)` (a physics broad-phase query) and checked whether the player's `HumanoidRootPart` appeared in the result set. Nothing in `CarryItemService` touches `CanQuery`/`CanCollide` on the player's own root part (only the carried visual, which is itself `CanQuery = false` so it shouldn't even appear in queries) — the query's exact filtering/capping behavior couldn't be fully pinned down from static reading alone, but a concrete, real confound was found: `TrackPickupSpawner.Generate` places static Fan Payload pickups at the same `pieceEntryCFrame`/`samples[1].Position` anchor `TrackGenerator` uses for checkpoint triggers, so checkpoints and pickups (and now, thanks to 2 rounds ago's persistent-drop feature, potentially *dropped* pickups too) are co-located by construction — extra nearby parts are a real, physically-present factor a broad-phase "what overlaps this volume" query has to sort through. Replaced the whole query with `isInsideTrigger`: a direct `triggerPart.CFrame:PointToObjectSpace(rootPart.Position)` half-extents check — pure geometry, zero dependency on any other part in the world, carried or not. This is strictly more robust regardless of the precise original mechanism, and should be considered the permanent detection method going forward (not a revert candidate).

**Monetization is live, not placeholder:**
- [ ] `MonetizationConfigs.luau` — all 4 Developer Products and the 1 remaining Game Pass now have real Creator Dashboard IDs (previously all `0`): `GoldSmall` 100 Gold/30 Robux (3612671273), `GoldMedium` 550 Gold/150 Robux (3612671406), `GoldLarge` 1200 Gold/300 Robux (3612671461), `FanBoost` 250 Fans/300 Robux (3612671585), `DoubleFans` a.k.a. "Rocket Fans and Gold" 500 Robux (1933401103, doubles Fan Payload deposit value while owned — description unchanged, matches what was already there). `ProcessReceiptManager` and `MonetizationService` needed no logic changes — both were already written to read entirely from this config, so filling in real IDs is the whole fix.
- [ ] `ExclusivePoseBundle` (the pose-unlock game pass) removed from `MonetizationConfigs.GamePasses` and its button removed from `RobuxShopPanel`/`ShopUIController.GAME_PASS_BUTTONS`, per explicit "remove or hide for now." Data model, not just UI, so it can't accidentally get sold — re-adding it later means adding the `GamePassEntry` back plus the JSON button.

**Cooldown visual — 3rd attempt, different technique entirely this time:**
- [ ] `CooldownDisplayController.luau` — the rotating-needle approach (2 sessions running now) kept reading as "a rectangle rotating" per repeated feedback, which is geometrically fair: a needle IS a rotating rectangle, however thin. Replaced with an HP-bar-style fill instead, since there's no rotation left to misread: on cast the button instantly greys out and STAYS grey for the whole cooldown (no simultaneous color tween competing for attention), while a thin `CooldownFill` bar along the button's bottom edge — tinted the button's own normal color — grows from empty to full width over the cooldown duration. The instant it finishes, the button pops back to full color and the bar disappears. `default.project.json`: `CooldownNeedle` replaced with `CooldownFill` on all 3 `BottomRight.SkillNButton`s (identical block, `replace_all`).

**HUD relayout — StatsPanel/Standings swapped sides, toggle button relocated, left-side menu system finally built:**
- [ ] `default.project.json` — `TopLeft` (was standings) and `TopRight` (was Gold/Fans/gear) swapped roles and were renamed to match: `StatsPanel` (left side, unchanged position) now holds Gold/Fans/Checkpoint stacked as 3 rows in one panel; `StandingsPanel` (right side, unchanged position) now holds the Grand Prix standings list. `TopCenter` renamed to `LocationToggle` and moved from top-center to directly beneath `StatsPanel` (same X range/width) — the Fan Box/Commercial Center/Leave Race button now reads as "the button that goes with the stats panel above it," not a floating top-center element. The old `SettingsButton` (gear icon, opened nothing — `ShopUIController.Open()` was a TODO stub) is gone entirely, superseded by the new `LeftMenuBar`'s `RobuxShopButton`.
- [ ] `CurrencyDisplay.luau` / `LiveRaceHUD.luau` / `LocationToggleController.luau` — updated to the renamed panels (`StatsPanel`/`StandingsPanel`/`LocationToggle`); `LiveRaceHUD` in particular now writes to two different panels (`StandingsList` on `StandingsPanel`, `LapLabel` on `StatsPanel`) instead of both living under one `TopLeft`.
- [ ] `LeftMenuBar` (**new**, `default.project.json`) — 3 stacked buttons beneath `StatsPanel`/`LocationToggle`: `MenuButton`, `SkillShopButton`, `RobuxShopButton`. Each opens a full-screen modal (dark backdrop + centered white "Card"); the backdrop itself is a `TextButton` (`Active` implicitly true for buttons) so clicking outside the Card closes the panel, while the Card has `Active: true` set explicitly (Frames default to `Active: false`, which would otherwise let clicks fall through the Card to the backdrop behind it and close the modal even when clicking inside it — caught before it shipped as a bug, not after).
- [ ] `MainMenuPanel` + `MainMenuController.luau` (**both new**) — read-only: player name, Lives, Checkpoint/8, Total Laps Completed, Gold, Fans, and equipped skill names. Everything shown is already a replicated player Attribute (`ProfileManager.SyncAttributes`) — no new remotes, pure display, refreshes on the relevant attribute-changed signals.
- [ ] `SkillShopPanel` + `SkillShopController.luau` (**both new**) — lists every skill `Network.Economy.GetOwnedSkills` (pre-existing RemoteFunction) reports owned, each row showing current level and the Gold cost of the next one, with an UPGRADE button. Since `Network.Economy.PurchaseItem` is a fire-and-forget RemoteEvent (not a RemoteFunction), the row re-renders off attribute changes rather than a return value — see the `ProfileManager`/`HubShoppingManager` entry below for the other half of this.
- [ ] `ProfileManager.SyncAttributes` — now also sets one `SkillLevel_<id>` attribute per owned skill, so the Skill Shop (and anything else client-side) can read current skill levels without a remote round-trip. New replication path, additive — nothing else reads these yet besides `SkillShopController`.
- [ ] `HubShoppingManager.luau` — was a complete stub (`TryPurchase` always returned `false`, `Init` connected nothing) despite already being called from `Main.server.luau`'s bootstrap. Implemented for real: `Network.Economy.PurchaseItem`'s `itemId` is a skillId; upgrading spends `SkillTrees[itemId].Levels[currentLevel + 1].UpgradeGoldCost` Gold to move the skill to the next level (capped at `MaxLevel`), server-authoritative (re-validates ownership, level cap, and Gold balance — the client-side afford/maxed styling in `SkillShopController` is UX only). Success/failure surfaces through the same `Network.Track.ShowNotification` toast system from last round ("SKILL UPGRADED!" / "NOT ENOUGH GOLD!"). Deliberately scoped to upgrading already-owned skills only — there's still no "unlock a new skill" feature, flagged in both this module's and `SkillShopController`'s docstrings.
- [ ] `RobuxShopPanel` + `ShopUIController.luau` (rewritten, not new) — `Open`/`Close` were TODO stubs before (the old gear button called `Open()` into a void). Now lists all 4 `MonetizationConfigs.DeveloperProducts` + 2 `GamePasses` as fixed named buttons (only 6 total, no clone-template needed), labeled from the config data itself, wired to the already-working `PromptRobuxProduct`/`PromptGamePassPurchase` (unchanged — those two were the only part of this module that actually worked before this round).

**Notification system generalized from a single-purpose flash into the one system every toast goes through:**
- [ ] `Network.Track.WrongDirectionWarning` renamed to `Network.Track.ShowNotification(text: string)` — server → client only, fire-and-forget text toast, not tied to wrong-direction anymore.
- [ ] `StarterGui.MainHUD` — old single `WrongDirectionLabel` replaced with `NotificationList` (a `Frame` + `UIListLayout` + a hidden `EntryTemplate` TextLabel) in `default.project.json`. Stacking is just "each active toast is another child" — the `UIListLayout` reflows automatically as entries are added/destroyed.
- [ ] `NotificationController.luau` (**new**, replaces deleted `WrongDirectionController.luau`) — clones `EntryTemplate` per call, fades in (0.2s) → holds (1.2s) → fades out (0.6s) → destroys. Fully generic; every caller just passes a string.
- [ ] `SkillTrees.luau` — every one of the 17 skills got a new `ActivationNoticeText: string` field (e.g. `DashSelf` = "DASHING!", `ReverseControlTarget` = "RUNNING BACKWARD!", the rest recommended in the same punchy style: "SLOWED DOWN!", "SHOCKED!", "SHIELDED!", etc.).
- [ ] Notification recipients follow the skill's own audience, not always the caster: `TargetedSkillManager`/`GlobalSkillStateMachine`/`SelfSkillManager`'s shared `resolveAndApply`/`activate` functions now fire `ShowNotification` with `skillDefinition.ActivationNoticeText` — **Target** skills notify the target (whoever the effect landed on), **Global** skills notify every currently-InRace player the effect actually applied to, **Self** skills notify the caster. `CarryItemService` fires its own two: `"PICKED UP FANS!"` on a completed 3-second Fan Payload channel, `"DROPPED FANS!"` on any drop (see below) that actually released a Fan Payload. `TrackBoundaryMonitor`'s wrong-direction warning now goes through the same remote with literal text `"WRONG DIRECTION"` — behavior unchanged, just re-plumbed.

**Skill pickups are now fully automatic — no button press:**
- [ ] `CarryItemService.TryPickup` no longer has a Skill-pickup branch at all; `Network.Economy.PickupItem` now only ever starts a Fan Payload's 3-second channel. A new local `tryAutoGrantSkillPickup(player, rootPart)`, called from the existing 0.5s proximity loop, instantly grants a nearby Skill pickup to any empty-handed InRace player — the "no need to press pick up" ask, applied to skills only (Fan Payloads deliberately kept their explicit-press 3-second channel, unchanged).
- [ ] **5-second anti-spam gate**: a new `lastSkillCastAt: {[Player]: number}` table (`os.clock()` timestamps) is written in `ReleaseTrackItem` right after a successful cast dispatch. `tryAutoGrantSkillPickup` refuses to grant if `os.clock() - lastSkillCastAt[player] < 5`. This is a pure server-side gate — nothing client-visible changes except the player standing next to a skill pickup and it just... not granting yet.
- [ ] `ActionButtonController` — the `TrackSkill` carry mode no longer shows a hardcoded "RELEASE SPELL" string. A new `CarriedSkillId` player attribute (set by `CarryItemService` alongside `CarryItemType`, cleared on drop/release) is read client-side and resolved through `SkillTrees[carriedSkillId].DisplayName` for the button label — falls back to "RELEASE SPELL" only if the id can't resolve (mirrors the existing "no icon → show text name" convention already established for `SkillTrees.IconAssetId`, which is still unpopulated everywhere).

**Fan Payloads never just vanish anymore:**
- [ ] `TrackPickupSpawner.SpawnDroppedPickup(position: Vector3)` (**new**) — appends a brand-new, immediately-available marker to the same registry the static markers live in, at an arbitrary world position (not tied to a track segment). A dropped payload is indistinguishable from a normal one from that point on: pick-able by anyone, same 30-second consume/respawn cycle. Required a small refactor — `pickupsFolder` is now a module-level upvalue (was a `Generate()`-local `pickupsFolder` var that has been renamed to `newFolder` to avoid shadowing it) so a drop can parent into the live folder outside of `Generate()`.
- [ ] `CarryItemService.DropAtLocation(player, position?)` (**new**, `Drop` is now a thin wrapper around it with no explicit position) — if the player is carrying a Fan Payload, calls `SpawnDroppedPickup` at `position` (or the player's current root position) before clearing carry state, instead of just discarding it. Skill carries still just clear — skills were never meant to litter the track, and the user's ask was specifically about fans.
- [ ] Three trigger paths, one shared function: (1) **kicked out of bounds** — `ArcadeManager.HandleTrackViolation` already called `CarryItemService.Drop(player)` *before* teleporting back to the checkpoint, so unifying `Drop`→`DropAtLocation` made this persist "for free," no `ArcadeManager` edit needed, and the drop lands at the actual out-of-bounds spot. (2) **stunned** — the existing 0.5s proximity loop now also checks `EffectStackManager.IsStunned(player)` for any InRace player currently carrying a Fan Payload and calls `DropAtLocation` the moment it's true. (3) **left the game** — `CarryItemService.Init`'s `Players.PlayerRemoving` handler now calls `DropAtLocation(player)` *before* clearing any state (character/root part are still around at that point).
- [ ] `EffectStackManager.IsStunned(player): boolean` (**new**) — true if any currently-active effect on the player has the new `SkillEffects.EffectDefinition.IsStun` flag set. Only `ShockTarget` has `IsStun = true` today; every other one of the 13 cataloged effects is explicitly `false`. This keeps "which skills stun" a single source of truth instead of hardcoding a skill-id check somewhere else.
- [ ] Confirmed no circular require: `CarryItemService` now requires `EffectStackManager` directly (previously only reached it indirectly via the 3 skill managers for `CastSkillDirect`) — `EffectStackManager` only requires `SkillEffects` (a config), so this is safe.

**Checkpoint/lap model — a real pivot, not an extension:**
- [ ] The 3-sessions-ago "8 checkpoints = 8 track types across a whole course" model (`CourseSequence.luau`) is now explicitly marked SUPERSEDED in its own docstring. The user directly clarified the actual design: **8 checkpoints = the 8 segments of ONE oval lap.** `TrackBlueprints.luau` changed accordingly — `IsCheckpoint` removed, every segment now has `CheckpointOrdinal == SegmentIndex` (1-8).
- [ ] `CheckpointValidator.luau` — real implementation (was a stub): strict sequential order (only `lastOrdinal + 1` counts, so skipping is impossible), checkpoint 8 → 1 completes a lap, reads actual trigger `Part`s built by `TrackGenerator` (not recomputed independently) so it stays correct if segments are randomized later. Replicates `CheckpointOrdinal` attribute — `LiveRaceHUD`'s "Checkpoint X / 8" display (built 3 sessions ago, never had real data) should now actually update.
- [ ] `ArcadeManager` — `EnterTrack` resets checkpoint progress; `HandleTrackViolation` now respawns at the player's **actual** last-passed checkpoint (`CheckpointValidator.GetCheckpointCFrameForPlayer`) instead of always the fixed track start. Also now drops whatever the player was carrying on violation/leave (`CarryItemService.Drop`).
- [ ] `ProfileTemplate.luau` — added `TotalLapsCompleted`. `EconomyRates.luau` — added `LapCompletionGoldReward` (10) / `LapCompletionFanReward` (5), granted by `CheckpointValidator` on lap completion.
- [ ] Direction-approach exploits (e.g. walking the whole lap backward to re-enter checkpoint 1 from behind) are deliberately NOT specially guarded against in `CheckpointValidator` — walking it backward takes exactly as long as running it forward, so there's no shortcut to prevent; `TrackBoundaryMonitor`'s existing cumulative-backward-movement warning (built last session) already covers the player-facing signal.

**Pickup/carry system — went from "one static marker" to a real respawn economy:**
- [ ] `TrackPickupSpawner.luau` — rewritten with real consume/respawn state (`PickupEntry` registry, `ConsumePickup`/`IsPickupAvailable`), 30-second respawn per marker (was permanent/static before).
- [ ] `CarryItemService.luau` — Fan Payload pickup is now a real 3-second channel: `NearbyInteraction = "PickingUp"` during the wait, re-validated after (still in range of *that specific* pickup, still empty-handed, still available) before granting. A visible carried-payload part (`WeldConstraint` to the `HumanoidRootPart`) now follows the character while carrying, removed on drop/deposit/violation.
- [ ] `SkillPickupSpawner.luau` (**new**) — 3 test-skill pickups at each of the 8 checkpoints (24 total), color-coded by `CastType`, instant pickup (only Fan Payloads got the 3-second spec), 30-second respawn with a freshly-random skill on each respawn.
- [ ] `TargetedSkillManager`/`GlobalSkillStateMachine`/`SelfSkillManager` — each got a new `CastSkillDirect(player, skillId)` entry point (refactored the existing cast logic into a shared `resolveAndApply`/`activate` function so there's no duplicated logic): Level 1, no ownership/cooldown check, `GlobalSkillStateMachine`'s still respects the server-wide Idle/Active/Cooldown gate. This is what `CarryItemService.ReleaseTrackItem` calls — "Release Spell" now actually does something for the first time.
- [ ] `ActionButtonController` — added the `PickingUp` mode ("PICKING UP...", not clickable) for the 3-second channel window.

**Cooldown visual — redesigned per explicit feedback ("showing a rectangle rotating," not the intended clock effect):**
- [ ] Removed the separate dark `CooldownOverlay` square (that's what was reading as "a rectangle"). `CooldownDisplayController` now directly greys out the skill button's own `BackgroundColor3` on cast, tweens it back to normal over the cooldown duration, and a thin white needle sweeps 0→360° on top — "grey out, then a line rotating like a clock slowly returning the color," closer to the literal ask.
- [ ] Skill buttons now also show the equipped skill's name (was hardcoded "1"/"2"/"3") — this shipped as part of last round but is grouped here since it's the same visual area.

**Fan box crowd — reworked again per direct feedback ("loaded noob does not look like an avatar at all"):**
- [ ] `FanBoxGenerator.luau` noob figures rebuilt from 3 parts (legs/torso/head, no arms, squashed proportions) to 6 parts matching REAL classic-R6 default-avatar part-size ratios (Head 2x1x1, Torso 2x2x1, each Arm/Leg 1x2x1 — scaled uniformly by `NOOB_SCALE = 0.5`, not independently guessed dimensions). Added a `SpecialMesh(MeshType.Head)` on the head part for the rounded classic-noob head silhouette (a stock Roblox mesh type, zero Toolbox dependency) — **UPDATE from the very next playtest: confirmed broken, not just unverified.** `UnionAsync` errored on all 20/20 pods (`CSG: One of the primitives was of unknown type (error -4)`) — CSG doesn't support legacy `SpecialMesh` as a union primitive at all, so every pod silently fell back to the plain block placeholder, the exact regression the whole redesign was meant to avoid. Fixed by a new `stripSpecialMeshes()` call in `buildCrowdMesh` right before `UnionAsync`, destroying the head's `SpecialMesh` on the union path only — `BUILD_AS_SINGLE_MESH = false` (unmerged inspection view) still shows the rounded head, since stripping only happens in the union phase; the shipped merged mesh has a plain block head instead. A real rounded head in the merged mesh would need an actual `MeshPart` (real mesh geometry, which `UnionAsync` does support), not attempted this round.
- [ ] Arrangement changed from a flat 10x4 grid to 3 ascending stadium-bleacher-style step platforms (`STEP_HEIGHTS = {2, 4.5, 7}` studs, each 4 studs deep) with a row of 7 noob figures standing on top of each step (21 figures total, vs. 40 before) — per explicit instruction ("3 long blocks with increasing height to mimic steps, then place the noob avatar(s) on top of each step"). Step blocks are included in the same `UnionAsync` call as the figures, so the whole stand is still one `CrowdMesh` BasePart.
- [ ] **Build process now explicitly two-phase**, per direct instruction not to combine both steps into one unreviewable pass: `buildStepsAndCrowdParts` (phase 1 — builds every step + figure part, plain and inspectable) is now a separate function from the `UnionAsync` merge (phase 2, `buildCrowdMesh`, which calls phase 1 then unions the result). A new module-level `BUILD_AS_SINGLE_MESH = true` toggle switches between them — set `false` locally to leave every part individually visible in Studio (no union at all) for a from-scratch geometry check, flip back to `true` to ship the merged version. Defaults to `true` (merged) since that's what actually ships; the toggle exists for verification, not as a runtime setting.
- [ ] **Batched concurrent pod generation**: `GenerateRing` used to build all 20 pods one at a time, fully sequentially (each pod's `UnionAsync` yield blocking the next pod from starting). Now precomputes all 20 pod placements first (still sequential — each track piece's exit CFrame feeds the next sample, can't be parallelized), then builds pods in concurrent batches of `GENERATION_BATCH_SIZE = 4` via `task.spawn` + a pending-counter wait loop, moving to the next batch only once the current one's 4 unions finish. Directly answers "for multiple joiners, do it by batch to ensure results" — bounded concurrency (not all 20 CSG ops firing at once) makes total generation faster and more predictable, so fan box pods are more reliably ready before a burst of players joins right after server start. `GenerateRing` still fully blocks until every pod exists before returning, so the existing ordering guarantee (`FanBoxGenerator.Init()` before `FanBoxSlotManager.Init()` in the bootstrap script) is unchanged — no pod is ever looked up by slot assignment before it exists.
- [ ] Slot ASSIGNMENT itself (`FanBoxSlotManager.AssignSlot`, one player -> one pod) was considered for batching too but isn't: Roblox runs one event handler to completion before the next starts, so concurrent `PlayerAdded` firings can't actually race each other inside a synchronous, non-yielding function like `AssignSlot` — there was no real bug there to fix, only the pod-generation side had genuine async/concurrency exposure.

**Fan box ring now auto-sizes to the server's actual player cap (same playtest round, follow-up question: "where is settings for max players... can you autodetect it"):**
- [ ] `Players.MaxPlayers` is the real setting (Studio -> Home tab -> Game Settings -> Players -> Max Players; also readable live as `game.Players.MaxPlayers`). `FanBoxGenerator.computePodsPerPiece()` (**new**) reads it and derives straight/curve pods-per-piece from it, replacing the fixed `STRAIGHT_PODS_PER_PIECE = 3` / `CURVE_PODS_PER_PIECE = 2` constants — kept as a 3:2 WEIGHT ratio (`STRAIGHT_POD_WEIGHT`/`CURVE_POD_WEIGHT`) scaled by `MaxPlayers / 20` and rounded, so the original fixed 12+8=20 split still comes out exactly the same at the default `MaxPlayers = 20`. Falls back to treating `MaxPlayers` as 20 if it's ever unset/0 (shouldn't normally happen).
- [ ] `FanBoxSlotManager.AssignSlot` no longer loops a hardcoded `TOTAL_SLOTS` (which would have silently drifted out of sync with whatever `FanBoxGenerator` now actually builds) — it walks `FanBoxes:GetChildren()` directly, matching by the `__EmptySlot_` name prefix and reading each pod's own `SlotIndex` attribute (already set by `FanBoxGenerator.buildPod`) as the source of truth. Self-consistent by construction with however many pods actually exist, regardless of `MaxPlayers`.
- [ ] Capacity ceiling (a server can't have more concurrently-assigned fan boxes than pods that exist) still technically exists but should no longer bite in practice, since the pod count now tracks the server's own configured cap instead of a number picked independently of it.

**Fan stand orientation bug ("facing sideward not the track") — same playtest round, fixed:**
- [ ] Root cause: `podOffsetCFrame()` only translates pods in local **-X** (that's the axis that actually pushes a pod out and away from the track), so within a pod's own local frame, local X is "toward/away from the track" and local **Z is "along the track's direction of travel."** The first stepped-riser build ascended the 3 steps along Z, not X — so the whole stand was arranged lengthwise alongside the track (sideways) instead of stepping back away from it. Swapped: steps now ascend along local X (`stepXCenter`), shortest step nearest `X = 0` (closest to the track, its lowest part facing it, per explicit instruction), tallest step furthest into `-X`; the row-of-figures spread (`NOOBS_PER_STEP`) now uses local Z (parallel to the track) instead of X. Step block `Size`/`FanBoxTiers.PodBaseSize` component usage swapped to match (depth now measured against `PodBaseSize.X`, width against `PodBaseSize.Z`).

**4 more fixes from the same playtest round:**
- [ ] **Every fan box pod showed a crowd, not just the assigned player's** ("still seeing all fanboxes filled instead of just 1"). Root cause: `FanBoxGenerator` builds all 20/40/N pods' full crowd geometry up front (before anyone has joined) so they physically exist, but nothing was hiding an UNCLAIMED pod's crowd — every pod looked equally "occupied" regardless of whether a player actually held it. Fixed: `buildPod` now sets a fresh `CrowdMesh.Transparency = 1` (hidden) right after building it; `FanBoxSlotManager.AssignSlot`/`ReleaseSlot` (**new** `setPodCrowdVisible` helper) flip it to `0`/`1` as pods actually change hands. Only the one pod a player is currently assigned to ever shows a crowd now.
- [ ] **Noob figures faced sideways, not the track** (steps confirmed correct this round). Root cause: `buildNoobFigureParts` built each figure via a pure translation (`CFrame.new(localX, localY, localZ)`, no rotation), so every figure's forward direction defaulted to `originCFrame`'s own -Z — which is "along the track" (same axis mistake as the step-orientation bug, just never corrected for the figures themselves). Fixed: figures are now built via `CFrame.lookAt(footPosition, footPosition + originCFrame.XVector, Vector3.new(0,1,0))`, aiming each figure's LookVector down `originCFrame`'s +X — the same "toward the track" axis the steps now correctly ascend away from.
- [ ] **HazardBar ("rod") obstacles reportedly appearing inside the Commercial Hub.** Traced (hand-derived oval geometry, not just a guess) to `HubGenerator`'s old flat `HUB_RADIUS = 140`: the Hub sits at the oval's centroid, and the closest the track's own paved surface ever gets to that centroid is along the two straights, at `TrackGeometry.CurveRadius - TrackGeometry.SegmentWidth/2` = `180 - 36` = **144 studs** at current values — meaning the old 140 left only ~4 studs of real clearance between the Hub's edge and the track. `HUB_RADIUS` is now derived from `TrackGeometry` with an explicit `HUB_RADIUS_SAFETY_MARGIN = 40` (`180 - 36 - 40 = 104`), giving ~40 studs of real clearance instead of ~4, and staying safe automatically if `TrackGeometry`'s dimensions ever change instead of silently drifting back into the track. (The derivation only pins down the tight straights-clearance number for certain — it doesn't independently confirm the exact hazard-bar case reported, since a HazardBar at a straight segment's own midpoint measured out to ~171 studs of clearance in the same derivation; either way, cutting the Hub down to a real margin resolves it with room to spare.)
- [ ] **"Maybe pause game until all are loaded correctly"** — implemented for real via Roblox's actual character-spawn gate, not a fake loading screen: `Main.server.luau` sets `Players.CharacterAutoLoads = false` as the very first statement (before any `require`), runs every `Init()` (data, world geometry, combat state, Hub, security, core loop) exactly as before, then at the very end explicitly calls `player:LoadCharacter()` for everyone already connected plus a permanent `Players.PlayerAdded` handler for everyone who joins afterward. A player who connects while the server is still generating the world (Track/Hub/FanBoxes — several of which, like FanBoxGenerator's batched `UnionAsync` calls, take real wall-clock time) now simply doesn't get a character until generation is confirmed fully done, instead of potentially spawning into a half-built map. Checked every other `Players.PlayerAdded` handler in the codebase (`ProfileManager`, `PlayerStateService`, `CarryItemService`, `GrandPrixManager`, `FanBoxSlotManager`, `FansBoxRenderer`) — none of them depend on `player.Character` existing at join time, so none needed changes.

**Next playtest round — 1 regression from the load-gate above, plus 2 explicitly-requested architecture changes:**
- [ ] **`ControlMapper` hung on `PlayerGui:WaitForChild("MainHUD")`, tripping Roblox's "Infinite yield possible" warning** — a direct regression from the character-spawn gate above. `MainHUD.ResetOnSpawn` was already `false` (ruled out as the cause), so this isn't the usual "GUI resets every respawn" issue — empirically, a player's very FIRST StarterGui-to-PlayerGui clone still requires at least one character spawn to happen at all, regardless of `ResetOnSpawn`. Gating character spawn on the ENTIRE world-gen sequence (the previous round's fix) held that first clone hostage to the slowest systems (FanBoxGenerator's per-pod `UnionAsync`, at the time). **Fixed by narrowing the gate**: `Main.server.luau` now releases characters right after `TrackGenerator.Init()` + `HubGenerator.Init()` — the only two systems that are actually unsafe to spawn before (no floor, no real `SpawnLocation`) — instead of waiting for the full `Init()` sequence. `TrackPickupSpawner`/`SkillPickupSpawner`/`FanBoxGenerator` now run AFTER character release; a player spawns at the Hub regardless, so a few extra seconds of background generation on parts of the map they can't reach yet is harmless.
- [ ] **Fan box crowds are now templated, not built per pod** (explicit ask: "generate the model fanboxes first and add them to assets, then just call corresponding model for the fanbox depending on number of fans"). New `FanBoxCrowdTemplates.luau` owns all the noob/step-building logic (moved out of `FanBoxGenerator`) and builds the 5 `FanBoxTiers` crowd shapes exactly ONCE at server start — 1 real `UnionAsync` call (the base/unscaled shape), then the other 4 tiers are that same result `Clone()`d with a different `.Size` baked in (a `UnionOperation` supports resizing via `.Size` same as any `BasePart` — this is the exact operation `FansBoxRenderer` used to do live via tweening, just done once ahead of time instead of per-frame). All 5 are stored under `ReplicatedStorage.Assets.FanBoxCrowdTemplates` (a real, inspectable "assets" folder, as asked). `FanBoxGenerator.buildPod` now just clones Tier1 and repositions it (`FanBoxCrowdTemplates.TemplateOffsetFromOrigin` — see that module's docstring for why a plain CFrame assignment would misplace the clone). `FanBoxGenerator.SwapPodTier` (**new**, used by `FanBoxSlotManager`) swaps a pod's crowd to whatever tier template actually matches, in place. Net effect: UnionAsync calls at server start drop from (pod count, which scales with `Players.MaxPlayers`) down to exactly 1, and `FanBoxGenerator.GenerateRing` no longer needs the batched-concurrency scheme a from-scratch union-per-pod design required (removed — it's a plain sequential loop again, since pod construction is now just Clone + CFrame set, nothing yields).
- [ ] **Fan tiers now actually graduate live, not just once at assignment** — a real gap in the previous design: `FansBoxRenderer` (client) only reacted to `TotalFans` changing for whichever player was VIEWING their own box; there was no mechanism keeping a pod's crowd in sync with its occupant's CURRENT tier if it changed while they held the pod, beyond that one client's own tween. Now server-side: `FanBoxSlotManager.AssignSlot` sets up a `player:GetAttributeChangedSignal("TotalFans")` connection (stored per-player, disconnected on `ReleaseSlot`) that calls `FanBoxGenerator.SwapPodTier` any time it fires — every client sees the swap, since it's a real instance change replicated from the server, not a per-viewer tween. `FansBoxRenderer.luau` (client) is now fully superseded (its whole job — tweening `CrowdMesh.Size` — would double-apply scaling on top of an already-correctly-sized template clone) — **deleted**, along with its require/`Init()` call in `Main.client.luau`.
- [ ] **Track pieces (Straight/Curve) are now templated too** (explicit ask, mirroring the fan-box change: "generate and save curve and straight segments first then save in assets then call as needed"). New `TrackPieceTemplates.luau` builds ONE Straight + ONE Curve model once, at `CFrame.new(0,0,0)`, each with an invisible `EntryPivot` Part (at the template's own local origin) set as `PrimaryPart` specifically so `Model:PivotTo(actualEntryCFrame)` repositions the whole piece correctly — without an explicit pivot exactly at the entry point, `PivotTo` falls back to a bounding-box-derived default that does NOT line up with where `TrackGenerator`'s chaining math expects the piece to sit. Stored under `ReplicatedStorage.Assets.TrackPieceTemplates`. `TrackGenerator.buildPieceFromTemplate` (**new**) clones + `PivotTo`s the matching shape, destroys the `EntryPivot`, then recolors the clone's `Road`/`RoadChord_*`/`Barrier` descendants to match the segment's theme (a property set, not a rebuild) — falls back to building fresh via `TrackPieceBuilder` if templates somehow weren't built yet. Unlike the fan-box case, `TrackPieceBuilder` never used `UnionAsync` — plain `Part` creation was already cheap — so this alone was never expected to fix the hazard-rod report; it doesn't touch `addHazardBar`'s positioning logic at all.

**Fan box occupancy visibility — reverted per direct instruction ("we do not need to hide empty unclaimed fanboxes, just ensure the one player gets one fan box"):**
- [ ] Last round made unclaimed pods invisible (`CrowdMesh.Transparency = 1`) specifically to answer "still seeing all fanboxes filled" — turns out that wasn't the actual ask; the only real requirement was always the 1-player-1-pod ASSIGNMENT, which was already correct and untouched by this. Reverted: `FanBoxGenerator.buildPod` no longer hides a fresh pod's crowd; `FanBoxGenerator.SwapPodTier` dropped its `visible` parameter entirely (a pod is always visible, just at whatever tier). `FanBoxSlotManager.ReleaseSlot` now resets a vacated pod back to Tier1 ("Empty") before returning it to the pool, so it doesn't keep showing the departed player's crowd size forever, but it's never literally invisible. Assignment logic itself (walk `FanBoxes:GetChildren()`, match `__EmptySlot_` prefix, one pod per player) is unchanged.

**Hazard "rod" — CONFIRMED FIXED by the user after 3 rounds of investigation.** Root cause was physics drift, not a placement-math bug (the spawn CFrame was correct all along, re-derived 3 times with no error found): `HazardBar` is unanchored + `CanCollide = true`, so every player collision imparts a real impulse/torque, `AlignPosition` was force-based (spring-like, not a hard constraint) so repeated/fast hits could out-pace its restoring force, and nothing ever re-asserted `AssemblyAngularVelocity` after creation so a hit could permanently tip the spin axis or change its rate with zero correction. **The fix, confirmed working — reusable pattern for any future "must always return to a fixed spot/spin cleanly" unanchored+collidable part**: set `AlignPosition.RigidityEnabled = true` (hard position lock, snaps back immediately instead of springing, so it genuinely cannot drift regardless of hit frequency/force) AND continuously reassert the intended `AssemblyAngularVelocity` every frame via a `RunService.Heartbeat` connection (disconnected via the part's `Destroying` event so it doesn't leak across regenerations). See `TrackGenerator.addHazardBar` for the reference implementation. Also saved to durable memory (`hazard-physics-drift-fix` — see `MEMORY.md`) since this project explicitly asked it be remembered.

**Fan box "elevated" + "unoccupied fanbox looks full" — same root cause, both fixed by dropping size-based tiers entirely:**
- [ ] Root cause of "elevated": the tier system rescaled a SHARED crowd mesh via `.Size` (baked in once per tier template). Resizing a `UnionOperation` via `.Size` scales the WHOLE mesh around the union's own natural centroid (wherever Roblox's CSG engine places it) — NOT around the ground plane the figures' feet stand on. Worse, the crowd's natural bounding box never matched `FanBoxTiers.PodBaseSize` (that was the OLD flat-block placeholder's footprint, never re-derived for the stepped-riser design) — so even "Tier1 at 1x scale" was already forcibly distorting the shape away from its natural, correctly-grounded proportions, visibly lifting (or sinking, depending on tier) the whole crowd off the ground.
- [ ] **Fixed by redesigning tiers as crowd DENSITY instead of a size scale** — directly matches what was actually asked for ("first tier should have no noobs, second tier a few noobs and far apart... until full house steps"). `FanBoxCrowdTemplates` now builds 5 fully independent unions (one per tier, `NOOBS_PER_STEP_BY_TIER = {0, 2, 4, 6, 7}`), sharing the exact same fixed step geometry every time (so every tier is grounded identically — no rescaling, no centroid-shift risk at all) and varying only how many figures stand on each step. Tier1 = bare steps, 0 figures. This is 5 real `UnionAsync` calls now (up from 1), still far cheaper than the original per-pod design.
- [ ] This ALSO resolves "unoccupied fanbox looks full" without reintroducing any hide/show logic (which was explicitly rejected the round before this one) — since every unclaimed pod shows Tier1 by construction, and Tier1 now genuinely has zero figures, an unclaimed pod just naturally looks like empty bleachers. No `Transparency` toggling needed.
- [ ] `FanBoxTiers.MeshScale` removed entirely (unused now) from both the type and all 5 tier entries — `PodBaseSize` stays, now used only for the stand's fixed footprint width (spacing figures across each step), not for scaling anything.

**Still reported floating after the above — and worse — plus "should be something a player can step on, not pass through." Traced to the SECOND bug in the same area: repositioning math relied on an unverified assumption about UnionAsync's result CFrame:**
- [ ] The density redesign fixed the `.Size`-rescale distortion, but repositioning a tier clone still composed `desiredOriginCFrame * (the union result's own .CFrame, recorded once at build time)` — an assumption that a `UnionOperation`'s auto-assigned CFrame is a simple, composable offset from its build origin. That assumption was never actually verified against Roblox's real CSG behavior, and evidently doesn't hold (or at least not reliably/consistently across different tier geometries) — explaining both "still floating" and "now higher" (different tiers' unions can get different auto-assigned CFrames, so the error itself could differ tier to tier).
- [ ] **Fixed by sidestepping the question entirely** — switched to the exact same robust pattern already proven working for track pieces (`TrackPieceTemplates`'s `EntryPivot`): each tier's `CrowdMesh` is now wrapped in a small Model alongside an invisible `GroundPivot` Part at the known-correct build origin (`CFrame.new(0,0,0)`), set as the Model's `PrimaryPart`. `FanBoxGenerator.cloneTierAt` clones the whole Model and repositions it via `Model:PivotTo(desiredOriginCFrame)` — which is correct regardless of whatever CFrame the `CrowdMesh` part itself happens to have, since `PivotTo` only cares about the relative transform from `GroundPivot`, never the `CrowdMesh` part's own CFrame directly. The `CrowdMesh` part is then extracted from the clone and the temporary Model+`GroundPivot` wrapper discarded — every other piece of code downstream (`SwapPodTier`, `FansBoxRenderer`... already deleted, pod lookups by `"CrowdMesh"` name) is completely unaffected, still just sees a plain BasePart.
- [ ] **Also made the fan box stand collidable** (`CanCollide = true`, was `false` — an explicit ask: "fanbox should be something a player can step on, not pass through") on both `FanBoxCrowdTemplates.buildCrowdMeshForTier`'s successful-union path and both fallback-block builders (`FanBoxCrowdTemplates` and `FanBoxGenerator`'s copies).

**⚡ This round is different from every one before it: direct Roblox Studio MCP tool access became available mid-session (execute_luau, inspect_instance, screen_capture, start_stop_play, etc.) — meaning everything below was VERIFIED LIVE in a running Play session, not written blind and left for the next playtest.** This finally, definitively fixed the fan box floating bug after 3 blind rounds — see below for how.

**Fan box floating — ROOT CAUSE FOUND (not just another guess) via live Studio inspection, CONFIRMED FIXED via live re-test:**
- [ ] Used `execute_luau` to directly read a real assigned pod's `CrowdMesh.CFrame.Y` in a running server — it was `11.75`, when the geometry (`Size.Y = 9.5`, built from `Y=0`) should have put it at `4.75`. Empirically tested `UnionAsync`'s actual CFrame-assignment behavior (a controlled 3-box union in a live server) to rule out bad assumptions there — it behaves exactly as expected (bounding-box centroid). That eliminated the "unverified CSG CFrame" theory from last round's fix as the remaining cause.
- [ ] **Actual root cause**: `FanBoxGenerator.SwapPodTier` read `targetCFrame = oldCrowdMesh.CFrame` — the OLD crowd mesh's own CFrame, which is ITS CENTROID (e.g. Y=4.75 for a populated tier), not the pod's actual ground-level origin (Y=0) — and passed that as the new `originCFrame` to reposition the replacement clone. Every single swap therefore re-pivoted the new clone's `GroundPivot` to the PREVIOUS mesh's centroid height instead of true ground, adding that height again on top. `FanBoxSlotManager.AssignSlot` always calls this at least once per assignment (even a same-tier reassignment), so every assigned pod was elevated from the very first swap, compounding further with each later tier-graduation swap — exactly matching "still floating... and now higher."
- [ ] **Fix**: `buildPod` now stamps the pod's real ground-level `originCFrame` as a CFrame attribute (`pod:SetAttribute("OriginCFrame", originCFrame)`) at creation time — CFrame attributes are natively supported by Roblox, confirmed via a live `SetAttribute`/`GetAttribute` round-trip test. `SwapPodTier` now reads `pod:GetAttribute("OriginCFrame")` instead of ever inferring a ground reference from a mesh's own CFrame again.
- [ ] **Verified live, 3 ways, in a running server**: (1) direct inspection immediately after `buildPod` — `CrowdMesh.CFrame.Y` exactly matches `originY + size.Y/2` for the initial assignment; (2) 3 consecutive `SwapPodTier` calls in a row (worst case for compounding) still land exactly on the expected grounded value, no drift; (3) the REAL end-to-end path — setting a player's `TotalFans` attribute (which fires `FanBoxSlotManager`'s live listener, the actual production code path, not a direct call) and confirming the resulting crowd swap is correctly grounded. A `screen_capture` of the live result visually confirms the crowd sitting flush on the ground with no gap.
- [ ] **A methodology trap worth remembering**: `execute_luau`'s `require()` does NOT share Luau's module cache with the actual running server scripts — calling `require(SomeModuleScript)` from an MCP `execute_luau` session creates a FRESH, independently-initialized copy of that module (its own upvalues, e.g. a fresh `nil` `templatesFolder` that never had `BuildAll()` called on it), not a reference to the live game's already-initialized instance. This produced several confusing false "fallback block" / `nil` results mid-investigation before being identified — the fix is to verify by (a) reading live instance properties directly (`workspace`/`ReplicatedStorage` traversal, no `require`) or (b) triggering the real code path indirectly (e.g. via `SetAttribute` + `task.wait()`, letting the ALREADY-CONNECTED live listener run), never by calling a freshly-`require`'d copy of game logic and trusting its state to match the live game.

**Fan box tiers expanded 5 → 8, per direct instruction ("add 3 more layers and adjust graduation, may increase number"):**
- [ ] `FanBoxTiers.luau` — 3 new tiers inserted, and the WHOLE threshold curve retuned (not just 3 more steps tacked onto the old spacing, which would've either bunched at the bottom or needed an awkwardly huge top number): `Empty(0) / First Fans(50) / Small Crowd(250) / Growing Crowd(1,000) / Solid Crowd(5,000) / Big Crowd(25,000) / Packed House(100,000) / Superstar Crowd(500,000)`.
- [ ] `FanBoxCrowdTemplates.NOOBS_PER_STEP_BY_TIER` extended to 8 entries: `{0, 1, 2, 3, 4, 5, 7, 9}` — Tier8 (9 figures/step, columnSpacing ≈1.56 studs) packs tighter than the old max of 7, giving the new top tier a visibly denser "sold out" look rather than just repeating the old ceiling. Verified live: all 8 templates build correctly (8 real `UnionAsync` calls at server start, still cheap/one-time), all correctly grounded, all threshold boundaries (`GetTierIndexForFanCount` tested at every boundary ±1) resolve to the right tier.

**Cosmetic: currency numbers now show up to 10 full digits before abbreviating, per direct instruction:**
- [ ] `Utils.FormatNumber` rewritten — values under 10,000,000,000 (10 digits) now show in FULL with thousands-separator commas (e.g. `1,234,567`), no letter abbreviation at all in that range (previously abbreviated starting at just 1,000 → "1.0K"). Only at 10,000,000,000+ does it switch to letter suffixes (B/T/Qa/Qi/Sx/Sp/Oc/No/De), continuing to scale for arbitrarily large values. Verified live via `execute_luau` across the boundary (`9,999,999,999` → full digits, `10,000,000,000` → `"10.0B"`) and several magnitudes beyond. `MainMenuController`'s Gold/Fans labels (which never used `FormatNumber` at all, showing raw un-formatted integers) now use it too, for consistency.

**Icon fixes — both root-caused as missing emoji glyphs in Roblox's default fonts, not just "wrong icon," confirmed via an actual in-Studio render test (`screen_capture` of test labels) before touching anything:**
- [ ] **Gold icon "square"**: `🪙` (coin emoji, Unicode 13.0/2020 — too recent for Roblox's font coverage) rendered as an empty tofu box. Rendered a side-by-side comparison of 6 candidate symbols live in a Play session and screenshotted it — `💰` (money bag, an older/universally-supported emoji) renders correctly; swapped in everywhere a Gold amount is shown: `CurrencyDisplay`, `MainMenuController`, `ShopUIController`, `SkillShopController`, `ProcessReceiptManager`, `CheckpointValidator`, and 3 static default-text values in `default.project.json`. `🌟` (Fans icon) was already a well-supported older emoji, confirmed via the same test — left unchanged.
- [ ] **Close-window "red circle with rectangle square"**: same root cause, different glyph — `✕` (U+2715) doesn't render in the `GothamBold` font specifically (a curated branded font file, not guaranteed to include extended Unicode/Dingbat glyphs), showing as a blank box inside the (correctly-rendering) red circular button background — exactly matching the report. Replaced with plain ASCII `"X"` (guaranteed present in every font) in all 4 `CloseButton` instances in `default.project.json` (Skill Loadout, Skill Shop, Robux Shop, Fan Deposit-adjacent panel — whichever 4 modals have one). Verified live: opened the Skill Shop panel in a running session and screenshotted a clean white "X" in the red circle.

**Fan box redesign — full avatar scale, 6 steps, connected "stadium wall" spacing. All 3 asks verified live (execute_luau measurements + screen_capture), including one real bug caught and fixed mid-round via live measurement (overlapping pods):**
- [ ] **Full avatar scale**: `NOOB_SCALE` 0.5 → 1.0 — figures now use the literal real Roblox R6 part sizes (Head 2x1x1, Torso 2x2x1, Arm/Leg 1x2x1), not a scaled-down version, directly answering "size of figurine should be size of actual noob avatars."
- [ ] **6 steps instead of 3**: `STEP_HEIGHTS` grew from `{2, 4.5, 7}` to `{3, 6, 9, 12, 15, 18}`, `STEP_DEPTH` from 4 to 6 studs (more comfortable footing at the now-doubled figure size). `NOOBS_PER_STEP_BY_TIER` keeps its existing 8-value progression, just reapplied across 6 rows instead of 3 (roughly doubling total crowd size per tier — a natural "adjust density accordingly" given the stand is now much bigger).
- [ ] **Connected "stadium wall" + even straight/curve spacing**: `FanBoxGenerator.computePodsPerPiece` no longer derives pod count from a fixed 3:2 straight:curve ratio scaled by `Players.MaxPlayers` — it now computes the WHOLE loop's real arc length (a 90° curve at `TrackGeometry.CurveRadius` is actually longer than a straight piece here, never accounted for before), picks a pod count (whichever is larger: however many `NOMINAL_POD_WIDTH`-wide pods naturally fit the loop, or `Players.MaxPlayers`), and derives the ACTUAL pod width as `loopArcLength / podCount` — the exact width that tiles the whole loop with ~zero gap. Both straight and curve piece pod-counts are then derived from THAT SAME width, which is what makes the spacing genuinely even between them (not an assumed ratio).
- [ ] **A real bug caught mid-round by live measurement, not just claimed working**: the first version of the width/count logic kept pod count "at least `Players.MaxPlayers`" by scaling counts up while leaving the BUILT pod width fixed at the nominal size — `execute_luau` measurements showed adjacent pod centers 30 studs apart while each pod was built 35 studs wide (5-stud overlap, at `Players.MaxPlayers = 60`). Fixed by deriving width and count TOGETHER (see above) so the built geometry always matches the actual spacing — `FanBoxCrowdTemplates.BuildAll`/`buildStepsAndCrowdParts`/`buildFallbackBlock` all now take `podWidth` as a parameter instead of reading `FanBoxTiers.PodBaseSize.Z` directly, and `FanBoxGenerator` remembers the actual width it generated at (`currentPodWidth` module upvalue) so `SwapPodTier`'s fallback-block path stays consistent too. Re-measured after the fix: overlap dropped from -5 studs to -0.85 studs (integer per-piece rounding noise, effectively touching) at the same `MaxPlayers = 60`.
- [ ] `FanBoxTiers.PodBaseSize` widened `(24,18,14)` → `(40,23,35)` to fit the bigger geometry (X: 6 steps × 6-stud depth = 36 + margin; Y: 18-tall top step + 5-tall figure = 23; Z: nominal width target for the connected-wall spacing calc).

## 3. Explicitly deferred / not addressed this round
- [ ] Ground arrow guides (flagged "maybe" several sessions ago) — still not built.
- [ ] Daily Quests panel, expandable Leaderboard/stats buttons beyond what's in the Main Menu — still not built.
- [ ] `EconomyRates.SpeedUpgradeCosts`/`CarryCapacityUpgradeCosts` are still unread by anything — a separate, still-unbuilt upgrade track from the skill Level/Unlock system.
- [ ] `GrandPrixManager`'s own roster/Countdown join flow is still an unimplemented stub — `ArcadeManager` remains the only real way onto the track. (Its state machine now drives one real thing — Standings visibility — but scoring/roster are still TODOs inside it.)
- [ ] Toolbox-sourced assets/sounds/icons — still placeholder (no Toolbox access). Monetization IDs are no longer placeholder (see prior round) except the pose-unlock pass, dropped on purpose. Track theming is NO LONGER on this deferred list — see section 2, it's real now, just simpler than the original 7-biome concept (which is deleted, not deferred).
- [ ] Theme-driven movement (`TrackThemes.WalkSpeedModifier`) — data exists per theme, but nothing reads it live; would need a terrain-zone spatial-query system (detect which theme's segment a player is on, apply the multiplier through `MovementModifier`) that doesn't exist yet.
- [ ] Real skill icons (`SkillTrees.IconAssetId`) and the 3 LeftMenuBar `Icon` placeholders — still no Toolbox access to source any; both fallback paths are wired and tested-by-construction (fall back to text), just waiting on real `rbxassetid://` values.

## 4. Next Up (For Next Session)
- [ ] **First real Play test — this codebase still has never had one.** This round's checklist is now the priority re-test, since the checkpoint bug specifically has now had TWO rounds of blind (no live Studio access) fixes: pick up a Fan Payload and walk/run through several checkpoints in a row while carrying it (the originally reported case), AND separately, run through checkpoints WITHOUT carrying anything, at normal speed and while boosted (e.g. `DashSelf`), confirming `CheckpointOrdinal` increments every single time in both cases — if it's still flaky even once, the last-position crossing logic itself needs review, not another root-cause hunt. Also: open the Skill1/2/3 slot picker in the Hub and confirm the new scrollable modal lists all 17 skills with correct grey/blue states (not-owned vs. equipped-elsewhere vs. available); confirm the location-toggle and 3 skill-cast buttons read cleanly at the smaller text size, including a multi-word equipped skill name like "Track-Wide Scramble" on a Skill button. Everything queued from prior rounds (stat capsules, Grand Prix standings visibility, Skill Shop listing all 17, Robux Shop live prompts) still needs its first real look too.
- [ ] The dropped-pickup marker spawned by `SpawnDroppedPickup` (a few rounds ago) is still visually identical to a normal marker — unrelated to this round, still an open note.
- [ ] `SkillPickupSpawner`'s 24 markers are placed via 3 fixed lateral offsets per checkpoint — not yet checked against the actual (scaled-up) road width for overlap with barriers or the checkpoint trigger itself; may need tuning once visually verified.
- [ ] `TrackGenerator.Regenerate()` still doesn't regenerate `TrackPickupSpawner`/`SkillPickupSpawner` alongside it — not an issue today since nothing currently triggers `Regenerate()` in practice, flagged for whenever `GrandPrixManager`'s roster flow gets built.
- [ ] `StatsRow`/`LocationToggle` sit at the same top-of-screen Y as before (`0.03`/`0.115`) — only `LeftMenuBar` was confirmed to overlap Roblox's default topbar and got moved. If the stats capsules or toggle button turn out to overlap it too (e.g. on narrower viewports), they need the same treatment.
- [ ] This round's additions to the checklist: confirm `CenterAction.ActionButton` and `LocationToggleButton` finally read as non-bold now that the actual cause (a `UIStroke` outlining the text) is removed — 4th attempt at this one complaint, should be the real fix this time; pick up a Fan Payload and confirm `PickupFill` visibly grows under the "PICKING UP..." text over the 3-second channel, then confirm it disappears the instant the channel resolves (granted or cancelled); deposit a Fan Payload, complete a lap, and (if testable) trigger a Robux purchase grant, confirming each one pops a distinct bouncy "+N 💰/🌟" toast that stacks correctly with any other active notifications.
- [ ] **Run a full lap end to end and count segments out loud** — with checkpoints now at segment EXITS, `CheckpointOrdinal` should read 1 right after finishing segment 1 (not at spawn), climb to 8 right after finishing segment 8, and "LAP COMPLETE" (Gold+Fans grant, `TotalLapsCompleted` +1) should fire in that SAME moment reaching 8 — no extra segment needed after. Also confirm a violation/respawn that happens before ever reaching Checkpoint 1 (still early in segment 1) now correctly sends the player back to the actual start line (Checkpoint 8's position), not partway through segment 1 at Checkpoint 1's new position. This is the 2nd attempt at this specific bug (1st attempt — wrap-to-1 bookkeeping — was reported as not working); this attempt fixes it by relocating the checkpoints instead of adding more special-case logic, per explicit instruction.
- [ ] **First look at the themed oval** — run/regenerate the track a few times (each `TrackGenerator.GenerateOval`/`Regenerate()` call re-rolls) and visually confirm: the 4 segment-pairs (2 straights, 2 curves, 2 straights, 2 curves) show 2-4 distinct materials/colors around the loop, not all one color; the road material actually LOOKS different per theme (Mud/Ice/CrackedLava/WoodPlanks/Metal/Sand/Neon/Concrete all render distinctly in Studio); barriers tint to match; and nothing looks broken at the seams between two differently-themed segments (they should still connect exactly the same as before — only material/color changed, not geometry).
- [x] **Fan Box crowd — CONFIRMED FIXED this round via live Studio testing** (grounding, collidability, all 8 tiers, live tier-graduation via the real `TotalFans`-attribute-change path, screenshotted). Still worth a human eyeball pass for TASTE, not correctness: does the new 8-tier density curve (1/2/3/4/5/7/9 figures per step) actually read as a satisfying progression when watched over real gameplay (not just synthetic `SetAttribute` jumps), and do the new thresholds (50/250/1,000/5,000/25,000/100,000/500,000) feel reasonably paced against how fast a player actually earns fans in practice.
- [x] **Gold icon + Close-button icon — CONFIRMED FIXED this round**, visually verified via `screen_capture` in a live session (💰 renders correctly top-left of the stats row; a clean white "X" shows in the Skill Shop panel's red close button).
- [x] **Number formatting — CONFIRMED via direct `execute_luau` test** of the boundary and several magnitudes; a live HUD screenshot also shows "300,000" (full digits, not "300.0K") for the Fans stat.
- [ ] **Track piece templates — still needs a first look**: confirm `ReplicatedStorage.Assets.TrackPieceTemplates` exists with `Straight`/`Curve` children; run/regenerate the track a few times and confirm every piece still connects seamlessly at its seams (no gaps/overlaps) and themes still visibly vary per segment pair; confirm `TrackGenerator.Regenerate()` (after a Grand Prix) still works. (Not covered this round — investigation time went entirely to the fan-box float bug and the 4 UI/economy asks.)
- [ ] **MainHUD load-gate fix — still needs confirmation the "Infinite yield possible on ... MainHUD" warning is gone** from the console on a fresh server start / player join, and that skill buttons (Skill1/2/3) are clickable promptly after spawning, not delayed. (Also not covered this round.)
- [x] **Fan box redesign — CONFIRMED via live measurement + screenshots this round**: full avatar scale, 6 visible ascending steps, connected/near-touching stand spacing, even straight:curve spacing, no overlap (down to -0.85 studs of rounding noise) at `MaxPlayers = 60`. Worth a human eyeball pass on TASTE once more: does the crowd density progression across 8 tiers still read well at the new, much larger scale (more figures now spread across 6 rows instead of 3), and does the near-touching pod spacing look right at whatever `Players.MaxPlayers` the production server actually runs (tested at 60; a very different value would derive a different `actualPodWidth`, worth a spot-check if that setting changes again).
- [ ] **Everything NOT touched by this round's Studio-MCP testing is still exactly as unverified as before** — checkpoints/laps, the themed oval, Grand Prix flow, monetization prompts, etc. Now that live Studio inspection tools are actually available (see Context Notes), these should be the priority to verify FOR REAL next, instead of another round of blind code changes.

## 5. Context Notes
- **A yielding call (like `BasePart:UnionAsync`) that operates on newly-created Parts needs those Parts `Anchored = true` BEFORE the call, not after.** An unanchored Part sitting in `workspace` during any yield is subject to gravity — `UnionAsync` genuinely yields (it's a real async CSG operation, not just async-flavored syntax), so unanchored source parts would visibly fall mid-union and corrupt the merged geometry. Caught by reasoning through the timing, not a runtime error. Same category of gotcha as the `Frame.Active`-defaults-false and `UIStroke`-outlines-text findings from earlier rounds: a non-obvious default/timing behavior that only bites once you reason through exactly what happens between two lines of code, not something `rojo build` or a type checker can catch.
- **A `UIStroke` instance parented directly to a `TextLabel`/`TextButton` outlines the TEXT GLYPHS, not (only) the button's border/corner shape.** This cost 3 full rounds of misdiagnosis on one complaint ("text is too thick/bold") — every round changed `Font` (Bold -> Medium -> plain Gotham) with zero visible effect, because the actual cause was a `Thickness = 2` `UIStroke` child on those 2 buttons the whole time. Any GuiObject in `default.project.json` that has BOTH visible `Text` AND a child `UIStroke` should be treated as suspect for "text looks thick" reports — check for this BEFORE touching `Font`/`TextSize`. `UIStroke` is fine (and intentional) on things like `NotificationList.EntryTemplate`, where an outline is the actual desired look; it's specifically a problem when a stroke was added for the BUTTON SHAPE (a colored border around a rounded rect) and the fact that it also outlines the text inside was an unintended side effect.
- **Target-skill targeting is "nearest enemy in range," full stop** — `TargetedSkillManager.findNearestTarget` does a `workspace:GetPartBoundsInRadius` around the caster (radius = the skill's current level `RangeStuds`), filters to other players' `HumanoidRootPart`s, and picks the closest by straight-line distance. No facing/cone check, no line-of-sight check, no race-position weighting (doesn't prefer whoever's ahead/behind/leading) — purely closest Euclidean distance among everyone in range. Global skills (`SlowGlobal`/`ScrambleGlobal`) don't target at all — they hit every currently-InRace player unconditionally. Self skills obviously only ever affect the caster. If directional/cone targeting, leader-targeting, or line-of-sight ever come up as a request, this is the one function (`TargetedSkillManager.luau`) to change — the 3 skill managers all funnel through their own single `resolveAndApply`/`activate`, so there's no duplicated targeting logic to hunt down elsewhere.
- **Any per-poll "is X currently touching/inside Y" check is only as reliable as (object size) vs. (distance moved per poll interval)** — do this division explicitly before trusting a spatial poll. `CheckpointValidator`'s bug survived one full fix attempt because the first fix addressed a plausible-but-wrong mechanism (physics query ambiguity) instead of this actual arithmetic (6-stud trigger / 16 studs-per-second walk speed / 0.5s poll = the trigger is narrower than one poll's worth of travel). When a spatial-poll bug is reported, compute this ratio FIRST, before reaching for a different detection technique.
- **Prefer pure CFrame-space geometry over `workspace:GetPartsInPart`/similar broad-phase queries for "is this specific known point inside this specific known volume"-type checks** — still true and still in place (`CheckpointValidator`'s `isInsideTrigger`), just not sufficient on its own; needed the crossing-detection layer on top for a thin/fast-crossed trigger. No dependency on CanQuery/CanCollide/MaxParts/what-else-is-nearby either way.
- **A Roblox `Frame`'s `Active` property defaults to `false`** (unlike `TextButton`/`ImageButton`, which default `true`) — a plain Frame sitting on top of other GUI (like the modal "Card" panels, on top of a full-screen backdrop button) will silently let clicks fall through to whatever's behind it unless `Active` is explicitly set `true`. Bit the modal-panel close-on-outside-click design before it shipped — caught by reasoning through the render/input model, not by a runtime error (`rojo build` has no concept of input behavior). Any future click-catching Frame needs this checked explicitly.
- **Roblox's default topbar (player thumbnail/leaderboard toggle, chat, settings) occupies real screen space that a `ScreenGui` with `IgnoreGuiInset = true` will happily draw underneath/through** — any HUD element placed near `Position Y ≈ 0.03` at the left or right edges should be checked against it; this bit `LeftMenuBar` this round.
- **Cooldown/progress visuals**: prefer a fill (`Size` tweening on one axis) over anything that rotates — a rotating element, however thin, reads as "a shape spinning" to a player, not as "time passing." Took 3 rounds to land on this; keep it in mind before designing the next progress-style indicator (e.g. a future Grand Prix countdown).
- **Direction/geometry bugs propagate silently across every generator that shares the same underlying math** (`TrackPieceBuilder`) — when touching shared geometry math, grep for every consumer (`FanBoxGenerator`, `HubGenerator`, `TrackPickupSpawner`, `SkillPickupSpawner`, `TrackBoundaryMonitor`) and re-derive their assumptions, don't just fix the one place a bug was reported.
- **Y-positioning of anything meant to sit "on" the road**: use `TrackGeometry.RoadThickness / 2 + visualHeight / 2 + margin` (the pattern `TrackPickupSpawner.surfaceOffsetY` formalizes) — a flat offset like `+0.5` will embed inside the road slab and be invisible.
- **Checkpoint model is locked and specific**: 8 checkpoints = 8 oval segments, strict sequential order, `CheckpointOrdinal` = whole numbers 1-8 with no other scope. If this changes again, update `TrackBlueprints`, `CheckpointValidator`, `ArcadeManager`, and this file together.
- **When a "build then merge" 2-phase build is requested, add an actual toggle, don't just reorder code internally.** `FanBoxGenerator.BUILD_AS_SINGLE_MESH` is a plain module-level `true`/`false` a future round (or the user, editing locally) can flip to skip the union entirely and leave raw geometry visible for inspection — this is what makes "verify the geometry before merging" a real, repeatable capability instead of just development discipline that happened once during this round's write-up.
- **Bounded-concurrency batching pattern for N independent yielding calls** (established this round for `FanBoxGenerator.GenerateRing`'s 20 `UnionAsync` calls): `task.spawn` a small batch (`GENERATION_BATCH_SIZE`), decrement a shared pending-counter from inside each spawned closure, `while pendingCount > 0 do task.wait() end` before starting the next batch. Faster than fully sequential, safer than firing all N at once; the calling function still blocks until everything is done, so callers needing a "definitely finished" guarantee (like bootstrap ordering) don't need to change at all. Reusable anywhere else a batch of independent expensive/yielding operations shows up.
- **`BasePart:UnionAsync` does not support legacy `SpecialMesh` instances as source primitives — confirmed via live playtest, not a guess.** Every source part passed to `UnionAsync` must be a plain-shaped `BasePart` (Block/Ball/Cylinder/Wedge/etc.) or a real `MeshPart`; a `SpecialMesh` child (the old `MeshType.Head`/`Torso`/`FileMesh` system) makes the whole union call fail with `CSG: One of the primitives was of unknown type (error -4)` — not a partial/degraded result, the ENTIRE union call fails and falls back to whatever error-handling path exists. If a rounded/custom look is ever needed on a part that will be unioned, either strip the `SpecialMesh` immediately before the union call (as `FanBoxGenerator.stripSpecialMeshes` now does) or use a real `MeshPart` instead, which CSG does support.
- **When a batch of `pcall`-wrapped operations can plausibly ALL fail the same way (e.g. every pod's `UnionAsync`), check the actual failure reason in the warn/log message before assuming the fallback path itself is fine.** The `x20` in the reported warning (`FanBoxGenerator: UnionAsync failed (...) — using a plain block for this pod instead. (x20)`) was the tell that this was systemic (every single pod, same root cause), not a random one-off — worth explicitly noting because a systemic 100% failure rate is exactly the situation the fallback-block path was designed to mask silently, which is otherwise easy to ship without noticing the "real" feature never actually worked.
- **A pure-translation `CFrame.new(x,y,z)` never changes facing — anything built that way inherits whatever direction its parent/origin CFrame happened to be facing, which is very rarely the direction you actually want a standalone visual element to face.** Both the step-orientation bug and the noob-facing bug this session were instances of the same underlying mistake: building geometry relative to `originCFrame` (whose own -Z axis is "along the track," an arbitrary inherited direction, not a deliberately chosen one) without ever asking "what direction should THIS specific thing actually face/extend." When placing a visual element that has an inherent "this side should point at X" requirement (a stand facing the action, a figure facing a stand, a sign facing a path), explicitly construct its CFrame via `CFrame.lookAt(position, position + desiredDirection, upVector)` (or explicit `CFrame.Angles`) — never assume the ambient/parent CFrame's default orientation happens to be correct.
- **When two independent things (a generated building/platform and a procedurally-placed hazard/prop) are positioned from the same shared coordinate math but sized with hand-picked constants, always compute the actual worst-case clearance between them before shipping, not just eyeball it.** `HubGenerator`'s `HUB_RADIUS = 140` was picked independently of `TrackGeometry`'s dimensions and left only ~4 studs of real clearance against the track's inner edge (`CurveRadius - SegmentWidth/2` = 144) — close enough that a randomly-placed hazard reportedly ended up visibly inside the Hub. Deriving a size/position constant FROM the geometry it has to stay clear of (with an explicit safety-margin constant, like `HUB_RADIUS_SAFETY_MARGIN`), instead of a flat hand-picked number, is the fix — and it stays correct automatically if the underlying geometry (`TrackGeometry`) is ever tuned again, which a flat number would not.
- **`Players.CharacterAutoLoads = false` + explicit `player:LoadCharacter()` is the real, correct way to gate character spawn on server-side readiness** ("pause game until all are loaded correctly") — not a client-side loading-screen illusion. Set the flag as the very first statement in the bootstrap script (before any `require`, since requiring a module can't itself yield player joins but minimizing the window is still good practice), run every system's `Init()` as normal, then explicitly release every already-connected player plus hook `PlayerAdded` for everyone afterward. Before adding a gate like this, grep every existing `Players.PlayerAdded` handler in the codebase for `player.Character`/`CharacterAdded` dependencies — none in this project had any, which is what made this a safe, no-side-effect change; a codebase where some handler DID assume an immediate character would need that handler moved to a `CharacterAdded` connection instead.
- **A player's FIRST StarterGui-to-PlayerGui clone appears to require at least one character spawn, regardless of `ResetOnSpawn`.** `MainHUD.ResetOnSpawn` was already `false` (governs whether GUI persists across RESPAWNS, not whether the very first copy needs a spawn at all) — yet gating character spawn behind slow server-start work still produced a `PlayerGui:WaitForChild("MainHUD")` hang on the client. Any future gate on `Players.CharacterAutoLoads` needs to stay narrow (only the genuinely spawn-unsafe systems) specifically because of this coupling — it's not just about physical safety, client GUI availability rides on the same event.
- **Template-once-and-clone is the right pattern whenever the SAME shape gets built repeatedly with only position/theme/scale varying** — applied twice this round (`FanBoxCrowdTemplates`, `TrackPieceTemplates`). The mechanics differ by what the "shape" actually is: a single `BasePart`/`UnionOperation` just needs `.CFrame`/`.Size` set directly on the clone (see `FanBoxCrowdTemplates.TemplateOffsetFromOrigin` for why a plain CFrame assignment is wrong if the source geometry wasn't built at a clean identity origin); a multi-part `Model` needs an explicit pivot reference (`TrackPieceTemplates`'s `EntryPivot` part, set as `PrimaryPart`) so `Model:PivotTo(cframe)` repositions the whole rigid group correctly — `PivotTo` without one falls back to a bounding-box-derived default pivot that won't line up with whatever "entry point" the caller's chaining math expects. Only worth doing where either (a) the build step is genuinely expensive/risky (CSG, in the fan-box case), or (b) it's been explicitly requested for its own sake (the track-piece case — cheap either way, but still a real simplification for `Regenerate()` and a real "single source of truth per shape").
- **`AlignPosition`/`AlignOrientation` are force-based by default (spring toward a target, governed by `MaxForce`/`Responsiveness`), not hard constraints — they CAN be out-paced by repeated or fast collision impulses on an unanchored part.** Set `RigidityEnabled = true` for anything that must never visibly drift no matter how hard/often it's hit (e.g. `TrackGenerator`'s spinning `HazardBar`) — this makes the hold immediate/absolute instead of springy. Similarly, any property set once at creation on an unanchored, collidable part (like `AssemblyAngularVelocity` for a "spins forever" object) should be treated as reasserted-not-guaranteed unless something keeps re-asserting it — a single hit can permanently change it with nothing to notice or correct that, silently, until a much later report ("it's misplaced") with no visible cause in the placement code itself.
- **Resizing a `UnionOperation` (or any `BasePart`) via `.Size` scales the WHOLE mesh around that part's own CFrame/centroid, not around any semantically meaningful reference point like "the ground" or "the feet."** If a shape needs to stay grounded/anchored at a specific reference plane across different sizes, size-based scaling is the wrong tool UNLESS the shape's natural bounding box already matches the target size at every tier (coincidental, fragile, and silently breaks the moment the source geometry changes — exactly what happened here: the stepped-riser redesign never matched `FanBoxTiers.PodBaseSize`, but nothing caught that until it was visibly "elevated" in Studio). Prefer varying an independent property that doesn't require rescaling at all (density/count, as landed on for fan box tiers) whenever the visual "levels" are naturally expressible that way — it sidesteps this whole class of bug.
- **Never compose a CFrame off of `someBasePart.CFrame` for a part whose CFrame you didn't explicitly set yourself (e.g. a `UnionAsync`/CSG result) — that value is whatever Roblox's engine happened to auto-assign, not a documented/guaranteed offset you can safely do CFrame algebra with.** This cost 2 full rounds on the fan-box "elevated" bug: the fix that actually worked wasn't correcting the assumed offset, it was DELETING the assumption — wrap the uncertain-CFrame part in a `Model` alongside an explicit reference Part (`GroundPivot`/`EntryPivot`, placed at a position YOU chose and know) set as `PrimaryPart`, and use `Model:PivotTo(targetCFrame)` to reposition, since `PivotTo` only needs the relative transform from the reference part and never has to know or trust the uncertain part's own CFrame. Apply this pattern proactively (not as a last resort after 2 failed attempts) any time repositioning code touches a CSG/union result, an imported mesh, or anything else whose CFrame wasn't set by code you wrote.
- **Roblox Studio MCP tools (execute_luau, inspect_instance, screen_capture, start_stop_play, script_grep/read/search, search_game_tree) became available this round — a real capability shift, not just another tool.** Every prior round's bug fixes for this project were written blind (code reasoning only, no way to see the actual running game) and handed to the user to playtest and report back — which is why the fan-box float bug survived 3 full rounds of plausible-but-wrong guesses. With these tools, ALWAYS verify a fix empirically before reporting it done: start Play, inspect real instance state (`workspace`/`ReplicatedStorage` traversal), trigger the REAL code path (not a reimplementation), and `screen_capture` the visual result. Don't fall back to blind code review as the default now that live verification is possible.
- **`execute_luau`'s `require()` does not share Luau's module cache with the actual running server/client scripts.** Calling `require(SomeModuleScript)` from an `execute_luau` session creates a fresh, independently-initialized copy of that module — its own upvalues, its own `nil` state for anything only set up via an `Init()`/`BuildAll()`-style function the live game already called once at startup. This produced several confusing false-negative results mid-investigation this round (a module that clearly worked, per direct instance inspection, appeared broken when re-required and called directly). To verify real game state via `execute_luau`: read live instance properties directly (no `require`), or trigger the real path indirectly (e.g. `player:SetAttribute(...)` + `task.wait()`, letting an already-connected live listener handle it) — never trust a freshly-`require`'d copy's behavior to represent the live game's actual state.
- **When a size/count/spacing requirement has TWO independent-looking drivers (e.g. "fit a target width" AND "guarantee a minimum count"), derive them TOGETHER, not one as a fallback bolted onto the other.** Scaling pod COUNT up to satisfy a capacity minimum while leaving the pod WIDTH fixed produced physically overlapping geometry — obvious in hindsight, easy to miss in code review, caught only by live measurement. The fix was picking the count first (`max(natural-fit count, required count)`) and then deriving width FROM that chosen count and the fixed total space (`totalSpace / count`) — a single formula with one degree of freedom, not two independently-tuned numbers that can silently drift out of consistency with each other.
- **An ongoing segment-by-segment difficulty pass has its own working doc: `SEGMENT_DIFFICULTY_PASS.md`.** It holds the agreed per-segment process (reuse existing hazards; force the segment onto the map; move the player and WAIT for the user's command; test via the official join route; wait for the user's confirmation before the next segment), the 16 theme x piece-type variant catalog, the forced-segment harness recipe, and the log of a first attempt at Classic that was reverted in full. Read it before touching `ThemeHazardBuilder` or `TrackGenerator` for difficulty work.
- Nothing in this project is committed to git yet. Commit only when the user explicitly asks.
- Use the `progress-tracker` subagent (`.claude/agents/progress-tracker.md`) to resume/update this file — confirm it's available via the Agent tool at the start of a fresh session before relying on it.

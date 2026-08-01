# Project State: Brawler-Racer
**Current Date/Time:** 2026-08-01 (session: state machines, scale-up, hub, monetization DataStore note)

## 0. From last session — status
The `init.server.luau`/`init.client.luau` → `Main.server.luau`/`Main.client.luau`
root-cause fix (see git history / prior version of this file for the full
story) is confirmed working: the user got past it and hit a NEW error
(`StudioAccessToApisNotAllowed`), which only happens once a Script is
actually executing DataStore calls — proof the bootstrap runs now. That
DataStore error is a Studio setting, not a bug: **Game Settings → Security
→ enable "Studio Access to API Services"**.

## 1. Completed Modules (Synced to Studio)
- [x] Rojo/Wally/ProfileStore toolchain; bootstrap execution confirmed working (see above).
- [ ] Nothing else has been confirmed Play-tested past the DataStore error yet — everything below is new/changed this session and unverified.

## 2. In Progress / Pending QA (this session)

**Map scale** — ~4.5x linear on every track/fanbox dimension (chosen so **area** scales ~20x, i.e. 4.5² ≈ 20, per "make it ~20x bigger" — literal 20x on every linear dimension would make a single straight piece 800 studs long; flag if that literal reading was actually intended):
- [ ] `TrackGeometry.luau` — SegmentWidth 16→72, StraightLength/CurveRadius 40→180, etc.
- [ ] `FanBoxTiers.luau` — PodBaseSize 6→(24,18,14); `FanBoxGenerator` RING_GAP 6→30.
- [ ] Still only the core Oval (1 of the 8 "partial tracks... connected into one field/stadium" the user described) — that architecture is understood but not built; see Next Up.

**Real state machine — the big functional addition this session:**
- [ ] `PlayerStateService` — stub → **real**: InLobby/InRace/AtFanBox, replicated via a `PlayerState` attribute, defaults every player to InLobby on join.
- [ ] `TargetedSkillManager`/`GlobalSkillStateMachine`/`SelfSkillManager` — all now gated on caster `PlayerState == InRace` ("skills can only be casted while on track", per explicit instruction). `GlobalSkillStateMachine` additionally only *applies* its effect to players who are InRace (a Hub bystander shouldn't get slowed by a track-wide skill).
- [ ] `HubGenerator.luau` — **new module**. Computes the oval's centroid (averages the 8 segment entry points via `TrackPieceBuilder`'s chain math) and builds a Hub floor + `SpawnLocation` there — players now spawn inside the oval, as specified.
- [ ] `TeleportPoseService` — stub → **real**: `TeleportToFanBox`/`ReturnToHub` do actual CFrame teleports (to the assigned pod / Hub center) and set `PlayerState` accordingly.
- [ ] `ArcadeManager` — stub → **real**, and now the ONLY working way onto the track: `EnterTrack`/`LeaveTrack`, teleports to/from the track start and sets `PlayerState`. New `Hub.EnterTrack` RemoteEvent. **No HUD button fires it** — the wireframe never defined an "enter track" button, so this is only reachable by firing the remote directly right now (or wiring a button later).
- [ ] `GrandPrixManager` — wired to the state machine (sets InRace on Countdown-start / InLobby on elimination-or-end for whoever's in the roster) and now calls `TrackGenerator.Regenerate()` after every `Ended` transition.
- [ ] `TrackGenerator.Regenerate()` — **new**. Destroys and rebuilds the Track folder with freshly randomized hazard-segment placement (2 random non-checkpoint segments each time) — the concrete implementation of "track updates every Grand Prix." Full thematic variation (the other 7 track types) still needs to be built; this is the honest, currently-achievable version of "changes every time."

**HUD layout corrections** (per explicit feedback):
- [ ] Removed the custom `JumpButton` and `ThumbstickArea` placeholder entirely — Roblox's standard jump button and movement thumbstick are used as-is now; we only place content around them.
- [ ] Merged the separate Pose button into `ActionButton` (`ActionButtonController` now reads the `PlayerState` attribute: shows/fires "POSE" while AtFanBox, "DEPOSIT FANS" otherwise) — the "pose button replaces deposit fans" requirement.
- [ ] `ActionButton` repositioned to the bottom row (`Position.Y = 0.87`) to sit level with the default Jump button, instead of screen-center.
- [ ] `Skill1/2/3` repositioned into a compact vertical stack near the default Jump button's usual corner (`Position ≈ (0.85, 0.40)`) rather than the old 2x2 grid that included Jump.
- [ ] **Exact pixel alignment against Roblox's actual default touch-control positions is unverified** — I can't see Studio, and those default positions vary slightly by device/aspect ratio. Nudge `Skill1/2/3Button` positions in `default.project.json` if they overlap the real default Jump button once visible.

## 3. Next Up (For Next Session)
- [ ] Confirm the DataStore Studio setting fix, then Play-test everything above for the first time.
- [ ] Verify the Skill1/2/3 cluster doesn't visually overlap Roblox's real default Jump button; nudge positions if so.
- [ ] Build a HUD trigger for `ArcadeManager.EnterTrack` (no button exists yet — currently only callable by firing the remote directly).
- [ ] The "8 partial tracks connected into one field/stadium" architecture: still just the 1 Oval. Building the other 7 as literally-connected segments (not teleport-linked separate zones) is a significant undertaking — tackle one at a time, starting with the lowest-difficulty theme (EasyMaze) as planned previously.
- [ ] GrandPrixManager's roster/Countdown join flow is still a TODO stub — `ArcadeManager` is currently the only real way onto the track, which is fine for testing but doesn't match the "Grand Prix" scheduled-event design yet.
- [ ] Give the gloss gradient a real transparency falloff (still flat — see prior session's NumberSequence note).
- [ ] Replicate `CheckpointOrdinal` and `CarryItemType` (same one-shot-attribute pattern as Gold/TotalFans) so the lap counter and a context-sensitive Deposit/Use-Item button actually reflect live state.
- [ ] Fill in real Monetization Product/Pass IDs once created on the Creator Dashboard.

## 4. Context Notes
- **Scale reasoning**: "20x bigger" was interpreted as 20x *area* (≈4.5x linear), not literal 20x on every dimension — flagged explicitly above in case that's wrong; easy to redo if so.
- **PlayerState is now load-bearing**: multiple systems depend on it being accurate (skill gating, HUD button label, Global-skill effect targeting). If a player ends up in a stuck/wrong state (e.g., a bug leaves someone marked InRace after leaving), skills will silently fail to cast with no error — this class of bug is worth checking first if "nothing happens" gets reported again.
- **"Enter track" has no UI trigger** — this is a known, deliberate gap (see section 2), not an oversight to re-discover.
- **Fan box pods remain plain Parts** representing "100+ NPCs" abstractly via size, not literal crowd meshes — no Toolbox access to source real crowd assets, unchanged from prior sessions.
- All prior sessions' context notes (Rojo service-class gotcha, ProfileStore switch, 8-checkpoint whole-course model, no Toolbox access, etc.) still apply — see git history of this file for full detail; kept out of this version to control length.
- Nothing in this project is committed to git yet. Commit only when the user explicitly asks.
- Use the `progress-tracker` subagent (`.claude/agents/progress-tracker.md`) to resume/update this file.

# Studio Preflight — run before ANY Roblox mutation

The guard blocks every mutating Studio tool until this runs. Use it verbatim:
the marker string is what the hook looks for.

## 1. Enumerate
`list_roblox_studios` — **if more than one instance is connected, HALT.** Studio
does not expose its open place on the command line, so a second instance cannot be
told apart. Ask the user to close all but the target.

## 2. Bind explicitly
`set_active_studio` with the id from step 1. Never rely on the heuristic.

## 3. Prove identity
`execute_luau`, `datamodel_type: "Edit"`, exactly:

```lua
--!strict
-- ROBLOX_PREFLIGHT_V1
return ("ROBLOX_IDENTITY_V1|%d|%d|%s"):format(game.PlaceId, game.GameId, game.Name)
```

## 4. Confirm
Compare the returned PlaceId to `engineTargets.placeId` in
`.claude/project-identity.json`. Mismatch means **stop all work and tell the user.**

## Re-run after
New session · `start_stop_play` · Studio restart · MCP reconnect · TTL expiry.

---

## Race Brawler specifics

| | |
|---|---|
| PlaceId | `95742062831533` — the id in the `roblox.com/games/<id>` URL |
| GameId (universe) | `10608291731` |
| Rojo port | **`34872`** — see below |
| Project root | `D:\Claude\Roblox\Race Brawler\Roblox Race Brawler` (nested one level in) |

These two ids are easy to transpose. The **longer** one is the PlaceId and is the
only value the attestation compares against.

## Rojo port allocation

**34872 belongs to Race Brawler.** Confirmed by the user 2026-08-05: this is the
only project that has ever connected to it, and every approved command and the
Studio plugin config already point there.

An earlier draft of this project's manifest declared 34873 with a comment implying
34872 was reserved for another game. That was wrong and has been corrected — do not
reinstate it.

The rule is one port per project, so **any other game on this machine must declare
something other than 34872** in its own `.claude/project-identity.json`. That is
enforced by the verifier reading each project's own manifest; it does not depend on
anyone remembering this file. If a sibling project is found declaring 34872, change
the sibling — not this one.

Serve from the project root above:

```
rojo serve default.project.json --port 34872
```

`servePlaceIds` in `default.project.json` is locked to `95742062831533`, so Rojo
will refuse to sync into any other place regardless of port.

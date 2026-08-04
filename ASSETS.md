# ReplicatedStorage.Assets

Hand-built assets (meshes, GUIs, particle templates) live under
`ReplicatedStorage.Assets`. Drag them in directly inside Roblox Studio — every
folder there is declared with `$ignoreUnknownInstances = true`, so Rojo will not
delete or overwrite what you put in them on sync.

| Folder | Holds |
| --- | --- |
| `UI_Templates` | cartoony bubbly labels, HUD buttons |
| `Track_Library` | modular road segments with collision barriers |
| `FanBox_Templates` | modular spectator pods/stands |
| `VFX_Library` | particle effects for deposits, poses, and skills |

Two folders are also created here **at runtime** by the server and are not part
of the declared layout: `TrackPieceTemplates` (`TrackPieceTemplates.BuildAll`)
and `FanBoxCrowdTemplates`. Both find their parent with
`ReplicatedStorage:FindFirstChild("Assets")`, so they land in whichever `Assets`
folder resolves first — which is why there must only ever be one.

## Why this file is here and not in `src/ReplicatedStorage/Assets/`

Because a `src/ReplicatedStorage/Assets/` directory is exactly what must not
exist.

`Assets` is declared **directly in `default.project.json`**, not synced from
disk. But `ReplicatedStorage` itself is mapped with `"$path":
"src/ReplicatedStorage"`, and Rojo turns *every* directory under a `$path` into
a Folder instance — including one that exists purely to hold a README. That
produced **two** folders named `Assets` in `ReplicatedStorage`:

1. the declared one, containing the four libraries above;
2. an empty one, from the directory this file used to sit in.

`FindFirstChild("Assets")` resolved to the empty one, so the runtime template
folders were being parented into a different `Assets` than the declared
libraries — and the `TODO` in `BubblyTextEngine.luau` to clone from
`ReplicatedStorage.Assets.UI_Templates` would have silently resolved against the
empty folder and found nothing.

Nothing referenced the libraries yet, so this never broke anything — it was
waiting to. Keeping this documentation outside `src/` is what stops the empty
folder coming back: **do not create `src/ReplicatedStorage/Assets/`.**

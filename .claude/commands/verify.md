---
description: Verify this is the correct project, editor, and git remote before doing any work.
---

Run the project verifier and report the result to the user.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Claude\_guard\bin\verify-project.ps1"
```

Then:
- **PASS** — state the project name and engine, and continue.
- **WARN** — list each warning and say what it means for the work being asked.
- **FAIL** — **stop.** Do not edit, build, or push. Report every failed check and
  what the user must do. Do not attempt to work around a failure.

For Roblox projects, if the Studio attestation is missing or stale, run the
preflight in `PREFLIGHT.md` before any Studio mutation.

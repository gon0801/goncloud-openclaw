---
name: gateway-sync-verify
description: "Verify a merged PR reached the gateway through the sync-repos cycle (the .openclaw repo and the workspace clones) without gateway exec: read clone refs and the sync log with the file tools, and fire-test plugin/guard changes with one harmless read-only exec. Use for autopilot compuertas and any summa-gate/hook/plugin change that only takes effect on the gateway after a sync."
---

# Gateway sync deployment verification

## When

A merge's "deploy" is the gateway's sync-repos cycle (clones `.openclaw`, `workspace`, `workspace-ingenieria`, `workspace-operaciones` under `C:\Users\ehven\.openclaw`) and you must confirm the SHA landed — autopilot gates, workspace content merges, and summa-gate/hook changes that take effect only after the sync pulls them.

## Steps

1. Gateway exec is pinned to the Mac node — `host:"gateway"` returns `exec host not allowed`. Verify through the file tools (`read`), never by sending `powershell`/`git -C` through exec (two wasted calls, 2026-09-16).
2. Read the clone ref directly: `C:\Users\ehven\.openclaw\.git\refs\heads\main` (workspaces use their default branch, e.g. `master`, under `workspace*` siblings). The file is the checked-out SHA — compare against the merge commit; a descendant is fine only if the merge is its ancestor (verify from the Mac with `git merge-base --is-ancestor`).
3. Read the cycle outcome in `C:\Users\ehven\.openclaw\logs\sync-repos.log`: per repo expect `pull aplico cambios (<old> -> <new>)` + `push ok`, cycle closes with `---- ciclo terminado`. `CONFLICTO` / `FALLO` lines mean that repo was left as-is — declare it with the verbatim lines; never assume a later cycle fixed it without reading it.
4. Timing: cycles run at least every 2 h at :10 past odd hours EDT (05:10, 07:10, 09:10, 11:10 observed), plus occasional extra cycles. A merge between cycles deploys on the next one — poll the ref across turns, not the clock; in-node `sleep` execs get cut (mac-node-ops step 9).
5. Fire test after a plugin/guard change (summa-gate, hooks): run ONE harmless read-only exec on the node (`gh pr view <n> -R <repo> --json state`). Success proves the deployed plugin loaded and exec is not broken; a denial or failure right after the deploy means the change broke the hook path — follow the repo's rollback note (revert + wait one sync cycle) and declare it with the verbatim error. Note the asymmetry: the guard blocking a forbidden pattern is the healthy signal; a legit read-only command failing is the alarm.

Completion check: the clone ref equals the merge SHA (or a descendant with the merge as ancestor), the last sync cycle shows no `CONFLICTO`/`FALLO` for that repo, and — for plugin changes — one read-only exec succeeded after the deploy.

---
name: gateway-sync-verify
description: "Verify a merged PR reached the gateway since the runtime separation (2026-09-22): merging does NOT deploy; any agent publishes with docs/runbooks/publicar-runtime-windows.md. Read the host source checkout, the publication manifest and the installed ledger with the file tools, and fire-test plugin/guard changes with one harmless read-only exec. Use for autopilot compuertas and any summa-gate/hook/plugin change."
---

# Gateway deployment verification (manual publication)

## When

You must confirm a merged SHA is live on the gateway: autopilot gates, and summa-gate/tablero-runbook/workshop-skill/watchdog changes. Since 2026-09-22 `C:\Users\ehven\.openclaw` is live state, **not** a git clone, and the old 2-hourly sync is disabled: a merge reaches the runtime when an agent runs `docs/runbooks/publicar-runtime-windows.md`.

## Steps

1. Gateway exec is pinned to the Mac node — `host:"gateway"` returns `exec host not allowed`. Verify through the file tools (`read`), never by sending `powershell`/`git -C` through exec.
2. Source on the host: read `C:\Users\ehven\src\goncloud-openclaw\.git\refs\heads\main` (if missing, `.git\packed-refs`). The merge must be that SHA or its ancestor (check from the Mac with `git merge-base --is-ancestor`). A change that only touches `scripts/` or `docs/` is deployed once the source has it.
3. Runtime files — only `summa-gate/**`, `tablero-runbook/**`, `agents/*/agent/workshop-skills/**` and `gateway-watchdog.ps1` are published. Read the newest `C:\Users\ehven\.openclaw-publish\<id>\selection.json`: its `commit` must be the merge or a descendant, and the path you care about must be in `files`. Then read `C:\Users\ehven\.openclaw\.ledger\sync-seguro-installed.json`: under `files`, that path (lowercased) must map to the same `sha256` as in the manifest.
4. No publication containing the merge yet → report "merged, not published" and perform the publication step. Never call it deployed because the merge exists.
5. Plugin loading is config, not files: a new plugin needs `plugins.load.paths` + `enabled` (and summa-gate `hooks.allowConversationAccess`/`allowPromptInjection`) in the gateway config. Look for `plugin registrado` lines in the gateway log after the restart, and for `typed hook … blocked` warnings.
6. Fire test after a plugin/guard change: run ONE harmless read-only exec on the node (`gh pr view <n> -R <repo> --json state`). Success proves the deployed plugin loaded and exec is not broken. A hook denial or a hook/plugin error right after the publication means the change broke the hook path (a network, auth or `gh` error of the command itself is inconclusive: retry once, then report it without rolling back): the rollback is `publish-selected.mjs … --rollback` with that publication's folder (runbook «Revertir»); declare it with the verbatim error. The guard blocking a forbidden pattern is the healthy signal; a legit read-only command failing is the alarm.
7. Workspaces (`workspace`, `workspace-ingenieria`, `workspace-operaciones`) are live agent memory: they are not deployed from git. They are backed up daily from the Mac to branch `respaldo/runtime` of each `goncloud-workspace-*` repo; their `master` is the 2026-09-21 snapshot and no longer moves.

Completion check: the host source contains the merge, the newest publication manifest's `commit` contains it and lists the path with the ledger's matching hash, and — for plugin changes — the plugin registered and one read-only exec succeeded after the publication.

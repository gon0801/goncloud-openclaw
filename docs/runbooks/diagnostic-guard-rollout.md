# Diagnostic Guard — Rollout Runbook (Fase 5)

Date: 2026-09-12
Default mode: `observe`. Promotion to `enforce` is a separate explicit
operator decision after canary evidence. Rollback is `mode=off` + safe reload.

## Preflight

1. Branch `feat/structural-investigation-guard` is based on freshly fetched
   `origin/main`; `git log --oneline origin/main..HEAD` shows only the
   planning commit and the single implementation commit.
2. Confirm the diff touches no model, provider, auth, credential, or secret
   surface:
   `git diff --name-only origin/main...HEAD | rg '(model|provider|auth|credential|secret)'`
   must print nothing.
3. Confirm the production guard references no bundled-only or private
   continuation primitive (`scheduleSessionTurn`, `enqueueNextTurnInjection`,
   `reply_payload_sending`, `resolve_exec_env`, `SUMMA_DIAGNOSTIC_CONTINUATION`).
   In tests those strings appear only as negative assertions.
4. Confirm plugin config sets
   `plugins.entries.summa-gate.config.diagnosticGuard.mode` to `observe`.
   `off` restores prior behavior; `enforce` is NOT the initial value.
5. Confirm no `tools.exec.pathPrepend` change ships in this block
   (see `Deferred PATH decision`).

## Observe canary

Run in `observe` first. `observe` appends guidance, tracks symbolic state,
and logs symbolic telemetry; it never requests a revision.

1. Isolated positive fixtures (each must yield guidance + tracked incident,
   and must NOT suppress or repeat anything):
   - `gh`: `exec` of `gh pr list` failing with `gh: command not found`
     (`isError=true`) → `incident=path_miss:gh_cli`, guidance names the
     fixed known path `C:\Users\ehven\.openclaw\tools\bin\gh.exe` and the
     five-step recovery; follow it with `which gh`, a known-location check,
     and an absolute-path `--version` probe.
   - browser-profile: `exec` of `openclaw browser --profile claw tabs --json`
     (the GLOBAL flag, not `--browser-profile`) failing with
     `gateway browser.request requires credentials before opening a websocket`
     plus a `.openclaw-claw` resolved-config path
     → `incident=wrong_profile:browser_claw`; retry once with
     `--browser-profile claw` on a read-only action. A `browser`-tool call
     with `profile=claw` is the VALID form and must yield no guidance.
   - session-scope: `sessions_search` without scope failing with
     `unable to open database file`
     → `incident=session_scope:sessions_search`; retry with explicit
     `agentId`, then explicit `sessionKeys`, then inspect for a database fault.
2. Legitimate-negative corpus (must pass through unchanged, no guidance,
   no state): successful results containing error phrases, the same phrase
   under the wrong tool, `echo` of an error, unknown command-not-found, and
   reviewer/adversary negatives without a recognized failure. Reference:
   `docs/evidence/corpus-rendiciones.tsv`.
3. Confirm the three pre-existing guards still block/pass exactly as before
   (merge guard, adversary confinement, `sessions_send`), including under a
   diagnostic registration failure.
4. Confirm logs carry only incident id, category ids, run id, counts, and
   booleans — no prompts, commands, outputs, paths, env values, or secrets.
5. Confirm no model/auth/provider diff resulted from the canary
   (re-run the Preflight file check).

## USER.md restoration

STATUS: STOPPED — preapproval package below, live file NOT touched.

The live file `C:\Users\ehven\.openclaw\workspace\USER.md` is external to this
repository and is not staged or modified by this change. Restoration requires
all four items BEFORE any edit:

1. Historical source with the exact deleted directive: NOT VERIFIED.
   Searched this repository (`docs/`, `Plans.md`, evidence, session corpora)
   for the deleted safety directive quoted verbatim — no citable source
   found. The design (`docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md`,
   Problem) records only that a new rule replaced an unrelated safety
   directive, without quoting it. Per the plan, a directive reconstructed
   from memory is NOT acceptable: do not edit until the operator supplies
   the verified historical source (gateway backup, snapshot, or transcript
   with exact bytes).
2. Backup location: to be recorded here once the source is verified
   (copy live file to a timestamped backup before editing).
3. One-line proposed diff: to be recorded here once the source is verified
   (restore literally the recovered line; read back and prove the diff
   contains only that line).
4. Proof of no active cron in the reload window: to be recorded here
   (`openclaw cron list` showing no running job overlapping the edit+reload).

If the historical source cannot be verified, this section stays STOPPED and
the task is reported incomplete — the guard rollout does not depend on it.

## Promotion gate

`observe` → `enforce` promotion requires ALL of:

1. Green observe canary above (three positive fixtures + negative corpus).
2. Explicit operator decision recorded (who + when); never by default.
3. Config change only:
   `plugins.entries.summa-gate.config.diagnosticGuard.mode: observe → enforce`.
   No code change, no model/auth/provider change.
4. Post-promotion smoke: one premature task-level incapacity final with a
   tracked incident yields exactly one same-run `revise`
   (`maxAttempts: 1`, `idempotencyKey=summa-diagnostic:<runId>`); the second
   final, completed investigations, missing/ambiguous runIds, and
   cron/heartbeat origins yield no revision.

## Rollback

1. Set `plugins.entries.summa-gate.config.diagnosticGuard.mode` to `off`.
2. Reload via the normal safe plugin reload/restart procedure, in a window
   with no active cron (verify with `openclaw cron list` first).
3. `off` registers no diagnostic hooks: tool results pass through byte-identical,
   no per-run state is written, and prior diagnostic behavior is restored
   without touching operator PATH configuration.
4. Verify: repeat one positive fixture — no `<diagnostic-contract>` block
   is appended and no `summa-gate diagnostic` lines appear in logs.

## Deferred PATH decision

- This block does NOT apply `tools.exec.pathPrepend`, does NOT call
  `resolve_exec_env` for `PATH` (the host strips it), and does NOT copy or
  inject any credential variable. Executable discovery uses known locations
  and absolute-path invocation from guidance.
- Any future global PATH change (e.g. adding the OpenClaw tools directory)
  is a SEPARATE operator-approved deployment requiring, in order:
  1. command-name collision inventory for the directory;
  2. directory ownership and write-ACL check;
  3. preserve-existing-entries plan with dry-run/read-back verification;
  4. its own explicit operator approval and a no-active-cron window.

# TDD RED log — review-fixes round (2026-09-13)

Seven major findings from the Codex review round. Each fix below was
test-driven: the failing test was written/updated first (RED, captured
here), then the production source was fixed (GREEN). Full raw outputs were
captured to the operator handoff; this file pins the RED counts and the
failing assertion names so a third party can verify RED preceded GREEN.

Runner in all cases: `node --test <file>` (Node type stripping, no build).

## diagnostic-guard.test.ts — RED before core fixes (issues 2,3,4,5)

- tests 71, pass 60, fail 11
- Failing:
  - classifies a browser global-profile miss via exec (real incident shape)
    (expected 'wrong_profile:browser_claw', actual undefined)
  - does not mistake the valid browser-tool profile for the global-flag miss
  - ignores a scoped sessions_search failure as an incident (it is not unscoped)
  - ignores a partially scoped sessions_search failure as an incident
  - does not let echo fake a version probe (spoof pin)
  - does not let echo fake executable discovery (spoof pin)
  - does not let a quoted documentary command count as a probe (spoof pin)
  - does not let result text alone grant a probe without the command (spoof pin)
  - does not grant a capability probe from result text alone (spoof pin)
  - matches the originating Spanish denial: no access
  - matches the originating Spanish denial: capability unavailable

## diagnostic-guard-middleware.test.ts — RED before middleware fix (issue 1,6)

- tests 17, pass 7, fail 10
- Failing:
  - reads runId from ctx, the only SDK-carried source
  - ignores an event-carried runId (spoof pin): ctx wins
  - appends exactly one text block and preserves everything else
  - guides codex-runtime results the same way
  - logs only symbolic telemetry, never observed content
  - rebuilds fresh state over corrupt stored state instead of crashing
  - does not lose categories on two concurrent updates of the same run
  - isolates two runIds in the same session
  - keeps the queue alive after a rejected update
  - treats a false setRunContext as a failed write: warns, still guides

## diagnostic-guard-finalize.test.ts — RED before finalize fix (issue 6)

- tests 16, pass 3, fail 13
- Failing: all seed-dependent tests (seeds drove the middleware with the
  pre-fix event-shaped call, so no state was ever written), plus the new
  pins:
  - a false setRunContext is a failed write: no revise
  - corrupt stored state fails open: no revise, no crash
  - tampered required categories fail open: no revise

## test-summa-gate-quality-entrypoints.sh — RED before fix (issue 7)

- Command: `PATH=/usr/bin:/bin bash scripts/tests/test-summa-gate-quality-entrypoints.sh`
- Result: exit 1, `FAIL: no se pudo leer scripts.check de summa-gate/package.json`
  (bare `node -e` with no node on PATH). After the fallback fix the same
  command exits 0.

## GREEN after fixes (same runner, same files)

- diagnostic-guard.test.ts: 71/71
- diagnostic-guard-middleware.test.ts: 17/17
- diagnostic-guard-finalize.test.ts + role.test.ts: 48/48
- test-summa-gate-quality-entrypoints.sh: PASS with and without node on PATH
- `node --check` clean on index.ts, lib.ts, observer.ts, diagnostic-guard.ts

---

# TDD RED log — blocking-findings round (2026-09-13, Codex re-review)

Three blocking findings. Same method: failing tests first (RED here),
then production fixes (GREEN below).

## diagnostic-guard.test.ts — RED (text-search spoof + dup threshold)

- tests 80, pass 74, fail 6
- Failing:
  - does not let a text search fake executable discovery (rg pin)
  - does not let a text search fake a known-location check (grep pin)
  - does not let a text search fake capability verification (rg pin)
  - does not let a text search fake a profile retry (rg pin)
  - does not let a text search fake resolved-config inspection (rg pin)
  - counts distinct categories only: triplicated one still revises (dup pin)
- Already-green regression pins that stayed green: chained echo+rg,
  quoted probe text (round-1 echo/quote guards).

## diagnostic-guard-finalize.test.ts — RED (real trigger + dup state)

- tests 17, pass 16, fail 1
- Failing:
  - cron/heartbeat triggers create no run, cancel nothing, and repeat no
    action (ctx `{trigger:"cron"|"heartbeat"}` revised under the old
    `inputProvenance.kind` filter)

## GREEN after fixes

- diagnostic-guard.test.ts: 81/81 (incl. new sqlite3 positive pin)
- diagnostic-guard-middleware.test.ts: 17/17
- diagnostic-guard-finalize.test.ts + role.test.ts: 50/50
  (17 finalize incl. duplicated-completed fail-open, 33 role incl. main's
  rebased observer ghost-turn test)
- observer.test.ts: 41/41 — joint battery 189/189, 0 fail

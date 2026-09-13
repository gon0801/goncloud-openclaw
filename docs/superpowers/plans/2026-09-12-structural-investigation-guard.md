# Structural Investigation Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for every behavior change and superpowers:verification-before-completion before claiming a task complete.

**Goal:** Prevent three evidenced first-probe failures from being misreported as nonexistent capabilities, without changing models, suppressing replies, or repeating external actions.

**Architecture:** Add a pure allowlisted diagnostic core to `summa-gate`, feed it through the supported tool-result middleware, and store only symbolic per-`runId` state in `api.runContext`. In `observe`, append guidance and log symbolic outcomes; in `enforce`, additionally request at most one best-effort revision in the same run. Discover `gh.exe` by known absolute paths. Cross-run continuation and plugin-owned `PATH` mutation are explicit non-features because OpenClaw 2026.9.4 does not support them for an installed plugin.

**Tech Stack:** TypeScript executed directly by Node.js 24 type stripping, Node built-in test runner, OpenClaw plugin SDK 2026.9.4, Bash quality runner, GitHub Actions.

**Spec:** `docs/spec/00-project-spec.md`; detailed design in `docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md`; ledger in `Plans.md` Fase 5.

## Global Constraints

- Implementation owner: Muse. Review owner: Codex/root. Codex does not implement this plan.
- Do not modify model selection, model chains, provider config, authentication, permissions, or secret contents.
- Do not patch OpenClaw `dist`, call private RPC, spawn Cron/heartbeat/shell continuation, use `enqueueNextTurnInjection`, or call `scheduleSessionTurn`.
- Do not register a diagnostic `reply_payload_sending` handler and never cancel a final response.
- Do not use `resolve_exec_env` for `PATH`; the host strips it. Do not apply `tools.exec.pathPrepend` in this change.
- State and logs may contain only incident id, category ids, runtime, agent id, run id, and booleans. They may not contain prompts, arguments, commands, paths, output, environment values, credentials, tokens, key material, or hashes of those values.
- Require an exact non-empty `runId`; never fall back to `sessionKey` for diagnostic state.
- Register the existing merge, adversary, and `sessions_send` guards before the diagnostic subsystem. A diagnostic registration exception must be contained.
- Default mode is `observe`; promotion to `enforce` is a separate explicit operator decision after canary evidence.
- During implementation run only the named focal test file for RED/GREEN. Keep tasks as uncommitted checkpoints and create one implementation commit after review so the mandatory pre-commit battery runs once for the block. Push the final branch and open a PR. The PR workflow is still required even though its full battery necessarily repeats the local commit gate.
- Keep the PR open. Never merge automatically and never use `--no-verify`.

## Contract Frozen for Version 1

Use these exported types and names in `summa-gate/diagnostic-guard.ts`:

```ts
export type DiagnosticMode = "off" | "observe" | "enforce";
export type IncidentId =
  | "path_miss:gh_cli"
  | "wrong_profile:browser_claw"
  | "session_scope:sessions_search";
export type ProbeCategory =
  | "executable_discovery"
  | "known_install_location"
  | "capability_verification"
  | "resolved_config"
  | "profile_retry"
  | "browser_capability"
  | "explicit_agent_scope"
  | "explicit_session_scope"
  | "database_fault_check";

export interface DiagnosticConfig {
  mode: DiagnosticMode;
  requiredProbeCategories: 3;
  maxRevisionAttempts: 1;
}

export interface DiagnosticState {
  version: 1;
  incidentId: IncidentId;
  requiredCategories: ProbeCategory[];
  completedCategories: ProbeCategory[];
  revisionRequested: boolean;
}

export interface DiagnosticObservation {
  toolName: string;
  args: Record<string, unknown>;
  isError?: boolean;
  result: unknown;
}
```

Export these pure functions:

```ts
parseDiagnosticConfig(raw: unknown): DiagnosticConfig
classifyIncident(input: DiagnosticObservation): IncidentId | undefined
classifyCompletedProbe(incidentId: IncidentId, input: DiagnosticObservation): ProbeCategory | undefined
reduceDiagnosticState(state: DiagnosticState | undefined, incidentId: IncidentId, category?: ProbeCategory): DiagnosticState
buildDiagnosticContract(state: DiagnosticState): string
isTaskLevelIncapacity(finalText: string): boolean
shouldRequestRevision(state: DiagnosticState, finalText: string): boolean
```

The namespace is exactly `summa-gate/diagnostic-guard/v1`. Every string view passed to a classifier is truncated to `MAX_INSPECTED_CHARS = 8192` before matching. The middleware result must be returned as:

```ts
{
  result: {
    ...event.result,
    content: [
      ...event.result.content,
      { type: "text", text: buildDiagnosticContract(nextState) },
    ],
  },
}
```

This preserves `details`, image items, `progress`, `terminate`, and any future top-level fields.

## Task 1: Preserve Sanitized Evidence and SDK Boundary

**Files:**

- Create: `docs/evidence/gh-path-miss-20260912.md`
- Verify: `docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md`

**Step 1: Write the evidence artifact**

Use exactly these headings: `Context`, `Observed failure`, `Incorrect conclusion`, `Independent discovery`, `SDK boundary`, `Sanitization`. Record the literal symbolic facts `tool=exec`, `incident=path_miss:gh_cli`, `known_location=C:\Users\ehven\.openclaw\tools\bin\gh.exe`, `plugin_origin=config`, and `schedule_result=undefined`. Replace every token, username beyond `ehven`, command argument, environment value, and unrelated output with `[removed]`; do not include the original prompt.

**Step 2: Prove the evidence contains the required facts and no obvious secrets**

Run:

```bash
rg -n 'tool=exec|incident=path_miss:gh_cli|known_location=C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh\.exe|plugin_origin=config|schedule_result=undefined' docs/evidence/gh-path-miss-20260912.md
rg -n '(ghp_|github_pat_|Bearer |Authorization:|api[_-]?key|BEGIN .*PRIVATE KEY)' docs/evidence/gh-path-miss-20260912.md && exit 1 || true
```

Expected: the first command finds all five facts; the second prints nothing.

**Step 3: Record the checkpoint without committing**

Use `git status --short` and `git diff -- docs/evidence/gh-path-miss-20260912.md`. Keep the change uncommitted until the single implementation commit in Task 7.

## Task 2: Establish the Source Syntax Baseline

**Files:**

- Modify: `summa-gate/package.json`
- Modify: `scripts/run-checks.sh`
- Modify: `.github/workflows/quality.yml`
- Create: `scripts/tests/test-summa-gate-quality-entrypoints.sh`

**Step 1: Write the failing contract test**

The shell test must parse the `check` script and assert it names `index.ts`, `lib.ts`, `observer.ts`, and `diagnostic-guard.ts`; assert `scripts/run-checks.sh` invokes `npm run check`; and assert CI reaches the battery through `pre-commit/action` without a second direct `run: bash scripts/run-checks.sh` step. Run:

```bash
bash scripts/tests/test-summa-gate-quality-entrypoints.sh
```

Expected RED: `summa-gate/package.json` has no `check` script.

**Step 2: Add the scripts**

Set `summa-gate/package.json` scripts exactly to:

```json
"scripts": {
  "check": "node --check index.ts && node --check lib.ts && node --check observer.ts && node --check diagnostic-guard.ts",
  "test": "node --test"
}
```

In `scripts/run-checks.sh`, after selecting Node and before `node --test`, prepend the selected Node directory to a command-local `PATH` and run `(cd summa-gate && PATH="$(dirname "$NODE"):$PATH" npm run check)`. Count failure through the existing `fallas` mechanism; do not abort before the remaining contracts run.

Remove the direct `Candados del repo (bateria + contratos)` step from `.github/workflows/quality.yml`. The preceding `pre-commit/action` already runs the always-on local `run-checks` hook over all files. Keep the workflow's OpenClaw installation before pre-commit and keep the `gate` job unchanged.

**Step 3: Run only the focal contract test**

```bash
bash scripts/tests/test-summa-gate-quality-entrypoints.sh
```

Expected GREEN: exit 0, all four source filenames are covered, and CI contains one battery entrypoint.

**Step 4: Record the checkpoint without committing**

Inspect the four changed paths with `git diff -- summa-gate/package.json scripts/run-checks.sh .github/workflows/quality.yml scripts/tests/test-summa-gate-quality-entrypoints.sh`. Keep them uncommitted until Task 7.

## Task 3: Build the Pure Allowlisted Diagnostic Core

**Files:**

- Create: `summa-gate/diagnostic-guard.ts`
- Create: `summa-gate/diagnostic-guard.test.ts`

**Step 1: Write failing classifier tests**

Cover all three positive incidents and these negative controls:

- the same phrase in a successful result;
- the same phrase under the wrong tool;
- an `echo` of the phrase;
- an unknown command-not-found;
- a legitimate reviewer/adversary negative without a recognized failure;
- input longer than 8192 characters with the signature only after the limit.

The `gh` classifier requires `isError === true`, tool `exec` or `bash`, an attempted command whose first executable token is `gh`, and a command-not-found/path-resolution signature. Browser requires the browser tool plus evidence that the global profile was selected instead of `claw`. Session scope requires `sessions_search`, a structured failure, and the unscoped-database signature. Do not classify from result text alone.

> Correction (Codex review round 1, 2026-09-13, grounded in `agents/main/agent/workshop-skills/browser-cli-claw-profile/SKILL.md:12-15`): the browser incident is classified from `exec`/`bash` running the CLI with the GLOBAL `--profile claw` flag plus the credentials signature — not from the `browser` tool, whose tool-style `profile=claw` is the valid form. Likewise the session incident requires ABSENT scope (`agentId`/`sessionKeys`), and probes validate the executed command/params, never result text. The implementation and its tests follow the corrected form; this note keeps the plan traceable.

Run:

```bash
cd summa-gate && node --test diagnostic-guard.test.ts
```

Expected RED: module not found.

**Step 2: Implement bounded extraction and incident classification**

Implement a recursive, cycle-safe string collector that reads at most 8192 total characters from `args` and `result`, without logging or retaining the collected string. Restrict recognized command fields to `command`, `cmd`, and `input`. Reject `isError !== true`.

**Step 3: Write failing reducer/probe tests**

For every incident, assert its three exact relevant categories. A completed tool result counts whether its sanitized result label is `FOUND`, `NOT_FOUND`, `DENIED`, or `AUTH_FAILED`; an aborted call, a call without a final result, an unrelated subject, or a repeated category does not advance. Assert state contains only the five `DiagnosticState` keys.

**Step 4: Implement reducer and static guidance**

Guidance begins with `<diagnostic-contract incident="...">`, says the initial failure proves only that path failed, lists the remaining symbolic categories, forbids secret-value output and repeat external actions, and ends with `</diagnostic-contract>`. Do not interpolate args, results, paths, prompts, or environment values. Only the fixed known path for `gh.exe` may appear in the static `path_miss:gh_cli` contract.

**Step 5: Write and pass incapacity tests**

Test task-level conclusions such as “I cannot access GitHub in this run” and “the capability is unavailable” only when they are the principal conclusion or occur in the final substantive paragraph. Test that quoted errors, historical discussion, reviewer findings, and “the first method failed; I will inspect another path” do not match. Do not import or reuse `observer.ts`'s broad `INCAPACITY_RE`.

Run:

```bash
cd summa-gate && node --test diagnostic-guard.test.ts
```

Expected GREEN: all pure-core tests pass.

**Step 6: Record the checkpoint without committing**

Inspect `git diff -- summa-gate/diagnostic-guard.ts summa-gate/diagnostic-guard.test.ts` and keep it uncommitted until Task 7.

## Task 4: Wire Middleware, Run State, Manifest, and Failure Isolation

**Files:**

- Modify: `summa-gate/index.ts`
- Modify: `summa-gate/openclaw.plugin.json`
- Create: `summa-gate/diagnostic-guard-middleware.test.ts`
- Modify: `summa-gate/role.test.ts`

**Step 1: Extend fake APIs before production wiring**

All existing fake plugin APIs must supply no-op `registerAgentToolResultMiddleware` and a memory-backed `runContext` with these SDK signatures:

```ts
setRunContext({ runId, namespace, value }): boolean
getRunContext({ runId, namespace }): unknown
clearRunContext({ runId, namespace? }): void
```

Keep storage keyed by `${runId}:${namespace}`. Do not weaken existing guard assertions.

**Step 2: Write failing middleware preservation tests**

Build a fake `AgentToolResult` containing text, an image item, `details`, `progress`, `terminate`, and an extra future field. Assert a recognized error returns a new result with one appended text item and all original fields/items unchanged. Assert an unknown error returns `undefined`. Assert missing `runId` appends no guidance and writes no state.

Run:

```bash
cd summa-gate && node --test diagnostic-guard-middleware.test.ts
```

Expected RED: no middleware registered.

**Step 3: Declare and register the supported middleware**

Add to `openclaw.plugin.json`:

```json
"contracts": {
  "agentToolResultMiddleware": ["openclaw", "codex"]
}
```

Add `diagnosticGuard` to `configSchema` with `additionalProperties: false`, enum `off|observe|enforce`, integer `requiredProbeCategories` fixed to minimum/maximum 3, and integer `maxRevisionAttempts` fixed to minimum/maximum 1. Keep all fields optional because runtime defaults are applied by `parseDiagnosticConfig`.

Register with:

```ts
api.registerAgentToolResultMiddleware(handler, {
  runtimes: ["openclaw", "codex"],
});
```

If mode is `off`, do not register it. For Codex native tools, document in code that the host may observe without re-injecting transformed content; never claim reinjection unless the integration test proves it.

**Step 4: Serialize per-run updates**

Use a module-local `Map<string, Promise<void>>` only as a lock queue. The map key is `runId`; values contain no diagnostic data. Read state from `api.runContext`, reduce it, write it back, then remove the settled promise if it is still the current entry. No state map keyed by session is allowed.

Test two concurrent category completions for the same run without loss and two runs in the same session without mixing. Test a rejected update does not poison the queue.

**Step 5: Isolate diagnostic registration failure**

Place diagnostic registration after the existing merge guard, adversary confinement, and `sessions_send` registrations, inside its own `try/catch`. The catch logs only `summa-gate diagnostic: registration failed` plus the error class, not arbitrary error messages. A fake that throws from middleware registration must still show all three existing protections registered.

**Step 6: Run focal tests**

```bash
cd summa-gate && node --test diagnostic-guard-middleware.test.ts
```

Expected GREEN: preservation, concurrency, missing-runId, config modes, and failure isolation pass.

**Step 7: Record the checkpoint without committing**

Inspect the four task paths with `git diff` and keep them uncommitted until Task 7.

## Task 5: Add Best-Effort Same-Run Revision Without Reply Suppression

**Files:**

- Modify: `summa-gate/index.ts`
- Create: `summa-gate/diagnostic-guard-finalize.test.ts`

**Step 1: Write failing finalize tests**

Capture `before_agent_finalize` registrations and identify the diagnostic handler by behavior, without changing the existing receipt-gate test. Cover:

- `observe`: no revise;
- `off`: no diagnostic finalize handler;
- `enforce`, recognized state, task-level incapacity, fewer than three categories, exact runId: one revise;
- second call for the same run: no revise;
- three categories complete: no revise;
- ambiguous or missing runId: no revise;
- cron/heartbeat trigger: no new run, no cancellation, no repeated action;
- two finals in concurrent runs: isolated outcomes;
- diagnostic registration failure: existing receipt gate still works.

Assert the fake scheduler spy remains zero and no diagnostic `reply_payload_sending`, `resolve_exec_env`, Cron, heartbeat, or continuation-marker hook is registered.

Run:

```bash
cd summa-gate && node --test diagnostic-guard-finalize.test.ts
```

Expected RED: diagnostic finalize behavior is absent.

**Step 2: Implement one same-run revision**

Return exactly:

```ts
{
  action: "revise",
  reason: "A recognized first-path failure was converted into a task-level incapacity conclusion before three distinct diagnostic categories completed.",
  retry: {
    instruction: buildDiagnosticContract(nextState),
    idempotencyKey: `summa-diagnostic:${event.runId}`,
    maxAttempts: 1,
  },
}
```

Set `revisionRequested=true` in run context before returning. If the state write fails, fail open and return nothing. Do not store or log `lastAssistantMessage`.

**Step 3: Add symbolic middleware/finalize telemetry**

Log state transitions inside the middleware and the final decision inside `before_agent_finalize`, while run context is still available. Use one fixed event name plus incident id, completed-category count, revision-requested boolean, and task-level-incapacity boolean. Inspect final text transiently and discard it. Do not depend on `agent_end`: OpenClaw may clear run context before that terminal hook. Existing `rendiciones.jsonl` behavior stays unchanged; do not add diagnostic text to it.

**Step 4: Run focal tests**

```bash
cd summa-gate && node --test diagnostic-guard-finalize.test.ts
```

Expected GREEN: exactly one best-effort revision, zero suppression, zero scheduling, and symbolic-only telemetry.

**Step 5: Record the checkpoint without committing**

Inspect `git diff -- summa-gate/index.ts summa-gate/diagnostic-guard-finalize.test.ts` and keep it uncommitted until Task 7.

## Task 6: Prepare Absolute Executable Discovery and Safe Rollout

**Files:**

- Modify: `summa-gate/diagnostic-guard.ts`
- Modify: `summa-gate/diagnostic-guard.test.ts`
- Create: `docs/runbooks/diagnostic-guard-rollout.md`
- Live, separately preapproved: `C:\Users\ehven\.openclaw\workspace\USER.md`

**Step 1: Test the static `gh` recovery sequence**

The `path_miss:gh_cli` contract must prescribe, in order:

1. inspect the runtime's executable inventory;
2. test the fixed known location `C:\Users\ehven\.openclaw\tools\bin\gh.exe` without printing environment values;
3. invoke the found binary by absolute path for a read-only `--version` probe;
4. verify auth/capability status without printing credential values;
5. only after three distinct categories, report `NOT_FOUND_AFTER_CHECKS`, `DENIED`, `AUTH_FAILED`, or `WRONG_HOST`.

Run:

```bash
cd summa-gate && node --test diagnostic-guard.test.ts
```

Expected GREEN after the static contract contains all five ordered requirements.

**Step 2: Write the rollout runbook**

The runbook must contain exact sections `Preflight`, `Observe canary`, `USER.md restoration`, `Promotion gate`, `Rollback`, `Deferred PATH decision`. It must say:

- use mode `observe` first;
- run isolated `gh`, browser-profile, and session-scope positive fixtures plus the legitimate-negative corpus;
- confirm no model/auth/provider diff;
- set mode `off` and safely reload outside active cron to roll back;
- do not apply `tools.exec.pathPrepend` in this block;
- any future PATH change requires collision inventory, directory ownership/write-ACL check, preserve/read-back, and its own operator approval.

**Step 3: Stop for the live-file preapproval**

Before touching `C:\Users\ehven\.openclaw\workspace\USER.md`, show the operator:

- the historical source containing the exact deleted directive;
- a backup path;
- a one-line proposed diff;
- proof no cron is active in the reload window.

After approval, copy the directive literally from the verified historical source. Do not reconstruct it from memory. Read back and prove the diff contains only that line. If the historical source cannot be verified, do not edit the live file and report the task incomplete.

**Step 4: Record the checkpoint without committing**

Inspect the repository artifacts with `git diff` and keep them uncommitted until Task 7. The live `USER.md` change is never staged in this repository.

## Task 7: Muse Self-Review and Codex Review Gate

**Files:** all task diff.

**Step 1: Muse performs mechanical self-review**

Run:

```bash
git diff --check
git diff --check origin/main...HEAD
git log --oneline origin/main..HEAD
git diff --name-only | rg '(model|provider|auth|credential|secret)' && exit 1 || true
rg -n 'scheduleSessionTurn|enqueueNextTurnInjection|reply_payload_sending|resolve_exec_env|SUMMA_DIAGNOSTIC_CONTINUATION' summa-gate/diagnostic-guard.ts summa-gate/diagnostic-guard-*.test.ts
```

Expected: committed and uncommitted diffs are clean; only the planning commit is present before the final implementation commit; no model/auth filenames changed; the forbidden-symbol search finds only explicit negative assertions in tests, never production code.

**Step 2: Hand the diff to Codex/root for one review round**

Codex/root reviews behavior, security/privacy, run isolation/concurrency, SDK compatibility, test quality/mutation resistance, and AI residuals. Codex groups all findings in this one round. Muse fixes the batch in one commit. A second review round is allowed only if the first contains a high-severity finding; never run a third.

**Step 3: Re-run only tests touched by review fixes**

Choose only the affected files from this fixed list and run each once: `diagnostic-guard.test.ts`, `diagnostic-guard-middleware.test.ts`, `diagnostic-guard-finalize.test.ts`, or `scripts/tests/test-summa-gate-quality-entrypoints.sh`. Do not run the full repository battery manually.

**Step 4: Update the ledger and create the single implementation commit**

Record the truthful Fase 5 statuses and any discrepancies in `Plans.md`. Use `git status --short` to ensure only the paths named by Tasks 1–6 plus `Plans.md` changed. Stage those paths explicitly, excluding any unrelated user file, then run one normal commit:

```bash
git commit -m "feat(summa-gate): add structural investigation guard"
```

The mandatory pre-commit hooks run the complete local battery here. Never use `--no-verify`. If the commit fails, fix the failure and retry the normal commit; do not run the full battery separately.

## Task 8: Pre-commit, PR, and Final-SHA CI

**Step 1: Refresh remote knowledge and verify branch purity**

```bash
git fetch origin
git log --oneline origin/main..HEAD
```

Expected: only the planning and Fase 5 implementation commits. If an unrelated commit appears, stop and repair the base before pushing. A newer `origin/main` alone is not an impurity and does not justify rewriting the already tested commit.

**Step 2: Push and open the pull request**

This external send requires the Fase 5 preapproval recorded in `Plans.md`.

```bash
git push -u origin feat/structural-investigation-guard
gh pr create --base main --head feat/structural-investigation-guard --title "feat: add structural investigation guard" --body-file docs/superpowers/plans/2026-09-12-structural-investigation-guard.md
```

Do not merge.

**Step 3: Read CI once on the final SHA**

```bash
gh pr checks --watch
```

Confirm the `quality` plus `gate` union ran the complete repository battery once through pre-commit and passed on the final SHA. If the SHA changes after CI, the prior evidence is invalid and the new PR CI run is the one that counts.

**Step 4: Report completion evidence**

Report branch, commit SHA, PR URL, CI result, pre-commit result, files changed, canary mode, deferred items, and any declared discrepancy. Keep the PR open for the operator.

## Acceptance Matrix

| Requirement | Proving test/evidence |
|---|---|
| Same model configuration | no model/provider/auth file in `origin/main...HEAD`; runbook read-back |
| Three allowlisted incidents only | `diagnostic-guard.test.ts` positive and wrong-tool/unknown negative controls |
| Real failure required | successful-result and `isError` mutation tests |
| Three distinct relevant probes | reducer duplicate/unrelated/aborted tests |
| Symbolic state and privacy | canary strings absent from run context, logs, and appended guidance |
| Concurrent runs isolated | middleware test with two runIds in one session |
| Existing safety guards survive | registration-failure integration test |
| Original tool result preserved | middleware image/details/progress/terminate/future-field test |
| No response suppression or fake continuation | finalize zero-cancel/zero-scheduler/zero-hook assertions |
| Absolute `gh.exe` recovery | static contract test plus isolated observe canary |
| Rollback | mode `off` registration test and runbook read-back |
| Repository quality | normal pre-commit plus green PR `quality`/`gate` on final SHA |

## Handoff to Muse

Working tree prepared for implementation:

```bash
cd /private/tmp/goncloud-openclaw-structural-retry
git fetch origin
git rebase origin/main
/Users/dn/.local/bin/muse --worktree existing --worktree-existing /private/tmp/goncloud-openclaw-structural-retry --trust-workspace
```

The command deliberately omits `--model`, so Muse uses its existing configured model rather than changing model selection for this task.

First message to Muse:

```text
Implementa docs/superpowers/plans/2026-09-12-structural-investigation-guard.md exactamente por tareas y con TDD focalizado. Tú eres el único implementador. No cambies modelos. No suprimas respuestas ni fabriques continuaciones: scheduleSessionTurn es bundled-only y resolve_exec_env no puede cambiar PATH. Detente antes de USER.md, push y PR si la preaprobación de Fase 5 no está registrada. Cuando termines la implementación y tu self-review, entrega el diff a Codex/root para una sola ronda de revisión; Codex no implementa.
```

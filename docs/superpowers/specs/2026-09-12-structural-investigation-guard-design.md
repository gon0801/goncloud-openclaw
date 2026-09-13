# Structural Investigation Guard

Date: 2026-09-12
Status: approved direction; revised during implementation planning for the OpenClaw 2026.9.4 installed-plugin boundary
Scope: all OpenClaw agents, without changing model selection or model chains

## Problem

OpenClaw sometimes converts the first failed lookup into a universal conclusion. Two observed examples are:

- `gh` was not on `PATH`, so the agent claimed that GitHub CLI and credentials did not exist. The executable was installed under `C:\Users\ehven\.openclaw\tools\bin`, authenticated through the Windows credential store, and a user-level `GH_TOKEN` also existed.
- `openclaw browser --profile claw ...` selected an empty global OpenClaw profile. The resulting credentials error was interpreted as a missing gateway key even though `--browser-profile claw` was the correct command.

Static instructions are not sufficient. The agent added a new rule to `USER.md` after the first incident while accidentally replacing an unrelated safety directive. The existing `before_agent_finalize` revision hook is also insufficient because OpenClaw discards revisions after a deterministic side effect, including `exec`.

The system needs to intervene where the bad inference begins: between a tool result and the next model step, with one bounded same-run revision request when the host can honor it safely.

This design supersedes only the earlier decision against a broad lexical “no se puede” gate. That gate had no reliable signal and would have blocked legitimate technical negatives. The new naturalistic `gh` incident supplies a narrower signal: a recognized tool failure followed by an unsupported capability conclusion. Enforcement below requires that tool-failure state and exact run correlation; text alone can never activate it.

## Goals

1. Distinguish “the first lookup failed” from “the capability does not exist.”
2. Require three distinct, relevant diagnostic paths before an agent reports an unavailable capability.
3. Give the model error-specific next steps immediately after the failing tool result.
4. Request at most one same-run revision when the host can honor it safely; never cancel a reply unless a continuation is already guaranteed by a supported host primitive.
5. Apply guidance to the full fleet while preventing duplicate business actions in cron and operations flows.
6. Preserve privacy: never persist prompts, commands, tool output, environment values, credentials, tokens, or key material.
7. Preserve current model configuration exactly.

## Non-goals

- Choosing, upgrading, reordering, or overriding models.
- Proving that every requested operation is possible.
- Automatically changing authentication, permissions, accounts, profiles, or gateway configuration.
- Retrying an external write, message, purchase, publish, delete, deployment, or business automation.
- Using an LLM classifier to decide whether a response is allowed.
- Patching OpenClaw's installed `dist` files or pretending that a bundled-only API works for an installed plugin.

## Architecture

The existing `summa-gate` plugin gains a small diagnostic subsystem with pure classification and state-machine logic in `summa-gate/diagnostic-guard.ts`. Hook wiring remains in `summa-gate/index.ts`.

### 1. Error classification

The classifier consumes a bounded text view of a tool error/result in memory and returns only a symbolic incident. Version 1 recognizes only incident/subject pairs backed by repo or sanitized runtime evidence:

| Incident | What the error proves | Required diagnostic categories |
|---|---|---|
| `path_miss:gh_cli` | `gh` was not resolved from the current `PATH` | executable discovery, known OpenClaw install locations, sanitized auth/capability verification |
| `wrong_profile:browser_claw` | the global OpenClaw profile was selected where the browser profile was intended | inspect resolved config path, retry with `--browser-profile claw`, verify the browser capability |
| `session_scope:sessions_search` | an unscoped session lookup could not resolve its database | retry with explicit `agentId` and `sessionKeys`, verify the session owner, then inspect for a database fault |

Classification is allowlisted by tool name, subject, and failure state. `event.isError === true` or an equivalent structured failure is mandatory. Successful web/tool output that merely contains an error phrase, an `echo`, the same phrase under the wrong tool, and unknown errors receive no intervention. Additional incident families require a sanitized positive fixture plus negative controls before being added.

### 2. Tool-result guidance

`api.registerAgentToolResultMiddleware` targets both supported runtimes, `openclaw` and `codex`, and appends a compact `<diagnostic-contract>` block to recognized tool results before the model sees its next step. `openclaw.plugin.json` declares both runtimes under `contracts.agentToolResultMiddleware`. The block contains:

- the symbolic incident;
- one sentence stating what the error proves and does not prove;
- the three required diagnostic categories;
- an instruction not to repeat external side effects;
- an instruction to report values only as `SET`, `UNSET`, `FOUND`, or `NOT_FOUND`.

The original result remains unchanged. The appended guidance contains no raw secret or user content.

### 3. Per-run evidence state

The same tool-result middleware updates plugin-owned state keyed by `runId` through `api.runContext`. State contains only:

```text
incident kind
required category ids
completed category ids
symbolic incident subject
whether a same-run revision was already requested
```

Commands and results are inspected transiently to categorize a probe, then discarded. No command text, path, output, prompt, hash of sensitive material, or credential value is stored.

A probe counts only when its tool call completed. The middleware has the completed call's name, arguments, error bit, and result, so no pending command state is needed. Repeating the same category does not advance the three-path requirement.

### 4. Final-response handling and hard capability boundary

The guard intervenes only when all conditions are true:

1. the current run has a recognized incident;
2. the final answer makes an explicit task-level incapacity claim: a first-person/agent/runtime inability statement in the final substantive paragraph, or a short answer whose principal conclusion is inability;
3. fewer than three required diagnostic categories completed;
4. the final payload is correlated by exact `runId`;
5. the run has not already received its one revision request.

`before_agent_finalize` may request one same-run revision with a stable idempotency key and `maxAttempts: 1`. OpenClaw may discard that revision after a deterministic side effect; in that case the original final is delivered. The plugin records the symbolic outcome but does not attempt a second path.

OpenClaw 2026.9.4 exposes `api.session.workflow.scheduleSessionTurn(...)` only to bundled plugins. `summa-gate` is an explicitly enabled installed/configured plugin, so this API returns `undefined`. `enqueueNextTurnInjection(...)` does not start a turn. Therefore version 1 must not register a cancelling `reply_payload_sending` handler, must not invoke Cron through shell or private runtime APIs, and must not use a textual continuation marker. Automatic cross-run continuation remains blocked until OpenClaw exposes an authenticated supported primitive to installed plugins or `summa-gate` is accepted upstream as bundled.

If the capability is still unavailable after guidance or the one host-supported revision, the agent must distinguish:

- `NOT_FOUND_AFTER_CHECKS`: three sources checked without finding it;
- `DENIED`: a named policy layer denied a concrete command;
- `UNAVAILABLE_IN_RUNTIME`: the capability exists but this runtime does not expose it;
- `AUTH_FAILED`: a named auth path failed after status/source checks.

It must include the three categories checked and sanitized result labels, not an absolute “it does not exist.”

### 5. Fleet and automation safety

The guidance applies to every agent. Enforcement is narrowed as follows:

- Direct owner conversations and delegated engineering sessions: guidance plus at most one host-supported same-run revision.
- Cron, heartbeat, and operations sessions: guidance applies; no new run is created and no business action is repeated.
- Reviewer and adversary: a negative technical finding alone never activates the guard. A recognized tool failure in the same run is required.
- Concurrent turns in one session: enforcement requires exact `runId`; session-only correlation fails open.

### 6. Executable discovery and PATH

The plugin must not try to change `PATH` through `resolve_exec_env`: OpenClaw always drops that key because command resolution and safe-bin checks depend on it. Guidance for `path_miss:gh_cli` first discovers known locations and invokes a found executable by absolute path.

The supported operator surface is `tools.exec.pathPrepend`, applied outside the plugin. It is a separate deployment decision, not coupled to `diagnosticGuard.mode`. Before adding `<USERPROFILE>\.openclaw\tools\bin`, deployment must inventory command-name collisions, verify directory ownership/write ACLs, preserve existing entries, perform a dry-run/read-back, and use a window with no active cron. No credential variable is injected or copied.

## Configuration and rollback

`summa-gate/openclaw.plugin.json` extends its JSON Schema with a `diagnosticGuard` object containing these optional properties:

```json
{
  "diagnosticGuard": {
    "mode": "observe",
    "requiredProbeCategories": 3,
    "maxRevisionAttempts": 1
  }
}
```

The plugin reads values from `api.pluginConfig`. All fields are optional in live config. Runtime defaults are `observe`, `3`, and `1`. Supported modes:

- `enforce`: guidance, evidence tracking, and at most one best-effort same-run `before_agent_finalize` revision; never cancellation or cross-run scheduling;
- `observe`: guidance and symbolic compliance logging, without requesting revision;
- `off`: no diagnostic hooks. Executable discovery and any operator-owned `tools.exec.pathPrepend` setting remain independent.

Initial rollout is `observe`. Promotion to `enforce` requires a canary/replay with the three positive fixtures and the legitimate-negative corpus, followed by an explicit operator decision. Immediate rollback sets `plugins.entries.summa-gate.config.diagnosticGuard.mode` to `off` and uses the normal safe plugin reload/restart procedure outside active cron windows. Model configuration is untouched.

## Privacy and security

- The subsystem never writes tool output or final-response text to disk.
- Logs contain incident kind, category ids, agent id, run id, and boolean outcomes only.
- Environment and credential probes are instructed to reveal presence, never values.
- Guidance never recommends reading secret contents.
- The subsystem cannot create another run and cannot authorize account, configuration, install, restart, message, publish, purchase, deploy, or deletion actions.
- Existing adversary confinement and merge guards remain unchanged.

## Testing

Implementation follows red-green-refactor.

1. Unit tests for each allowlisted incident/subject pair and unknown-error fail-open behavior, including successful output containing every error phrase.
2. Unit tests for distinct category counting, repeated probes, completed-versus-failed probes, and the three-path threshold.
3. Hook integration tests using a fake plugin API:
   - the `gh` PATH incident receives the correct guidance;
   - the browser global-profile incident is classified as `wrong_profile`;
   - `Unavailable in this run` is not described as non-existence;
   - unscoped `sessions_search` is guided toward explicit scope;
   - a same phrase under the wrong tool does not activate the guard;
   - a legitimate reviewer sentence is delivered unchanged;
   - a premature correlated final requests at most one same-run revision;
   - absent or mismatched `runId` fails open;
   - no `reply_payload_sending`, scheduler, heartbeat, shell-Cron, continuation-marker, or PATH hook is registered.
4. Privacy tests assert that prompt, command, output, token-shaped strings, and environment values never enter state, logs, or appended guidance.
5. Failure-isolation tests prove that diagnostic registration failure leaves merge guard, adversary confinement, and `sessions_send` protection registered.
6. Mutation checks make removal of `isError`, a real incident signature, the distinct-category rule, privacy redaction, or the one-revision limit fail the battery.

During implementation only the changed test file is run for red/green cycles. The mandatory pre-commit battery runs once at the final implementation commit; the required pull-request workflow then reruns the battery on that final SHA.

## Rollout and acceptance

1. Create the task branch from freshly fetched `origin/main`.
2. Implement with default `observe` and documented `off` rollback; do not implement outbound suppression or cross-run scheduling.
3. Muse implements; Codex/root performs the single review round requested by the operator.
4. Push and open a PR; do not merge automatically.
5. Require green union CI for the final SHA.
6. After operator merge and safe gateway reload, run isolated `gh`, browser-profile, and session-scope smokes. Any `tools.exec.pathPrepend` change is a separately approved operator action.

Acceptance requires evidence that:

- no model configuration changed;
- the initial PATH miss receives guidance to discover and use the absolute `gh.exe` path rather than treating the miss as nonexistence;
- the agent finds `gh` or completes three distinct checks before reporting a sanitized blocker;
- a legitimate reviewer negative is not withheld;
- at most one same-run revision is requested and no cross-run continuation is scheduled;
- no external action is repeated;
- disabling the guard restores prior diagnostic behavior without changing operator PATH configuration;
- pre-commit and final PR CI pass.

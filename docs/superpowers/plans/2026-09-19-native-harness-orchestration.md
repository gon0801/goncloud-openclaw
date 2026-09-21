# Native Harness Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `main` route an engineering request to the best available native CLI worker, expose every run in Terminal and the existing dashboard, and autonomously complete the reviewed PR, merge, deploy, canary, or verified rollback.

**Architecture:** Keep `corrida.sh` as the lifecycle boundary and `tablero-runbook` as the read-only operator view. Add a versioned worker registry plus a deterministic Python control-plane CLI for validation, selection, gate state, and reconciliation; keep external effects in small Bash subcommands that own worktrees, `tmux`, Terminal, GitHub, and deployment. Every durable transition is written atomically to `registro.json`, keyed by SHA, so restart and retry converge instead of repeating effects.

**Tech Stack:** Bash 3.2, Python 3.10+ standard library, JSON, git worktrees, tmux, macOS Terminal automation, TypeScript/Node test runner, OpenClaw plugin SDK, GitHub CLI, quality-kit cross-review.

**Spec:** `docs/superpowers/specs/2026-09-19-native-harness-orchestration-design.md`


## Execution prerequisites and ownership (revised 2026-09-20)

This document is a corrected plan, not an instruction to start Phase 14 now. Finish Phase 15, then Phase 9, before implementation. Delivery-without-seal Blocks A/B/C must be integrated and the applicable kit installed. No pending PR number is evidence of integration.

Before starting, fetch both repos, record their default-branch SHAs, read the Phase 9/15 closure evidence, verify the Phase 9 installed manifest/hashes and registered `usuario`, confirm `python3` is 3.10 or newer, and inspect the installed kit receipt interface. Resolve any installer filename difference in Task 9 once. Missing prerequisites produce one explicit pending-dependency report; do not repeatedly launch the phase.

| Owner | Result consumed here | Phase 14 action |
|---|---|---|
| Phase 15 | CI coverage, sharding, injected test clocks and timing evidence | Reuse; no rewrite of `quality.yml`, pre-commit or test timing infrastructure |
| Phase 9 | Installed corrida runtime, bounded close/recovery, installer/rollback, registered usuario, user acceptance and global-clock canary | Extend and regression-test; do not reinstall an alternative scheduler or recreate usuario |
| Delivery-without-seal A/B/C | Persistent PR receipt, independent roles and canonical delivery loop | Consume; no signing model or session-dependent merge authorization |
| Phase 23, SummonAIKit repo | Muse compatibility and hook improvements | Independent; consume merged behavior if available. Recommended pending rows do not block Phase 14 |

The final preflight updates paths and SHAs against completed Phase 9, not its feature design. Phase 23 modifications belong to its own repo and worktree, and never run concurrently against an unmerged Block A hook.

### Implementation blocks and dependency order

Use four code PRs, each cut from freshly fetched `origin/main` after its predecessor merges: `fase14/registro-adaptadores` (Tasks 1–4), `fase14/estado-entrega` (Tasks 5–7), `fase14/tablero-direccion` (Tasks 8–9), `fase14/rollout` (Task 10 driver and rollout contract). Then deploy and record live acceptance in one `docs/fase14-cierre` PR. Tasks retain their focused tests and may use local commits; they do not each require another PR or whole-change review. Serialize edits to `corrida.sh`, `lib.sh` and `corrida-worker.py`. Read-only investigation may overlap.

A block has one grouped correction batch per review round. Only a reproducible blocker opens the next round; review only the fixes with a different reviewer. The same blocker in two consecutive rounds stops the lane for the operator, as required by quality-kit. Nonblocking one-line fixes fit the current batch; other residuals get tracker rows and PR disclosure. No arbitrary round cap permits an open blocker to merge.

### Monitoring, quota and bot availability

Retain `corrida.v2` with one global `avance-tareas` internal tick every 15 minutes and consolidated `seguimiento.v2` updates every 30 minutes while work is active. Progress percentages derive from task counts. Existing tmux events wake the director between ticks. No per-worker delivery cron, second `corrida-latido` LaunchAgent or hourly reporting clock. Closure releases only phase-owned state; other work keeps the shared clock.

Worker quota/auth/missing-binary failures move to the next compatible unattempted candidate immediately. An ordinary crash permits one resume. Confirm that the previous writer and its children stopped before handing off the preserved worktree, commits and diff. No paid top-up or provider account change is authorized. Required host-specific measurements remain pending for that host.

CodeRabbit is requested once after local review. Read its comments on the current SHA. Explicit quota exhaustion is disclosed immediately; pending/unknown gets one recheck after at most 20 minutes, scheduled while other work proceeds. Continued unavailability is recorded in the receipt evidence/PR under the canonical loop policy, never called approval. Current CI, the independent verifier/reviewer and absence of open blockers remain required. Honor any GitHub-required bot check; if it prevents merging, report that external requirement and do not bypass branch protection. Do not wait indefinitely for quota.

## Global Constraints

- The initial registry uses the versions measured on 2026-09-19: Claude Code 2.1.278, Codex CLI 0.155.1, ZCode 0.16.5, Kimi Code CLI 0.39.1, Cursor Agent CLI 2026.09.18-9a7762b, and Grok CLI 1.0.34.
- Claude, Codex/OpenAI, GLM, Kimi, Cursor, and Grok use their native harnesses; GLM uses `zcode`, not a Claude Code compatibility wrapper.
- A run has at most four external harness sessions active at once.
- Writers never share a worktree. Each writing branch starts from a freshly fetched `origin/<default>`.
- `main` chooses and records the worker but never performs merge, live configuration, or deploy. Only `implementer` or `ingenieria` executes those effects.
- The first push and PR happen only after local cross-review has no reproducible blocker.
- A CodeRabbit blocker is corrected locally, cross-reviewed only over the correction, then pushed to the same PR. CI and CodeRabbit rerun for the new SHA.
- CodeRabbit unavailable is recorded as unavailable, never as approval; use the canonical declared-unavailability policy below. Only reproducible blockers reopen correction reviews.
- Merge consumes the installed kit's persistent `saikit-entrega.v1` PR receipt and current CI evidence; use `expectedHeadOid`. Local hook state, a signing model and a second approval format are not prerequisites.
- Success means a canary passed against the live SHA. A failed canary ends in a verified rollback or an evidence-bearing alert.
- The dashboard remains read-only. It renders state written by the director and never executes an arbitrary command.
- Worker paths, tokens, destinations, and credentials remain local; no versioned file contains them.
- During implementation run only focused tests. Run the full battery once on the final PR SHA in CI; every correction SHA caused by a blocking review invalidates the prior CI evidence.
- Run every configured pre-commit hook. Never use `--no-verify`.
- Keep the legacy `agent-dispatch` flow available behind the automatic-routing kill switch during staged rollout.

## Review Focus

- A registry row with a malicious binary, argument, regex, or transcript path must fail validation before any subprocess starts; Task 1 pins this with invalid fixtures.
- Two concurrent selectors must not both reserve the fourth slot or the same writable worktree; Task 4 pins the lock and capacity race.
- A restart between an external effect and its local state write must discover the already-created branch, PR, merge, or deploy and record it without repeating it; Task 5 pins every recovery boundary.
- A stale clean CodeRabbit result or green CI result for an older SHA must not authorize merge; Task 6 pins evidence applicability and current-head receipt validation.
- Terminal automation failure, untrusted transcript text, or very long worker metadata must not stop work, inject HTML, or leak secrets; Task 8 pins degraded visibility, escaping, truncation, and redaction.

---

### Task 1: Versioned worker registry and strict validation

**Files:**
- Create: `scripts/mac/workers.v1.json`
- Create: `scripts/mac/corrida_worker/__init__.py`
- Create: `scripts/mac/corrida_worker/registry.py`
- Create: `scripts/mac/corrida-worker.py`
- Create: `scripts/tests/fixtures/workers/valid.json`
- Create: `scripts/tests/fixtures/workers/invalid-command.json`
- Create: `scripts/tests/fixtures/workers/invalid-pattern.json`
- Create: `scripts/tests/fixtures/corrida/v2-existing-without-workers.json`
- Create: `scripts/tests/fixtures/corrida/v2-native-workers.json`
- Create: `scripts/tests/test-worker-registry.sh`
- Modify: `docs/spec/corrida.v2.md`

**Interfaces:**
- Consumes: local executable overrides from `CORRIDA_WORKER_BIN_<UPPER_ID>`; no secrets or absolute user paths from the registry.
- Produces: `load_registry(path: Path) -> Registry`, `resolve_binary(worker: Worker, env: Mapping[str, str]) -> Path | None`, CLI `corrida-worker.py registry validate|list --registry PATH`, and compatibility check `corrida-worker.py record validate --record PATH`.

- [ ] **Step 1: Write the valid registry and red/green contract fixtures**

```json
{
  "schema": "workers.v1",
  "max_external_sessions": 4,
  "workers": [{
    "id": "claude",
    "harness": "claude-code",
    "binary": "claude",
    "provider": "anthropic",
    "model": "router",
    "capabilities": ["read", "write", "review"],
    "task_types": ["general", "backend", "frontend", "review"],
    "permission_modes": {"write": "acceptEdits", "review": "plan"},
    "version": "2.1.278",
    "commands": {
      "health": ["claude", "--version"],
      "start:write": ["claude", "--permission-mode", "acceptEdits"],
      "start:review": ["claude", "--permission-mode", "plan"],
      "resume:write": ["claude", "--resume", "{session_id}", "--permission-mode", "acceptEdits"],
      "resume:review": ["claude", "--resume", "{session_id}", "--permission-mode", "plan"],
      "stop": ["tmux-stop", "{session_name}"]
    },
    "quota_patterns": ["usage limit", "rate limit"],
    "auth_patterns": ["login required", "authentication failed"],
    "blocked_patterns": ["permission denied"],
    "transcript": {"kind": "tmux-pane"}
  }]
}
```

The production file repeats that closed shape for `codex`, `zcode`, `kimi`, `cursor`, and `grok`. Command values are argv arrays, never shell strings. Every worker with both `write` and `review` capabilities has explicit `start:<role>` and `resume:<role>` argv plus a `permission_modes` entry for each role. Validation rejects a missing role command or permission. It permits only the closed placeholders `{session_id}`, `{session_name}`, `{worktree}`, and `{brief}`. The measured write modes are Claude `--permission-mode acceptEdits`, Codex `--sandbox workspace-write`, ZCode `--mode edit`, Kimi `--auto`, Cursor `--auto-review --sandbox enabled --trust --workspace {worktree}`, and Grok with repo-scoped `--allow` rules. Review commands use the read-only modes exposed by their CLI, including Cursor `--mode plan`, and never inherit the writer's permission argv.

- [ ] **Step 2: Write the failing registry test**

```bash
python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/valid.json \
  | grep -qx 'VALID workers.v1 1'
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-command.json 2>&1); then
  fail "accepted a shell-bearing binary"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid command' || fail "wrong invalid-command diagnostic: $out"
if out=$(python3 scripts/mac/corrida-worker.py registry validate --registry scripts/tests/fixtures/workers/invalid-pattern.json 2>&1); then
  fail "accepted an empty or control-bearing pattern"
fi
printf '%s\n' "$out" | grep -qx 'ERROR invalid pattern' || fail "wrong invalid-pattern diagnostic: $out"
```

- [ ] **Step 3: Run the focused test and confirm the missing CLI failure**

Run: `bash scripts/tests/test-worker-registry.sh`

Expected: FAIL because `scripts/mac/corrida-worker.py` does not exist.

- [ ] **Step 4: Implement immutable registry types and validation**

```python
@dataclass(frozen=True)
class Worker:
    id: str
    harness: str
    binary: str
    provider: str
    model: str
    capabilities: tuple[str, ...]
    task_types: tuple[str, ...]
    permission_modes: Mapping[str, str]
    version: str
    commands: Mapping[str, tuple[str, ...]]
    quota_patterns: tuple[str, ...]
    auth_patterns: tuple[str, ...]
    blocked_patterns: tuple[str, ...]
    transcript_kind: str

def resolve_binary(worker: Worker, env: Mapping[str, str]) -> Path | None:
    override = env.get(f"CORRIDA_WORKER_BIN_{worker.id.upper()}")
    candidate = override or shutil.which(worker.binary)
    return Path(candidate).resolve() if candidate else None
```

Reject unknown top-level and worker keys, duplicate IDs, non-ASCII identifiers, binaries containing whitespace or shell metacharacters, command arrays with unknown placeholders or shell operators, empty/control-bearing patterns, absolute transcript paths, missing required capabilities, and any session limit other than `4`.

- [ ] **Step 5: Extend the existing `corrida.v2` contract compatibly**

Extend `docs/spec/corrida.v2.md` with optional `workers_registry`, `automatic_routing`, `lanes`, `effects`, `evidence`, `outcome`, and `authorization_ref`. Preserve `seguimiento_global:true`, absence of `cron_vigia_id`, reading existing v1/v2 records, and the global reporting lifecycle. Add `scripts/tests/fixtures/corrida/v2-existing-without-workers.json`, which omits every new field, and `scripts/tests/fixtures/corrida/v2-native-workers.json`, which exercises the enriched fields and points `authorization_ref` at the checked-in Phase 14 preapproval. The field remains optional for legacy and read-only records; Task 7 requires it, resolves it against the versioned preapproval table, and fails closed when it is missing, unknown, unapproved, or out of scope before automatic merge. Do not create another schema named v2 or copy the old per-run cron.

Add these compatibility assertions to `scripts/tests/test-worker-registry.sh`:

```bash
python3 scripts/mac/corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-existing-without-workers.json \
  | grep -qx 'VALID corrida.v2 legacy'
python3 scripts/mac/corrida-worker.py record validate --record scripts/tests/fixtures/corrida/v2-native-workers.json \
  | grep -qx 'VALID corrida.v2 native-workers'
```

- [ ] **Step 6: Run the focused test and syntax checks**

Run: `bash scripts/tests/test-worker-registry.sh && python3 -m py_compile scripts/mac/corrida-worker.py scripts/mac/corrida_worker/*.py`

Expected: PASS, `VALID workers.v1 6` for the production registry, and both `corrida.v2` compatibility fixtures accepted with their exact diagnostics.

- [ ] **Step 7: Commit**

```bash
git add scripts/mac/workers.v1.json scripts/mac/corrida-worker.py scripts/mac/corrida_worker scripts/tests/fixtures/workers scripts/tests/fixtures/corrida/v2-existing-without-workers.json scripts/tests/fixtures/corrida/v2-native-workers.json scripts/tests/test-worker-registry.sh docs/spec/corrida.v2.md
git commit -m "feat: add native worker registry"
```

### Task 2: Deterministic health results and worker selection

**Files:**
- Create: `scripts/mac/corrida_worker/selector.py`
- Create: `scripts/tests/fixtures/workers/selection.json`
- Create: `scripts/tests/fixtures/workers/request-review.json`
- Create: `scripts/tests/fixtures/workers/selection-state.json`
- Create: `scripts/tests/test-worker-selector.sh`
- Modify: `scripts/mac/corrida-worker.py`
- Modify: `scripts/mac/corrida/preflight.sh`

**Interfaces:**
- Consumes: `Registry`, requirement JSON, closed historical outcomes, and normalized health records.
- Produces: `select_worker(registry, request, health, history, active) -> SelectionDecision` and CLI `health probe` plus `select` whose stdout is one JSON object.

- [ ] **Step 1: Write the failing selection matrix**

```bash
decision=$(python3 scripts/mac/corrida-worker.py select \
  --registry scripts/tests/fixtures/workers/selection.json \
  --request scripts/tests/fixtures/workers/request-review.json \
  --state scripts/tests/fixtures/workers/selection-state.json)
[ "$(printf '%s' "$decision" | json_get winner)" = "codex" ] || fail "unstable winner"
printf '%s' "$decision" | grep -q 'unauthenticated' || fail "auth discard not recorded"
```

Cover absent executable, `limited`, `unauthenticated`, missing capability, repo prohibition, four active sessions, occupied worktree, implementer-as-only-reviewer, reuse of the previous round's reviewer, closed-history-only scoring, and a score tie resolved by registry order.

Also exclude every effective author of a handed-off change from its independent review and persist attempted/discarded candidates for the incident. Selection must never cycle through an already exhausted account. Unknown quota is not proof of exhaustion; use an explicit bounded failure observation. Preserve the existing score-based selection rather than introducing a second ranked router in SummonAIKit.

- [ ] **Step 2: Run the focused test and confirm selection is unavailable**

Run: `bash scripts/tests/test-worker-selector.sh`

Expected: FAIL with an unknown `select` subcommand.

- [ ] **Step 3: Implement hard filters and integer scoring**

```python
WEIGHTS = {"affinity": 40, "history": 25, "availability": 15, "quota": 10, "diversity": 10}

def select_worker(registry, request, health, history, active):
    candidates = []
    discarded = []
    for order, worker in enumerate(registry.workers):
        reasons = hard_filter_reasons(worker, request, health, active)
        if reasons:
            discarded.append({"worker": worker.id, "reasons": reasons})
            continue
        parts = score_parts(worker, request, health, closed_history(history), active)
        candidates.append((sum(parts.values()), -order, worker, parts))
    if not candidates:
        return SelectionDecision(None, (), tuple(discarded), "no-compatible-worker")
    score, _, winner, parts = max(candidates)
    return SelectionDecision(winner.id, tuple(sorted(parts.items())), tuple(discarded), "selected")
```

Use integers only. Never include free-form model output in `score_parts`.

- [ ] **Step 4: Add bounded health probes to preflight**

`corrida_preflight` calls `corrida-worker.py health probe` once per enabled worker with a per-process timeout, records `available|limited|unauthenticated|broken`, and prints `NO APTO` only when no compatible worker remains. A single limited worker is a recorded fallback, not a global failure.

- [ ] **Step 5: Run focused selector and preflight tests**

Run: `bash scripts/tests/test-worker-selector.sh && bash scripts/tests/test-corrida-preflight.sh`

Expected: PASS; running the same fixture 20 times yields byte-identical JSON.

- [ ] **Step 6: Commit**

```bash
git add scripts/mac/corrida_worker/selector.py scripts/mac/corrida-worker.py scripts/mac/corrida/preflight.sh scripts/tests/fixtures/workers scripts/tests/test-worker-selector.sh scripts/tests/test-corrida-preflight.sh
git commit -m "feat: select native workers deterministically"
```

### Task 3: One adapter contract for six native CLIs

**Files:**
- Create: `scripts/mac/corrida/adaptador.sh`
- Create: `scripts/tests/fixtures/harness/fake-native-cli.sh`
- Create: `scripts/tests/test-native-harness-adapters.sh`
- Modify: `scripts/mac/cli-modos.tsv`
- Modify: `scripts/mac/corrida.sh`
- Modify: `scripts/mac/corrida/lanzar-sesion.sh`
- Modify: `scripts/mac/corrida/lib.sh`

**Interfaces:**
- Consumes: registry worker ID, run ID, lane ID, persisted lane role (`write|review`), worktree, brief file, and named tmux session.
- Produces: `corrida.sh adaptador <health|start|deliver|inspect|resume|stop> ...` with the exact normalized statuses from the spec.

- [ ] **Step 1: Write a table-driven failing contract test for all six workers**

```bash
for worker in claude codex zcode kimi cursor grok; do
  got=$(FAKE_HARNESS_MODE=complete bash scripts/mac/corrida.sh adaptador inspect run-1 lane-1 "$worker" "ses-$worker")
  [ "$got" = complete ] || fail "$worker inspect: $got"
done
```

For every worker exercise both `write` and `review` start/resume argv, accepted delivery, swallowed Enter, running, waiting, complete, failed, quota, expired authentication, stop, and already-stopped. The fake CLI records argv separately so the test proves the adapter invoked the intended native binary and role-specific permission mode. A silence fixture remains `running` until `inspect` reads the pane; silence alone can never become `complete`.

- [ ] **Step 2: Run the focused test and confirm the subcommand is absent**

Run: `bash scripts/tests/test-native-harness-adapters.sh`

Expected: FAIL with `subcomando desconocido: adaptador`.

- [ ] **Step 3: Implement the normalized shell boundary without `eval`**

```bash
corrida_adaptador() {
  local accion="$1" id="$2" carril="$3" worker="$4" sesion="$5"
  shift 5
  case "$accion" in
    health)  adaptador_health "$worker" ;;
    start)   adaptador_start "$id" "$carril" "$worker" "$sesion" "$@" ;;
    deliver) adaptador_deliver "$sesion" "$@" ;;
    inspect) adaptador_inspect "$worker" "$sesion" ;;
    resume)  adaptador_resume "$worker" "$sesion" ;;
    stop)    adaptador_stop "$sesion" ;;
    *) echo "adaptador: accion invalida: $accion" >&2; return 2 ;;
  esac
}
```

Build argv from closed `case` branches. Do not concatenate registry text into a shell command. Replace obsolete `glm` and `kimi-claude` rows with measured `zcode` and `kimi` rows while preserving other legacy tokens used outside automatic routing.

- [ ] **Step 4: Make session registration precede delivery**

Split `lanzar-sesion` into create, mark/register, and deliver phases. Persist `worker`, `harness`, `provider`, `reported_model`, and `session` before the first `send-keys`; if delivery fails, persist `failed` and stop the session rather than deleting its history.

- [ ] **Step 5: Run adapter and existing session tests**

Run: `bash scripts/tests/test-native-harness-adapters.sh && bash scripts/tests/test-corrida-nucleo.sh && bash scripts/tests/test-cli-modos.sh`

Expected: PASS, including the existing two-Enter failure discriminator.

- [ ] **Step 6: Commit**

```bash
git add scripts/mac/corrida/adaptador.sh scripts/mac/corrida.sh scripts/mac/corrida/lanzar-sesion.sh scripts/mac/corrida/lib.sh scripts/mac/cli-modos.tsv scripts/tests/fixtures/harness scripts/tests/test-native-harness-adapters.sh scripts/tests/test-corrida-nucleo.sh scripts/tests/test-cli-modos.sh
git commit -m "feat: normalize native harness lifecycle"
```

### Task 4: Worktree ownership, capacity reservation, and visible Terminal

**Files:**
- Create: `scripts/mac/corrida/preparar-carril.sh`
- Create: `scripts/mac/corrida/mostrar-terminal.sh`
- Create: `scripts/tests/test-corrida-worktrees.sh`
- Create: `scripts/tests/test-corrida-terminal-visible.sh`
- Modify: `scripts/mac/corrida.sh`
- Modify: `scripts/mac/corrida/abrir.sh`
- Modify: `scripts/mac/corrida/lib.sh`

**Interfaces:**
- Consumes: `preparar-carril RUN LANE REPO [--read-only]` and `mostrar-terminal RUN LANE`.
- Produces: an atomic lane reservation with `branch`, `worktree`, `base_remote_sha`, `owner`, `mode`, and visibility `{state, attach_command}`.

- [ ] **Step 1: Write failing ownership and race tests**

Create a bare remote plus five simultaneous `preparar-carril` processes. Assert exactly four reservations succeed, every writer has a distinct canonical worktree, every base equals the fetched `origin/main`, a duplicate worktree is rejected, and `git log origin/main..HEAD` starts empty.

Run: `bash scripts/tests/test-corrida-worktrees.sh`

Expected: FAIL because `preparar-carril` is unknown.

- [ ] **Step 2: Implement reservation under the existing run lock**

```bash
if ! lock_tomar "$reg"; then return 1; fi
activos="$(registro_contar_harnesses_activos "$reg")"
[ "$activos" -lt 4 ] || { lock_soltar "$reg"; echo "capacidad agotada" >&2; return 1; }
registro_worktree_libre "$reg" "$canon" || { lock_soltar "$reg"; return 1; }
registro_reservar_carril "$reg" "$lane" "$canon" "$rama" "$base_sha" "$modo"
lock_soltar "$reg"
```

Fetch before resolving the default branch. Create the branch with `git worktree add -b "$rama" "$path" "origin/$default"`. On creation failure, reacquire the lock and release only the matching reservation token.

- [ ] **Step 3: Write the failing visibility degradation test**

Stub `osascript` success and failure with session `ses-codex-run1`. Success must set `visibility.state == "visible"`. Failure must leave the worker active, set state `degraded`, and store exactly `/opt/homebrew/bin/tmux attach -t =ses-codex-run1`.

Run: `bash scripts/tests/test-corrida-terminal-visible.sh`

Expected: FAIL because `mostrar-terminal` is unknown.

- [ ] **Step 4: Implement Terminal opening through fixed AppleScript input**

Pass the already validated tmux session name as one argv value to a checked-in AppleScript or `osascript -e` program. Never interpolate a brief, repo path, transcript, or worker response into AppleScript. Treat automation denial as degraded visibility, not a worker failure.

- [ ] **Step 5: Run both focused tests plus core lifecycle**

Run: `bash scripts/tests/test-corrida-worktrees.sh && bash scripts/tests/test-corrida-terminal-visible.sh && bash scripts/tests/test-corrida-nucleo.sh`

Expected: PASS with four winners in the capacity race and no shared worktree.

- [ ] **Step 6: Commit**

```bash
git add scripts/mac/corrida/preparar-carril.sh scripts/mac/corrida/mostrar-terminal.sh scripts/mac/corrida.sh scripts/mac/corrida/abrir.sh scripts/mac/corrida/lib.sh scripts/tests/test-corrida-worktrees.sh scripts/tests/test-corrida-terminal-visible.sh
git commit -m "feat: isolate workers and expose terminals"
```

### Task 5: Persistent reducer and idempotent reconciliation

**Files:**
- Create: `scripts/mac/corrida_worker/state.py`
- Create: `scripts/mac/corrida_worker/reconcile.py`
- Create: `scripts/mac/corrida/reconciliar.sh`
- Create: `scripts/tests/fixtures/reconcile/`
- Create: `scripts/tests/test-corrida-reconcile.sh`
- Modify: `scripts/mac/corrida-worker.py`
- Modify: `scripts/mac/corrida.sh`
- Modify: `scripts/mac/corrida/lib.sh`

**Interfaces:**
- Consumes: the run registry plus read-only observations of tmux, git/worktrees, remote branches, GitHub PRs, merge state, deployed SHA, and canary evidence.
- Produces: `reduce_state(state: RunState, event: Event) -> RunState`, `reconcile(state, observations) -> tuple[RunState, tuple[PlannedEffect, ...]]`, and `corrida.sh reconciliar RUN [--observations FILE]`.

- [ ] **Step 1: Write failing reducer and crash-window fixtures**

Cover duplicate event IDs, vanished session with commits, push already present, PR already open, merge already applied, deploy partially recorded, and a failed worker that resumes once before a handoff. Replaying every fixture twice must yield byte-identical normalized state and no second external effect.

Add handoff cases: explicit quota/auth/executable failure skips same-account resume; ordinary crash resumes once; silent but working process is not replaced; predecessor or child still writing prevents successor launch; dirty diff and commits survive; candidate exhaustion stops only its lane; repeated reconciliation launches the successor once. Check the handoff event and session/watch ownership. A failed test never becomes approval through fallback. Include Phase 23 compatibility: replacement may implement the fix, but a required Muse/Claude live measurement remains pending until that host runs it. Task 6's rewrite of the loop must preserve §9's availability handoff and these host-specific measurement exceptions.

Run: `bash scripts/tests/test-corrida-reconcile.sh`

Expected: FAIL because reconciliation does not exist.

- [ ] **Step 2: Implement append-only events and atomic snapshots**

```python
def reduce_state(state: RunState, event: Event) -> RunState:
    if event.id in state.applied_event_ids:
        return state
    next_state = apply_event(state, event)
    return replace(next_state, applied_event_ids=state.applied_event_ids | {event.id})

def write_atomic(path: Path, payload: Mapping[str, object]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
```

Store event intent before an external effect and record its observed completion afterward. A pending intent always triggers observation before retry.

- [ ] **Step 3: Implement ordered reconciliation**

Reconcile in this order: registry, tmux, worktree and HEAD, remote branch, PR and head SHA, evidence, merge, deployed SHA, canary. Return planned effects but execute none from Python. The Bash wrapper executes one closed effect, records its result, and invokes reconciliation again.

- [ ] **Step 4: Add transcript and evidence archival to close**

Before stopping tmux, write the lane directory `archive/lane-api/` containing `transcript.txt`, `selection.json`, `events.jsonl`, and `evidence.json` under the run state directory with mode 600. The implementation substitutes the validated lane ID for `lane-api`. Redact configured token patterns and control characters. Only after successful archival call the adapter `stop`; a retry recognizes an already stopped session.

- [ ] **Step 5: Run reconciliation and close tests**

Run: `bash scripts/tests/test-corrida-reconcile.sh && bash scripts/tests/test-corrida-nucleo.sh`

Expected: PASS; each crash fixture converges in two invocations and produces no duplicate effect record.

- [ ] **Step 6: Commit**

```bash
git add scripts/mac/corrida_worker/state.py scripts/mac/corrida_worker/reconcile.py scripts/mac/corrida-worker.py scripts/mac/corrida/reconciliar.sh scripts/mac/corrida.sh scripts/mac/corrida/lib.sh scripts/mac/corrida/cerrar.sh scripts/tests/fixtures/reconcile scripts/tests/test-corrida-reconcile.sh scripts/tests/test-corrida-nucleo.sh
git commit -m "feat: reconcile autonomous runs after restart"
```

### Task 6: Persistent PR receipt and review, CI, and CodeRabbit state machine

**Files:**
- Create: `scripts/mac/corrida_worker/gates.py`
- Create: `scripts/mac/corrida/compuerta.sh`
- Create: `scripts/tests/fixtures/gates/`
- Create: `scripts/tests/test-corrida-gates.sh`
- Modify: `scripts/mac/corrida-worker.py`
- Modify: `scripts/mac/corrida.sh`
- Modify: `docs/runbooks/loop-autopilot.md`
- Modify: `scripts/tests/test-loop-autopilot.sh`

**Interfaces:**
- Consumes: `compuerta RUN LANE <cross-review|push-pr|ci|coderabbit|merge|deploy|canary|rollback> --sha SHA --evidence FILE`.
- Produces: a read-only evidence projection with source URL, repo, PR, reviewed SHA, result and availability; it never replaces the kit receipt. `gate_decision(state, action, sha)` rereads the authoritative PR and installed kit contract.

- [ ] **Step 1: Write failing behavioral gate tests**

Fixtures deny merge for missing/revoked receipt, wrong repo/PR/head, CI red/missing/stale, author acting as independent reviewer, and an open reproducible blocker. They allow a valid current-head receipt plus current green CI with CodeRabbit unavailable and declared under the policy below. They reject treating bot unavailability as approval. A resumed lead uses the existing receipt without rerunning the reviewer. A nonblocking residual does not reopen review. A fix reviews only the delta from the previous reviewed SHA, with another reviewer; the same blocker twice stops the lane. Close without live acceptance or verified rollback is rejected.

- [ ] **Step 2: Run the focused test**

Run: `bash scripts/tests/test-corrida-gates.sh`
Expected before implementation: FAIL because the projection and gate command are absent.

- [ ] **Step 3: Consume the existing delivery contract**

Read the installed kit's `tools/lib/entrega_contract.sh` and `tools/saikit-merge.sh`; use their supported receipt/merge interface. Keep implementer, verifier and reviewer independence for code. Editorial/ledger changes use the kit fast class. Store source references in the run, not a second approval or private signature. No hook-session lookup, `veredicto_sha256`, signing-model capability or re-signing after handoff.

CI applies to the current PR head. A code change needs review of its delta and CI for the resulting SHA. A mechanical rebase with identical reviewed content records the old/new SHA and verified empty content difference, then uses the kit's receipt update policy; it does not cause another full review. Squash/deploy map reviewed PR head to the actual merge commit and deployed artifact. Record both SHAs rather than requiring their hashes to be equal.

- [ ] **Step 4: Align the existing loop once**

Preserve the delivery-without-seal contract already installed by Blocks A/C. First code cross-review precedes push/PR, then CodeRabbit once. Keep the PR open while correcting locally, delta-review, then push to the same PR. Only reproducible blockers reopen this cycle. Record nonblocking residuals in the tracker and PR. Preserve availability handoff and host-specific measurement rules. Do not rewrite unrelated loop sections or demand a full cross-review for editorial closure.

- [ ] **Step 5: Run the focused tests**

Run: `bash scripts/tests/test-corrida-gates.sh && bash scripts/tests/test-loop-autopilot.sh`
Expected: PASS for persistent receipts, current CI, bot-unavailability disclosure, independent review, bounded handoff and existing global-clock behavior.

- [ ] **Step 6: Commit**

```bash
git add scripts/mac/corrida_worker/gates.py scripts/mac/corrida-worker.py scripts/mac/corrida/compuerta.sh scripts/mac/corrida.sh scripts/tests/fixtures/gates scripts/tests/test-corrida-gates.sh docs/runbooks/loop-autopilot.md scripts/tests/test-loop-autopilot.sh
git commit -m "feat: evidence autonomous quality gates by sha"
```

### Task 7: Autonomous merge authority without granting `main` execution rights

**Files:**
- Modify: `agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md`
- Modify: `agents/implementer/agent/workshop-skills/saikit-cierre-pr/MERGE-POR-ORDEN.md`
- Modify: `agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md`
- Modify: `agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/MERGE-POR-ORDEN.md`
- Modify: `agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md`
- Create: `scripts/tests/test-autonomous-merge-authority.sh`
- Modify: `scripts/tests/test-saikit-cierre-pr-merge-owner.sh`
- Modify: `scripts/tests/test-merge-allowlist-cierre-pr.sh`

**Interfaces:**
- Consumes: either a dated owner order or a validated `corrida.v2` record with `authorization_ref` pointing to an approved, versioned phase preapproval, a valid current-head kit receipt and current CI, and `automatic_routing.enabled=true`.
- Produces: one merge request assigned to exactly one `implementer|ingenieria`, pinned by `expectedHeadOid`; `main` receives only the result.

- [ ] **Step 1: Write the failing authority tests**

Assert that `main`, `reviewer`, and a malformed run record cannot merge; a missing, unknown, unapproved, or out-of-scope `authorization_ref` fails closed; `implementer` and `ingenieria` can follow the documented API route only when the versioned preapproval, kit receipt and current CI validate; the legacy dated owner order still works; and both copies of `saikit-cierre-pr` remain byte-identical.

Run: `bash scripts/tests/test-autonomous-merge-authority.sh`

Expected: FAIL because the skill recognizes only a dated textual order.

- [ ] **Step 2: Add the second, closed authority branch to both skill copies**

The branch reads the run record, resolves `authorization_ref` to the checked-in preapproval table, verifies that the requested repo/branch/operation is in scope, invokes the Task 6 `corrida.sh compuerta RUN LANE merge --sha SHA --evidence FILE` projection and delegates to the installed kit merge entrypoint. The kit verifies the current receipt, CI and `headRefOid`, and pins its GitHub mutation with `expectedHeadOid`. A receipt never creates authorization by itself. No alternate direct GraphQL bypass is introduced. Record intent before delegation and reread `state,mergedAt,mergeCommit` after every response, including `UNPROCESSABLE`.

- [ ] **Step 3: Keep the hard allowlist unchanged**

Do not add `main` to `MERGE_AGENT_ALLOWLIST`. Extend the tests so any extra allowlist entry fails. Update `saikit-merge-route` to say that `main` chooses the closer and passes the verified run path, but the closer alone invokes the merge route.

- [ ] **Step 4: Run all focused merge-contract tests**

Run: `bash scripts/tests/test-autonomous-merge-authority.sh && bash scripts/tests/test-saikit-cierre-pr-merge-owner.sh && bash scripts/tests/test-merge-allowlist-cierre-pr.sh && bash scripts/tests/test-cierre-pr-merge-comando.sh`

Expected: PASS and recursive equality between the two `saikit-cierre-pr` folders.

- [ ] **Step 5: Commit**

```bash
git add agents/implementer/agent/workshop-skills/saikit-cierre-pr agents/ingenieria/agent/workshop-skills/saikit-cierre-pr agents/main/agent/workshop-skills/saikit-merge-route/SKILL.md scripts/tests/test-autonomous-merge-authority.sh scripts/tests/test-saikit-cierre-pr-merge-owner.sh scripts/tests/test-merge-allowlist-cierre-pr.sh
git commit -m "feat: authorize verified autonomous merges"
```

### Task 8: Extend the existing dashboard with worker and gate state

**Files:**
- Modify: `tablero-runbook/contrato.ts`
- Modify: `tablero-runbook/render.ts`
- Modify: `tablero-runbook/contrato-v2.test.ts`
- Modify: `tablero-runbook/render.test.ts`
- Create: `tablero-runbook/fixtures/v2-native-workers.json`
- Create: `tablero-runbook/fixtures/v2-native-workers-invalid.json`
- Modify: `docs/spec/runbook-progress.v2.md`

**Interfaces:**
- Consumes: optional `Carril.worker`, `Carril.execution`, `Carril.evidence`, and `Carril.delivery` blocks written by `main`.
- Produces: strict validation and escaped rendering without any command-execution endpoint.

- [ ] **Step 1: Define the additive TypeScript shapes in the failing fixture tests**

```ts
type WorkerView = {
  id: string;
  harness: string;
  provider: string;
  model: string;
  health: "available" | "limited" | "unauthenticated" | "broken";
};
type ExecutionView = {
  worktree: string;
  session: string;
  visibility: "visible" | "detached" | "degraded";
  attach_command: string | null;
  started_at: string;
};
type EvidenceView = { status: "pending" | "clean" | "blocked" | "unknown"; sha: string | null };
type DeliveryView = { merge: EvidenceView; deploy: EvidenceView; canary: EvidenceView; rollback: EvidenceView };
```

The valid fixtures collectively cover pending, working, limited, waiting, cross-review, CI, CodeRabbit, deploy, reverted, and finished. The invalid fixture includes a fifth active harness, evidence applied to an unrelated PR head, an attach command for the wrong session, control characters, and a token-shaped value.

- [ ] **Step 2: Run the focused contract test and confirm rejection is not implemented**

Run: `cd tablero-runbook && node --test contrato-v2.test.ts`

Expected: FAIL because worker fields are not validated and the invalid fixture passes.

- [ ] **Step 3: Implement validation and derived attention state**

Validate all enum values and text limits, at most four active external sessions, exact attach command derivation from the validated session, and source-appropriate evidence SHAs, including the PR-head to merge-commit mapping. Reject secret-shaped values in display fields. Derive attention for `unauthenticated`, `broken`, stale evidence, failed rollback, and unresolved required evidence; disclosed CodeRabbit unavailability alone does not request operator attention.

- [ ] **Step 4: Write and run failing render assertions**

Assert visible text for worker, harness, provider/model, repo/branch/worktree, tmux session, elapsed time, last event, health, cross-review/CI/CodeRabbit SHA, PR/merge/deploy/canary, and visibility. Assert HTML escaping, 300-character truncation, no token fixture substring, and no button/form/script capable of executing the attach command.

Run: `cd tablero-runbook && node --test render.test.ts`

Expected: FAIL because the worker columns and gate cards are absent.

- [ ] **Step 5: Implement compact lane details in `render.ts`**

Render the existing table summary plus a `<details>` block per lane. Use `esc` and `truncar` for every external value. Render `attach_command` only inside `<code>` when visibility is degraded.

- [ ] **Step 6: Run the focused dashboard suite**

Run: `cd tablero-runbook && node --test contrato-v2.test.ts render.test.ts index.test.ts`

Expected: PASS with byte-identical RPC and HTTP HTML for the same document.

- [ ] **Step 7: Commit**

```bash
git add tablero-runbook/contrato.ts tablero-runbook/render.ts tablero-runbook/contrato-v2.test.ts tablero-runbook/render.test.ts tablero-runbook/fixtures/v2-native-workers.json tablero-runbook/fixtures/v2-native-workers-invalid.json docs/spec/runbook-progress.v2.md
git commit -m "feat: show native workers in run dashboard"
```

### Task 9: Teach `main` to direct native runs and preserve the legacy fallback

**Files:**
- Create: `agents/main/agent/workshop-skills/native-harness-orchestration/SKILL.md`
- Modify: `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md`
- Create: `scripts/tests/test-native-harness-orchestration-skill.sh`
- Modify: `scripts/mac/install-agent-tools.sh`
- Modify: `scripts/tests/test-hooks-apuntan-a-archivos-trackeados.sh`

**Interfaces:**
- Consumes: one engineering request, repo policy, registry, health, state history, and `CORRIDA_NATIVE_ROUTING=report|execute|off`.
- Produces: classified lanes, recorded selector decisions, adapter invocations, dashboard updates, and delegation of privileged effects to authorized agents.

- [ ] **Step 1: Write the failing skill contract test**

Assert that the skill requires reconciliation before effects, records the selector explanation, caps at four, never changes harness silently, never sends secrets in briefs, never lets `main` merge/deploy, uses local cross-review before first push, handles the CodeRabbit correction loop on the same PR, verifies live canary, and routes `off` to the existing `agent-dispatch` chain.

Assert that “never changes harness silently” requires a recorded availability handoff under loop §9, not a prohibition on switching. Route quota/auth/launcher failures to the next compatible unattempted candidate and preserve host-specific measurements. The pre-install/manual route must remain usable by Phases 14 and 23 without invoking scripts that Task 9 has not yet installed.

Run: `bash scripts/tests/test-native-harness-orchestration-skill.sh`

Expected: FAIL because the skill is absent.

- [ ] **Step 2: Write the orchestration skill as an executable decision table**

Include exact commands for open, preflight, select, prepare lane, start/deliver, show terminal, inspect, reconcile, evidence, delegate merge/deploy, canary/rollback, archive, and close. Every effect step begins by reconciling and ends by writing its observation.

- [ ] **Step 3: Make `agent-dispatch` point to the new contract once**

Add one routing paragraph: native requests use `native-harness-orchestration`; `CORRIDA_NATIVE_ROUTING=off` or a failed staged-rollout gate uses the current chain. Do not copy the state machine into `agent-dispatch`.

- [ ] **Step 4: Install the new package and registry atomically**

Use the installer path recorded by the Phase 9 closure manifest. `scripts/mac/install-agent-tools.sh` is the preferred name; if Phase 9 delivered `scripts/mac/instalar-mac.sh`, update this task's file list, commands and tests to that path before implementation, without creating a second installer. Extend that installer to copy `corrida-worker.py`, the `corrida_worker` package, `workers.v1.json`, and every new `corrida/*.sh` beside the installed dispatcher. Verify hashes against tracked source and preserve executable bits only on entrypoints.

- [ ] **Step 5: Run focused skill and installer tests**

Run: `bash scripts/tests/test-native-harness-orchestration-skill.sh && bash scripts/tests/test-hooks-apuntan-a-archivos-trackeados.sh && bash scripts/tests/test-agent-dispatch-spawn.sh`

Expected: PASS, and the skill contains no absolute credential, destination, or user-specific worker binary path.

- [ ] **Step 6: Commit**

```bash
git add agents/main/agent/workshop-skills/native-harness-orchestration/SKILL.md agents/main/agent/workshop-skills/agent-dispatch/SKILL.md scripts/mac/install-agent-tools.sh scripts/tests/test-native-harness-orchestration-skill.sh scripts/tests/test-hooks-apuntan-a-archivos-trackeados.sh
git commit -m "feat: direct engineering work through native harnesses"
```

### Task 10: Staged real smokes, integral canary, and PR delivery

Execution order within this task: Steps 1–4 build the driver; Steps 6–10 validate and integrate only B4 via the kit; then install the merged artifact, run Step 5's real smokes and Steps 11–12's canary/user acceptance. Step 13 publishes the closure evidence. Never deploy the unmerged B4 branch or repeat B1–B3 reviews.

**Files:**
- Create: `scripts/mac/smoke-native-harnesses.sh`
- Create: `scripts/tests/test-smoke-native-harnesses.sh`
- Create: `docs/runbooks/native-harness-rollout.md`
- Modify: `Plans.md`

**Interfaces:**
- Consumes: a disposable remote, `CORRIDA_NATIVE_ROUTING=report|execute|off`, optional `--worker ID`, and local worker binary overrides.
- Produces: redacted JSON evidence per harness plus one end-to-end acceptance record containing selected worker, visible terminal result, local cross-review, PR, CI, CodeRabbit, merge, live SHA, and canary or rollback.

- [ ] **Step 1: Write a failing no-network smoke-driver test**

Stub every native CLI and assert that the driver creates a disposable repo from `origin/main`, delivers a minimal edit, observes transcript and completion, archives evidence, closes tmux, redacts token-shaped output, and returns nonzero if any requested worker is skipped.

Run: `bash scripts/tests/test-smoke-native-harnesses.sh`

Expected: FAIL because the smoke driver is absent.

- [ ] **Step 2: Implement the smoke driver with explicit worker selection**

The driver accepts `--worker claude|codex|zcode|kimi|cursor|grok|all`, calls the same production adapter, and writes one result object per worker. It never commits evidence containing the transcript; committed documentation records only version, outcome, duration, and archive path.

- [ ] **Step 3: Write the five-stage rollout runbook and kill-switch checks**

Stage 1 runs selection in report mode. Stage 2 attempts six disposable smokes and enables only the passed hosts under Step 5's acceptance rule. Stage 3 permits implementation and PR but denies merge/deploy. Stage 4 permits one low-risk end-to-end canary. Stage 5 enables general routing with four slots. Every stage documents its promotion evidence and the single command that returns to `CORRIDA_NATIVE_ROUTING=off`.

- [ ] **Step 4: Run the focused fake smoke test**

Run: `bash scripts/tests/test-smoke-native-harnesses.sh`

Expected: PASS with six result rows and no secrets in output.

- [ ] **Step 5: Run the six real disposable smokes**

Run: `bash scripts/mac/smoke-native-harnesses.sh --worker all --evidence-dir "$CORRIDA_STATE/native-smoke-20260919"`

Expected when all six are available: six `passed` results proving start, authentication, delivery, transcript, completion event, archive, and stop. A limited or unauthenticated harness is recorded as unavailable and disabled for live routing; continue other smokes. All six adapters must pass the fake contract. A partial rollout may enable only passed harnesses when at least two, including an independent reviewer, passed. The phase's six-host acceptance stays incomplete until the remaining real smokes run; unavailable is never passed. Continue independent work and record pending host measurements rather than waiting for quota renewal. A behavioral failure in a claimed-supported adapter is a blocker.

- [ ] **Step 6: Run all pre-commit hooks on the final local tree**

Commit B4's driver, its focal test and the rollout contract; this runs the configured hooks:

```bash
git add scripts/mac/smoke-native-harnesses.sh scripts/tests/test-smoke-native-harnesses.sh docs/runbooks/native-harness-rollout.md
git commit -m "feat: add native harness rollout driver"
```

Reuse hook success for the same tree. Never bypass a configured hook.

Expected: PASS. Fix failures and rerun the failing hook through the normal pre-commit command; never bypass it.

- [ ] **Step 7: Review B4 locally before its first push**

Run from the repository worktree:

```bash
/Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -RepoPath "$PWD"
```

Expected: no reproducible blocking finding. Fix all findings in one block. If a blocker exists, use a different reviewer for the correction delta with `-Desde "$SHA_VISTO"`; stop at the first round without blockers.

- [ ] **Step 8: Verify B4 branch purity, push, and open its PR**

```bash
git fetch origin
git log --oneline origin/main..HEAD
git diff --check origin/main...HEAD
git push -u origin HEAD
/opt/homebrew/bin/gh pr create --title "feat: orchestrate native coding harnesses" --body-file /tmp/native-harness-pr.md
```

Expected: the log contains only this task's commits. Rebase onto current `origin/main` before the PR if unrelated commits appear. The PR is opened ready for review, not as a draft.

- [ ] **Step 9: Use CI as the single normal-path full battery**

Run once: `/opt/homebrew/bin/gh pr checks`. If still pending, leave it running in CI and continue independent work; read the completion before any further poll. No blocking watch loop.

Expected: every required job passes on the PR head and their union is the full battery. Do not run the same full battery locally.

- [ ] **Step 10: Read CodeRabbit comments and exercise the correction contract if needed**

Run: `/opt/homebrew/bin/gh pr view --json headRefOid,reviews,comments,mergeStateStatus`

Expected: CodeRabbit completed on the current head without an open reproducible blocker, or its unavailability was declared under the global policy. If it reports a blocker, keep this PR open, fix locally without pushing, cross-review only `git diff "$SHA_VISTO"..HEAD`, then push to this same branch so CI and CodeRabbit rerun. Nonblocking findings become concrete `Plans.md` rows and are named in the PR. Once the kit's receipt and current CI validate, the authorized closer merges B4; install and verify that merged SHA before real smokes.

- [ ] **Step 11: Execute one low-risk integral canary through the new route**

Use a disposable or explicitly low-risk change. Record the request, selector decision, four-or-fewer sessions, visible/degraded terminal evidence, local review, PR, CI, CodeRabbit, merge SHA, deployed SHA, live observation, and cleanup. If the live check fails, run and verify the documented rollback before closing.

- [ ] **Step 12: Have the `usuario` agent run the acceptance path**

Give `usuario` only the original engineering request and the dashboard URL. Require it to confirm that the request starts a run, the selected worker and terminal state are understandable, the final live behavior is observable, and no source-code reading is needed. Store its pass/fail result in the run evidence; a failure returns to the owning task and does not become a documentation residual.

- [ ] **Step 13: Publish one final closure PR after live acceptance**

```bash
git add Plans.md docs/runbooks/native-harness-rollout.md
git commit -m "docs: record native harness rollout evidence"
```

Keep acceptance evidence and ledger closure in one docs PR on a fresh branch from `origin/main`. Use the installed fast review lane and actual CI policy; do not rerun code cross-review because documentation changed. Evidence for an unchanged deployed artifact remains valid. Run the phase closure check once after integration.

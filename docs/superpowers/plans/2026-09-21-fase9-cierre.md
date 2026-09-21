# Fase 9 Closure Implementation Plan

> **For agentic workers:** Execute this plan through `docs/runbooks/autopilot-fase9.md`. Do not restart completed lanes. Use focused tests while editing and the PR CI once for the final SHA.

**Goal:** Close Phase 9 from its current integrated state, recover PR #100, deliver the missing installer, bounded close, and user acceptance, then prove the seven live scenarios without restoring the obsolete per-session seal or the old five-minute heartbeat.

**Architecture:** Keep the global tmux watchdog as the only progress clock. Recover the existing documentation lane first, then implement installation/concurrency and user acceptance in isolated worktrees. Install only from integrated `origin/main`, run an accelerated live simulation with an injected clock, and finish with one evidence/ledger PR.

**Tech Stack:** Bash 3.2, tmux, launchd, OpenClaw CLI/RPC, GitHub CLI/Actions, Markdown, shell test harnesses.

**Spec:** `docs/superpowers/specs/2026-09-21-fase9-cierre-design.md`

**Plan metadata:** `team_validation_mode: subagent`. Operations review found that the Phase 9 tools were not installed and that loading `ai.goncloud.corrida-latido` would duplicate the global watchdog. QA required focused tests plus one final CI battery per PR and a time-injected 7/7 simulation. The skeptic review required recovering completed work instead of replaying the whole phase. This plan incorporates all three findings.

**Formatter baseline:** configured. Evidence: `.pre-commit-config.yaml`, `.github/workflows/quality.yml`, and `scripts/run-checks.sh`. Hooks remain mandatory; never use `--no-verify`.

## Global Constraints

- Fetch first. Every new branch starts from `origin/main`, not local `main`.
- PR #100 stays the owner of 9.7 and 9.13. Merge `origin/main` into its branch; do not rebase, force-push, or open a replacement PR.
- Already integrated work is evidence, not work to repeat: PRs #81, #97, #98, #104, and #110.
- Do not load `scripts/mac/ai.goncloud.corrida-latido.plist`. The global watchdog supplies the 30-minute progress update.
- A worker may be replaced only for quota, authentication, unavailable binary/provider, or launch failure. Preserve its branch, worktree, brief, and commits. A red test or review finding stays with the lane.
- Each lane runs only focused tests locally. Open its PR for the full battery once on the final SHA. Reuse CI evidence while that SHA is unchanged.
- Review each code lane once across the whole lane, then CodeRabbit once. Only a reproduced blocker opens a correction and delta-only cross-review with a different reviewer. The same blocker twice stops the lane.
- Nonblocking findings from lanes I and U join A.R2–A.R11, 9.17–9.18, and the future B/C findings in delivery-without-seal Block D. Recording is not implementation.
- Phase 14 implementation starts only after Phase 9 and Phase 15. Phase 23 remains independent.

## Review Focus

- No second progress scheduler, duplicate Telegram cadence, or old LaunchAgent activation.
- Installer behavior is idempotent, uses the invoking HOME/uid, and verifies exact installed blobs.
- Closing while launch holds the global lock is bounded and leaves neither an open run nor a borrowed mark.
- User evidence proves the public path without reading implementation artifacts.
- PR receipt `saikit-entrega.v1` is persistent in GitHub; no merge step depends on the reviewer session, host, cwd, or a seal.

### Task 1: Merge the planning contract (Q0)

**Files:**
- Add: `docs/superpowers/specs/2026-09-21-fase9-cierre-design.md`
- Add: `docs/superpowers/plans/2026-09-21-fase9-cierre.md`
- Replace: `docs/runbooks/autopilot-fase9.md`
- Modify: `docs/runbooks/base-openclaw.md`
- Modify: `docs/runbooks/loop-autopilot.md`
- Modify: `scripts/tests/test-loop-autopilot.sh`
- Modify: `scripts/tests/test-runbooks-no-contradicen-entorno.sh`
- Modify: `scripts/tests/test-lanzar-fase.sh`
- Modify: `Plans.md`

**Step 1: Run the focused documentation contracts**

```bash
bash scripts/tests/test-loop-autopilot.sh
bash scripts/tests/test-runbooks-no-contradicen-entorno.sh
bash scripts/tests/test-lanzar-fase.sh
bash scripts/runbook.sh 9
```

Expected: every test exits 0, and the last command prints the absolute Phase 9 runbook path.

**Step 2: Commit, push, and open one PR**

```bash
git diff --check
git log --oneline origin/main..HEAD
git add Plans.md docs/runbooks docs/superpowers scripts/lanzar-fase.sh scripts/tests
git commit -m "docs(fase9): replace stalled runbook with closure plan"
git push -u origin docs/fase9-cierre-runbook
gh pr create --title "docs(fase9): closure runbook from current state" --body-file /tmp/fase9-q0-body.md
```

Include added files in the same commit. Expected: `git log origin/main..HEAD` contains only this task's commit. Let the PR CI run the full battery once.

**Step 3: Prove the launcher without starting a worker**

```bash
bash scripts/lanzar-fase.sh 9 --rama docs/fase9-cierre-runbook --dry-run -- /Users/dn/.local/bin/muse --yolo
```

Expected: `LISTO` and no tmux session created. Once Q0 is integrated, Claw continues with Task 2.

### Task 2: Recover PR #100 and close 9.7/9.13 (lane D)

**Files:** keep the existing PR #100 file set; likely owners include:
- Modify: `docs/runbooks/loop-autopilot.md`
- Modify: `docs/agent-skills/autopilot-runbook/SKILL.md`
- Modify: `docs/runbooks/guia-del-vigia.md`
- Modify: `scripts/tests/test-tmux-activity-watch.sh`
- Modify: `scripts/run-checks.sh` only if the reproduced classification bug is there

**Step 1: Restore the existing lane, never duplicate it**

```bash
git fetch origin
git worktree add /Users/dn/dev/wt-f9-D fase9/docs
cd /Users/dn/dev/wt-f9-D
git merge origin/main
gh pr view 100 --repo gon0801/goncloud-openclaw --json state,isDraft,headRefOid,statusCheckRollup
```

Expected: PR #100 remains the one open PR for `fase9/docs`; conflicts are resolved only within its declared files.

**Step 2: Reproduce 9.13 before changing it**

```bash
for i in $(jot 20); do bash scripts/tests/test-tmux-activity-watch.sh || exit 1; done
bash scripts/run-checks.sh
```

Record the first failing command and its exit status in `.saikit/scratch/D/tdd.md`. A final `TODO VERDE` line with a nonzero runner result is still a reproduction.

**Step 3: Add the smallest discriminating regression**

Change the owner identified by Step 2. The regression must fail under the reproduced bad classification and pass when the runner reports the test's actual exit code. Do not hide the failure with retries.

**Step 4: Run focused tests and commit**

```bash
bash scripts/tests/test-tmux-activity-watch.sh
bash scripts/tests/test-skill-autopilot-runbook.sh
bash scripts/tests/test-loop-autopilot.sh
git diff --check
git commit -am "fix(9.13): make tmux watcher result deterministic"
```

Expected: focused tests exit 0. Push normally to PR #100, perform one cross-review, promote from draft, and let CodeRabbit and CI examine the final SHA once.

### Task 3: Implement 9.10 and 9.16 (lane I)

**Files:**
- Create: `scripts/mac/instalar-mac.sh`
- Create: `scripts/tests/test-instalar-mac.sh`
- Modify: `scripts/mac/corrida/cerrar.sh`
- Modify: `scripts/mac/corrida/lib.sh` only if the bounded lock helper belongs there
- Modify: `scripts/tests/test-corrida-nucleo.sh`
- Modify: `scripts/tests/test-corrida-marcas.sh` only for mark ownership assertions

**Step 1: Write failing installer tests**

Use a temporary HOME and injected uid. Assert dry-run writes nothing; install creates the current Phase 9 files with generated HOME/uid; a second install changes no bytes or mtimes; `--verificar` detects one modified file by name. Assert the old `ai.goncloud.corrida-latido` is neither copied nor loaded.

```bash
bash scripts/tests/test-instalar-mac.sh
```

Expected before implementation: nonzero. Save output in `.saikit/scratch/I/tdd.md`.

**Step 2: Implement the single installer**

Resolve sources relative to the script. Copy the corrida scripts, mode table, tmux shell/config, and global watchdog assets authorized by the runbook. Generate launchd content using the invoking HOME and uid. Support `--dry-run` and `--verificar`; keep repeated installation idempotent. Treat an absent optional source as a named result, not an abrupt partial install.

**Step 3: Write the failing bounded-close case**

In the existing tmux/lock doubles, pause `lanzar-sesion` after it owns the global mark lock and before it finishes delivery. Start `cerrar` concurrently. Assert it returns within the measured bound, closes the run, and leaves no session marked for it.

```bash
bash scripts/tests/test-corrida-nucleo.sh
```

Expected before the fix: nonzero on the new case.

**Step 4: Implement bounded convergence**

Make `cerrar` wait/retry only while ownership proves the in-flight launch belongs to the same run. Stop at a declared bound with a diagnostic. On success, converge to closed and unmarked without asking for a manual rerun.

**Step 5: Verify and commit by task**

```bash
bash scripts/tests/test-instalar-mac.sh
bash scripts/tests/test-corrida-nucleo.sh
bash scripts/tests/test-corrida-marcas.sh
git diff --check
git add scripts/mac/instalar-mac.sh scripts/tests/test-instalar-mac.sh
git commit -m "feat(9.10): install and verify Mac corrida tools"
git add scripts/mac/corrida scripts/tests/test-corrida-nucleo.sh scripts/tests/test-corrida-marcas.sh
git commit -m "fix(9.16): make close wait boundedly for launch"
```

Stage each task's files before its commit; do not use the two `-am` commands if they would mix ownership. Open one lane PR, run one cross-review, CodeRabbit once, and one full CI battery on the final SHA.

### Task 4: Implement 9.11 and 9.12 (lane U)

Start after lane D is integrated. It may share lane I's PR only if `git diff --name-only` proves disjoint ownership and both tasks retain separate commits/tests; otherwise create `fase9/usuario` from fresh `origin/main`.

**Files:**
- Create: `agents/usuario/agent/AGENTS.md`
- Create: `scripts/tests/test-agente-usuario.sh`
- Modify: `scripts/cierre-de-fase.sh`
- Modify: `scripts/tests/test-cierre-de-fase.sh`
- Modify: `docs/agent-skills/autopilot-runbook/SKILL.md`
- Modify: its focused skill contract test

**Step 1: Test the user contract red-first**

Fixtures cover: fulfilled promise gives `FUNCIONA` plus evidence; broken promise gives `NO FUNCIONA`; missing human route gives `NO PUDE PROBARLO`; planted diff/test files never appear in the report.

```bash
bash scripts/tests/test-agente-usuario.sh
```

Expected before implementation: nonzero.

**Step 2: Implement the read-only user agent**

The agent receives only an observable promise and the human entry path. It must not inspect the diff, tests, PR, or source, and cannot repair the product. Its output is exactly one of the three contractual lines plus evidence in `docs/evidence/usuario-<fase>-<date>.md`.

**Step 3: Test closure evidence red-first**

Add fixtures for promised+`FUNCIONA`, promised+missing evidence, promised+`NO FUNCIONA`, and a phase with no observable promises.

```bash
bash scripts/tests/test-cierre-de-fase.sh
```

Expected before implementation: the missing/negative cases are not yet discriminated.

**Step 4: Implement closure validation and the runbook slot**

Parse only explicit observable-promise lines. Require a matching `FUNCIONA` evidence entry. Name the exact row when red. When a phase has no promise, say that explicitly and pass that check. Add the promise/path slot to the canonical autopilot skill and its contract test.

**Step 5: Verify, commit, and review**

```bash
bash scripts/tests/test-agente-usuario.sh
bash scripts/tests/test-cierre-de-fase.sh
bash scripts/tests/test-skill-autopilot-runbook.sh
git diff --check
```

Commit 9.11 and 9.12 separately. Use the same review/CodeRabbit/CI policy as lane I.

### Task 5: Install the integrated SHA and run the accelerated 7/7 simulation

**Files:**
- Create: `docs/evidence/fase9-simulacro-<date>.md`
- Create: `docs/evidence/usuario-fase9-<date>.md`
- Update during closure only: `.saikit/progress/9.json`

**Step 1: Verify the source and create backups**

```bash
git fetch origin
git checkout --detach origin/main
bash scripts/mac/instalar-mac.sh --verificar || true
bash scripts/mac/instalar-mac.sh
bash scripts/mac/instalar-mac.sh --verificar
launchctl list | grep -F ai.goncloud.corrida-latido && exit 1 || true
pgrep -f 'bin/tmux-activity-watch.sh'
```

Expected: verification passes after install, the old heartbeat is not loaded, and the global watcher is alive. Preserve `.anterior` backups for every replaced installed file.

**Step 2: Run the seven cases with injected time**

Use a unique simulation id and `[SIMULACRO]` for every real Telegram message. Advance the injected clock rather than sleeping 10, 30, or 60 real minutes. Complete within ten wall-clock minutes:

1. real cheap CLI starts in noninteractive mode, receives the brief, and reports `LISTO`;
2. trust dialog is answered by policy in under one simulated minute;
3. command outside policy sends `NECESITO TU RESPUESTA` in under two simulated minutes;
4. 30 simulated minutes of silence emits progress;
5. dead worker is relaunched once;
6. dead lead is recovered from recorded state;
7. 60 simulated minutes without change emits the heartbeat/progress report.

Record event time, message time, Telegram id, observable, installed source SHA, and installed blobs. Every case must be `FUNCIONA`; an unknown required case keeps the phase open.

**Step 3: Reuse the same run for user acceptance**

Give `usuario` only the promise and its human route. Store its `FUNCIONA` line and evidence. Do not run a second simulation merely to create acceptance evidence.

### Task 6: Close the ledger once

**Files:**
- Modify: `Plans.md`
- Add: final `.saikit/progress/9.json`
- Add: final `.saikit/progress/9-sesiones.txt`
- Add: evidence from Task 5

**Step 1: Reconcile every Phase 9 row**

Use existing merge evidence for 9.1–9.6, 9.8, 9.14, and 9.15. Use the new PRs/evidence for 9.7, 9.9–9.13, and 9.16. Close 9.0 with measured unknowns. Keep 9.17–9.18 pending and point them to delivery-without-seal Block D; do not call them done.

**Step 2: Run the closure command as a loop over missing facts**

```bash
bash scripts/cierre-de-fase.sh 9
```

Expected final output: `VERDE: la fase 9 puede declararse cerrada`, exit 0. A red run is a precise to-do list, not permission to weaken the checker.

**Step 3: Open one docs/evidence closure PR**

Run focused ledger/doc checks, commit all Phase 9 closure records together, open one fast-lane PR, let CI validate its final SHA once, then integrate through the persistent receipt gate. Remove only Phase 9 watchdog marks after closure; do not stop the global watcher when other work remains.

## Block D handoff

After delivery-without-seal Blocks B and C finish, create one hardening phase with repository-separated lanes. Seed it with A.R2–A.R11 and Phase 9.17–9.18, then append every nonblocking B/C/I/U finding with reproduction and owner. Each repository keeps its own tests, review, CI, and PR. No item becomes complete merely by appearing in this list.

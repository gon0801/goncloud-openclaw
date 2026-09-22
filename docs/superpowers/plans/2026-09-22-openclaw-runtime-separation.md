# OpenClaw Windows Runtime Separation Implementation Plan

> **For Muse:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task in one writing lane. Stop at the authorization gates; do not merge or operate the Windows host.

**Goal:** Separate the versioned OpenClaw checkout from live Windows state, replace the unsafe repository sync, restore local semantic memory with Ollama, and provision the Windows node with isolated state without losing data.

**Architecture:** Keep `C:\Users\ehven\.openclaw` as runtime-owned state, deploy a closed positive manifest from `C:\Users\ehven\src\goncloud-openclaw`, and capture only allowlisted autonomous skill edits through reviewable PRs. Put portable policy in small PowerShell functions and JSON contracts, keep Windows effects behind explicit `-Apply` gates, and write a redacted JSON receipt plus write-ahead journal for every resumable transition. A detached Scheduled Task transaction owns any interval when the gateway is stopped and guarantees restart in `finally`; the implementation PR creates and tests the machinery, while a separately authorized engineering run performs the live cutover.

**Tech Stack:** Windows PowerShell 5.1, Bash test harness, Git/GitHub CLI, OpenClaw 2026.9.5 CLI, Windows Task Scheduler, Ollama HTTP API, JSON receipts, GitHub Actions on Ubuntu and Windows.

**Spec:** `docs/superpowers/specs/2026-09-22-openclaw-runtime-separation-design.md`; stable product contract: `docs/spec/00-project-spec.md`.

## Execution contract

Tasks 1–7 must not start until David merges this Q0 planning PR and `origin/main` contains this plan, its design, and the Phase 16 runbook. Authorization to merge Q0 does not authorize the implementation PR or any operation on Windows.

Muse implements and commits the versioned work in Tasks 1–7 sequentially on one branch created from a freshly fetched `origin/main`, then reports `LISTO <sha>`. It runs each named test red, implements the smallest behavior, then runs that test green. It may commit after every green task. Muse does not push or open the PR: the lead owns those external effects. Muse must not run the full suite locally; the final implementation PR supplies the complete three-shard CI evidence. Codex/root reviews the complete PR and groups all findings into one correction brief. Only a reproducible blocker opens a delta-only review with a different reviewer.

Task 8 is an engineering operation on the live Windows host. It starts only after the implementation PR has current green CI, Codex/root approval, merge authorization, merge receipt, and a separate `authorization_ref` for the operational window. “De corrido” means Muse proceeds through all versioned tasks without questions while their gates are green; it does not convert implementation authority into merge or server authority.

Before code, Muse records the output shapes—not secrets—of `openclaw backup --help`, `openclaw memory --help`, `openclaw node --help`, `openclaw nodes --help`, and `openclaw config --help` from OpenClaw 2026.9.5. Unsupported or ambiguous CLI syntax stops the affected task before any live mutation and produces one concise blocker report.

Q0 also aligns `docs/runbooks/loop-autopilot.md` §3 with the repository's Phase 15 quality policy: pre-PR work uses focused tests and mutation checks; the complete battery is consumed in PR CI for the candidate final head. A correction creates a new candidate head and invalidates the older CI evidence.

## Plan-time decisions

- `team_validation_mode: subagent`; Product, Architecture, Security, QA, and Skeptic perspectives were requested independently.
- Required: every task below, except the live portion of Task 8 until separately authorized.
- Recommended: retain a report-only mode, structured receipts, and reversible quarantine indefinitely through the acceptance window.
- Optional and deferred: deleting quarantine after seven days, moving the three workspace repos, enabling more node file commands, or choosing a remote embedding fallback.
- Rejected: reinstalling OpenClaw, relaxing Code Integrity, returning to blocked `llama.cpp`, sharing the gateway database with the node, Git inside live state, `git add -A` for the main repo, pushing directly to `main`, or deleting live data.
- Formatter baseline: pre-commit supplies the repository's whitespace/YAML/JSON checks; PowerShell uses parser and behavioral tests. Adding PSScriptAnalyzer or another formatter is outside this migration and is not a prerequisite.
- Memory lookup: no project memory store is configured; this plan uses the repository spec, design, runbooks, tests, and ledger as the decision record.

## Review focus

- A path containing `..`, an absolute path, reparse point, junction, or symlink must never escape the source or runtime roots.
- A crash after PR creation or after the first file replacement must reconcile from ledger/receipt state without duplicating a PR or broadening rollback.
- `SKILLS_PR` means pending review; only matching read-back after merge emits `SKILLS_DEPLOYED`.
- Linux CI must not be presented as proof of Scheduled Tasks, Authenticode, Event Log, ACL, or NTFS behavior.
- No receipt, log, fixture, or PR body may contain credentials, `.env` values, pairing codes, memory contents, or agent database rows.
- A stopped gateway cannot be the control channel for its own restart. Every quiet-window action runs inside the preinstalled detached transaction, coordinated with the watchdog by an ACL-restricted maintenance lease. A separately scheduled dead-man recovery expires that lease, re-enables the watchdog, starts the gateway, and leaves `DONE` or `ROLLED_BACK` even if the transaction process is killed.

---

### Task 1: Pin the 2026.9.5 contract and receipt schema

**Files:**
- Create: `docs/spec/runtime-separation-receipt.v1.schema.json`
- Create: `scripts/runtime-separation/RuntimeSeparation.psm1`
- Create: `scripts/tests/test-runtime-receipt.sh`
- Create: `scripts/tests/test-runtime-layout.sh`
- Modify: `.github/workflows/quality.yml`
- Modify: `scripts/run-checks.sh`

- [ ] **Step 1: Write failing receipt and layout tests.** Require `schema`, `phase`, UTC start/end, `sourceSha`, host, OpenClaw version, commands with exit codes, hashed inputs, observations, health, `passed|failed|rolled_back`, rollback artifact, and rollback deadline. Reject secret-looking keys/values, `.env`, pairing material, or memory content. Assert the three canonical roots are distinct and workspace repos remain excluded.
- [ ] **Step 2: Run the focused red tests.** Run `bash scripts/tests/test-runtime-receipt.sh` and `bash scripts/tests/test-runtime-layout.sh`; both fail because the schema/module is absent.
- [ ] **Step 3: Implement strict schema validation and atomic receipt writes.** Export typed helpers from `RuntimeSeparation.psm1`; write to a sibling temporary file, validate, then replace. Canonicalize roots and fail closed on overlap.
- [ ] **Step 4: Align CI with the target.** Change the single OpenClaw install from `2026.9.4` to `2026.9.5`. Add a `windows-contract` job on `windows-latest` that runs only the new Windows contract tests; make the existing gate depend on it for the complete lane and permit it to be skipped only for a valid fast lane. Keep the existing three Linux shards as the full portable battery.
- [ ] **Step 5: Run both focused tests green and commit.** Commit message: `test: define runtime separation contracts`.

### Task 2: Positive manifest, staging, watchdog gate, and file-scoped rollback

**Files:**
- Create: `config/runtime-deploy.v1.json`
- Create: `scripts/runtime-separation/Invoke-OpenClawDeploy.ps1`
- Create: `scripts/tests/test-deploy-manifest.sh`
- Create: `scripts/tests/test-deploy-atomic.sh`
- Create: `scripts/tests/test-repository-hygiene.sh`
- Modify: `.gitignore`
- Modify: `scripts/tests/test-gateway-watchdog.sh`

- [ ] **Step 1: Write failing manifest and path-safety cases.** The manifest names closed allowed roots/files and defaults to deny; it is never “all tracked minus exclusions.” Also hard-deny SQLite/WAL/SHM, credentials, sessions, logs, tools, models, `.git`, `.env*`, `openclaw.json*`, `tls/lego-data/**`, workspaces, generated launchers, backups, private keys/certs and alternate data streams. Reject absolute paths, `..`, reserved devices, control characters, symlinks and Windows reparse points. The source tree—not live state—determines candidates, and every tracked path is classified explicitly as deployable or rejected.
- [ ] **Step 1a: Write the repository-hygiene regression.** It must reject tracked `openclaw.json*`, `live-bus.env`, `tls/lego-data/**`, `agents/*/sessions/**`, generated gateway/node launchers and their backups. Remove those generated/confidential artifacts from HEAD, add ignore rules, and remove the two `tablero-runbook.bak-*` trees plus confirmed `tmp_*`, incident log and obsolete launcher/script copies from HEAD. Run a redacted secret/history scan; if it confirms credentials, open a separate owner decision for rotation/history cleanup. Do not print secret contents or rewrite history in this phase.
- [ ] **Step 2: Write failing deploy cases.** A validation failure performs zero writes; a failure after one replacement restores only receipt-listed files; every published file is read back by hash. Parse the effective `httpTimeoutSec` assignment as exactly one integer: 89, duplicate, decimal, negative and text fail; 90 and 120 pass regardless of whitespace.
- [ ] **Step 3: Run red tests.** Run `bash scripts/tests/test-deploy-manifest.sh`, `bash scripts/tests/test-deploy-atomic.sh`, `bash scripts/tests/test-repository-hygiene.sh`, and `bash scripts/tests/test-gateway-watchdog.sh`.
- [ ] **Step 4: Implement report-only staging and explicit apply.** `Invoke-OpenClawDeploy.ps1` defaults to `-WhatIf`; `-Apply` requires source/runtime/staging/receipt roots. Stage outside destinations, run config/contracts against staging, backup only replacement targets, replace atomically where supported, hash read-back, probe `/startupz` and `/readyz`, and roll back the receipt set on failure. Never use `git reset --hard` in runtime state.
- [ ] **Step 5: Run focused tests green and commit.** Commit message: `feat: add manifest driven runtime deploy`.

### Task 3: Replace main-repo sync with capture, ledger, and deploy

**Files:**
- Create: `scripts/runtime-separation/skills-pr-ledger.v1.schema.json`
- Create: `scripts/runtime-separation/Sync-OpenClawRuntime.ps1`
- Create: `scripts/tests/test-source-checkout.sh`
- Create: `scripts/tests/test-skills-pr-ledger.sh`
- Create: `scripts/tests/test-protected-paths.sh`
- Create: `scripts/tests/test-sync-four-repos.sh`
- Create: `scripts/tests/test-sync-resume.sh`
- Create: `scripts/tests/test-sync-idempotent.sh`
- Modify: `scripts/sync-repos.ps1`
- Modify: `scripts/tests/test-sync-avisa-skills.sh`
- Modify: `scripts/tests/test-sync-no-sube-binarios.sh`
- Modify: `scripts/tests/test-sync-pull-identity.sh`

- [ ] **Step 1: Write red tests for source ownership and capture.** The dedicated checkout must finish on `main`, exactly at `origin/main`, clean, and without local commits. Only `agents/*/agent/workshop-skills/**` may enter a temporary worktree/branch/PR; never push `main`. Reorient the old binary and pull-identity tests to the three workspace repos.
- [ ] **Step 2: Write red ledger/protection tests.** A repeated hash opens no duplicate; a newer live edit updates a writable PR or opens a linked successor; a closed-unmerged PR remains protected and logs conflict; a merge deploys only when captured and live hashes still agree. A deleted or renamed skill creates a tombstone and `git rm` in the capture PR, remains absent while pending/closed-unmerged, and is reconciled only after merge. A changed noncapturable path emits an alert and preserves its bytes. A missing configuration or `gateway-watchdog.ps1` creates a protected tombstone and `CONFLICTO`, remains missing across deploys, and never produces a commit until the owner resolves it.
- [ ] **Step 3: Write red crash/idempotency/four-repo tests.** Interrupt after ledger write, PR creation, staging, and first replacement; retry must converge. Two unchanged cycles alter no files or PRs. A main-repo failure still processes all workspaces, records four outcomes, writes `---- ciclo terminado`, and exits nonzero overall.
- [ ] **Step 4: Implement orchestration.** The existing `scripts/sync-repos.ps1` keeps the four-repo loop but delegates the main repo to `Sync-OpenClawRuntime.ps1`; the three workspaces retain their existing behavior. Use a global mutex, write-ahead journal, canonical paths, a locked atomic ledger outside agent-writable trees, temporary worktrees from fresh `origin/main`, explicit path copies, `gh pr create`, and the deploy from Task 2. Before external send, scan the exact staged blobs with redacted output; cap extension, size and count, reject binary/link/control-character/unexpected-agent paths, then push the already-hashed bytes. Sanitize path text so filenames cannot forge log tokens. No `git add -A`, commit, pull, reset, or push runs inside `.openclaw`.
- [ ] **Step 5: Run all Task 3 focused tests green and commit.** Commit message: `feat: separate runtime sync from source checkout`.

### Task 4: Version the v3 watcher and receipts together

**Files:**
- Create: `docs/crons/verif-sync-repos.v3.md`
- Create: `docs/cron-messages/verif-sync-repos.v3.txt`
- Create: `scripts/tests/test-vigia-sync-v3.sh`
- Modify: `scripts/aplicar-vigia-sync-prueba.sh`
- Modify: `scripts/tests/test-aplicar-vigia-sync-prueba.sh`
- Modify: `scripts/tests/test-crons-dos-copias.sh`

- [ ] **Step 1: Write the failing watcher contract.** `SKILLS_PR` reports pending once; matching `SKILLS_DEPLOYED` reports successful deployment once and clears pending. Read only the last completed cycle for health, preserve `FALLO`, `CONFLICTO`, and the final marker, and keep the watcher read-only.
- [ ] **Step 2: Run the focused red tests.** Run `bash scripts/tests/test-vigia-sync-v3.sh`, `bash scripts/tests/test-aplicar-vigia-sync-prueba.sh`, and `bash scripts/tests/test-crons-dos-copias.sh`.
- [ ] **Step 3: Implement v3 as one deployable unit.** Update test installer/backup parity and scratch markers without embedding a destination or secret. Do not enable `GoncloudRepoSync` until v3's live read-back matches the versioned message.
- [ ] **Step 4: Run focused tests green and commit.** Commit message: `feat: distinguish pending and deployed skills`.

### Task 5: Build guarded backup, Ollama memory, and rollback commands

**Files:**
- Create: `config/ollama-runtime.v1.json`
- Create: `scripts/runtime-separation/Backup-OpenClawRuntime.ps1`
- Create: `scripts/runtime-separation/Set-OpenClawMemory.ps1`
- Create: `scripts/tests/test-runtime-backup.sh`
- Create: `scripts/tests/test-memory-migration.sh`

- [ ] **Step 1: Write failing portable policy tests.** Backup success requires `openclaw backup create --verify`, restoration to a fresh ACL-restricted staging root outside repo/runtime, readable manifest coverage of shared/agent state, credentials and declared workspaces, a valid source `git bundle`, five Task Scheduler XML exports, launchers, free-space proof, and a hashed inventory. Evidence stores only archive path, size, hash, timestamp and pass/fail. `config/ollama-runtime.v1.json` must pin the approved Ollama version, its immutable official installer URL, expected installer SHA-256, expected Authenticode publisher and chain identity, and expected installed-binary hash and signature identity. Muse resolves and reviews those literal values before the implementation PR can merge. The installer command must compare the downloaded artifact and installed binary with that policy before execution or configuration and fail closed on any mismatch. The policy forbids pipe-to-shell installation and requires loopback-only port 11434, a resolved local `nomic-embed-text` digest, nonempty `/api/embed` vector, exact `ollama/nomic-embed-text/none` config, snapshot per agent, and a recorded Event Log bookmark.
- [ ] **Step 2: Write the rollback state-machine test.** Before traffic resumes and only with proof of no later writes, snapshots may be restored. Afterwards, a full database restore is rejected; create a verified diagnostic backup, preserve current databases, set provider/fallback to `none`, validate/read back, and rebuild lexical state. Never select `local` or `llama.cpp`.
- [ ] **Step 3: Run focused red tests.** Run `bash scripts/tests/test-runtime-backup.sh` and `bash scripts/tests/test-memory-migration.sh`.
- [ ] **Step 4: Implement report-only commands with `-Apply`.** Resolve exact OpenClaw 2026.9.5 memory index/search syntax from captured help. Stop before mutation if version, signature, hash, endpoint, schema, or per-agent inventory differs. Do not alter conversation models or fallbacks.
- [ ] **Step 5: Run focused tests green and commit.** Commit message: `feat: add reversible memory migration`.

### Task 6: Build isolated Windows node and quarantine commands

**Files:**
- Create: `scripts/runtime-separation/Set-OpenClawNode.ps1`
- Create: `scripts/runtime-separation/Move-OpenClawQuarantine.ps1`
- Create: `scripts/tests/test-node-isolation.sh`
- Create: `scripts/tests/test-quarantine.sh`

- [ ] **Step 1: Write failing node tests.** Require `.openclaw-node`, restrictive ACL intent, no gateway SQLite copy, browser proxy skill/inference restrictions, and the exact eight-command surface. Before pairing, configure node-local exec approvals with executable, cwd and exact argv. Variable arguments require anchored, literally escaped, non-nested `argPattern` cases. Reject path-only duplicates, wildcards, shell wrappers, changed arguments, interpreters and unlisted `cmd.exe /c`. Pair once in the foreground with `node run --pair --commands`; redact the code; approve the device and then the distinct command surface; install without `--pair` under the same state. Export duplicate-task XML before removal and preserve the official task's environment after terminal exit.
- [ ] **Step 2: Write failing quarantine tests.** Hash and inventory every candidate before moving it outside deploy roots; reject databases, WAL/SHM, credentials, sessions, active launchers, evidence, open handles, or unclosed worktrees. No delete command exists. Restore an innocuous fixture by recorded path/hash.
- [ ] **Step 3: Run focused red tests.** Run `bash scripts/tests/test-node-isolation.sh` and `bash scripts/tests/test-quarantine.sh`.
- [ ] **Step 4: Implement guarded commands and green tests.** Node apply waits by condition for `connected=true` and version `2026.9.5`; process existence alone fails. Commit message: `feat: isolate node state and quarantine cleanup`.

### Task 7: Integration contract, documentation, and implementation PR

**Files:**
- Create: `docs/runbooks/openclaw-runtime-cutover.md`
- Create: `docs/evidence/openclaw-runtime-cutover-template.md`
- Create: `scripts/runtime-separation/Invoke-OpenClawCutover.ps1`
- Create: `scripts/tests/test-runtime-cutover-transaction.sh`
- Modify: `gateway-watchdog.ps1`
- Modify: `scripts/tests/test-gateway-watchdog.sh`
- Modify: `docs/runbooks/base-openclaw.md`
- Modify: `docs/agent-skills/verify/SKILL.md`
- Modify: `scripts/tests/test-restart-gateway-script.sh`

- [ ] **Step 1: Build and test the detached transaction.** Before any stop, create a one-shot Scheduled Task pointing by absolute path to the merged `Invoke-OpenClawCutover.ps1`, plus an independent dead-man recovery mode/task with a fixed deadline. Each run creates a unique generation ID in an ACL-restricted, schema-valid maintenance lease and state record. The watchdog honors only that generation while its lease remains valid. The transaction has hard per-phase/global timeouts, idempotent resume, durable sanitized logs/receipts and `try/finally`. After re-enabling the watchdog and verifying `/startupz` and `/readyz`, success atomically and durably writes terminal `DONE` for the same generation, then cancels the dead-man. Immediately before recovery, the dead-man locks and rereads the state. It exits without mutation when the matching generation is `DONE`; otherwise, it may recover and write `ROLLED_BACK` only for the same nonterminal generation and must never overwrite a terminal state. Test valid, expired, malformed, wrong-ACL and absent leases. Test process death after gateway stop, after health verification but before `DONE`, and after `DONE` but before dead-man cancellation. The first two recover service; the last does not roll back. The controller dispatches once and later reads the receipt; it never expects another gateway-mediated turn while the gateway is down. Run `bash scripts/tests/test-runtime-cutover-transaction.sh` and `bash scripts/tests/test-gateway-watchdog.sh` red then green.
- [ ] **Step 2: Document the exact engineering sequence.** Cover preflight, backup/restore, trusted bootstrap clone/fetch directly to `C:\Users\ehven\src\goncloud-openclaw` without enabling the old sync, Scheduled Task XML/action read-back, watcher-v3 read-back, checkout/deploy, one real sync cycle, Ollama, per-agent reindex/search, isolated node, fifteen-minute soak, quarantine, component rollback, and sanitized receipts. Move live `.git` to ACL-protected quarantine only after the new task points at the clean dedicated checkout; rollback restores both task XML and `.git`. Mark all live commands as requiring the operational `authorization_ref`.
- [ ] **Step 3: Update durable operator truth.** Replace the old “repo is gateway state” assumption in `base-openclaw.md` and verification guidance with source/runtime ownership, including the temporary disabled-sync state. Preserve historical ledger text; explicitly supersede the Phase 13 `SKILLS` behavior.
- [ ] **Step 4: Run neighboring focused tests.** Run the Task 1–6 tests plus `bash scripts/tests/test-runtime-cutover-transaction.sh` and `bash scripts/tests/test-restart-gateway-script.sh`; do not run `scripts/run-checks.sh` locally.
- [ ] **Step 5: Self-review the complete diff.** Check path ownership, failure exits, receipt redaction, idempotency, PowerShell 5.1 syntax, documentation parity, and that every new test discriminates by temporarily introducing one local defect and observing failure before restoring it.
- [ ] **Step 6: Muse runs hygiene and hands off.** Run `git diff --check` and `pre-commit run --all-files`; never use `--no-verify`. Fetch `origin/main`, verify `git log origin/main..HEAD` contains only this task's commits, write the contract `LISTO <sha>`, and stop. Do not push or open a PR.
- [ ] **Step 7: The lead publishes and consumes final evidence.** The lead audits the commits/tests, pushes the phase branch, opens the implementation PR, and requires classifier, three Linux shards, `windows-contract`, CI-contract, and gate green on the candidate final head. A correction SHA invalidates prior CI evidence. A fresh reader and an independent reviewer must each approve that exact head; their durable receipts record reviewer identity, role, SHA, verdict, and blocking findings. Codex/root posts `APPROVE Codex <sha>` after grouped review; Muse applies one correction batch if needed and only blockers trigger delta review. The lead posts `APPROVE lead <sha>` only after both review receipts and current CI are green. All exact-head review and lead receipts are prerequisites for merge authorization and Task 8. Do not rerun the full battery locally.

### Task 8: Separately authorized Windows cutover and acceptance

**Files:**
- Create after operation: `docs/evidence/openclaw-runtime-cutover-<date>.md`
- Modify after operation: `Plans.md`

- [ ] **Step 1: Gate authority, bootstrap, and exact artifact.** Engineering records the implementation merge SHA plus a distinct operational `authorization_ref`. The authorization names that exact merge SHA and cites current CI, fresh-reader, independent-reviewer, Codex, and lead receipts for the same SHA. Before creating either transaction task, clone/fetch directly into the new `C:\Users\ehven\src\goncloud-openclaw`, pin it to that merge SHA, and verify expected remote, `HEAD == <merge SHA>`, clean tree and artifact hashes. Do not enable the old sync or run the stale live checkout. Confirm Windows is on OpenClaw 2026.9.5. Preflight also records AC sleep policy, logged-on user/session durability, free space for backup+restore+snapshots+model, admin/elevation or noninteractive install capability, network/GitHub access, task prerequisites, watchdog/dead-man readiness, and exact CLI help. Do not change power policy, reboot or log off. A missing reference, SHA mismatch, nonzero AC sleep timeout, unavailable durable session, interactive UAC requirement, or insufficient disk stops before mutation.
- [ ] **Step 2: Create restorable backups.** Dispatch the detached transaction; it stops the gateway per the validated runbook, creates/verifies the real OpenClaw backup, restores to fresh ACL-restricted staging and inspects its manifest, verifies the source bundle, XML exports, launchers and inventory, then restarts/verifies the gateway in `finally`. Any failure stops before moves.
- [ ] **Step 3: Cut over source/deploy and sync.** Fetch without changing the checkout, then require the authorized merge SHA, `origin/main`, and the dedicated checkout `HEAD` to be identical. Any advancement or mismatch aborts before deploy and requires a new exact-SHA authorization with current CI and review receipts; never fast-forward under the old authorization. Deploy staging, install/read back watcher v3, then enable and run `GoncloudRepoSync`. Require four repo outcomes, final marker, exit 0, source exactly at the authorized clean `origin/main`, runtime without the main `.git`, and a second unchanged cycle with no new writes or PRs.
- [ ] **Step 4: Migrate memory.** Verify Ollama SHA/signature and loopback bind, pull `nomic-embed-text`, require a nonempty embedding, snapshot each agent, change only memory search fields, validate/read back, rebuild every agent index, run a nonliteral semantic query, and prove no new 3033/3077 `llama-server` events.
- [ ] **Step 5: Isolate the node.** Pair in foreground under `.openclaw-node`, install without persisting the pair code, approve the exact allowlist, export/remove the duplicate task, restart the official task, and require connection/version after terminal exit.
- [ ] **Step 6: Soak and quarantine.** For fifteen minutes under normal gateway traffic, sample `/readyz` and node connection. Only after green soak move eligible artifacts to quarantine, verify destination hashes, and restore one innocuous candidate as a reversal rehearsal.
- [ ] **Step 7: Record closure.** Commit only redacted evidence and terminal ledger states in one closure PR. Final acceptance joins current CI, valid receipts, healthy two-cycle sync, semantic search, connected isolated node, soak, no new Code Integrity events, and zero permanent deletions.

## Verification command index

During implementation, run the test file being changed plus the dependent focused tests listed in that task; Task 7 runs the neighboring Task 1–6 tests named in Step 4. Before the implementation handoff, run `git diff --check` and all configured pre-commit hooks. The sole complete battery is the implementation PR's GitHub Actions run on its final SHA; its three Linux shards must collectively cover `scripts/run-checks.sh`, and the Windows job covers only Windows-specific contracts. Operational acceptance is not a substitute for CI, and CI is not evidence of the live Windows cutover.

## Source notes

- OpenClaw node documentation: `node run --pair` or `--pair-if-needed` performs short-lived enrollment; `node install --pair` is intentionally unavailable. The installed service reuses the durable identity in `OPENCLAW_STATE_DIR`.
- OpenClaw backup documentation requires verified archive creation and restoration into a fresh target before claiming recoverability.
- OpenClaw memory documentation treats provider/model changes as a new index identity; rebuilding per agent is mandatory. `provider: none` provides intentional lexical-only degradation.
- Ollama's Windows distribution is local by default, but the live gate still verifies signature, hash, listener binding, and `/api/embed` behavior.

---
name: openclaw-cron-jobs
description: Create, patch, or force-test OpenClaw cron automations (single-line prompt files, scratch, run monitoring, CLI-locked fallbacks) on the Windows gateway. Use when adding or editing scheduled jobs.
---

# OpenClaw Cron Jobs

Manage gateway cron automations from this Windows PowerShell host without quoting failures, truncated messages, or blind waits.

## Steps

1. Check for duplicates with `openclaw cron list` before creating a job.
2. Write the job message to a file first (workspace `tmp/<job>_oneline.txt`): PURE 7-bit ASCII — no double quotes, no `$`, no emoji, no accented characters, and no typographic punctuation (· – — “ ” ’ …). Any non-ASCII byte corrupts in transit: a single `·` in a BOM-less UTF-8 file read by `Get-Content -Raw` (ANSI default on this PowerShell host) stored as mojibake `Â·` in the live message. Keep typographic separators and labels in the referenced template or runbook (the `read` tool handles UTF-8 correctly) and have the message instruct copying them from there. SINGLE line, no newlines: multi-line content is not reliably preserved — a job edited with a multi-line message stored only its first line, and the isolated run then executed without instructions until an idle timeout. Make the message self-contained, with absolute Windows paths to any runbook or detail file it references.
3. Load and create in one command; pass the job name positionally (`--name` plus a long `--message` corrupts argument parsing on this host):
   ```powershell
   $msg = Get-Content -Raw "<prompt file>"
   openclaw cron create <job-name> --display-name "<label>" --cron "<expr>" --tz America/Mexico_City --exact --agent operaciones --session isolated --no-deliver --timeout-seconds 3600 --message $msg
   ```
4. Patch an existing job with `openclaw cron edit <job-uuid> --message $msg` (there is no `cron update`). `cron edit` echoes the full updated job JSON including the stored message — verify from that echo: version marker in the FIRST line AND scan the whole echoed message for mojibake (`Â`) or stray non-ASCII; a clean first-line marker can hide a corrupted body. `configRevision` DOES change on message-only edits — a new hash confirms the edit landed. For later checks with `cron get` (which previews only line 1 of long messages), a transient `Opening handshake has timed out` clears on a single retry.
5. If exec denies the CLI (observed after gateway restarts: `approval cannot safely bind this command` / `approval script operand changed`, `Approved executables: none`): the first-class `automations` tool is caller-scoped and will not list these jobs; the `openclaw` system-expert tool cannot edit cron payloads. Verified fallback: hand the owner a `.ps1` that runs `openclaw cron edit <job-uuid> --message "$(Get-Content -Raw '<prompt file>')"` for each job plus `cron get` verifications — the owner terminal is not subject to the agent approval binder. Control UI → Automations paste is the no-terminal alternative. Simple literal `ssh <host> "<command>"` exec shapes may still pass while the CLI is denied; do not assume total lockout. The first-class `automations` tool can still ADD self-owned one-shot wakeups (schedule `{kind:"at"}`, `sessionTarget:"current"`, delivery announce) even while its caller-scoped inventory reports the cron jobs as not found — use one to schedule post-run verification while the CLI is locked; it auto-deletes after firing.
6. Update scratch with the job UUID, never the job name: `openclaw automations scratch <job-uuid> --set "<state>"` (name-based scratch fails with `Automation not found`).
7. Force a test with `openclaw cron run <job-uuid> --wait --wait-timeout 25m` in a background exec. If the wrapper exec disappears, the run continues server-side: authoritative status is `openclaw cron list`; `cron runs <uuid>` shows entries only after completion; live progress is `sessions_history` on `agent:operaciones:cron:<job-uuid>`.

## Completion check

- `openclaw cron list` shows the job with the expected schedule and next-run time.
- `cron get <uuid>` message preview (line 1) shows the current version marker.
- The prompt file contains no newlines.
- The forced run ends with status `ok` and its final report matches what the census/baseline should produce.

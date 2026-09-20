---
name: automation-run-recovery
description: Re-fire a scheduled automation by hand and diagnose why a run died, stalled, or reported ok without doing its work. Use for "run this cron/automation now", after a gateway restart killed an in-flight job, when a run shows failed/partial, or when a job's payload/instructions (prompt v-swap) must be updated. Produces the run outcome, proof of whether outward-facing sends happened, or a verified payload read-back.
---

# Automation Run Recovery

Manually run, inspect and re-fire a scheduled automation (`openclaw cron`, alias `automations`) through the Gateway. Verified 2026-09-10 (diagnosing a `packing-digest-20h` run killed by a gateway restart, then re-firing it with `--wait`).

## Steps

1. Read the job before touching it: `openclaw cron get <id>` (JSON) or `openclaw cron show <id>`. Note `payload.message`, `agentId`, `schedule.tz`, `timeoutSeconds`, `failureAlert`, and the `state` block: `runningAtMs` non-empty = a run is in flight now; `lastRunStatus`, `lastDurationMs`, `consecutiveErrors`, `nextRunAtMs` describe the last one.
   - Completion: you know whether a run is already in flight and how the last one ended.

2. History and prior summary: `openclaw cron runs <id> --limit <n>` for per-run `action` (started/finished), `status` (ok/error), `completionStatus`, `error`, `durationMs`, `tsIso`, and the run's `sessionKey`. `openclaw cron scratch <id>` holds the previous run's own written summary — often the fastest read of what it actually did.
   - Completion: the cause of a failed/partial run is named (e.g. `error: "Gateway shutting down."`).
   - Second cause shape: the turn aborted with `stopReason=aborted` / `errorMessage="LLM idle timeout (Ns): no response from model"` — the model provider went silent past the stream watchdog. A configured model-fallback chain does **not** engage on this path (the turn enters settled post-tool finalization instead), so the fallback is not a rescue; the gateway log line to search for is `settled post-tool turn lacked a final answer`.
   - Third cause shape — **the run itself succeeded but delivery failed**: the transcript shows the correct work and summary, yet `status: error` with `deliveryStatus: "not-delivered"`. An isolated cron with `delivery: last` is refused ("Refusing implicit isolated cron delivery: the target would be inherited from the shared agent-main session bucket's last recipient... Set delivery.channel and delivery.to explicitly"). The job keeps failing every tick while the work is fine. Fix the route, not the payload: `openclaw cron edit <id> --announce --channel telegram --to <owner-chat-id>`, then verify with one forced `cron run` whose history entry reads `delivered: true`. Verified 2026-09-12 (`verif-sync-repos`, two errors cleared). A chat id as `to` is a routing fact, not a secret.

3. Read what a run did in detail: the history entry's `sessionKey` (shape `agent:<agentId>:cron:<jobId>:run:<runId>`) is a real session. `sessions_history sessionKey=<that> includeTools=true` shows its progress and exactly which step it reached.
   - Completion: you can say which pipeline step the run stopped at.

4. Before re-firing, check whether the dead run got as far as its **outward-facing** steps (mail, Telegram, posts). A run killed mid-pipeline before its send step leaves nothing to duplicate; one killed after sending would duplicate on re-fire. Cross-check both the run transcript (step 3) and the artifacts it writes (files, sent-scripts, dedup ledgers).
   - A run's `status: ok` / `completionStatus: succeeded` is the **wrapper's exit**, not proof the work happened: a turn aborted mid-pipeline can still record `ok` with `summary: "The tool run finished, but no final summary was produced. I did not repeat any completed actions."` and `delivered: false`. Judge success by the artifacts and the send records, never by the run status — and check the artifacts before re-firing to know what actually needs redoing.
   - Completion: a stated go/no-go on re-firing, backed by what the run reached.

5. Re-fire it: `openclaw cron run <id>`. Add `--wait --wait-timeout <duration>` (e.g. `25m`) to block until it finishes; without `--wait` the call returns immediately after queueing. `--expect-final` additionally waits for the agent's final response. This is the debug path and works even when the schedule is not due.
   - Completion: a queued run's `runningAtMs` advances in `cron get` (queued), or the `--wait` call returns a finished status.

6. Let the job's own `failureAlert` (channel + recipient) report a failure; do not hand-roll an alert. If the job has `failureAlert.mode: announce`, a failed run announces itself.
   - Completion: you are not replacing the job's configured alerting.

## Update a job's payload (prompt swap)

Replace a job's agent-turn instructions (e.g. a new runbook-prompt version). Verified 2026-09-13 (`packing-digest-20h` v14 → v15, a 9.5k-char single-line prompt).

1. Prepare the new prompt as a one-line text file, then apply and read back:
   `$m = Get-Content <prompt-file> -Raw; openclaw cron edit <id> --message $m`
   `openclaw cron edit` only patches the fields you pass — schedule, agentId, failureAlert and delivery are untouched; confirm that in the JSON the command returns (`payload.message` starts with the new version string, `schedule` unchanged).
   - Completion: the read-back shows the new payload text and an unchanged schedule.

2. Long payloads break the shim: values over ~8k characters fail with `The command line is too long.` because `openclaw.cmd` is a cmd.exe shim and cmd's line limit is 8,191 chars. The shim is only `node ...npm\node_modules\openclaw\dist\index.js %*` — call node directly instead, which passes args via CreateProcess (~32k limit):
   `node "C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\index.js" cron edit <id> --message $m`
   - Completion: the same read-back as step 1 succeeds.

## Pitfalls

- **The internal runtime snapshot ("Active exec sessions: none") can be stale during long runs.** Re-check with the `process list` tool; a long `--wait` call keeps running even while that snapshot says nothing is active. Judge by `process list` / `cron get state.runningAtMs`, never by the snapshot alone.
- A `cron run` that exits non-zero under PowerShell is not necessarily a failure: the CLI writes diagnostics to stderr and PowerShell paints them as `NativeCommandError`. Judge by `cron runs` and `runningAtMs`.
- `openclaw cron list --all` is the inventory (id, schedule, next/last, status, agentId); use it to find the id and to spot a job already `running`.
- A gateway restart kills an in-flight run with `error: "Gateway shutting down."` and consumes a `consecutiveErrors`. Check for a `running` job before restarting the gateway for any config change.
- Do not re-run a job that is already in flight: step 1's `runningAtMs` is the guard against double-sends.
- The last-run status you read (e.g. a job `state` block showing `lastRunStatus: error` with `consecutiveErrors`) and a fresh manual run that reports `ok` can describe the same dead turn — the manual wrapper exits 0 while the work still never completed. Reconcile both against the artifacts (step 4) before concluding anything ran.
- When the diagnosis lands on OpenClaw's own runtime (e.g. an idle-timed-out turn reclassified as `ok`), that is an **upstream defect**: do not patch the installed `openclaw` package in place (the fix is lost on the next update). Confirm the upstream PR and wait for the release that ships it, or cherry-pick only with the owner's explicit OK.

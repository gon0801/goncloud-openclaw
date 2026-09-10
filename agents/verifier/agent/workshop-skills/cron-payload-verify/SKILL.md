---
name: cron-payload-verify
description: Verify cron/automation job messages were applied. Prove live payload wiring separately from source files; last-run chat is not the current message.
---

# Verify cron job payloads

Two claims, two artifacts. Source-file checklist ≠ job-store payload. Finish only when each claimed job has a live payload artifact, or name that job inconcluso.

## 1. Content vs wiring

Read the intended message files first. Score content against the requested checklist.

Then prove the **store**: the job's current `payload.message`. Do not treat these as the store:

- `tmp/job*.json` or other workspace dumps (they lag)
- the applying agent's memory note or "exit=0 ×N" report
- the last isolated cron session preview (that is the last **run**, not the current payload)

Done when: each job is either (a) content+wiring both evidenced, or (b) listed inconcluso with the missing artifact.

## 2. Get the live payload

Prefer `openclaw cron get <id>` / `automations get` on the **gateway** host, JSON `payload.message`.

If exec is bound to a node without the CLI, or gateway exec is denied: do not mine sqlite/WAL as text and do not retry the same host. Recover from the applying agent's session:

1. `sessions_list` with `kinds: ["cron"]` and that `agentId` — confirms the job exists, schedule, last run. Not the payload.
2. `sessions_history` on the applying agent's **main** (not the cron session), `includeTools: true`. Page `offset` until the apply/`cron edit` process log.
3. Accept wiring only for jobs whose **full** `payload.message` (or `cron get` echo of it) is in that tool result.

`sessions_history` truncates long tool output. A truncated log that shows job A is not evidence for jobs B and C in the same script. Inconcluso ≠ PASS.

Done when: live message text is in hand for every job you mark wired, or those without it are inconcluso.

## 3. Report

Per job: content checklist, then wiring (live JSON / recovered edit log / inconcluso). State when the payload has not been executed yet (last cron session still shows the previous run).

---
name: agent-dispatch
description: Dispatch a brief to the engineering agent chain (implementer / verifier / reviewer) or to a spawned subagent, and recover full results. Use for a task brief or "-saikit" lane, when a sessions_send agent fails with "All models failed", or when a completion result arrives truncated. Produces the complete result.
---

# Agent / Subagent Dispatch

Route work to this Gateway's agents and collect complete results. Main orchestrates the team; `ingenieria` is a peer worker, not the orchestrator. Verified 2026-09-10: a full lane ran implementer -> verifier -> reviewer on the Mac repo, each role fed the previous role's commit and evidence paths; the same day a chain failed on rate-limited models and was re-dispatched on an alternate one.

## Chain dispatch (brief / "-saikit" lane)

1. Read the brief yourself before dispatching; it names the lane and the role order. Dispatch one role at a time with `sessions_send agentId=<role>` and wait for its reply before the next. Observed full lane: implementer -> verifier -> reviewer.
   - Completion: each role's reply returns before the next dispatch.

2. Put the whole shared context in each dispatch message: repo path, branch, base commit, brief path (the role reads it itself), that role's scope, what NOT to touch, and the handoff facts — previous role's commit SHA, the evidence paths it left (`.saikit/scratch/<task>/`), and which of its claims to attack.
   - Completion: the role can start without re-deriving state you already know.

3. Reviewer reviews and reports; it never applies a fix. A defect it finds reopens the previous role — say so in the dispatch. Never let one role silently redo another's work, and never substitute a role you consider broken.
   - Completion: the reply is a verdict (approved / approved with observations / rejected) with file:line, or the reopened role's new commit.

4. Require evidence in the repo, not in the reply: mutation tables, logs, revalidation notes under `.saikit/scratch/<task>/`, with the module under test left identical to the commit.
   - Completion: evidence files exist and `git diff --quiet <module>` is clean at the end.

5. On a PR-extension task, have the role confirm the working branch is the PR's head branch (`git branch --show-current`) before committing: a commit on another branch does not extend the PR, and the mistake is silent.
   - Completion: branch name matches the PR head before the commit.

## Failed or truncated dispatch

6. A configured agent's model list is fixed: if it fails with `All models failed (n): ... in cooldown` / `subscription usage limit`, retrying or waiting will not help. Re-dispatch as a subagent with an explicit working model: `sessions_spawn model=<provider/model> ...`, naming a model registered in `models.providers` (e.g. `xai/grok-4.6`; register it first with the `openclaw-config-patch` skill if it is missing).
   - Completion: the spawn is accepted (`modelApplied: true`).

7. Wait for the accepted completion mode: announced children -> `sessions_yield`; collector runs -> `agents_wait`. Never busy-poll.

8. Read the FULL result. A completion/settle event and the inline reply of a `sessions_send` can both truncate the text (`display-cap`) — a report ending mid-sentence is truncated, not complete. Fetch the whole one with `sessions_history sessionKey=<childSessionKey>`. For a configured agent that key is `agent:<id>:main`; if an unscoped `sessions_list` fails with `unable to open database file`, list with `agentId=<id>` to get the key and `sessionId`.
   - Completion: you have the child's complete final text.

9. Consolidate across roles and report only the synthesized result.

## Pitfalls

- A configured agent cannot be model-overridden through `sessions_send`; model fallback requires `sessions_spawn` with an explicit `model`. Spawning is by id only for `main`: `sessions_spawn agentId=<configured-agent>` is rejected (`agentId is not allowed for sessions_spawn (allowed: main)`), so spawn a fresh subagent and carry the role's instructions in the task text instead.
- Trust `sessions_history` of the child over a truncated settle text.
- Rate-limit cooldowns are provider-wide; switch provider instead of retrying the same one.
- Dispatching the next role before the previous reply arrives loses the handoff facts (SHA, evidence paths) that role needs.

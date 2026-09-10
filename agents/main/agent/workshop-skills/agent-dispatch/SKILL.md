---
name: agent-dispatch
description: Dispatch work to configured agents or spawned subagents and recover full results. Use when a sessions_send agent fails with "All models failed" (its model is rate-limited), or a subagent completion result arrives truncated. Produces the complete result.
---

# Agent / Subagent Dispatch

Route work to this Gateway's agents and collect complete results. Main orchestrates the team; `ingenieria` is a peer worker, not the orchestrator. Verified 2026-09-10 (the review chain could not start on its OpenAI models; it was re-dispatched on alternate models and the full reports were read from the child sessions).

## Steps

1. Dispatch to a configured agent by id: `sessions_send agentId=<id>`. A configured agent always runs its own configured model.
   - Completion: the send is accepted.

2. If it fails with `All models failed (n): ... in cooldown` / `subscription usage limit`, the agent's model list is fixed — retrying or waiting will not help. Re-dispatch as a subagent with an explicit working model: `sessions_spawn model=<provider/model> ...`, naming a model registered in `models.providers` (e.g. `xai/grok-4.6`; register it first with the `openclaw-config-patch` skill if it is missing).
   - Completion: the spawn is accepted (`modelApplied: true`).

3. Wait for the accepted completion mode: announced children → `sessions_yield`; collector runs → `agents_wait`. Never busy-poll.

4. Read the FULL result. A completion/settle event and the inline reply of a `sessions_send` can both truncate the text (`display-cap`) — a report ending mid-sentence is truncated, not complete. Fetch the whole one with `sessions_history sessionKey=<childSessionKey>` (the key returned by `sessions_spawn`, or the key the send targeted).
   - Completion: you have the child's complete final text.

5. Consolidate across children and report only the synthesized result.

## Pitfalls

- A configured agent cannot be model-overridden through `sessions_send`; model fallback requires `sessions_spawn` with an explicit `model`.
- Trust `sessions_history` of the child over a truncated settle text.
- Rate-limit cooldowns are provider-wide; switch provider instead of retrying the same one.

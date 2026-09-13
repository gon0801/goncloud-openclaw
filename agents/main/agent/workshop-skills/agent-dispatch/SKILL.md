---
name: agent-dispatch
description: Dispatch a brief to the engineering agent chain (implementer / verifier / reviewer) or to a spawned subagent, and recover full results; run the external Claude-on-the-Mac review loop (brief file, do-script delivery, verdict watch) until APROBADO. Use for a task brief or "-saikit" lane, when a sessions_send agent fails with "All models failed", when a completion result arrives truncated, or when David asks for a fix→review loop until Claude approves a block.
---

# Agent / Subagent Dispatch

Route work to this Gateway's agents and collect complete results. Main orchestrates the team; `ingenieria` is a peer worker, not the orchestrator. Verified 2026-09-10: a full lane ran implementer -> verifier -> reviewer on the Mac repo, each role fed the previous role's commit and evidence paths; the same day a chain failed on rate-limited models and was re-dispatched on an alternate one.

## Chain dispatch (brief / "-saikit" lane)

0. Multi-PR rounds need delivery sequencing: an external reviewer re-reading an OLD brief can race the implementer's push (it re-read the unchanged brief file, saw old PR heads, and re-stamped its previous verdict instead of reviewing the fixes — verified 2026-09-13). Write the brief file pointing at the NEW head SHAs, list the per-finding commits, and only then deliver; if a reviewer reports "nothing new", compare the PR heads it cites against the actual pushed heads before dispatching fixes.

1. Read the brief yourself before dispatching; it names the lane and the role order. Dispatch one role at a time with `sessions_spawn agentId=<role> mode=run` and put the whole shared context in `task` (a spawned child starts with isolated context). Its completion comes back to you as a new turn even after your turn has closed; dispatch the next role then. Observed full lane: implementer -> verifier -> reviewer.
   - Never dispatch work whose result you need with `sessions_send` and `timeoutSeconds: 0`: that reply travels a path that dies silently once your turn ends (2026-09-11: 41 lost replies in one day).
   - Completion: each role's completion arrives before the next dispatch.

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

8. Read the FULL result. A completion/settle event and the inline reply of a `sessions_send` can both truncate the text (`display-cap`) — a report ending mid-sentence is truncated, not complete. Fetch the whole one with `sessions_history sessionKey=<childSessionKey>`. For a spawned child that key is the `childSessionKey` returned by `sessions_spawn`; for a configured agent's own session it is `agent:<id>:main`. If an unscoped `sessions_list` fails with `unable to open database file`, list with `agentId=<id>` to get the key and `sessionId`.
   - Completion: you have the child's complete final text.

9. Consolidate across roles and report only the synthesized result.

## External review loop (Claude on the Mac)

David repeatedly orders a fix-then-review loop against the Claude Code tab in the Mac project ("revisa y haz el loop hasta que Claude apruebe"; asked 2026-09-11 and 2026-09-13 for different lanes). Verified full cycle 2026-09-13 (bloque 6: ronda 1 `VEREDICTO: CAMBIOS` with 8 findings, then fixes pushed → ronda 2 `VEREDICTO: APROBADO`):

1. Write the brief to a Mac file (`/tmp/brief-<task>-r<N>.txt`): what to review (PRs, branches, head SHAs), the operator decisions it must not re-litigate (marked as such), the authoritative sources (Plans.md rows, artifact path), and the verdict format — first word `VEREDICTO: APROBADO` / `VEREDICTO: CAMBIOS` with file:line findings.
   - Completion: the brief file exists on the Mac (`wc -c`).
2. Deliver with ONE short `do script "Lee /tmp/brief-… y haz lo que pide"` into the project's tab (mac-terminal-control step 4). Confirm delivery by the marker text appearing in the project transcript (mac-agent-transcript step 4), not by the osascript exit.
3. Watch for a NEW verdict by counting `VEREDICTO` occurrences in the transcript against a baseline taken at delivery — the brief itself contains the word, so a plain grep false-positives (same rule as mac-terminal-control step 5's marker matching). A detached watcher that fires when the count increases beats poll loops over a flaky companion channel.
   - The verdict can take 30+ minutes: Claude dispatches its own verifier/reviewer subagents and posts progress echoes (`SUMMONAIKIT HARNESS DELEGATED - awaiting verifier`). Read the final verdict from the transcript (mac-agent-transcript step 3), never from the tab tail.
4. `CAMBIOS` → dispatch the fixes to the implementer with the findings verbatim (each carries file:line), do the trivial gh-side items yourself (e.g. cross-PR chaining comments; "lo chico lo haces vos"), then re-brief with the NEW head SHAs and the per-finding commits before re-delivering (step 0's race rule — an un-updated brief makes the reviewer re-stamp the old verdict). `APROBADO` → the loop ends; report PRs, CI state, and the owner's remaining action (merge order for stacked PRs).

## Pitfalls

- A configured agent cannot be model-overridden through `sessions_send`; model fallback requires `sessions_spawn` with an explicit `model`. Since 2026-09-11 `agents.entries.main.subagents.allowAgents` lets main spawn under main, operaciones, ingenieria, implementer, verifier, reviewer, adversary and scout. If `sessions_spawn` answers `agentId is not allowed for sessions_spawn`, that allowlist changed: report it, do not fall back to a fire-and-forget `sessions_send`.
- A `sessions_send` that answers with an error yet also reports `sentBeforeError: true` **did deliver** the message: do not resend it (verified twice on 2026-09-11, error `Auth profile "opencode-go:manual" is temporarily unavailable`). Read the target session to confirm instead of dispatching again.
- Trust `sessions_history` of the child over a truncated settle text.
- To hand a running child a correction mid-run, `sessions_send` to its `childSessionKey` is the route — but a plain send may be blocked by the gateway gate ("la respuesta de un sessions_send ... se pierde"). The gate error lists the allowed forms; for a correction that needs no reply, prefix the text with `[AVISO SIN RESPUESTA]` and resend (verified 2026-09-13: blocked plain send, then accepted with that prefix).
- Rate-limit cooldowns are provider-wide; switch provider instead of retrying the same one.
- Dispatching the next role before the previous completion arrives loses the handoff facts (SHA, evidence paths) that role needs.

---
name: owner-report-delivery
description: Use when a turn without an inbound user message (heartbeat poll, forwarded inter-session report, system continuation) must reach David's Telegram, or a continuation reports the previous attempt "did not produce a user-visible answer". Produces a delivered message verified by ok:true and messageId.
---

# Owner Report Delivery

Get a consolidated answer to actually reach David when the turn was not started by his message. Consolidation duties live in SOUL.md; this skill is only the delivery mechanics. Verified 2026-09-10: four explicit sends (798, 804, 813, 814) all delivered, while plain-text replies in heartbeat/continuation turns never surfaced and the harness kept flagging "no user-visible answer".

## Steps

1. Check whether the turn has an inbound user message. Heartbeat polls, forwarded inter-session reports, and system continuations do not create a reply route — final assistant text in such turns was observed to never reach the chat.
   - Completion: you know whether a reply route exists.

2. No reply route → deliver explicitly: `message` action=send with `target` = the owner's DM chat (David: 6470689715). The result must contain `"ok":true` and a `messageId`.
   - Completion: ok:true + messageId returned.

3. Repeated continuation demanding a "user-visible answer" → before resending, check for an existing confirmed send (this turn's earlier results, or `sessions_history`): if one already returned ok with a messageId, do NOT send again; answer the continuation with a short text and end. Duplicate pushes are worse than a benign loop flag.
   - Completion: either a new confirmed send, or a deliberate no-resend backed by evidence.

4. Long output (~4000+ chars): split into numbered parts ("1/2", "2/2") and send them sequentially, not parallel, so order is preserved. Example: full `openclaw doctor` output ≈ 6k chars → two parts.
   - Completion: all parts confirmed sent, in order.

5. Forwarded inter-session report duplicating a reply already handled: answer the forward with exactly `REPLY_SKIP` to stop the announce ping-pong, then consolidate and deliver once via step 2.
   - Completion: one delivered consolidation, no duplicate.

## Pitfalls

- Do not keep re-issuing plain-text replies to heartbeat continuations; the explicit message send is the only verified user-visible path in non-user-sourced turns.
- Sending is outward-facing: consolidate first, send once, keep it complete but brief; never push "nothing new" pings (quiet-time rules live in AGENTS.md).

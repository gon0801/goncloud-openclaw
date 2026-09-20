---
name: browser-bridge-recovery
description: Recover a wedged OpenClaw browser content bridge. Use when browser text/snapshot/act/evaluate return "timed out. Restart the OpenClaw gateway" while tabs/status/navigate still succeed, or when a profile reports running:true with pid:null. Produces a working browser with a real PID and readable pages.
---

# Browser Content Bridge Recovery

Recover the managed browser when page-load/metadata operations work but content reads are dead. Verified 2026-09-09 (gateway restart + profile stop/start produced a real PID and restored `text`/`navigate` reads).

## Steps

1. Recognize the wedge, do not retry blindly. The signature is split behavior:
   - `browser tabs` / `browser status` / `browser navigate` succeed (metadata + page load).
   - `browser text` / `snapshot` / `act` / `evaluate` fail with "timed out. Restart the OpenClaw gateway".
   - `browser status` on the profile shows `running: true` but `pid: null` (zombie — the gateway cannot recycle the process).
   - A single retry of `text` is allowed, but if it times out again, the bridge is wedged, not transient. Stop retrying.
   - Completion: you have confirmed content ops fail while metadata ops work.

2. Restart the gateway (owner-authorized). This clears the wedged content bridge at the gateway level. stop/start of the profile BEFORE the restart only reproduces the zombie (`pid: null`) and does not fix content reads.
   - Completion: gateway is back up (check uptime via `session_status`).

3. Stop then start the profile: `browser stop <profile>` then `browser start <profile>`. The start must report a real `pid` (non-null, e.g. 14996) — that is the signal the profile was actually recycled, not left as a zombie.
   - Completion: `browser start` returns `pid` non-null and `cdpReady: true`.

4. Verify content reads work: navigate to a simple page, then read `browser text`. It must return actual page text (not a timeout, not "tab not found").
   - Completion: a `text` read returns real content.

## Pitfalls

- stop/start alone (without the gateway restart) leaves the profile a zombie (`running: true, pid: null`) and content stays broken. Restart first.
- A clean stop/start empties the tab list (old tabs close), but cookies/session persist in the profile user-data dir — re-open the target page (Seller Central, Gmail) and the login survives.
- A single `text` timeout is not proof of the wedge; tabs/status working while content consistently times out is.

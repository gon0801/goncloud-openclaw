---
name: gateway-stability-diagnosis
description: Diagnose a slow, frozen or apparently self-restarting OpenClaw gateway — mobile/app connections dying with code=1006, "connection refused"/timeouts, RPCs taking seconds, liveness heartbeat delays, or a restart count that looks alarming. Use when the gateway is suspected of freezing or restarting in a loop, before any gateway maintenance or restart, and when a message must not carry an unverified number. Produces the freeze verdict with evidence, the day's real restart list with its causes, and the supported levers — read-only, no state changed.
---

# Gateway Stability Diagnosis

Tell a freezing gateway from a network fault, and a config-driven restart from a watchdog one, before changing anything. Verified 2026-09-16 on the Windows gateway host (OpenClaw 2026.9.3, 8 GB RAM).

## Steps

1. Split reachability from health. Confirm the client reaches the gateway, then measure the gateway's own response:
   - `curl.exe -sS -o NUL -w "%{http_code}" --max-time 8 http://<addr>:18789/` → 200 means the listener answers.
   - `openclaw gateway health`, and a timed `openclaw sessions list --agent main --limit 5` (`Measure-Command`, or a stopwatch around it).
   A listener that answers while `health`/`sessions list` take seconds is a slow or frozen gateway, not a connectivity problem.
   - Completion: you can state whether the gateway answers, and how fast.

2. Read the freeze signature in the gateway log (`C:\Users\ehven\AppData\Local\Temp\openclaw\openclaw-<date>.log`):
   - `liveness heartbeat delayed ... overdue=<n>ms elapsed=<30-40>s` — the event loop is blocked for tens of seconds. This is the signal that matters; it is NOT a restart.
   - `memory pressure: level=warning reason=rss_growth rss=<n> MiB heap=<n> MiB threshold=512 MiB` — the gateway past its own memory threshold.
   - `slow SQLite transaction hold` / `lock wait` — concurrent writers on the per-agent stores. Count them **inside the window you care about** (date/time-filter the lines), not the day's total.
   - `phase=ws_upgrade_started` then `closed before connect ... code=1006` naming the client's address — the client arrived and the upgrade never completed.
   - Completion: each symptom is either present with a timestamp or explicitly ruled out.

3. Tie the client's failures to the freeze, not to the network. Line up the `code=1006` timestamps against the gateway's own start time and the blocked windows:
   - closes inside a blocked window, with the process up the whole time → the freeze is the cause;
   - closes right after a start → the restart is the cause.
   Before blaming a tunnel, prove or clear it: `ping -M do -s 1400 -c1 <peer>` from the server side plus the MTU at both ends (expect 1420 on a WireGuard tunnel). A route that passes large packets is not the problem.
   - Completion: the verdict names freeze or restart, with the timestamps behind it.

4. Count restarts correctly — an alarming number is usually a measurement error. `openclaw\logs\gateway-restart.log` **accumulates across days** (no per-day filter), so counting its `restart attempt` lines inflates today's total. Count the day's real restarts in the gateway log instead: `http server listening` (a process start) and `received SIGUSR1` / `forced restart requested; skipping active work drain`.
   Then name each cause: a restart following a config edit (`config change requires gateway restart (<path>)`) is self-inflicted (deferral/force mechanic in `openclaw-config-patch`); `liveness` lines never escalated to restarts here.
   - Completion: you can state the day's real restart count, each one's trigger, and whether any was watchdog-driven.

5. Collect the supported levers before proposing anything — read them, do not improvise: `openclaw gateway stability` and `openclaw gateway diagnostics` (read-only), `openclaw gateway restart` (the supported restart), `openclaw sessions cleanup --all-agents --dry-run` (safe preview), `openclaw sessions archive|compact|delete`, and `openclaw backup sqlite` (create/list/verify/restore) as the required snapshot before any store change.
   - A dry-run is cheap and decisive: on 2026-09-16 it reported 16 kept / **0 pruned**, which ruled out age/count retention entirely — the freeze was memory/event-loop load, not accumulated sessions.
   - Completion: every lever you intend to use is confirmed present in `--help`, and a snapshot path exists for anything destructive.

6. Report; do not act. The deliverable is the freeze verdict, the real restart list, and the levers. Store or gateway maintenance is a separate owner-approved step; if a restart is needed, check `openclaw cron list --all` for a `running` job first (a restart kills in-flight runs — recover them with `automation-run-recovery`).
   - Completion: the owner has the verdict, the causes and the proposed window; no state was changed.

## Pitfalls

- Reporting the `gateway-restart.log` line count as "restarts today" is wrong and reached the owner as a wrong number on 2026-09-16 (17 reported, 3 real). Count starts (`http server listening`) and `SIGUSR1` in the dated gateway log.
- "Gateway refused the connection" from a mobile app is not a refusal by the transport: an upgrade that starts and dies with `code=1006` means the gateway was blocked or absent at that instant. Checking the VPN first sends the whole diagnosis the wrong way.
- One blocked window explains a burst of unrelated-looking failures (RPC latency, dead WebSockets, delayed heartbeats). Look for the shared window before opening three separate investigations.
- Elevated exec is denied for chat-sourced sessions (`tools.elevated.allowFrom`); do not plan a fix that depends on it.
- Do not restart or reconfigure the gateway to "clear" a freeze while the owner is waiting on an answer: a restart aborts the turn that is mid-diagnosis, and the state you were measuring is gone.

---
name: gateway-doctor-fix
description: Run openclaw doctor --fix on the Windows gateway host from the agent. Use when doctor --fix fails with "running inside the gateway process tree" or "schtasks disable failed: Access is denied", or before attempting gateway maintenance repairs. Produces applied fixes verified in a completion log, or the exact owner-run instruction when elevation is unavailable.
---

# Gateway Doctor --fix (Windows host)

`openclaw doctor --fix` enters maintenance mode (it may stop/restart the gateway). From the agent it hits up to three independent blockers. Fast path: if exec elevation is already known unavailable (step 3) and the owner is reachable, skip straight to step 4 — steps 1–2 only re-confirm the blockers. Verified 2026-09-10 on the Windows gateway host (OpenClaw 2026.9.3); the three failure modes below are tool-evidenced, the owner-run path is the doctor's stated requirement.

## Steps

1. Never retry `doctor --fix` through a plain agent exec or any process the gateway spawned: the doctor refuses to manage the gateway that owns it — "This command is running inside the gateway process tree (gateway PID …)". Read-only `openclaw doctor` from exec works fine and is the tool to list pending fixes before and after.
   - Completion: direct exec is ruled out for --fix; you know the pending fixes from a read-only run.

2. A detached run via Task Scheduler passes the process-tree check (task parent is the scheduler service), but doctor's maintenance then calls `schtasks disable` on the root-folder tasks `\OpenClaw Gateway`, `\OpenClaw Gateway Watchdog`, `\OpenClaw CUA Node` — registered with admin rights — so a non-elevated run dies with "Doctor could not enter maintenance. Error: schtasks disable failed: ERROR: Access is denied." That error appears only in the run log; `schtasks /run` itself reports SUCCESS regardless.
   - Working mechanic: write a .ps1 calling the full path `C:\Users\ehven\AppData\Roaming\npm\openclaw.cmd doctor --fix --non-interactive --yes *> <log>`, append a `DONE_EXIT_<code>` marker line, then `schtasks /create /tn <name> /sc once /st 23:59 /tr "powershell -NoProfile -ExecutionPolicy Bypass -File <ps1>" /f` + `schtasks /run /tn <name>`; read the log after a bounded wait for the marker.
   - Completion: the log shows whether the run reached maintenance or died on permissions.

3. Elevation check: agent exec with `elevated: true` is denied for Telegram-sourced sessions by policy (`tools.elevated.allowFrom` failing gate). Creating an `/rl HIGHEST` task also needs an elevated shell. Do not push to weaken the policy; state the tradeoff only if the owner asks for the option.
   - Completion: elevation available → redo step 2 elevated; unavailable → step 4.

4. Owner-run resolution (independent + admin shell, exactly what the doctor requires): have the owner run, in an elevated PowerShell on the gateway host:
   `openclaw doctor --fix --non-interactive --yes`
   - Completion: a later read-only `openclaw doctor` no longer lists the pending fixes (e.g. legacy session row, model auto-enable, heartbeat cadence).

5. Clean up: delete the temp task (`schtasks /delete /tn <name> /f`) so the leftover one-shot entry cannot fire at its scheduled time; keep the log as evidence, remove or consciously keep the .ps1.
   - Completion: no leftover scheduled task named by this procedure.

## Pitfalls

- A successfully created and launched scheduled task is not a successful fix — only the log's `DONE_EXIT_0` plus applied-fix lines are; exit 1 with the Access-denied text means the run never touched state.
- `--non-interactive` restricts to safe migrations; `--yes` accepts defaults; both verified accepted together with `--fix`.
- Maintenance may restart the gateway, killing in-flight agent turns (the Watchdog task restarts it automatically). Check no packing/automation job is due before launching, and expect the current turn to blink.
- The doctor's `--help` lists no maintenance-skip flag; there is no supported agent-side path around the privilege requirement on this host.

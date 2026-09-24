---
name: browser-cli-claw-profile
description: Rules for driving the claw browser from exec — correct CLI flag, one driver session at a time (no fan-out to helpers), 60 s timeouts on Windows, and what the misleading "requires credentials" error really means. Use before running any `openclaw browser` command or handing browser work to another session, or when a browser command fails with "gateway browser.request requires credentials before opening a websocket" and a `Config:` path inside a `.openclaw-<name>` folder, or exits 1 with no output.
---

# Browser CLI: `--browser-profile claw`, never the global `--profile`

Why (2026-09-11): the global flag made every browser command "ask for a key"; the agents chased a gateway key that was never missing, and the unneeded gateway restart killed the 11h extras run.

## Rules

1. Pick the browser profile with `--browser-profile claw`, e.g. `openclaw browser --browser-profile claw tabs --json`.
   A tool-style hint such as `action=reset-profile profile=claw` translates to the CLI flag `--browser-profile claw`.
2. The bare `--profile <name>` is the GLOBAL OpenClaw option: it moves the whole CLI to `~/.openclaw-<name>` (state and config).
   `~/.openclaw-claw` has no gateway settings, so the command fails with "gateway browser.request requires credentials before opening a websocket" and `Config: C:\Users\ehven\.openclaw-claw\openclaw.json`.
<!-- candado: test-browser-profile-flag.sh -->
3. That error with a `Config:` path inside `.openclaw-<name>` is a wrong flag, not a missing key: fix the command and retry.
   Do not touch `gateway.auth`, do not create `~/.openclaw-claw`, do not ask the owner for a key, do not restart the gateway for it.
4. NEVER run `reset-profile` on `claw`: it moves the profile's browser data to Trash and wipes every logged-in session (Seller Central, Seller Flex, Gmail, Mercado Libre).
<!-- candado: test-browser-profile-flag.sh -->
   For "Port 18801 is in use for profile claw but not by openclaw", an owner-authorized gateway restart re-adopted the running browser (afterwards `tabs` listed the 4 tabs and `evaluate` read Seller Central).
   Before asking for any restart, check that no cron job runs in the next 15 minutes.
5. Recognize the managed browser from the OS side (2026-09-12): an `msedge.exe` window titled "<pages> - claw - Microsoft Edge" (`Get-Process msedge | Select-Object Id,MainWindowTitle`) IS the OpenClaw-managed claw profile — the standard Edge User Data dir has no "claw" profile (`Local State` → `profile.info_cache` lists only Default). Before any gateway browser task, run `openclaw browser --browser-profile claw tabs` first: the session you need may already live there. Never `taskkill /IM msedge.exe` to get a "clean" browser — that kills the managed browser and the owner's tabs; a graceful kill also leaves background msedge PIDs alive anyway.
   - Completion: you know which browser holds the target session before touching any msedge process.

6. One session drives the claw browser at a time: the session that owns the task. Never split browser work across sessions or fan it out to helpers, and never touch the browser while a session you dispatched or spawned could still be on it: a sub-agent that times out leaves its own children running.
<!-- candado: test-browser-profile-flag.sh -->
   Why: at 7:33 PDT on 2026-09-11 operaciones and an orphaned sub-agent drove the same tab at once (one navigating, one reading) and the gateway lost track of the running Edge.
7. On the Windows gateway host every exec of the browser CLI needs `timeoutSeconds >= 60`: the CLI alone takes 10-23 s to start, so a 15-20 s timeout kills it before it connects.
   That shows up as exit code 1 with no output, not as a browser failure. Rerun a read-only command once with the longer timeout; before repeating an action, check `tabs` first.
8. If `tabs` responds but `evaluate`/`navigate`/`screenshot` consistently time out (wedged bridge after a gateway restart), stop retrying browser actions: report the browser limit and reroute through ssh, whose approval passes independently.
9. A gateway restart does not reliably restore the profile registration: after the 2026-09-16 04:54 restart the CLI still answered "Profile claw not found" and `create-profile` stayed refused over the node proxy, while the managed Edge was alive the whole time. The run finished on raw CDP at 127.0.0.1:18801 (read-only, Seller Central/Flex sessions intact). In that state raw CDP is a read-only exception: list tabs, read page text/DOM and take screenshots only — no navigate, click, type, form submit or state-changing `evaluate`; anything that must change state waits until the registration is back. Report the missing registration — do NOT `reset-profile` (rule 4) and do NOT kill msedge to force a re-registration.
<!-- candado: test-browser-profile-flag.sh -->

## Completion check

- `openclaw browser --browser-profile claw tabs --json` lists the open tabs.
<!-- candado: test-browser-profile-flag.sh -->

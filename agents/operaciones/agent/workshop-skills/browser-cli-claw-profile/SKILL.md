---
name: browser-cli-claw-profile
description: Correct CLI flag for the claw browser profile, and what the misleading "requires credentials" browser error really means. Use before running any `openclaw browser` command through exec, or when one fails with "gateway browser.request requires credentials before opening a websocket" and a `Config:` path inside a `.openclaw-<name>` folder.
---

# Browser CLI: `--browser-profile claw`, never the global `--profile`

Why (2026-09-11): the global flag made every browser command "ask for a key"; the agents chased a gateway key that was never missing, and the unneeded gateway restart killed the 11h extras run.

## Rules

1. Pick the browser profile with `--browser-profile claw`, e.g. `openclaw browser --browser-profile claw tabs --json`.
   A tool-style hint such as `action=reset-profile profile=claw` translates to the CLI flag `--browser-profile claw`.
2. The bare `--profile <name>` is the GLOBAL OpenClaw option: it moves the whole CLI to `~/.openclaw-<name>` (state and config).
   `~/.openclaw-claw` has no gateway settings, so the command fails with "gateway browser.request requires credentials before opening a websocket" and `Config: C:\Users\ehven\.openclaw-claw\openclaw.json`.
3. That error with a `Config:` path inside `.openclaw-<name>` is a wrong flag, not a missing key: fix the command and retry.
   Do not touch `gateway.auth`, do not create `~/.openclaw-claw`, do not ask the owner for a key, do not restart the gateway for it.
4. NEVER run `reset-profile` on `claw`: it moves the profile's browser data to Trash and wipes every logged-in session (Seller Central, Seller Flex, Gmail, Mercado Libre).
   For "Port 18801 is in use for profile claw but not by openclaw", an owner-authorized gateway restart re-adopted the running browser (afterwards `tabs` listed the 4 tabs and `evaluate` read Seller Central).
   Before asking for any restart, check that no cron job runs in the next 15 minutes.

## Completion check

- `openclaw browser --browser-profile claw tabs --json` lists the open tabs.

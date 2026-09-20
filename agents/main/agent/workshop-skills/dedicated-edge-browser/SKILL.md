---
name: dedicated-edge-browser
description: Use Claw's own Edge browser on the Windows gateway — the persistent-session browser (CDP port 18803, user-data-dir .openclaw\browser-claw) seeded with Monday, Claude, Amazon, MercadoLibre and Gmail. Use for any gateway browser task on those accounts, when the owner says "mi navegador / tu navegador", when that window is not running, or when a hand-declared OpenClaw browser profile reports "Profile not found". Produces a running CDP-controllable Edge with live sessions.
---

# Claw's Dedicated Edge Browser (gateway PC)

The gateway's own browser for tasks needing a persistent login: one dedicated Edge instance with its own user-data-dir. The owner seeded its sessions once (2026-09-12) and they persist across window closes. Drive it over CDP with puppeteer-core — install, `node -e` and PowerShell pitfalls are the same as `gateway-edge-cdp` steps 2–3.

## Steps

1. Ensure it is running. `Invoke-WebRequest http://127.0.0.1:18803/json/version` returning Edge JSON = live. If down, launch it (never taskkill anything for this — it has its own user-data-dir):
   `Start-Process "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ArgumentList "--user-data-dir=C:\Users\ehven\.openclaw\browser-claw","--remote-debugging-port=18803","--no-first-run","<url>"`
   If the owner must act in the window (login, 2FA), it must be visible on the gateway desktop: bring it to front with user32 `ShowWindowAsync(hWnd, 9)` + `SetForegroundWindow(hWnd)` over the msedge processes that have a MainWindowHandle (Add-Type snippet; verified the window appears and takes focus).
   - Completion: `/json/version` returns the browser JSON, and the window is foregrounded when the owner must act in it.
2. Confirm the session you need before asking anyone to log in: count cookies per domain with a puppeteer `Storage.getCookies` probe. Seeded 2026-09-12 (cookie counts at seeding: monday 39, claude 19, amazon 18, mercadolibre 38, google 73; `anthropic` 0 — Claude stores under `claude.ai`). A site login wall means that site's own session expired — ask the owner to log in once in this window, never for a password in chat.
   - Completion: the task's domain has cookies, or the owner has just seeded/expired-and-renewed it.
3. Work the task with `.js` puppeteer scripts. For a Monday group export, `gateway-edge-cdp/monday-export.md` applies unchanged over this port (verified with "Septiembre 2026"). For sending a file by email, `gmail-attachment-send.md` in this folder. To read a claude.ai artifact tab whose body will not load (blank shell, puppeteer methods hang on it), read `claude-artifact-read.md` in this folder before any retry.
   - Completion: the task's own artifact (downloaded file, sent mail) is verified.
3b. For a `claude.ai/artifact` URL (or any page whose content renders inside a cross-origin iframe), the puppeteer paths in step 3 fail to reach the content: read `claude-artifact-read.md` for the raw-WebSocket `Target.attachToTarget` procedure that does.

## Pitfalls

- This profile is separate from the owner's everyday Edge (standard User Data dir) and from the `claw` managed profile (port 18801). Launching it touches nothing else; conversely, **ask the owner before any `taskkill` of Edge** — on 2026-09-12 he objected to a silent Edge restart that dropped his open Monday tabs.
- "Mi navegador / tu navegador" is ambiguous between this browser and the owner's everyday default-profile Edge. When the owner says "mi Edge" with a distinct trait (tab count, window feel), confirm which one before driving or restarting: on 2026-09-14 "mi edge, unas 52 pestañas" meant his default-profile Edge (CDP route via `gateway-edge-cdp`), not this dedicated browser.
- The config route does not work (verified 2026-09-12, do not retry it): `create-profile` is refused with "browser.request cannot mutate persistent browser profiles over a node proxy", and a hand-declared `browser.profiles.pc` (driver openclaw, cdpPort, executablePath) applied via `openclaw config patch` survived an owner gateway restart yet the CLI still reported "Profile pc not found" (it lists only openclaw/user/chrome). The direct launch (step 1) is the working route.
- The default `openclaw` managed profile routes to the **Mac's** Edge over a node proxy: tabs created there appear in the Mac's Edge (verified twice by AppleScript tab listing) and `browser status` shows a macOS `detectedPath`. It is not a gateway browser.
- Chromium CDP endpoints answer 404 without an explicit `--user-data-dir` (see `gateway-edge-cdp` step 2) — this browser sets one by construction; every relaunch must keep it.

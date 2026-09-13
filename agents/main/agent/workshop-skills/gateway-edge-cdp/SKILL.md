---
name: gateway-edge-cdp
description: Drive the owner's default-profile Edge on the Windows gateway host over CDP. Use when a browser task targets a session living in the gateway's default Edge profile (not the claw managed browser), when Edge's DevTools port listens but answers 404, or when chrome-mcp/extension browser profiles fail to attach. Produces a puppeteer-controllable Edge with the target tab listed. For exporting a Monday board group to Excel over that connection, read monday-export.md after step 3.
---

# Gateway default-profile Edge over CDP

Fallback for driving Edge on the Windows gateway host when the target session is in the **default** Edge profile and `computer` cannot reach it (the only computer-capable node is the Mac). Verified 2026-09-12: Edge 153 relaunched with an explicit `--user-data-dir` accepted the DevTools port; `puppeteer-core` connected and drove pages.

## Steps

1. **Check the seeded dedicated browser and the claw managed browser first** — they are the usual homes of task-relevant sessions on this host. The dedicated Edge (persistent sessions: Monday, Claude, Amazon, MercadoLibre, Gmail; CDP 18803) is the standing route for those accounts — use the `dedicated-edge-browser` skill and stop. An `msedge.exe` window titled "<pages> - claw - Microsoft Edge" (`Get-Process msedge | Select-Object Id,MainWindowTitle`) IS the OpenClaw-managed claw browser. If `openclaw browser --browser-profile claw tabs` lists the target tab or the site's session, drive it through the browser CLI (`browser-cli-claw-profile` skill) and stop — never attach CDP for it. A bare `--profile <name>` here re-triggers the documented credentials trap ("gateway browser.request requires credentials", `Config:` inside `.openclaw-<name>`).
   - 2026-09-12: a "Monday in Edge" task sent the agent down the CDP path while the target tab ("Pedidos Arras Mx") was open in the claw browser the whole time.
   - Completion: dedicated-browser and claw tabs checked, and the dedicated-vs-claw-vs-default-Edge decision is explicit.
2. Restart Edge with the debugging port **and an explicit `--user-data-dir`**. On current Chromium (verified Edge 153), launching with only `--remote-debugging-port=9222` on the default user-data dir leaves the HTTP endpoints dead: the port listens (`netstat` shows msedge LISTENING on 9222) but `/json`, `/json/version`, `/json/list` all answer 404. Passing the same default path explicitly (`--user-data-dir=C:\Users\<user>\AppData\Local\Microsoft\Edge\User Data`) plus `--restore-last-session` makes the endpoints live.
   - Sequence: `taskkill /F /IM msedge.exe`, wait ~3 s, `Start-Process msedge.exe -ArgumentList '--restore-last-session','--remote-debugging-port=9222','--user-data-dir=C:\...\User Data'`, wait ~8 s.
   - **This force-kill also kills the claw managed browser and its tabs.** Do it only when the gateway-host browser task was explicitly requested and the target session is genuinely in the default profile; afterwards re-run `--browser-profile claw tabs` and, if the gateway lost the claw browser, an owner-authorized gateway restart re-adopts it (see `browser-cli-claw-profile` rule on re-adoption).
   - Completion: `(Invoke-WebRequest http://127.0.0.1:9222/json/version).Content` returns the browser JSON.
3. Drive it with `puppeteer-core` (`npm install puppeteer-core` in `$env:TEMP\cdp`, scripts as .js files — never `node -e` under PowerShell) connecting via `puppeteer.connect({ browserURL: 'http://127.0.0.1:9222', defaultViewport: null })`. Reuse an existing tab (`browser.pages()`) before opening new ones.
   - Completion: a script lists tabs (`url` + `title`) including the target site.
   - Monday-specific export flow (group menu → "Exportar a Excel" → confirm dialog → GUID download file): read `monday-export.md` in this folder.
4. Judge the session **in the profile that owns the target tab**. A login wall in the default Edge does not prove the session is gone elsewhere — on 2026-09-12 Monday showed its login page in the default profile while the claw browser, which held the board tab, was never re-checked after the kill; "no hay sesión" was reported to the owner from the wrong browser. If the claw check (step 1) was skipped or invalidated by the restart, re-check claw before asking the owner to log in. When a login really is needed, ask the owner to log in once in that browser; never ask for the password in chat.
   - Completion: the session state claim names the profile it was verified in.

## Pitfalls

- `openclaw browser --browser-profile user` / `--profile chrome` (chrome-mcp / extension transports) do NOT attach to the owner's Edge on this host: both fail with "Could not connect to Chrome" / credentials errors, and writing a gateway-auth SecretRef into `~/.openclaw-<name>/openclaw.json` does not resolve in that command path. CDP is the working route for the default profile; the claw profile needs no CDP at all.
- `app.<site>.com`-style hosts may have no A record at all (verified: DoH query for `app.monday.com` returns Status 0 with only an SOA Authority — the app lives on `<account>.monday.com`). Before diagnosing DNS, query `https://1.1.1.1/dns-query?name=<host>&type=A` with header `accept: application/dns-json` and read the Answer section; a login-wall on the marketing site is the likelier cause of "the site is down".
- After a forced Edge restart, `--restore-last-session` may restore only the welcome tab — do not assume the target page came back.

# Read a claude.ai artifact open in the dedicated Edge (CDP)

Recovery for the case where the artifact tab is open and titled in the dedicated Edge (port 18803) but its content cannot be read. Verified 2026-09-15: Claude renders the artifact body inside a cross-origin iframe (`<uuid>.frame.claudeusercontent.com`), and puppeteer's page-level methods on that tab never return — `page.screenshot()`, `page.setViewport()`, even `Runtime.evaluate` through puppeteer and `page.close()` all hung until killed (40–70 s each). The outer page's own `innerText` is only the shell (measured 133 chars: title, "Translate", "Artifacts are private by default…").

Skip puppeteer for this tab entirely. Work raw CDP over the `/json/list` WebSocket (small `.js` script with `require('http')`):

1. `GET /json/list` → find the tab whose `url` contains `claude.ai/artifact`; take its `webSocketDebuggerUrl`.
2. Connect a WebSocket to it. On Node ≥22 the global `WebSocket` exists but is the browser-style API — use `addEventListener('open'/'error'/'message')`, never `ws.on(...)` (verified: `ws.on is not a function`).
3. `Target.getTargets` → take the target with `type: "iframe"` and `url` containing `claudeusercontent`.
4. `Target.attachToTarget {targetId, flatten: true}` → this call returns `sessionId`; pass that `sessionId` on every subsequent call.
5. `Runtime.evaluate {expression: 'document.body.innerText', returnByValue: true}` **with the iframe sessionId** → the complete artifact body (measured 13.7k chars of clean text, checklist items included).
   - Completion: text length in the thousands and it contains artifact content, not the 133-char shell.
6. Screenshot: `Page.captureScreenshot` works on the tab's own session (step 1–2 socket with no sessionId) — but on the iframe's balanced session it errors `-32000 "Command can only be executed on top-level targets"`. Screenshot the tab, not the iframe.

## Script hygiene

- Wrap every CDP call in its own timeout and add a hard process timer that exits with a log line; append a log line per step to a small file. Without this, a hung call produces no output at all and you cannot tell connect from call failure.
- To close a hung artifact tab, skip puppeteer (`page.close()` hangs too): `curl.exe -s http://127.0.0.1:18803/json/close/<targetId>` returns "Target is closing"; confirm with `/json/list`.
- To see every sub-target (which is how you discover the iframe), one-off: `Target.getTargets` over the tab socket and print `type` + `url` per target.

## Reading order

Use this after the normal tab check of `dedicated-edge-browser` steps 1–2 (port live, Claude domain has cookies). `gateway-edge-cdp` steps 2–3 pitfalls (explicit `--user-data-dir`, scripts as `.js` files next to their `node_modules`, `curl.exe -s` for CDP HTTP checks) apply unchanged.

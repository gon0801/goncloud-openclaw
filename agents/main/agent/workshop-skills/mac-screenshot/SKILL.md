---
name: mac-screenshot
description: "Screenshot David's Mac and deliver it to chat. Use when asked for an 'ss', screenshot, or to see the Mac's screen; repeating black captures. Wakes the sleeping display first, verifies content and PNG integrity end-to-end, transfers via the gonserver scp relay."
---

# Mac Screenshot (David's MacBook Pro)

Capture the Mac screen, verify it is real content (not black, not corrupt), and deliver it through the gateway. Verified 2026-09-14: the trap that wasted several round trips was the black capture from a sleeping display, plus a relay that double-encoded the PNG.

## Steps

1. Wake the display before capturing, from `exec host=node` ("David's MacBook Pro"):
   `caffeinate -u -t 8` then wait ~2 s.
   A capture whose size is small (~39 KB at 1080p) and identical across recaptures means the display was asleep — that is not a permissions problem. Wake it instead of diagnosing screen-recording permissions or displays.
   - Completion: identity of the display state confirmed; only 1 display exists on this Mac (`screencapture -x -D 2` fails as invalid, expected).

2. Capture and size-check in the same call:
   `screencapture -x /tmp/<name>.png && stat -f%z /tmp/<name>.png`
   - Completion: file exists with a non-trivial size (<~100 KB at 1080p almost certainly means black). If still small, re-wake with `caffeinate -u -t 8` and recapture once; if it stays black after a confirmed wake, report it instead of looping.

3. Transfer by scp through the gonserver relay (both machines have the `gonserver` alias) — do NOT pipe the image through a Terminal relay:
   - On the Mac: `scp /tmp/<name>.png gonserver:/tmp/<name>.png`
   - On the gateway: `scp gonserver:/tmp/<name>.png "<workspace>\media\<name>.png"`
   - Verify integrity on the gateway: header bytes `89 50 4e 47` and size equal to the Mac side.
   - **Do not double-encode**: `.b64`/`.png` intermediates from a past relay can already be base64 text (header reads ASCII `iVBORw0KGgo`). `base64 -d` the odd file once before pushing, or recapture — scp is clean end to end.
   - Completion: gateway file with valid PNG header and the Mac-side size.
4. Attach with a `MEDIA:<gateway-path>` line, keep the gateway copy in place, and confirm receipt with the user in the next exchange before any cleanup (do not delete in the same turn). Delivery record 2026-09-14: valid-PNG MEDIA lines were received and confirmed multiple times — a failure to arrive has so far tracked with an invalid/black capture, not with the delivery mechanism (details in `mac-node-file-transfer` pitfalls).

## Capturing a specific browser tab (not just the full screen)

When the request names a specific tab (e.g. "session de opencode-go"): full-screen capture alone is not a verified answer. (1) Locate the tab first — `osascript` tab listing on the Mac or a CDP `/json` listing; profiles' windows only appear under their own process. (2) Bring the target Edge to front with `osascript -e 'tell application "Microsoft Edge" to activate'` and set the active tab before capturing. (3) If the tab is no longer open, recover its URL from the Edge `Sessions/` files (see the related pitfall entry in `gateway-edge-cdp`) and reopen it via CDP before capturing. (4) Then run this skill's wake → capture → scp → verify → MEDIA flow. Completion: the screenshot shows the named tab, not merely some Edge window.

## Reference

- Terminal/tab control and TUI delivery on the Mac: `mac-terminal-control`.
- File-transfer decision tree and fallbacks: `mac-node-file-transfer`.

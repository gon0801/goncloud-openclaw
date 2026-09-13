---
name: gateway-to-mac-mail-attachment
description: Send an email with a gateway-side file attached from the owner's Mac Mail app. Use when a task says "mándalo por Mail" and the file (export, report, screenshot) lives on the Windows gateway while the Mail app with the owner's account is on the Mac node, or when Gmail web has no session in the browser you control. When the gateway's dedicated Edge (port 18803) has the Gmail session, prefer `dedicated-edge-browser/gmail-attachment-send.md` instead — same send, no Mac hop. Produces a sent email with the attachment.
---

# Gateway → Mac Mail Attachment

Send a gateway-local file as an email attachment through Mail.app on the Mac node. Verified 2026-09-12: a Monday board group exported on the gateway (see `gateway-edge-cdp`) was pushed to the Mac over Tailscale and mailed to the owner's recipient.

## Steps

1. Route check first (2026-09-12): if the gateway's dedicated Edge (port 18803) holds a Gmail session, do not hop through the Mac — use `dedicated-edge-browser/gmail-attachment-send.md`. This skill is the Mac Mail route. Confirm the file on the gateway with a non-zero size, and check whether the browser you control has a Gmail session (`mail.google.com` redirecting to `accounts.google.com` = no session). No Gmail session and no SMTP config means Mail.app is the route.
   - Completion: gateway path + size recorded; route decided.
2. Serve the file over the tailnet and pull it from the Mac:
   - Write a node `http.createServer(...).listen(18888, '0.0.0.0')` script (in a `.js` file under `$env:TEMP\cdp`) and run it as a background exec. A PowerShell `HttpListener` with an IP prefix fails with "Access is denied" (URLACL) — node needs no reservation.
   - On the Mac (`exec host=node node="David's MacBook Pro"`): `curl -sS -o ~/Downloads/<name> --max-time 60 http://100.80.179.76:18888/<name>` (100.80.179.76 is the gateway's tailnet IP). Verify the size matches (`ls -la`).
   - Completion: same byte count on both sides. Stop the server process afterwards.
3. Compose and send via AppleScript — build the message by setting properties one by one; `make new outgoing message with properties {subject:..., body:...}` throws `-1700`:
   ```applescript
   tell application "Mail"
     set msg to make new outgoing message
     set subject of msg to "Monday"
     set content of msg to "prueba Monday"
     tell msg
       make new to recipient at end of to recipients with properties {address:"areli.arista.m@gmail.com"}
       make new attachment with properties {file name:POSIX file "/Users/dn/Downloads/<name>"} at after the last paragraph
     end tell
     send msg
   end tell
   ```
   Use the recipient and subject/body the owner specified for this task; an odd transcription (typo in the body spec) is worth one clarifying question before sending.
   - Completion: osascript returns without error (exit 0 / `true`).
4. Report what was sent (recipient, subject, attachment, source of the data). Delivery proof beyond the `send` returning is not yet verified on this host — Mail syncs in the background; offer to check Sent if the owner asks.
   - Completion: the owner knows what went out and any body-text substitution you made.

## Pitfalls

- Ask before sending to a new external address the owner has not named in the same request; here the owner named the recipient explicitly.
- `exec host=node` AppleScript can fail with transient `COMPANION_APP_UNAVAILABLE` (see `mac-terminal-control`): retry before declaring the Mac unreachable.
- The attachment property is `file name` with a POSIX path, and `at after the last paragraph` — placing it before any body text is set can drop it from the draft.

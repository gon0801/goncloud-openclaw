---
name: "mac-input-control"
description: "Control David's Mac keyboard/mouse from gateway exec host=node via System Events (no cliclick). Type keys, click, activate apps; verify with screenshot."
---

# Mac Keyboard & Mouse Control (David's MacBook Pro)

Drive David's Mac keyboard and mouse remotely from gateway `exec` calls with `host=node`. Verified live 2026-09-14: keystrokes and clicks both work through System Events (`osascript`); `cliclick` and Homebrew are NOT installed on this Mac, so use System Events.

## Steps

1. Wake the display first if the Mac may be idle: `caffeinate -u -t 4`, wait ~1 s.
   Completion: a quick capture is not tiny/solid-black (compare `mac-screenshot` size rules).

2. Activate the target app so input lands in it:
   `osascript -e 'tell application "Microsoft Edge" to activate'`, wait ~1 s.
   Completion: app is frontmost or the expected window id is active.

3. Keyboard — inside `tell application "System Events"`:
   - Type text: `keystroke "hello"`; add modifiers: `keystroke "p" using {command down}`.
   - Special keys: `key code 53` = Esc, `36` = Return, `48` = Tab.
   Completion: verified by a follow-up screenshot, never by trusting the silent "ok" return.

4. Mouse — inside `tell application "System Events"`:
   `click at {x, y}` uses screen coordinates (1920x1080; single display only).
   Completion: verify with a screenshot; if the click seems swallowed, re-activate the app and retry once.

5. Report with evidence: attach the post-action screenshot via a `MEDIA:` line. Never claim a click/keystroke worked without the visual check (unknown-outcome rule in AGENTS.md).

## Pitfalls

- Do not trust `tell app "System Events" to tell process "X"` for window truth: on 2026-09-14 it reported Edge `windows=0` while `tell application "Microsoft Edge"` saw the window fine. Ask the app itself, not its process entry.

## Reference

- Screenshot verification pipeline: `mac-screenshot`.
- Reading/typing into Terminal tabs: `mac-terminal-control`.

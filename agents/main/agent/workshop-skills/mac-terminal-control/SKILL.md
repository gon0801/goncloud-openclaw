---
name: mac-terminal-control
description: Operate David's Mac (macOS node "David's MacBook Pro") to read or type into Terminal tabs. Use when asked to see or control what's running in a Terminal window, or when node permissions/osascript behave unexpectedly. Produces the tab→tty map, the correct osascript calls, and the permission-state decision rules.
---

# Mac Terminal Control (David's Mac)

Drive Terminal.app and the macOS node via read-only `exec host=node` plus `osascript`, and resolve the permission-state confusion. Verified 2026-09-09 on node "David's MacBook Pro" (macOS 26.6.0, user `dn`).

## Steps

1. Run read-only shell on the node: `exec` with `host="node"` and `node="David's MacBook Pro"`. Plain shell commands (ps, lsof, find, cat, tail) work this way; they do not need the macOS companion app.
   - Completion: shell output returns.

2. List Terminal windows/tabs and their ttys with osascript:
   ```applescript
   tell application "Terminal"
     set out to ""
     repeat with i from 1 to count of windows
       repeat with j from 1 to count of tabs of window i
         set out to out & "win " & i & " tab " & j & " | tty=" & (tty of tab j of window i) & " | title=" & (custom title of tab j of window i) & linefeed
       end repeat
     end repeat
     return out
   end tell
   ```
   This yields the `win → tab → tty → title` map (e.g. `win 1 tab 1 | tty=/dev/ttys005 | title=…`). Cross-reference `ps -o pid,tty,stat,command -p <pid>` to know which tab hosts which process.
   - Completion: you have the tab→tty→title map and know which tty each agent process lives on.

3. Select a specific tab (correct syntax — the `set selected of window … to tab …` form fails with `-1700`):
   ```applescript
   tell application "Terminal" to activate
   tell application "Terminal" to set selected of tab N of window W to true
   ```
   - Completion: the target tab is selected without an AppleScript error.

4. Type into the focused terminal (if the task is to send input):
   ```applescript
   tell application "System Events" to keystroke "<text>"
   tell application "System Events" to key code 36
   ```
   - Completion: `osascript` exits 0. Note: exit 0 only proves the keystroke was dispatched, NOT that a running TUI (e.g. kimi-code) accepted it as input — verify by checking the agent's session log for a new turn (`grep -o '"turnId":[0-9]*' wire.jsonl | sort -n | tail -1`) before claiming the agent received the message.

## Permission-state decision rules

- `nodes describe` `permissions.appleScript: false` can be **stale**. Re-run `nodes describe` after a reconnect before concluding the user must change System Settings; observed 2026-09-09 flipping to `true` with no System Settings change, after which `osascript` worked.
- `exec` running `osascript` may return `COMPANION_APP_UNAVAILABLE: macOS app exec host unreachable` while plain shell commands still succeed — this means the macOS app's automation/companion exec host is unreachable, not that the command is blocked. Retry after the app reconnects.
- **Computer use needs a vision-capable model** (it drives screen snapshots). A non-vision model (e.g. `deepseek-v4-pro`) cannot drive it even with `tools.alsoAllow: ["computer"]` set. For text-to-terminal tasks prefer `osascript`, which needs no vision.

## Pitfalls

- `osascript` tab selection: `set selected of tab N of window W to true` (not `set selected of window W to tab N …`, which throws `-1700`).
- A keystroke `exit 0` is not delivery confirmation into a TUI; confirm a new turn in the target agent's log before reporting success.

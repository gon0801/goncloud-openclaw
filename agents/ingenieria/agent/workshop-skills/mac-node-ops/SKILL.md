---
name: mac-node-ops
description: "Operate the paired MacBook Pro OpenClaw node (exec, Mac-to-gateway file transfer, UI screenshots) when node file tools are allowlist-blocked."
---

# Mac node operations ("David's MacBook Pro")

## When

Any read, edit, transfer, or screenshot on the paired Mac node ("David's MacBook Pro", 192.168.1.126, user `dn`).

## Steps

1. Call exec with BOTH `host:"node"` and `node:"David's MacBook Pro"`. Omitting `host:"node"` silently runs the command on the Windows gateway instead (verified 2026-09-09).
2. Node file tools (`dir_list`/`dir_fetch`/`file_fetch`) are allowlist-blocked for this macOS node — do reads via node exec (`ls`, `find`, `grep`, `sed -n`).
3. Mac→gateway file transfer (file_fetch blocked; Mac has no inbound sshd):
   1. Mac: `mkdir -p /tmp/<share> && cp <file> /tmp/<share>/ && cd /tmp/<share> && (nohup python3 -m http.server 8765 >/dev/null 2>&1 &) && sleep 1 && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/<file>` (expect 200).
   2. Gateway: `curl.exe -s --max-time 25 http://192.168.1.126:8765/<file> -o <local>`; verify size and magic bytes.
   3. Mac: kill and clean immediately: `pkill -f "http.server 8765"; rm -rf /tmp/<share>`.
   Never base64 large binaries through exec output — it floods model context.
4. Screenshots — two branches:
   - Static render: headless Microsoft Edge (no Chrome app on this Mac):
     `"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" --headless=new --disable-gpu --screenshot=<png> --window-size=1440,1900 --hide-scrollbars --virtual-time-budget=3000 "file://<abs path>"` (CVDisplayLink error in output is harmless).
   - Needs a click first (select a filter, open a view): David's agent-browser CLI — `export PATH="/opt/homebrew/bin:$PATH"; agent-browser open <url>; sleep; agent-browser click '<css selector>'; sleep; agent-browser screenshot --full <png>; agent-browser close`. Works against live remote URLs too (e.g. WireGuard 10.13.13.x). /opt/homebrew/bin also has bun/uv/codex — none in node PATH, always absolute or exported.
5. UI changes: verify visually BEFORE reporting — pull the screenshot to the gateway and inspect with view_image. `open <file>` on the Mac shows the result live in David's browser.
6. Commits in David's repos: pre-commit ruff-format often reformats on the first attempt and the commit silently aborts — `git add -A` and re-commit; if push rejects (behind), `git pull --rebase origin <branch>` then push.
7. A node exec can end with `COMPANION_APP_UNAVAILABLE / outcome is unknown` while the command DID run. Before retrying, check the effects (git status, ls of expected outputs) — retrying blind double-applies edits (verified 2026-09-09).
8. Headless agent CLIs (cursor-agent, claude, kimi): invoke by absolute path — the node service runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so `which` finds nothing (verified 2026-09-09; e.g. /Users/dn/.local/bin/cursor-agent, /Users/dn/.local/bin/claude, /opt/homebrew/bin/kimi). cursor-agent in `-p` mode additionally needs `--trust` in new/untrusted directories or it exits with "Workspace Trust Required" instead of answering.

Completion check: transfer matches source size/magic; UI change confirmed in the inspected screenshot before any report.

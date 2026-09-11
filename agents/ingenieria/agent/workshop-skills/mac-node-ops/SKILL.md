---
name: mac-node-ops
description: "Operate the paired MacBook Pro OpenClaw node (exec, Mac-to-gateway file transfer, UI screenshots) when node file tools are allowlist-blocked."
---

# Mac node operations ("David's MacBook Pro")

## When

Any read, edit, transfer, or screenshot on the paired Mac node ("David's MacBook Pro", 192.168.1.126, user `dn`).

## Steps

1. Pass BOTH `host:"node"` and `node:"David's MacBook Pro"`. Never rely on omitting `host`: the configured default changes between runs (2026-09-09 it moved from the Windows gateway to the node, so a gateway command silently ran on the Mac). `host:"gateway"` is rejected with `exec host not allowed` unless the operator enables it — for gateway-side work use the file tools (`read`/`ls`/`write`/`edit`) or ask the operator.
2. Node file tools (`dir_list`/`dir_fetch`/`file_fetch`) are allowlist-blocked for this macOS node — do reads via node exec (`ls`, `find`, `grep`, `sed -n`). To reach goncloud from this node see the `goncloud-ssh-ops` skill (`ssh gonserver`, root).
3. Mac→gateway file transfer (file_fetch blocked; Mac has no inbound sshd):
   1. Mac: `mkdir -p /tmp/<share> && cp <file> /tmp/<share>/ && cd /tmp/<share> && (nohup python3 -m http.server 8765 >/dev/null 2>&1 &) && sleep 1 && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/<file>` (expect 200; a `000`/timeout means the port is taken — pick another).
   2. Gateway: `curl.exe -s --max-time 25 http://192.168.1.126:8765/<file> -o <local>`; verify size and magic bytes.
   3. Mac: kill and clean immediately: `pkill -f "http.server 876[5]"; rm -rf /tmp/<share>` (bracket one digit so the pattern does not match the pkill command line; unbracketed `http.server 8765` can kill the session).
   Never base64 large binaries through exec output — it floods model context.
   When gateway exec is unavailable (host pinned to the node) that gateway-side step cannot run, and nothing else on the gateway can fetch from the Mac/LAN: `file_fetch` is allowlisted out, the gateway browser refuses LAN/WireGuard URLs (`browser navigation blocked by policy`), and `view_image` rejects private IPs (all verified 2026-09-10). Leave the temp server up, hand the requester the exact `curl.exe -s --max-time 25 http://192.168.1.126:8765/<file> -o <gateway path>` command, and stop the server once confirmed.
4. Screenshots — two branches:
   - Static render: headless Microsoft Edge (no Chrome app on this Mac):
     `"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" --headless=new --disable-gpu --screenshot=<png> --window-size=1440,1900 --hide-scrollbars --virtual-time-budget=3000 "file://<abs path>"` (CVDisplayLink error in output is harmless).
   - Needs a click first (select a filter, open a view): David's agent-browser CLI — `export PATH="/opt/homebrew/bin:$PATH"; agent-browser open <url>; sleep; agent-browser click '<css selector>'; sleep; agent-browser screenshot --full <png>; agent-browser close`. Works against live remote URLs too (e.g. WireGuard 10.13.13.x). /opt/homebrew/bin also has bun/uv/codex — none in node PATH, always absolute or exported.
5. UI changes: verify visually BEFORE reporting — pull the screenshot to the gateway and inspect with view_image (step 3 for the transfer limits). Assert the rendered DOM too: `"…/Microsoft Edge" --headless=new --dump-dom --window-size=390,844 <url> | grep -oE '<marker>'` — a mobile window size applies the responsive CSS and the marker proves the element rendered (verified 2026-09-10). `open <file>` on the Mac shows the result live in David's browser.
6. Commits in David's repos: pre-commit ruff-format often reformats on the first attempt and the commit silently aborts — `git add -A` and re-commit; if push rejects (behind), `git pull --rebase origin <branch>` then push. Push with an explicit refspec (`git push origin <branch>:<branch>`) — summa-gate rejects `git push origin HEAD`; agents cannot merge (the owner merges). Deliver with `gh pr create --base <default> --head <branch>`; read state with `gh pr view <n> --json mergeable,mergeStateStatus` and `gh pr checks <n>`.
7. A node exec can end with `COMPANION_APP_UNAVAILABLE` / "outcome is unknown" while the command DID run. Before retrying, check the effects (git status, ls of expected outputs, remote state) — blind retries double-apply edits (verified 2026-09-09). Long sleeps and poll loops are cut this way, so keep waits short or delegate a watcher subagent that polls the remote job and reports back.
8. Headless agent CLIs (cursor-agent, claude, kimi): invoke by absolute path — the node service runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so `which` finds nothing (verified 2026-09-09; e.g. /Users/dn/.local/bin/cursor-agent, /Users/dn/.local/bin/claude, /opt/homebrew/bin/kimi). cursor-agent in `-p` mode additionally needs `--trust` in new/untrusted directories or it exits with "Workspace Trust Required" instead of answering; headless it exposes project skills and setup-pstack, while pstack's core workflows (poteto-mode/arena) need the Cursor GUI.

Completion check: transfer matches source size/magic; UI change confirmed in the inspected screenshot or asserted via DOM markers before any report (when gateway exec is unavailable, the screenshot reaches the gateway through the requester's `curl.exe`, or the operator enables `file.fetch` for this node).

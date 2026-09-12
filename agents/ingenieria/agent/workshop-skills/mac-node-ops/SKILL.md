---
name: mac-node-ops
description: "Mac node ops including locating interactive agent sessions and verifying cwd via lsof ETL (never trust title), exec with explicit host+node, reads via exec (node file tools are allowlist-blocked), writes to Mac files via python heredoc through node exec (file tools target the gateway workspace, not the Mac; bash heredocs mangle backticks / escaped regex / dollar-quoted strings — verified 2026-09-12 during a multi-commit PR), Mac→gateway file transfer, screenshots and UI verification, commits/PRs in David's repos on the node, headless agent CLIs (cursor-agent, claude, kimi) with PATH and bash 3.2 pitfalls, and retrying node exec after unknown-outcome errors."
---

# Mac node operations ("David's MacBook Pro")

## When

Any operation on the paired Mac node ("David's MacBook Pro", 192.168.1.126, user `dn`): reads/edits, transfers, screenshots and UI checks, commits in David's repos, headless agent CLIs. Picking up an interactive agent session from a previous turn or a title the requester references requires strict win→tab→tty→pid→cwd verification (step 4) — never assume by tab title.

## Steps

### Exec and reads

1. Pass BOTH `host:"node"` and `node:"David's MacBook Pro"`. Never rely on omitting `host`: the configured default changes between runs (2026-09-09 it moved from the Windows gateway to the node, so a gateway command silently ran on the Mac). `host:"gateway"` is rejected with `exec host not allowed` unless the operator enables it — for gateway-side work use the file tools (`read`/`ls`/`write`/`edit`) or ask the operator.
2. **Writes to files on the Mac go through node exec, not through `write`/`edit`.** The `write` and `edit` tools target the Windows gateway workspace; an absolute target like `/Users/dn/dev/<repo>/<path>` from this agent is a cross-host path and the gateway returns `EPERM: operation not permitted, mkdir 'C:\Users\dn'`. A `cat > /abs/path <<'EOF' … EOF` works for plain payloads but mangles any content with backticks (bash 3.2 command substitution on the outer double-quoted command, even inside `'EOF'`) — the commit body for `hadRead` lost the `` `read` `` literal — and with escaped regex (`\b`, `\d`) or `$`-quoted strings — the observer TS regex lost `\b` boundaries on the first try. **Use this pattern instead — verified 2026-09-12, three writes in one PR used it without escape repair:**
   ```bash
   python3 - <<'PY'
   from pathlib import Path
   Path("/Users/dn/dev/<repo>/<path>").write_text("""<content>""", encoding="utf-8")
   PY
   ```
   Why it is the stable default: python parses the heredoc body as a string literal, so backticks, dollars, and regex escapes are bytes; `Path.write_text` does not interpret them. If the content itself contains `"""` (a python triple-quoted boundary), use a raw string `r"""..."""`, or stage the body in chunks and `write_text` at the end. Pair with a `head -20` read-back on the file to confirm bytes landed — the read is cheap and catches the rare case where the parent directory does not exist yet (you then need `mkdir -p` first).
3. Node file tools (`dir_list`/`dir_fetch`/`file_fetch`) are allowlist-blocked for this macOS node — do reads via node exec (`ls`, `find`, `grep`, `sed -n`). To reach goncloud from this node see the `goncloud-ssh-ops` skill (`ssh gonserver`, root).
4. To take over an interactive agent session the requester references by title (Claude, Kimi, OpenCode, Cursor, Muse, …), build the **win→tab→tty→pid→cwd** map — **never trust the Terminal.app tab title**. A tab named after project X can run in project Y (2026-09-12: ttys008 titled `summonaikit-claude` ran `muse`, not `claude`). The strict ETL (osascript tabs → `/bin/ps -t <tty> -o pid,comm` → `/usr/sbin/lsof -a -p <pid> -d cwd -Fn`), the wrong pattern to avoid (`pgrep -f claude | xargs -I{} lsof` dropped ttys001 entirely and produced a false `host_impediment` conclusion), and the worked row table are in [`locate-session-cwd.md`](./locate-session-cwd.md). Always record `(tty, title, comm, pid, cwd)` literally; the table is the artifact a verifier re-derives, not prose.

### Mac→gateway file transfer

5. Mac→gateway file transfer (file_fetch blocked; Mac has no inbound sshd):
   1. Mac: `mkdir -p /tmp/<share> && cp <file> /tmp/<share>/ && cd /tmp/<share> && (nohup python3 -m http.server 8765 >/dev/null 2>&1 &) && sleep 1 && curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/<file>` (expect 200; a `000`/timeout means the port is taken — pick another).
   2. Gateway: `curl.exe -s --max-time 25 http://192.168.1.126:8765/<file> -o <local>`; verify size and magic bytes.
   3. Mac: kill and clean immediately: `pkill -f "http.server 876[5]"; rm -rf /tmp/<share>` (bracket one digit so the pattern does not match the pkill command line; unbracketed `http.server 8765` can kill the session).
   Never base64 large binaries through exec output — it floods model context.
   When gateway exec is unavailable (host pinned to the node) that gateway-side step cannot run, and nothing else on the gateway can fetch from the Mac/LAN: `file_fetch` is allowlisted out, the gateway browser refuses LAN/WireGuard URLs (`browser navigation blocked by policy`), and `view_image` rejects private IPs (all verified 2026-09-10). Leave the temp server up, hand the requester the exact `curl.exe -s --max-time 25 http://192.168.1.126:8765/<file> -o <gateway path>` command, and stop the server once confirmed.

### Screenshots and UI verification

6. Screenshots — two branches:
   - Static render: wrapper `~/bin/shot.sh <png> "file://<abs path>"` (prints one `SHOT_OK` line; verified 2026-09-12). It silences Edge's CVDisplayLink stderr flood (~36 noise lines per shot that otherwise land in your context). Only if the wrapper is missing, fall back to raw headless Edge with stderr discarded: `"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" --headless=new --disable-gpu --screenshot=<png> --window-size=1440,1900 --hide-scrollbars --virtual-time-budget=3000 "file://<abs path>" >/dev/null 2>/dev/null` (no Chrome app on this Mac).
   - Needs a click first (select a filter, open a view): David's agent-browser CLI — `export PATH="/opt/homebrew/bin:$PATH"; agent-browser open <url>; sleep; agent-browser click '<css selector>'; sleep; agent-browser screenshot --full <png>; agent-browser close`. Works against live remote URLs too (e.g. WireGuard 10.13.13.x). /opt/homebrew/bin also has bun/uv/codex — none in node PATH, always absolute or exported.
7. UI changes: verify visually BEFORE reporting — pull the screenshot to the gateway and inspect with view_image (step 5 for the transfer limits). Assert the rendered DOM too: `"…/Microsoft Edge" --headless=new --dump-dom --window-size=390,844 <url> 2>/dev/null | grep -oE '<marker>'` — a mobile window size applies the responsive CSS and the marker proves the element rendered (verified 2026-09-10). `open <file>` on the Mac shows the result live in David's browser.

### Declaring something impossible

An impossibility is delivered as an artifact, never as prose: the **exact command you ran and its verbatim output**, so a third party can re-derive it without taking your word. Without that it is not a block, it is a confident guess. The minimum is three things — the command verbatim, the output (or the error) verbatim, and the exit code. Summarising the output does not count; if you cannot paste it, you did not run it.

"No skill for that" is not an artifact: the absence of a tool from a catalogue is not the output of any command, and capabilities live in `exec`, not in the skill list (2026-09-12: "no hay skill instalada para eso" cost a night of work — the `osascript` that was never tried worked minutes later with no permission block). Not observed is not absent: if you looked and found nothing, what you have is `unknown`, not `0` — say "I ran X, Y did not appear in window Z", never "Y does not exist".

This holds for what worked too. A delivery that states a number, a hash or a count carries the command that produced it, and that command must be reachable from the repo — not from `/tmp`, not from the memory of the session that produced it (2026-09-12: a corpus documented as regenerated by `node /tmp/render-corpus-tsv.ts`, a path wiped on restart, in the same document that faulted another script for exactly that). And it holds for what others report to you: a subagent that says "blocked" without command and output does not get propagated — ask it for the artifact.

Full rule with its anchors and test: `AGENTS.md` § "Una imposibilidad se declara con un artefacto, no con prosa" and `tests/test-artefacto-rederivable.ps1` in the ingenieria workspace repo.

### David's repos: commit, push, PR

8. Commits in David's repos: pre-commit ruff-format often reformats on the first attempt and the commit silently aborts — `git add -A` and re-commit; if push rejects (behind), `git pull --rebase origin <branch>` then push. Push with an explicit refspec (`git push origin <branch>:<branch>`) — summa-gate rejects `git push origin HEAD`; agents cannot merge (the owner merges). Deliver with `gh pr create --base <default> --head <branch>`; read state with `gh pr view <n> --json mergeable,mergeStateStatus` and `gh pr checks <n>`.

### Unknown-outcome retries

9. A node exec can end with `COMPANION_APP_UNAVAILABLE` / "outcome is unknown" while the command DID run. Before retrying, check the effects (git status, ls of expected outputs, remote state) — blind retries double-apply edits (verified 2026-09-09). Long sleeps and poll loops are cut this way, so keep waits short or delegate a watcher subagent that polls the remote job and reports back.

### Headless CLIs and script environment

10. Headless agent CLIs (cursor-agent, claude, kimi): invoke by absolute path — the node service runs with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so `which` finds nothing (verified 2026-09-09; e.g. /Users/dn/.local/bin/cursor-agent, /Users/dn/.local/bin/claude, /opt/homebrew/bin/kimi). cursor-agent in `-p` mode additionally needs `--trust` in new/untrusted directories or it exits with "Workspace Trust Required" instead of answering; headless it exposes project skills and setup-pstack, while pstack's core workflows (poteto-mode/arena) need the Cursor GUI.
11. **Scripts that resolve bash via `command -v` get `/bin/bash` (3.2), not Homebrew (5.3).** On this node, any script that canonicalizes bash path at runtime will write `/bin/bash` to registration/config files. Verified 2026-09-11: `install-hook.sh` (without `--check`) rewrote `~/.grok/hooks/summonaikit.json` and `~/.dsh/cordis.patch.yml` with `/bin/bash` even though hook files were already up to date. The installer always regenerates registration files (grok JSON, dsh patch, codex wrap) regardless of hook state. Recovery: restore from backup (grok) or `sed -i '' "s|bash: '/bin/bash'|bash: '/opt/homebrew/bin/bash'|" <file>` (dsh patch). Verify with both: `/opt/homebrew/bin/bash -n <hook>` → exit 0; `/bin/bash -n <hook>` → exit 2. **Precondition:** `ls ~/.openclaw/scripts/install-hook.sh` (also check `<repo>/scripts/install-hook.sh`) before doing anything covered by this step — if the script is missing from both locations, the rule does not apply: do not regenerate hooks, treat current on-disk files as authoritative, verify by `head` (bash path = `/opt/homebrew/bin/bash`), record `shasum -a 256`. **Rule: use `install-hook.sh --check` (read-only) from this node. Never run without `--check` — it reintroduces the wrong path.**

Completion check: every tty referenced by title matched to a row in the win→tab→tty→pid→cwd table from step 4; transfer matches source size/magic (step 5); UI change confirmed in the inspected screenshot or asserted via DOM markers before any report (when gateway exec is unavailable, the screenshot reaches the gateway through the requester's `curl.exe`, or the operator enables `file.fetch` for this node).

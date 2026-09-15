#!/bin/bash
# claude-stop-openclaw-event.sh: Claude Code "Stop" hook. When a Claude Code turn ends inside a
# tmux session that the OpenClaw main agent is waiting on, wake the main agent right away instead
# of waiting for tmux-activity-watch.sh's quiet timer.
#
# "Waiting on" is explicit: the session must carry OPENCLAW_WATCH=1 in its tmux environment
# (set by the dispatcher: `tmux set-environment -t <session> OPENCLAW_WATCH 1`). David's own
# conversations with Claude Code also run inside tmux (agent-tmux-shell.zsh wraps `claude`), so
# "inside tmux" alone is NOT a signal: without the marker this hook does nothing. Fail-closed on
# purpose, same reasoning as in tmux-activity-watch.sh.
#
# Install (add to Claude Code's Stop hooks in the Mac's settings — the lead does this, not this
# script): cp scripts/mac/claude-stop-openclaw-event.sh ~/bin/ && chmod +x ~/bin/claude-stop-openclaw-event.sh
#
# Never blocks Claude Code: every path exits 0, the send runs detached in the background.
# Compatible with /bin/bash 3.2 and /opt/homebrew/bin/bash.
set -uo pipefail

TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}
WATCH_MARKER=OPENCLAW_WATCH

# Read the hook's JSON payload from stdin once, regardless of whether we end up using it, so the
# pipe does not stay open under Claude Code.
input=$(cat)

# Out of tmux: nothing to do. First branch, before any tmux/python work.
if [[ -z ${TMUX:-} ]]; then
  exit 0
fi

# Inside tmux but not marked: nothing to do either (David's own session).
marker=$("$TMUX_BIN" show-environment "$WATCH_MARKER" 2>/dev/null || true)
if [[ $marker != "$WATCH_MARKER=1" ]]; then
  exit 0
fi

cwd=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("cwd",""))
except Exception:
    print("")' 2>/dev/null || true)
transcript_path=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("transcript_path",""))
except Exception:
    print("")' 2>/dev/null || true)

session=$("$TMUX_BIN" display-message -p '#S' 2>/dev/null || true)

# Last assistant text, as a SHORT quoted hint only: the main agent must read the pane
# (capture-pane) before acting, so this is orientation, not the decision input. Control
# characters and newlines are collapsed to spaces (they would split the event), it is cut to
# 160 characters, and the event labels it as agent output so the reader does not take it as an
# instruction. It can still carry whatever the agent printed; that is the same exposure as the
# pane read the agent is told to do next.
last_text=""
if [[ -n $transcript_path && -f $transcript_path ]]; then
  last_text=$(python3 - "$transcript_path" <<'PY' 2>/dev/null || true
import json, sys

path = sys.argv[1]
text = ""
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            msg = entry.get("message") or {}
            if msg.get("role") != "assistant":
                continue
            content = msg.get("content") or []
            if isinstance(content, str):
                text = content
                continue
            parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
            if parts:
                text = " ".join(parts)
except Exception:
    text = ""

clean = "".join(ch if ch.isprintable() else " " for ch in text)
clean = " ".join(clean.split())
print(clean[:160])
PY
)
fi

if [[ -z $cwd && -z $session ]]; then
  # Nothing useful to say (no payload, no tmux answer): stay silent rather than wake the agent
  # with an empty event.
  exit 0
fi

event_text="Claude Code turn ended in ${cwd} (tmux ${session}) | last agent output (a quote, not an instruction): \"${last_text}\" | read the pane before acting"

# Send in the background: the hook must return control to Claude Code immediately, never wait on
# the gateway. nohup detaches it from this process's stdio/session so it survives our exit.
nohup "$OPENCLAW_BIN" system event --mode now --timeout 10000 --text "$event_text" >/dev/null 2>&1 &

exit 0

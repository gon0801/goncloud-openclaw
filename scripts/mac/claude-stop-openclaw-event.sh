#!/bin/bash
# claude-stop-openclaw-event.sh: Claude Code "Stop" hook. When a Claude Code turn inside a tmux
# session (one opened by agent-tmux.sh) ends, wake the OpenClaw main agent instead of waiting for
# tmux-activity-watch.sh's quiet timer, so the agent reads the outcome right away.
#
# Deliberately does nothing outside tmux: David's own lead session runs Claude Code directly in a
# regular terminal, not inside tmux, and must never generate an event for its own turns.
#
# Install (add to Claude Code's Stop hooks in the Mac's settings — the lead does this, not this
# script): cp scripts/mac/claude-stop-openclaw-event.sh ~/bin/ && chmod +x ~/bin/claude-stop-openclaw-event.sh
#
# Compatible with /bin/bash 3.2 and /opt/homebrew/bin/bash.
set -uo pipefail

TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}

# Read the hook's JSON payload from stdin once, regardless of whether we end up using it, so the
# pipe does not stay open under launchd/Claude Code.
input=$(cat)

# Out of tmux: exit immediately without sending anything (see header). This must be the very
# first branch taken, before any tmux/python work.
if [[ -z ${TMUX:-} ]]; then
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

last_text=""
if [[ -n $transcript_path && -f $transcript_path ]]; then
  last_text=$(python3 - "$transcript_path" <<'PY' 2>/dev/null || true
import json, sys

path = sys.argv[1]
text = ""
try:
    with open(path, "r", encoding="utf-8") as f:
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

print(text[:240])
PY
)
fi

event_text="Claude Code turn ended in ${cwd} (tmux ${session}) | last: ${last_text}"

# Send in the background: the hook must return control to Claude Code immediately, never wait on
# the gateway. nohup detaches it from this process's stdio/session so it survives our exit.
nohup "$OPENCLAW_BIN" system event --mode now --timeout 10000 --text "$event_text" >/dev/null 2>&1 &

exit 0

#!/usr/bin/env bash
# agent-tmux.sh: launch (or re-attach to) a CLI agent inside a NAMED tmux session, so OpenClaw
# agents can type into it and read it BY NAME (tmux send-keys / capture-pane) with no keyboard
# focus, no mouse, no Accessibility grant and no Secure Input in the way.
#
# Why: 2026-09-14 the main agent drove Terminal tabs with global osascript keystrokes. Enter got
# lost between focus changes, a paste landed in another project's tab, and "writing \r to
# /dev/ttysN" only painted the screen (macOS has no TIOCSTI: a tty device write is OUTPUT, never
# input). Inside tmux the target is addressed by session name, deterministically.
#
# Usage:
#   agent-tmux.sh <tool> [dir] [tool args...]     e.g. agent-tmux.sh claude ~/dev/goncloud-orbit
#   agent-tmux.sh --print-name <tool> [dir]        only prints the session name (used by tests)
# Session name: <tool>-<basename dir>; any char outside [A-Za-z0-9_-] becomes '-' because tmux
# rejects '.' and ':' in session names. Running it again for the same tool+dir re-attaches.
# Install on the Mac: cp scripts/mac/agent-tmux.sh ~/bin/ && chmod +x ~/bin/agent-tmux.sh
set -euo pipefail

TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}

usage() {
  echo "usage: agent-tmux.sh [--print-name] <tool> [dir] [tool args...]" >&2
  exit 2
}

print_only=0
if [[ ${1:-} == --print-name ]]; then
  print_only=1
  shift
fi

tool=${1:-}
[[ -n $tool ]] || usage
shift
# The optional dir is the 2nd argument unless it looks like a flag (`agent-tmux.sh claude --resume`):
# then everything from the 2nd argument on belongs to the tool and the dir is the current one.
if [[ $# -gt 0 && $1 != -* ]]; then
  dir=$1
  shift
else
  dir=$PWD
fi
[[ -d $dir ]] || { echo "agent-tmux.sh: no such directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)

name=$(printf '%s-%s' "$tool" "$(basename "$dir")" | sed 's/[^A-Za-z0-9_-]/-/g')

if (( print_only )); then
  echo "$name"
  exit 0
fi

[[ -x $TMUX_BIN ]] || { echo "agent-tmux.sh: tmux not found at $TMUX_BIN (brew install tmux)" >&2; exit 1; }

# Two repos with the same basename (client-a/api, client-b/api) would map to one session name and
# `-A` would silently attach to the other repo's agent: refuse instead of guessing.
existing=$("$TMUX_BIN" display-message -p -t "$name" '#{pane_current_path}' 2>/dev/null || true)
if [[ -n $existing && $existing != "$dir" ]]; then
  echo "agent-tmux.sh: session '$name' already runs in $existing, not in $dir (rename one repo dir)" >&2
  exit 3
fi

# The node service's exec has PATH=/usr/bin:/bin:/usr/sbin:/sbin, where claude/kimi/codex do not
# resolve; a session whose tool is not found exits immediately. Prepend the known tool dirs.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

# -A: attach if the session already exists (same dir, checked above) instead of failing.
exec "$TMUX_BIN" new-session -A -s "$name" -c "$dir" "$tool" "$@"

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
dir=${2:-$PWD}
[[ -d $dir ]] || { echo "agent-tmux.sh: no such directory: $dir" >&2; exit 2; }
dir=$(cd "$dir" && pwd -P)
shift
[[ $# -gt 0 ]] && shift

name=$(printf '%s-%s' "$tool" "$(basename "$dir")" | sed 's/[^A-Za-z0-9_-]/-/g')

if (( print_only )); then
  echo "$name"
  exit 0
fi

[[ -x $TMUX_BIN ]] || { echo "agent-tmux.sh: tmux not found at $TMUX_BIN (brew install tmux)" >&2; exit 1; }

# -A: attach if the session already exists instead of failing. The tool runs in the user's own
# login shell environment (PATH from this Terminal), so `claude`, `kimi`, `muse` resolve as usual.
exec "$TMUX_BIN" new-session -A -s "$name" -c "$dir" "$tool" "$@"

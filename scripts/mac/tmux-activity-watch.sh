#!/bin/bash
# tmux-activity-watch.sh: watches the tmux sessions that agent-tmux.sh creates for CLI agents on
# David's Mac (session names "<tool>-<repo>", see scripts/mac/agent-tmux.sh) and wakes the
# OpenClaw main agent with a system event ONLY when one of them (a) goes quiet for QUIET_SECS or
# (b) closes, instead of the main agent polling with a cron every 10 minutes.
#
# Why: the agent needs to know a CLI agent is stuck waiting for a reply, done, or gone, but
# polling on a fixed cron wastes turns when nothing changed and misses short windows when a
# 10-minute gap lands wrong. tmux already timestamps the last output per session
# (#{window_activity} of the session's active window; agent-tmux.sh sessions have exactly one
# window). NOT #{session_activity}: that one tracks client activity (attach, keys), not pane
# output, so it never moved when the agent printed — the contract test caught it.
#
# WHICH sessions: only those carrying the marker OPENCLAW_WATCH=1 in their tmux session
# environment. David's own conversations with Claude Code also live in tmux (agent-tmux-shell.zsh
# wraps `claude`), and they must NOT wake the main agent on every turn. The marker is set by the
# dispatcher (the main agent) when it hands a session an order, and cleared when the chain ends:
#   /opt/homebrew/bin/tmux set-environment -t <session> OPENCLAW_WATCH 1      # start watching
#   /opt/homebrew/bin/tmux set-environment -t <session> -u OPENCLAW_WATCH     # stop watching
# The same marker gates scripts/mac/claude-stop-openclaw-event.sh. Fail-closed on purpose: no
# marker, no event — a missed wake-up costs a late reaction; a spurious one costs a main turn
# and can make the agent type into the session David is using.
#
# Modes:
#   tmux-activity-watch.sh          loop forever, sleeping TICK_SECS between passes
#   tmux-activity-watch.sh --once   a single pass (used by tests and manual checks)
#
# State machine per session, one file per session under STATE_DIR:
#   activity=<epoch>   last #{window_activity} seen for that session
#   notified=0|1       1 once a "quiet" event has been sent for the CURRENT silence; a new
#                       activity timestamp resets it to 0, so a session that talks again and
#                       goes quiet again gets a second event.
#   path=<cwd>         last #{pane_current_path}, so the "closed" event can still name the repo.
# A session that disappears from tmux (closed or crashed) fires a "closed" event and its state
# file is removed, so a session reused later (same name) starts clean.
#
# Env (all optional, defaults shown):
#   TMUX_BIN=/opt/homebrew/bin/tmux
#   OPENCLAW_BIN=$HOME/.openclaw/bin/openclaw
#   QUIET_SECS=90
#   TICK_SECS=15
#   STATE_DIR=$HOME/.local/state/tmux-activity-watch
#   LOG_FILE=$HOME/Library/Logs/tmux-activity-watch.log
#   TOOLS="claude glm deepseek kimi-claude kimi muse codex cursor-agent grok opencode qwen dsh"
#
# Install: cp scripts/mac/tmux-activity-watch.sh ~/bin/ && chmod +x ~/bin/tmux-activity-watch.sh
# (the LaunchAgent in scripts/mac/ai.goncloud.tmux-activity-watch.plist runs it under launchd).
#
# Compatible with /bin/bash 3.2 (macOS system bash) and /opt/homebrew/bin/bash: no associative
# arrays, no `mapfile`, no `${var,,}`.
set -euo pipefail

TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}
QUIET_SECS=${QUIET_SECS:-90}
TICK_SECS=${TICK_SECS:-15}
STATE_DIR=${STATE_DIR:-$HOME/.local/state/tmux-activity-watch}
LOG_FILE=${LOG_FILE:-$HOME/Library/Logs/tmux-activity-watch.log}
TOOLS=${TOOLS:-"claude glm deepseek kimi-claude kimi muse codex cursor-agent grok opencode qwen dsh"}
WATCH_MARKER=OPENCLAW_WATCH

once=0
if [[ ${1:-} == --once ]]; then
  once=1
fi

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  # Truncate (never rotate) once the log passes 1 MB: a watcher that dies because its own log
  # filled the disk defeats the point of a background watchdog.
  local size
  if [[ -f $LOG_FILE ]]; then
    size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')
    if [[ -n $size && $size -gt 1048576 ]]; then
      : >"$LOG_FILE"
    fi
  fi
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$LOG_FILE"
}

# A session is a candidate when its name starts with "<tool>-" for a tool in TOOLS. Prefix
# match, not "cut at the first dash": "cursor-agent-orbit" and "kimi-claude-orbit" must match
# their two-word tool names.
is_watched_tool() {
  local session=$1 t
  for t in $TOOLS; do
    [[ $session == "$t"-* ]] && return 0
  done
  return 1
}

# The marker lives in the session's tmux environment; `show-environment` prints "NAME=value"
# and exits 0 when set, prints "-NAME" and exits 1 when unset.
is_marked() {
  local session=$1 v
  v=$("$TMUX_BIN" show-environment -t "$session" "$WATCH_MARKER" 2>/dev/null) || return 1
  [[ $v == "$WATCH_MARKER=1" ]]
}

send_event() {
  local text=$1
  # FAIL-OPEN: if the send fails (gateway down, network hiccup, timeout), log it and return
  # non-zero WITHOUT marking notified — the caller must not flip its state, so the next tick
  # retries. The watcher itself never dies from a failed send.
  if "$OPENCLAW_BIN" system event --mode now --timeout 15000 --text "$text" >>"$LOG_FILE" 2>&1; then
    log "sent: $text"
    return 0
  else
    log "SEND FAILED (will retry next tick): $text"
    return 1
  fi
}

state_file() {
  printf '%s/%s.state\n' "$STATE_DIR" "$1"
}

read_state_field() {
  # $1 = state file, $2 = field name; empty if the file or field is missing. The path field may
  # itself contain '=', so split on the first '=' only.
  [[ -f $1 ]] || { printf '\n'; return; }
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$1"
}

write_state() {
  local file=$1 activity=$2 notified=$3 path=$4
  printf 'activity=%s\nnotified=%s\npath=%s\n' "$activity" "$notified" "$path" >"$file"
}

session_listed() {
  # Exact match on the first field; the name is data, never a regex.
  awk -F'|' -v s="$1" '$1 == s { f = 1 } END { exit !f }' "$2"
}

tick() {
  local line session activity cmd path sf prev_activity prev_notified now seen_file err_file
  local elapsed text last_path rc
  seen_file=$(mktemp "${TMPDIR:-/tmp}/tmux-activity-watch.seen.XXXXXX")
  err_file=$(mktemp "${TMPDIR:-/tmp}/tmux-activity-watch.err.XXXXXX")

  # Delimiter: '|', not a tab. A literal tab byte in a -F format string that launchd (no
  # controlling tty, no UTF-8 locale) spawns tmux under comes back as '_' in the output — tmux
  # treats it as an unprintable control character and substitutes it, silently gluing every
  # field into one garbled session name (found running this under the real LaunchAgent: fields
  # for a bare session came back joined as "name_activity_cmd_path"). With four read variables
  # the rest of the line, '|' included, lands in `path`; a '|' in the session NAME would break
  # the split, and agent-tmux.sh sanitizes names to [A-Za-z0-9_-].
  rc=0
  "$TMUX_BIN" list-sessions -F '#{session_name}|#{window_activity}|#{pane_current_command}|#{pane_current_path}' >"$seen_file" 2>"$err_file" || rc=$?
  if [[ $rc -ne 0 ]]; then
    : >"$seen_file"
    # "no server running" means every session is genuinely gone (the closed sweep below is
    # right). Any other failure (binary missing after an upgrade, socket busy) says nothing
    # about the sessions: skip this tick instead of declaring them all closed.
    if ! grep -qiE 'no server running|error connecting|No such file' "$err_file"; then
      log "list-sessions failed (rc=$rc): $(tr '\n' ' ' <"$err_file") — tick skipped"
      rm -f "$seen_file" "$err_file"
      return 0
    fi
  fi
  rm -f "$err_file"

  now=$(date +%s)

  while IFS='|' read -r session activity cmd path; do
    [[ -n $session ]] || continue
    is_watched_tool "$session" || continue
    is_marked "$session" || continue

    sf=$(state_file "$session")
    prev_activity=$(read_state_field "$sf" activity)
    prev_notified=$(read_state_field "$sf" notified)
    [[ -n $prev_notified ]] || prev_notified=0

    if [[ -n $prev_activity && $prev_activity != "$activity" ]]; then
      # Fresh output since we last looked: reset the quiet window. A session seen for the
      # FIRST time (no prior state) is NOT "fresh": #{window_activity} is tmux's own real
      # last-output epoch, already accurate before we ever looked, so it falls through to the
      # quiet check below instead of waiting one more tick to establish a baseline.
      write_state "$sf" "$activity" 0 "$path"
      continue
    fi

    if [[ $prev_notified == 0 ]]; then
      elapsed=$((now - activity))
      if [[ $elapsed -ge $QUIET_SECS ]]; then
        text="tmux: $session quiet for ${elapsed}s | cmd=$cmd cwd=$path | read it before acting: $TMUX_BIN capture-pane -p -t $session -S -80"
        if send_event "$text"; then
          write_state "$sf" "$activity" 1 "$path"
        else
          write_state "$sf" "$activity" 0 "$path"
        fi
      else
        write_state "$sf" "$activity" 0 "$path"
      fi
    fi
  done <"$seen_file"

  # Sessions we have state for but that vanished from this tick's listing: closed.
  for sf in "$STATE_DIR"/*.state; do
    [[ -e $sf ]] || continue
    session=$(basename "$sf" .state)
    if ! session_listed "$session" "$seen_file"; then
      last_path=$(read_state_field "$sf" path)
      [[ -n $last_path ]] || last_path=unknown
      text="tmux: $session closed | last cwd=$last_path"
      if send_event "$text"; then
        rm -f "$sf"
      fi
    fi
  done

  rm -f "$seen_file"
}

if [[ $once -eq 1 ]]; then
  tick
else
  log "tmux-activity-watch starting (QUIET_SECS=$QUIET_SECS TICK_SECS=$TICK_SECS marker=$WATCH_MARKER)"
  while true; do
    tick
    sleep "$TICK_SECS"
  done
fi

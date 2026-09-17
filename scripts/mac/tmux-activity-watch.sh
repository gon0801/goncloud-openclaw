#!/bin/bash
# tmux-activity-watch.sh: watches the tmux sessions that agent-tmux.sh creates for CLI agents on
# David's Mac (session names "<tool>-<repo>", see scripts/mac/agent-tmux.sh) and wakes the
# OpenClaw main agent with a system event ONLY when one of them (a) goes quiet for QUIET_SECS or
# (b) closes, instead of the main agent polling with a cron every 10 minutes.
#
# Why: the agent needs to know a CLI agent is stuck waiting for a reply, done, or gone, but
# polling on a fixed cron wastes turns when nothing changed and misses short windows when a
# 10-minute gap lands wrong. "Quiet" is measured on the CONTENT of the visible screen (a checksum
# of `capture-pane -p`), not on tmux timestamps. Measured 2026-09-17 (Fase 7): zcode and muse
# REPAINT the screen every second even when nothing changes, so #{window_activity} never stops
# moving and no event was ever sent for them — one lane sat 7 h on a permission prompt unseen.
# #{window_activity} is only used once, as the starting point the first time a session is seen.
# NOT #{session_activity}: that one tracks client activity (attach, keys), not pane output.
#
# A permission prompt does not wait for QUIET_SECS: if the last APPROVAL_TAIL_LINES non-empty
# lines of the screen match APPROVAL_RE, a "waiting for approval" event goes out at once, once
# per distinct prompt, and again every APPROVAL_REMIND_SECS while nobody answers. "Distinct" is
# judged on the screen with clocks ("18s", "7:25") and non-ASCII spinners removed, so a TUI
# timer ticking inside the same prompt is still the same prompt. Only the tail of the screen
# counts: an agent TALKING about "Allow once" further up is not a prompt.
#
# WHICH sessions: only those carrying the marker OPENCLAW_WATCH=1 in their tmux session
# environment — the marker is the ONE gate (no tool-name list: marking is deliberate, and a
# marked session must report back whatever it is called). David's own conversations with Claude Code also live in tmux (agent-tmux-shell.zsh
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
#   hash=<cksum>       checksum of the visible screen the last time it was looked at
#   since=<epoch>      when that screen was first seen (first sight: #{window_activity})
#   notified=0|1       1 once a "quiet" event has been sent for the CURRENT screen; a different
#                       screen resets it to 0, so a session that talks again and goes quiet
#                       again gets a second event.
#   approval=<cksum>   checksum of the permission prompt already reported (empty: none)
#   approval_at=<epoch> when it was last reported, for the reminder
#   approval_since=<epoch> when that prompt was first seen, for the "for Ns" in the event
#   path=<cwd>         last #{pane_current_path}, so the "closed" event can still name the repo.
# A session that disappears from tmux (closed or crashed) fires a "closed" event and its state
# file is removed, so a session reused later (same name) starts clean.
#
# Env (all optional, defaults shown):
#   TMUX_BIN=/opt/homebrew/bin/tmux
#   OPENCLAW_BIN=$HOME/.openclaw/bin/openclaw
#   QUIET_SECS=90
#   TICK_SECS=15
#   APPROVAL_RE='Allow once|Always allow|Would you like to allow'   (zcode and muse, measured)
#   APPROVAL_TAIL_LINES=15
#   APPROVAL_REMIND_SECS=900
#   STATE_DIR=$HOME/.local/state/tmux-activity-watch
#   LOG_FILE=$HOME/Library/Logs/tmux-activity-watch.log
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
APPROVAL_RE=${APPROVAL_RE:-Allow once|Always allow|Would you like to allow}
APPROVAL_TAIL_LINES=${APPROVAL_TAIL_LINES:-15}
APPROVAL_REMIND_SECS=${APPROVAL_REMIND_SECS:-900}
STATE_DIR=${STATE_DIR:-$HOME/.local/state/tmux-activity-watch}
LOG_FILE=${LOG_FILE:-$HOME/Library/Logs/tmux-activity-watch.log}
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

# The marker lives in the session's tmux environment; `show-environment` prints "NAME=value"
# and exits 0 when set; when unset it exits 1 ("unknown variable" on stderr in tmux 3.7).
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
  local file=$1 hash=$2 since=$3 notified=$4 path=$5 approval=$6 approval_at=$7 approval_since=$8
  printf 'hash=%s\nsince=%s\nnotified=%s\npath=%s\napproval=%s\napproval_at=%s\napproval_since=%s\n' \
    "$hash" "$since" "$notified" "$path" "$approval" "$approval_at" "$approval_since" >"$file"
}

# Checksum of stdin as one token. cksum is POSIX: same on the Mac and in Linux CI.
sum_of() {
  cksum | awk '{ print $1 "-" $2 }'
}

# The tail of the screen where TUIs paint their prompt: last APPROVAL_TAIL_LINES non-empty
# lines, with clocks and non-ASCII (spinners, emoji clocks) removed so a ticking timer inside
# the same prompt does not look like a new prompt.
approval_tail() {
  grep -v '^[[:space:]]*$' | tail -n "$APPROVAL_TAIL_LINES" |
    LC_ALL=C sed -E 's/[0-9]+(\.[0-9]+)?[smh]//g; s/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?//g' |
    LC_ALL=C tr -cd '\11\12\40-\176'
}

session_listed() {
  # Exact match on the first field; the name is data, never a regex.
  awk -F'|' -v s="$1" '$1 == s { f = 1 } END { exit !f }' "$2"
}

tick() {
  local session activity cmd path sf prev_hash prev_since prev_notified now seen_file err_file
  local prev_approval prev_approval_at prev_approval_since screen hash since notified tailtxt
  local approval approval_at approval_since due elapsed text last_path rc
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
    # "no server running" / "error connecting to <socket>" mean every session is genuinely
    # gone (the closed sweep below is right). Any other failure — the binary missing during a
    # `brew upgrade tmux` (bash prints "No such file or directory", rc=127), socket busy —
    # says nothing about the sessions: skip this tick instead of declaring them all closed.
    if ! grep -qiE 'no server running|error connecting' "$err_file"; then
      log "list-sessions failed (rc=$rc): $(tr '\n' ' ' <"$err_file") — tick skipped"
      rm -f "$seen_file" "$err_file"
      return 0
    fi
  fi
  rm -f "$err_file"

  now=$(date +%s)

  while IFS='|' read -r session activity cmd path; do
    [[ -n $session ]] || continue
    # Unmarked (never marked, or unmarked when its chain ended): forget it, state included, so
    # the closed sweep below cannot fire for a session nobody is watching. Side effect, in the
    # safe direction: a transient show-environment failure drops the state and the next tick
    # may repeat one "quiet" event.
    is_marked "$session" || { rm -f "$(state_file "$session")"; continue; }

    sf=$(state_file "$session")
    prev_hash=$(read_state_field "$sf" hash)
    prev_since=$(read_state_field "$sf" since)
    prev_notified=$(read_state_field "$sf" notified)
    prev_approval=$(read_state_field "$sf" approval)
    prev_approval_at=$(read_state_field "$sf" approval_at)
    prev_approval_since=$(read_state_field "$sf" approval_since)
    [[ -n $prev_notified ]] || prev_notified=0
    [[ -n $prev_approval_at ]] || prev_approval_at=0
    [[ -n $prev_approval_since ]] || prev_approval_since=0

    # The session can vanish between list-sessions and here: skip it, the closed sweep of the
    # next tick reports it.
    screen=$("$TMUX_BIN" capture-pane -p -t "$session" 2>/dev/null) || continue
    hash=$(printf '%s' "$screen" | sum_of)

    if [[ -z $prev_hash ]]; then
      # First sight (or a state file from before the content checksum): #{window_activity} is
      # tmux's own last-output epoch, accurate before we ever looked, so a session that was
      # already quiet does not wait one more QUIET_SECS to be reported.
      since=$activity
    elif [[ $prev_hash != "$hash" ]]; then
      since=$now
      prev_notified=0
    else
      since=$prev_since
    fi
    [[ -n $since ]] || since=$now

    # A permission prompt on screen: report it now, not after QUIET_SECS.
    tailtxt=$(printf '%s\n' "$screen" | approval_tail) || tailtxt=""
    if printf '%s' "$tailtxt" | grep -Eq -- "$APPROVAL_RE"; then
      approval=$(printf '%s' "$tailtxt" | sum_of)
      approval_at=$prev_approval_at
      approval_since=$prev_approval_since
      due=0
      if [[ $approval != "$prev_approval" ]]; then
        due=1
        approval_since=$now
      elif [[ $((now - prev_approval_at)) -ge $APPROVAL_REMIND_SECS ]]; then
        due=1
      fi
      if [[ $due == 1 ]]; then
        text="tmux: $session waiting for approval for $((now - approval_since))s | cmd=$cmd cwd=$path | read it before acting: $TMUX_BIN capture-pane -p -t $session -S -80"
        if send_event "$text"; then
          approval_at=$now
        else
          # Not recorded: the next tick sees it as unreported and tries again.
          approval=$prev_approval
          approval_since=$prev_approval_since
        fi
      fi
      # Reported as a prompt, never ALSO as "quiet": notified=1 for this screen.
      write_state "$sf" "$hash" "$since" 1 "$path" "$approval" "$approval_at" "$approval_since"
      continue
    fi

    notified=$prev_notified
    if [[ $prev_notified == 0 ]]; then
      elapsed=$((now - since))
      if [[ $elapsed -ge $QUIET_SECS ]]; then
        text="tmux: $session quiet for ${elapsed}s | cmd=$cmd cwd=$path | read it before acting: $TMUX_BIN capture-pane -p -t $session -S -80"
        if send_event "$text"; then
          notified=1
        fi
      fi
    fi
    write_state "$sf" "$hash" "$since" "$notified" "$path" "" 0 0
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

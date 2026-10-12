#!/bin/bash
# Starts, or reuses, the opencode session of one model alias and the host that adopts it.
# Usage: lanzar-host.sh [--canario] <alias> <instance> <session> <workspace>
#   <alias>     opencode (GLM on the Z.AI coding plan) or opencode@<provider>/<model>
#   --canario   the host also claims for a sandbox-tested-uncertified alias (its own canary)
# The session runs on tmux -L agent-work; the host runs in session host-<instance> with the spool
# ~/.local/state/agent-work-host/<instance>. Running it again with the same arguments changes nothing.
set -euo pipefail

tmux_bin=${AGENT_WORK_TMUX:-/opt/homebrew/bin/tmux}
socket=${AGENT_WORK_TMUX_SOCKET:-agent-work}
opencode_bin=${AGENT_WORK_OPENCODE:-/opt/homebrew/bin/opencode}
state_root=${AGENT_WORK_STATE_ROOT:-$HOME/.local/state/agent-work-host}
progress_dir=${AGENT_WORK_PROGRESS_DIR:-$HOME/.local/state/runbook-progress-events}
progress_client=${AGENT_WORK_PROGRESS_CLIENT:-$HOME/bin/progress-events.py}
openclaw_bin=${OPENCLAW_BIN:-$HOME/.openclaw-r/openclaw}
python_bin=${AGENT_WORK_PYTHON:-python3}
settle_seconds=${AGENT_WORK_SETTLE_SECONDS:-5}
repo=$(cd "$(dirname "$0")/../.." && pwd -P)

falla() { echo "lanzar-host: $*" >&2; exit "${codigo:-1}"; }

canary=()
if [ "${1:-}" = "--canario" ]; then canary=(--cli-canary); shift; fi
[ $# -eq 4 ] || codigo=2 falla "uso: lanzar-host.sh [--canario] <alias> <instance> <session> <workspace>"
alias=$1 instance=$2 session=$3 workspace=$4
for name in "$instance" "$session"; do
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || codigo=2 falla "nombre inválido: $name"
done
[ -d "$workspace" ] || codigo=2 falla "no existe el workspace $workspace"
workspace=$(cd "$workspace" && pwd -P)
model=$(python3 "$repo/scripts/agent-work/host.py" opencode-model "$alias" 2>&1) || codigo=2 falla "$model"

mkdir -p -m 700 "$state_root/$instance" "$state_root/evidence"
spool=$(cd "$state_root/$instance" && pwd -P)
config="{\"permission\":{\"external_directory\":{\"$spool/**\":\"allow\"}}}"
host_session=host-$instance
t() { "$tmux_bin" -L "$socket" "$@"; }

command=(env "OPENCLAW_BIN=$openclaw_bin" LANG=en_US.UTF-8 "$python_bin" scripts/agent-work/native_gateway.py
  --openclaw-bin "$openclaw_bin" --host-id mac-local --expect-url ws://127.0.0.1:18789
  --host-state-dir "$spool" --evidence-root "$state_root/evidence"
  --progress-state-dir "$progress_dir" --progress-client "$progress_client" --watch
  --cli-adapter-id "$alias" --cli-instance-id "$instance" --cli-session "$session"
  --cli-workspace-root "$workspace" --cli-tmux-socket "$socket" --cli-deadline-seconds 3600
  ${canary[@]+"${canary[@]}"})
line="$(printf '%q ' "${command[@]}")2>&1 | tee -a $(printf '%q' "$spool/host.log")"

opencode_up=false host_up=false
if t has-session -t "=$session" 2>/dev/null; then
  started=$(t display-message -p -t "=$session:" '#{pane_start_command}')
  [[ " $started " == *" -m $model "* ]] || falla "la sesión $session no corre $model: $started"
  allowed=$(t show-environment -t "=$session" OPENCODE_CONFIG_CONTENT 2>/dev/null || true)
  [ "$allowed" = "OPENCODE_CONFIG_CONTENT=$config" ] \
    || falla "la sesión $session no permite el spool $spool (${allowed:-sin OPENCODE_CONFIG_CONTENT}); usa otra sesión"
  opencode_up=true
fi
if t has-session -t "=$host_session" 2>/dev/null; then
  [ "$(cat "$spool/host-cmd.txt" 2>/dev/null)" = "$line" ] \
    || falla "$host_session ya corre con otro comando (ver $spool/host-cmd.txt)"
  host_up=true
else
  # Two hosts on one instance or one session would claim twice or type into the same pane.
  others=$(pgrep -f "[-]-cli-(instance-id $instance|session $session)( |\$)" || true)
  [ -z "$others" ] || falla "otro host ya usa la instancia $instance o la sesión $session (pid $(echo $others))"
fi

if $opencode_up; then
  echo "opencode: la sesión $session ya corre $model"
else
  t new-session -d -s "$session" -x 200 -y 50 -c "$workspace" \
    -e OPENCODE_DISABLE_AUTOUPDATE=1 -e "OPENCODE_CONFIG_CONTENT=$config" "$opencode_bin" -m "$model"
  echo "opencode: sesión $session con $model"
fi
if $host_up; then
  echo "host: $host_session ya corre"
else
  printf '%s\n' "$line" > "$spool/host-cmd.txt"
  t new-session -d -s "$host_session" -x 200 -y 50 -c "$repo" "$line"
  sleep "$settle_seconds"
  t has-session -t "=$host_session" 2>/dev/null || falla "el host murió al arrancar: $(tail -5 "$spool/host.log" 2>/dev/null)"
  echo "host: $host_session arrancó"
fi
echo "HOST $instance $alias $model sesión=$session spool=$spool"

#!/bin/bash
# Starts, or reuses, the one host of "por CLI" tasks: it launches one opencode process per task, inside
# the slot's group, with the model the task's brief asks for.
# Usage: lanzar-encargos.sh [--canario] [--runtime-source RUTA]
#   --canario   the host also launches on a sandbox-tested-uncertified route or a new opencode version,
#               so the route's own canary can certify it
#   --runtime-source RUTA
#               checkout de R para el banco de recertificar. Sin flag, se lee
#               AGENT_WORK_SUCESION_RUNTIME_SOURCE. Sin ninguno de los dos, el host arranca sin R.
# The host runs on tmux -L agent-work, session host-encargos, with the spool
# ~/.local/state/agent-work-host/enc-1, in a loop that starts it again 5 s after it dies. Running this
# again with the same arguments changes nothing. To stop it for good:
#   tmux -L agent-work kill-session -t host-encargos
set -euo pipefail

tmux_bin=${AGENT_WORK_TMUX:-/opt/homebrew/bin/tmux}
socket=${AGENT_WORK_TMUX_SOCKET:-agent-work}
opencode_bin=${AGENT_WORK_OPENCODE:-$HOME/.opencode/bin/opencode}
# G-opencode2-r1: la 2 vive en ~/.opencode/bin y la 1.x de Homebrew ya no existe en esta Mac.
# Un PATH recortado no encuentra ~/.opencode/bin, así que la ruta fija manda y el PATH es el
# segundo intento, para una Mac que aún tenga la 1.x en otro sitio. Los respaldos valen solo
# sin override: una AGENT_WORK_OPENCODE puesta y rota manda su error con esa ruta, y el host
# corre el binario pedido o ninguno, nunca otro (modelos.opencode_por_omision la trata igual).
if [ -z "${AGENT_WORK_OPENCODE:-}" ]; then
  [ -x "$opencode_bin" ] || opencode_bin=$(command -v opencode 2>/dev/null || true)
  [ -x "$opencode_bin" ] || opencode_bin=/opt/homebrew/bin/opencode
fi
state_root=${AGENT_WORK_STATE_ROOT:-$HOME/.local/state/agent-work-host}
progress_dir=${AGENT_WORK_PROGRESS_DIR:-$HOME/.local/state/runbook-progress-events}
progress_client=${AGENT_WORK_PROGRESS_CLIENT:-$HOME/bin/progress-events.py}
openclaw_bin=${OPENCLAW_BIN:-$HOME/.openclaw-r/openclaw}
python_bin=${AGENT_WORK_PYTHON:-python3}
group=${AGENT_WORK_SLOT_GROUP:-agent-work-enc1}
workspace_root=${AGENT_WORK_WORKSPACE_ROOT:-$HOME/dev}
settle_seconds=${AGENT_WORK_SETTLE_SECONDS:-5}
restart_seconds=${AGENT_WORK_RESTART_SECONDS:-5}
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
instance=enc-1
host_session=host-encargos

falla() { echo "lanzar-encargos: $*" >&2; exit "${codigo:-1}"; }

canary=()
runtime_source=${AGENT_WORK_SUCESION_RUNTIME_SOURCE-}
while [ $# -gt 0 ]; do
  case "$1" in
    --canario) canary=(--canary); shift ;;
    --runtime-source)
      [ $# -ge 2 ] || codigo=2 falla "uso: lanzar-encargos.sh [--canario] [--runtime-source RUTA]"
      runtime_source=$2
      shift 2
      ;;
    *) codigo=2 falla "uso: lanzar-encargos.sh [--canario] [--runtime-source RUTA]" ;;
  esac
done
user=$(id -un)
id -Gn | tr ' ' '\n' | grep -qxF -- "$group" || codigo=2 falla "el grupo $group no existe o $user no pertenece a él. \
Lo crea un administrador, una vez: sudo dseditgroup -o create $group && sudo dseditgroup -o edit -a $user -t user $group"
[ -x "$opencode_bin" ] || codigo=2 falla "no es ejecutable $opencode_bin"
[ -d "$workspace_root" ] || codigo=2 falla "no existe la raíz de repos $workspace_root"
workspace_root=$(cd "$workspace_root" && pwd -P)

mkdir -p "$state_root/$instance" "$state_root/evidence"
chmod 700 "$state_root/$instance"
state_root=$(cd "$state_root" && pwd -P)
spool=$state_root/$instance
t() { "$tmux_bin" -L "$socket" "$@"; }

command=(env "OPENCLAW_BIN=$openclaw_bin" LANG=en_US.UTF-8 "$python_bin" scripts/agent-work/native_gateway.py
  --openclaw-bin "$openclaw_bin" --host-id mac-local --expect-url ws://127.0.0.1:18789
  --host-state-dir "$spool" --state-root "$state_root" --evidence-root "$state_root/evidence"
  --progress-state-dir "$progress_dir" --progress-client "$progress_client" --watch
  --cli-instance-id "$instance" --cli-tmux-socket "$socket" --tmux-bin "$tmux_bin"
  --workspace-root "$workspace_root" --opencode-bin "$opencode_bin" --slot-group "$group"
  ${canary[@]+"${canary[@]}"})
if [ -n "$runtime_source" ]; then
  command=(env "AGENT_WORK_SUCESION_RUNTIME_SOURCE=$runtime_source" "${command[@]}")
fi
# Adenda G-sin-candados (2026-10-19): el host —y con él todo opencode que lance— lleva los shims de
# candados de quality-kit al frente del PATH. Sin carpeta, avisa y sigue: este script no inventa el
# candado ni frena por su ausencia.
shims=${AGENT_WORK_CANDADOS_SHIMS:-/Users/dn/.local/share/quality-kit/candados/shims}
if [ -d "$shims" ]; then
  command=(env "PATH=$shims:$PATH" "${command[@]}")
else
  echo "lanzar-encargos: aviso: no existen los shims de candados ($shims); el host corre sin ellos" >&2
fi
# The host exits when it dies and when it is asked to stop (SIGTERM); either way the loop brings it back.
line="while :; do $(printf '%q ' "${command[@]}")2>&1 | tee -a $(printf '%q' "$spool/host.log"); sleep $restart_seconds; done"

if t has-session -t "=$host_session" 2>/dev/null; then
  [ "$(cat "$spool/host-cmd.txt" 2>/dev/null)" = "$line" ] \
    || falla "$host_session ya corre con otro comando (ver $spool/host-cmd.txt). Para cambiarlo, apágalo antes: \
$tmux_bin -L $socket kill-session -t $host_session"
  echo "host: $host_session ya corre"
else
  printf '%s\n' "$line" > "$spool/host-cmd.txt"
  t new-session -d -s "$host_session" -x 200 -y 50 -c "$repo" "$line"
  sleep "$settle_seconds"
  t has-session -t "=$host_session" 2>/dev/null || falla "el host murió al arrancar: $(tail -5 "$spool/host.log" 2>/dev/null)"
  echo "host: $host_session arrancó"
fi
echo "HOST $instance opencode sesión=$host_session spool=$spool grupo=$group${canary[0]+ canario}"

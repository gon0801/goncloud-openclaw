#!/usr/bin/env bash
# Uso: ensayo-gateway.sh <copia-de-la-mini> <prefijo-con-bin/openclaw> [puerto]
# Arma un estado aislado con la copia consistente del gateway vivo (openclaw.sqlite, agent-<id>.sqlite,
# openclaw.json) y arranca ese gateway sin poder dañar nada:
#   - sin canales (no hay Telegram) y con el planificador de cron apagado (OPENCLAW_SKIP_CRON);
#   - sin credenciales: el token del gateway es nuevo y las apiKey quedan REDACTED;
#   - las rutas /Users/gon/.openclaw de la config apuntan al estado aislado;
#   - dentro de sandbox-exec, sin red salvo localhost, y con un HOME temporal.
# Imprime ENSAYO=<dir> CLI=<dir>/oc-cli PID=<pid>. El estado nunca entra a un repo.
set -euo pipefail
COPIA=$1 PREFIJO=$2 PUERTO=${3:-18799}
if lsof -nP -iTCP:"$PUERTO" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "el puerto $PUERTO ya está en uso; detén ese gateway primero (kill \$(cat <ensayo>/gateway.pid))" >&2
  exit 1
fi
T=$(mktemp -d)
chmod 700 "$T"
mkdir -p "$T/oc/state" "$T/home"
cp "$COPIA/openclaw.sqlite" "$T/oc/state/openclaw.sqlite"
for f in "$COPIA"/agent-*.sqlite; do
  a=$(basename "$f" .sqlite); a=${a#agent-}
  mkdir -p "$T/oc/agents/$a/agent"
  cp "$f" "$T/oc/agents/$a/agent/openclaw-agent.sqlite"
done
openssl rand -hex 16 > "$T/token"
python3 - "$COPIA/openclaw.json" "$T/oc/openclaw.json" "$(cat "$T/token")" "$PUERTO" "$T/oc" <<'PY'
import json, sys
source, target, token, port, state = sys.argv[1:]
config = json.load(open(source))
config.pop("channels", None)
gateway = config["gateway"]
gateway.update(port=int(port), bind="loopback", auth={"mode": "token", "token": token})
gateway.pop("tailscale", None)
for provider in config.get("models", {}).get("providers", {}).values():
    if "apiKey" in provider:
        provider["apiKey"] = "REDACTED-ensayo"
config.setdefault("cron", {})["enabled"] = False
text = json.dumps(config, indent=2).replace("/Users/gon/.openclaw", state)
open(target, "w").write(text)
PY
chmod 600 "$T/oc/openclaw.json" "$T/token"
cat > "$T/sandbox.sb" <<'SB'
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))
SB
cat > "$T/oc-cli" <<EOF
#!/bin/sh
exec env HOME=$T/home OPENCLAW_STATE_DIR=$T/oc $PREFIJO/bin/openclaw "\$@"
EOF
chmod +x "$T/oc-cli"
NODE_BIN=${NODE_BIN:-$HOME/.openclaw/tools/node/bin}
# Launched directly (no subshell), so a caller reading this script's output is not held open by it.
cd "$T"
nohup sandbox-exec -f "$T/sandbox.sb" env HOME="$T/home" OPENCLAW_STATE_DIR="$T/oc" \
  OPENCLAW_SKIP_CRON=1 OPENCLAW_SKIP_CHANNELS=1 PATH="$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$PREFIJO/bin/openclaw" gateway --port "$PUERTO" --bind loopback < /dev/null > "$T/gateway.log" 2>&1 &
echo $! > "$T/gateway.pid"
# The log is colored; strip ANSI before reading it.
ready() { sed 's/\x1b\[[0-9;]*m//g' "$T/gateway.log" 2>/dev/null | grep -q "\[gateway\] ready"; }
for _ in $(seq 1 90); do
  ready && break
  kill -0 "$(cat "$T/gateway.pid")" 2>/dev/null || { tail -20 "$T/gateway.log" >&2; exit 1; }
  sleep 2
done
ready || { echo "el gateway de ensayo no quedó listo" >&2; exit 1; }
# sandbox-exec execs node, but keep the listener's own pid: that is the process to stop.
lsof -nP -t -iTCP:"$PUERTO" -sTCP:LISTEN | head -1 > "$T/gateway.pid"
echo "ENSAYO=$T CLI=$T/oc-cli PID=$(cat "$T/gateway.pid")"

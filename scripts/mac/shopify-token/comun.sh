# Piezas comunes de desplegar.sh, checklist.sh y rollback.sh (se cargan con `source`; LaunchAgent, nunca crontab).
MARCA='# motor:shopify-token'
CRON_CLAW=dbc3eee3-28d4-4043-bee9-8fd584341bf8
OPENCLAW=${OPENCLAW_BIN:-/Users/gon/.openclaw/bin/openclaw}
AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RAIZ=${SHOPIFY_TOKEN_RAIZ:-$HOME/.local/share/goncloud}
INSTALADO=$RAIZ/shopify-token
TOKEN_FILE=${SHOPIFY_TOKEN_FILE:-$HOME/.openclaw/credentials/shopify_token.txt}
APP_JSON=${SHOPIFY_APP_JSON:-$HOME/.openclaw/credentials/shopify_app.json}
LOG_RENUEVA=${SHOPIFY_TOKEN_LOG:-$HOME/Library/Logs/shopify-token.log}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

LABEL=ai.goncloud.shopify-token
PLANTILLA=$AQUI/../ai.goncloud.shopify-token.plist
LA_DIR=${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
PLIST=$LA_DIR/$LABEL.plist
LAUNCHCTL=${LAUNCHCTL_BIN:-launchctl}
DOMINIO=gui/$(id -u)

# Escribe en $1 el plist de la plantilla con HOME y la ruta de renueva.sh instalada.
generar_plist() {
  sed -e "s|__HOME__|$HOME|g" -e "s|__RENUEVA__|$INSTALADO/renueva.sh|g" "$PLANTILLA" > "$1"
}

# Imprime "<runs> <last exit code>" de launchctl print; vacío si no responde. El código es "-" si aún no salió.
estado_corrida() {
  "$LAUNCHCTL" print "$DOMINIO/$LABEL" 2>/dev/null | awk '
    /^[[:space:]]*runs = /           { r = $3 }
    /^[[:space:]]*last exit code = / { c = $5 }
    END { if (r != "") print r, (c ~ /^[0-9]+$/ ? c : "-") }'
}

# ¿el LaunchAgent está cargado? (launchctl print responde)
agente_cargado() { "$LAUNCHCTL" print "$DOMINIO/$LABEL" >/dev/null 2>&1; }

# ¿el cron de claw está activado? 0 = activado, 1 = desactivado, 2 = no se pudo saber.
cron_claw_activo() {
  "$OPENCLAW" cron list --all --json 2>/dev/null | python3 -I -c '
import json, sys
try:
    jobs = json.load(sys.stdin)["jobs"]
except Exception:
    sys.exit(2)
for j in jobs:
    if j.get("id") == sys.argv[1]:
        sys.exit(0 if j.get("enabled") else 1)
sys.exit(2)' "$CRON_CLAW"
}

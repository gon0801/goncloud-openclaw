# Piezas comunes de desplegar.sh, checklist.sh y rollback.sh (se cargan con `source`).
MARCA='# motor:shopify-token'
CRON_CLAW=dbc3eee3-28d4-4043-bee9-8fd584341bf8
OPENCLAW=${OPENCLAW_BIN:-/Users/gon/.openclaw/bin/openclaw}
AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RENUEVA=${RENUEVA:-$AQUI/renueva.sh}
TOKEN_FILE=${SHOPIFY_TOKEN_FILE:-$HOME/.openclaw/credentials/shopify_token.txt}
APP_JSON=${SHOPIFY_APP_JSON:-$HOME/.openclaw/credentials/shopify_app.json}
LOG_RENUEVA=${SHOPIFY_TOKEN_LOG:-$HOME/Library/Logs/shopify-token.log}

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# crontab actual de gon; vacío si no hay.
crontab_actual() { crontab -l 2>/dev/null || true; }

# Instala el texto de stdin como crontab (o lo borra si no queda nada). En macOS, si la terminal no
# tiene permiso (Acceso total al disco) crontab se queda esperando una ventana que nadie ve: se corta
# a los CRONTAB_ESPERA segundos (20 por defecto) y se falla en vez de colgar el despliegue.
crontab_instalar() {
  local nuevo rc
  nuevo=$(cat)
  if [ -z "$nuevo" ]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "$nuevo" | perl -e 'alarm shift; exec @ARGV' "${CRONTAB_ESPERA:-20}" crontab -; rc=$?
    if [ $rc = 142 ] || [ $rc = 124 ]; then
      log "crontab no responde: macOS espera un permiso (Ajustes > Privacidad > Acceso total al disco para la terminal/app que lo corre); solo una persona puede darlo" >&2
    fi
    return $rc
  fi
}

linea_cron() { printf '5 0,12 * * * %q >> %q 2>&1 %s' "$RENUEVA" "$LOG_RENUEVA" "$MARCA"; }

cuenta_marcadas() { crontab_actual | grep -cF -- "$MARCA" || true; }

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

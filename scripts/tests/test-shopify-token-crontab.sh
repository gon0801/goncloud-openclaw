#!/bin/bash
# Prueba desplegar.sh / checklist.sh / rollback.sh de scripts/mac/shopify-token con `launchctl`,
# `openclaw`, `curl` y renueva.sh falsos: idempotencia (bootout+bootstrap), rollback borra el
# plist y descarga el agente, y el cron de claw solo se desactiva si renueva.sh salió bien.
# Uso: bash scripts/tests/test-shopify-token-crontab.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/scripts/mac/shopify-token
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
for f in desplegar checklist rollback comun; do [ -f "$D/$f.sh" ] || fail "falta $D/$f.sh"; done

mkdir -p "$T/bin" "$T/home" "$T/LA" "$T/lcstate"
cat > "$T/bin/launchctl" <<'SH'
#!/bin/bash
# launchctl falso: "cargado" = existe $FAKE_LOADED (copia del plist); registra las llamadas.
# kickstart corre el ProgramArguments del plist cargado como launchd y guarda runs, código y salida.
echo "$*" >> "$FAKE_LC_LOG"
case "$1" in
  print)
    [ -f "$FAKE_LOADED" ] || exit 113
    runs=$(cat "$FAKE_STATE/runs" 2>/dev/null || echo 0)
    rc=$(cat "$FAKE_STATE/rc" 2>/dev/null || echo "(never exited)")
    printf '%s = {\n\tactive count = 0\n\truns = %s\n\tlast exit code = %s\n}\n' "$2" "$runs" "$rc" ;;
  bootstrap) [ -f "$FAKE_LOADED" ] && exit 5; [ -f "$3" ] || exit 1; cp "$3" "$FAKE_LOADED"; rm -f "$FAKE_STATE"/runs "$FAKE_STATE"/rc ;;
  bootout)   [ -f "$FAKE_LOADED" ] || exit 3; rm -f "$FAKE_LOADED" "$FAKE_STATE"/runs "$FAKE_STATE"/rc ;;
  kickstart)
    [ -f "$FAKE_LOADED" ] || exit 113
    python3 -I - "$FAKE_LOADED" "$FAKE_STATE" <<'PY'
import os, plistlib, subprocess, sys
d = plistlib.load(open(sys.argv[1], "rb"))
env = dict(os.environ, **d.get("EnvironmentVariables", {}))
r = subprocess.run(d["ProgramArguments"], capture_output=True, text=True, env=env)
st = sys.argv[2]
try:
    n = int(open(st + "/runs").read())
except OSError:
    n = 0
open(st + "/runs", "w").write(str(n + 1))
open(st + "/rc", "w").write(str(r.returncode))
open(st + "/out", "a").write(r.stdout + r.stderr)
PY
    ;;
  *) exit 2 ;;
esac
SH
cat > "$T/bin/openclaw" <<'SH'
#!/bin/bash
# openclaw falso: estado del cron de claw en $FAKE_CLAW ("on"/"off"); registra las llamadas
echo "$*" >> "$FAKE_CLAW_LOG"
case "$1 $2" in
  "cron disable") [ "$3" = dbc3eee3-28d4-4043-bee9-8fd584341bf8 ] && echo off > "$FAKE_CLAW" ;;
  "cron enable")  [ "$3" = dbc3eee3-28d4-4043-bee9-8fd584341bf8 ] && echo on > "$FAKE_CLAW" ;;
  "cron list")
    [ "$(cat "$FAKE_CLAW")" = on ] && en=true || en=false
    printf '{"jobs":[{"id":"otro","enabled":true},{"id":"dbc3eee3-28d4-4043-bee9-8fd584341bf8","enabled":%s}]}\n' "$en" ;;
esac
SH
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
cat > /dev/null; printf '%s' "${FAKE_HTTP:-200}"
SH
# crontab trampa: si algo lo llama, la prueba falla
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
echo "crontab llamado: $*" >> "$FAKE_CRON_TRAMPA"; exit 9
SH
cat > "$T/renueva.sh" <<'SH'
#!/bin/bash
echo x >> "$FAKE_RENUEVA_LOG"; exit "${FAKE_RENUEVA_RC:-0}"
SH
chmod +x "$T"/bin/* "$T/renueva.sh"

export FAKE_STATE=$T/lcstate SHOPIFY_TOKEN_RAIZ=$T/raiz
export FAKE_LOADED=$T/loaded FAKE_LC_LOG=$T/lc.log FAKE_CRON_TRAMPA=$T/trampa
export FAKE_CLAW=$T/claw FAKE_CLAW_LOG=$T/claw.log FAKE_RENUEVA_LOG=$T/renueva.log
export PATH="$T/bin:$PATH" OPENCLAW_BIN=$T/bin/openclaw LAUNCHCTL_BIN=$T/bin/launchctl RENUEVA=$T/renueva.sh
export LAUNCH_AGENTS_DIR=$T/LA
export SHOPIFY_TOKEN_FILE=$T/token.txt SHOPIFY_APP_JSON=$T/app.json SHOPIFY_TOKEN_LOG=$T/shopify.log
printf '{"store":"tienda-falsa.myshopify.com"}' > "$T/app.json"
printf 'tok' > "$T/token.txt"
PL=$T/LA/ai.goncloud.shopify-token.plist
reset() { rm -f "$FAKE_LOADED" "$PL"; echo on > "$FAKE_CLAW"; : > "$FAKE_LC_LOG"; : > "$FAKE_CLAW_LOG"
          : > "$FAKE_RENUEVA_LOG"; unset FAKE_RENUEVA_RC FAKE_HTTP; }
cargas() { grep -c '^bootstrap ' "$FAKE_LC_LOG"; }

# (1) desplegar: plist con 00:05 y 12:05 que corre renueva.sh, cargado, renueva corrió, claw off
reset
bash "$D/desplegar.sh" >"$T/out" 2>&1 || fail "desplegar debía salir 0: $(cat "$T/out")"
[ -f "$PL" ] || fail "desplegar: no escribió el plist"
plutil -lint "$PL" >/dev/null 2>&1 || ! command -v plutil >/dev/null || fail "desplegar: plist inválido"
grep -q '__HOME__\|__RENUEVA__' "$PL" && fail "desplegar: quedaron marcadores sin llenar"
python3 -I - "$PL" "$T/renueva.sh" <<'PY' || fail "desplegar: el plist no tiene Label/horario/programa esperados"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "ai.goncloud.shopify-token"
assert sorted((x["Hour"], x["Minute"]) for x in d["StartCalendarInterval"]) == [(0, 5), (12, 5)]
assert sys.argv[2] in d["ProgramArguments"]
PY
[ -f "$FAKE_LOADED" ] || fail "desplegar: no cargó el agente"
grep -q "^bootstrap gui/$(id -u) $PL" "$FAKE_LC_LOG" || fail "desplegar: no llamó a launchctl bootstrap gui/<uid> <plist>"
[ "$(wc -l < "$FAKE_RENUEVA_LOG" | tr -d " ")" = 1 ] || fail "desplegar: renueva.sh debía correr una vez"
[ "$(cat "$FAKE_CLAW")" = off ] || fail "desplegar: no desactivó el cron de claw"
grep -q 'cron disable dbc3eee3-28d4-4043-bee9-8fd584341bf8' "$FAKE_CLAW_LOG" || fail "desplegar: no llamó a openclaw cron disable con el id"
echo "ok 1 desplegar"

# (2) idempotencia: ya cargado → bootout y bootstrap, una sola carga viva, mismo plist
cp "$PL" "$T/pl1"; : > "$FAKE_LC_LOG"
bash "$D/desplegar.sh" >"$T/out" 2>&1 || fail "desplegar (2da) debía salir 0: $(cat "$T/out")"
grep -q '^bootout ' "$FAKE_LC_LOG" || fail "idempotencia: no hizo bootout del agente ya cargado"
[ "$(cargas)" = 1 ] || fail "idempotencia: debía hacer un bootstrap"
[ -f "$FAKE_LOADED" ] || fail "idempotencia: el agente quedó descargado"
diff "$PL" "$T/pl1" >/dev/null || fail "idempotencia: el plist cambió"
echo "ok 2 idempotencia"

# (3) checklist: pasa con todo bien
bash "$D/checklist.sh" >"$T/out" 2>&1 || fail "checklist debía salir 0: $(cat "$T/out")"
echo "ok 3 checklist ok"

# (4) checklist falla cuando cualquiera de sus condiciones se rompe
cp "$FAKE_LOADED" "$T/loaded.bak"; rm -f "$FAKE_LOADED"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó el agente sin cargar"
cp "$T/loaded.bak" "$FAKE_LOADED"
touch -t 202001010000 "$T/token.txt"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó un token viejo"
touch "$T/token.txt"
FAKE_HTTP=401 bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó shop.json 401"
echo on > "$FAKE_CLAW"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó el cron de claw activado"
echo off > "$FAKE_CLAW"
bash "$D/checklist.sh" >/dev/null 2>&1 || fail "checklist: debía volver a pasar al restaurar todo"
echo "ok 4 checklist falla"

# (5) rollback: descarga el agente, borra el plist y reactiva claw; repetirlo no falla
bash "$D/rollback.sh" >"$T/out" 2>&1 || fail "rollback debía salir 0: $(cat "$T/out")"
[ ! -e "$FAKE_LOADED" ] || fail "rollback: el agente seguía cargado"
[ ! -e "$PL" ] || fail "rollback: no borró el plist"
[ "$(cat "$FAKE_CLAW")" = on ] || fail "rollback: no reactivó el cron de claw"
bash "$D/rollback.sh" >/dev/null 2>&1 || fail "rollback repetido debía salir 0"
echo "ok 5 rollback"

# (6) si renueva.sh falla, desplegar sale ≠0 y NO desactiva el cron de claw
reset; FAKE_RENUEVA_RC=1 bash "$D/desplegar.sh" >/dev/null 2>&1 && fail "desplegar: debía salir ≠0 si renueva falla"
[ "$(cat "$FAKE_CLAW")" = on ] || fail "desplegar: desactivó claw aunque renueva falló"
echo "ok 6 renueva falla"

# (7) nada de esto toca crontab
[ ! -e "$FAKE_CRON_TRAMPA" ] || fail "se llamó a crontab: $(cat "$FAKE_CRON_TRAMPA")"
echo "ok 7 sin crontab"

# (8) la copia del motor desaparece: el plist no depende de ella
copia_motor() {
  local m=$1/.motor/tmp/despliega-shopify-token-02-A/scripts/mac
  mkdir -p "$m"; cp -R "$D" "$m/shopify-token"; cp "$D/../ai.goncloud.shopify-token.plist" "$m/"
  cp "$T/renueva.sh" "$m/shopify-token/renueva.sh"
}
reset; unset RENUEVA; rm -rf "$T/raiz" "$T/mc"; : > "$FAKE_STATE/out"; rm -f "$FAKE_STATE"/runs "$FAKE_STATE"/rc
copia_motor "$T/mc"
bash "$T/mc/.motor/tmp/despliega-shopify-token-02-A/scripts/mac/shopify-token/desplegar.sh" >"$T/out" 2>&1 \
  || fail "copia desaparece: desplegar debía salir 0: $(cat "$T/out")"
rm -rf "$T/mc"
python3 -I - "$PL" <<'PY' || fail "copia desaparece: el plist apunta a rutas que no existen o dentro de /.motor/"
import os, plistlib, sys
for a in plistlib.load(open(sys.argv[1], "rb"))["ProgramArguments"]:
    if a.startswith("/"):
        assert os.path.exists(a), "no existe " + a
        assert "/.motor/" not in a, "dentro de /.motor/: " + a
PY
"$T/bin/launchctl" kickstart -k "gui/$(id -u)/ai.goncloud.shopify-token" || fail "copia desaparece: kickstart falló"
"$T/bin/launchctl" print "gui/$(id -u)/ai.goncloud.shopify-token" | grep -q 'last exit code = 0$' \
  || fail "copia desaparece: kickstart no dejó last exit code = 0"
echo "ok 8 la copia del motor desaparece"
echo "PASS test-shopify-token-crontab"

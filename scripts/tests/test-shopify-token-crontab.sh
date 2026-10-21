#!/bin/bash
# Prueba desplegar.sh / checklist.sh / rollback.sh de scripts/mac/shopify-token con `crontab`,
# `openclaw`, `curl` y renueva.sh falsos: idempotencia, no tocar líneas ajenas, rollback deja el
# crontab como estaba, y el cron de claw solo se desactiva si renueva.sh salió bien.
# Uso: bash scripts/tests/test-shopify-token-crontab.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
D=$PWD/scripts/mac/shopify-token
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
for f in desplegar checklist rollback comun; do [ -f "$D/$f.sh" ] || fail "falta $D/$f.sh"; done

mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
# crontab falso: el "crontab" es el archivo $FAKE_CRONTAB
case "${1:-}" in
  -l) [ -f "$FAKE_CRONTAB" ] || { echo "crontab: no crontab for gon" >&2; exit 1; }; cat "$FAKE_CRONTAB" ;;
  -r) rm -f "$FAKE_CRONTAB" ;;
  -)  cat > "$FAKE_CRONTAB" ;;
  *)  exit 2 ;;
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
cat > "$T/renueva.sh" <<'SH'
#!/bin/bash
echo x >> "$FAKE_RENUEVA_LOG"; exit "${FAKE_RENUEVA_RC:-0}"
SH
chmod +x "$T"/bin/* "$T/renueva.sh"

export FAKE_CRONTAB=$T/crontab FAKE_CLAW=$T/claw FAKE_CLAW_LOG=$T/claw.log FAKE_RENUEVA_LOG=$T/renueva.log
export PATH="$T/bin:$PATH" OPENCLAW_BIN=$T/bin/openclaw RENUEVA=$T/renueva.sh
export SHOPIFY_TOKEN_FILE=$T/token.txt SHOPIFY_APP_JSON=$T/app.json SHOPIFY_TOKEN_LOG=$T/shopify.log
printf '{"store":"tienda-falsa.myshopify.com"}' > "$T/app.json"
printf 'tok' > "$T/token.txt"
reset() { printf '0 3 * * * /usr/bin/ajeno uno\n# comentario ajeno\n*/10 * * * * /usr/bin/ajeno dos\n' > "$FAKE_CRONTAB"
          echo on > "$FAKE_CLAW"; : > "$FAKE_CLAW_LOG"; : > "$FAKE_RENUEVA_LOG"; unset FAKE_RENUEVA_RC FAKE_HTTP; }
marcadas() { grep -cF '# motor:shopify-token' "$FAKE_CRONTAB"; }

# (1) desplegar: una línea marcada a las 00:05 y 12:05, ajenas intactas, renueva corrió, claw off
reset; cp "$FAKE_CRONTAB" "$T/antes"
bash "$D/desplegar.sh" >"$T/out" 2>&1 || fail "desplegar debía salir 0: $(cat "$T/out")"
[ "$(marcadas)" = 1 ] || fail "desplegar: la línea marcada debía estar una vez"
grep -F '# motor:shopify-token' "$FAKE_CRONTAB" | grep -q '^5 0,12 \* \* \* ' || fail "desplegar: horario distinto de 00:05 y 12:05"
grep -F '# motor:shopify-token' "$FAKE_CRONTAB" | grep -qF "$T/renueva.sh" || fail "desplegar: la línea no corre renueva.sh"
diff <(grep -vF '# motor:shopify-token' "$FAKE_CRONTAB") "$T/antes" >/dev/null || fail "desplegar: tocó líneas ajenas"
[ "$(wc -l < "$FAKE_RENUEVA_LOG" | tr -d " ")" = 1 ] || fail "desplegar: renueva.sh debía correr una vez"
[ "$(cat "$FAKE_CLAW")" = off ] || fail "desplegar: no desactivó el cron de claw"
grep -q 'cron disable dbc3eee3-28d4-4043-bee9-8fd584341bf8' "$FAKE_CLAW_LOG" || fail "desplegar: no llamó a openclaw cron disable con el id"
echo "ok 1 desplegar"

# (2) idempotencia: otra vez no duplica ni cambia nada
cp "$FAKE_CRONTAB" "$T/tras1"
bash "$D/desplegar.sh" >"$T/out" 2>&1 || fail "desplegar (2da) debía salir 0"
[ "$(marcadas)" = 1 ] || fail "idempotencia: línea duplicada"
diff "$FAKE_CRONTAB" "$T/tras1" >/dev/null || fail "idempotencia: el crontab cambió"
# una línea marcada duplicada o vieja se normaliza a una sola
printf '1 1 * * * /viejo # motor:shopify-token\n1 1 * * * /viejo2 # motor:shopify-token\n' >> "$FAKE_CRONTAB"
bash "$D/desplegar.sh" >"$T/out" 2>&1 || fail "desplegar (con duplicadas) debía salir 0"
[ "$(marcadas)" = 1 ] || fail "idempotencia: no normalizó las duplicadas"
grep -q '/viejo' "$FAKE_CRONTAB" && fail "idempotencia: quedó una línea marcada vieja"
echo "ok 2 idempotencia"

# (3) checklist: pasa con todo bien
bash "$D/checklist.sh" >"$T/out" 2>&1 || fail "checklist debía salir 0: $(cat "$T/out")"
echo "ok 3 checklist ok"

# (4) checklist falla cuando cualquiera de sus condiciones se rompe
printf '1 1 * * * /x # motor:shopify-token\n' >> "$FAKE_CRONTAB"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó la línea duplicada"
bash "$D/desplegar.sh" >/dev/null 2>&1
touch -t 202001010000 "$T/token.txt"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó un token viejo"
touch "$T/token.txt"
FAKE_HTTP=401 bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó shop.json 401"
echo on > "$FAKE_CLAW"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó el cron de claw activado"
echo off > "$FAKE_CLAW"
grep -vF '# motor:shopify-token' "$FAKE_CRONTAB" > "$T/sin"; cp "$T/sin" "$FAKE_CRONTAB"
bash "$D/checklist.sh" >/dev/null 2>&1 && fail "checklist: aceptó sin la línea marcada"
echo "ok 4 checklist falla"

# (5) rollback deja el crontab como estaba y reactiva claw
reset; cp "$FAKE_CRONTAB" "$T/antes"
bash "$D/desplegar.sh" >/dev/null 2>&1 || fail "desplegar previo al rollback falló"
bash "$D/rollback.sh" >"$T/out" 2>&1 || fail "rollback debía salir 0: $(cat "$T/out")"
diff "$FAKE_CRONTAB" "$T/antes" >/dev/null || fail "rollback: el crontab no quedó como estaba"
[ "$(cat "$FAKE_CLAW")" = on ] || fail "rollback: no reactivó el cron de claw"
# y sin crontab previo: queda sin crontab
rm -f "$FAKE_CRONTAB"; echo on > "$FAKE_CLAW"
bash "$D/desplegar.sh" >/dev/null 2>&1; bash "$D/rollback.sh" >/dev/null 2>&1
[ ! -s "$FAKE_CRONTAB" ] || fail "rollback: debía dejar el crontab vacío"
echo "ok 5 rollback"

# (6) si renueva.sh falla, desplegar sale ≠0 y NO desactiva el cron de claw
reset; FAKE_RENUEVA_RC=1 bash "$D/desplegar.sh" >/dev/null 2>&1 && fail "desplegar: debía salir ≠0 si renueva falla"
[ "$(cat "$FAKE_CLAW")" = on ] || fail "desplegar: desactivó claw aunque renueva falló"
echo "ok 6 renueva falla"
echo "PASS test-shopify-token-crontab"

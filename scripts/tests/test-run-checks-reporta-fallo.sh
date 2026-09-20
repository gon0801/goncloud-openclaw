#!/usr/bin/env bash
# Fase 7 (cierre): el bloque de la bateria de tablero-runbook en run-checks.sh tenia un
# filtro que no atrapaba fallos reales. Medido con el BOM de openclaw.plugin.json:
#   - `grep '^not ok '` no ve los subtests anidados (van indentados en el TAP).
#   - el mensaje de error real vive en las lineas SIGUIENTES a `error: |-` (un bloque
#     YAML), no en la propia linea `error:`.
# Resultado en produccion: la bateria en rojo solo mostraba el rotulo vacio "error: |-"
# y nunca el nombre del caso ni el mensaje real.
#
# Esta prueba arma un caso de node --test de juguete con un subtest anidado que falla,
# corre el MISMO filtro que usa run-checks.sh (scripts/tap-detalle-fallas.awk, la unica
# fuente: run-checks.sh lo invoca con `awk -f`) y exige que la salida traiga el nombre
# del caso anidado y su mensaje de error.
#
# Uso: bash scripts/tests/test-run-checks-reporta-fallo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

FILTRO=scripts/tap-detalle-fallas.awk
[ -f "$FILTRO" ] || fail "falta $FILTRO"

command -v node >/dev/null 2>&1 || fail "hace falta node para correr el caso de juguete"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

cat > "$T/juguete.test.js" <<'JS'
const { test } = require('node:test');

test('suite de juguete', async (t) => {
  await t.test('subtest anidado que revienta', () => {
    throw new Error('mensaje de error real del subtest anidado');
  });
});
JS

salida=$(cd "$T" && node --test --test-reporter tap --test-reporter-destination stdout 2>&1)
rc_juguete=$?
[ "$rc_juguete" -ne 0 ] || fail "el caso de juguete deberia fallar (rc=0)"

# El subshell `cd "$T" && ...` de arriba no cambia el cwd de esta prueba, pero el filtro
# se referencia con ruta absoluta de todos modos para no depender de donde corra awk.
FILTRO_ABS="$(pwd)/$FILTRO"
detalle=$(printf '%s\n' "$salida" | awk -f "$FILTRO_ABS")

printf '%s\n' "$detalle" | grep -qF 'subtest anidado que revienta' \
  || fail "el filtro no nombro el subtest anidado que fallo. Salida:
$detalle"

printf '%s\n' "$detalle" | grep -qF 'mensaje de error real del subtest anidado' \
  || fail "el filtro no incluyo el mensaje de error real. Salida:
$detalle"

echo "ok: el filtro nombra el subtest anidado y su mensaje de error real"
echo "TODO VERDE: run-checks-reporta-fallo"

#!/bin/bash
# Contrato de cobertura de CI (Bloque B1): la union de los tres shards publicados
# como artifacts ES la bateria completa, cada entrada exactamente una vez, y el
# gate la AUDITA de verdad antes de dar verde.
#
# POR QUE. El gate de quality.yml solo mira RESULTADOS de jobs (success/skipped).
# Ese agregado no ve CONTENIDO: si la matriz pierde una pata (un shard deja de
# correrse), el job sigue success con las patas restantes y el gate da verde con
# una fraccion de la bateria. Lo mismo vale para un resumen vacio (un shard que
# no corrio nada), un artifact que no llego, una entrada duplicada o una prueba
# fuera del inventario. Esta prueba ejecuta LA MISMA logica que decide el gate
# (scripts/valida-union-shards.sh, llamada por el workflow y por aca) contra
# sandboxes con un runner de juguete que REGISTRA invocaciones, pruebas corridas
# y exit codes; no hay ningun grep de nombres de job acreditando cobertura: los
# casos 1-13 ejecutan el validador de union, y solo el caso (w) — cableado del
# workflow, no acreditacion — mira el YAML.
#
# Los 13 casos:
#   (1)  el caso valido ejecuta la bateria logica completa y el validador sale 0
#   (2)  cada shard se invoca exactamente una vez y ninguna entrada corre dos veces
#   (3)  la union de los resumenes contiene TODO el inventario esperado
#   (4)  una entrada duplicada -> rechazo con su razon
#   (5)  una falla del runner -> el agregador (el validador) sale rojo
#   (6)  eliminar la invocacion del runner (ningun shard) -> rechazo
#   (7)  repetir la invocacion del MISMO shard sobre su artifact -> rechazo
#   (7b) un artifact de shard fuera del contrato (shard-4) -> rechazo
#   (8)  eliminar el shard 1/3 -> rechazo independiente
#   (9)  eliminar el shard 2/3 -> rechazo independiente
#   (10) eliminar el shard 3/3 -> rechazo independiente
#   (11) resumenes vacios (cero pruebas) -> rechazo
#   (12) un artifact esperado sin su resumen.txt -> rechazo
#   (13) una prueba no inventariada en la union -> rechazo
#   (w)  el workflow llama al MISMO validador que este test ejecuta, desde un job
#        propio ci-contract SIN condicion de omision, y el gate baja los tres
#        artifacts y audita la union solo cuando la bateria corrio.
#
# El arbol de juguete es el MISMO contrato del que usa
# scripts/tests/test-runner-shards.sh (mismos fixtures en
# scripts/tests/fixtures/runner-shards/): cada entrada deja una linea por
# ejecucion en un tally, asi que "corrio la bateria" es un hecho contado, no un
# grep. Uso: bash scripts/tests/test-ci-coverage-contract.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

VALIDADOR=scripts/valida-union-shards.sh
YAML=.github/workflows/quality.yml
[ -f "$VALIDADOR" ] || fail "falta $VALIDADOR: sin el, el gate no tiene logica propia para auditar la union de shards"
[ -f "$YAML" ] || fail "falta $YAML"

# Mismo fallback que scripts/run-checks.sh (elegir_node): el arbol de juguete corre
# entradas node de mentira y necesita un node >= 22.
elegir_node() {
  local c
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    local v; v=$("$c" --version 2>/dev/null | sed 's/^v//;s/\..*//')
    [ -n "$v" ] && [ "$v" -ge 22 ] 2>/dev/null && { echo "$c"; return 0; }
  done
  return 1
}
NODE=$(elegir_node) || fail "no hay un node >= 22 disponible (mismo requisito que run-checks.sh)"

T=$(mktemp -d "${TMPDIR:-/tmp}/ci-coverage-contract.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/arbol"

# --- arbol de juguete: misma receta de test-runner-shards.sh (copiada a
# proposito: modificar ESE test para extraer el montador queda fuera del alcance
# de este bloque; si un dia cambia su receta, esta copia tiene que seguir igual).
montar_arbol() {
  mkdir -p "$R/scripts/tests" "$R/summa-gate" "$R/tablero-runbook"
  cp scripts/run-checks.sh "$R/scripts/run-checks.sh"
  cp scripts/tap-detalle-fallas.awk "$R/scripts/"
  FX=scripts/tests/fixtures/runner-shards
  [ -d "$FX" ] || fail "falta $FX"
  cp "$FX/nucleo.sh"    "$R/scripts/tests/test-corrida-nucleo.sh"
  cp "$FX/watchdog.sh"  "$R/scripts/tests/test-tmux-activity-watch.sh"
  cp "$FX/preflight.sh" "$R/scripts/tests/test-corrida-preflight.sh"
  cp "$FX/resto-a.sh"   "$R/scripts/tests/test-aaa.sh"
  cp "$FX/resto-b.sh"   "$R/scripts/tests/test-zzz.sh"
  cat >"$R/tally.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$TALLY_SHARDS"
SH
  cat >"$R/summa-gate/package.json" <<'JSON'
{
  "name": "summa-gate-toy",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "check": "sh ../tally.sh sintaxis-summa && node --check verify-corpus.mjs"
  }
}
JSON
  cat >"$R/tablero-runbook/package.json" <<'JSON'
{
  "name": "tablero-runbook-toy",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "check": "sh ../tally.sh sintaxis-tablero"
  }
}
JSON
  cat >"$R/summa-gate/toy.test.js" <<'JS'
const { test } = require('node:test');
const fs = require('fs');
test('bateria summa de juguete', () => {
  fs.appendFileSync(process.env.TALLY_SHARDS, 'bateria-summa\n');
});
JS
  cat >"$R/tablero-runbook/toy.test.js" <<'JS'
const { test } = require('node:test');
const fs = require('fs');
test('bateria tablero de juguete', () => {
  fs.appendFileSync(process.env.TALLY_SHARDS, 'bateria-tablero\n');
});
JS
  cat >"$R/summa-gate/verify-corpus.mjs" <<'JS'
import fs from 'node:fs';
fs.appendFileSync(process.env.TALLY_SHARDS, 'corpus\n');
JS
}
montar_arbol

# Inventario esperado de la bateria de juguete: los 5 shell instalados (los ids
# del resumen son los BASenames, igual que en CI) mas las 5 entradas fijas de
# node/sintaxis/corpus del runner. Es el mismo inventario que el gate genera del
# checkout en quality.yml.
INVENTARIO="$T/inventario.txt"
cat >"$INVENTARIO" <<'EOF'
test-corrida-nucleo.sh
test-corrida-preflight.sh
test-tmux-activity-watch.sh
test-aaa.sh
test-zzz.sh
sintaxis-summa-gate
bateria-summa-gate
sintaxis-tablero-runbook
bateria-tablero-runbook
verify-corpus
EOF

INVOCACIONES="$T/invocaciones.txt"
TALLY_GLOBAL="$T/tally-global.txt"
: >"$INVOCACIONES"
: >"$TALLY_GLOBAL"

correr_shard() { # $1=valor SAIKIT_SHARD, $2=dir artifact destino; 0 si el runner salio 0
  local shard=$1 dest=$2 rc
  printf '%s\n' "$shard" >>"$INVOCACIONES"
  TALLY_SHARDS="$TALLY_GLOBAL" SAIKIT_SHARD="$shard" PATH="$(dirname "$NODE"):$PATH" \
    bash "$R/scripts/run-checks.sh" >"$T/salida-ultimo-shard.log" 2>&1
  rc=$?
  # CI publica el artifact TAMBIEN cuando el shard revienta (upload con if:
  # always()). Cada invocacion deja SU corrida-<marca> dentro del artifact: las
  # corridas se ACUMULAN (es lo que hace visible una re-corrida para el
  # validador, caso 7) y el resumen de la corrida fallida se publica igual.
  ultimo=$(ls -td "$R"/logs/run-checks/corrida-* 2>/dev/null | head -1)
  if [ -n "$ultimo" ] && [ -f "$ultimo/resumen.txt" ]; then
    mkdir -p "$dest/logs/run-checks"
    cp -R "$ultimo" "$dest/logs/run-checks/"
  fi
  return "$rc"
}

correr_pipeline_valido() { # $1=dir artifacts destino
  local dest=$1 shard
  rm -rf "$dest"
  mkdir -p "$dest"
  for shard in 1/3 2/3 3/3; do
    correr_shard "$shard" "$dest/shard-${shard%/*}" || return 1
  done
}

validar() { # $1=dir artifacts -> separa salida y rc como el gate
  SALIDA_VALIDADOR=$(bash "$VALIDADOR" "$1" "$INVENTARIO" 2>&1)
  RC_VALIDADOR=$?
}

ids_union() { # $1=dir artifacts -> ids de la union, orden C, uno por linea
  for r in "$1"/shard-*/resumen.txt "$1"/shard-*/logs/run-checks/*/resumen.txt; do
    [ -f "$r" ] || continue
    awk -F'\t' '$1=="ok" || $1=="falla" {print $4}' "$r"
  done | LC_ALL=C sort
}

echo "(1) el caso valido: la bateria logica completa corre y el validador sale 0"
correr_pipeline_valido "$T/ok" || fail "(1) el pipeline valido revinto:
$(cat "$T/salida-ultimo-shard.log")"
validar "$T/ok"
[ "$RC_VALIDADOR" -eq 0 ] || fail "(1) el validador rechazo la union VALIDA (rc=$RC_VALIDADOR):
$SALIDA_VALIDADOR"
esperado_tally='bateria-summa bateria-tablero corpus nucleo preflight resto-a resto-b sintaxis-summa sintaxis-tablero watchdog'
got_tally=$(LC_ALL=C sort "$TALLY_GLOBAL" | uniq | tr '\n' ' ' | sed 's/ $//')
[ "$got_tally" = "$esperado_tally" ] || fail "(1) la bateria logica corrida no es la completa.
  esperaba: $esperado_tally
  obtuvo  : $got_tally"
echo "ok (1): union valida aceptada y las 10 entradas logicas corrieron"

echo "(2) cada shard exactamente una vez y ninguna entrada corre dos veces"
n_inv=$(wc -l <"$INVOCACIONES" | tr -d ' ')
[ "$n_inv" -eq 3 ] || fail "(2) esperaba exactamente 3 invocaciones del runner, hay $n_inv: $(tr '\n' ' ' <"$INVOCACIONES")"
got_inv=$(LC_ALL=C sort -u "$INVOCACIONES" | tr '\n' ' ' | sed 's/ $//')
[ "$got_inv" = "1/3 2/3 3/3" ] || fail "(2) las invocaciones del runner no son una por shard: $got_inv"
dup_tally=$(LC_ALL=C sort "$TALLY_GLOBAL" | uniq -d)
[ -z "$dup_tally" ] || fail "(2) estas entradas corrieron mas de una vez: $dup_tally"
echo "ok (2): una invocacion por shard, cero entradas repetidas"

echo "(3) la union de los resumenes contiene TODO el inventario"
got_union=$(ids_union "$T/ok")
esp_union=$(LC_ALL=C sort "$INVENTARIO")
[ "$got_union" = "$esp_union" ] || fail "(3) la union de ids no es el inventario.
  esperaba: $esp_union
  obtuvo  : $got_union"
echo "ok (3): union == inventario, verificado fuera del validador"

echo "(4) una entrada duplicada es rechazada con su razon"
rm -rf "$T/dup"; cp -R "$T/ok" "$T/dup"
# Las filas de shard-1 se cuelan DENTRO de la unica corrida de shard-2: la
# union repite ids sin que haya una segunda corrida en el artifact (eso lo
# cubre el caso 7; aqui lo duplicado es la entrada, no la corrida).
cat "$T/dup/shard-1/logs/run-checks/"*/resumen.txt >>"$T/dup/shard-2/logs/run-checks/"*/resumen.txt
validar "$T/dup"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(4) el validador acepto ids duplicados:
$SALIDA_VALIDADOR"
grep -q 'duplicad' <<<"$SALIDA_VALIDADOR" || fail "(4) el rechazo no dice que hay duplicados:
$SALIDA_VALIDADOR"
echo "ok (4): duplicado detectado"

echo "(5) una falla del runner vuelve rojo el agregador"
# La corrida roja REEMPLAZA la corrida del shard 3 sobre una union por lo demas
# valida (el artifact nuevo trae UNA sola corrida, la roja): si se validara solo
# el shard rojo, el rechazo seria por shard faltante, y si la segunda corrida se
# acumulara, el rechazo seria por re-corrida (caso 7); ninguno de los dos
# demostraria lo que este caso mide (la fila en falla).
rm -rf "$T/rojo"; cp -R "$T/ok" "$T/rojo"
rm -rf "$T/rojo/shard-3/logs/run-checks"
cp scripts/tests/fixtures/runner-shards/roja.sh "$R/scripts/tests/test-roja.sh"
correr_shard 3/3 "$T/rojo/shard-3"
rc_roja=$?
rm -f "$R/scripts/tests/test-roja.sh"
[ "$rc_roja" -ne 0 ] || fail "(5) el shard con la prueba roja salio 0"
RES_ROJO=$(ls -td "$T/rojo/shard-3"/logs/run-checks/*/resumen.txt 2>/dev/null | head -1)
grep -q '^falla' "$RES_ROJO" || fail "(5) el resumen del shard rojo no trae la fila en falla:
$(cat "$RES_ROJO")"
validar "$T/rojo"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(5) el agregador acepto una corrida con filas en falla:
$SALIDA_VALIDADOR"
# La razon importa: en CI real la prueba roja SI esta en el inventario (sale del
# glob del checkout), asi que el rechazo por entrada desconocida no existiria y
# solo el check de filas en falla la caza. Si el rechazo llegara por otro motivo,
# este caso no estaria protegiendo lo que dice medir.
grep -q 'en rojo' <<<"$SALIDA_VALIDADOR" || fail "(5) el rechazo no fue por las filas en falla (razon equivocada):
$SALIDA_VALIDADOR"
grep -q 'test-roja.sh' <<<"$SALIDA_VALIDADOR" || fail "(5) el rechazo no nombra la prueba que fallo:
$SALIDA_VALIDADOR"
echo "ok (5): falla del runner -> agregador rojo, nombrando la prueba"

echo "(6) eliminar la invocacion del runner (cero shards) es rechazado"
rm -rf "$T/vacio"; mkdir -p "$T/vacio"
validar "$T/vacio"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(6) el validador acepto una auditoria SIN NINGUN artifact de shard:
$SALIDA_VALIDADOR"
n_inv=$(wc -l <"$INVOCACIONES" | tr -d ' ')
echo "ok (6): sin invocacion no hay verde (registradas $n_inv invocaciones acumuladas; el rechazo no depende de eso)"

echo "(7) repetir la invocacion del MISMO shard sobre el mismo artifact es rechazado"
# Medido el 2026-09-22: la version anterior de este caso inventaba un artifact
# shard-4; una re-corrida REAL del mismo shard re-escribe SU resumen.txt y el
# gate la daba por buena (el artifact queda como una corrida limpia). La
# re-corrida de verdad se simula invocando 1/3 dos veces contra el mismo dir.
rm -rf "$T/rerun"; cp -R "$T/ok" "$T/rerun"
n13_antes=$(grep -c '^1/3$' "$INVOCACIONES")
correr_shard 1/3 "$T/rerun/shard-1" || fail "(7) la primera corrida de 1/3 revinto"
correr_shard 1/3 "$T/rerun/shard-1" || fail "(7) la segunda corrida de 1/3 revinto"
n13=$(grep -c '^1/3$' "$INVOCACIONES")
[ "$((n13 - n13_antes))" -eq 2 ] || fail "(7) el registro debia sumar dos 1/3 mas, tiene $n13_antes -> $n13"
validar "$T/rerun"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(7) el validador acepto la RE-CORRIDA del mismo shard (rc=0): el artifact quedo como una sola corrida limpia y el gate no la detecta:
$SALIDA_VALIDADOR"
grep -qE 'shard 1|re-corrida|corrida' <<<"$SALIDA_VALIDADOR" || fail "(7) el rechazo no nombra la re-corrida del shard 1:
$SALIDA_VALIDADOR"
echo "ok (7): la re-corrida del mismo shard deja rastro y el gate la rechaza"

echo "(7b) un artifact de shard fuera del contrato (shard-4) es rechazado"
rm -rf "$T/dupinv"; cp -R "$T/ok" "$T/dupinv"
correr_shard 1/3 "$T/dupinv/shard-4" || fail "(7b) la invocacion extra de 1/3 revinto"
validar "$T/dupinv"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(7b) el validador acepto un artifact fuera del contrato (shard-4):
$SALIDA_VALIDADOR"
grep -q 'shard-4' <<<"$SALIDA_VALIDADOR" || fail "(7b) el rechazo no nombra el artifact inesperado:
$SALIDA_VALIDADOR"
echo "ok (7b): el artifact de mas sigue rechazado por el conjunto exacto"

echo "(8) eliminar el shard 1/3 es rechazado independientemente"
rm -rf "$T/sin1"; cp -R "$T/ok" "$T/sin1"; rm -rf "$T/sin1/shard-1"
validar "$T/sin1"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(8) el validador acepto la union sin el shard 1/3:
$SALIDA_VALIDADOR"
grep -q 'shard-1' <<<"$SALIDA_VALIDADOR" || fail "(8) el rechazo no nombra el shard que falta:
$SALIDA_VALIDADOR"
echo "ok (8): falta shard-1 -> rechazo"

echo "(9) eliminar el shard 2/3 es rechazado independientemente"
rm -rf "$T/sin2"; cp -R "$T/ok" "$T/sin2"; rm -rf "$T/sin2/shard-2"
validar "$T/sin2"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(9) el validador acepto la union sin el shard 2/3:
$SALIDA_VALIDADOR"
grep -q 'shard-2' <<<"$SALIDA_VALIDADOR" || fail "(9) el rechazo no nombra el shard que falta:
$SALIDA_VALIDADOR"
echo "ok (9): falta shard-2 -> rechazo"

echo "(10) eliminar el shard 3/3 es rechazado independientemente"
rm -rf "$T/sin3"; cp -R "$T/ok" "$T/sin3"; rm -rf "$T/sin3/shard-3"
validar "$T/sin3"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(10) el validador acepto la union sin el shard 3/3:
$SALIDA_VALIDADOR"
grep -q 'shard-3' <<<"$SALIDA_VALIDADOR" || fail "(10) el rechazo no nombra el shard que falta:
$SALIDA_VALIDADOR"
echo "ok (10): falta shard-3 -> rechazo"

echo "(11) resumenes vacios (cero pruebas) son rechazados"
rm -rf "$T/vacios"; cp -R "$T/ok" "$T/vacios"
: >"$T/vacios/shard-1/logs/run-checks/"*/resumen.txt; : >"$T/vacios/shard-2/logs/run-checks/"*/resumen.txt; : >"$T/vacios/shard-3/logs/run-checks/"*/resumen.txt
validar "$T/vacios"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(11) el validador acepto resumenes VACIOS (cero pruebas corridas):
$SALIDA_VALIDADOR"
# Razon propia: el rechazo por faltantes de union tambien dispara con resumenes
# vacios; exigir el motivo VACIO es lo que prueba que ESTE candado existe.
grep -q 'VACIO' <<<"$SALIDA_VALIDADOR" || fail "(11) el rechazo no fue por resumen vacio (razon equivocada):
$SALIDA_VALIDADOR"
echo "ok (11): un shard que no corrio nada no da verde"

echo "(12) un artifact esperado sin su resumen.txt es rechazado"
rm -rf "$T/sinlog"; cp -R "$T/ok" "$T/sinlog"; rm -f "$T/sinlog/shard-2/logs/run-checks/"*/resumen.txt
validar "$T/sinlog"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(12) el validador acepto un artifact sin resumen:
$SALIDA_VALIDADOR"
grep -q 'shard-2' <<<"$SALIDA_VALIDADOR" || fail "(12) el rechazo no nombra el artifact sin resumen:
$SALIDA_VALIDADOR"
echo "ok (12): artifact sin resumen -> rechazo"

echo "(13) una prueba no inventariada en la union es rechazada"
rm -rf "$T/intruso"; cp -R "$T/ok" "$T/intruso"
printf 'ok\t1\t0\ttest-intruso.sh\t-\n' >>"$T/intruso/shard-3/logs/run-checks/"*/resumen.txt
validar "$T/intruso"
[ "$RC_VALIDADOR" -ne 0 ] || fail "(13) el validador acepto una prueba FUERA del inventario:
$SALIDA_VALIDADOR"
grep -q 'test-intruso.sh' <<<"$SALIDA_VALIDADOR" || fail "(13) el rechazo no nombra la prueba desconocida:
$SALIDA_VALIDADOR"
echo "ok (13): intruso fuera del inventario -> rechazo"

# --- (w) cableado del workflow: mismo validador, job propio, gate que audita.
# Este caso SI mira el YAML (es cableado, no acreditacion de cobertura), con la
# misma tecnica de anclaje por seccion de test-summa-gate-quality-entrypoints.sh:
# seccion extraida por su clave, lineas de comentario afuera.
seccion() { # $1=nombre de job, $2=yaml -> texto de la seccion del job
  awk -v job="$1" '
    $0 == "  " job ":" {f=1; next}
    f && /^  [A-Za-z_][A-Za-z0-9_-]*:/ {f=0}
    f {print}
  ' "$2"
}
limpio() { # $1=texto -> sin lineas de comentario
  printf '%s\n' "$1" | grep -v '^[[:space:]]*#'
}

echo "(w) el workflow llama al MISMO validador desde un job propio sin omision, y el gate audita la union"
Y="$T/quality-extraido.yml"
cp "$YAML" "$Y"
sec_cc=$(seccion ci-contract "$Y")
[ -n "$sec_cc" ] || fail "(w) quality.yml no tiene el job ci-contract: el contrato corre dentro de la matriz que valida o no corre"
limpio "$sec_cc" | grep -qE '^[[:space:]]+run:.*bash scripts/tests/test-ci-coverage-contract\.sh' \
  || fail "(w) ci-contract no ejecuta ESTE contrato:
$sec_cc"
if limpio "$sec_cc" | grep -qE '^[[:space:]]+if:'; then
  fail "(w) ci-contract tiene condicion de omision: el contrato de cobertura no admite carril que lo salte:
$sec_cc"
fi
limpio "$sec_cc" | grep -q 'node-version' \
  || fail "(w) ci-contract no fija node: el arbol de juguete exige >= 22 y el default del runner puede ser viejo"

sec_gate=$(seccion gate "$Y")
[ -n "$sec_gate" ] || fail "(w) quality.yml no tiene la seccion gate"
GL=$(limpio "$sec_gate")
printf '%s\n' "$GL" | grep -qF 'needs: [clasificador, shards, ci-contract]' \
  || fail "(w) el gate no depende de ci-contract:
$GL"
printf '%s\n' "$GL" | grep -qF 'R_CI_CONTRACT: ${{ needs.ci-contract.result }}' \
  || fail "(w) el gate no lee el resultado de ci-contract:
$GL"
printf '%s\n' "$GL" | grep -qF 'case "$R_CI_CONTRACT" in' \
  || fail "(w) el gate no decide sobre ci-contract:
$GL"
# El validador del YAML debe ser EL MISMO archivo que este test ejecuto arriba.
path_yaml=$(printf '%s\n' "$GL" | grep -oE 'bash scripts/valida-union-shards\.sh' | head -1 | sed 's/^bash //')
[ "$path_yaml" = "$VALIDADOR" ] || fail "(w) el gate no llama al MISMO validador que este test (YAML='$path_yaml' test='$VALIDADOR')"
for n in 1 2 3; do
  printf '%s\n' "$GL" | grep -qF "logs-run-checks-shard-$n" \
    || fail "(w) el gate no baja el artifact logs-run-checks-shard-$n:
$GL"
done
printf '%s\n' "$GL" | grep -qF "if: needs.shards.result == 'success'" \
  || fail "(w) la auditoria de la union debe correr solo cuando la bateria corrio:
$GL"
printf '%s\n' "$GL" | grep -qF 'scripts/tests/*.sh' \
  || fail "(w) el gate no genera el inventario desde el glob del checkout:
$GL"
# En fast, la omision de shards sigue autorizada SOLO por clasificacion fast
# (lo mide test-summa-gate-quality-entrypoints); aca se fija que la auditoria
# condicionada no abre la puerta: la decision sigue leyendo R_SHARDS.
printf '%s\n' "$GL" | grep -qF 'R_SHARDS: ${{ needs.shards.result }}' \
  || fail "(w) el gate dejo de leer el resultado agregado de shards:
$GL"
echo "ok (w): mismo validador en YAML y test, ci-contract sin omision, gate audita la union"

echo "TODO VERDE: ci-coverage-contract"

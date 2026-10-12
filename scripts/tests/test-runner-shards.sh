#!/bin/bash
# 15.1 (carril R): el runner reparte la bateria en shards sin perder cobertura.
#
# POR QUE. La bateria completa tarda minutos y en CI quiere correrse particionada para
# bajar el reloj del PR. El riesgo clasico de repartir es el de siempre: un shard que
# "no encuentra" sus pruebas queda verde sin correr nada y la union deja de ser la
# bateria (el mismo defecto del arbol sin pruebas que el cross-review de qwen le
# encontro a run-checks.sh el 2026-09-12). Esta prueba NO corre la bateria real:
# monta un arbol de juguete (una copia de run-checks.sh + fixtures de un dia de vida
# en scripts/tests/fixtures/runner-shards/) donde CADA entrada —shell, node, sintaxis
# y corpus— deja una linea por ejecucion en un tally, y exige el contrato entero:
#   (1) SAIKIT_SHARD=1/5 a 5/5: cada shard corre EXACTAMENTE su porcion del reparto
#       por duracion (la entrada pesada queda sola), la union es TODA la bateria
#       (shell + node + sintaxis + corpus) y nada corre dos veces;
#   (2) sin SAIKIT_SHARD corre TODO, y un archivo NUEVO en el glob entra solo, a la
#       bateria completa y a exactamente un shard;
#   (3) SAIKIT_SHARD invalido (6/5, 0/5, el 1/3 del reparto viejo, x) sale != 0 sin
#       haber corrido nada;
#   (4) un arbol sin pruebas shell sale rojo en cada shard, nunca verde corriendo
#       solo las entradas fijas;
#   (5) una prueba roja se ejecuta UNA sola vez: su PRIMERA salida y su exit code
#       quedan en logs/run-checks/<prueba>.log y en resumen.txt;
#   (6) con el inventario y los pesos REALES del repo ningun shard pasa de 9 min
#       estimados (la regla de CI: un job de mas de ~10 min se reparte).
# Uso: bash scripts/tests/test-runner-shards.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FX=scripts/tests/fixtures/runner-shards
[ -d "$FX" ] || fail "falta $FX"
command -v node >/dev/null 2>&1 || fail "hace falta node para el arbol de juguete"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/tests" "$T/summa-gate" "$T/tablero-runbook"
cp scripts/run-checks.sh "$T/scripts/run-checks.sh"
# El filtro de detalle TAP: el runner lo invoca por su ruta relativa cuando la bateria
# de tablero-runbook falla. Sin la copia, un fallo de juguete imprimiria un error de
# awk que no es lo que esta prueba quiere medir.
cp scripts/tap-detalle-fallas.awk "$T/scripts/"

instalar() { cp "$FX/$1" "$T/scripts/tests/$2"; }
instalar nucleo.sh    test-corrida-nucleo.sh
instalar watchdog.sh  test-tmux-activity-watch.sh
instalar preflight.sh test-corrida-preflight.sh
instalar resto-a.sh   test-aaa.sh
instalar resto-b.sh   test-zzz.sh
instalar node.mjs     test-node-fixture.mjs
# Pesos de juguete: el nucleo "tarda" 100 s y todo lo demas 1 (sin fila = 1). Con eso el
# reparto por duracion tiene un resultado literal que esta prueba fija: el nucleo queda
# SOLO en el shard 1 y las otras diez entradas se reparten entre los otros cuatro.
printf '# juguete\n100\ttest-corrida-nucleo.sh\n' >"$T/scripts/ci-duraciones.tsv"

# Entradas node/sintaxis/corpus de juguete: lo unico que hacen es dejar su linea en el
# tally. Asi la union auditada incluye TODO lo que el runner puede correr, no solo shell.
cat >"$T/tally.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "$TALLY_SHARDS"
SH
cat >"$T/summa-gate/package.json" <<'JSON'
{
  "name": "summa-gate-toy",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "check": "sh ../tally.sh sintaxis-summa && node --check verify-corpus.mjs"
  }
}
JSON
cat >"$T/tablero-runbook/package.json" <<'JSON'
{
  "name": "tablero-runbook-toy",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "check": "sh ../tally.sh sintaxis-tablero"
  }
}
JSON
cat >"$T/summa-gate/toy.test.js" <<'JS'
const { test } = require('node:test');
const fs = require('fs');
test('bateria summa de juguete', () => {
  fs.appendFileSync(process.env.TALLY_SHARDS, 'bateria-summa\n');
});
JS
cat >"$T/tablero-runbook/toy.test.js" <<'JS'
const { test } = require('node:test');
const fs = require('fs');
test('bateria tablero de juguete', () => {
  fs.appendFileSync(process.env.TALLY_SHARDS, 'bateria-tablero\n');
});
JS
cat >"$T/summa-gate/verify-corpus.mjs" <<'JS'
import fs from 'node:fs';
fs.appendFileSync(process.env.TALLY_SHARDS, 'corpus\n');
JS

SALIDA=''
RC_RUN=0
run_runner() { # $1=SAIKIT_SHARD ('' = sin la variable), $2=tally absoluto
  # El caso '' usa env -u a proposito: esta prueba corre DENTRO del runner real, que en CI
  # se invoca como SAIKIT_SHARD=3/3 bash scripts/run-checks.sh. Sin el -u, esa variable
  # heredada convirtio el caso "sin variable corre TODO" en un shard 3 disfrazado (medido:
  # la bateria lo puso en rojo justo ahi, y no dentro de un corrida suelta).
  : >"$2"
  if [ -n "$1" ]; then
    SALIDA=$(TALLY_SHARDS="$2" SAIKIT_SHARD="$1" bash "$T/scripts/run-checks.sh" 2>&1)
  else
    SALIDA=$(TALLY_SHARDS="$2" env -u SAIKIT_SHARD bash "$T/scripts/run-checks.sh" 2>&1)
  fi
  RC_RUN=$?
}

esperar() { # $1=tally, $2=esperado (tags orden C, separados por espacio), $3=caso
  local got
  got=$(LC_ALL=C sort "$1" | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$2" ] || fail "$3: el inventario corrido no es el esperado.
    esperaba : $2
    obtuvo   : $got"
}

n_lineas() { wc -l <"$1" | tr -d ' '; }

echo "(1) cada shard corre su porcion del reparto por duracion; la union es la bateria, sin duplicados"
# Reparto literal: peso descendente (nucleo 100, el resto 1) y, a igual peso, id en
# orden C; cada entrada va al shard menos cargado (a igual carga, el de menor numero).
correr_shard_esperando() { # $1=i, $2=tally esperado (orden C)
  run_runner "$1/5" "$T/s$1"
  [ "$RC_RUN" -eq 0 ] || fail "(1) shard $1/5 salio $RC_RUN:
$SALIDA"
  esperar "$T/s$1" "$2" "(1) shard $1/5"
  grep -q 'TODO VERDE' <<<"$SALIDA" || fail "(1) el shard $1/5 en verde no dice TODO VERDE"
}
correr_shard_esperando 1 "nucleo"
grep -q 'OK    test-corrida-nucleo.sh' <<<"$SALIDA" || fail "(1) el shard 1/5 no publico en su salida la prueba que corrio:
$SALIDA"
correr_shard_esperando 2 "bateria-summa resto-a resto-b"
correr_shard_esperando 3 "bateria-tablero corpus preflight"
correr_shard_esperando 4 "node-test sintaxis-summa"
correr_shard_esperando 5 "sintaxis-tablero watchdog"

cat "$T/s1" "$T/s2" "$T/s3" "$T/s4" "$T/s5" >"$T/union"
dup=$(LC_ALL=C sort "$T/union" | uniq -d)
[ -z "$dup" ] || fail "(1) estas entradas corrieron en mas de un shard: $dup"
esperar "$T/union" "bateria-summa bateria-tablero corpus node-test nucleo preflight resto-a resto-b sintaxis-summa sintaxis-tablero watchdog" "(1) union de los cinco shards"
echo "ok (1): cada shard corrio su porcion literal, la union es la bateria completa y nada corre dos veces"

echo "(2) sin SAIKIT_SHARD corre TODO y un archivo nuevo entra solo por el glob"
instalar nuevo.sh test-nuevo-recien-llegado.sh
run_runner '' "$T/t4"
[ "$RC_RUN" -eq 0 ] || fail "(2) la bateria completa salio $RC_RUN:
$SALIDA"
esperar "$T/t4" "bateria-summa bateria-tablero corpus node-test nucleo nuevo preflight resto-a resto-b sintaxis-summa sintaxis-tablero watchdog" "(2) bateria completa"
: >"$T/union-nuevo"
for i in 1 2 3 4 5; do
  run_runner "$i/5" "$T/n$i"
  [ "$RC_RUN" -eq 0 ] || fail "(2) shard $i/5 con el archivo nuevo salio $RC_RUN:
$SALIDA"
  cat "$T/n$i" >>"$T/union-nuevo"
done
esperar "$T/union-nuevo" "bateria-summa bateria-tablero corpus node-test nucleo nuevo preflight resto-a resto-b sintaxis-summa sintaxis-tablero watchdog" "(2) union de los shards con el archivo nuevo"
echo "ok (2): sin la variable corre TODO y el archivo nuevo entro solo, a la bateria y a exactamente un shard"

echo "(3) shards invalidos salen != 0 sin correr nada"
for invalido in 6/5 0/5 1/3 x; do
  run_runner "$invalido" "$T/t5"
  [ "$RC_RUN" -ne 0 ] || fail "(3) SAIKIT_SHARD=$invalido salio 0: un shard invalido no puede pasar por verde"
  [ "$(n_lineas "$T/t5")" -eq 0 ] || fail "(3) SAIKIT_SHARD=$invalido corrio pruebas igual: $(cat "$T/t5")"
  grep -Fq "SAIKIT_SHARD='$invalido'" <<<"$SALIDA" || fail "(3) el mensaje de rechazo no nombra el shard invalido ($invalido):
$SALIDA"
done
echo "ok (3): 6/5, 0/5, 1/3 y x salen != 0 sin correr una sola entrada"

echo "(4) un arbol sin pruebas shell es rojo en cada shard, no un verde por vacio"
mkdir "$T/apartadas"
mv "$T"/scripts/tests/*.sh "$T/apartadas/"
for i in 1 2 3 4 5; do
  run_runner "$i/5" "$T/t7"
  [ "$RC_RUN" -ne 0 ] || fail "(4) el shard $i/5 quedo verde en un arbol sin una sola prueba shell:
$SALIDA"
  grep -q 'no se encontro NINGUNA prueba' <<<"$SALIDA" || fail "(4) el shard $i/5 no dice que faltan las pruebas shell:
$SALIDA"
done
mv "$T"/apartadas/*.sh "$T/scripts/tests/"
echo "ok (4): sin pruebas shell los cinco shards revientan"

echo "(5) una prueba roja: una sola ejecucion, primera salida y exit code en el log"
instalar roja.sh test-roja.sh
# Con la roja y el nuevo instalados el reparto literal deja en el shard 2:
# bateria-summa-gate, test-aaa.sh y test-roja.sh.
run_runner 2/5 "$T/t8"
[ "$RC_RUN" -ne 0 ] || fail "(5) la prueba roja no propago su fallo (salio 0)"
esperar "$T/t8" "bateria-summa resto-a roja" "(5) shard 2/5 con la roja"
n=$(grep -c '^roja$' "$T/t8")
[ "$n" -eq 1 ] || fail "(5) la prueba roja se ejecuto $n veces (esperaba 1): el runner no puede re-ejecutarla para diagnosticar"
LOG_ROJA=$(ls -td "$T"/logs/run-checks/corrida-*/test-roja.sh.log 2>/dev/null | head -1)
[ -f "$LOG_ROJA" ] || fail "(5) falta el log de la prueba roja: $LOG_ROJA"
grep -q 'PRIMERA SALIDA UNICA DE LA ROJA' "$LOG_ROJA" || fail "(5) el log no conserva la primera salida:
$(cat "$LOG_ROJA")"
grep -Eq '^# exit[[:space:]]*: 7$' "$LOG_ROJA" || fail "(5) el log no conserva el exit code real (7):
$(cat "$LOG_ROJA")"
grep -q 'PRIMERA SALIDA UNICA DE LA ROJA' <<<"$SALIDA" || fail "(5) la salida del runner no muestra la primera salida de la roja"
grep -q 'FALLA test-roja.sh' <<<"$SALIDA" || fail "(5) la salida no reporta la FALLA:
$SALIDA"
RES=$(ls -td "$T"/logs/run-checks/corrida-*/resumen.txt 2>/dev/null | head -1)
[ -f "$RES" ] || fail "(5) falta $RES"
awk -F'\t' 'BEGIN{ok=0} $1=="falla" && $3=="7" && $4=="test-roja.sh"{ok=1} END{exit ok?0:1}' "$RES" \
  || fail "(5) resumen.txt no registro la falla con su exit code:
$(cat "$RES")"
awk -F'\t' '$4=="test-roja.sh" && $2 !~ /^[0-9]+$/{bad=1} END{exit bad?1:0}' "$RES" \
  || fail "(5) la duracion de la roja no quedo registrada en resumen.txt:
$(cat "$RES")"
grep -q "$(printf 'ok\t')" "$RES" || fail "(5) resumen.txt tampoco registro las entradas verdes:
$(cat "$RES")"
echo "ok (5): una sola ejecucion; primera salida y exit code conservados en el log y el resumen"

echo "(6) con el inventario y los pesos reales ningun shard pasa de 9 min estimados"
# La regla de CI de este repo: un job de mas de ~10 min se reparte. 540 s de pruebas
# estimadas dejan margen para el checkout y la instalacion de cada runner. Si esto se
# pone rojo, el arreglo es sumar shards o partir la prueba que no cabe, no subir el tope.
REPARTO_REAL=$(env -u SAIKIT_SHARD bash scripts/run-checks.sh --reparto) || fail "(6) --reparto salio distinto de 0"
cargas=$(printf '%s\n' "$REPARTO_REAL" | awk -F'\t' '!/^#/ { c[$1] += $2 } END { for (k = 1; k <= 5; k++) printf "%d ", c[k] }')
for carga in $cargas; do
  [ "$carga" -gt 0 ] || fail "(6) un shard quedo sin carga con el inventario real: $cargas"
  [ "$carga" -le 540 ] || fail "(6) un shard pasa de 540 s estimados ($cargas): suma shards o parte la prueba que no cabe"
done
[ "$(printf '%s\n' $cargas | wc -l | tr -d ' ')" -eq 5 ] || fail "(6) el reparto real no tiene cinco shards: $cargas"
n_real=$(printf '%s\n' "$REPARTO_REAL" | grep -vc '^#')
n_unicas=$(printf '%s\n' "$REPARTO_REAL" | grep -v '^#' | cut -f3 | LC_ALL=C sort -u | wc -l | tr -d ' ')
[ "$n_real" -eq "$n_unicas" ] || fail "(6) el reparto real repite entradas ($n_real filas, $n_unicas ids)"
echo "ok (6): cargas estimadas por shard ($cargas) dentro de 540 s"

echo "TODO VERDE: runner-shards"

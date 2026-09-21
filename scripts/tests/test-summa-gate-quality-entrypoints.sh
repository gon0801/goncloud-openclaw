#!/bin/bash
# Contrato de entrypoints de calidad de summa-gate (Fase 5 / 5.2).
# Verifica: (1) el script `check` de summa-gate/package.json cubre los cuatro
# .ts fuente; (2) scripts/run-checks.sh invoca `npm run check`; (3) CI alcanza
# la bateria una sola vez de forma directa y pre-commit no la corre localmente.
# 15.2 (carril W): (6) esa unica corrida es la MATRIZ de tres shards con
# fail-fast: false y el gate depende de ella con la regla de pares; (7) fixtures
# recortados demuestran que el validador rechaza shard faltante, fallo ignorado,
# gate sin dependencia completa y gate con la dependencia escondida en un job
# señuelo — r1: la seccion gate se ancla por su clave (siembras locales, jamas
# pushes rojos) — r2: TODOS los checks del job de shards corren DENTRO de la
# seccion `shards:` anclada por su clave (un comentario u otro job satisfacia
# los tokens mientras el shards real violaba el contrato) y la matriz exige
# EXACTAMENTE tres entradas con cada valor UNA vez — r3: antes de matchear se
# quitan las lineas de COMENTARIO de cada seccion (un comentario dentro del
# propio job shards satisfacia el grep -F de la corrida shardada) y un cuarto
# entrada con valor NUEVO se rechaza por el tope de tres (fixture que solo el
# tope rechaza: el exactly-once ya atrapaba a los duplicados) — r4: el filtro
# r3 ya corria sobre TODOS los checks de texto (reasigna la seccion antes de
# cada grep), asi que el hallazgo de re-review (fail-fast, regla de pares y
# upload satisfacibles con un comentario interno) NO reproduce contra el
# validador vigente; lo que si faltaba es la COBERTURA: sin fixtures propios,
# borrar SOLO el filtro de seccion_gate dejaba la suite en verde (medido). Los
# dos fixtures nuevos fijan la cobertura por job: sin el filtro de shards
# pasan shards-run-en-comentario y shards-failfast-en-comentario; sin el de
# gate pasa gate-pareja-en-comentario. El sufijo inline ` # ...` de lineas de
# codigo sigue sin recortarse (borde r3, sin reparar aca).
# Uso: bash scripts/tests/test-summa-gate-quality-entrypoints.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Mismo fallback que scripts/run-checks.sh (elegir_node): el node del PATH
# puede no existir o ser viejo; Node 24 suele vivir fuera del PATH
# ($HOME/.openclaw/tools/...). Un `node` pelado rompe este test en esas
# maquinas aunque la bateria corra bien.
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
NODE=$(elegir_node) || fail "no hay un node >= 22 disponible (mismo fallback que run-checks.sh)"

# (1) El script check cubre los cuatro fuentes.
[ -f summa-gate/package.json ] || fail "falta summa-gate/package.json"
check=$("$NODE" -e "console.log(require('./summa-gate/package.json').scripts?.check ?? '')" 2>/dev/null) \
  || fail "no se pudo leer scripts.check de summa-gate/package.json"
[ -n "$check" ] || fail "summa-gate/package.json no tiene script check"
for f in index.ts lib.ts observer.ts diagnostic-guard.ts; do
  printf '%s' "$check" | grep -qF "$f" || fail "scripts.check no nombra $f (check=$check)"
done
echo "ok (1): scripts.check cubre index.ts, lib.ts, observer.ts y diagnostic-guard.ts"

# (2) El runner invoca el chequeo de sintaxis.
grep -q 'npm run check' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no invoca npm run check"
echo "ok (2): scripts/run-checks.sh invoca npm run check"

# (3) La bateria completa pertenece a CI, no al commit local. Un hook pesado aca
# hizo que un cambio de una linea en progress/ tardara minutos y ademas dejara
# artefactos al interrumpirse. Los hooks genericos de pre-commit siguen corriendo.
# Desde 15.2 la bateria en CI corre SOLO dentro de la matriz de shards: una
# corrida monolitica aparte pagaria la bateria dos veces, y una corrida sin
# SAIKIT_SHARD romperia la union (el resumen dejaria de cubrir cada entrada
# exactamente una vez).
grep -q 'pre-commit/action' .github/workflows/quality.yml \
  || fail "quality.yml no usa pre-commit/action"
if grep -qE '^[[:space:]]*(- id: run-checks|entry: .*scripts/run-checks\.sh)' .pre-commit-config.yaml; then
  fail "pre-commit todavia conecta la bateria completa: los commits locales deben ser rapidos"
fi
invocaciones=$(grep -cE '^[[:space:]]+run:.*scripts/run-checks\.sh' .github/workflows/quality.yml || true)
[ "$invocaciones" -eq 1 ] \
  || fail "la bateria debe invocarse en exactamente un paso (el de la matriz de shards); llega: $invocaciones"
grep -F 'run: SAIKIT_SHARD=${{ matrix.shard }} bash scripts/run-checks.sh' .github/workflows/quality.yml >/dev/null \
  || fail 'la unica corrida de la bateria debe quedar shardada por la matriz (SAIKIT_SHARD=${{ matrix.shard }})'
echo "ok (3): pre-commit es rapido y CI corre la bateria solo via los shards de la matriz"

# (3b) Los scripts del repo corren sin credenciales de escritura persistentes.
grep -qE '^permissions:$' .github/workflows/quality.yml \
  || fail "quality.yml no declara permisos minimos para GITHUB_TOKEN"
grep -qE '^[[:space:]]+contents: read[[:space:]]*$' .github/workflows/quality.yml \
  || fail "quality.yml debe limitar GITHUB_TOKEN a contents: read"
checkouts=$(grep -cE '^[[:space:]]*- uses: actions/checkout@' .github/workflows/quality.yml || true)
sin_credenciales=$(grep -cE '^[[:space:]]+persist-credentials: false[[:space:]]*$' .github/workflows/quality.yml || true)
[ "$checkouts" -gt 0 ] || fail "quality.yml no contiene checkouts que validar"
[ "$sin_credenciales" -eq "$checkouts" ] \
  || fail "cada checkout debe declarar persist-credentials: false ($sin_credenciales/$checkouts)"
echo "ok (3b): CI usa permisos de solo lectura y no persiste credenciales del checkout"

# (4) tablero-runbook (Fase 7 / 7.3): los mismos contratos de entrypoint, incluida la
# preaprobacion del dueño (package.json con check y SIN dependencies).
[ -f tablero-runbook/package.json ] || fail "falta tablero-runbook/package.json"
tr_check=$("$NODE" -e "console.log(require('./tablero-runbook/package.json').scripts?.check ?? '')" 2>/dev/null) \
  || fail "no se pudo leer scripts.check de tablero-runbook/package.json"
tr_test=$("$NODE" -e "console.log(require('./tablero-runbook/package.json').scripts?.test ?? '')" 2>/dev/null)
tr_deps=$("$NODE" -e "const d=require('./tablero-runbook/package.json').dependencies; console.log(d?Object.keys(d).length:0)" 2>/dev/null)
[ -n "$tr_check" ] || fail "tablero-runbook/package.json no tiene script check"
[ "$tr_test" = "node --test" ] || fail "tablero-runbook: scripts.test debe ser 'node --test' (llega: $tr_test)"
[ "$tr_deps" = "0" ] || fail "tablero-runbook/package.json declara dependencies: instalar dependencias esta NEGADO (preaprobaciones Fase 7)"
# El check cubre cada .ts fuente presente (excluye *.test.ts): obliga a actualizar
# scripts.check en el mismo commit que agrega una fuente nueva.
for f in $(cd tablero-runbook && ls *.ts 2>/dev/null | grep -v '\.test\.ts$'); do
  printf '%s' "$tr_check" | grep -qF "$f" || fail "tablero-runbook scripts.check no nombra $f (check=$tr_check)"
done
echo "ok (4): tablero-runbook/package.json con check completo, node --test y sin dependencies"

# (5) el runner corre la bateria de tablero-runbook CON guard de conteo: la medicion de
# Plans 7.3 es que `node --test` en un directorio sin pruebas sale 0, asi que sin el
# guard un arbol sin pruebas pasaria en verde.
grep -q 'tablero-runbook' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no corre la bateria de tablero-runbook"
grep -q '0 pass' scripts/run-checks.sh \
  || fail "scripts/run-checks.sh no tiene el guard de conteo (0 pass = FALLA) para tablero-runbook"
echo "ok (5): run-checks.sh corre tablero-runbook con guard de conteo"

# (6) Contrato de shards + gate en el workflow REAL (15.2). La misma funcion
# valida los fixtures de (7): si el validador acepta un fixture roto, no
# discrimina y esta prueba no protege nada. Solo greps de lineas de contrato
# sobre YAML que este repo controla: sin red, sin llamar a GitHub, sin parser.
contrato_shards() { # $1=yaml -> exit 0 si cumple el contrato de shards+gate
  yaml=$1
  [ -f "$yaml" ] || return 1
  # (a)-(d) y (g): checks del JOB DE SHARDS, anclados a SU seccion. r2
  # (cross-review): sobre el YAML crudo, un comentario u otro job satisfacia
  # fail-fast, los valores de shard, la dependencia del clasificador, la
  # corrida shardada o el upload de artifacts mientras el job shards REAL
  # violaba el contrato (fixture shards-en-comentario.yml, rojo medido antes
  # del arreglo). Se extrae la SECCION `shards:` por su clave (clave de job a
  # dos espacios hasta la siguiente de igual nivel o EOF, la misma tecnica del
  # gate); seccion ausente o vacia = rechazo (fail-closed).
  seccion_shards=$(awk '/^  shards:/{f=1} f && !/^  shards:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$yaml")
  [ -n "$seccion_shards" ] || return 1
  # r3 (cross-review codex): un comentario DENTRO del propio job shards
  # satisfacia los tokens del contrato — conservar `# run: SAIKIT_SHARD=...`
  # debajo de un `run:` monolitico dejaba el grep -F de (a) en verde porque el
  # -F no esta anclado y el substring vive en el comentario (fixture
  # shards-run-en-comentario.yml, rojo medido antes del arreglo). Por eso las
  # lineas de comentario COMPLETAS (primer caracter no-blanco = #) se quitan
  # de la seccion ANTES de matchear; los sufijos ` # ...` de lineas de codigo
  # NO se recortan: no hay evidencia de ese hueco y partir la linea podria
  # alterar valores legitimos. Seccion que queda vacia al filtrar = rechazo
  # (los checks de abajo fallan sobre entrada vacia, fail-closed).
  seccion_shards=$(printf '%s\n' "$seccion_shards" | grep -vE '^[[:space:]]*#' || true)
  # (a) exactamente UN paso corre la bateria, shardado por la matriz — dentro
  # del job shards
  [ "$(printf '%s\n' "$seccion_shards" | grep -cE '^[[:space:]]+run:.*scripts/run-checks\.sh' || true)" -eq 1 ] || return 1
  printf '%s\n' "$seccion_shards" | grep -F 'run: SAIKIT_SHARD=${{ matrix.shard }} bash scripts/run-checks.sh' >/dev/null || return 1
  # (b) matriz con fail-fast: false y EXACTAMENTE tres entradas de matrix
  # include, cada valor UNA vez: la union de resumen.txt cubre el glob y las
  # entradas node/sintaxis/corpus solo si los tres corren, con cada entrada
  # exactamente una vez. Duplicados (dos 1/3), entradas extra o faltantes
  # rechazan (fixture shards-duplicado.yml: dos 1/3 y ningun 3/3; el loop
  # viejo solo verificaba que APARECIERAN y aceptaba entradas de mas).
  printf '%s\n' "$seccion_shards" | grep -q 'fail-fast: false' || return 1
  [ "$(printf '%s\n' "$seccion_shards" | grep -cE '^[[:space:]]*-[[:space:]]*shard:' || true)" -eq 3 ] || return 1
  for s in 1/3 2/3 3/3; do
    [ "$(printf '%s\n' "$seccion_shards" | grep -cE "^[[:space:]]*-[[:space:]]*shard:[[:space:]]*$s[[:space:]]*\$" || true)" -eq 1 ] || return 1
  done
  # (c) los shards dependen del clasificador y solo se omiten con fast EXACTO
  # (fail-closed: carril ausente o invalido corre la bateria)
  needs_shards=$(printf '%s\n' "$seccion_shards" | grep -E '^[[:space:]]{4}needs:' || true)
  printf '%s\n' "$needs_shards" | grep -qF 'clasificador' || return 1
  printf '%s\n' "$seccion_shards" | grep -qF "carril != 'fast'" || return 1
  # (d) un fallo de shard jamas se ignora
  printf '%s\n' "$seccion_shards" | grep -q 'continue-on-error' && return 1
  # (e) el GATE — anclado por su clave, no cualquier job — depende del
  # clasificador Y de los shards. r1 (cross-review): grepear el needs completo
  # en TODO el archivo aceptaba un job señuelo con `needs: [clasificador,
  # shards]` mientras el gate real quedaba `needs: [clasificador]` (fixture
  # gate-sin-shards-senuelo.yml, rojo medido antes del arreglo). Se extrae la
  # SECCION `gate:` por su clave (clave de job a dos espacios hasta la
  # siguiente clave de igual nivel o EOF); seccion ausente o vacia = rechazo
  # (fail-closed). Dentro de la seccion, el `needs:` de nivel de job (cuatro
  # espacios) debe nombrar a los dos, en cualquier orden.
  seccion_gate=$(awk '/^  gate:/{f=1} f && !/^  gate:/ && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$yaml")
  [ -n "$seccion_gate" ] || return 1
  # r3: mismo filtro de comentarios que seccion_shards — un `# needs: [...]`
  # o un `# success:fast` dentro del propio gate satisfacian (e) y (f) igual
  # que en el job shards.
  seccion_gate=$(printf '%s\n' "$seccion_gate" | grep -vE '^[[:space:]]*#' || true)
  needs_gate=$(printf '%s\n' "$seccion_gate" | grep -E '^[[:space:]]{4}needs:' || true)
  printf '%s\n' "$needs_gate" | grep -qF 'clasificador' || return 1
  printf '%s\n' "$needs_gate" | grep -qF 'shards' || return 1
  # (f) la regla de pares: success pasa; skipped pasa SOLO con fast valido
  # (success:fast); todo lo demas rebota como "no quedo en success". r2:
  # DENTRO de la seccion gate — el texto suelto en el YAML crudo lo
  # satisfacia un comentario o el job señuelo.
  printf '%s\n' "$seccion_gate" | grep -qF 'success:fast' || return 1
  printf '%s\n' "$seccion_gate" | grep -qF 'no quedo en success' || return 1
  # (g) cada shard publica logs/run-checks/ para auditar la union sin
  # re-correr — dentro del job shards
  printf '%s\n' "$seccion_shards" | grep -q 'actions/upload-artifact' || return 1
  printf '%s\n' "$seccion_shards" | grep -q 'logs/run-checks' || return 1
  return 0
}
contrato_shards .github/workflows/quality.yml \
  || fail "quality.yml no cumple el contrato de shards+gate (15.2)"
echo "ok (6): tres shards fail-fast: false, gate con dependencia completa y regla de pares"

# (7) Sembrar fallos CON FIXTURES, nunca con pushes rojos deliberados. El fixture
# valido es un recorte del workflow real; cada roto es una mutacion UNA por una:
#   shard-faltante        la matriz pierde el 3/3 (la union deja de ser la bateria)
#   fallo-ignorado        continue-on-error en el job de shards
#   gate-sin-dependencia  el gate ya no depende de los shards
#   gate-sin-shards-senuelo  el needs completo vive en un job señuelo y el gate
#                            arranca sin los shards (r1: el validador tiene que
#                            anclar la seccion gate, no grepear todo el archivo)
#   shards-duplicado      dos entradas 1/3 y ninguna 3/3 (r2: exactamente tres
#                            entradas, cada valor UNA vez)
#   shards-en-comentario  los tokens del contrato en comentarios de OTRO job
#                            mientras el shards real viola el contrato (r2: los
#                            checks del job corren DENTRO de su seccion)
#   shards-run-en-comentario  la corrida shardada conservada como COMENTARIO
#                            dentro del propio job shards y el run real
#                            monolitico (r3: se filtran las lineas de
#                            comentario de la seccion antes de matchear)
#   shards-cuatro-entradas    CUARTA entrada con valor NUEVO (4/4): los tres
#                            valores presentes cada una vez, SOLO el tope de
#                            tres la rechaza — un duplicado de 1/3 ya lo
#                            atrapaba el exactly-once y no discriminaba el
#                            tope (r3, medido: sin la asercion -eq 3 este
#                            fixture pasa de rechazado a aceptado)
#   shards-failfast-en-comentario  `fail-fast: false` SOLO en un comentario
#                            dentro del propio job shards, estrategia real
#                            sin el (r4: el validador ya lo rechazaba — el
#                            filtro r3 cubre TODOS los checks de texto,
#                            rojo no reproduce contra f019dd5: hallazgo de
#                            re-review stale, era real contra c4c86ba —
#                            pero sin fixture propio, borrar el filtro de
#                            seccion_shards solo lo atrapaba
#                            shards-run-en-comentario y borrar el de
#                            seccion_gate no ponia NADA rojo, medido)
#   gate-pareja-en-comentario  regla de pares (`success:fast`,
#                            `no quedo en success`) SOLO en un comentario
#                            dentro del propio gate, script real exit 0
#                            (r4: idem validador; es el UNICO fixture que
#                            flipea al borrar SOLO el filtro de
#                            seccion_gate — su cobertura era un hueco)
FX=scripts/tests/fixtures/quality-shards
[ -d "$FX" ] || fail "falta $FX"
contrato_shards "$FX/workflow-valido.yml" \
  || fail "el fixture VALIDO no pasa el contrato: el validador esta roto, no discrimina"
for roto in shard-faltante fallo-ignorado gate-sin-dependencia gate-sin-shards-senuelo shards-duplicado shards-en-comentario shards-run-en-comentario shards-cuatro-entradas shards-failfast-en-comentario gate-pareja-en-comentario; do
  if contrato_shards "$FX/$roto.yml"; then
    fail "fixture $roto.yml no fue rechazado: el validador acepta $roto"
  fi
  echo "ok (7): fixture $roto.yml rechazado como corresponde"
done

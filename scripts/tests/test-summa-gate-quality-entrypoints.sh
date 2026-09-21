#!/bin/bash
# Contrato de entrypoints de calidad de summa-gate (Fase 5 / 5.2).
# Verifica: (1) el script `check` de summa-gate/package.json cubre los cuatro
# .ts fuente; (2) scripts/run-checks.sh invoca `npm run check`; (3) CI alcanza
# la bateria una sola vez de forma directa y pre-commit no la corre localmente.
# 15.2 (carril W): (6) esa unica corrida es la MATRIZ de tres shards con
# fail-fast: false y el gate depende de ella con la regla de pares; (7) fixtures
# recortados demuestran que el validador rechaza shard faltante, fallo ignorado
# y gate sin dependencia completa (siembras locales, jamas pushes rojos).
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
  # (a) exactamente UN paso corre la bateria, shardado por la matriz
  [ "$(grep -cE '^[[:space:]]+run:.*scripts/run-checks\.sh' "$yaml" || true)" -eq 1 ] || return 1
  grep -F 'run: SAIKIT_SHARD=${{ matrix.shard }} bash scripts/run-checks.sh' "$yaml" >/dev/null || return 1
  # (b) matriz con fail-fast: false y EXACTAMENTE los tres shards: la union de
  # resumen.txt cubre el glob y las entradas node/sintaxis/corpus solo si los
  # tres corren; un shard faltante deja cobertura muerta.
  grep -q 'fail-fast: false' "$yaml" || return 1
  for s in 1/3 2/3 3/3; do
    grep -qF "shard: $s" "$yaml" || return 1
  done
  # (c) los shards dependen del clasificador y solo se omiten con fast EXACTO
  # (fail-closed: carril ausente o invalido corre la bateria)
  grep -qF 'needs: [clasificador]' "$yaml" || return 1
  grep -qF "carril != 'fast'" "$yaml" || return 1
  # (d) un fallo de shard jamas se ignora
  grep -q 'continue-on-error' "$yaml" && return 1
  # (e) el gate depende del clasificador Y de los shards
  grep -qE '^    needs: \[clasificador, shards\]' "$yaml" || return 1
  # (f) la regla de pares: success pasa; skipped pasa SOLO con fast valido
  # (success:fast); todo lo demas rebota como "no quedo en success"
  grep -qF 'success:fast' "$yaml" || return 1
  grep -qF 'no quedo en success' "$yaml" || return 1
  # (g) cada shard publica logs/run-checks/ para auditar la union sin re-correr
  grep -q 'actions/upload-artifact' "$yaml" || return 1
  grep -q 'logs/run-checks' "$yaml" || return 1
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
FX=scripts/tests/fixtures/quality-shards
[ -d "$FX" ] || fail "falta $FX"
contrato_shards "$FX/workflow-valido.yml" \
  || fail "el fixture VALIDO no pasa el contrato: el validador esta roto, no discrimina"
for roto in shard-faltante fallo-ignorado gate-sin-dependencia; do
  if contrato_shards "$FX/$roto.yml"; then
    fail "fixture $roto.yml no fue rechazado: el validador acepta $roto"
  fi
  echo "ok (7): fixture $roto.yml rechazado como corresponde"
done

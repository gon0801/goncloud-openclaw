#!/bin/bash
# Contrato CI-una-vez-por-bloque (orden del dueno 2026-10-18; patron portado
# de goncloud-Orbit, PR 477). La bateria completa corre UNA vez por bloque:
#   (1) en un PR en draft NO corre la bateria (solo clasificador, ci-contract
#       y checks documentales); `ready_for_review` -- y synchronize/reopened/
#       opened de un PR que NO es draft -- dispara la matriz de shards UNA
#       vez sobre el SHA final;
#   (2) el gate exige shards=success en un PR que NO es draft con carril
#       completo; en draft, shards=skipped sigue siendo valido;
#   (3) en push a main/master, si el arbol empujado es identico al de la
#       cabeza del PR y sus cinco patas de shards quedaron en success, el
#       veredicto se REUSA (.github/scripts/reusar_completa.sh); ante
#       cualquier duda se corre (fail-closed hacia CORRER, nunca hacia saltar).
# El carril fast de docs no cambia y no se duplica: ese verde rapido YA era el
# reuso de verde documental, y un PR fast no deja patas de shards que reusar.
#
# Ademas ejercita el script de reuso con un doble de gh, sin red y SIN
# heredar variables GIT_*: un hook de git exporta GIT_DIR/GIT_INDEX_FILE/
# GIT_WORK_TREE y, heredadas por los subprocess, el git del repo temporal
# pegaria contra el repo REAL (incidente 2026-10-18 en Orbit: GIT_DIR del
# hook pre-push reinicializo el repo y le puso core.bare=true).
# Uso: bash scripts/tests/test-ci-una-vez-por-bloque.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

WF=.github/workflows/quality.yml
SCRIPT=.github/scripts/reusar_completa.sh
SCRIPT_ABS=$PWD/.github/scripts/reusar_completa.sh
[ -f "$WF" ] || fail "falta $WF"
[ -f "$SCRIPT" ] || fail "falta $SCRIPT"

# seccion <archivo> <clave>: el bloque del job `  clave:` (clave a dos
# espacios) hasta la siguiente clave de igual nivel o EOF, SIN lineas de
# comentario: un comentario dentro del propio job no debe satisfacer los
# greps (tecnica y leccion de test-summa-gate-quality-entrypoints.sh).
seccion() {
  awk -v clave="$2" \
    '$0 == "  " clave ":" {f=1; next} f && /^  [A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$1" \
    | grep -vE '^[[:space:]]*#'
}

# ── (1) Draft sin bateria; ready corre UNA vez ─────────────────────────────
on=$(awk '/^on:/{f=1; next} f && /^[A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$WF")
[ -n "$on" ] || fail "quality.yml no declara disparadores"
printf '%s\n' "$on" | grep -qF 'types: [opened, synchronize, reopened, ready_for_review]' \
  || fail "pull_request debe dispararse en ready_for_review: es el paso donde la bateria corre UNA vez sobre el SHA final (tras el APROBADO)"

shards=$(seccion "$WF" shards)
[ -n "$shards" ] || fail "falta el job shards"
printf '%s\n' "$shards" | grep -qF 'needs: [clasificador, reuso]' \
  || fail "los shards deben depender del clasificador y del reuso"
printf '%s\n' "$shards" | grep -qF "if: needs.clasificador.outputs.carril != 'fast' && needs.reuso.outputs.reusar != 'true'" \
  || fail "los shards corren salvo carril fast o reuso; en pull_request el reuso no corre y su output vacio mantiene la corrida"

reuso=$(seccion "$WF" reuso)
[ -n "$reuso" ] || fail "falta el job reuso (reuso del veredicto por arbol)"
printf '%s\n' "$reuso" | grep -qF "if: github.event_name == 'push'" \
  || fail "el reuso SOLO aplica en push a main/master"
printf '%s\n' "$reuso" | grep -qF 'GH_TOKEN: ${{ github.token }}' \
  || fail "el reuso usa github.token: sin tokens nuevos"
printf '%s\n' "$reuso" | grep -qF 'run: bash .github/scripts/reusar_completa.sh' \
  || fail "el reuso debe invocar el script de reuso"
printf '%s\n' "$reuso" | grep -qF 'reusar: ${{ steps.reuso.outputs.reusar }}' \
  || fail "el job reuso debe exponer reusar como output"
printf '%s\n' "$reuso" | grep -qF 'persist-credentials: false' \
  || fail "el checkout del reuso no debe persistir credenciales"
echo "ok (1): draft sin bateria; ready_for_review dispara los shards; reuso solo en push con github.token"

# ── (2) El gate exige la bateria en PR no draft con carril completo ────────
gate=$(seccion "$WF" gate)
[ -n "$gate" ] || fail "falta el job gate"
printf '%s\n' "$gate" | grep -qF 'needs: [clasificador, shards, ci-contract, reuso]' \
  || fail "el gate debe depender tambien del reuso"
printf '%s\n' "$gate" | grep -qF 'EVENTO: ${{ github.event_name }}' \
  || fail "el gate necesita saber el evento"
printf '%s\n' "$gate" | grep -qF 'DRAFT: ${{ github.event.pull_request.draft }}' \
  || fail "el gate necesita saber si el PR es draft"
printf '%s\n' "$gate" | grep -qF 'REUSO: ${{ needs.reuso.outputs.reusar }}' \
  || fail "el gate necesita el veredicto del reuso"
printf '%s\n' "$gate" | grep -qF '"$EVENTO" = "pull_request" ] && [ "$DRAFT" != "true" ] && [ "$CARRIL" = "completo" ] && [ "$R_SHARDS" != "success" ]' \
  || fail "el gate debe exigir shards=success en PR no draft con carril completo (2)"
printf '%s\n' "$gate" | grep -qF 'exit 1' \
  || fail "sin bateria en PR no draft con carril completo, el gate falla con exit 1"
printf '%s\n' "$gate" | grep -qF '[ "$DRAFT" = "true" ]' \
  || fail "en draft, shards=skipped sigue siendo valido: la bateria llega al pasar a ready"
printf '%s\n' "$gate" | grep -qF '[ "$REUSO" = "true" ]' \
  || fail "el reuso debe autorizar shards=skipped en push (veredicto reusado)"
printf '%s\n' "$gate" | grep -qF 'success:fast' \
  || fail "la omision autorizada por fast debe seguir viva (carril de docs, no se duplica ni se quita)"
echo "ok (2): gate exige shards=success en PR no draft con carril completo; draft, fast y reuso autorizan la omision"

# ── (3) El script de reuso, fijado en su texto ─────────────────────────────
grep -qF 'reusar=false' "$SCRIPT" \
  || fail "el default del reuso es NO reusar: sin veredicto confirmado se corre la bateria"
grep -qF 'se corre la bateria completa' "$SCRIPT" \
  || fail "el fallback del reuso es CORRER, jamas saltar (fail-closed hacia correr)"
grep -qF 'startswith("shards")' "$SCRIPT" \
  || fail "el reuso debe leer las patas de shards de la cabeza del PR (la bateria vive en la matriz)"
grep -qF 'select(.conclusion != "success")' "$SCRIPT" \
  || fail "el reuso exige TODAS las patas de shards en success"
echo "ok (3): script de reuso con default reusar=false y fallback hacia correr"

# ── (4) Permisos minimos de lectura, sin tokens nuevos ─────────────────────
perms=$(awk '/^permissions:/{f=1; next} f && /^[A-Za-z_][A-Za-z0-9_-]*:/{f=0} f' "$WF")
printf '%s\n' "$perms" | grep -qF 'contents: read' \
  || fail "permisos: contents: read es el piso"
printf '%s\n' "$perms" | grep -qF 'pull-requests: read' \
  || fail "el reuso necesita leer el PR asociado al commit empujado"
printf '%s\n' "$perms" | grep -qF 'checks: read' \
  || fail "el reuso necesita leer los check runs de la cabeza del PR"
echo "ok (4): permisos de solo lectura (contents, pull-requests, checks)"

# ── (5) Escenario del reuso con doble de gh (sin red, sin GIT_*) ───────────
# Todos los subprocess (git incluidos) corren con un entorno SIN variables
# GIT_*: heredadas de un hook de git pegarian contra el repo real.
limpiar_git_env() {
  while IFS= read -r linea; do
    k=${linea%%=*}
    case $k in
      GIT_*) unset "$k" ;;
    esac
  done < <(env)
}

git_limpio() { # git_limpio <repo> <args de git...>: git sin GIT_* heredadas
  (
    cd "$1" || exit 9
    limpiar_git_env
    exec git "${@:2}"
  )
}

correr_reuso() { # correr_reuso <repo> <archivo_salida> <escena_json>: stdout y rc del script real
  (
    cd "$1" || exit 9
    limpiar_git_env
    PATH="$1/doble:$PATH"
    export PATH ESCENA="$3" GITHUB_OUTPUT="$2" GH_REPO="dueno/g"
    bash "$SCRIPT_ABS"
  )
}

TMP=$(mktemp -d) || fail "no se pudo crear el directorio temporal"
trap 'rm -rf "$TMP"' EXIT
repo="$TMP/repo"
mkdir -p "$repo/doble"
cat >"$repo/doble/gh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
assert args[0] == "api", args
url = args[1]
escena = json.loads(os.environ["ESCENA"])
if url.endswith("/pulls"):
    clave = "pulls"
elif url.endswith("/check-runs"):
    clave = "check-runs"
else:
    clave = "arbol"
accion = escena[clave]
if accion == "FALLO":
    sys.exit(1)
if not isinstance(accion, str):
    accion = json.dumps(accion)
sys.stdout.write(accion)
PY
chmod +x "$repo/doble/gh"

(
  cd "$repo" || exit 9
  limpiar_git_env
  git init -q -b master .
  printf 'contenido\n' >archivo.txt
  git add .
  git -c user.email=t@t -c user.name=t commit -qm uno
) || fail "no se pudo armar el repo temporal del escenario"

sha=$(git_limpio "$repo" rev-parse HEAD)
arbol=$(git_limpio "$repo" rev-parse 'HEAD^{tree}')
patas=$(jq -cn '[range(1; 6) | {name: ("shards (\(.)/5)"), conclusion: "success", html_url: ("https://ci/run/\(.)")}]') \
  || fail "no se pudo armar el payload de patas"
pulls_ok=$(jq -cn --arg sha "$sha" '[{number: 7, head: {sha: $sha}}]')
arbol_ok=$(jq -cn --arg arbol "$arbol" '{commit: {tree: {sha: $arbol}}}')
arbol_malo='{"commit":{"tree":{"sha":"0000000000000000000000000000000000000000"}}}'
checks_ok=$(jq -cn --argjson patas "$patas" '{check_runs: $patas}')
escena=$(jq -cn --argjson p "$pulls_ok" --argjson a "$arbol_ok" --argjson c "$checks_ok" '{pulls: $p, arbol: $a, "check-runs": $c}')

# 5a) Arbol identico + las cinco patas en success en la cabeza -> REUSA.
salida="$TMP/salida-5a.txt"; : >"$salida"
stdout=$(correr_reuso "$repo" "$salida" "$escena") || fail "5a: el script de reuso jamas debe fallar (rc != 0)"
grep -q 'reusar=true' "$salida" || fail "5a: mismo arbol ya validado debe reusarse (salida: $(cat "$salida"))"
printf '%s' "$stdout" | grep -qF "$sha" || fail "5a: debe imprimir la cabeza del PR reusada"
echo "ok (5a): arbol identico con las cinco patas en success -> reusar=true"

# 5b) Arbol distinto (la base avanzo y no se mezclo) -> CORRE la bateria.
escena=$(jq -cn --argjson p "$pulls_ok" --argjson a "$arbol_malo" --argjson c "$checks_ok" '{pulls: $p, arbol: $a, "check-runs": $c}')
salida="$TMP/salida-5b.txt"; : >"$salida"
correr_reuso "$repo" "$salida" "$escena" >/dev/null || fail "5b: el script de reuso jamas debe fallar"
grep -q 'reusar=false' "$salida" || fail "5b: arbol distinto nunca se reusa (salida: $(cat "$salida"))"
echo "ok (5b): arbol distinto de la cabeza del PR -> reusar=false (corre)"

# 5c) gh falla (red, rate limit) -> CORRE: fail-closed hacia correr.
escena='{"pulls": "FALLO", "arbol": "FALLO", "check-runs": "FALLO"}'
salida="$TMP/salida-5c.txt"; : >"$salida"
correr_reuso "$repo" "$salida" "$escena" >/dev/null || fail "5c: el script de reuso jamas debe fallar"
grep -q 'reusar=false' "$salida" || fail "5c: consulta fallida cae a correr, jamas a saltar (salida: $(cat "$salida"))"
echo "ok (5c): gh roto -> reusar=false (corre)"

# 5d) Sin PR asociado (push directo) -> CORRE.
escena=$(jq -cn --argjson a "$arbol_ok" --argjson c "$checks_ok" '{pulls: [], arbol: $a, "check-runs": $c}')
salida="$TMP/salida-5d.txt"; : >"$salida"
correr_reuso "$repo" "$salida" "$escena" >/dev/null || fail "5d: el script de reuso jamas debe fallar"
grep -q 'reusar=false' "$salida" || fail "5d: sin PR no hay veredicto que reusar (salida: $(cat "$salida"))"
echo "ok (5d): push directo sin PR -> reusar=false (corre)"

# 5e) 5d-variante: PR fast de docs (patas de shards en skipped) -> CORRE.
patas_skip=$(printf '%s' "$patas" | jq '[.[] | .conclusion = "skipped"]')
checks_skip=$(jq -cn --argjson p "$patas_skip" '{check_runs: $p}')
escena=$(jq -cn --argjson p "$pulls_ok" --argjson a "$arbol_ok" --argjson c "$checks_skip" '{pulls: $p, arbol: $a, "check-runs": $c}')
salida="$TMP/salida-5e.txt"; : >"$salida"
correr_reuso "$repo" "$salida" "$escena" >/dev/null || fail "5e: el script de reuso jamas debe fallar"
grep -q 'reusar=false' "$salida" || fail "5e: un PR fast no deja bateria que reusar (salida: $(cat "$salida"))"
echo "ok (5e): patas de shards en skipped (PR fast de docs) -> reusar=false (corre)"

# ── (6) Regresion GIT_*: el entorno hostil de un hook no pega al repo real ─
centinela="$TMP/centinela"
mkdir -p "$centinela"
(
  cd "$centinela" || exit 9
  limpiar_git_env
  git init -q -b master .
  printf 'sentinela\n' >archivo.txt
  git add .
  git -c user.email=t@t -c user.name=t commit -qm centinela
) || fail "no se pudo armar el repo centinela"
instantanea() {
  printf '%s\n%s\n%s\n' \
    "$(git_limpio "$centinela" config core.bare)" \
    "$(git_limpio "$centinela" rev-parse HEAD)" \
    "$(git_limpio "$centinela" ls-files -s)"
}
antes=$(instantanea)

# Entorno hostil del hook, apuntando AL CENTINELA (jamas al repo real): el
# escenario completo debe ignorar estas variables por completo. Si falta el
# filtro de GIT_*, el git del repo temporal mutaria el centinela y la
# instantanea posterior cambiaria.
(
  export GIT_DIR="$centinela/.git"
  export GIT_INDEX_FILE="$centinela/.git/index"
  escenario="$TMP/escenario-hostil"
  mkdir -p "$escenario/doble"
  cp "$repo/doble/gh" "$escenario/doble/gh"
  cd "$escenario" || exit 9
  limpiar_git_env
  git init -q -b master .
  printf 'contenido\n' >archivo.txt
  git add .
  git -c user.email=t@t -c user.name=t commit -qm uno
) || fail "el escenario hostil no debio fallar"
despues=$(instantanea)
[ "$antes" = "$despues" ] \
  || fail "el repo centinela cambio (core.bare, HEAD o indice): el GIT_* del hook se colo en los subprocess del escenario"
echo "ok (6): GIT_* hostil del hook deja intacto el repo apuntado (regresion 2026-10-18)"

echo "ok: contrato CI-una-vez-por-bloque completo (disparadores, gate, reuso por arbol, doble de gh y centinela GIT_*)"

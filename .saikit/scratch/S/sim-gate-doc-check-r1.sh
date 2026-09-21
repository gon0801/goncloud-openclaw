#!/bin/bash
# sim-gate-doc-check-r1.sh -- simulacion local del bloqueante 2 de la r1.
#
# Extrae LITERALES de .github/workflows/quality.yml:
#   - el paso "Checks documentales del rango" del job clasificador, y
#   - el paso "Carril valido y jobs de calidad en su carril" del gate,
# y los corre contra repos de juguete para afirmar la matriz de estados:
#   A. fast + progress sin schema      -> doc-check rojo  -> clasificador failure -> gate RECHAZA
#   B. fast + docs validos             -> doc-check verde -> clasificador success -> gate PASA (quality skipped autorizado)
#   C. mixto + evidencia sin titulo    -> doc-check rojo  -> clasificador failure -> gate RECHAZA (aunque quality corra)
#   D. fast + fila de Plans.md de 4 col-> doc-check rojo  -> clasificador failure -> gate RECHAZA
#   E. fast + solo 15-sesiones.txt     -> doc-check verde (nada que validar) -> gate PASA
#
# El clasificador es el real (scripts/clasificar-cambio.sh); los resultados de
# los pasos se traducen a job results como los veria GitHub y el paso del gate
# decide con ellos. Uso: bash .saikit/scratch/S/sim-gate-doc-check-r1.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
RAIZ=$(pwd)
W=.github/workflows/quality.yml
CLASIFICADOR=scripts/clasificar-cambio.sh
ALLOWLIST=scripts/ci-fast-allowlist.txt

# El host de mac tiene el python3 de brew roto; el paso usa `python3` como en
# CI (en el runner es el del sistema). /usr/bin primero para que resuelva a uno
# que funciona. En CI esto es un no-op.
PATH=/usr/bin:$PATH
export PATH

# git hermetico, mismo cuidado que scripts/tests/test-clasificador-cambio.sh.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX 2>/dev/null
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fails=0
ok()   { printf '  OK    %s\n' "$1"; }
falla(){ printf '  FALLA %s\n' "$1"; fails=$((fails + 1)); }

extraer_run() { # $1: substring unico del "- name:"; imprime el cuerpo de su run: |
  awk -v nom="$1" '
    /^      - name:/ { act = ($0 ~ nom) }
    act && /^        run: \|/ { grab = 1; next }
    grab {
      if ($0 ~ /^          /) { print substr($0, 11); next }
      if ($0 == "") { print ""; next }
      exit
    }
  ' "$W"
}

PASO_DOCS=$(extraer_run "Checks documentales")
PASO_GATE=$(extraer_run "Carril valido")
[ -n "$PASO_DOCS" ] || { echo "FAIL: quality.yml no tiene el paso 'Checks documentales del rango'"; exit 1; }
[ -n "$PASO_GATE" ] || { echo "FAIL: quality.yml no tiene el paso del gate (Carril valido)"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/sim-doc-check.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT INT TERM

sembrar_sim() { # $1: repo de juguete con la semilla y su commit base
  local d=$1
  mkdir -p "$d/docs/evidence" "$d/.saikit/progress" "$d/summa-gate"
  printf '| Task | Contenido | DoD | Depends | Status |\n' > "$d/Plans.md"
  printf '|---|---|---|---|---|\n'                          >> "$d/Plans.md"
  printf '| 14.1 | algo | algo | - | cc:TODO |\n'            >> "$d/Plans.md"
  printf '{"schema":"runbook-progress.v1","fase":"14"}\n' > "$d/.saikit/progress/14.json"
  printf '# Evidencia base\n' > "$d/docs/evidence/base.md"
  printf 'export const A=1\n' > "$d/summa-gate/lib.ts"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=sim -c user.email=sim@test commit -qm semilla
}

# Un "run" del job clasificador sobre el repo $1: clasifica con el script real
# y corre el paso de doc-check extraido del workflow. Devuelve por variables:
#   SIM_CARRIL (stdout del clasificador), SIM_CLAS_RC, SIM_DOC_RC.
correr_clasificador() { # $1: repo
  local d=$1 b h
  b=$(git -C "$d" rev-parse HEAD~1)
  h=$(git -C "$d" rev-parse HEAD)
  SIM_CARRIL=$( cd "$d" && bash "$RAIZ/$CLASIFICADOR" --allowlist "$RAIZ/$ALLOWLIST" \
      --base "$b" --head "$h" 2>/dev/null )
  SIM_CLAS_RC=$?
  ( cd "$d" && EVENTO=push PR_BASE= PR_HEAD= PUSH_BASE="$b" PUSH_HEAD="$h" \
      bash -c "$PASO_DOCS" ) >"$T/doc.log" 2>&1
  SIM_DOC_RC=$?
}

correr_gate() { # $1: repo; usa SIM_CARRIL/SIM_CLAS_RC/SIM_DOC_RC; devuelve SIM_GATE_RC
  local d=$1 r_clas r_qual
  if [ "$SIM_CLAS_RC" -eq 0 ] && [ "$SIM_DOC_RC" -eq 0 ]; then r_clas=success; else r_clas=failure; fi
  if [ "$SIM_CARRIL" = "fast" ]; then r_qual=skipped; else r_qual=success; fi
  ( cd "$d" && R_CLASIFICADOR="$r_clas" CARRIL="$SIM_CARRIL" R_QUALITY="$r_qual" \
      bash -c "$PASO_GATE" ) >"$T/gate.log" 2>&1
  SIM_GATE_RC=$?
}

# <nombre> <repo> <carril esperado> <doc rc esperado> <gate rc esperado>
afirmar() {
  local nombre=$1 d=$2 carril=$3 docrc=$4 gaterc=$5
  if [ "$SIM_CARRIL" != "$carril" ]; then
    falla "$nombre: carril '$SIM_CARRIL', esperaba '$carril'"; return
  fi
  if [ "$SIM_DOC_RC" != "$docrc" ]; then
    falla "$nombre: doc-check rc=$SIM_DOC_RC, esperaba $docrc ($(tail -1 "$T/doc.log"))"; return
  fi
  if [ "$SIM_GATE_RC" != "$gaterc" ]; then
    falla "$nombre: gate rc=$SIM_GATE_RC, esperaba $gaterc ($(tail -1 "$T/gate.log"))"; return
  fi
  ok "$nombre -> carril=$carril doc=$docrc gate=$gaterc"
}

commit_sim() { git -C "$1" add -A; git -C "$1" -c user.name=sim -c user.email=sim@test commit -qm cambio; }

# A. fast + progress sin la clave schema: JSON parseable pero fuera del
# contrato runbook-progress.v1 -> el doc-check rebota el job y el gate no
# autoriza la omision de quality.
d=$T/A-fast-progress-sin-schema; sembrar_sim "$d"
printf '{"fase": "15"}\n' > "$d/.saikit/progress/15.json"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar A-fast-progress-sin-schema "$d" fast 1 1

# A2. fast + progress que ni siquiera parsea como JSON.
d=$T/A2-fast-progress-no-json; sembrar_sim "$d"
printf '{"fase": \n' > "$d/.saikit/progress/15.json"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar A2-fast-progress-no-json "$d" fast 1 1

# B. fast + todos los contratos validos -> gate PASA con quality skipped
# autorizado por clasificacion fast valida.
d=$T/B-fast-docs-validos; sembrar_sim "$d"
printf '{"schema":"runbook-progress.v1","fase":"15"}\n' > "$d/.saikit/progress/15.json"
printf '# Nueva evidencia\ncon contenido\n' > "$d/docs/evidence/nueva.md"
printf '| 15.9 | algo | algo | - | cc:TODO |\n' >> "$d/Plans.md"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar B-fast-docs-validos "$d" fast 0 0

# C. mixto (codigo + evidencia sin titulo): carril completo, quality corre, PERO
# el doc-check sigue rojo -> el clasificador muere y el gate rebota igual.
d=$T/C-mixto-evidencia-sin-titulo; sembrar_sim "$d"
printf 'export const A=2\n' > "$d/summa-gate/lib.ts"
printf 'evidencia sin titulo\n' > "$d/docs/evidence/roto.txt"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar C-mixto-evidencia-sin-titulo "$d" completo 1 1

# D. fast + fila del ledger tocada con 4 columnas: Plans.md esta en la
# allowlist, pero la fila tocada por el diff rompe el contrato de 5 columnas.
d=$T/D-fast-fila-4-columnas; sembrar_sim "$d"
printf '| 15.9 | a | b | cc:TODO |\n' >> "$d/Plans.md"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar D-fast-fila-4-columnas "$d" fast 1 1

# D2. fast + evidencia vacia: el contrato exige evidencia no vacia.
d=$T/D2-fast-evidencia-vacia; sembrar_sim "$d"
: > "$d/docs/evidence/vacia.txt"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar D2-fast-evidencia-vacia "$d" fast 1 1

# E. fast + solo un archivo sin contrato que validar (15-sesiones.txt): el paso
# pasa -- valida lo que cambio, no es un chequeo vacio del arbol entero.
d=$T/E-fast-sin-docs-contractuales; sembrar_sim "$d"
printf 'sesion 15\n' > "$d/.saikit/progress/15-sesiones.txt"
commit_sim "$d"; correr_clasificador "$d"; correr_gate "$d"
afirmar E-fast-sin-docs-contractuales "$d" fast 0 0

if [ "$fails" -gt 0 ]; then
  echo "ROJO: $fails escenario(s) del sim en fallo"
  exit 1
fi
echo "TODO VERDE: sim-gate-doc-check-r1 (7 escenarios)"

#!/bin/bash
# Candado de scripts/plans-fila-check.sh: el doc-check de quality.yml revisa
# las 5 columnas tambien en filas con letra (14.13a), que antes se saltaba.
# Ademas corre el brazo REAL de Plans.md del workflow sobre un diff de
# juguete: sin eso, quitar el `cut -c2-` del pipeline (filas con '+' que no
# casan con nada) deja el doc-check mudo con esta prueba en verde.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
chk=scripts/plans-fila-check.sh

printf '%s\n' '| 14.1 | a | b | c | cc:TODO |' | bash "$chk" 2>/dev/null \
  || fail "rechazo una fila numerica valida"
printf '%s\n' '| 14.13a | a | b | c | cc:TODO |' | bash "$chk" 2>/dev/null \
  || fail "rechazo una fila con letra valida"
if printf '%s\n' '| 14.1 | a | b | cc:TODO |' | bash "$chk" 2>/dev/null; then
  fail "acepto una fila numerica con 4 columnas"
fi
if printf '%s\n' '| 14.13a | a | b | cc:TODO |' | bash "$chk" 2>/dev/null; then
  fail "acepto una fila con letra y 4 columnas"
fi
printf '%s\n' '| Etapa | x |' | bash "$chk" 2>/dev/null \
  || fail "reviso una fila que no es del ledger"
grep -qF 'scripts/plans-fila-check.sh' .github/workflows/quality.yml \
  || fail "quality.yml no usa scripts/plans-fila-check.sh"
grep -qF '(14.13a)' .github/workflows/quality.yml \
  || fail "el comentario del brazo de Plans.md no menciona la letra final del id"

# El brazo REAL de Plans.md del doc-check, de punta a punta sobre un diff de
# juguete: se extrae el paso literal de quality.yml y se corre en un repo de
# juguete con scripts/plans-fila-check.sh sembrado, igual que en CI.
W=.github/workflows/quality.yml
PASO_DOCS=$(awk -v nom="Checks documentales" '
  /^      - name:/ { act = ($0 ~ nom) }
  act && /^        run: \|/ { grab = 1; next }
  grab {
    if ($0 ~ /^          /) { print substr($0, 11); next }
    if ($0 == "") { print ""; next }
    exit
  }
' "$W")
[ -n "$PASO_DOCS" ] || fail "quality.yml no tiene el paso 'Checks documentales del rango'"

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX 2>/dev/null
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
PATH=/usr/bin:$PATH
export PATH
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

juguete() { # $1: fila 14.13a a agregar tras la semilla
  d=$T/repo
  rm -rf "$d"
  mkdir -p "$d/scripts"
  cp "$chk" "$d/scripts/plans-fila-check.sh"
  printf '| Task | Contenido | DoD | Depends | Status |\n' >  "$d/Plans.md"
  printf '|---|---|---|---|---|\n'                        >> "$d/Plans.md"
  printf '| 14.1 | a | b | - | cc:TODO |\n'               >> "$d/Plans.md"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@test commit -qm semilla
  printf '%s\n' "$1" >> "$d/Plans.md"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@test commit -qm fila
}

brazo() { # el paso extraido, sobre el rango semilla..fila del repo de juguete
  ( cd "$T/repo" && EVENTO=push PR_BASE= PR_HEAD= \
      PUSH_BASE="$(git -C "$T/repo" rev-parse HEAD~1)" \
      PUSH_HEAD="$(git -C "$T/repo" rev-parse HEAD)" \
      bash -c "$PASO_DOCS" ) 2>&1
}
brazo_pr() { # el mismo paso con el evento de un PR (14.24 R2): rango en PR_*
  ( cd "$T/repo" && EVENTO=pull_request PUSH_BASE= PUSH_HEAD= \
      PR_BASE="$(git -C "$T/repo" rev-parse HEAD~1)" \
      PR_HEAD="$(git -C "$T/repo" rev-parse HEAD)" \
      bash -c "$PASO_DOCS" ) 2>&1
}

juguete '| 14.13a | a | b | cc:TODO |'
salida=$(brazo); rc=$?
[ "$rc" -ne 0 ] || fail "el brazo real acepto una fila 14.13a de 4 columnas: $salida"
printf '%s\n' "$salida" | grep -q 'doc-check: RECHAZADO' \
  || fail "fila 14.13a de 4 columnas sin RECHAZADO: $salida"
salida=$(brazo_pr); rc=$?
[ "$rc" -ne 0 ] || fail "en pull_request el brazo real acepto una fila 14.13a de 4 columnas: $salida"
printf '%s\n' "$salida" | grep -q 'doc-check: RECHAZADO' \
  || fail "en pull_request, fila 14.13a de 4 columnas sin RECHAZADO: $salida"

juguete '| 14.13a | a | b | c | cc:TODO |'
salida=$(brazo); rc=$?
[ "$rc" -eq 0 ] || fail "el brazo real rechazo una fila 14.13a valida: $salida"
printf '%s\n' "$salida" | grep -q 'doc-check: OK' \
  || fail "fila 14.13a valida sin 'doc-check: OK': $salida"
salida=$(brazo_pr); rc=$?
[ "$rc" -eq 0 ] || fail "en pull_request el brazo real rechazo una fila 14.13a valida: $salida"

echo "VERDE: plans-fila-check"

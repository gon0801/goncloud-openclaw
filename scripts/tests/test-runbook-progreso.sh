#!/bin/bash
# La regla 8 "Progreso escrito, no contado" de docs/runbooks/autopilot-fase6.md
# obliga al lead a escribir el JSON runbook-progress.v1 en cada cambio de
# estado de un carril o de la cola, y al cierre: copia local en
# .saikit/progress/ y envio con runbook.progress.set. Sin esa regla versionada,
# el tablero de la Fase 7 no tiene fuente de datos y pinta humo con buena cara.
#
# Esta prueba ancla la regla con seis frases literales mas una anti-ancla: si
# el runbook dijera que la interfaz "calcula" o "infiere" el progreso, el dato
# dejaria de venir del lead (el Reject de la Fase 7 en Plans.md).
#
# El rojo se demuestra contra el padre del commit que introdujo las anclas
# (f8acd56, padre de 7fbcb9a), no contra origin/main, que ya las trae:
#   RUNBOOK=/tmp/fase6-previo.md bash scripts/tests/test-runbook-progreso.sh  # ROJO
#   bash scripts/tests/test-runbook-progreso.sh                               # VERDE
#
# Uso: bash scripts/tests/test-runbook-progreso.sh
#      RUNBOOK=<ruta> bash scripts/tests/test-runbook-progreso.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

RUNBOOK="${RUNBOOK:-docs/runbooks/autopilot-fase6.md}"
[ -r "$RUNBOOK" ] || fail "no encuentro el runbook: $RUNBOOK"

anclas() {
  local f=$1 a
  for a in 'runbook.progress.set' \
           '.saikit/progress/' \
           'no detiene nada' \
           'atencion_requerida' \
           'eventos clave' \
           'docs/spec/runbook-progress.v1.md'; do
    grep -qF "$a" "$f" || { printf 'falta el ancla: %s\n' "$a"; return 1; }
  done
  return 0
}

limpio() {
  # Sale 0 si ninguna linea junta "interfaz" con "calcula"/"infiere".
  ! grep -qiE 'interfaz.*(calcula|infiere)' "$1"
}

# (1) Las seis anclas sobre el runbook.
motivo=$(anclas "$RUNBOOK") || fail "$RUNBOOK: $motivo"
echo "ok (1): las seis anclas de la regla 8 estan en $RUNBOOK"

# (2) La anti-ancla sobre el runbook.
limpio "$RUNBOOK" \
  || fail "$RUNBOOK dice que la interfaz calcula o infiere el progreso"
echo "ok (2): el runbook no pone a la interfaz a calcular ni inferir"

# (3) Discriminacion: la comprobacion tiene que fallar sobre archivos que no
# traen la regla, y la anti-ancla sobre las dos formas prohibidas. Sin esto,
# un patron roto pasaria en verde sin mirar nada.
SONDA=$(mktemp)
trap 'rm -f "$SONDA"' EXIT
printf 'regla 8 sin anclas\n' > "$SONDA"
anclas "$SONDA" >/dev/null 2>&1 \
  && fail "las anclas pasan sobre un archivo sin la regla: no discriminan"
for verbo in calcula infiere; do
  {
    printf 'envio con runbook.progress.set --params @.saikit/progress/fase6.json\n'
    printf 'si falla, no detiene nada: se anota en eventos\n'
    printf 'cada escritura lleva atencion_requerida y reconstruye los eventos clave\n'
    printf 'forma en docs/spec/runbook-progress.v1.md\n'
    printf 'la interfaz %s el progreso desde los PRs\n' "$verbo"
  } > "$SONDA"
  anclas "$SONDA" >/dev/null 2>&1 \
    || fail "la sonda con las seis anclas no pasa las anclas: falso negativo"
  limpio "$SONDA" \
    && fail "la anti-ancla no caza 'la interfaz $verbo el progreso'"
done
{
  printf 'envio con runbook.progress.set --params @.saikit/progress/fase6.json\n'
  printf 'si falla, no detiene nada: se anota en eventos\n'
  printf 'cada escritura lleva atencion_requerida y reconstruye los eventos clave\n'
  printf 'forma en docs/spec/runbook-progress.v1.md\n'
  printf 'el progreso lo escribe el lead; la interfaz solo lo pinta\n'
} > "$SONDA"
motivo=$(anclas "$SONDA") || fail "sonda limpia rechazada por las anclas: $motivo"
limpio "$SONDA" || fail "sonda limpia marcada por la anti-ancla: falso positivo"
echo "ok (3): las anclas discriminan y la anti-ancla caza calcula/infiere sin falsos positivos"

echo "PASS test-runbook-progreso"

#!/bin/bash
# 96-mutantes.sh — mutaciones del DoD 9.6 sobre scripts/mac/corrida/responder.sh:
# cada mutante debe poner la batería ROJA; si alguna queda verde, el mutante
# sobrevivió (exit 1). Restaura el original al terminar (cp, jamas reescribe a
# mano). Uso: bash .saikit/scratch/P/96-mutantes.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
RESP=scripts/mac/corrida/responder.sh
BAT=scripts/tests/test-corrida-responder.sh
cp "$RESP" "$RESP.orig-96" || exit 1
restaura() { cp "$RESP.orig-96" "$RESP" 2>/dev/null || true; }
trap restaura EXIT

muta() { # $1 descripción, $2 patrón sed; corre la batería y exige ROJO
  sed -i.bak "$2" "$RESP" && rm -f "$RESP.bak"
  if ! cmp -s "$RESP" "$RESP.orig-96"; then
    printf 'MUTANTE: %s\n' "$1"
  else
    printf 'MUTANTE: %s — APLICACION FALLIDA (patrón no encontrado)\n' "$1"
    exit 1
  fi
  if bash "$BAT" >/dev/null 2>&1; then
    printf '  >> SOBREVIVIO (bateria verde): mal\n'
    exit 1
  else
    printf '  >> ROJO (bateria lo caza): bien\n'
  fi
  restaura
}

# 1) Sin relectura TOCTOU: la pantalla cambiada entre lectura y envío ya no
#    detiene la tecla (resp_relee siempre "intacta").
muta "sin relectura (TOCTOU fuera)" 's/^  \[ -n "\$c" \] \&\& \[ "\$c" = "\$2" \]$/  return 0/'

# 2) Sin lista dura: el comando cae directo a la tabla del registro, así que un
#    "git push origin main" con fila Aprobado se aceptaría con tecla.
muta "sin lista dura" 's/^    if resp_lista_dura "\$comando"; then$/    if false; then/'

# Vuelta al original y batería verde de sanity.
restaura
cmp -s "$RESP" "$RESP.orig-96" || { printf 'no quedo igual que el original\n'; exit 1; }
rm -f "$RESP.orig-96"
trap - EXIT
bash "$BAT" >/dev/null 2>&1 || { printf 'la batería no volvió a verde tras restaurar\n'; exit 1; }
printf 'RESTAURADO: batería en verde de nuevo\n'

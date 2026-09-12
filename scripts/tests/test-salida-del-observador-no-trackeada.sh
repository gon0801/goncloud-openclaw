#!/bin/bash
# El gateway tiene su clon de este repo en ~/.openclaw, asi que TODO lo que un plugin escriba
# bajo ~/.openclaw/<algo> cae DENTRO del repo. El observador de summa-gate escribe
# summa-gate/rendiciones.jsonl en cada turno, y trackearlo costo dos cosas el 2026-09-12:
#
#  1. El arbol del gateway quedaba sucio entre snapshots, asi que el sync fallaba con
#     "cannot pull with rebase: You have unstaged changes" y el gateway dejo de recibir
#     codigo nuevo por ~1 h. El sync loguea el fallo pero sale con exit 0, asi que nadie se
#     enteraba: el sintoma era "mergee el PR y el gateway sigue con el codigo viejo".
#  2. El snapshot automatico lo commiteo a GitHub (7d909f2) con 22 lineas que incluian
#     previews de las respuestas de scout e ingenieria. Es dato de medicion, no fuente.
#
# Esta prueba exige que la salida del observador este ignorada y sin trackear. Si algun dia
# otro plugin escribe dentro del repo, agregalo a ARCHIVOS.
# Uso: bash scripts/tests/test-salida-del-observador-no-trackeada.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { echo "FAIL: $1"; exit 1; }

ARCHIVOS=(
  summa-gate/rendiciones.jsonl
)

# (1) Ni trackeado ni trackeable: el .gitignore tiene que cubrirlo.
for f in "${ARCHIVOS[@]}"; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    fail "$f esta TRACKEADO: ensucia el arbol del gateway en cada turno y rompe el pull del sync"
  fi
  git check-ignore -q "$f" \
    || fail "$f no esta en .gitignore: el auto-commit del snapshot lo va a volver a subir"
done
echo "ok (1): ${#ARCHIVOS[@]} salida(s) del observador ignoradas y sin trackear"

# (2) El patron tambien tiene que cubrir las rotaciones, que llevan sufijo de timestamp.
ROT="summa-gate/rendiciones.jsonl.1789245777936.1.jsonl"
git check-ignore -q "$ROT" \
  || fail ".gitignore no cubre las rotaciones ($ROT): entrarian al repo al rotar"
echo "ok (2): el patron cubre los archivos rotados"

# (3) Discriminacion: el .gitignore no puede ser tan ancho que ignore el codigo del plugin.
# Sin esto, un `summa-gate/*` cumpliria (1) y (2) y dejaria de versionar el plugin entero.
# `--no-index` es obligatorio aca: sin el, `git check-ignore` NO reporta los archivos que
# estan en el indice, asi que la comprobacion pasaria siempre y no discriminaria. Detectado
# mutando el .gitignore a `summa-gate/*`: el mutante sobrevivia en verde.
for necesario in summa-gate/observer.ts summa-gate/index.ts summa-gate/lib.ts; do
  git check-ignore -q --no-index "$necesario" \
    && fail ".gitignore ignora $necesario: el patron es demasiado ancho y saca el plugin del repo"
  git ls-files --error-unmatch "$necesario" >/dev/null 2>&1 \
    || fail "$necesario no esta trackeado; la comprobacion (3) no estaria mirando el plugin real"
done
echo "ok (3): el codigo del plugin sigue versionado (el patron no es demasiado ancho)"

echo "PASS test-salida-del-observador-no-trackeada"

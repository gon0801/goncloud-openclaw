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
git check-ignore -q --no-index "$ROT" \
  || fail ".gitignore no cubre las rotaciones ($ROT): entrarian al repo al rotar"
echo "ok (2): el patron cubre los archivos rotados"

# (2b) Preventivo por FORMA: el siguiente plugin que escriba un .jsonl o un .log bajo
# summa-gate/ tiene que quedar fuera sin que nadie se acuerde de agregarlo. El auto-commit
# del snapshot corre `add -A` antes del pull, asi que lo que no este ignorado entra.
for futuro in summa-gate/otro-medidor.jsonl summa-gate/debug.log; do
  git check-ignore -q --no-index "$futuro" \
    || fail ".gitignore no cubre $futuro por forma: el proximo plugin que escriba ahi entra al repo"
done
echo "ok (2b): el patron cubre por forma (*.jsonl y *.log), no solo por nombre"

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

# (4) tablero-runbook (Fase 7 / 7.4): el SEGUNDO plugin, mismo contrato. Su estado vive
# fuera del clon (decision del spike 7.0), asi que no hay archivo vivo que vigilar hoy;
# lo que se exige es la FORMA: .jsonl y .log bajo tablero-runbook/ ignorados, y el
# patron sin roturas para el codigo versionado del plugin.
for futuro in tablero-runbook/events-local.jsonl tablero-runbook/debug.log tablero-runbook/6.jsonl.1.jsonl; do
  git check-ignore -q --no-index "$futuro" \
    || fail ".gitignore no cubre $futuro por forma: si el estado cae en el clon, el snapshot lo sube"
done
echo "ok (4): la salida potencial de tablero-runbook esta ignorada por forma"

# (5) Discriminacion para tablero-runbook: mismo mutante que (3), otro plugin. Un
# `tablero-runbook/*` pasaria (4) y dejaria el plugin fuera del repo.
for necesario_tr in tablero-runbook/lib.ts tablero-runbook/index.ts; do
  git check-ignore -q --no-index "$necesario_tr" \
    && fail ".gitignore ignora $necesario_tr: el patron es demasiado ancho"
done
git ls-files --error-unmatch tablero-runbook/lib.ts >/dev/null 2>&1 \
  || echo "aviso: tablero-runbook/lib.ts todavia no esta en el indice (primer commit del plugin)"
echo "ok (5): el codigo de tablero-runbook sigue versionado"

echo "PASS test-salida-del-observador-no-trackeada"

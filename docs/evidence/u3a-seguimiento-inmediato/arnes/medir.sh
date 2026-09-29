#!/bin/bash
# Arnes de medicion 19.0 (U3a B1): UNA finalizacion real de <token> hacia el
# aviso del seguimiento previo, con servidor tmux propio (-L), estado de
# corrida propio y transporte doblado (openclaw-falso). Deja tiempos y
# artefactos en salidas/<token>/ bajo docs/evidence/u3a-seguimiento-inmediato/.
# Negado si algun inyectable apunta al estado o al gateway real.
# uso: medir.sh <token> [--relanzo]   (token: claude|kimi|codex|zcode|grok)
set -uo pipefail

TOKEN=${1:-}
MODO=${2:-}
case "$TOKEN" in
  claude|kimi|codex|zcode|grok) ;;
  falso) [ -n "${ARNES_TSV:-}" ] || { echo "token falso exige ARNES_TSV" >&2; exit 2; } ;;
  *) echo "uso: medir.sh <token> [--relanzo]" >&2; exit 2;;
esac
[ "$MODO" = "" ] || [ "$MODO" = "--relanzo" ] || { echo "modo desconocido: $MODO" >&2; exit 2; }

ARNES="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ARNES/../../../.." && pwd)"
CORRIDA="$REPO/scripts/mac/corrida.sh"
WATCHER="$REPO/scripts/mac/tmux-activity-watch.sh"
TSV="${ARNES_TSV:-$REPO/scripts/mac/cli-modos.tsv}"
BASE="arnes19-$TOKEN-$(date +%H%M%S)"
WORK="$ARNES/.tmp/$BASE"
SALIDA="$ARNES/salidas/$TOKEN"
ID="arnes19-$TOKEN"
SESION="medicion-$TOKEN"

export TMUX_BIN="$ARNES/tmux-arnes"
export ARNES_SOCKET="u3a19-$$"
export OPENCLAW_BIN="$ARNES/openclaw-falso"
export DOBLE_LOG="$WORK/doble.jsonl"
export CORRIDA_STATE="$WORK/estado"
export CORRIDA_BIN="$CORRIDA"
export STATE_DIR="$WORK/watch"
export LOG_FILE="$WORK/watch.log"
export QUIET_SECS=10 TICK_SECS=2 LATIDO_SECS=1800 CORR_TOPE_RED=5

case "$CORRIDA_STATE" in "$HOME/.local/state"*) echo "NEGADO: CORRIDA_STATE apunta al estado real" >&2; exit 2;; esac
[ "$(basename "$OPENCLAW_BIN")" = "openclaw-falso" ] || { echo "NEGADO: OPENCLAW_BIN no es el doble" >&2; exit 2; }
[ "$(basename "$TMUX_BIN")" = "tmux-arnes" ] || { echo "NEGADO: TMUX_BIN no es el envoltorio" >&2; exit 2; }

mkdir -p "$WORK/repo" "$WORK/watch" "$CORRIDA_STATE" "$SALIDA"
cd "$WORK/repo"
git init -q
git config user.email arnes@local
git config user.name arnes
printf 'arnes 19.0\n' > README.md
git add README.md && git commit -qm "arnes"

printf '# Corrida de medicion %s\n\nUna parte: crear resultado.txt.\n' "$TOKEN" > "$WORK/runbook.md"
printf 'Trabajo unico: crea el archivo resultado.txt en la raiz del repositorio con exactamente el texto MEDICION-19.0-%s (una linea). Usalo con tu herramienta nativa de escritura de archivos, no con comandos de terminal. No hagas nada mas: ni commit, ni preguntas, ni archivos extra. Si algo te lo impide, escribe el motivo en bloqueo.txt con tu herramienta de archivos y termina.\n' "$TOKEN" > "$WORK/encargo.txt"

WATCH_PID=""
SONDEO_PID=""
CARRERA_PID=""
limpiar() {
  [ -n "$CARRERA_PID" ] && kill "$CARRERA_PID" 2>/dev/null
  [ -n "$SONDEO_PID" ] && kill "$SONDEO_PID" 2>/dev/null
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null
  wait 2>/dev/null
  "$TMUX_BIN" kill-server 2>/dev/null
}
trap 'RC=$?; limpiar; exit $RC' EXIT

: > "$DOBLE_LOG"
# La sesion de arranque mantiene vivo el servidor propio: su entorno global
# lleva el doble al hook Stop de los CLIs que arranquen dentro.
"$TMUX_BIN" new-session -d -s arranque -x 80 -y 24 "sleep 3600" 2>/dev/null
"$TMUX_BIN" set-environment -g OPENCLAW_BIN "$OPENCLAW_BIN"
"$TMUX_BIN" set-environment -g DOBLE_LOG "$DOBLE_LOG"

"$WATCHER" >"$WORK/watch.out" 2>&1 &
WATCH_PID=$!
sleep 1

python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "$SESION" "$WORK/repo/resultado.txt" \
  "$WORK/sondeo.jsonl" --tope 300 &
SONDEO_PID=$!

if [ "$TOKEN" = claude ] || [ "$TOKEN" = codex ] || [ "$TOKEN" = kimi ]; then
  # Precalentamiento: la espera de barra de lanzar-sesion (10 s) no alcanza
  # cuando el primer arranque trae el dialogo de confianza y los hooks de
  # sesion. La confianza queda por carpeta, asi que esta sesion previa la
  # responde y muere; la sesion medida arranca ya confiada.
  fila_tsv="$(LC_ALL=C awk -F'\t' -v t="$TOKEN" '$1==t {print $2 "\t" $3 "\t" $4; exit}' "$TSV")"
  bin_cal="$(printf '%s' "$fila_tsv" | cut -f1)"
  flag_cal="$(printf '%s' "$fila_tsv" | cut -f2)"
  barra_cal="$(printf '%s' "$fila_tsv" | cut -f3)"
  "$TMUX_BIN" new-session -d -s "$SESION" -x 200 -y 50 -c "$WORK/repo" \
    "/usr/bin/env PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH\" $bin_cal $flag_cal" 2>/dev/null
  i_cal=0
  while [ "$i_cal" -lt 90 ]; do
    "$ARNES/responder-confianza.sh" "$TOKEN" "$SESION" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 || true
    "$TMUX_BIN" capture-pane -p -t "=$SESION:" 2>/dev/null | grep -qF -- "$barra_cal" && break
    sleep 1
    i_cal=$((i_cal + 1))
  done
  "$TMUX_BIN" kill-session -t "=$SESION" 2>/dev/null
  (
    i=0
    while [ "$i" -lt 60 ]; do
      "$ARNES/responder-confianza.sh" "$TOKEN" "$SESION" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 && exit 0
      sleep 0.5
      i=$((i + 1))
    done
  ) &
  CARRERA_PID=$!
fi

{
  "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes \
    --cli-modos "$TSV" --canal-de arnes-canal --simulacro &&
  "$CORRIDA" lanzar-sesion "$ID" lead "$TOKEN" "$WORK/repo" --nombre "$SESION" \
    --encargo "$WORK/encargo.txt"
} >"$WORK/lanzar.out" 2>&1
LANZAR_RC=$?

if [ "$LANZAR_RC" -ne 0 ]; then
  printf '{"veredicto":"LANZAMIENTO-FALLO","token":"%s"}\n' "$TOKEN" > "$WORK/times.json"
  cp "$WORK/lanzar.out" "$SALIDA/lanzar.$(date +%H%M%S).out"
  echo "medir: lanzamiento fallo (ver $SALIDA)" >&2
  exit 1
fi

wait $SONDEO_PID 2>/dev/null
SONDEO_PID=""
sleep $((QUIET_SECS + 2 * TICK_SECS + 6))

if [ "$MODO" = "--relanzo" ]; then
  "$TMUX_BIN" kill-session -t "=$SESION" 2>/dev/null
  python3 - "$WORK/sondeo-relevo.jsonl" <<'PY'
import json, sys, time
d = {"ev": "cierre-simulado", "mono_ns": time.monotonic_ns(),
     "wall": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())}
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(d) + "\n")
PY
  python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "$SESION" "$WORK/repo/resultado.txt" \
    "$WORK/sondeo-relevo.jsonl" --tope 120 --actividad
fi

kill "$WATCH_PID" 2>/dev/null
WATCH_PID=""
"$CORRIDA" cerrar "$ID" >"$WORK/cerrar.out" 2>&1 || true

python3 "$ARNES/calcular-tiempos.py" "$WORK" "$TOKEN" "$QUIET_SECS" "$TICK_SECS" > "$WORK/times.json"
VEREDICTO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["veredicto"])' "$WORK/times.json")

ESTAMPA="$(date +%H%M%S)"
"$TMUX_BIN" capture-pane -p -t "=$SESION:" >"$WORK/pane-final.log" 2>/dev/null
cp "$WORK/pane-final.log" "$SALIDA/pane-final.$ESTAMPA.log" 2>/dev/null
cp "$WORK/doble.jsonl" "$SALIDA/doble.$ESTAMPA.jsonl"
cp "$WORK/sondeo.jsonl" "$SALIDA/sondeo.$ESTAMPA.jsonl"
[ -f "$WORK/sondeo-relevo.jsonl" ] && cp "$WORK/sondeo-relevo.jsonl" "$SALIDA/sondeo-relevo.$ESTAMPA.jsonl"
cp "$WORK/watch.log" "$SALIDA/watch.$ESTAMPA.log" 2>/dev/null
cp "$WORK/lanzar.out" "$SALIDA/lanzar.$ESTAMPA.out"
cp "$CORRIDA_STATE/$ID/registro.json" "$SALIDA/registro.$ESTAMPA.json" 2>/dev/null
cp "$WORK/times.json" "$SALIDA/times.$ESTAMPA.json"

printf '%s %s\n' "$TOKEN" "$VEREDICTO"
[ "$VEREDICTO" = "OK" ] || [ "$VEREDICTO" = "OK-CON-RESERVAS" ]

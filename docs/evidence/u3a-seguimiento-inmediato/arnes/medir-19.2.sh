#!/bin/bash
# Arnes 19.2 (B3 cierre): cadena de transiciones reales del recorrido completo.
# Cada transicion k: el trabajador k (CLI del anillo) termina su encargo con
# requisitos cumplidos (resultado-k.txt valido + cola estable) -> la maquinaria
# real (vigia + aviso durable + atender) lo entrega -> el brazo mecanico del
# dueno (declarado: lanza el siguiente del anillo pre-planificado) levanta al
# trabajador k+1 -> la transicion cierra cuando k+1 muestra trabajo verificable
# (sesion viva; actividad como corroboration). 20 transiciones = 4 vueltas al
# anillo de 5 CLIs: cada CLI termina 4 veces y es destino 4 veces.
# Casos APARTE (no cuentan en las 20 normales): perdida de aviso (el brazo
# ignora un pendiente y no debe duplicarse nada), caida recuperable del vigia
# (recuperacion <60 s desde el relanzamiento), reversa del seguimiento
# (CORRIDA_AVISOS=0 devuelve el fin a vigia-mac y no escribe pendientes).
# Todo en sandbox: tmux -L propio, CORRIDA_STATE propio, pasarela openclaw
# (system event NEGADO cerrado salvo la sesion propia), hook Stop negado.
# uso: medir-19.2.sh <n-transiciones>   (def. 20; las vueltas cierran el anillo)
set -uo pipefail

N=${1:-20}
case "$N" in ''|*[!0-9]*) echo "uso: medir-19.2.sh [n]" >&2; exit 2;; esac

ARNES="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ARNES/../../../.." && pwd)"
CORRIDA="$REPO/scripts/mac/corrida.sh"
WATCHER="$REPO/scripts/mac/tmux-activity-watch.sh"
TSV="$REPO/scripts/mac/cli-modos.tsv"
OPENCLAW_REAL="${OPENCLAW_REAL_BIN:-$HOME/.openclaw/bin/openclaw}"
WORK="$ARNES/.tmp/r19-2"
SALIDA="$ARNES/salidas/19-2"
ANILLO=(zcode codex kimi grok claude)

export TMUX_BIN="$ARNES/tmux-arnes"
export ARNES_SOCKET="u3a192-$$"
export OPENCLAW_BIN="$ARNES/openclaw-pasarela"
export OPENCLAW_REAL_BIN="$OPENCLAW_REAL"
export DOBLE_LOG="$WORK/doble.jsonl"
export CORRIDA_STATE="$WORK/estado"
export CORRIDA_BIN="$CORRIDA"
export STATE_DIR="$WORK/watch"
export LOG_FILE="$WORK/watch.log"
export QUIET_SECS=10 TICK_SECS=2 LATIDO_SECS=1800 CORR_TOPE_RED=5

case "$CORRIDA_STATE" in "$HOME/.local/state"*) echo "NEGADO: CORRIDA_STATE apunta al estado real" >&2; exit 2;; esac
[ "$(basename "$OPENCLAW_BIN")" = "openclaw-pasarela" ] || { echo "NEGADO: falta la pasarela" >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/repo" "$WORK/watch" "$CORRIDA_STATE" "$SALIDA"
cd "$WORK/repo"
git init -q
git config user.email arnes@local
git config user.name arnes
printf 'arnes 19.2\n' > README.md
git add README.md && git commit -qm "arnes 19.2"

ID="arnes192-$(date +%H%M%S)"
printf '# Corrida de cierre 19.2\n\nCadena de %s transiciones reales.\n' "$N" > "$WORK/runbook.md"
printf '%s\n' "$N" > "$WORK/exigidas.txt"  # F1 (C2-r1): la N PEDIDA, contra la que se compara cumplen
TOTAL=$((N + 1))
k=0
while [ "$k" -lt "$TOTAL" ]; do
  cli=${ANILLO[$((k % 5))]}
  printf 'Trabajo unico: crea el archivo resultado-%s.txt en la raiz del repositorio con exactamente el texto MEDICION-19.2-%s-%s (una linea). Usalo con tu herramienta nativa de escritura de archivos, no con comandos de terminal. No hagas nada mas: ni commit, ni preguntas, ni archivos extra. Al terminar, termina tu turno. Si algo te lo impide, escribe el motivo en bloqueo-%s.txt con tu herramienta de archivos y termina.\n' \
    "$k" "$k" "$cli" "$k" > "$WORK/encargo-$k.txt"
  k=$((k + 1))
done

WATCH_PID=""; ARM_PID=""
declare -a RACERS=()
limpiar() {
  [ -n "${ARM_PID:-}" ] && kill "$ARM_PID" 2>/dev/null
  local r
  for r in "${RACERS[@]:-}"; do [ -n "$r" ] && kill "$r" 2>/dev/null; done
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  wait 2>/dev/null
  "$TMUX_BIN" kill-server 2>/dev/null
}
trap 'RC=$?; limpiar; exit $RC' EXIT

: > "$DOBLE_LOG"
"$TMUX_BIN" new-session -d -s arranque -x 80 -y 24 "sleep 28800" 2>/dev/null
"$TMUX_BIN" set-environment -g OPENCLAW_BIN "$OPENCLAW_BIN"
"$TMUX_BIN" set-environment -g DOBLE_LOG "$DOBLE_LOG"

precalentar() { # $1 token: sesion previa responde confianza y espera barra
  local t=$1 fila bin flag barra i
  fila="$(LC_ALL=C awk -F'\t' -v w="$t" '$1==w {print $2 "\t" $3 "\t" $4; exit}' "$TSV")"
  bin="$(printf '%s' "$fila" | cut -f1)"; flag="$(printf '%s' "$fila" | cut -f2)"; barra="$(printf '%s' "$fila" | cut -f3)"
  "$TMUX_BIN" new-session -d -s "precalienta-$t" -x 200 -y 50 -c "$WORK/repo" \
    "/usr/bin/env PATH=\"$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH\" $bin $flag" 2>/dev/null
  i=0
  while [ "$i" -lt 90 ]; do
    "$ARNES/responder-confianza.sh" "$t" "precalienta-$t" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 || true
    "$TMUX_BIN" capture-pane -p -t "=precalienta-$t:" 2>/dev/null | grep -qF -- "$barra" && break
    sleep 1; i=$((i+1))
  done
  "$TMUX_BIN" kill-session -t "=precalienta-$t" 2>/dev/null
}

precalentar claude
precalentar kimi
precalentar grok

lanzar() { # $1 indice, $2 cli; 0 ademas abre la corrida; 0 si la sesion quedo
  local idx=$1 cli=$2 ses rc
  ses="trab-$idx"
  if [ "$idx" = 0 ]; then
    { "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes \
        --cli-modos "$TSV" --canal-de arnes-canal --simulacro \
      && "$CORRIDA" lanzar-sesion "$ID" lead "$cli" "$WORK/repo" --nombre "$ses" \
        --encargo "$WORK/encargo-$idx.txt"; } >"$WORK/lanzar-0.out" 2>&1
    rc=$?
  else
    CORRIDA_STATE="$CORRIDA_STATE" OPENCLAW_BIN="$OPENCLAW_BIN" TMUX_BIN="$TMUX_BIN" ARNES_SOCKET="$ARNES_SOCKET" \
      bash "$CORRIDA" lanzar-sesion "$ID" lead "$cli" "$WORK/repo" --nombre "$ses" \
      --encargo "$WORK/encargo-$idx.txt" >"$WORK/lanzar-$idx.out" 2>&1
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$ses" "$cli" >> "$WORK/lanzados.txt"
  printf '%s %s\n' "$idx" "$cli" >> "$WORK/slot-cli.txt"
  return 0
}

lanzar_slot() { # $1 indice: 3 intentos del CLI planificado y, si no levanta,
  # el resto del anillo (declarado en slot-cli.txt; el resumen publica la
  # cobertura real, no la planeada). 0 si algun CLI quedo lanzado.
  local idx=$1 i=0 cli
  while [ "$i" -lt 8 ]; do
    cli=${ANILLO[$(( (idx + i / 3) % 5 ))]}
    if lanzar "$idx" "$cli"; then return 0; fi
    printf '%s lanzamiento fallo (intento %s, cli %s)\n' "$(date -u +%FT%TZ)" "$((i + 1))" "$cli" >> "$WORK/brazo.log"
    sleep 5
    i=$((i + 1))
  done
  return 1
}

# Brazo mecanico del dueno (declarado): la entrega del trabajador k queda en
# un pendiente que la RUTA REAL puede consumar sola (emitir despierta al lead
# con 'avisos atender'; medido en la primera pasada). El brazo dispara con el
# pendiente en avisos/ (consume con atender) o ya en tratados/ (consumido por
# la ruta real) y lanza al k+1 del anillo. La decision de lanzamiento esta
# pre-planificada: sin red ni esperas humanas en las N normales.
brazo() {
  local k=0 pend trat t_lanz=${1:-0}
  while [ "$k" -lt "$N" ]; do
    pend=$(ls "$CORRIDA_STATE/$ID/avisos/"*-trab-$k-fin-turno-*.json 2>/dev/null | head -1)
    trat=$(ls "$CORRIDA_STATE/$ID/avisos/tratados/"*-trab-$k-fin-turno-*.json 2>/dev/null | head -1)
    if [ -n "$pend" ]; then
      printf '%s pendiente trab-%s (el brazo atiende)\n' "$(date -u +%FT%TZ)" "$k" >> "$WORK/brazo.log"
      CORRIDA_BIN="$CORRIDA" bash "$CORRIDA" avisos atender "$ID" >>"$WORK/brazo.log" 2>&1
      lanzar_slot $((k + 1)) \
        || printf '%s FALLO-LANZAMIENTO: ningun CLI levanto para trab-%s\n' "$(date -u +%FT%TZ)" "$((k + 1))" >> "$WORK/brazo.log"
      t_lanz=$(date +%s)
      printf '%s lanzado trab-%s\n' "$(date -u +%FT%TZ)" "$((k + 1))" >> "$WORK/brazo.log"
      k=$((k + 1))
      sleep 1
    elif [ -n "$trat" ]; then
      printf '%s consumido por la ruta real (tratados); el brazo lanza\n' "$(date -u +%FT%TZ)" >> "$WORK/brazo.log"
      lanzar_slot $((k + 1)) \
        || printf '%s FALLO-LANZAMIENTO: ningun CLI levanto para trab-%s\n' "$(date -u +%FT%TZ)" "$((k + 1))" >> "$WORK/brazo.log"
      t_lanz=$(date +%s)
      printf '%s lanzado trab-%s\n' "$(date -u +%FT%TZ)" "$((k + 1))" >> "$WORK/brazo.log"
      k=$((k + 1))
      sleep 1
    elif [ "$t_lanz" -gt 0 ] && [ $(( $(date +%s) - t_lanz )) -gt 240 ]; then
      # Guarda: el trabajador k no completo en 240 s (CLI variable: proceso
      # muerto o dialogo sin respuesta). La transicion k se publica FALLO y
      # la cadena sigue con el siguiente slot; nada se oculta.
      printf '%s FALLO: trab-%s sin fin-turno en 240 s; se mata y la cadena sigue\n' "$(date -u +%FT%TZ)" "$k" >> "$WORK/brazo.log"
      printf 'trab-%s\n' "$k" >> "$WORK/fallos.txt"
      "$TMUX_BIN" kill-session -t "=trab-$k:" 2>/dev/null
      t_lanz=0
      lanzar_slot $((k + 1)) \
        || printf '%s FALLO-LANZAMIENTO: ningun CLI levanto para trab-%s\n' "$(date -u +%FT%TZ)" "$((k + 1))" >> "$WORK/brazo.log"
      t_lanz=$(date +%s)
      k=$((k + 1))
      sleep 1
    else
      sleep 1
    fi
  done
  printf '%s brazo termina\n' "$(date -u +%FT%TZ)" >> "$WORK/brazo.log"
}

# Racers persistentes por CLI (vida = la cadena): responden dialogos de
# confianza y aprobacion en CUALQUIER sesion de su CLI, no solo en los
# primeros 240 s (la ronda anterior se atasco en una aprobacion tardia).
racer_persistente() { # $1 cli
  local cli=$1 fin=$(( $(date +%s) + 3300 )) s
  while [ "$(date +%s)" -lt "$fin" ]; do
    if [ -f "$WORK/lanzados.txt" ]; then
      while read -r _ts s _cli; do
        [ "${_cli:-}" = "$cli" ] || continue
        "$ARNES/responder-confianza.sh" "$cli" "$s" "$WORK/repo" >>"$WORK/carrera.log" 2>&1 || true
      done < "$WORK/lanzados.txt"
    fi
    sleep 3
  done
}

if [ "${DRY19:-}" = "1" ]; then echo "DRY: arnes preparado en $WORK"; exit 0; fi

for CLI_R in claude codex kimi; do
  racer_persistente "$CLI_R" &
  RACERS+=($!)
done
"$WATCHER" >"$WORK/watch.out" 2>&1 &
WATCH_PID=$!
sleep 1
lanzar_slot 0
T_LANZ0=$(date +%s)

# Sondeos arrancados ANTES de que cada sesion exista, para fechar la primera
# vista real. Por trabajador: uno de FIN (resultado completo + cola estable;
# abre la SIGUIENTE transicion) y, del 1 en adelante, uno de INICIO
# (sesion-viva + actividad; cierra ESTA transicion).
SONDEO_PIDS=""
k=0
while [ "$k" -lt "$TOTAL" ]; do
  python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "trab-$k" "$WORK/repo/resultado-$k.txt" \
    "$WORK/fin-$k.jsonl" --tope 900 --solo-archivo &
  SONDEO_PIDS="$SONDEO_PIDS $!"
  if [ "$k" -gt 0 ]; then
    python3 "$ARNES/sondeo-fin.py" "$ARNES_SOCKET" "trab-$k" "$WORK/repo/resultado-$k.txt" \
      "$WORK/ini-$k.jsonl" --tope 900 --actividad &
    SONDEO_PIDS="$SONDEO_PIDS $!"
  fi
  k=$((k + 1))
done

brazo $T_LANZ0 &
ARM_PID=$!

for p in $SONDEO_PIDS; do wait "$p" 2>/dev/null; done
kill "$ARM_PID" 2>/dev/null; ARM_PID=""
kill "$WATCH_PID" 2>/dev/null; WATCH_PID=""
"$CORRIDA" cerrar "$ID" >"$WORK/cerrar.out" 2>&1 || true

ESTAMPA="$(date +%H%M%S)"
mkdir -p "$SALIDA/$ESTAMPA"
cp "$WORK"/fin-*.jsonl "$WORK"/ini-*.jsonl "$WORK/lanzados.txt" "$WORK/slot-cli.txt" \
   "$WORK/exigidas.txt" "$WORK/brazo.log" \
   "$WORK/doble.jsonl" "$WORK/watch.log" "$SALIDA/$ESTAMPA/" 2>/dev/null
cp -r "$CORRIDA_STATE/$ID" "$SALIDA/$ESTAMPA/registro" 2>/dev/null
printf '%s\n' "$ESTAMPA" > "$SALIDA/ultima"
echo "medir-19.2: cadena completa; estampa $ESTAMPA"

#!/bin/bash
# Casos APARTE de las 20 transiciones normales (19.2). Cada caso en su propio
# sandbox (tmux -L, CORRIDA_STATE, pasarela); un trabajador zcode real que
# termina su turno. No cuentan para la tabla de transiciones.
#   A perdida: el pendiente se pierde (se borra) tras emitirse; el recordatorio
#     (QUIET_REMIND_SECS corto) lo re-emite con la MISMA identidad y el brazo
#     lanza UNA sola vez: recuperacion sin duplicados.
#   B caida recuperable: el vigia muere antes del fin; al relanzarlo el aviso
#     aparece y el sucesor arranca; recuperacion medida desde el relanzamiento
#     (<60 s con gateway y dueno disponibles) y sin lanzamientos duplicados.
#   C reversa del seguimiento: CORRIDA_AVISOS=0 -> cero pendientes y el fin va
#     por system event a agent:main:vigia-mac (la pasarela lo deja en el log
#     y NEGADO cerrado); sin la reversa, los pendientes vuelven.
# uso: casos-19.2.sh [A|B|C]
set -uo pipefail
SOLO=${1:-}

ARNES="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ARNES/../../../.." && pwd)"
CORRIDA="$REPO/scripts/mac/corrida.sh"
WATCHER="$REPO/scripts/mac/tmux-activity-watch.sh"
TSV="$REPO/scripts/mac/cli-modos.tsv"
OPENCLAW_REAL="${OPENCLAW_REAL_BIN:-$HOME/.openclaw/bin/openclaw}"
SALIDA="$ARNES/salidas/19-2-casos"
export TMUX_BIN="$ARNES/tmux-arnes"
export OPENCLAW_REAL_BIN="$OPENCLAW_REAL"

case_arm() { # $1 work $2 id: consuma el pendiente de trab-0 (o detecta que la
  # ruta real ya lo consumio) y lanza al sucesor
  local work=$1 id=$2 intento=0 pend trat
  while [ "$intento" -lt 120 ]; do
    pend=$(ls "$work/estado/$id/avisos/"*-trab-0-fin-turno-*.json 2>/dev/null | head -1)
    trat=$(ls "$work/estado/$id/avisos/tratados/"*-trab-0-fin-turno-*.json 2>/dev/null | head -1)
    if [ -n "$pend" ]; then
      printf '%s pendiente visto (intento %s)\n' "$(date -u +%FT%TZ)" "$intento" >> "$work/brazo.log"
      CORRIDA_STATE="$work/estado" bash "$CORRIDA" avisos atender "$id" >>"$work/brazo.log" 2>&1
      CORRIDA_STATE="$work/estado" OPENCLAW_BIN="$ARNES/openclaw-pasarela" TMUX_BIN="$TMUX_BIN" ARNES_SOCKET="$SOCKET_CASO" \
        bash "$CORRIDA" lanzar-sesion "$id" lead zcode "$work/repo" --nombre trab-1 \
        --encargo "$work/encargo-1.txt" >>"$work/brazo.log" 2>&1
      printf '%s lanzado trab-1\n' "$(date -u +%FT%TZ)" >> "$work/brazo.log"
      return 0
    fi
    if [ -n "$trat" ]; then
      printf '%s ya consumido por la ruta real; el brazo lanza\n' "$(date -u +%FT%TZ)" >> "$work/brazo.log"
      CORRIDA_STATE="$work/estado" OPENCLAW_BIN="$ARNES/openclaw-pasarela" TMUX_BIN="$TMUX_BIN" ARNES_SOCKET="$SOCKET_CASO" \
        bash "$CORRIDA" lanzar-sesion "$id" lead zcode "$work/repo" --nombre trab-1 \
        --encargo "$work/encargo-1.txt" >>"$work/brazo.log" 2>&1
      printf '%s lanzado trab-1\n' "$(date -u +%FT%TZ)" >> "$work/brazo.log"
      return 0
    fi
    sleep 1; intento=$((intento + 1))
  done
  return 1
}

preparar() { # $1 caso: deja WORK/SOCKET/CASE_DIR listos y los encargos
  CASE_DIR="$SALIDA/$1-$(date +%H%M%S)"
  WORK="$ARNES/.tmp/caso-$1"
  SOCKET_CASO="u3a192caso$1-$$"
  export ARNES_SOCKET="$SOCKET_CASO"
  export CORRIDA_STATE="$WORK/estado"
  export STATE_DIR="$WORK/watch"
  export LOG_FILE="$WORK/watch.log"
  export OPENCLAW_BIN="$ARNES/openclaw-pasarela"
  export DOBLE_LOG="$WORK/doble.jsonl"
  export CORRIDA_BIN="$CORRIDA"
  export QUIET_SECS=8 TICK_SECS=2 LATIDO_SECS=1800
  case "$CORRIDA_STATE" in "$HOME/.local/state"*) echo "NEGADO" >&2; exit 2;; esac
  rm -rf "$WORK"; mkdir -p "$WORK/repo" "$WORK/watch" "$CORRIDA_STATE" "$CASE_DIR"
  cd "$WORK/repo"
  git init -q; git config user.email arnes@local; git config user.name arnes
  printf 'caso %s\n' "$1" > README.md
  git add README.md && git commit -qm "caso $1"
  ID="caso192-$1-$(date +%H%M%S)"
  printf '# Caso %s\n\nUn trabajador y su sucesor.\n' "$1" > "$WORK/runbook.md"
  printf 'Trabajo unico: crea el archivo resultado-0.txt en la raiz del repositorio con exactamente el texto CASO-192-%s-0 (una linea), con tu herramienta nativa de archivos y sin terminal. Nada mas: al terminar, termina tu turno.\n' "$1" > "$WORK/encargo-0.txt"
  printf 'Trabajo unico: crea el archivo resultado-1.txt en la raiz del repositorio con exactamente el texto CASO-192-%s-1 (una linea), con tu herramienta nativa de archivos y sin terminal. Nada mas: al terminar, termina tu turno.\n' "$1" > "$WORK/encargo-1.txt"
  : > "$DOBLE_LOG"
  "$TMUX_BIN" new-session -d -s arranque -x 80 -y 24 "sleep 3600" 2>/dev/null
  "$TMUX_BIN" set-environment -g OPENCLAW_BIN "$OPENCLAW_BIN"
  "$TMUX_BIN" set-environment -g DOBLE_LOG "$DOBLE_LOG"
}

esperar_resultado0() {
  local i=0
  while [ "$i" -lt 240 ]; do
    [ -s "$WORK/repo/resultado-0.txt" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

caso_A() {
  preparar A
  export QUIET_REMIND_SECS=25
  { "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes --cli-modos "$TSV" --canal-de arnes-canal --simulacro \
      && "$CORRIDA" lanzar-sesion "$ID" lead zcode "$WORK/repo" --nombre trab-0 --encargo "$WORK/encargo-0.txt"; } >"$WORK/lanzar.out" 2>&1
  esperar_resultado0 || { echo "caso A: SIN-RESULTADO" | tee -a "$CASE_DIR/veredicto"; return 1; }
  "$WATCHER" >>"$WORK/watch.out" 2>&1 &
  local wp=$!
  # Perdida: borrar el pendiente apenas exista (queda perdido: notified=1).
  local i=0 borrado=0
  while [ "$i" -lt 60 ]; do
    local p
    for p in "$WORK/estado/$ID/avisos/"*-trab-0-fin-turno-*.json; do
      [ -f "$p" ] || continue
      mkdir -p "$CASE_DIR" && cp "$p" "$CASE_DIR/perdido.json" && rm -f "$p" && borrado=1 && break
    done
    [ "$borrado" = "1" ] && break
    sleep 1; i=$((i + 1))
  done
  printf '%s pendiente perdido (borrado)\n' "$(date -u +%FT%TZ)" >> "$WORK/brazo.log"
  # El recordatorio (25 s) debe re-emitir la MISMA identidad; el brazo consume
  # y lanza UNA sola vez. Recovery = perdido -> actividad de trab-1.
  t0=$(python3 -c 'import time; print(time.monotonic_ns())')
  case_arm "$WORK" "$ID" || { echo "caso A: SIN-RECUPERACION" | tee -a "$CASE_DIR/veredicto"; kill $wp 2>/dev/null; return 1; }
  local i2=0 act=""
  while [ "$i2" -lt 180 ]; do
    "$TMUX_BIN" has-session -t "=trab-1:" 2>/dev/null && break
    sleep 1; i2=$((i2 + 1))
  done
  python3 "$ARNES/sondeo-fin.py" "$SOCKET_CASO" trab-1 "$WORK/repo/resultado-1.txt" \
    "$CASE_DIR/ini-1.jsonl" --tope 240 --actividad >/dev/null
  act=$(python3 -c 'import json,sys
f=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
a=[r for r in f if r["ev"]=="sesion-viva"] or [r for r in f if r["ev"]=="actividad"]
print(a[0]["mono_ns"] if a else "")' "$CASE_DIR/ini-1.jsonl")
  t1=$(python3 -c 'import time; print(time.monotonic_ns())')
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  local n_lanz n_pend
  n_lanz=$(grep -c 'lanzado trab-1' "$WORK/brazo.log" 2>/dev/null || echo 0)
  n_pend=$(ls "$WORK/estado/$ID/avisos/tratados/"*-trab-0-fin-turno-*.json 2>/dev/null | wc -l | tr -d ' ')
  python3 - "$t0" "$t1" "$act" > "$CASE_DIR/caso-A.json" <<PY
import json, sys
t0, t1, act = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rec = round((t1 - t0) / 1e9, 2) if act else None
print(json.dumps({"caso": "A_perdida", "recuperacion_s": rec,
  "lanzamientos_trab1": ${n_lanz:-0}, "pendientes_tratados": ${n_pend:-0},
  "sin_duplicados": ${n_lanz:-0} == 1,
  "veredicto": "OK" if (act and ${n_lanz:-0} == 1 and rec is not None and rec < 60) else "REVISAR"}, indent=1))
PY
  cat "$CASE_DIR/caso-A.json"
  cp -r "$WORK/estado/$ID" "$CASE_DIR/registro" 2>/dev/null
  cp "$WORK/brazo.log" "$WORK/doble.jsonl" "$CASE_DIR/" 2>/dev/null
}

caso_B() {
  preparar B
  { "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes --cli-modos "$TSV" --canal-de arnes-canal --simulacro \
      && "$CORRIDA" lanzar-sesion "$ID" lead zcode "$WORK/repo" --nombre trab-0 --encargo "$WORK/encargo-0.txt"; } >"$WORK/lanzar.out" 2>&1
  # El vigia arranca y MUERE antes de ver el fin: caida recuperable.
  "$WATCHER" >>"$WORK/watch.out" 2>&1 &
  local wp=$!
  sleep 2
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  printf '%s vigia muerto\n' "$(date -u +%FT%TZ)" >> "$WORK/brazo.log"
  esperar_resultado0 || { echo "caso B: SIN-RESULTADO" | tee -a "$CASE_DIR/veredicto"; return 1; }
  sleep 6
  # Recuperacion: relanzar el vigia; el reloj corre desde AQUI (el plan: se
  # mide desde su recuperacion, con gateway y dueno disponibles).
  t0=$(python3 -c 'import time; print(time.monotonic_ns())')
  printf '%s vigia relanzado (recovery clock start)\n' "$(date -u +%FT%TZ)" >> "$WORK/brazo.log"
  "$WATCHER" >>"$WORK/watch.out" 2>&1 &
  wp=$!
  case_arm "$WORK" "$ID" || { echo "caso B: SIN-RECUPERACION" | tee -a "$CASE_DIR/veredicto"; kill $wp 2>/dev/null; return 1; }
  local i2=0
  while [ "$i2" -lt 180 ]; do
    "$TMUX_BIN" has-session -t "=trab-1:" 2>/dev/null && break
    sleep 1; i2=$((i2 + 1))
  done
  python3 "$ARNES/sondeo-fin.py" "$SOCKET_CASO" trab-1 "$WORK/repo/resultado-1.txt" \
    "$CASE_DIR/ini-1.jsonl" --tope 240 --actividad >/dev/null
  local act
  act=$(python3 -c 'import json,sys
f=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
a=[r for r in f if r["ev"]=="sesion-viva"] or [r for r in f if r["ev"]=="actividad"]
print(a[0]["mono_ns"] if a else "")' "$CASE_DIR/ini-1.jsonl")
  t1=$(python3 -c 'import time; print(time.monotonic_ns())')
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  local n_lanz
  n_lanz=$(grep -c 'lanzado trab-1' "$WORK/brazo.log" 2>/dev/null || echo 0)
  python3 - "$t0" "$t1" "$act" > "$CASE_DIR/caso-B.json" <<PY
import json, sys
t0, t1, act = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rec = round((t1 - t0) / 1e9, 2) if act else None
print(json.dumps({"caso": "B_caida", "recuperacion_s": rec,
  "lanzamientos_trab1": ${n_lanz:-0},
  "sin_duplicados": ${n_lanz:-0} == 1,
  "veredicto": "OK" if (act and ${n_lanz:-0} == 1 and rec is not None and rec < 60) else "REVISAR"}, indent=1))
PY
  cat "$CASE_DIR/caso-B.json"
  cp -r "$WORK/estado/$ID" "$CASE_DIR/registro" 2>/dev/null
  cp "$WORK/brazo.log" "$WORK/doble.jsonl" "$CASE_DIR/" 2>/dev/null
}

caso_C() {
  preparar C
  # Reversa ON: CORRIDA_AVISOS=0 en el entorno GLOBAL del servidor sandbox:
  # la heredan el vigia Y la sesion (su hook Stop), que son los dos emisores
  # de la ruta de avisos. Sin esto, solo el vigia queda revertido.
  "$TMUX_BIN" set-environment -g CORRIDA_AVISOS 0
  "$CORRIDA" abrir "$ID" --runbook "$WORK/runbook.md" --vigia hermes --cli-modos "$TSV" --canal-de arnes-canal --simulacro >"$WORK/abrir.out" 2>&1
  "$CORRIDA" lanzar-sesion "$ID" lead zcode "$WORK/repo" --nombre trab-0 --encargo "$WORK/encargo-0.txt" >"$WORK/lanzar.out" 2>&1
  CORRIDA_AVISOS=0 "$WATCHER" >>"$WORK/watch.out" 2>&1 &
  local wp=$!
  esperar_resultado0 || { echo "caso C: SIN-RESULTADO" | tee -a "$CASE_DIR/veredicto"; kill $wp 2>/dev/null; return 1; }
  sleep 14
  local pend_rev ev_vigia
  pend_rev=$(ls "$WORK/estado/$ID/avisos/"*.json 2>/dev/null | wc -l | tr -d ' ')
  ev_vigia=$(grep -c 'vigia-mac' "$DOBLE_LOG" 2>/dev/null); ev_vigia=${ev_vigia:-0}
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  # Reversa OFF: se quita del entorno del servidor y la ruta de avisos vuelve.
  "$TMUX_BIN" set-environment -g -u CORRIDA_AVISOS
  "$WATCHER" >>"$WORK/watch.out" 2>&1 &
  wp=$!
  local i=0 pend_on=0
  while [ "$i" -lt 40 ]; do
    pend_on=$(ls "$WORK/estado/$ID/avisos/"*.json 2>/dev/null | wc -l | tr -d ' ')
    [ "$pend_on" -ge 1 ] && break
    sleep 1; i=$((i + 1))
  done
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  cat > "$CASE_DIR/caso-C.json" <<PY
{"caso": "C_reversa", "pendientes_con_reversa": $pend_rev, "eventos_vigia_mac_en_log": $ev_vigia, "pendientes_sin_reversa": $pend_on, "veredicto": "$( [ "$pend_rev" -eq 0 ] && [ "$pend_on" -ge 1 ] && echo OK || echo REVISAR)"}
PY
  cat "$CASE_DIR/caso-C.json"
  cp -r "$WORK/estado/$ID" "$CASE_DIR/registro" 2>/dev/null
  cp "$WORK/doble.jsonl" "$CASE_DIR/" 2>/dev/null
}

mkdir -p "$SALIDA"
case "$SOLO" in
  A) caso_A;;
  B) caso_B;;
  C) caso_C;;
  *) caso_A; caso_B; caso_C;;
esac
"$TMUX_BIN" kill-server 2>/dev/null
echo "casos 19.2 listos en $SALIDA"

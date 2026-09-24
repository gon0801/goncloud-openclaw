#!/bin/bash
# 9.9 pieza (a): esqueleto del arnes del simulacro, de punta a punta. Con
# --ensayo: tmux propio (-L), openclaw/gh/glm de mentira, vigia doblado del
# checkout y CORRIDA_STATE temporal. No corre ningun caso todavia (son
# placeholder "NO OBSERVADO"): esta prueba cubre prerrequisitos, arranque,
# limpieza (trap y --limpiar) y el generador de evidencia.
# Uso: bash scripts/tests/test-simulacro-fase9.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

ARNES="$PWD/scripts/mac/simulacro-fase9.sh"
FIX="$PWD/scripts/tests/fixtures/simulacro"
[ -x "$ARNES" ] || fail "falta $ARNES"
[ -x "$FIX/tmux-envoltura.sh" ] || fail "falta $FIX/tmux-envoltura.sh"

TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba del arnes"

T="$(mktemp -d)" || exit 1
SOCKET="sim9ensayo$$"
trap '"$TM_REAL" -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/home/bin/corrida" "$T/home/Library/LaunchAgents" "$T/corridas" "$T/watch-state"

# glm de mentira en el PATH (preflight lanza una sesion de prueba por cada
# fila de la tabla, incluida "glm": tiene que quedarse viva y pintar su barra).
cp "$FIX/glm-falso.sh" "$T/bin/glm" && chmod +x "$T/bin/glm"

# HOME de mentira, pre-poblado como si instalar-mac.sh ya hubiera corrido —
# a mano, con cp, NUNCA con el modo instalar real (ese carga LaunchAgents de
# verdad; instalar-mac.sh --verificar solo compara archivos, no toca nada).
for f in corrida.sh cli-modos.tsv agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh; do
  cp -p "scripts/mac/$f" "$T/home/bin/$f" || fail "no se pudo poblar HOME de mentira ($f)"
done
for f in scripts/mac/corrida/*.sh; do
  cp -p "$f" "$T/home/bin/corrida/$(basename "$f")" || fail "no se pudo poblar HOME de mentira (corrida/$(basename "$f"))"
done
cp -p scripts/mac/tmux.conf "$T/home/.tmux.conf"
sed "s|/Users/dn|$T/home|g" scripts/mac/ai.goncloud.tmux-activity-watch.plist \
  > "$T/home/Library/LaunchAgents/ai.goncloud.tmux-activity-watch.plist"
: > "$T/home/.zshrc"
printf 'source ~/bin/agent-tmux-shell.zsh\n' >> "$T/home/.zshrc"

export HOME="$T/home"
export CORRIDA_STATE="$T/corridas"
export WATCH_STATE_DIR="$T/watch-state"
export CORRIDA_BIN="$PWD/scripts/mac/corrida.sh"
export TMUX_BIN="$FIX/tmux-envoltura.sh"
export SIM9_TMUX_SOCKET="$SOCKET"
export OPENCLAW_BIN="$FIX/openclaw-falso.sh"
export SIM9_LLAMADAS="$T/llamadas.log"
export SIM9_DESTINO="DESTINO-FALSO-9Z-NUNCA-EN-LA-EVIDENCIA"
export SIM9_MSG_ID=9001
export GH_BIN="$FIX/gh-falso.sh"
export CORRIDA_CANDADO_gh=permitido CORRIDA_CANDADO_ssh=permitido
export CORRIDA_CANDADO_red_externa=permitido
export PATH="$T/bin:$PATH"

# ============================= (1) todo sano ================================
EVID1="$T/evidencia-1.md"
salida1="$(bash "$ARNES" --ensayo --salida "$EVID1" --tope-pared 60 2>&1)"
rc1=$?
[ "$rc1" -eq 1 ] || fail "todo sano: se esperaba salida 1 (7 NO OBSERVADO), salio $rc1 -- $salida1"
printf '%s\n' "$salida1" | grep -q '^arrancada sim9-' || fail "no se vio 'arrancada sim9-...': $salida1"
[ -f "$EVID1" ] || fail "no se genero la evidencia en $EVID1"

# (1b) tras el trap: cero sesiones y cero marcas en el socket propio.
sesiones_quedan="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones_quedan" -eq 0 ] || fail "quedaron $sesiones_quedan sesion(es) sim9-* vivas tras el trap"

# (1c) la evidencia nunca trae el destino falso.
grep -q "$SIM9_DESTINO" "$EVID1" && fail "la evidencia dejo escrito el destino falso"

# (1d) la evidencia trae las 7 filas, todas pendientes.
n_pendientes="$(grep -c 'NO OBSERVADO' "$EVID1")"
[ "$n_pendientes" -eq 7 ] || fail "se esperaban 7 filas NO OBSERVADO en la evidencia, hay $n_pendientes"

# (1e) el registro de esa corrida quedo cerrado (la limpieza del trap cerro).
SIM_ID1="$(printf '%s\n' "$salida1" | sed -n 's/^arrancada //p')"
[ -n "$SIM_ID1" ] || fail "no se pudo leer el id de la corrida de la salida"
grep -q '"estado": *"cerrada"' "$T/corridas/$SIM_ID1/registro.json" \
  || fail "el registro de $SIM_ID1 no quedo cerrado tras el trap"

# ============================= (2) prerrequisito roto: sin glm ==============
T2="$T/sin-glm-path"
mkdir -p "$T2"
antes_dirs="$(find "$T/corridas" -maxdepth 1 -name 'sim9-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
salida2="$(PATH="$T2:/usr/bin:/bin" HOME="$T/home" CORRIDA_STATE="$T/corridas" WATCH_STATE_DIR="$T/watch-state" \
  CORRIDA_BIN="$CORRIDA_BIN" TMUX_BIN="$TMUX_BIN" SIM9_TMUX_SOCKET="$SOCKET" \
  OPENCLAW_BIN="$OPENCLAW_BIN" SIM9_DESTINO="$SIM9_DESTINO" SIM9_MSG_ID=9001 \
  GH_BIN="$GH_BIN" CORRIDA_CANDADO_gh=permitido CORRIDA_CANDADO_ssh=permitido CORRIDA_CANDADO_red_externa=permitido \
  bash "$ARNES" --ensayo --salida "$T/evidencia-2.md" --tope-pared 30 2>&1)"
rc2=$?
[ "$rc2" -eq 2 ] || fail "sin glm en el PATH: se esperaba salida 2 (NO APTO), salio $rc2 -- $salida2"
printf '%s\n' "$salida2" | grep -q 'NO APTO' || fail "sin glm: no se vio NO APTO: $salida2"
printf '%s\n' "$salida2" | grep -q 'glm' || fail "sin glm: la razon no menciona glm: $salida2"
[ -f "$T/evidencia-2.md" ] && fail "NO APTO igual escribio evidencia (no deberia)"
despues_dirs="$(find "$T/corridas" -maxdepth 1 -name 'sim9-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$despues_dirs" -eq "$antes_dirs" ] || fail "NO APTO igual creo un directorio de corrida (se esperaba ninguno nuevo)"
sesiones_tras_no_apto="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones_tras_no_apto" -eq 0 ] || fail "NO APTO igual dejo sesiones sim9-* vivas"

# ============================= (3) --limpiar sobre una corrida a medias =====
# Se abre por fuera del arnes (como si el arnes hubiera muerto con kill -9 a
# mitad del arranque) y se comprueba que --limpiar la deja cerrada de verdad.
SIM_MEDIAS="sim9-a-medias-$$"
mkdir -p "$T/corridas/$SIM_MEDIAS/bin"
cp "$PWD/scripts/tests/fixtures/tui-falso.sh" "$T/corridas/$SIM_MEDIAS/bin/sim9-tui-falso" \
  || fail "no se pudo copiar tui-falso.sh para la corrida a medias"
chmod +x "$T/corridas/$SIM_MEDIAS/bin/sim9-tui-falso"
{
  printf 'tui-falso\tsim9-tui-falso\t\tTUI-FALSO\tunknown\tEnter\tEscape\n'
  printf 'glm\tglm\t--mode yolo\tyolo\t/mode yolo\tunknown\tunknown\n'
} > "$T/corridas/$SIM_MEDIAS/cli-modos.tsv"
PATH="$T/corridas/$SIM_MEDIAS/bin:$PATH" bash "$CORRIDA_BIN" abrir "$SIM_MEDIAS" \
  --runbook "$PWD/scripts/tests/fixtures/corrida/runbook-simulacro.md" --vigia claw \
  --cli-modos "$T/corridas/$SIM_MEDIAS/cli-modos.tsv" --simulacro >/dev/null 2>&1 \
  || fail "no se pudo abrir la corrida a medias para probar --limpiar"
"$TM_REAL" -L "$SOCKET" new-session -d -s "sim9-huerfana-$$" >/dev/null 2>&1
"$TM_REAL" -L "$SOCKET" set-environment -t "=sim9-huerfana-$$" OPENCLAW_WATCH_RUN "$SIM_MEDIAS" >/dev/null 2>&1
grep -q '"estado": *"abierta"' "$T/corridas/$SIM_MEDIAS/registro.json" \
  || fail "la corrida a medias no quedo abierta antes de --limpiar"

salida3="$(bash "$ARNES" --limpiar "$SIM_MEDIAS" 2>&1)"
rc3=$?
[ "$rc3" -eq 0 ] || fail "--limpiar salio distinto de 0: $rc3 -- $salida3"
grep -q '"estado": *"cerrada"' "$T/corridas/$SIM_MEDIAS/registro.json" \
  || fail "--limpiar no dejo cerrada la corrida a medias"
"$TM_REAL" -L "$SOCKET" has-session -t "=sim9-huerfana-$$" 2>/dev/null \
  && fail "--limpiar no mato la sesion huerfana marcada con OPENCLAW_WATCH_RUN"

# ============================= (4) grep del arnes: sin rm -r/-rf ============
sed 's/#.*//' scripts/mac/simulacro-fase9.sh | grep -qE 'rm[[:space:]]+-[a-zA-Z]*r' \
  && fail "el arnes tiene un rm -r/-rf fuera de un comentario: la limpieza tiene que ser sin rm -r"

echo "TODO VERDE: simulacro-fase9 (pieza a)"

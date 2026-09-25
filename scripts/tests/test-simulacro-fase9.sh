#!/bin/bash
# 9.9 piezas (a)-(e): el arnes del simulacro de punta a punta, con los 7
# casos corriendo de verdad. Con --ensayo: tmux propio (-L), openclaw/gh/glm
# de mentira, vigia doblado del checkout y CORRIDA_STATE temporal. Cubre
# prerrequisitos, arranque, limpieza (trap y --limpiar), el generador de
# evidencia, --dry-run, la observacion extendida (con un reloj corto
# inyectado SOLO en el sondeo propio del arnes, nunca en corrida.sh estado),
# y un escenario de fallo por caso: glm que nunca dice LISTO (caso 1 NO
# FUNCIONA), responder apagado (caso 2 NO FUNCIONA), message send sin id
# (casos 3, 4 y 7 NO FUNCIONA — los tres mandan con la misma via), "main"
# sin relanzar (casos 5 y 6 NO FUNCIONA), y "main" mudo en la observacion
# extendida (el aviso real no sale: NO OBSERVADO, nunca "no aplica").
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
export SIM_TOPE_C1=15 SIM_TOPE_C2=15 SIM_TOPE_C3=20 SIM_TOPE_C4=20 SIM_TOPE_C5=30 SIM_TOPE_C6=30
export SIM_ESPERA_DOBLE=6

# ============================= (1) todo sano ================================
EVID1="$T/evidencia-1.md"
salida1="$(bash "$ARNES" --ensayo --salida "$EVID1" --tope-pared 300 2>&1)"
rc1=$?
[ "$rc1" -eq 0 ] || fail "todo sano: se esperaba salida 0 (7/7 FUNCIONA), salio $rc1 -- $salida1"
printf '%s\n' "$salida1" | grep -q '^arrancada sim9-' || fail "no se vio 'arrancada sim9-...': $salida1"
[ -f "$EVID1" ] || fail "no se genero la evidencia en $EVID1"

# (1b) tras el trap: cero sesiones y cero marcas en el socket propio.
sesiones_quedan="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones_quedan" -eq 0 ] || fail "quedaron $sesiones_quedan sesion(es) sim9-* vivas tras el trap"

# (1c) la evidencia nunca trae el destino falso.
grep -q "$SIM9_DESTINO" "$EVID1" && fail "la evidencia dejo escrito el destino falso"

# (1d) los 7 casos FUNCIONA.
n_funciona="$(grep -cE '\| FUNCIONA ' "$EVID1")"
[ "$n_funciona" -eq 7 ] || fail "se esperaban 7 filas FUNCIONA en la evidencia, hay $n_funciona: $(grep '|' "$EVID1")"
for i in 1 2 3 4 5 6 7; do
  grep -qE "^\\| $i .*\\| FUNCIONA " "$EVID1" || fail "el caso $i no salio FUNCIONA en la evidencia"
done
grep -qE '^\| 1 .*no aplica: sin mensaje por diseno' "$EVID1" || fail "el caso 1 no trae 'no aplica: sin mensaje por diseno'"
grep -qE '^\| 1 .*AVANZA' "$EVID1" || fail "el caso 1 no cita la linea AVANZA de eventos-seguimiento.jsonl"
grep -qE '^\| 5 .*no aplica: sin mensaje por diseno' "$EVID1" || fail "el caso 5 no trae 'no aplica: sin mensaje por diseno'"
grep -qE '^\| 6 .*no aplica: sin mensaje por diseno' "$EVID1" || fail "el caso 6 no trae 'no aplica: sin mensaje por diseno'"

# (1e) el registro de esa corrida quedo cerrado (la limpieza del trap cerro).
SIM_ID1="$(printf '%s\n' "$salida1" | sed -n 's/^arrancada //p')"
[ -n "$SIM_ID1" ] || fail "no se pudo leer el id de la corrida de la salida"
grep -q '"estado": *"cerrada"' "$T/corridas/$SIM_ID1/registro.json" \
  || fail "el registro de $SIM_ID1 no quedo cerrado tras el trap"

# (1f) decisiones.jsonl trae las decisiones de los casos 2 y 3; el registro
# quedo con dos entradas para sim9-c5 y para sim9-lead (la original + el
# relanzamiento del caso 5/6).
DEC1="$T/corridas/$SIM_ID1/decisiones.jsonl"
grep -q '"sesion": "sim9-t2"' "$DEC1" || fail "decisiones.jsonl no trae nada de sim9-t2"
grep -q '"sesion": "sim9-t3"' "$DEC1" || fail "decisiones.jsonl no trae nada de sim9-t3"
# lanzar-sesion siempre APPEND-ea (nunca reemplaza): la relanzada reusa el
# mismo nombre de sesion Y el mismo dir, asi que quedan DOS entradas del
# registro para ese par (la original, muerta, y la relanzada, viva) — "una
# entrada mas" que antes del kill, tal como pide el diseno.
n_c5="$(python3 -c "
import json
d=json.load(open('$T/corridas/$SIM_ID1/registro.json'))
print(sum(1 for s in d['sesiones'] if s.get('nombre')=='sim9-c5'))")"
[ "$n_c5" = "2" ] || fail "se esperaban 2 entradas del registro nombradas sim9-c5 (original + relanzada), hay $n_c5"

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

# ============================= (5) glm que nunca dice LISTO: caso 1 NO FUNCIONA
EVID5="$T/evidencia-5.md"
salida5="$(SIM9_GLM_MUDO=1 bash "$ARNES" --ensayo --salida "$EVID5" --tope-pared 60 2>&1)"
rc5=$?
[ "$rc5" -eq 1 ] || fail "glm mudo: se esperaba salida 1, salio $rc5 -- $salida5"
grep -qE '^\| 1 .*\| NO FUNCIONA ' "$EVID5" \
  || fail "glm mudo: el caso 1 no salio NO FUNCIONA: $(grep '^| 1 ' "$EVID5")"
grep -qE '^\| 2 .*\| FUNCIONA ' "$EVID5" || fail "glm mudo: el caso 2 debio seguir FUNCIONA"
grep -qE '^\| 3 .*\| FUNCIONA ' "$EVID5" || fail "glm mudo: el caso 3 debio seguir FUNCIONA"
sesiones5="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones5" -eq 0 ] || fail "glm mudo: quedaron sesiones sim9-* vivas (el caso 1 se colgo)"

# ============================= (6) responder apagado: caso 2 NO FUNCIONA ====
EVID6="$T/evidencia-6.md"
salida6="$(SIM9_SIN_RESPONDER=1 bash "$ARNES" --ensayo --salida "$EVID6" --tope-pared 60 2>&1)"
rc6=$?
[ "$rc6" -eq 1 ] || fail "responder apagado: se esperaba salida 1, salio $rc6 -- $salida6"
grep -qE '^\| 2 .*\| NO FUNCIONA ' "$EVID6" \
  || fail "responder apagado: el caso 2 no salio NO FUNCIONA: $(grep '^| 2 ' "$EVID6")"

# ============================= (7) message send sin id: casos 3, 4 y 7 =======
# NO FUNCIONA (los tres mandan por con_tope + message send --json de la
# misma forma; sin messageId, ninguno de los tres puede confirmar el envio).
EVID7="$T/evidencia-7.md"
salida7="$(SIM9_MSG_ID='' bash "$ARNES" --ensayo --salida "$EVID7" --tope-pared 120 2>&1)"
rc7=$?
[ "$rc7" -eq 1 ] || fail "message send sin id: se esperaba salida 1, salio $rc7 -- $salida7"
grep -qE '^\| 3 .*\| NO FUNCIONA ' "$EVID7" \
  || fail "message send sin id: el caso 3 no salio NO FUNCIONA: $(grep '^| 3 ' "$EVID7")"
grep -qE '^\| 4 .*\| NO FUNCIONA ' "$EVID7" \
  || fail "message send sin id: el caso 4 no salio NO FUNCIONA: $(grep '^| 4 ' "$EVID7")"
grep -qE '^\| 7 .*\| NO FUNCIONA ' "$EVID7" \
  || fail "message send sin id: el caso 7 no salio NO FUNCIONA: $(grep '^| 7 ' "$EVID7")"

# ============================= (8) "main" sin relanzar: casos 5 y 6 ==========
EVID8="$T/evidencia-8.md"
salida8="$(SIM_MAIN=mudo bash "$ARNES" --ensayo --salida "$EVID8" --tope-pared 120 2>&1)"
rc8=$?
[ "$rc8" -eq 1 ] || fail "main sin relanzar: se esperaba salida 1, salio $rc8 -- $salida8"
grep -qE '^\| 5 .*\| NO FUNCIONA ' "$EVID8" \
  || fail "main sin relanzar: el caso 5 no salio NO FUNCIONA: $(grep '^| 5 ' "$EVID8")"
grep -qE '^\| 6 .*\| NO FUNCIONA ' "$EVID8" \
  || fail "main sin relanzar: el caso 6 no salio NO FUNCIONA: $(grep '^| 6 ' "$EVID8")"
sesiones8="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones8" -eq 0 ] || fail "main sin relanzar: quedaron sesiones sim9-* vivas"

# ============================= (9) observacion extendida: el aviso SALE =====
# Reloj corto inyectado (solo el sondeo propio del arnes, nunca el de
# corrida.sh estado): con un tope de 1 minuto y una ventana minima de pocos
# segundos, "main" (el openclaw falso) crea el cron avance-tareas con su
# scratch YA confirmado al recibir el turno.
EVID9="$T/evidencia-9.md"
salida9="$(SIM_TOPE_OBS_POLL=2 SIM_TOPE_OBS_VENTANA=5 \
  bash "$ARNES" --ensayo --salida "$EVID9" --tope-pared 300 --observar-avance 1 2>&1)"
rc9=$?
[ "$rc9" -eq 0 ] || fail "observacion (aviso sale): se esperaba salida 0, salio $rc9 -- $salida9"
grep -q '## Observacion extendida' "$EVID9" || fail "observacion (aviso sale): falta la seccion en la evidencia"
grep -A2 '## Observacion extendida' "$EVID9" | grep -q 'FUNCIONA observado real' \
  || fail "observacion (aviso sale): no se vio 'FUNCIONA observado real': $(grep -A2 '## Observacion extendida' "$EVID9")"
grep -qE '^\| 4 .*observado real' "$EVID9" || fail "observacion (aviso sale): el caso 4 no quedo anotado como observado real"
grep -qE '^\| 7 .*observado real' "$EVID9" || fail "observacion (aviso sale): el caso 7 no quedo anotado como observado real"
grep -qE '^\| 4 .*\| FUNCIONA ' "$EVID9" || fail "observacion (aviso sale): el caso 4 dejo de ser FUNCIONA"
grep -qE '^\| 7 .*\| FUNCIONA ' "$EVID9" || fail "observacion (aviso sale): el caso 7 dejo de ser FUNCIONA"

# ============================= (10) observacion extendida: el aviso NO SALE =
# Con "main" mudo, ni el cron ni su scratch aparecen: la observacion tiene
# que decir "NO OBSERVADO: disparo real", nunca "no aplica" (BRIEF-lead). El
# cron falso es GLOBAL (como el avance-tareas real): sin retirar el que dejo
# el escenario (9) en el mismo CORRIDA_STATE, este escenario lo heredaria y
# "veria" un aviso que "main" (mudo) nunca creo.
rm -rf "$T/corridas/.sim9-obs-cron"
EVID10="$T/evidencia-10.md"
salida10="$(SIM_MAIN=mudo SIM_TOPE_OBS_POLL=2 SIM_TOPE_OBS_VENTANA=5 \
  bash "$ARNES" --ensayo --salida "$EVID10" --tope-pared 300 --observar-avance 1 2>&1)"
rc10=$?
[ "$rc10" -eq 1 ] || fail "observacion (aviso no sale): se esperaba salida 1 (5 y 6 tambien NO FUNCIONA con main mudo), salio $rc10 -- $salida10"
grep -A2 '## Observacion extendida' "$EVID10" | grep -q 'NO OBSERVADO: disparo real' \
  || fail "observacion (aviso no sale): no se vio 'NO OBSERVADO: disparo real': $(grep -A2 '## Observacion extendida' "$EVID10")"
grep -A2 '## Observacion extendida' "$EVID10" | grep -q 'no aplica' \
  && fail "observacion (aviso no sale): la seccion dijo 'no aplica' en vez de NO OBSERVADO"
grep -qE '^\| 4 .*NO OBSERVADO: disparo real' "$EVID10" || fail "observacion (aviso no sale): el caso 4 no quedo anotado NO OBSERVADO"
grep -qE '^\| 7 .*NO OBSERVADO: disparo real' "$EVID10" || fail "observacion (aviso no sale): el caso 7 no quedo anotado NO OBSERVADO"
# Los casos 4 y 7 mismos siguen FUNCIONA (el reloj inyectado ya los probo);
# solo el DISPARO REAL queda sin observar.
grep -qE '^\| 4 .*\| FUNCIONA ' "$EVID10" || fail "observacion (aviso no sale): el caso 4 dejo de ser FUNCIONA"
grep -qE '^\| 7 .*\| FUNCIONA ' "$EVID10" || fail "observacion (aviso no sale): el caso 7 dejo de ser FUNCIONA"

# ============================= (11) --dry-run: no toca nada =================
T11="$T/dry-run-check"
mkdir -p "$T11"
antes11="$(find "$T/corridas" -maxdepth 1 -name 'sim9-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
salida11="$(bash "$ARNES" --ensayo --dry-run 2>&1)"
rc11=$?
[ "$rc11" -eq 0 ] || fail "--dry-run: se esperaba salida 0, salio $rc11 -- $salida11"
printf '%s\n' "$salida11" | grep -q '^DRY-RUN:' || fail "--dry-run: no dijo DRY-RUN: $salida11"
printf '%s\n' "$salida11" | grep -q 'nada de esto se ejecuto' || fail "--dry-run: no confirmo que no ejecuto nada"
despues11="$(find "$T/corridas" -maxdepth 1 -name 'sim9-*' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$despues11" -eq "$antes11" ] || fail "--dry-run creo un directorio de corrida (se esperaba ninguno nuevo)"
sesiones11="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones11" -eq 0 ] || fail "--dry-run dejo sesiones sim9-* vivas"

echo "TODO VERDE: simulacro-fase9 (piezas a-e)"

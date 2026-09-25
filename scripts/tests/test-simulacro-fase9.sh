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

# decide-puro.mjs importa seguimiento-clock.ts (un .ts con sintaxis borrable):
# necesita un node capaz de importar .ts SIN flags extra, con la misma
# invocacion exacta que usa decide-puro.mjs ("node archivo.mjs", nada mas).
# CodeRabbit (PR #153): un numero de version >=22 NO alcanza para saberlo —
# el type stripping nativo sin flag es el default recien desde 22.18.0; una
# 22.6-22.17 lo tiene detras de --experimental-strip-types y con la
# invocacion pelada simplemente falla. Se prueba la capacidad REAL (importar
# un .ts minimo) en vez de adivinar por el numero.
elegir_node() {
  local c tmp
  tmp="$(mktemp -d)" || return 1
  printf 'export const SIM9_OK = "ok";\n' > "$tmp/prueba.ts"
  printf 'import { SIM9_OK } from "./prueba.ts";\nif (SIM9_OK !== "ok") process.exit(1);\n' > "$tmp/prueba.mjs"
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if "$c" "$tmp/prueba.mjs" >/dev/null 2>&1; then
      echo "$c"; rm -rf "$tmp"; return 0
    fi
  done
  rm -rf "$tmp"
  return 1
}
SIM9_NODE_BIN="$(elegir_node)" || fail "no hay un node capaz de importar un .ts sin flags extra (como decide-puro.mjs lo necesita)"
export SIM9_NODE_BIN

# SIM9_SOLO=<n>[,<n>...] corre solo esos escenarios numerados (para iterar
# rojo/verde de un punto sin pagar los ~9 min de la bateria completa); sin
# el, corren todos (asi debe correr la bateria completa, una sola vez).
SIM9_SOLO="${SIM9_SOLO:-}"
debe_correr() { # $1 numero de escenario; 0 = correrlo
  [ -z "$SIM9_SOLO" ] && return 0
  case ",$SIM9_SOLO," in *",$1,"*) return 0;; esac
  return 1
}

# `timeout` no viene de fabrica en macOS (coreutils lo instala como
# `gtimeout`, salvo que se agregue su gnubin al PATH) — CodeRabbit (PR #153):
# sin esto, el escenario del reloj de pared fallaba con "command not found"
# ANTES de arrancar el arnes, en vez de probar lo que dice probar. `timeout`,
# si no `gtimeout`, si no un limite portable (un job de fondo que mata al
# comando si se pasa del plazo).
elegir_timeout() {
  command -v timeout >/dev/null 2>&1 && { command -v timeout; return 0; }
  command -v gtimeout >/dev/null 2>&1 && { command -v gtimeout; return 0; }
  return 1
}
TIMEOUT_BIN="$(elegir_timeout || true)"
con_tope_prueba() { # $1 segundos; resto: comando -> mismo rc que el comando
  local seg="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$seg" "$@"
    return $?
  fi
  "$@" &
  local pid=$! rc
  ( sleep "$seg"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local vigia=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$vigia" 2>/dev/null
  return "$rc"
}

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

if debe_correr 1; then
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

fi

if debe_correr 2; then
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

fi

if debe_correr 3; then
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

fi

if debe_correr 4; then
# ============================= (4) grep del arnes: sin rm -r/-rf ============
sed 's/#.*//' scripts/mac/simulacro-fase9.sh | grep -qE 'rm[[:space:]]+-[a-zA-Z]*r' \
  && fail "el arnes tiene un rm -r/-rf fuera de un comentario: la limpieza tiene que ser sin rm -r"

fi

if debe_correr 5; then
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

fi

if debe_correr 6; then
# ============================= (6) responder apagado: caso 2 NO FUNCIONA ====
EVID6="$T/evidencia-6.md"
salida6="$(SIM9_SIN_RESPONDER=1 bash "$ARNES" --ensayo --salida "$EVID6" --tope-pared 60 2>&1)"
rc6=$?
[ "$rc6" -eq 1 ] || fail "responder apagado: se esperaba salida 1, salio $rc6 -- $salida6"
grep -qE '^\| 2 .*\| NO FUNCIONA ' "$EVID6" \
  || fail "responder apagado: el caso 2 no salio NO FUNCIONA: $(grep '^| 2 ' "$EVID6")"

fi

if debe_correr 7; then
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

fi

if debe_correr 8; then
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

fi

if debe_correr 9; then
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

fi

if debe_correr 10; then
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

fi

if debe_correr 14; then
# ===================== (14) observacion extendida: scratch VIEJO no cuela (CodeRabbit bloqueante) ==
# CodeRabbit (PR #153, bloqueante): un cron avance-tareas que YA existia de
# antes (rancio, con un reporte confirmado de mucho antes de esta corrida) no
# puede colarse como si fuera el aviso de ESTA observacion. Se deja un
# job.json + scratch.json ya escritos a mano, con un messageId real pero un
# "ultimoReporteConfirmado" del pasado remoto (epoch 1000), y "main" mudo (no
# lo toca de nuevo): el cron NUNCA dispara durante la ventana, pero su scratch
# viejo sigue ahi con corte "reporte-confirmado".
rm -rf "$T/corridas/.sim9-obs-cron"
mkdir -p "$T/corridas/.sim9-obs-cron"
printf '{"id":"sim9-avance-tareas-fake","name":"avance-tareas","declarationKey":"avance-tareas","enabled":true}' \
  > "$T/corridas/.sim9-obs-cron/job.json"
printf '{"schema":"seguimiento-clock.v1","corte":{"kind":"reporte-confirmado","ultimoReporteConfirmado":1000},"ultimoEstado":"","ultimoInmediato":null,"messageId":8001,"trabajosActivos":[]}' \
  > "$T/corridas/.sim9-obs-cron/sim9-avance-tareas-fake.scratch.json"
EVID14="$T/evidencia-14.md"
salida14="$(SIM_MAIN=mudo SIM_TOPE_OBS_POLL=2 SIM_TOPE_OBS_VENTANA=5 \
  bash "$ARNES" --ensayo --salida "$EVID14" --tope-pared 300 --observar-avance 1 2>&1)"
rc14=$?
[ "$rc14" -eq 1 ] || fail "observacion (scratch viejo): se esperaba salida 1, salio $rc14 -- $salida14"
grep -A2 '## Observacion extendida' "$EVID14" | grep -q 'NO OBSERVADO: disparo real' \
  || fail "observacion (scratch viejo): no se vio 'NO OBSERVADO: disparo real': $(grep -A2 '## Observacion extendida' "$EVID14")"
grep -A2 '## Observacion extendida' "$EVID14" | grep -q 'FUNCIONA observado real' \
  && fail "observacion (scratch viejo): acepto un scratch viejo (de antes del turno) como observado real"
grep -qE '^\| 4 .*observado real' "$EVID14" && fail "observacion (scratch viejo): el caso 4 quedo anotado observado real"
grep -qE '^\| 7 .*observado real' "$EVID14" && fail "observacion (scratch viejo): el caso 7 quedo anotado observado real"
rm -rf "$T/corridas/.sim9-obs-cron"

fi

if debe_correr 11; then
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

fi

if debe_correr 15; then
# ===================== (15) --tope-pared efectivo con --observar-avance =====
# CodeRabbit (PR #153, bloqueante): el tope de pared (570s por defecto) mataba
# la corrida mucho antes de que la observacion extendida pudiera confirmar
# nada (la ventana minima real son 1800s). (a) sin --tope-pared explicito, el
# arnes lo sube solo; --dry-run (sin abrir nada: la validacion corre ANTES de
# sourcear lib.sh, ni siquiera necesita --ensayo) lo muestra. (b) con un
# --tope-pared explicito insuficiente, rechaza la combinacion antes de tocar
# nada.
salida15a="$(bash "$ARNES" --ensayo --dry-run --observar-avance 35 2>&1)"
rc15a=$?
[ "$rc15a" -eq 0 ] || fail "--dry-run --observar-avance 35: se esperaba salida 0, salio $rc15a -- $salida15a"
tope_efectivo15="$(printf '%s\n' "$salida15a" | sed -n 's/.*tope de pared efectivo): \([0-9]*\)s.*/\1/p')"
[ -n "$tope_efectivo15" ] || fail "--dry-run --observar-avance 35: no se pudo leer el tope de pared efectivo: $salida15a"
[ "$tope_efectivo15" -ge $((35*60)) ] || fail "--dry-run --observar-avance 35: el tope efectivo ($tope_efectivo15) es menor que 35*60: $salida15a"

salida15b="$(bash "$ARNES" --observar-avance 35 --tope-pared 100 2>&1)"
rc15b=$?
[ "$rc15b" -eq 2 ] || fail "--observar-avance 35 --tope-pared 100 (insuficiente): se esperaba salida 2 (rechazo), salio $rc15b -- $salida15b"
printf '%s\n' "$salida15b" | grep -q 'menor que lo que --observar-avance' \
  || fail "--observar-avance 35 --tope-pared 100: no explico por que rechazo: $salida15b"
fi

if debe_correr 16; then
# ===================== (16) ventana de observacion: chequeo al borde ========
# CodeRabbit (PR #153, bloqueante): el bucle solo entraba mientras faltaban
# MENOS de SIM_TOPE_OBS_VENTANA segundos reales; el chequeo del scratch solo
# corria cuando ya habian pasado AL MENOS esos mismos segundos — con un
# sondeo que salta justo por encima del borde, ninguna vuelta cae con las dos
# cosas a la vez y el bucle terminaba sin comprobar nunca, aunque el reporte
# ya estuviera confirmado. Ventana angosta a proposito (SIM_TOPE_OBS_VENTANA
# apenas por debajo del tope de la observacion, con un sondeo grande) para
# que la unica vuelta util caiga justo en el borde.
rm -rf "$T/corridas/.sim9-obs-cron"
EVID16="$T/evidencia-16.md"
salida16="$(SIM_TOPE_OBS_POLL=30 SIM_TOPE_OBS_VENTANA=55 \
  bash "$ARNES" --ensayo --salida "$EVID16" --tope-pared 300 --observar-avance 1 2>&1)"
rc16=$?
[ "$rc16" -eq 0 ] || fail "ventana al borde: se esperaba salida 0 (7/7 FUNCIONA), salio $rc16 -- $salida16"
grep -A2 '## Observacion extendida' "$EVID16" | grep -q 'FUNCIONA observado real' \
  || fail "ventana al borde: no se confirmo el aviso justo en el limite de la ventana: $(grep -A2 '## Observacion extendida' "$EVID16")"
rm -rf "$T/corridas/.sim9-obs-cron"
fi

if debe_correr 12; then
# ============================= (12) tabla_casos: saneo y escape (CodeRabbit) =
# Extrae escribir_caso/leer_caso/markdown_celda/tabla_casos DEL ARNES REAL (no
# una reimplementacion) para probarlas aisladas: un detalle con un salto de
# linea propio (como la salida de un `lanzar-sesion` fallido) no puede correr
# los campos siguientes de leer_caso, y una barra vertical en cualquier campo
# no puede crear una columna de mas en la tabla Markdown.
T12="$T/tabla-check"
mkdir -p "$T12/casos"
FUNCS12="$T12/funcs.sh"
awk '/^escribir_caso\(\)/,/^}/; /^leer_caso\(\)/,/^}/; /^markdown_celda\(\)/,/^}/; /^tabla_casos\(\)/,/^}/' \
  "$ARNES" > "$FUNCS12"
[ -s "$FUNCS12" ] || fail "no se pudieron extraer las funciones de la tabla del arnes"
(
  DIR_SIM="$T12"
  CASOS_NOMBRE="1|primer caso de prueba"
  . "$FUNCS12"
  escribir_caso 1 "NO FUNCIONA" "linea uno
linea dos | con una barra" "" "" "" "" "simulado | con barra"
  tabla_casos > "$T12/tabla.md"
)
n_filas12="$(grep -c '^|' "$T12/tabla.md")"
[ "$n_filas12" -eq 3 ] || fail "un detalle con salto de linea corrio la tabla a mas de 3 lineas (cabecera+separador+1 fila): $(cat "$T12/tabla.md")"
grep -q 'linea uno linea dos \\| con una barra' "$T12/tabla.md" \
  || fail "el detalle con salto de linea no quedo aplastado y con su barra escapada: $(cat "$T12/tabla.md")"
grep -q 'simulado \\| con barra' "$T12/tabla.md" \
  || fail "la celda 'que se simulo' no escapo su barra vertical: $(cat "$T12/tabla.md")"

fi

if debe_correr 13; then
# ============================= (13) --tope-pared: reloj de pared aplicado ===
# CodeRabbit: el tope se leia pero nunca se aplicaba. Un caso 1 colgado (glm
# mudo, nunca dice LISTO) con un tope de pared corto tiene que cortar la
# corrida por la via normal (SIGTERM -> limpieza_exit), sin sesiones vivas
# ni que el proceso seco quede corriendo mas alla del tope.
EVID13="$T/evidencia-13.md"
ini13=$SECONDS
salida13="$(con_tope_prueba 60 env SIM9_GLM_MUDO=1 SIM_TOPE_C1=120 \
  bash "$ARNES" --ensayo --salida "$EVID13" --tope-pared 5 2>&1)"
rc13=$?
dur13=$((SECONDS-ini13))
[ "$dur13" -lt 40 ] || fail "--tope-pared 5 no corto la corrida colgada a tiempo (tardo ${dur13}s): $salida13"
[ "$rc13" -eq 143 ] || fail "--tope-pared 5 con la corrida colgada: se esperaba salida 143 (SIGTERM via limpieza_exit), salio $rc13 -- $salida13"
sesiones13="$("$TM_REAL" -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep -c 'sim9-')"
[ "$sesiones13" -eq 0 ] || fail "--tope-pared: quedaron sesiones sim9-* vivas tras el corte"

fi

echo "TODO VERDE: simulacro-fase9 (piezas a-e)"

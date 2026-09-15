#!/bin/bash
# Prueba del incidente 2026-09-14: el agente main escribia en las pestañas de Terminal de la Mac
# con teclas globales (osascript / System Events). El Enter se perdia entre cambios de foco, un
# pegado cayo en la pestaña de otro proyecto, y el "inyectar \r al dispositivo /dev/ttysN" solo
# pinto la pantalla: en macOS no existe TIOCSTI, escribir al tty es SALIDA, nunca entrada. La
# orden quedo "escrita" en el prompt y ningun Enter la disparo.
# Ademas: el 2026-09-11 un `openclaw doctor` interactivo instalo en la Mac un segundo nodo
# (launchd ai.openclaw.node) apuntando a 127.0.0.1:18789, donde no hay gateway: 11 000
# ECONNREFUSED en 4 dias, jamas emparejado. El nodo de la Mac es el de OpenClaw.app.
# Verifica: (1) el detector marca las formas malas y deja pasar las buenas (discrimina);
# (2) ninguna instruccion versionada para agentes usa la forma mala; (3) la skill mac-tmux-control
# existe en main con sus anclas y mac-terminal-control la manda primero; (4) el wrapper
# agent-tmux.sh parsea, sanea el nombre y falla bien; (5) con tmux local, el mecanismo real:
# send-keys -l + Enter por separado llega al programa y capture-pane lo lee.
# Uso: bash scripts/tests/test-mac-tmux-control.sh
# OJO: agents/*/agent/workshop-skills/ son ARTEFACTOS GENERADOS por el snapshot del gateway
# (ver test-browser-profile-flag.sh). Si (3) se pone rojo, el arreglo va en el gateway.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Escribir a un dispositivo tty como si fuera entrada, o instalar el nodo headless en la Mac.
# Escribir al tty (echo/printf/cat/tee) o LEER del tty (< /dev/ttysN, script/screen/cat sobre el):
# un lector pegado al tty se roba las teclas que David escribe y el Enter nunca llega al TUI.
BAD_TTY='((echo|printf|cat)[^|]*>+ */dev/ttys[0-9]+|tee +(-a +)?/dev/ttys[0-9]+|< */dev/ttys[0-9]+|(script|screen|cat) [^|]*/dev/ttys[0-9]+)'
BAD_NODE='openclaw node install'
# Una prohibicion ("never ...") cita el comando sin ser una instruccion de correrlo.
bad() { grep -n -E -e "$BAD_TTY" -e "$BAD_NODE" | grep -v -i -E 'never|nunca|jam[aá]s'; }

# (1) Discrimina: las formas del incidente se marcan; las correctas y las prohibiciones no.
for c in "printf '\\r' > /dev/ttys006" \
         'echo "texto" >> /dev/ttys006' \
         'cat orden.txt > /dev/ttys016' \
         "printf 'orden' | tee /dev/ttys006" \
         'screen -dmS claude_tab /bin/bash -c "script -q /dev/null < /dev/ttys006 > /tmp/claw_ttys006.txt"' \
         'cat /dev/ttys005' \
         'openclaw node install --host 127.0.0.1 --port 18789'; do
  printf '%s\n' "$c" | bad >/dev/null || fail "el detector NO marca: $c (la prueba no discrimina)"
done
for c in "/opt/homebrew/bin/tmux send-keys -t claude-orbit -l 'hola'" \
         '/opt/homebrew/bin/tmux send-keys -t claude-orbit Enter' \
         '/opt/homebrew/bin/tmux capture-pane -p -t claude-orbit -S -80' \
         'ps -o pid,tty,command -t ttys006' \
         'lsof -a -p 123 -d cwd -Fn' \
         'tell application "Terminal" to get tty of tab 1 of window 1' \
         'Never run `openclaw node install` on the Mac' \
         "Nunca: printf '\\r' > /dev/ttys006"; do
  printf '%s\n' "$c" | bad >/dev/null && fail "el detector marca una forma correcta: $c"
done
echo "ok (1): el detector marca escrituras a /dev/ttysN y node install, y deja pasar tmux y las prohibiciones"

# (2) Ninguna instruccion versionada para agentes usa la forma mala (escribir NI leer el tty).
SPECS=('agents/*/agent/workshop-skills/*/SKILL.md' 'agents/*/agent/workshop-skills/*/*.md' '*AGENTS.md' '*TOOLS.md' 'docs/cron-messages/*.txt')
n=$(git ls-files --cached --others --exclude-standard -- "${SPECS[@]}" | wc -l)
[ "$n" -gt 0 ] || fail "no encontre instrucciones versionadas que revisar"
hits=$(git ls-files -z --cached --others --exclude-standard -- "${SPECS[@]}" \
  | xargs -0 grep -n -E -e "$BAD_TTY" -e "$BAD_NODE" -- 2>/dev/null | grep -v -i -E 'never|nunca|jam[aá]s')
[ -z "$hits" ] || fail "instrucciones con la forma mala:
$hits"
echo "ok (2): $n instrucciones revisadas, ninguna escribe a /dev/ttysN ni instala el nodo headless"

# (3) La skill vive en main con sus anclas, y la skill vieja manda a tmux antes del osascript.
SK=agents/main/agent/workshop-skills/mac-tmux-control/SKILL.md
[ -f "$SK" ] || fail "falta $SK"
grep -qF '/opt/homebrew/bin/tmux list-sessions' "$SK" || fail "$SK: falta el listado por ruta absoluta"
grep -qF "send-keys -t <session> -l" "$SK" || fail "$SK: falta send-keys literal (-l)"
grep -qF 'send-keys -t <session> Enter' "$SK" || fail "$SK: falta el Enter en llamada aparte"
grep -qF 'capture-pane -p -t <session> -S -80' "$SK" || fail "$SK: falta la lectura con capture-pane"
grep -qF 'Never write to `/dev/ttysNNN`' "$SK" || fail "$SK: falta la prohibicion de escribir al tty"
grep -qF 'openclaw node uninstall' "$SK" || fail "$SK: falta el arreglo del nodo duplicado"
grep -qF 'COMPANION_APP_UNAVAILABLE' "$SK" || fail "$SK: falta la regla de esperas cortas"
OLD=agents/main/agent/workshop-skills/mac-terminal-control/SKILL.md
[ -f "$OLD" ] || fail "falta $OLD"
grep -qF 'mac-tmux-control' "$OLD" || fail "$OLD: no manda a mac-tmux-control antes del osascript"
grep -qF '/dev/ttysNNN' "$OLD" || fail "$OLD: no advierte que escribir al tty no es entrada"
echo "ok (3): skill mac-tmux-control en main con sus anclas; mac-terminal-control la refiere"

# (4) El wrapper parsea, sanea el nombre de sesion y falla con codigo 2 sin argumentos o sin dir.
W=scripts/mac/agent-tmux.sh
[ -f "$W" ] || fail "falta $W"
bash -n "$W" || fail "$W no parsea"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/goncloud.orbit:v2"
out=$(bash "$W" --print-name claude "$T/goncloud.orbit:v2") || fail "--print-name fallo"
[ "$out" = "claude-goncloud-orbit-v2" ] || fail "nombre no saneado: '$out' (tmux rechaza '.' y ':')"
bash "$W" >/dev/null 2>&1; [ $? -eq 2 ] || fail "$W sin argumentos debe salir con 2"
bash "$W" --print-name claude "$T/no-existe" >/dev/null 2>&1; [ $? -eq 2 ] || fail "$W con dir inexistente debe salir con 2"
# Un 2º argumento con guion es del tool, no un dir: `agent-tmux.sh claude --resume` usa el cwd.
out=$(cd "$T/goncloud.orbit:v2" && bash "$OLDPWD/$W" --print-name claude --resume) || fail "--print-name con flag del tool fallo"
[ "$out" = "claude-goncloud-orbit-v2" ] || fail "un flag del tool se tomo como dir: '$out'"
echo "ok (4): wrapper parsea, nombre saneado, flags del tool no son dir, falla bien sin argumentos o sin dir"

# (4b) Config de tmux (rueda del mouse) y funciones de shell que abren los CLIs dentro de tmux solos.
C=scripts/mac/tmux.conf
grep -qE '^set -g mouse on' "$C" || fail "$C: falta 'set -g mouse on' (la rueda del mouse)"
grep -qF 'pbcopy' "$C" || fail "$C: seleccionar con el mouse debe copiar al portapapeles"
Z=scripts/mac/agent-tmux-shell.zsh
[ -f "$Z" ] || fail "falta $Z"
if command -v zsh >/dev/null; then
  zsh -n "$Z" || fail "$Z no parsea"
  STUB="$T/launcher"; printf '#!/bin/sh\necho "LAUNCHER $1 $2 $3"\n' > "$STUB"; chmod +x "$STUB"
  mkdir -p "$T/bin"; printf '#!/bin/sh\necho REAL-CLAUDE\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
  ZR="export PATH=$T/bin:\$PATH; source $PWD/$Z; export AGENT_TMUX_LAUNCHER=$STUB; export AGENT_TMUX_ASSUME_TTY=1"
  # Fuera de tmux e interactivo: va al launcher con el cwd y los flags del tool.
  out=$(cd "$T" && unset TMUX && zsh -c "$ZR; claude --resume" 2>&1)
  printf '%s\n' "$out" | grep -q "LAUNCHER claude $T/\?.* --resume\|LAUNCHER claude .* --resume" || fail "fuera de tmux, claude no fue al launcher: $out"
  # Dentro de tmux, o one-shot (--version), o sin tty: corre el tool real, nunca el launcher.
  out=$(zsh -c "$ZR; TMUX=1 claude; claude --version; unset AGENT_TMUX_ASSUME_TTY; claude </dev/null" 2>&1)
  [ "$(printf '%s\n' "$out" | grep -c REAL-CLAUDE)" -eq 3 ] || fail "dentro de tmux / one-shot / sin tty debe correr el tool real: $out"
  printf '%s\n' "$out" | grep -q LAUNCHER && fail "dentro de tmux / one-shot / sin tty no debe ir al launcher: $out"
  echo "ok (4b): tmux.conf con mouse; las funciones de shell rutean a tmux solo fuera de tmux e interactivo"
else
  echo "SKIP (4b): sin zsh en esta maquina"
fi

# (5) Mecanismo real, solo si hay tmux: servidor propio (-L) para no tocar las sesiones del usuario;
# el wrapper se prueba con un shim TMUX_BIN que agrega -L, asi tampoco toca al usuario.
TM=$(command -v tmux || true); [ -z "$TM" ] && [ -x /opt/homebrew/bin/tmux ] && TM=/opt/homebrew/bin/tmux
if [ -n "$TM" ]; then
  L="t$$"
  "$TM" -L "$L" new-session -d -s probe -x 80 -y 20 'cat' || fail "no pude crear la sesion de prueba"
  sleep 0.5
  "$TM" -L "$L" send-keys -t probe -l 'HOLA_TMUX Enter'   # -l: la palabra Enter NO es una tecla
  sleep 0.3
  "$TM" -L "$L" send-keys -t probe Enter
  sleep 0.5
  screen=$("$TM" -L "$L" capture-pane -p -t probe)
  # Colision de nombres: una sesion con el mismo nombre en OTRO dir se rechaza (exit 3), no se adopta.
  mkdir -p "$T/a/api" "$T/b/api"
  "$TM" -L "$L" new-session -d -s claude-api -c "$T/a/api" 'cat'
  TMUX_BIN="$(mktemp "$T/tmuxXXXX")"; printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" > "$TMUX_BIN"; chmod +x "$TMUX_BIN"
  TMUX_BIN="$TMUX_BIN" bash "$W" claude "$T/b/api" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || fail "la colision de nombres no se rechazo (exit $rc, esperado 3)"
  "$TM" -L "$L" kill-server 2>/dev/null
  # cat devuelve la linea: el texto aparece dos veces (eco de la tty + salida de cat).
  c=$(printf '%s\n' "$screen" | grep -c '^HOLA_TMUX Enter$')
  [ "$c" -eq 2 ] || fail "send-keys -l + Enter no llego a cat (apariciones=$c):
$screen"
  echo "ok (5): send-keys -l + Enter aparte llega al programa y capture-pane lo lee ($TM)"
else
  echo "SKIP (5): sin tmux en esta maquina; el mecanismo real se prueba en la Mac"
fi
echo "TODO VERDE: mac-tmux-control"

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
BAD_TTY='(echo|printf|cat|tee)[^|]*>+ */dev/ttys[0-9]+'
BAD_NODE='openclaw node install'
# Una prohibicion ("never ...") cita el comando sin ser una instruccion de correrlo.
bad() { grep -n -E -e "$BAD_TTY" -e "$BAD_NODE" | grep -v -i -E 'never|nunca|jam[aá]s'; }

# (1) Discrimina: las formas del incidente se marcan; las correctas y las prohibiciones no.
for c in "printf '\\r' > /dev/ttys006" \
         'echo "texto" >> /dev/ttys006' \
         'cat orden.txt > /dev/ttys016' \
         'openclaw node install --host 127.0.0.1 --port 18789'; do
  printf '%s\n' "$c" | bad >/dev/null || fail "el detector NO marca: $c (la prueba no discrimina)"
done
for c in "/opt/homebrew/bin/tmux send-keys -t claude-orbit -l 'hola'" \
         '/opt/homebrew/bin/tmux send-keys -t claude-orbit Enter' \
         '/opt/homebrew/bin/tmux capture-pane -p -t claude-orbit -S -80' \
         'ps -o pid,tty,command -t ttys006' \
         'Never run `openclaw node install` on the Mac' \
         "Nunca: printf '\\r' > /dev/ttys006"; do
  printf '%s\n' "$c" | bad >/dev/null && fail "el detector marca una forma correcta: $c"
done
echo "ok (1): el detector marca escrituras a /dev/ttysN y node install, y deja pasar tmux y las prohibiciones"

# (2) Ninguna instruccion versionada para agentes usa la forma mala.
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
echo "ok (4): wrapper parsea, nombre saneado, falla bien sin argumentos o sin dir"

# (5) Mecanismo real, solo si hay tmux: servidor propio (-L) para no tocar las sesiones del usuario.
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

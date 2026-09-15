#!/bin/bash
# Prueba de la tarea "el agente main se despierta solo, no con un cron cada 10 min": David
# corre sus agentes CLI dentro de tmux (scripts/mac/agent-tmux.sh); antes de esto, el agente
# main tenia que asomarse por cron a preguntar "¿sigue vivo?" sin saber si habia pasado algo.
# Esta prueba corre el vigilante (tmux-activity-watch.sh) y el Stop hook de Claude Code
# (claude-stop-openclaw-event.sh) contra un servidor tmux PROPIO (-L, nunca el del usuario) y
# un stub de `openclaw` que solo anexa sus argumentos a un archivo — nunca se llama al
# `openclaw system event` real (despertaria al agente vivo y podria mandar Telegram).
# Verifica: (1) los tres scripts parsean y el plist es un LaunchAgent valido; (2) la maquina de
# estados del vigilante (quiet una sola vez por silencio, activity nueva la resetea, closed
# borra el estado, un envio fallido no marca notified); (3) el Stop hook no manda nada fuera de
# tmux y manda el texto correcto dentro de tmux; (4) las anclas de las dos skills; (5) el
# detector de test-mac-tmux-control.sh sigue verde.
# Uso: bash scripts/tests/test-tmux-activity-watch.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

W=scripts/mac/tmux-activity-watch.sh
P=scripts/mac/ai.goncloud.tmux-activity-watch.plist
H=scripts/mac/claude-stop-openclaw-event.sh

# (1) Los tres scripts parsean con bash 3.2 y con homebrew bash, y el plist es un LaunchAgent valido.
[ -f "$W" ] || fail "falta $W"
[ -f "$P" ] || fail "falta $P"
[ -f "$H" ] || fail "falta $H"
/bin/bash -n "$W" || fail "$W no parsea con /bin/bash"
/bin/bash -n "$H" || fail "$H no parsea con /bin/bash"
if [ -x /opt/homebrew/bin/bash ]; then
  /opt/homebrew/bin/bash -n "$W" || fail "$W no parsea con /opt/homebrew/bin/bash"
  /opt/homebrew/bin/bash -n "$H" || fail "$H no parsea con /opt/homebrew/bin/bash"
fi
python3 -c "
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
assert d.get('Label') == 'ai.goncloud.tmux-activity-watch', 'Label incorrecto'
assert d.get('KeepAlive') is True, 'falta KeepAlive'
assert d.get('RunAtLoad') is True, 'falta RunAtLoad'
" "$P" || fail "$P: no parsea como plist valido o le faltan Label/KeepAlive/RunAtLoad"
echo "ok (1): los tres scripts parsean (bash 3.2 y homebrew bash) y el plist es un LaunchAgent valido"

# (2) y (3) necesitan un servidor tmux de verdad.
TM=$(command -v tmux || true); [ -z "$TM" ] && [ -x /opt/homebrew/bin/tmux ] && TM=/opt/homebrew/bin/tmux
if [ -z "$TM" ]; then
  echo "SKIP (2): sin tmux en esta maquina; el mecanismo real se prueba en la Mac"
  echo "SKIP (3): sin tmux en esta maquina; el mecanismo real se prueba en la Mac"
else
  T=$(mktemp -d) || exit 1
  trap '"$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
  L="taw$$"

  STATE_DIR="$T/state"
  LOG_FILE="$T/watch.log"
  STUB_DIR="$T/stubbin"
  mkdir -p "$STUB_DIR"
  CALLS="$T/openclaw-calls.txt"
  : >"$CALLS"
  RC_FILE="$T/openclaw-rc"
  echo 0 >"$RC_FILE"
  STUB_OPENCLAW="$STUB_DIR/openclaw"
  cat >"$STUB_OPENCLAW" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$CALLS"
exit "\$(cat "$RC_FILE")"
STUB
  chmod +x "$STUB_OPENCLAW"

  TMUX_SHIM="$T/tmux-shim"
  printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" >"$TMUX_SHIM"
  chmod +x "$TMUX_SHIM"

  run_once() {
    TMUX_BIN="$TMUX_SHIM" OPENCLAW_BIN="$STUB_OPENCLAW" QUIET_SECS=1 TICK_SECS=1 \
      STATE_DIR="$STATE_DIR" LOG_FILE="$LOG_FILE" \
      bash "$W" --once
  }

  # Sesion vigilada: muse-orbit, tool "muse" esta en TOOLS por default.
  "$TM" -L "$L" new-session -d -s muse-orbit -x 80 -y 20 'cat' || fail "no se pudo crear muse-orbit"
  # Sesion NO vigilada: tool "zsh" no esta en la lista.
  "$TM" -L "$L" new-session -d -s zsh-cosa -x 80 -y 20 'cat' || fail "no se pudo crear zsh-cosa"

  n=$(wc -l <"$CALLS" | tr -d ' '); [ "$n" -eq 0 ] || fail "no deberia haber llamadas todavia"

  sleep 2
  run_once || fail "primer --once fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 1 ] || fail "tras 2s de silencio esperaba 1 evento quiet, hubo $n:
$(cat "$CALLS")"
  grep -q 'muse-orbit quiet for' "$CALLS" || fail "el evento no menciona muse-orbit quiet: $(cat "$CALLS")"

  run_once || fail "segundo --once fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 1 ] || fail "un segundo --once sin actividad nueva NO debe repetir el evento (notified=1); hubo $n"

  "$TM" -L "$L" send-keys -t muse-orbit -l 'hola'
  "$TM" -L "$L" send-keys -t muse-orbit Enter
  run_once || fail "--once tras actividad nueva fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 1 ] || fail "actividad nueva (aun no callada QUIET_SECS) no debe generar un evento de inmediato; hubo $n"

  sleep 2
  run_once || fail "--once tras la segunda callada fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 2 ] || fail "esperaba un SEGUNDO evento quiet tras volver a hablar y callarse; hubo $n:
$(cat "$CALLS")"

  n=$(wc -l <"$CALLS" | tr -d ' ')
  cp "$CALLS" "$CALLS.before-zsh"
  # zsh-cosa nunca genera eventos porque "zsh" no esta en TOOLS.
  n2=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq "$n2" ] || fail "zsh-cosa (tool no listado) genero eventos"
  grep -q 'zsh-cosa' "$CALLS" && fail "zsh-cosa no deberia aparecer en ningun evento"
  echo "ok (2a): quiet una sola vez por silencio, se repite si vuelve a hablar y se calla, sesion no vigilada nunca dispara"

  [ -f "$STATE_DIR/muse-orbit.state" ] || fail "falta el archivo de estado de muse-orbit"
  "$TM" -L "$L" kill-session -t muse-orbit
  run_once || fail "--once tras kill-session fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 3 ] || fail "esperaba un evento closed tras kill-session; hubo $n:
$(cat "$CALLS")"
  tail -1 "$CALLS" | grep -q 'muse-orbit closed' || fail "el ultimo evento no es 'closed' de muse-orbit: $(tail -1 "$CALLS")"
  [ -f "$STATE_DIR/muse-orbit.state" ] && fail "el archivo de estado de muse-orbit deberia haberse borrado tras closed"
  echo "ok (2b): sesion cerrada dispara 'closed' y borra su archivo de estado"

  # Reintento tras fallo: un envio que falla NO debe marcar notified (fail-open).
  "$TM" -L "$L" new-session -d -s muse-retry -x 80 -y 20 'cat' || fail "no se pudo crear muse-retry"
  sleep 2
  echo 1 >"$RC_FILE"  # el stub va a salir con 1 (fallo simulado)
  : >"$LOG_FILE"
  run_once || fail "--once con stub fallando no deberia abortar el vigilante"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 4 ] || fail "el stub fallando igual debe intentarse (queda registrada la llamada); hubo $n"
  grep -qi 'fail' "$LOG_FILE" || fail "el log no registro el fallo del envio"
  # Un envio fallido nunca escribe notified=1: si el archivo de estado existe no debe decir
  # notified=1, y si no existe (aun no hubo envio exitoso) tambien es consistente con "no
  # notificado".
  if [ -f "$STATE_DIR/muse-retry.state" ]; then
    grep -q 'notified=1' "$STATE_DIR/muse-retry.state" && fail "un envio fallido NO debe marcar notified=1 (se reintenta)"
  fi
  echo 0 >"$RC_FILE"
  run_once || fail "--once de reintento fallo"
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 5 ] || fail "el reintento con el stub ya sano debio mandar el evento; hubo $n"
  grep -q 'notified=1' "$STATE_DIR/muse-retry.state" || fail "tras el reintento exitoso notified deberia ser 1"
  echo "ok (2c): un envio fallido no marca notified (fail-open) y se reintenta en el siguiente tick"

  "$TM" -L "$L" kill-server 2>/dev/null
  echo "ok (2): maquina de estados del vigilante verificada con tmux real ($TM)"

  # (3) Stop hook.
  : >"$CALLS"
  TRANSCRIPT="$T/transcript.jsonl"
  cat >"$TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"role":"user","content":"hola"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Primera respuesta, ignorame."}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Listo, termine el bloque A.5."}]}}
JSONL
  HOOK_JSON=$(python3 -c "
import json
print(json.dumps({
  'cwd': '/Users/dn/dev/goncloud-orbit',
  'session_id': 'abc123',
  'transcript_path': '$TRANSCRIPT',
  'hook_event_name': 'Stop',
  'stop_hook_active': False,
}))
")

  # Fuera de tmux: exit 0 inmediato, el stub no se llama.
  out_rc=$(unset TMUX; TMUX_BIN="$TMUX_SHIM" OPENCLAW_BIN="$STUB_OPENCLAW" bash -c "unset TMUX; printf '%s' '$HOOK_JSON' | bash '$H'; echo \$?" | tail -1)
  [ "$out_rc" = "0" ] || fail "el hook fuera de tmux debe salir 0, salio $out_rc"
  n=$(wc -l <"$CALLS" | tr -d ' '); [ "$n" -eq 0 ] || fail "fuera de tmux el stub NO debe llamarse, se llamo $n vez/veces"
  echo "ok (3a): fuera de tmux (\$TMUX vacio) el hook no manda nada y sale 0"

  DISPLAY_STUB="$T/tmux-display-stub"
  cat >"$DISPLAY_STUB" <<STUB
#!/bin/sh
if [ "\$1" = "display-message" ]; then
  echo "claude-orbit"
  exit 0
fi
exec $TMUX_SHIM "\$@"
STUB
  chmod +x "$DISPLAY_STUB"

  out_rc=$(TMUX=fake TMUX_BIN="$DISPLAY_STUB" OPENCLAW_BIN="$STUB_OPENCLAW" bash -c "printf '%s' '$HOOK_JSON' | bash '$H'; echo \$?" | tail -1)
  [ "$out_rc" = "0" ] || fail "el hook dentro de tmux debe salir 0, salio $out_rc"

  waited=0
  while [ "$(wc -l <"$CALLS" | tr -d ' ')" -eq 0 ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  n=$(wc -l <"$CALLS" | tr -d ' ')
  [ "$n" -eq 1 ] || fail "dentro de tmux el stub deberia haberse llamado una vez (via nohup en 2do plano), se llamo $n"
  call=$(cat "$CALLS")
  printf '%s' "$call" | grep -q '/Users/dn/dev/goncloud-orbit' || fail "el evento no incluye el cwd: $call"
  printf '%s' "$call" | grep -q 'claude-orbit' || fail "el evento no incluye la sesion tmux: $call"
  printf '%s' "$call" | grep -q 'Listo, termine el bloque A.5' || fail "el evento no incluye el ultimo texto del asistente: $call"
  echo "ok (3b): dentro de tmux el hook manda cwd + sesion + ultimo texto del asistente en 2do plano"
fi

# (4) Anclas de las dos skills tocadas.
SK=agents/main/agent/workshop-skills/mac-tmux-control/SKILL.md
grep -qF '## Wake-ups (events)' "$SK" || fail "$SK: falta la seccion Wake-ups (events)"
grep -qF 'background: true' "$SK" || fail "$SK: falta la regla de esperar con exec background: true"
grep -qF 'capture-pane' "$SK" || fail "$SK: falta la regla de leer con capture-pane antes de actuar"
grep -qF 'notifyOnExit' "$SK" || fail "$SK: falta la mencion de notifyOnExit"

DISP=agents/main/agent/workshop-skills/agent-dispatch/SKILL.md
grep -qF 'Wake-ups' "$DISP" || fail "$DISP: el paso 3 no referencia el mecanismo de despertar de mac-tmux-control"
echo "ok (4): anclas de mac-tmux-control y agent-dispatch presentes"

# (5) El detector de test-mac-tmux-control.sh (parte 1) sigue verde.
bash scripts/tests/test-mac-tmux-control.sh >/dev/null 2>&1 || fail "test-mac-tmux-control.sh se puso rojo"
echo "ok (5): test-mac-tmux-control.sh sigue verde"

echo "TODO VERDE: tmux-activity-watch"

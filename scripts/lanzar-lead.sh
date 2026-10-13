#!/usr/bin/env bash
# Lanza una sesión de tmux para un lead (o un implementador) con el cwd, el
# flag sin preguntas y la marca OPENCLAW_WATCH correctos, espera a que el CLI
# tome el teclado, manda el mensaje inicial y lee de vuelta el cwd del proceso.
#
# Por qué existe (medido 2026-09-17/18, Fase 10 de Orbit): el hook del kit de
# merge usa como clave el cwd del PROCESO del CLI; un `cd` de una herramienta
# no lo mueve. Así que el cwd se fija aquí, al crear la sesión, y se comprueba.
# Y un `send-keys` a un TUI que todavía no tomó el teclado se pierde sin
# rastro, con el sentinel dentro: por eso se espera el prompt antes de mandar.
#
# uso: lanzar-lead.sh -s <sesion> -c <cwd> -m '<mensaje>' [-p '<regex prompt>'] [-t <seg>] -- <cli> [flags...]
#   -s  nombre de la sesión de tmux (p. ej. fase10-lead)
#   -c  directorio de trabajo del proceso (debe existir)
#   -m  mensaje inicial, con su sentinel (p. ej. '... -saikit')
#   -p  regex (grep -E) que identifica el prompt del CLI en pantalla; default: cualquier línea no vacía
#   -t  segundos máximos de espera del prompt; default 60
#   --  después va el CLI y sus flags, tal cual se ejecutan
# salida: la última línea es `LISTO <sesion> <cwd>` o `ATORADO <razón>`
# códigos: 0 ok · 1 uso/cwd inválido · 2 la sesión ya existía · 3 cwd del proceso distinto · 4 sin prompt · 5 el mensaje no entró
# TMUX_BIN (default /opt/homebrew/bin/tmux) y PATH_LEAD se pueden fijar por entorno (los tests lo usan).
set -u
TMUX_BIN=${TMUX_BIN:-/opt/homebrew/bin/tmux}
PATH_LEAD=${PATH_LEAD:-/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin}
SESION=""; CWD=""; MENSAJE=""; PROMPT='[^[:space:]]'; TOPE=60
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SESION=$2; shift 2 ;;
    -c) CWD=$2; shift 2 ;;
    -m) MENSAJE=$2; shift 2 ;;
    -p) PROMPT=$2; shift 2 ;;
    -t) TOPE=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "ATORADO uso: argumento desconocido $1"; exit 1 ;;
  esac
done
[ $# -gt 0 ] || { echo "ATORADO uso: falta el CLI después de --"; exit 1; }
[ -n "$SESION" ] && [ -n "$CWD" ] && [ -n "$MENSAJE" ] || { echo "ATORADO uso: -s, -c y -m son obligatorios"; exit 1; }
[ -d "$CWD" ] || { echo "ATORADO cwd inexistente: $CWD"; exit 1; }
CWD_REAL=$(cd "$CWD" && pwd -P)

if "$TMUX_BIN" has-session -t "$SESION" 2>/dev/null; then
  echo "YA-EXISTE $SESION"
  echo "ATORADO la sesion $SESION ya existe: kill-session antes de relanzar"
  exit 2
fi

# El CLI y sus flags van dentro del comando de la sesión, con el PATH embebido.
CMD="PATH=$PATH_LEAD:\$PATH exec"
for a in "$@"; do CMD="$CMD $(printf '%q' "$a")"; done
"$TMUX_BIN" new-session -d -s "$SESION" -x 200 -y 50 -c "$CWD_REAL" "$CMD" || { echo "ATORADO new-session fallo"; exit 1; }
"$TMUX_BIN" set-environment -t "$SESION" OPENCLAW_WATCH 1
echo "marca=$("$TMUX_BIN" show-environment -t "$SESION" OPENCLAW_WATCH)"

PANE_CWD=$("$TMUX_BIN" display-message -p -t "$SESION" '#{pane_current_path}')
echo "cwd=$PANE_CWD"
if [ "$(cd "$PANE_CWD" 2>/dev/null && pwd -P)" != "$CWD_REAL" ]; then
  echo "ATORADO cwd del proceso ($PANE_CWD) distinto del pedido ($CWD_REAL)"
  exit 3
fi
PANE_PID=$("$TMUX_BIN" display-message -p -t "$SESION" '#{pane_pid}')
echo "proceso=$(ps -o args= -p "$PANE_PID" 2>/dev/null | head -1)"

# Espera el prompt: el CLI tiene que haber tomado el teclado antes del mensaje.
n=0
until "$TMUX_BIN" capture-pane -p -t "$SESION" | grep -qE -- "$PROMPT"; do
  n=$((n + 1))
  if [ "$n" -ge "$TOPE" ]; then
    echo "ATORADO sin prompt en ${TOPE}s (regex: $PROMPT)"
    exit 4
  fi
  sleep 1
done
echo "prompt=ok (${n}s)"

"$TMUX_BIN" send-keys -t "$SESION" -l "$MENSAJE"
sleep 1
"$TMUX_BIN" send-keys -t "$SESION" Enter
# El mensaje entró si la pantalla lo muestra (eco del CLI o de la caja de texto).
n=0
until "$TMUX_BIN" capture-pane -p -t "$SESION" -S -60 | grep -qF -- "${MENSAJE:0:40}"; do
  n=$((n + 1))
  if [ "$n" -ge 20 ]; then
    echo "ATORADO el mensaje no aparece en pantalla tras 20s"
    exit 5
  fi
  sleep 1
done
echo "LISTO $SESION $CWD_REAL"

#!/bin/sh
# Doble de TMUX_BIN para --ensayo (9.9, pieza a): el mismo tmux real, pero con
# su propio socket (-L), para que el arnes de mentira jamas toque las
# sesiones de nadie mas. Env: SIM9_TMUX_SOCKET (obligatorio).
set -u
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
if [ -z "$TM_REAL" ]; then
  echo "tmux-envoltura: no hay tmux real en el PATH" >&2
  exit 1
fi
if [ -z "${SIM9_TMUX_SOCKET:-}" ]; then
  echo "tmux-envoltura: falta SIM9_TMUX_SOCKET" >&2
  exit 1
fi
exec "$TM_REAL" -L "$SIM9_TMUX_SOCKET" "$@"

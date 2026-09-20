#!/bin/bash
# Retira la vigilancia de una sesion que pertenece a una corrida registrada.
# No mata tmux, no borra worktrees y repetir la operacion es seguro.
corrida_terminar_sesion() {
  [ "$#" -eq 2 ] || {
    echo "uso: corrida.sh terminar-sesion <id> <sesion>" >&2
    return 2
  }
  local id="$1" sesion="$2" reg marca
  corrida_id_valido "$id" || { echo "id invalido: $id" >&2; return 2; }
  corrida_id_valido "$sesion" || { echo "sesion invalida: $sesion" >&2; return 2; }
  reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "registro inexistente: $id" >&2; return 1; }
  [ -n "${TMUX_BIN:-}" ] || { echo "tmux no disponible" >&2; return 1; }

  lock_tomar "$reg" || { echo "no se pudo tomar el lock: $id" >&2; return 1; }
  if ! CORR_REG="$reg" CORR_SESION="$sesion" python3 -c '
import json, os, sys
d = json.load(open(os.environ["CORR_REG"]))
nombres = [s.get("nombre") for s in d.get("sesiones", []) if isinstance(s, dict)]
sys.exit(0 if os.environ["CORR_SESION"] in nombres else 1)
' 2>/dev/null; then
    lock_soltar "$reg"
    echo "sesion fuera del registro $id: $sesion" >&2
    return 1
  fi

  marca="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH 2>/dev/null || true)"
  if [ "$marca" = "OPENCLAW_WATCH=1" ]; then
    if ! "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH; then
      lock_soltar "$reg"
      echo "no se pudo retirar OPENCLAW_WATCH de $sesion" >&2
      return 1
    fi
  fi
  "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH_RUN 2>/dev/null || true
  lock_soltar "$reg"
  echo "terminada $sesion"
}

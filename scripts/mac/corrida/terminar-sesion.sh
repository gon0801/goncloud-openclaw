#!/bin/bash
# Retira la vigilancia de una sesion que pertenece a una corrida registrada.
# No mata tmux, no borra worktrees y repetir la operacion es seguro.
corrida_terminar_sesion() {
  [ "$#" -eq 2 ] || {
    echo "uso: corrida.sh terminar-sesion <id> <sesion>" >&2
    return 2
  }
  local id="$1" sesion="$2" reg
  corrida_id_valido "$id" || { echo "id invalido: $id" >&2; return 2; }
  corrida_id_valido "$sesion" || { echo "sesion invalida: $sesion" >&2; return 2; }
  reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "registro inexistente: $id" >&2; return 1; }
  [ -n "${TMUX_BIN:-}" ] || { echo "tmux no disponible" >&2; return 1; }

  marcas_lock_tomar || { echo "no se pudo tomar el lock global de marcas" >&2; return 1; }
  lock_tomar "$reg" \
    || { marcas_lock_soltar; echo "no se pudo tomar el lock: $id" >&2; return 1; }
  if ! CORR_REG="$reg" CORR_SESION="$sesion" python3 -c '
import json, os, sys
d = json.load(open(os.environ["CORR_REG"]))
nombres = [s.get("nombre") for s in d.get("sesiones", []) if isinstance(s, dict)]
sys.exit(0 if os.environ["CORR_SESION"] in nombres else 1)
' 2>/dev/null; then
    lock_soltar "$reg"
    marcas_lock_soltar
    echo "sesion fuera del registro $id: $sesion" >&2
    return 1
  fi

  if ! marca_retirar_si_dueno "$id" "$sesion"; then
    lock_soltar "$reg"
    marcas_lock_soltar
    echo "no se pudieron retirar las marcas propias de $sesion" >&2
    return 1
  fi
  lock_soltar "$reg"
  marcas_lock_soltar
  echo "terminada $sesion"
}

#!/bin/bash
# Retira la vigilancia de una sesion que pertenece a una corrida registrada.
# No mata tmux, no borra worktrees y repetir la operacion es seguro.
recurso_cerrar_gestionado() { # $1 hostId $2 encargo_ref $3 evidencia
  local host_id="$1" ref="$2" evidencia="$3" resource_bin result estado
  [ -n "${AGENT_WORK_HOST_STATE_DIR:-}" ] && [ -n "${AGENT_WORK_TMUX_SOCKET:-}" ] \
    && [ -f "${AGENT_WORK_RESOURCE_BIN:-}" ] && [ -f "$evidencia" ] \
    || { echo "recurso gestionado: faltan estado, socket, adaptador o evidencia" >&2; return 1; }
  resource_bin="$AGENT_WORK_RESOURCE_BIN"
  result="$(python3 "$resource_bin" close --host-id "$host_id" \
    --state-dir "$AGENT_WORK_HOST_STATE_DIR" --assignment "$ref" \
    --evidence "$evidencia" --tmux-socket "$AGENT_WORK_TMUX_SOCKET" --tmux-bin "$TMUX_BIN")" \
    || { echo "recurso gestionado: cierre no confirmado" >&2; return 1; }
  estado="$(RESOURCE_RESULT="$result" python3 -c '
import json,os
print(json.loads(os.environ["RESOURCE_RESULT"])["state"])
' 2>/dev/null)" || return 1
  case "$estado" in
    AbsenceVerified|ReleasedAdopted) return 0;;
    *) echo "recurso gestionado: cierre pendiente ($estado)" >&2; return 1;;
  esac
}

corrida_terminar_sesion() {
  { [ "$#" -eq 2 ] || { [ "$#" -eq 4 ] && [ "$3" = "--evidence" ]; }; } || {
    echo "uso: corrida.sh terminar-sesion <id> <sesion> [--evidence <archivo>]" >&2
    return 2
  }
  local id="$1" sesion="$2" evidencia="${4:-}" reg
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

  local recurso host_id encargo_ref
  recurso="$(CORR_REG="$reg" CORR_SESION="$sesion" python3 -c '
import json,os,sys
d=json.load(open(os.environ["CORR_REG"]))
matches=[x for x in d["sesiones"] if x.get("nombre")==os.environ["CORR_SESION"]]
if len(matches)!=1:
  sys.exit("session identity is not unique")
s=matches[0]
managed=bool(s.get("host_id") or s.get("encargo_ref") or any(
  lane.get("session")==os.environ["CORR_SESION"] and lane.get("resource_receipt_ref")
  for lane in d.get("lanes",[]) if isinstance(lane,dict)))
if managed:
  if not s.get("host_id") or not s.get("encargo_ref"):
    sys.exit("managed resource binding incomplete")
  print(s["host_id"]+"\t"+s["encargo_ref"])
')" || { lock_soltar "$reg"; marcas_lock_soltar; return 1; }
  if [ -n "$recurso" ]; then
    host_id="${recurso%%$'\t'*}"
    encargo_ref="${recurso#*$'\t'}"
    if [ -z "$host_id" ] || [ -z "$evidencia" ] \
      || ! recurso_cerrar_gestionado "$host_id" "$encargo_ref" "$evidencia"; then
      lock_soltar "$reg"
      marcas_lock_soltar
      echo "terminar-sesion: recurso de $sesion sigue pendiente; marcas conservadas" >&2
      return 1
    fi
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

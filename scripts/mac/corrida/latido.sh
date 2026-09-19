#!/bin/bash
# corrida/latido.sh (9.5). latido: el seguimiento garantizado, sin modelo.
# Lo corre el LaunchAgent ai.goncloud.corrida-latido cada 5 min. Por cada
# corrida abierta calcula el parte (9.4), manda el mensaje a David cuando
# cambio el estado (o a la hora sin mensaje, o NECESITO cuando un dialogo
# lleva 10 min o la politica no lo cubre), y despierta al vigia con el parte y
# la accion que toca segun loop 12: system event para claw, linea en
# eventos.jsonl para hermes (9.0). Todo evento que produce queda en
# <dir>/eventos.jsonl. Tope: un mensaje cada 15 min salvo NECESITO. El cron
# hombre-muerto que abre creo en el gateway sigue hablando si este muere.
# Inyectables: CORR_AHORA (reloj), OPENCLAW_BIN, y los de estado.sh.
. "$(dirname "${BASH_SOURCE[0]}")/estado.sh"

LAT_TOPE_MSG=900    # 15 min entre mensajes, salvo NECESITO
LAT_HORA_MSJ=3600   # sin mensaje aunque todo avance: a la hora, uno

evento_jsonl() { # $1 dir de la corrida; pares EVT_<campo>=valor en el entorno
  EVT_DIR="$1" EVT_AT="$(epoch_a_iso "$(corr_ahora)")" python3 -c "
import json,os
p={k[4:]:v for k,v in os.environ.items() if k.startswith('EVT_')}
p['at']=os.environ['EVT_AT']
open(os.path.join(os.environ['EVT_DIR'],'eventos.jsonl'),'a').write(json.dumps(p)+chr(10))" 2>/dev/null
  return 0
}

lat_escribir() { # $1 latido.json $2 firma $3 ult_msj $4 etq $5 firma_vigia $6 ci_sha
  LATF="$1" L_FIRMA="$2" L_ULT="$3" L_ETQ="$4" L_FV="$5" L_CI="${6:-}" python3 -c "
import json,os
E=os.environ
d={'firma':E['L_FIRMA'],'ult_msj':int(E['L_ULT']),'etq':E['L_ETQ'],
   'firma_vigia':E['L_FV'],'ci_sha':E['L_CI']}
t=E['LATF']+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,E['LATF'])" 2>/dev/null
}

latido_de() { # $1 dir de la corrida (con el registro adentro)
  local dir="$1" id reg now lat
  id="$(basename "$dir")"
  reg="$dir/registro.json"
  parte_calcular "$id" || return 0
  now="$(corr_ahora)"
  lat="$dir/latido.json"
  local lfirma="" lult=0 letq="" lfv="" lci=""
  if [ -f "$lat" ]; then
    lfirma="$(json_campo "$lat" firma)"
    lult="$(json_campo "$lat" ult_msj)"; [ -n "$lult" ] && [ "$lult" != "None" ] || lult=0
    letq="$(json_campo "$lat" etq)"
    lfv="$(json_campo "$lat" firma_vigia)"
    lci="$(json_campo "$lat" ci_sha)"
  fi
  local parte4
  parte4="[$P_ETIQ] Corrida, $P_AVANCE / Que cambio: $P_CAMBIO / Que sigue: $P_SIGUE / Que necesito de ti: $P_NECESITO"

  # (1) el mensaje a David: cambio de estado, hora sin mensaje, o NECESITO.
  # NECESITO no espera al tope cuando es nueva (la firma cambio) o lleva 15 min
  # sin nadie contestarla; pero la misma espera parada no se remanda cada tick.
  local enviar=0
  if [ "$P_ETIQ" = "NECESITO TU RESPUESTA" ]; then
    if [ "$P_FIRMA" != "$lfirma" ] || [ "$lult" -eq 0 ] || [ $(( now - lult )) -ge "$LAT_TOPE_MSG" ]; then
      enviar=1
    fi
  elif [ "$P_FIRMA" != "$lfirma" ]; then
    if [ "$lult" -eq 0 ] || [ $(( now - lult )) -ge "$LAT_TOPE_MSG" ]; then enviar=1; fi
  elif [ "$lult" -gt 0 ] && [ $(( now - lult )) -ge "$LAT_HORA_MSJ" ]; then
    enviar=1
  fi
  if [ "$enviar" -eq 1 ]; then
    if corrida_mensaje "$id" "$P_ETIQ" "$P_AVANCE" "$P_CAMBIO" "$P_SIGUE" "$P_NECESITO"; then
      lfirma="$P_FIRMA"; lult="$now"; letq="$P_ETIQ"
      lat_escribir "$lat" "$lfirma" "$lult" "$letq" "$lfv" "$lci"
      EVT_tipo=mensaje EVT_etiqueta="$P_ETIQ" EVT_firma="$P_FIRMA" evento_jsonl "$dir"
    else
      # sin memoria nueva: el proximo tick reintenta con el mismo cambio.
      EVT_tipo=mensaje EVT_etiqueta="$P_ETIQ" EVT_ok=false evento_jsonl "$dir"
    fi
  fi

  # (2) el vigia: con el parte y la accion que toca (loop 12). claw se despierta
  # con system event; hermes lee la linea de eventos.jsonl por ssh (9.0). Solo
  # cuando hay acciones: un parte sin nada pendiente no gasta un turno del vigia.
  if [ -n "$P_ACCIONES" ] && [ "$P_FIRMA" != "$lfv" ]; then
    local vigia rc=0 acc_claves
    vigia="$(json_campo "$reg" vigia)"
    acc_claves="$(printf '%s\n' "$P_ACCIONES" | cut -d'|' -f1 | paste -sd, -)"
    if [ "$vigia" = "claw" ]; then
      con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" system event --mode now --timeout 15000 \
        --text "corrida $id | accion: ${P_ACCIONES//$LF/ ; } | parte: $parte4 | estado: $dir" \
        >/dev/null 2>&1 || rc=1
    fi
    EVT_tipo=evento-vigia EVT_vigia="$vigia" EVT_accion="$acc_claves" \
      EVT_ok="$([ "$rc" -eq 0 ] && echo true || echo false)" \
      EVT_corrida="$id" EVT_parte="$parte4" evento_jsonl "$dir"
    if [ "$rc" -eq 0 ]; then
      lfv="$P_FIRMA"
      lat_escribir "$lat" "$lfirma" "$lult" "$letq" "$lfv" "$lci"
    fi
  fi
  return 0
}

corrida_latido() {
  [ -d "$CORRIDA_STATE" ] || return 0
  local dir reg
  for dir in "$CORRIDA_STATE"/*/; do
    [ -d "$dir" ] || continue
    reg="${dir%/}/registro.json"
    [ -f "$reg" ] || continue
    validar_registro "$reg" >/dev/null 2>&1 || continue
    [ "$(json_campo "$reg" estado)" = "abierta" ] || continue
    latido_de "${dir%/}"
  done
  return 0
}

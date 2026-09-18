#!/bin/bash
# corrida/cerrar.sh (9.2). cerrar <id>: desmarca, quita el cron, manda CERRADA.
corrida_cerrar() {
  local id="$1"
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local s
  for s in $(python3 -c "
import json
print(' '.join(x.get('nombre','') for x in json.load(open('$reg')).get('sesiones',[])))"); do
    "$TMUX_BIN" set-environment -t "$s" -u OPENCLAW_WATCH 2>/dev/null
  done
  "$OPENCLAW_BIN" cron rm "corrida-vigia-$id" >/dev/null 2>&1
  corrida_mensaje "$id" "CERRADA" "la corrida termino" "no queda nada en curso" "nada" || return 1
  python3 -c "
import json
d=json.load(open('$reg')); d['estado']='cerrada'
open('$reg','w').write(json.dumps(d,indent=1)+chr(10))"
  echo "cerrada $id"
}

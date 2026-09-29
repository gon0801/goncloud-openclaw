#!/bin/bash
# corrida/seleccionar.sh (B21). seleccionar <id> <carril> --request F --state F:
# corre el selector sobre el registro de workers y guarda en el carril la
# decision entera: ganador, modelo, effort, puntaje por parte, candidatos y
# descartados con sus razones, la salud medida y el pedido. El porque queda
# en el registro, en el tablero y en archive/<carril>/selection.json, no solo
# en la pantalla del director. Cada seleccion se agrega a `selections`
# (la del relevo no borra la primera) y `selection` es la vigente.
# stdout: el JSON del selector. rc 1 sin ganador (la decision igual queda).
# Uso: corrida.sh seleccionar <id> <carril> --request FILE --state FILE
corrida_seleccionar() {
  [ "$#" -ge 2 ] || { echo "uso: corrida.sh seleccionar <id> <carril> --request FILE --state FILE" >&2; return 2; }
  local id="$1" carril="$2" req="" st=""
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --request) [ $# -ge 2 ] || { echo "seleccionar: --request sin valor" >&2; return 2; }; req="$2"; shift 2;;
      --state) [ $# -ge 2 ] || { echo "seleccionar: --state sin valor" >&2; return 2; }; st="$2"; shift 2;;
      *) echo "seleccionar: flag desconocido $1" >&2; return 2;;
    esac
  done
  [ -n "$req" ] && [ -n "$st" ] || { echo "uso: corrida.sh seleccionar <id> <carril> --request FILE --state FILE" >&2; return 2; }
  corrida_id_valido "$id" || { echo "seleccionar: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "seleccionar: carril invalido: $carril" >&2; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  [ "$(json_campo "$reg" estado)" = "abierta" ] \
    || { echo "seleccionar: la corrida $id no esta abierta" >&2; return 1; }
  local out
  out="$(python3 "$AQUI/corrida-worker.py" select --registry "$(corrida_workers_registry)" \
    --request "$req" --state "$st")" || { printf 'seleccionar: %s\n' "$out" >&2; return 1; }
  lock_tomar "$reg" || { echo "seleccionar: lock del registro de $id no cede" >&2; return 1; }
  local rrc=0
  CORR_C="$carril" CORR_SEL="$out" CORR_REQ="$req" CORR_ST="$st" \
  CORR_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" registro_escribir "$reg" "
import sys
c=next((e for e in d.get('lanes') or [] if isinstance(e,dict) and e.get('id')==os.environ['CORR_C']),None)
if c is None: sys.exit(10)
sel=json.loads(os.environ['CORR_SEL'])
salud=(json.load(open(os.environ['CORR_ST'])).get('health') or {}).get(sel.get('winner'))
if isinstance(salud,dict): salud=salud.get('status')
sel['health']=salud if salud in ('available','limited','unauthenticated','broken') else None
sel['request']=json.load(open(os.environ['CORR_REQ']))
sel['at']=os.environ['CORR_AT']
c.setdefault('selections',[]).append(sel)
c['selection']=sel
" 2>/dev/null || rrc=$?
  lock_soltar "$reg"
  [ "$rrc" -ne 10 ] || { echo "seleccionar: el carril $carril no existe en $id (prepararlo antes)" >&2; return 1; }
  [ "$rrc" -eq 0 ] || { echo "seleccionar: no se pudo guardar la seleccion" >&2; return 1; }
  printf '%s\n' "$out"
  printf '%s' "$out" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('winner') else 1)"
}

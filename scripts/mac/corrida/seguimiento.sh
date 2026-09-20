#!/bin/bash
# corrida/seguimiento.sh. corrida.sh seguimiento --json: inventario de solo
# lectura de las corridas abiertas para el reloj global (avance-tareas).
# No escribe archivos, no toca disco salvo leer, no llama a la red: el
# director lo reconcilia con runbook.progress.list por trabajoId estable
# (corrida:<id>). Un registro malformado o que no pasa el validador no
# desaparece: su ruta sale en errores. Del acumulado
# (eventos-seguimiento.jsonl) se lee el ultimo evento VALIDO; si la ultima
# linea esta malformada se reporta su ruta en errores y se retrocede al
# valido anterior (sin ninguno, actividad null).
corrida_seguimiento() {
  [ "${1:-}" = "--json" ] || { echo "uso: corrida.sh seguimiento --json" >&2; return 2; }
  local base="${CORRIDA_STATE:-$HOME/.local/state/corridas}"
  local lista errores d reg
  lista="$(mktemp)" || return 1
  errores="$(mktemp)" || { rm -f "$lista"; return 1; }
  : >"$lista"; : >"$errores"
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    reg="${d}registro.json"
    [ -f "$reg" ] || continue
    if ! validar_registro "$reg" >/dev/null 2>&1; then
      printf '%s\n' "$reg" >>"$errores"
      continue
    fi
    if [ "$(json_campo "$reg" estado)" = "cerrada" ]; then
      continue
    fi
    printf '%s\n' "$reg" >>"$lista"
  done
  SEGM_LISTA="$lista" SEGM_ERRORES="$errores" python3 - <<'PY' 2>/dev/null || { rm -f "$lista" "$errores"; echo "seguimiento: no se pudo inventariar" >&2; return 1; }
import json,os
def lineas_validas(ruta):
  try:
    with open(ruta) as f:
      return [l for l in f.read().split('\n') if l.strip()]
  except Exception:
    return []
with open(os.environ['SEGM_LISTA']) as f:
  regs=[l.rstrip('\n') for l in f if l.strip()]
with open(os.environ['SEGM_ERRORES']) as f:
  errores=[l.rstrip('\n') for l in f if l.strip()]
def es_evento(c):
  return (isinstance(c,dict) and isinstance(c.get('at'),str)
    and isinstance(c.get('cambio'),str) and isinstance(c.get('sigue'),str)
    and isinstance(c.get('necesito'),str))
corridas=[]
for reg in sorted(regs):
  try:
    with open(reg) as f:
      d=json.load(f)
  except Exception:
    errores.append(reg)
    continue
  if not isinstance(d,dict):
    errores.append(reg)
    continue
  rid=d.get('id')
  if not isinstance(rid,str) or not rid:
    errores.append(reg)
    continue
  evf=os.path.join(os.path.dirname(reg),'eventos-seguimiento.jsonl')
  actividad=None
  if os.path.isfile(evf):
    lineas=lineas_validas(evf)
    for i in range(len(lineas)-1,-1,-1):
      try:
        cand=json.loads(lineas[i])
      except Exception:
        continue
      if es_evento(cand):
        actividad=cand
        break
    if lineas:
      try:
        ultima_ok=es_evento(json.loads(lineas[-1]))
      except Exception:
        ultima_ok=False
      if not ultima_ok or actividad is None:
        errores.append(evf)
  corridas.append({'trabajoId':'corrida:'+rid,'id':rid,
    'inicio':d.get('inicio') if isinstance(d.get('inicio'),str) else None,
    'estado':d.get('estado') if isinstance(d.get('estado'),str) else None,
    'runbook':d.get('runbook') if isinstance(d.get('runbook'),str) else None,
    'actividad':actividad})
print(json.dumps({'schema':'corrida-seguimiento.v1','corridas':corridas,'errores':sorted(errores)}))
PY
  rm -f "$lista" "$errores"
}

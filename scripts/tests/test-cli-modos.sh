#!/bin/bash
# 9.1 Contratos: validadores de corrida.v1 / seguimiento.v1 y cobertura de cli-modos.tsv.
# El validador de mensajes es el de scripts/mac/corrida/lib.sh (9.2 lo reusa en vivo):
# se prueba el de produccion, no una copia que pueda derivar. validar_registro es la
# referencia 9.1 del contrato del registro.
# Uso: bash scripts/tests/test-cli-modos.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

FX=scripts/tests/fixtures/corrida
TSV=scripts/mac/cli-modos.tsv
ZSH=scripts/mac/agent-tmux-shell.zsh
. scripts/mac/corrida/lib.sh

# --- validador del registro (referencia 9.1) ---
validar_registro() { # $1: json del registro; 0 = valido
  local j="$1" v
  v=$(python3 - "$j" <<'PY'
import sys,json
try:
  d=json.load(open(sys.argv[1]))
  assert isinstance(d,dict)
except Exception:
  print('ROTO:no es json'); raise SystemExit
e=[]
def malo(m):
  if m not in e: e.append(m)
if d.get('vigia') not in ('claw','hermes'): malo('vigia fuera del conjunto')
if d.get('schema')!='corrida.v1': malo('schema distinto')
for c in ('id','runbook'):
  if not d.get(c): malo('sin '+c)
if not (isinstance(d.get('canal'),dict) and d['canal'].get('cron')): malo('sin canal.cron')
if d.get('estado') not in ('abierta','cerrada'): malo('estado fuera del conjunto')
tb=d.get('timebox_horas')
if isinstance(tb,bool) or not isinstance(tb,int): malo('timebox no numerico')
ss=d.get('sesiones')
if not isinstance(ss,list) or not ss: malo('sin sesiones')
else:
  for s in ss:
    for c in ('nombre','rol','cli','dueno','dir'):
      if not (isinstance(s,dict) and s.get(c)): malo('sesion sin '+c); break
    if isinstance(s,dict) and s.get('rol') not in (None,'lead','carril'):
      malo('rol fuera del conjunto')
# Lista dura (regla 3 de 00-project-spec): ninguna tabla la aprueba.
DURA=('borrado recursivo','drop','push a la rama','merge','credencial')
for p in d.get('preaprobaciones') or []:
  if not isinstance(p,dict): malo('preaprobacion sin forma'); continue
  if p.get('decision') not in ('Aprobado','Negado'): malo('decision fuera del conjunto')
  pat=str(p.get('patron','')).lower()
  if p.get('decision')=='Aprobado' and any(k in pat for k in DURA):
    malo('lista dura aprobada: '+pat)
for m in e: print('ROTO:'+m)
PY
) || fail "el registro no es json: $1"
  [ -z "$v" ]
}

# --- casos ---
[ -f "$TSV" ] || fail "falta $TSV"
validar_registro "$FX/registro-valido.json" || fail "el registro valido no pasa"
for r in vigia-malo sesion-sin-rol schema-malo sin-canal estado-malo timebox-malo sesion-sin-dir decision-mala lista-dura; do
  validar_registro "$FX/registro-$r.json" 2>/dev/null && fail "registro mutante pasa: $r"
done

# mensaje_valido viene de lib.sh: es el que corre en cada envio de verdad.
mensaje_valido "$FX/mensaje-valido.txt" || fail "el mensaje valido no pasa"
mensaje_valido "$FX/mensaje-etiqueta-mala.txt" 2>/dev/null && fail "etiqueta desconocida pasa"
mensaje_valido "$FX/mensaje-forma-mala.txt" 2>/dev/null && fail "forma sin prefijos pasa"
for j in palabra ruta flag sha tilde commits mergeado prs; do
  mensaje_valido "$FX/mensaje-jerga-$j.txt" 2>/dev/null && fail "jerga ($j) pasa"
done
# Falsos positivos declarados residuales: sin digito o sin letra no es sha.
mensaje_valido "$FX/mensaje-pasa-acabada.txt" || fail "acabada (solo letras) dio jerga"
mensaje_valido "$FX/mensaje-pasa-numeros.txt" || fail "1234567 (solo digitos) dio jerga"
# El marcador "Comando: ": uno y solo en NECESITO TU RESPUESTA.
mensaje_valido "$FX/mensaje-comando-valido.txt" || fail "el comando textual en NECESITO no pasa"
mensaje_valido "$FX/mensaje-comando-sin-necesito.txt" 2>/dev/null && fail "Comando fuera de NECESITO pasa"
mensaje_valido "$FX/mensaje-comando-doble.txt" 2>/dev/null && fail "dos Comando pasan"

# Cobertura: cada CLI de AGENT_TMUX_TOOLS tiene fila en cli-modos.tsv.
clis=$(grep -E '^AGENT_TMUX_TOOLS=\(' "$ZSH" | sed 's/.*(\(.*\)).*/\1/')
[ -n "$clis" ] || fail "no se pudo leer AGENT_TMUX_TOOLS de $ZSH"
for c in $clis; do
  grep -qE "^${c}	" "$TSV" || fail "$TSV: sin fila para $c"
done

echo "TODO VERDE: test-cli-modos"

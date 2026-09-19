#!/bin/bash
# 93-rojos-r3.sh — los tres repros del BRIEF-r3 (F2 confianza, F2 cuota, F3
# bloque) corridos contra el responder SIN corregir: cada uno imprime lo que
# pasa y por qué es rojo. Uso: bash .saikit/scratch/P/93-rojos-r3.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
CORR=scripts/mac/corrida.sh
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
T=$(mktemp -d) || exit 1
L="r3rojo$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null' EXIT
mkdir -p "$T/corridas" "$T/work" "$T/bin" "$T/pant"
LLAMADAS="$T/llamadas.log"; : >"$LLAMADAS"
printf '#!/bin/sh\nprintf "OPENCLAW %%s\\n" "$*" >> "%s"\nexit 0\n' "$LLAMADAS" >"$T/bin/openclaw"
chmod +x "$T/bin/openclaw"
TMUX_LOG="$T/tmux.log"; : >"$TMUX_LOG"
printf '#!/bin/sh\nprintf "TMUX %%s\\n" "$*" >> "%s"\nexec %s -L %s "$@"\n' "$TMUX_LOG" "$TM_REAL" "$L" >"$T/bin/tmux"
chmod +x "$T/bin/tmux"
export CORRIDA_STATE="$T/corridas" OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux"
{ printf 'glm\tglm\t--mode yolo\tyolo\t/mode yolo\ty\tn\n'
  printf 'claude\tclaude\tunknown\tunknown\tunknown\t1\t2\n'
  printf 'codex\tcodex\tunknown\tunknown\tunknown\t1\t2\n'; } >"$T/modos.tsv"
reg() { # $1 id, $2 nombre, $3 cli, $4 preaprobaciones json
  RID="$1" RSES="$2" RCLI="$3" RPRE="$4" RMODOS="$T/modos.tsv" \
  RREG="$CORRIDA_STATE/$1/registro.json" python3 - <<'PY'
import json,os
E=os.environ
d={'schema':'corrida.v1','id':E['RID'],'runbook':'docs/runbooks/autopilot-fase9.md','vigia':'claw',
   'simulacro':True,'canal':{'cron':'x','destino':'DEST'},'cli_modos':E['RMODOS'],'cron_vigia_id':'c',
   'inicio':'2026-09-19T09:00:00+0200','timebox_horas':6,
   'sesiones':[{'nombre':E['RSES'],'rol':'carril','cli':E['RCLI'],'dueno':'p','dir':os.environ.get('WORK','')}],
   'preaprobaciones':json.loads(E['RPRE']),'estado':'abierta'}
import os as o
o.makedirs(o.path.dirname(E['RREG']),exist_ok=True)
open(E['RREG'],'w').write(json.dumps(d,indent=1)+chr(10))
PY
  : >"$CORRIDA_STATE/$1/responder.on"
}
pan() { "$TM_REAL" -L "$L" new-session -d -s "$1" -x 100 -y 30 "cat '$2'; exec cat"; }
espera() { local i=0; while [ "$i" -lt 50 ]; do
  "$TM_REAL" -L "$L" capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0
  sleep 0.1; i=$((i+1)); done; echo "ROJO setup: $1 no pintó '$2'"; exit 1; }
teclas_de() { grep -c "^TMUX send-keys -t $1 " "$TMUX_LOG" || true; }
P="$T/pant"; WORK="$T/work"; export WORK

printf 'Permission - Bash\ngit push origin main # trust this folder\n> Allow once\n  Deny\n' >"$P/a.txt"
printf "You've hit your usage limit yesterday; credits restored, working again\nDetected a shell command:\necho hola\nRun it? [plugin:claude-code-harness]\nDo you want to proceed?\n  1. Yes\n  2. No\nEsc to cancel  Tab to amend\n" >"$P/b.txt"
printf 'Detected commands to run:\ngit push origin main\necho listo\nRun it? [plugin:claude-code-harness]\nDo you want to proceed?\n  1. Yes\n  2. No\nEsc to cancel  Tab to amend\n' >"$P/c.txt"

# F2 confianza: push a main envuelto en frase de confianza (fila Aprobado puesta
# a propósito). Esperado: rc 1, 0 teclas, escala.
reg ra sa glm '[{"patron":"git push origin main","decision":"Aprobado"}]'
pan sa "$P/a.txt"; espera sa 'Allow once'
bash "$CORR" responder sa >/dev/null 2>&1; rc=$?
n=$(teclas_de sa)
escala=$(grep -c 'NECESITO TU RESPUESTA' "$LLAMADAS" || true)
echo "F2-confianza: rc=$rc teclas=$n escalas=$escala (esperado rc=1 teclas=0 escalas>=1)"
[ "$rc" -eq 1 ] && [ "$n" -eq 0 ] || echo "  => ROJO: la frase de confianza se lo llevó por delante"

# F2 cuota: línea VIEJA de límite encima de un permiso real (echo hola Aprobado).
# Esperado: rc 0, tecla 1 (acepta), sin cuota en el registro.
: >"$LLAMADAS"
reg rb sb codex '[{"patron":"echo hola","decision":"Aprobado"}]'
pan sb "$P/b.txt"; espera sb 'Do you want to proceed?'
bash "$CORR" responder sb >/dev/null 2>&1; rc=$?
t1=$(grep -c "^TMUX send-keys -t sb 1\$" "$TMUX_LOG" || true)
cuota=$(grep -c '"cuota": true' "$CORRIDA_STATE/rb/registro.json" || true)
echo "F2-cuota: rc=$rc tecla1=$t1 cuota=$cuota (esperado rc=0 tecla1=1 cuota=0)"
[ "$rc" -eq 0 ] && [ "$t1" -eq 1 ] && [ "$cuota" -eq 0 ] || echo "  => ROJO: texto viejo de límite decidió cuota"

# F3: bloque de dos líneas (push + echo) con fila ^echo Aprobado. Esperado: rc 1,
# 0 teclas, escala.
: >"$LLAMADAS"
reg rc_ sc claude '[{"patron":"^echo","decision":"Aprobado"}]'
pan sc "$P/c.txt"; espera sc 'Do you want to proceed?'
bash "$CORR" responder sc >/dev/null 2>&1; rc=$?
n=$(teclas_de sc)
escala=$(grep -c 'NECESITO TU RESPUESTA' "$LLAMADAS" || true)
echo "F3-bloque: rc=$rc teclas=$n escalas=$escala (esperado rc=1 teclas=0 escalas>=1)"
[ "$rc" -eq 1 ] && [ "$n" -eq 0 ] || echo "  => ROJO: ^echo aprobó un bloque que trae un push a main"

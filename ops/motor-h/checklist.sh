#!/usr/bin/env bash
# H.5: sale 0 solo si claw responde, tiene la skill `motor`, no quedan crons
# *-vigia en el gateway y en esta Mac no existe ~/.claude/skills/prompt-claw.
# Si ssh a la Mini falla (o la respuesta no trae las tres claves), sale != 0:
# sin dato no hay verde.
#
# Uso: bash ops/motor-h/checklist.sh
# Pruebas: MOTOR_H_SSH y MOTOR_H_MINI permiten apuntar a un ssh falso.
set -u

SSH=${MOTOR_H_SSH:-ssh}
MINI=${MOTOR_H_MINI:-gon@100.73.187.5}
fails=0
no() { echo "ROJO: $1"; fails=$((fails+1)); }

remoto=$("$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$MINI" 'bash -s' <<'EOS'
OC=/Users/gon/.openclaw/bin/openclaw
h=$("$OC" health --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d.get("ok") else 0)' 2>/dev/null || echo 0)
s=0
[ -f /Users/gon/.openclaw/agents/main/agent/workshop-skills/motor/SKILL.md ] && s=1
v=$("$OC" cron list --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); jobs=d.get("jobs", d if isinstance(d,list) else []); print(sum(1 for j in jobs if str(j.get("name","")).endswith("-vigia")))' 2>/dev/null || echo -1)
echo "HEALTH_OK=$h"
echo "MOTOR_SKILL=$s"
echo "VIGIA_CRONS=$v"
EOS
)
if [ $? -ne 0 ]; then
  echo "ROJO: ssh a la Mini falló ($MINI)"
  exit 1
fi

valor() { printf '%s\n' "$remoto" | sed -n "s/^$1=//p" | head -1; }
health=$(valor HEALTH_OK)
skill=$(valor MOTOR_SKILL)
vigia=$(valor VIGIA_CRONS)

for par in "HEALTH_OK=$health" "MOTOR_SKILL=$skill" "VIGIA_CRONS=$vigia"; do
  case $par in *=) echo "ROJO: la Mini no devolvió $par (¿ssh falso o gateway caído?)"; exit 1;; esac
done

[ "$health" = "1" ] || no "claw no responde (openclaw health != ok)"
[ "$skill" = "1" ] || no "claw no tiene la skill motor (agents/main/agent/workshop-skills/motor/SKILL.md)"
[ "$vigia" = "0" ] || no "quedan crons *-vigia en el gateway o no se pudo listar (VIGIA_CRONS=$vigia)"
[ ! -e "$HOME/.claude/skills/prompt-claw" ] || no "sigue ~/.claude/skills/prompt-claw en la Mac"

if [ "$fails" -gt 0 ]; then
  echo "ROJO: $fails fallo(s) en el checklist del bloque H"
  exit 1
fi
echo "VERDE: claw responde, tiene la skill motor, no quedan crons *-vigia ni prompt-claw"

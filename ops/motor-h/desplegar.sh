#!/usr/bin/env bash
# H.5 — despliegue del bloque H: OpenClaw usa el motor y se retiran los loops.
# Corre en la Mac (donde vive este repo). Idempotente: cada paso se puede
# repetir sin duplicar ni corromper. Pasos:
#   1. actualiza el checkout de goncloud-openclaw en la Mini (main, ff-only)
#   2. publica la skill motor en los agentes del gateway que la traen en el checkout
#   3. quita de openclaw.json las herramientas de escritura (write, edit) de
#      implementer e ingenieria (respaldo previo)
#   4. borra los crons *-vigia del gateway
#   5. reinicia el gateway (openclaw gateway restart) y espera el health ok
#   6. en la Mac: mueve ~/.claude/skills/prompt-claw a ~/.claude/skills-retiradas/
# Cierra corriendo ops/motor-h/checklist.sh: si algo no quedó, sale != 0.
#
# Uso: bash ops/motor-h/desplegar.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

SSH=${MOTOR_H_SSH:-ssh}
MINI=${MOTOR_H_MINI:-gon@100.73.187.5}
CHECKOUT=${MOTOR_H_CHECKOUT:-/Users/gon/dev/goncloud-openclaw}

paro() { echo "PARO: $1" >&2; exit 1; }

echo "== 1-5. Mini ($MINI): checkout, skill motor, openclaw.json, crons *-vigia, reinicio"
"$SSH" -o BatchMode=yes -o ConnectTimeout=10 "$MINI" "CHECKOUT='$CHECKOUT' bash -s" <<'EOS' || paro "falló el paso remoto (ver salida)"
set -uo pipefail
OC=/Users/gon/.openclaw/bin/openclaw
AGENTS=/Users/gon/.openclaw/agents
TS=$(date +%Y%m%d-%H%M)
paro() { echo "PARO(Mini): $1" >&2; exit 1; }

# -- 1. checkout al día (main, fast-forward; sucio o divergido = PARO)
rama=$(git -C "$CHECKOUT" branch --show-current) || paro "no se pudo leer la rama del checkout"
[ "$rama" = "main" ] || paro "el checkout está en '$rama', no en main"
[ -z "$(git -C "$CHECKOUT" status --short)" ] || paro "checkout sucio; reconcilia a mano"
git -C "$CHECKOUT" fetch origin || paro "git fetch falló"
git -C "$CHECKOUT" merge --ff-only origin/main || paro "main no avanza fast-forward"
echo "-- checkout en $(git -C "$CHECKOUT" log -1 --format='%h %s')"

# -- 2. skill motor: del checkout al agentDir de cada agente que la trae
for a in main implementer ingenieria; do
  src="$CHECKOUT/agents/$a/agent/workshop-skills/motor"
  [ -f "$src/SKILL.md" ] || continue
  mkdir -p "$AGENTS/$a/agent/workshop-skills/motor" || paro "no se pudo crear motor/ en $a"
  cp "$src/SKILL.md" "$AGENTS/$a/agent/workshop-skills/motor/SKILL.md" || paro "no se pudo copiar la skill a $a"
  echo "-- skill motor publicada en $a"
done

# -- 3. openclaw.json: fuera write/edit de implementer e ingenieria
CONF=/Users/gon/.openclaw/openclaw.json
F=/Users/gon/.openclaw/respaldos/pre-motor-h-$TS
mkdir -p "$F" || paro "no se pudo crear $F"
cp "$CONF" "$F/openclaw.json" || paro "no se pudo respaldar openclaw.json"
echo "-- respaldo en $F/openclaw.json"
"$OC" config patch --stdin <<'JSON' || paro "config patch falló"
{"agents":{"entries":{"implementer":{"tools":{"deny":["write","edit"]}},"ingenieria":{"tools":{"deny":["write","edit"]}}}}}
JSON
python3 - "$CONF" <<'PY' || paro "el deny de write/edit no quedó persistido"
import json, sys
d = json.load(open(sys.argv[1]))
for a in ("implementer", "ingenieria"):
    deny = (d["agents"]["entries"].get(a, {}).get("tools", {}) or {}).get("deny", [])
    assert "write" in deny and "edit" in deny, (a, deny)
print("-- write/edit denegadas en implementer e ingenieria")
PY

# -- 4. crons *-vigia: borrar y verificar
ids=$("$OC" cron list --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
jobs = d.get("jobs", d if isinstance(d, list) else [])
print(" ".join(j["id"] for j in jobs if str(j.get("name", "")).endswith("-vigia")))')
for id in $ids; do
  "$OC" cron rm "$id" >/dev/null 2>&1 || paro "no se pudo borrar el cron $id"
  echo "-- cron *-vigia borrado: $id"
done
quedan=$("$OC" cron list --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
jobs = d.get("jobs", d if isinstance(d, list) else [])
print(sum(1 for j in jobs if str(j.get("name", "")).endswith("-vigia")))')
[ "$quedan" = "0" ] || paro "quedan $quedan crons *-vigia"
echo "-- crons *-vigia: 0"

# -- 5. reinicio del gateway (launchd) y espera del health
echo "-- reinicio del gateway; crons corriendo ahora:"
"$OC" cron list --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
jobs = d.get("jobs", d if isinstance(d, list) else [])
for j in jobs:
    st = j.get("state", {})
    if st.get("runningAtMs"):
        print("   corriendo:", j.get("name"))' || true
# Reinicio soportado (enable + kickstart). bootout/bootstrap a mano dejó el gateway
# descargado: por ssh `launchctl list` no ve el servicio y bootstrap falla.
"$OC" gateway restart || paro "openclaw gateway restart falló"
n=0
while [ $n -lt 20 ]; do
  ok=$("$OC" health --json 2>/dev/null | python3 -c 'import json,sys; print(1 if json.load(sys.stdin).get("ok") else 0)' 2>/dev/null || echo 0)
  [ "$ok" = "1" ] && break
  sleep 3; n=$((n+1))
done
[ "$ok" = "1" ] || paro "el gateway no volvió a responder health ok tras el reinicio"
echo "-- gateway de vuelta (health ok)"
EOS

echo "== 6. Mac: retirar prompt-claw"
if [ -e "$HOME/.claude/skills/prompt-claw" ]; then
  mkdir -p "$HOME/.claude/skills-retiradas" || paro "no se pudo crear ~/.claude/skills-retiradas"
  [ ! -e "$HOME/.claude/skills-retiradas/prompt-claw" ] \
    || paro "ya existe ~/.claude/skills-retiradas/prompt-claw; resuelve a mano"
  mv "$HOME/.claude/skills/prompt-claw" "$HOME/.claude/skills-retiradas/" \
    || paro "no se pudo mover prompt-claw"
  echo "-- prompt-claw movido a ~/.claude/skills-retiradas/"
else
  echo "-- prompt-claw ya no está (nada que hacer)"
fi

echo "== checklist"
bash ops/motor-h/checklist.sh

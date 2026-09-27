#!/bin/bash
# Task 7 Step 3: la allowlist dura queda intacta y cerrada.
# La lista de roles con autoridad de merge es EXACTAMENTE implementer e
# ingenieria: main jamas, y cualquier entrada extra rompe esta prueba.
# Uso: bash scripts/tests/test-merge-allowlist-cierre-pr.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
GATE=scripts/mac/corrida/autoridad-merge.sh
[ -f "$GATE" ] || fail "falta $GATE"

esperados="implementer ingenieria"
reales="$(sed -n 's/.*ROL_OK = {\(.*\)}.*/\1/p' "$GATE" | grep -oE '"[a-z]+"' | tr -d '\"' | sort -u | tr '\n' ' ')"
[ "$reales" = "implementer ingenieria " ] \
  || fail "la lista cerrada de roles no es exactamente implementer+ingenieria: [$reales]"

# main jamas: aunque todo lo demas valide, el rol main no puede mergear.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/corridas"
python3 - "$T/registro.json" <<'PY'
import json, sys
d = {"schema": "corrida.v2", "id": "r", "estado": "abierta", "seguimiento_global": True,
     "runbook": "rb", "canal": {"cron": "c", "destino": "d"}, "cli_modos": "m",
     "inicio": "2026-09-27T00:00:00Z", "simulacro": False, "timebox_horas": 6, "sesiones": [],
     "authorization_ref": "fase14-merge-automatico",
     "automatic_routing": {"enabled": True}, "preaprobaciones": [],
     "lanes": [{"id": "l1", "branch": "fase14/a", "worktree": "/tmp", "base_remote_sha": "9" * 40,
                "owner": "l1", "mode": "write", "role": "write", "estado": "activo",
                "token": "t", "repo": "gon0801/goncloud-openclaw", "worker": "x", "session": "s"}]}
open(sys.argv[1], "w").write(json.dumps(d))
PY
python3 - "$T/ev.json" <<'PY'
import json, sys
json.dump({"schema": "saikit-entrega.v1", "ci": {"sha": "1" * 40, "conclusion": "success"}},
          open(sys.argv[1], "w"))
PY
python3 - "$T/rc.json" <<'PY'
import json, sys
json.dump({"schema": "saikit-entrega.v1", "headRefOid": "1" * 40}, open(sys.argv[1], "w"))
PY
out="$(bash "$GATE" main r "$T/registro.json" l1 1111111111111111111111111111111111111111 "$T/ev.json" "$T/rc.json" 2>&1)"
[ "$?" -ne 0 ] || fail "main logro pasar el gate de autoridad: $out"
printf '%s\n' "$out" | grep -q "rol sin autoridad de merge: main" \
  || fail "sin el motivo de main: $out"

# Si el repo trae summa-gate con MERGE_AGENT_ALLOWLIST, la lista debe seguir
# cerrada y sin main (la decision historica de 14.2).
if [ -f summa-gate/lib.ts ]; then
  lista="$(grep -o 'MERGE_AGENT_ALLOWLIST\s*=\s*new Set(\[[^]]*\])' summa-gate/lib.ts | head -1)"
  printf '%s\n' "$lista" | grep -q '"main"' \
    && fail "main aparecio en MERGE_AGENT_ALLOWLIST"
fi

echo "TODO VERDE: merge-allowlist-cierre-pr"

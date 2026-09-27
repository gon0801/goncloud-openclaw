#!/bin/bash
# Task 7 Step 1/2: autoridad de merge sin darle ejecucion a main.
# El gate puro (autoridad-merge.sh) decide; las skills documentan la ruta.
# Uso: bash scripts/tests/test-autonomous-merge-authority.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
. scripts/mac/corrida/lib.sh

GATE=scripts/mac/corrida/autoridad-merge.sh
TABLA=scripts/mac/corrida/preaprobaciones.v1.json
SKILL=agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md
SKILL2=agents/ingenieria/agent/workshop-skills/saikit-cierre-pr/SKILL.md
SHA=1111111111111111111111111111111111111111
MERGE_SHA=2222222222222222222222222222222222222222

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/corridas"

registro() { # $1 salida $2 ref $3 auto $4 rol... : registro corrida.v2 con un carril
  python3 - "$1" "$2" "$3" "${@:4}" <<'PY'
import json, sys
salida, ref, auto = sys.argv[1], sys.argv[2], sys.argv[3]
rol = sys.argv[4] if len(sys.argv) > 4 else "implementer"
d = {
    "schema": "corrida.v2", "id": "r14-4", "estado": "abierta",
    "vigia": "claw", "seguimiento_global": True,
    "runbook": "loop-autopilot",
    "canal": {"cron": "c", "destino": "d"},
    "cli_modos": "/tmp/m.tsv", "inicio": "2026-09-27T00:00:00Z",
    "simulacro": False, "timebox_horas": 6, "sesiones": [],
    "authorization_ref": ref,
    "automatic_routing": {"enabled": auto == "True"},
    "preaprobaciones": [],
    "lanes": [{
        "id": "l1", "branch": "corrida/r14-4/l1", "worktree": "/tmp/wt-a",
        "base_remote_sha": "9" * 40, "owner": "l1", "mode": "write",
        "role": "write", "estado": "activo", "token": "t",
        "repo": "gon0801/goncloud-openclaw",
        "worker": "claude_fable", "session": "ses-a",
    }],
}
json.dump(d, open(salida, "w"), indent=1)
PY
}

evidencia() { # $1 salida $2 sha $3 conclusion
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
json.dump({
    "schema": "saikit-entrega.v1",
    "repo": "gon0801/goncloud-openclaw", "pr": 7,
    "head": sys.argv[2],
    "ci": {"sha": sys.argv[2], "conclusion": sys.argv[3], "workflow": "quality"},
    "review": {"reviewer": "codex", "sha": sys.argv[2], "verdict": "approve"},
}, open(sys.argv[1], "w"), indent=1)
PY
}

recibo() { # $1 salida $2 sha
  python3 - "$1" "$2" <<'PY'
import json, sys
json.dump({
    "schema": "saikit-entrega.v1", "repo": "gon0801/goncloud-openclaw", "pr": 7,
    "headRefOid": sys.argv[2],
    "ci": {"sha": sys.argv[2], "conclusion": "success", "workflow": "quality"},
}, open(sys.argv[1], "w"), indent=1)
PY
}

verifica() { # $1 desc $2 rol $3 reg $4 expect(0|1) [$5 motivo-esperado]
  local desc="$1" rol="$2" reg="$3" expect="$4" motivo="${5:-}"
  local out rc
  out="$(ALANE=l1 bash "$GATE" "$rol" r14-4 "$reg" l1 "$SHA" "$T/ev.json" "$T/rc.json" 2>&1)"
  rc=$?
  if [ "$expect" = 0 ] && [ "$rc" -ne 0 ]; then
    fail "$desc: debio autorizar y salio $rc: $out"
  fi
  if [ "$expect" = 1 ] && [ "$rc" -eq 0 ]; then
    fail "$desc: autorizo cuando debia fallar: $out"
  fi
  if [ -n "$motivo" ]; then
    printf '%s\n' "$out" | grep -q "$motivo" || fail "$desc: sin el motivo '$motivo': $out"
  fi
}

# Fixtures base.
registro "$T/reg-ok.json" "fase14-merge-automatico" True
evidencia "$T/ev.json" "$SHA" success
recibo "$T/rc.json" "$SHA"

# (1) Roles: main y reviewer jamas; implementer/ingenieria si.
verifica "main fuera de la ejecucion" main "$T/reg-ok.json" 1 "rol sin autoridad"
verifica "reviewer fuera" reviewer "$T/reg-ok.json" 1 "rol sin autoridad"
verifica "verifier fuera" verifier "$T/reg-ok.json" 1 "rol sin autoridad"
verifica "implementer autorizado" implementer "$T/reg-ok.json" 0
verifica "ingenieria autorizada" ingenieria "$T/reg-ok.json" 0
out="$(ALANE=l1 bash "$GATE" implementer r14-4 "$T/reg-ok.json" l1 "$SHA" "$T/ev.json" "$T/rc.json")"
printf '%s\n' "$out" | grep -q '^DELEGAR: bash scripts/mac/corrida.sh compuerta r14-4 l1 merge' \
  || fail "sin linea de delegacion a la compuerta: $out"
printf '%s\n' "$out" | grep -q 'gh pr merge' \
  && fail "la ruta publica un bypass directo de gh"
echo "ok (1): roles cerrados y delegacion unica a la compuerta"

# (2) authorization_ref: ausente, desconocido, no aprobado, fuera de alcance.
registro "$T/reg-sinref.json" "" True
verifica "authorization_ref ausente" implementer "$T/reg-sinref.json" 1 "authorization_ref ausente"
registro "$T/reg-desc.json" "ref-desconocida-xyz" True
verifica "authorization_ref desconocida" implementer "$T/reg-desc.json" 1 "authorization_ref desconocido"
registro "$T/reg-pend.json" "fase14-merge-pendiente" True
verifica "authorization_ref no aprobada" implementer "$T/reg-pend.json" 1 "authorization_ref no aprobado"
cp "$T/reg-ok.json" "$T/reg-scope.json"
python3 - "$T/reg-scope.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["lanes"][0]["branch"] = "otra-rama/x"
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
verifica "authorization_ref fuera de alcance (rama)" implementer "$T/reg-scope.json" 1 "fuera de alcance: rama"
echo "ok (2): authorization_ref falla cerrado en los cuatro defectos"

# (2b) 14.4 r2 B1: el alcance de la preaprobacion es obligatorio. La
# evidencia y el recibo de OTRO repo no pueden aprovechar la preaprobacion
# de este repo (el repo del carril es opcional en el contrato de 14.16).
evidencia "$T/ev-otro.json" "$SHA" success
python3 - "$T/ev-otro.json" "$T/rc-otro.json" <<'PY'
import json, sys
ev = json.load(open(sys.argv[1]))
ev["repo"] = "otro-dueno/otro-repo"
json.dump(ev, open(sys.argv[1], "w"), indent=1)
rc = {"schema": "saikit-entrega.v1", "repo": "otro-dueno/otro-repo", "pr": 7,
      "headRefOid": "1" * 40}
json.dump(rc, open(sys.argv[2], "w"), indent=1)
PY
out_aj="$(bash "$GATE" implementer r14-4 "$T/reg-ok.json" l1 "$SHA" "$T/ev-otro.json" "$T/rc-otro.json" 2>&1)"
[ "$?" -ne 0 ] || fail "la preaprobacion autorizo un merge en otro repo: $out_aj"
printf '%s\n' "$out_aj" | grep -q "authorization_ref fuera de alcance: repo" \
  || fail "sin el motivo de repo fuera de alcance: $out_aj"
out_otro="$(bash "$GATE" implementer r14-4 "$T/reg-ok.json" l1 "$SHA" "$T/ev-otro.json" "$T/rc-otro.json" 2>&1)"
printf '%s\n' "$out_otro" | grep -q "authorization_ref fuera de alcance: repo" \
  || fail "sin el motivo de repo fuera de alcance: $out_otro"
echo "ok (2b): la preaprobacion no autoriza merges en otros repos"

# (2c) 14.4 r3 F1: la rama que preparar-carril produce de verdad es
# corrida/<run>/<carril>; con la preaprobacion declarando ese patron el
# registro real debe autorizar, no morir fuera de alcance.
registro "$T/reg-rama-real.json" "fase14-merge-automatico" True
python3 - "$T/reg-rama-real.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["lanes"][0]["branch"] = "corrida/r14-4/l1"
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
out_rr="$(bash "$GATE" implementer r14-4 "$T/reg-rama-real.json" l1 "$SHA" "$T/ev.json" "$T/rc.json" 2>&1)"
[ "$?" -eq 0 ] || fail "rama real de preparar-carril debio autorizar: $out_rr"
printf '%s
' "$out_rr" | grep -q "^DELEGAR:" || fail "sin DELEGAR con la rama real: $out_rr"
echo "ok (2c): la rama corrida/<run>/<carril> de preparar-carril autoriza"

# (3) Registro y routing.
printf 'no-json' >"$T/reg-roto.json"
verifica "registro malformado" implementer "$T/reg-roto.json" 1 "registro de corrida ilegible"
registro "$T/reg-off.json" "fase14-merge-automatico" False
verifica "automatic_routing apagado" implementer "$T/reg-off.json" 1 "automatic_routing.enabled"
out_ci="$(bash "$GATE" implementer r14-4 "$T/reg-ok.json" no-existe "$SHA" "$T/ev.json" "$T/rc.json" 2>&1)"
[ "$?" -ne 0 ] || fail "carril inexistente debio fallar: $out_ci"
printf '%s\n' "$out_ci" | grep -q "carril inexistente: no-existe" \
  || fail "P7... sin motivo del carril: $out_ci"
echo "ok (3): registro y routing fail-closed"

# (4) Recibo y CI vigentes.
python3 - "$T/ev.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["ci"]["sha"] = "9" * 40
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
verifica "CI de otro SHA" implementer "$T/reg-ok.json" 1 "CI no corresponde"
evidencia "$T/ev.json" "$SHA" failure
verifica "CI fallido" implementer "$T/reg-ok.json" 1 "CI no vigente"
evidencia "$T/ev.json" "$SHA" success
recibo "$T/rc-viejo.json" "$(printf '9%.0s' $(seq 40))"
out_rh="$(bash "$GATE" implementer r14-4 "$T/reg-ok.json" l1 "$SHA" "$T/ev.json" "$T/rc-viejo.json" 2>&1)"
[ "$?" -ne 0 ] || fail "recibo de otro head debio fallar: $out_rh"
printf '%s\n' "$out_rh" | grep -q "recibo de un head distinto" \
  || fail "sin motivo del recibo: $out_rh"
echo "ok (4): recibo del kit y CI vigentes para el head"

# (5) Ruta legada: orden fechada del dueno sigue funcionando (skills la
# documentan como camino historico; el gate nuevo solo gobierna la ruta
# automatica de Task 7).
grep -q 'orden' agents/implementer/agent/workshop-skills/saikit-cierre-pr/MERGE-POR-ORDEN.md \
  || fail "MERGE-POR-ORDEN.md sin la mension de la ruta legada"
echo "ok (5): ruta legada documentada"

# (6) Copias byte-identicas.
diff -r agents/implementer/agent/workshop-skills/saikit-cierre-pr \
       agents/ingenieria/agent/workshop-skills/saikit-cierre-pr \
  || fail "las copias de saikit-cierre-pr difieren"
echo "ok (6): copias byte-identicas"

echo "TODO VERDE: autoridad de merge (Task 7)"

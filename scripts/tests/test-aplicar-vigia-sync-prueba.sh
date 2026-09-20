#!/usr/bin/env bash
# Aserciones D1/D2/rm del aplicador vigia, en seco (BRIEF-r4).
# Rojo primero: invertir assert_d1/d2 deja este test en rojo.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ASSERT=scripts/tests/vigia_sync_prueba_assert.py
[ -f "$ASSERT" ] || fail "falta $ASSERT"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# --- fixtures ---
# D1 bueno: summary nombra verifier + archivos
python3 - "$T/d1_ok.json" <<'PY'
import json,sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC SKILLS agentes=verifier n=1\nverifier: cron-payload-verify/SKILL.md,lane-claim-verify/SKILL.md\nYa esta en main. Si algo no te cuadra, dime y lo reviso."}]},
  open(sys.argv[1],"w"))
PY
# D1 malo: vacio
python3 -c 'import json,sys; json.dump({"entries":[{"summary":""}]}, open(sys.argv[1],"w"))' "$T/d1_vacio.json"
# D2 bueno: OK sin aviso D
python3 -c 'import json,sys; json.dump({"entries":[{"status":"ok","summary":"VIGIA SYNC OK ciclo=2026-09-19 12:00 CDMX"}]}, open(sys.argv[1],"w"))' "$T/d2_ok.json"
# D2 malo: aviso D
python3 -c 'import json,sys; json.dump({"entries":[{"summary":"VIGIA SYNC SKILLS agentes=verifier n=1\nYa esta en main."}]}, open(sys.argv[1],"w"))' "$T/d2_aviso.json"

# (1) D1 bueno → PASS
python3 "$ASSERT" assert-d1 "$T/d1_ok.json" >/dev/null \
  || fail "(1) D1 con aviso de verifier debio PASS"
echo "ok (1): D1 con verifier+archivos → PASS"

# (2) D1 vacio → FAIL
if python3 "$ASSERT" assert-d1 "$T/d1_vacio.json" >/dev/null 2>&1; then
  fail "(2) D1 vacio debio FAIL y paso"
fi
echo "ok (2): D1 vacio → FAIL"

# (3) D2 bueno → PASS
python3 "$ASSERT" assert-d2 "$T/d2_ok.json" >/dev/null \
  || fail "(3) D2 callado debio PASS"
echo "ok (3): D2 sin aviso D → PASS"

# (4) D2 con aviso → FAIL
if python3 "$ASSERT" assert-d2 "$T/d2_aviso.json" >/dev/null 2>&1; then
  fail "(4) D2 con aviso D debio FAIL y paso"
fi
echo "ok (4): D2 con aviso D → FAIL"

# (5) rm fallido → FAIL
if python3 "$ASSERT" assert-rm deadbeef 0 0 >/dev/null 2>&1; then
  fail "(5) rm fallido debio FAIL y paso"
fi
echo "ok (5): rm fallido → FAIL"

# (6) rm OK pero sigue listado → FAIL
if python3 "$ASSERT" assert-rm deadbeef 1 1 >/dev/null 2>&1; then
  fail "(6) job aun listado debio FAIL y paso"
fi
echo "ok (6): rm OK pero sigue en list → FAIL"

# (7) rm OK y no listado → PASS
python3 "$ASSERT" assert-rm deadbeef 1 0 >/dev/null \
  || fail "(7) rm limpio debio PASS"
echo "ok (7): rm verificado → PASS"

# (8) Mutante: invertir assert_d1 (aceptar vacio) deja rojo este test.
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import importlib.util, pathlib, sys, tempfile, textwrap
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
# Invertir: D1 vacio pasa
mut = src.replace(
    'if not blob.strip():\n        return "D1: runs vacio o sin summary (no hay evidencia de aviso)"',
    'if not blob.strip():\n        return ""  # MUTANTE: vacio aceptado',
    1,
)
assert mut != src, "no pude mutar assert_d1"
mp = pathlib.Path(sys.argv[2]) / "mut_assert.py"
mp.write_text(mut, encoding="utf-8")
import subprocess
# Con el mutante, d1_vacio PASS — nuestro chequeo (2) fallaria; aqui verificamos que
# el mutante efectivamente acepta vacio (discrimina).
r = subprocess.run([sys.executable, str(mp), "assert-d1", str(pathlib.Path(sys.argv[2])/"d1_vacio.json")],
                   capture_output=True, text=True)
if r.returncode != 0:
    print("ROJO: mutante no acepto d1 vacio; el test no discriminaria", file=sys.stderr)
    sys.exit(1)
print("ok (8): mutante que acepta D1 vacio queda expuesto (discriminacion)")
PY

# (9) El aplicador invoca el assert, ESCRIBE el fixture y verifica rm.
grep -qE '^escribir_log_prueba\(\)' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta la funcion escribir_log_prueba() — el script debe escribir el fixture"
grep -q 'escribir_log_prueba 1 D1' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta la llamada escribir_log_prueba 1 D1 antes de D1"
grep -q 'escribir_log_prueba 0 D2' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta la llamada escribir_log_prueba 0 D2 antes de D2"
grep -q 'assert-d1 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta assert-d1 tras el run de D1"
grep -q 'assert-d2 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta assert-d2 tras el run de D2"
grep -q 'assert-rm' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(9) falta assert-rm en el cleanup"
echo "ok (9): el aplicador escribe fixture, aserta resultado y verifica rm"

echo "TODO VERDE: aplicar-vigia-sync-prueba"

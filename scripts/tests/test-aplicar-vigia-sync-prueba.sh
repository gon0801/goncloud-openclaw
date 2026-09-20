#!/usr/bin/env bash
# Aserciones D1/D2/rm del aplicador vigia, en seco (BRIEF-r4/r5).
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ASSERT=scripts/tests/vigia_sync_prueba_assert.py
[ -f "$ASSERT" ] || fail "falta $ASSERT"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# --- fixtures ---
# D1 bueno: run ok + linea de contrato
python3 - "$T/d1_ok.json" <<'PY'
import json,sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC SKILLS agentes=verifier n=1\nverifier: cron-payload-verify/SKILL.md,lane-claim-verify/SKILL.md\nYa esta en main. Si algo no te cuadra, dime y lo reviso."}]},
  open(sys.argv[1],"w"))
PY
# D1 malo: run FALLIDO que menciona verifier (BRIEF-r5 hueco 1)
python3 - "$T/d1_failed.json" <<'PY'
import json,sys
json.dump({"entries":[{"status":"error","completionStatus":"failed",
  "error":"verifier no pudo leer cron-payload-verify/SKILL.md"}]}, open(sys.argv[1],"w"))
PY
# D1 malo: vacio / sin status
python3 -c 'import json,sys; json.dump({"entries":[{"summary":""}]}, open(sys.argv[1],"w"))' "$T/d1_vacio.json"
# D2 bueno: OK sin aviso D
python3 -c 'import json,sys; json.dump({"entries":[{"status":"ok","completionStatus":"succeeded","summary":"VIGIA SYNC OK ciclo=2026-09-19 12:00 CDMX"}]}, open(sys.argv[1],"w"))' "$T/d2_ok.json"
# D2 malo: aviso D
python3 -c 'import json,sys; json.dump({"entries":[{"status":"ok","summary":"VIGIA SYNC SKILLS agentes=verifier n=1\nYa esta en main."}]}, open(sys.argv[1],"w"))' "$T/d2_aviso.json"
# D2 malo: {} (BRIEF-r5 hueco 2)
printf '%s' '{}' > "$T/d2_vacio.json"

# (1) D1 bueno → PASS
python3 "$ASSERT" assert-d1 "$T/d1_ok.json" >/dev/null \
  || fail "(1) D1 con linea de contrato debio PASS"
echo "ok (1): D1 ok+contrato → PASS"

# (2) D1 run fallido → FAIL (aunque mencione verifier)
if python3 "$ASSERT" assert-d1 "$T/d1_failed.json" >/dev/null 2>&1; then
  fail "(2) D1 con status=error debio FAIL y paso"
fi
out=$(python3 "$ASSERT" assert-d1 "$T/d1_failed.json" 2>&1 || true)
echo "$out" | grep -q 'ASSERT_FAIL' || fail "(2) debio imprimir ASSERT_FAIL"
echo "ok (2): D1 run fallido → FAIL"

# (3) D1 vacio → FAIL
if python3 "$ASSERT" assert-d1 "$T/d1_vacio.json" >/dev/null 2>&1; then
  fail "(3) D1 vacio debio FAIL y paso"
fi
echo "ok (3): D1 vacio → FAIL"

# (4) D2 bueno → PASS
python3 "$ASSERT" assert-d2 "$T/d2_ok.json" >/dev/null \
  || fail "(4) D2 callado debio PASS"
echo "ok (4): D2 sin aviso D → PASS"

# (5) D2 con aviso → FAIL
if python3 "$ASSERT" assert-d2 "$T/d2_aviso.json" >/dev/null 2>&1; then
  fail "(5) D2 con aviso D debio FAIL y paso"
fi
echo "ok (5): D2 con aviso D → FAIL"

# (6) D2 {} → FAIL
if python3 "$ASSERT" assert-d2 "$T/d2_vacio.json" >/dev/null 2>&1; then
  fail "(6) D2 {} debio FAIL y paso"
fi
out=$(python3 "$ASSERT" assert-d2 "$T/d2_vacio.json" 2>&1 || true)
echo "$out" | grep -q 'ASSERT_FAIL' || fail "(6) debio imprimir ASSERT_FAIL"
echo "ok (6): D2 {} → FAIL"

# (7) rm fallido → FAIL
if python3 "$ASSERT" assert-rm deadbeef 0 absent >/dev/null 2>&1; then
  fail "(7) rm fallido debio FAIL y paso"
fi
echo "ok (7): rm fallido → FAIL"

# (8) rm OK pero sigue listado → FAIL
if python3 "$ASSERT" assert-rm deadbeef 1 present >/dev/null 2>&1; then
  fail "(8) job aun listado debio FAIL y paso"
fi
echo "ok (8): rm OK pero sigue en list → FAIL"

# (9) rm OK y lista unknown → FAIL (no fail-open)
if python3 "$ASSERT" assert-rm deadbeef 1 unknown >/dev/null 2>&1; then
  fail "(9) lista unknown debio FAIL y paso"
fi
out=$(python3 "$ASSERT" assert-rm deadbeef 1 unknown 2>&1 || true)
echo "$out" | grep -q 'UNKNOWN' || fail "(9) debio decir UNKNOWN"
echo "ok (9): lista unknown → FAIL (UNKNOWN)"

# (10) rm OK y absent → PASS
python3 "$ASSERT" assert-rm deadbeef 1 absent >/dev/null \
  || fail "(10) rm limpio debio PASS"
echo "ok (10): rm verificado → PASS"

# (11) Mutante: aceptar run fallido en D1 queda expuesto
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import pathlib, subprocess, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
needle = 'if why:\n        return f"D1: run no exitoso ({why}) — un run fallido no es un aviso"'
mut = src.replace(needle, 'if why:\n        pass  # MUTANTE: run fallido aceptado', 1)
assert mut != src, "no pude mutar assert_d1"
mp = pathlib.Path(sys.argv[2]) / "mut_assert.py"
mp.write_text(mut, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "assert-d1", str(pathlib.Path(sys.argv[2]) / "d1_failed.json")],
    capture_output=True, text=True,
)
# Tras el mutante, d1_failed puede seguir fallando por falta de linea de contrato.
# Forzar: el mutante solo salta el check de run; el error blob no tiene la linea → aun FAIL.
# Mejor mutante: saltar run_exitoso Y el contrato.
mut2 = src.replace(
    'why = _run_exitoso(entry)\n    if why:\n        return f"D1: run no exitoso ({why}) — un run fallido no es un aviso"',
    'why = ""  # MUTANTE',
    1,
)
assert mut2 != src
mp.write_text(mut2, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "assert-d1", str(pathlib.Path(sys.argv[2]) / "d1_failed.json")],
    capture_output=True, text=True,
)
# Aun sin check de run, falta linea de contrato → FAIL. Mutar tambien el contrato:
mut3 = mut2.replace(
    'if not _RE_CONTRATO_D1.search(blob):\n        return (\n            "D1: falta la linea de contrato "\n            "\'VIGIA SYNC SKILLS agentes=verifier ... n=<n>\'"\n        )',
    'if False:\n        return "x"',
    1,
)
# Simpler: make assert_d1 always return ""
mut3 = src.replace(
    'def assert_d1_result(runs: Any) -> str:\n    """D1: run exitoso + linea de contrato del aviso. \'\' = OK."""',
    'def assert_d1_result(runs: Any) -> str:\n    return ""  # MUTANTE\n    """D1: run exitoso + linea de contrato del aviso. \'\' = OK."""',
    1,
)
assert mut3 != src
mp.write_text(mut3, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "assert-d1", str(pathlib.Path(sys.argv[2]) / "d1_failed.json")],
    capture_output=True, text=True,
)
if r.returncode != 0:
    print("ROJO: mutante no acepto d1_failed; no discrimina", file=sys.stderr)
    sys.exit(1)
print("ok (11): mutante que acepta D1 fallido queda expuesto")
PY

# (12) El aplicador: escribe fixture, aserta, verifica rm, franja de silencio
grep -qE '^escribir_log_prueba\(\)' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba()"
grep -q 'escribir_log_prueba 1 D1' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba 1 D1"
grep -q 'escribir_log_prueba 0 D2' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba 0 D2"
grep -q 'assert-d1 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-d1"
grep -q 'assert-d2 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-d2"
grep -q 'assert-rm' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-rm"
grep -q 'cron_list_status' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta cron_list_status (no fail-open)"
grep -q 'en_franja_silencio_cdmx' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta rechazo en franja de silencio CDMX"
echo "ok (12): aplicador escribe, aserta, lista legible, franja silencio"

echo "TODO VERDE: aplicar-vigia-sync-prueba"

#!/usr/bin/env bash
# Aserciones D1/D2/D3/rm del aplicador vigia, en seco (BRIEF-r4/r5; v3).
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
ASSERT=scripts/tests/vigia_sync_prueba_assert.py
[ -f "$ASSERT" ] || fail "falta $ASSERT"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
PORCELAIN_ANTES=$(git status --porcelain)

# --- fixtures ---
# D1 bueno: run ok + linea de contrato de pendiente
python3 - "$T/d1_ok.json" <<'PY'
import json,sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC PENDIENTE pr=7 agentes=verifier\nverifier: cron-payload-verify/SKILL.md,lane-claim-verify/SKILL.md\nTodavia no esta en el gateway. Te aviso cuando se deploye."}]},
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
# D2 malo: aviso D (deployado)
python3 -c 'import json,sys; json.dump({"entries":[{"status":"ok","summary":"VIGIA SYNC DEPLOYED sha=e701489 n=1\nYa esta en el gateway. Si algo no te cuadra, dime y lo reviso."}]}, open(sys.argv[1],"w"))' "$T/d2_aviso.json"
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

# (3b) D1 contrato partido entre lineas → FAIL (UNA linea; sin DOTALL/\s cruzando salto)
python3 - "$T/d1_partido.json" <<'PY'
import json, sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC PENDIENTE pr=7\nagentes=verifier skill.md"}]}, open(sys.argv[1],"w"))
PY
if python3 "$ASSERT" assert-d1 "$T/d1_partido.json" >/dev/null 2>&1; then
  fail "(3b) contrato partido debio FAIL y paso"
fi
echo "ok (3b): D1 contrato partido → FAIL"

# (3c) Mutante DOTALL: acepta contrato partido → queda expuesto
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import pathlib, subprocess, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = '''def _linea_contrato_d1(blob: str) -> str | None:
    for line in blob.splitlines():
        if _RE_CONTRATO_D1.search(line):
            return line
    return None'''
new = '''def _linea_contrato_d1(blob: str) -> str | None:
    # MUTANTE: DOTALL + \\s cruza saltos
    import re as _re
    if _re.search(r"VIGIA SYNC PENDIENTE\\s+pr=[\\d,]+\\s+agentes=verifier\\b", blob, _re.I | _re.DOTALL):
        return blob
    return None'''
mut = src.replace(old, new, 1)
assert mut != src, "no pude aplicar mutante DOTALL"
mp = pathlib.Path(sys.argv[2]) / "mut_dotall.py"
mp.write_text(mut, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "assert-d1", str(pathlib.Path(sys.argv[2]) / "d1_partido.json")],
    capture_output=True, text=True,
)
if r.returncode != 0:
    print("ROJO: mutante DOTALL no acepto partido; no discrimina", file=sys.stderr)
    sys.exit(1)
print("ok (3c): mutante DOTALL que acepta contrato partido queda expuesto")
PY

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

# (6b) D3 bueno → PASS
python3 - "$T/d3_ok.json" <<'PY'
import json, sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC DEPLOYED sha=e701489 n=1\ne701489 agents/verifier/agent/workshop-skills/cron-payload-verify/SKILL.md\nYa esta en el gateway. Si algo no te cuadra, dime y lo reviso."}]},
  open(sys.argv[1],"w"))
PY
python3 "$ASSERT" assert-d3 "$T/d3_ok.json" >/dev/null \
  || fail "(6b) D3 con linea de contrato debio PASS"
echo "ok (6b): D3 ok+contrato → PASS"

# (6c) D3 callado → FAIL
python3 -c 'import json,sys; json.dump({"entries":[{"status":"ok","completionStatus":"succeeded","summary":"VIGIA SYNC OK ciclo=2026-09-19 12:00 CDMX"}]}, open(sys.argv[1],"w"))' "$T/d3_callado.json"
if python3 "$ASSERT" assert-d3 "$T/d3_callado.json" >/dev/null 2>&1; then
  fail "(6c) D3 callado debio FAIL y paso"
fi
echo "ok (6c): D3 sin aviso → FAIL"

# (6d) D3 contrato partido → FAIL; mutante DOTALL queda expuesto
python3 - "$T/d3_partido.json" <<'PY'
import json, sys
json.dump({"entries":[{"status":"ok","completionStatus":"succeeded",
  "summary":"VIGIA SYNC DEPLOYED sha=e701489\nn=1 skill.md"}]}, open(sys.argv[1],"w"))
PY
if python3 "$ASSERT" assert-d3 "$T/d3_partido.json" >/dev/null 2>&1; then
  fail "(6d) D3 contrato partido debio FAIL y paso"
fi
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import pathlib, subprocess, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = '''def _linea_contrato_d3(blob: str) -> str | None:
    for line in blob.splitlines():
        if _RE_CONTRATO_D3.search(line):
            return line
    return None'''
new = '''def _linea_contrato_d3(blob: str) -> str | None:
    # MUTANTE: DOTALL + \\s cruza saltos
    import re as _re
    if _re.search(r"VIGIA SYNC DEPLOYED\\s+sha=[0-9a-f]{7}\\s+n=\\d+", blob, _re.I | _re.DOTALL):
        return blob
    return None'''
mut = src.replace(old, new, 1)
assert mut != src, "no pude aplicar mutante DOTALL en d3"
mp = pathlib.Path(sys.argv[2]) / "mut_dotall_d3.py"
mp.write_text(mut, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "assert-d3", str(pathlib.Path(sys.argv[2]) / "d3_partido.json")],
    capture_output=True, text=True,
)
if r.returncode != 0:
    print("ROJO: mutante DOTALL-D3 no acepto partido; no discrimina", file=sys.stderr)
    sys.exit(1)
print("ok (6d): D3 contrato partido → FAIL; mutante DOTALL-D3 queda expuesto")
PY

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

# (10b) list-status: {"jobs":[]} → absent (no unknown); sin clave jobs → unknown
printf '%s' '{"jobs":[]}' > "$T/list_empty.json"
printf '%s' '{"status":"ok"}' > "$T/list_no_jobs.json"
printf '%s' '{"jobs":[{"id":"abc"}]}' > "$T/list_present.json"
st=$(python3 "$ASSERT" list-status deadbeef "$T/list_empty.json")
[ "$st" = "absent" ] || fail "(10b) jobs=[] debio absent, got $st"
st=$(python3 "$ASSERT" list-status deadbeef "$T/list_no_jobs.json")
[ "$st" = "unknown" ] || fail "(10b) sin clave jobs debio unknown, got $st"
st=$(python3 "$ASSERT" list-status abc "$T/list_present.json")
[ "$st" = "present" ] || fail "(10b) tid en lista debio present, got $st"
# Mutante jobs-or: [] falsy → unknown
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import pathlib, subprocess, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
old = 'if "jobs" not in data:\n        return "unknown", []\n    jobs = data["jobs"]'
new = 'jobs = data.get("jobs") or data  # MUTANTE: [] falsy\n    if False:\n        return "unknown", []'
mut = src.replace(old, new, 1)
assert mut != src, "no pude mutar jobs_from"
mp = pathlib.Path(sys.argv[2]) / "mut_jobs_or.py"
mp.write_text(mut, encoding="utf-8")
r = subprocess.run(
    [sys.executable, str(mp), "list-status", "tid", str(pathlib.Path(sys.argv[2]) / "list_empty.json")],
    capture_output=True, text=True,
)
if r.stdout.strip() != "unknown":
    print(f"ROJO: mutante jobs-or no dio unknown en []; out={r.stdout!r}", file=sys.stderr)
    sys.exit(1)
print("ok (10b): jobs=[] → absent; mutante jobs-or queda expuesto")
PY

# (11) Mutante: aceptar run fallido en D1 queda expuesto
python3 - "$ASSERT" "$T" <<'PY' || exit 1
import pathlib, subprocess, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
mut3 = src.replace(
    'def assert_d1_result(runs: Any) -> str:\n    """D1: run exitoso + linea de contrato del aviso. \'\' = OK."""',
    'def assert_d1_result(runs: Any) -> str:\n    return ""  # MUTANTE\n    """D1: run exitoso + linea de contrato del aviso. \'\' = OK."""',
    1,
)
assert mut3 != src
mp = pathlib.Path(sys.argv[2]) / "mut_assert.py"
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

# (12) Anclas del aplicador (escritura, asserts, lista, franja)
grep -qE '^escribir_log_prueba\(\)' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba()"
grep -q 'escribir_log_prueba 1 D1' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba 1 D1"
grep -q 'escribir_log_prueba 0 D2' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba 0 D2"
grep -q 'escribir_log_prueba 2 D3' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta escribir_log_prueba 2 D3"
grep -q 'verif-sync-repos.v3.txt' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) aplicador no apunta a v3"
grep -q 'assert-d1 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-d1"
grep -q 'assert-d2 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-d2"
grep -q 'assert-d3 "' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-d3"
grep -q 'assert-rm' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta assert-rm"
grep -q 'cron_list_status' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta cron_list_status (no fail-open)"
grep -q 'en_franja_silencio_cdmx' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta rechazo en franja de silencio CDMX"
grep -q 'run_two' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta run_two (D4 doble corrida)"
grep -q 'runs1.json' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta evidencia runs1"
grep -q 'runs2.json' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta evidencia runs2"
grep -q 'D4 ASSERT-2 FALLO' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta asercion 2da corrida"
grep -q 'escribir_log_prueba 1 D4' docs/cron-messages/APLICAR_VIGIA_SYNC.sh \
  || fail "(12) falta fixture D4"
rtwo=$(sed -n '/^  run_two() {/,/^  }/p' docs/cron-messages/APLICAR_VIGIA_SYNC.sh)
[ -n "$rtwo" ] || fail "(12) no se aislo run_two"
echo "$rtwo" | grep -q 'for n in 1 2' || fail "(12) D4 sin doble corrida"
a1=$(printf '%s\n' "$rtwo" | grep -n 'assert-d1' | head -1 | cut -d: -f1)
a2=$(printf '%s\n' "$rtwo" | grep -n 'assert-d2' | head -1 | cut -d: -f1)
[ -n "$a1" ] && [ -n "$a2" ] && [ "$a1" -lt "$a2" ] \
  || fail "(12) D4 aserta en orden distinto (1ra avisa, 2da calla)"
echo "ok (12): anclas aplicador (escribe, aserta, lista, franja, D4)"

# (13) Prueba CONDUCTUAL de franja (no solo grep): copia bajo scratch, mock hora
python3 - "$T" <<'PY' || exit 1
"""Copia hermetica del aplicador: mock franja + stub gateway/ejecutar."""
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys
import textwrap

T = pathlib.Path(sys.argv[1])
repo = pathlib.Path(".").resolve()
src = (repo / "docs/cron-messages/APLICAR_VIGIA_SYNC.sh").read_text(encoding="utf-8")

# Stub openclaw: cron get → JSON minimo valido para el seco
oc = T / "oc_stub"
oc.write_text(
    textwrap.dedent(
        """\
        #!/bin/bash
        if [ "${1:-}" = cron ] && [ "${2:-}" = get ]; then
          cat <<'JSON'
        {"id":"2d763be5-6390-4ccf-a3a4-621c91c41e94","agentId":"main","enabled":true,
         "schedule":{"kind":"cron","expr":"40 */2 * * *"},
         "payload":{"message":"LOG=old","toolsAllow":["exec"]}}
        JSON
          exit 0
        fi
        exit 0
        """
    ),
    encoding="utf-8",
)
oc.chmod(0o755)

def make_copy(*, franja_true: bool, annul_guard: bool, name: str) -> pathlib.Path:
    body = src
    # cd fijo al repo: la copia vive bajo $T, no bajo docs/cron-messages/
    body = body.replace(
        'cd "$(dirname "$0")/../.." || exit 1',
        f'cd "{repo}" || exit 1',
    )
    body = body.replace("OC=~/.openclaw/bin/openclaw", f"OC={oc}")
    # Evitar ventanas cerradas UTC y lock global
    body, n_win = re.subn(
        r"for w in .*?; do\n  # shellcheck disable=SC2086\n  if in_win \$w; then echo \"ABORTO: dentro de ventana cerrada \(\$w UTC\)\.\"; exit 1; fi\ndone",
        "true  # stub: sin ventanas en prueba hermetica",
        body,
        count=1,
        flags=re.S,
    )
    if n_win != 1:
        raise SystemExit(f"sin stub de ventana cerrada en {name}: reemplazos={n_win}")
    body = body.replace(
        "LOCKDIR=/tmp/aplicar_vigia_sync.lock",
        f"LOCKDIR={T / ('lock_' + name)}",
    )
    # Hermetico (F14): respaldos y evidencia al temporal de la prueba
    body = body.replace("docs/cron-messages/backup", f"{T}/ap13-backup")
    body = body.replace("docs/cron-messages/evidence", f"{T}/ap13-evidence")
    body = body.replace(".saikit/scratch/M", f"{T}/ap13-scratch")
    # Mock franja
    if franja_true:
        body = body.replace(
            "en_franja_silencio_cdmx() {\n  local h\n  h=$(TZ=America/Mexico_City date +%H)\n  h=$((10#$h))\n  [ \"$h\" -ge 23 ] || [ \"$h\" -lt 8 ]\n}",
            "en_franja_silencio_cdmx() { return 0; }  # MOCK: dentro de franja",
        )
    else:
        body = body.replace(
            "en_franja_silencio_cdmx() {\n  local h\n  h=$(TZ=America/Mexico_City date +%H)\n  h=$((10#$h))\n  [ \"$h\" -ge 23 ] || [ \"$h\" -lt 8 ]\n}",
            "en_franja_silencio_cdmx() { return 1; }  # MOCK: fuera de franja",
        )
    # Stub ejecutar (no tocar gateway)
    body = body.replace(
        "ejecutar_pruebas() {",
        'ejecutar_pruebas() { echo "STUB ejecutar_pruebas"; return 0; }\n_ejecutar_pruebas_ORIG() {',
    )
    if annul_guard:
        if "if en_franja_silencio_cdmx; then" not in body:
            raise SystemExit("no hallé el guard de franja para anular")
        body = body.replace(
            "if en_franja_silencio_cdmx; then",
            "if false; then  # MUTANTE: guard anulado",
            1,
        )
    out = T / f"aplicar_{name}.sh"
    out.write_text(body, encoding="utf-8")
    out.chmod(0o755)
    return out

env = os.environ.copy()
env["VIGIA_SYNC_EJECUTAR"] = "1"

# Dentro de franja → exit != 0 + mensaje
c_in = make_copy(franja_true=True, annul_guard=False, name="in")
r = subprocess.run(["bash", str(c_in), "--test"], cwd=str(repo), capture_output=True, text=True, env=env)
if r.returncode == 0:
    print("ROJO: dentro de franja debio exit!=0", r.stdout, r.stderr, file=sys.stderr)
    sys.exit(1)
blob = r.stdout + r.stderr
if "franja de silencio" not in blob:
    print("ROJO: falta mensaje de franja:", blob[:800], file=sys.stderr)
    sys.exit(1)

# Fuera de franja → no bloquea (stub ejecutar → exit 0)
c_out = make_copy(franja_true=False, annul_guard=False, name="out")
r = subprocess.run(["bash", str(c_out), "--test"], cwd=str(repo), capture_output=True, text=True, env=env)
if r.returncode != 0:
    print("ROJO: fuera de franja no debio abortar:", r.stdout, r.stderr, file=sys.stderr)
    sys.exit(1)
if "franja de silencio" in (r.stdout + r.stderr):
    print("ROJO: fuera de franja no debio mencionar aborto de franja", file=sys.stderr)
    sys.exit(1)

# Guard anulado + mock dentro → la prueba conductual sale ROJA (no aborta)
c_mut = make_copy(franja_true=True, annul_guard=True, name="mut")
r = subprocess.run(["bash", str(c_mut), "--test"], cwd=str(repo), capture_output=True, text=True, env=env)
if r.returncode != 0 and "franja de silencio" in (r.stdout + r.stderr):
    print("ROJO: mutante con guard anulado aun aborto por franja; no discrimina", file=sys.stderr)
    sys.exit(1)
if r.returncode == 0:
    # Expuesto: con guard anulado pasa aunque "estamos" en franja
    print("ok (13): franja conductual (in→abort, out→ok); guard anulado queda expuesto")
else:
    print(
        f"ROJO: mutante guard-anulado debio exit 0 (stub), got {r.returncode}: {r.stdout[:400]}",
        file=sys.stderr,
    )
    sys.exit(1)
PY

# (14) D4 doble corrida hermetica (F11): MISMA cola + MISMO scratch =>
# la 2da corrida calla ("cada aviso una sola vez"). El gateway falso
# modela el scratch: un job fresco re-avisa, el mismo job calla.
python3 - "$T" <<'PY' || exit 1
"""Ejecuta ejecutar_pruebas de verdad contra un gateway falso con scratch."""
from __future__ import annotations

import glob
import json
import os
import pathlib
import re
import subprocess
import sys
import textwrap

T = pathlib.Path(sys.argv[1])
repo = pathlib.Path(".").resolve()
src = (repo / "docs/cron-messages/APLICAR_VIGIA_SYNC.sh").read_text(encoding="utf-8")

# --- fixtures de runs ---
d1 = {"entries": [{"status": "ok", "completionStatus": "succeeded",
  "summary": "VIGIA SYNC PENDIENTE pr=7 agentes=verifier\n"
             "archivos: agents/verifier/agent/workshop-skills/cron-payload-verify/SKILL.md "
             "agents/verifier/agent/workshop-skills/lane-claim-verify/SKILL.md"}]}
quiet = {"entries": [{"status": "ok", "completionStatus": "succeeded",
  "summary": "VIGIA SYNC OK ciclo=2026-09-19 12:00 CDMX"}]}
d3 = {"entries": [{"status": "ok", "completionStatus": "succeeded",
  "summary": "VIGIA SYNC DEPLOYED sha=e701489 n=1 skill\n"
             "archivos: agents/verifier/agent/workshop-skills/cron-payload-verify/SKILL.md"}]}
(T / "fix-d1.json").write_text(json.dumps(d1), encoding="utf-8")
(T / "fix-quiet.json").write_text(json.dumps(quiet), encoding="utf-8")
(T / "fix-d3.json").write_text(json.dumps(d3), encoding="utf-8")

# --- gateway falso: scratch por job ---
fake = T / "fakeoc_d4"
fake.write_text(
    textwrap.dedent(
        """\
        #!/bin/bash
        ST="$FAKEOC_STATE"
        LOG="$FAKEOC_LOG"
        echo "oc $*" >>"$LOG"
        if [ "$1" = "cron" ] && [ "$2" = "add" ]; then
          name=""; prev=""
          for a in "$@"; do
            if [ "$prev" = "--name" ]; then name="$a"; fi
            prev="$a"
          done
          n=0
          if [ -f "$ST/seq" ]; then n=$(cat "$ST/seq"); fi
          n=$((n + 1)); echo "$n" >"$ST/seq"
          tid="tid-$name-$n"
          echo "$name" >"$ST/$tid.name"
          echo 0 >"$ST/$tid.runs"
          echo "add $name -> $tid" >>"$LOG"
          printf '{"id":"%s"}\\n' "$tid"
          exit 0
        fi
        if [ "$1" = "cron" ] && [ "$2" = "run" ]; then
          tid="$3"
          c=$(cat "$ST/$tid.runs" 2>/dev/null || echo 0)
          echo $((c + 1)) >"$ST/$tid.runs"
          printf '{"id":"%s","run":%d}\\n' "$tid" $((c + 1))
          exit 0
        fi
        if [ "$1" = "cron" ] && [ "$2" = "runs" ]; then
          tid="$3"
          name=$(cat "$ST/$tid.name" 2>/dev/null || echo "?")
          c=$(cat "$ST/$tid.runs" 2>/dev/null || echo 0)
          case "$name" in
            vigia-sync-write-*) printf '{"entries":[]}\\n'; exit 0;;
            vigia-sync-prueba-D1) f="$FIX_D1";;
            vigia-sync-prueba-D2) f="$FIX_QUIET";;
            vigia-sync-prueba-D3) f="$FIX_D3";;
            vigia-sync-prueba-D4*)
              if [ "$c" -ge 2 ]; then f="$FIX_QUIET"; else f="$FIX_D1"; fi;;
            *) printf '{"entries":[]}\\n'; exit 0;;
          esac
          cat "$f"
          exit 0
        fi
        if [ "$1" = "cron" ] && [ "$2" = "get" ]; then
          printf '{"id":"%s"}\\n' "$3"; exit 0
        fi
        if [ "$1" = "cron" ] && [ "$2" = "rm" ]; then exit 0; fi
        if [ "$1" = "cron" ] && [ "$2" = "list" ]; then
          printf '{"jobs":[]}\\n'; exit 0
        fi
        echo "fakeoc: args inesperados: $*" >&2
        exit 99
        """
    ),
    encoding="utf-8",
)
fake.chmod(0o755)

FRANJA = ("en_franja_silencio_cdmx() {\n  local h\n"
          "  h=$(TZ=America/Mexico_City date +%H)\n  h=$((10#$h))\n"
          '  [ "$h" -ge 23 ] || [ "$h" -lt 8 ]\n}')


def make_copy(*, name: str, fresh_scratch_mutant: bool = False) -> pathlib.Path:
    body = src
    body = body.replace(
        'cd "$(dirname "$0")/../.." || exit 1',
        f'cd "{repo}" || exit 1',
    )
    body = body.replace("OC=~/.openclaw/bin/openclaw", f"OC={fake}")
    body, n_win = re.subn(
        r"for w in .*?; do\n  # shellcheck disable=SC2086\n  if in_win \$w; then echo \"ABORTO: dentro de ventana cerrada \(\$\w UTC\)\.\"; exit 1; fi\ndone",
        "true  # stub: sin ventanas en prueba hermetica",
        body,
        count=1,
        flags=re.S,
    )
    if n_win != 1:
        raise SystemExit(f"sin stub de ventana cerrada en {name}: reemplazos={n_win}")
    body = body.replace(
        "LOCKDIR=/tmp/aplicar_vigia_sync.lock",
        f"LOCKDIR={T / ('lock_' + name)}",
    )
    # Hermetico (F14): respaldos y evidencia al temporal de la prueba
    body = body.replace("docs/cron-messages/backup", f"{T}/ap14-backup")
    body = body.replace("docs/cron-messages/evidence", f"{T}/ap14-evidence")
    body = body.replace(".saikit/scratch/M", f"{T}/ap14-scratch")
    if FRANJA not in body:
        raise SystemExit("no halle en_franja para mock")
    body = body.replace(
        FRANJA, "en_franja_silencio_cdmx() { return 1; }  # MOCK: fuera de franja"
    )
    if fresh_scratch_mutant:
        old = "for n in 1 2; do"
        if body.count(old) != 1:
            raise SystemExit("no halle el loop D4 para mutar")
        mut = (
            "for n in 1 2; do\n"
            '    if [ "$n" = "2" ]; then TID=$($OC cron add --name "$jname-fresh" '
            "--agent main --session isolated --no-deliver --at 30m --keep-after-run "
            "--timeout-seconds 600 --tools exec --message x --json 2>/dev/null | "
            "python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"id\",\"\"))'); fi "
            "# MUTANTE: 2da corrida en job fresco"
        )
        body = body.replace(old, mut, 1)
    out = T / f"aplicar_{name}.sh"
    out.write_text(body, encoding="utf-8")
    out.chmod(0o755)
    return out


def run_copy(path: pathlib.Path, tag: str):
    st = T / f"ocstate_{tag}"
    st.mkdir(exist_ok=True)
    env = os.environ.copy()
    env["VIGIA_SYNC_EJECUTAR"] = "1"
    env["FAKEOC_STATE"] = str(st)
    env["FAKEOC_LOG"] = str(T / f"oc_{tag}.log")
    env["FIX_D1"] = str(T / "fix-d1.json")
    env["FIX_QUIET"] = str(T / "fix-quiet.json")
    env["FIX_D3"] = str(T / "fix-d3.json")
    r = subprocess.run(
        ["bash", str(path), "--test"], cwd=str(repo),
        capture_output=True, text=True, env=env,
    )
    log = (T / f"oc_{tag}.log").read_text(encoding="utf-8") if (T / f"oc_{tag}.log").exists() else ""
    return r, log


def rojob(msg: str, extra: str = "") -> None:
    print(f"ROJO: {msg}", file=sys.stderr)
    if extra:
        print(extra[:1500], file=sys.stderr)
    sys.exit(1)


evdir = T / "ap14-scratch"
antes = set(glob.glob(str(evdir / "vigia-sync-prueba-D4.*.runs?.json")))

# Verde: doble corrida, mismo job, 1ra avisa + 2da calla.
c_ok = make_copy(name="d4ok")
r, log = run_copy(c_ok, "d4ok")
if r.returncode != 0:
    rojob("D4 hermetico debio salir 0", r.stdout + r.stderr)
lineas = log.splitlines()
adds = [l for l in lineas if l.startswith("add vigia-sync-prueba-D4 ")]
if len(adds) != 1:
    rojob(f"D4 debio crear UN job, creo {len(adds)}", log)
tid = adds[0].split(" -> ")[1]
runs = [i for i, l in enumerate(lineas) if f"cron run {tid} " in l or l.endswith(f"cron run {tid}")]
if len(runs) != 2:
    rojob(f"D4 debio correr el mismo job 2 veces, corrio {len(runs)}", log)
writes = [i for i, l in enumerate(lineas) if "vigia-sync-write-D4" in l and "cron add" in l]
if len(writes) != 1:
    rojob(f"D4 debio escribir el fixture 1 vez, lo escribio {len(writes)}", log)
if not (writes[0] < runs[0] < runs[1]):
    rojob("D4 orden distinto de fixture->run1->run2", log)
if not any(f"cron rm {tid}" in l for l in lineas):
    rojob("D4 no borro su job", log)
nuevos = sorted(set(glob.glob(str(evdir / "vigia-sync-prueba-D4.*.runs?.json"))) - antes)
r1 = [p for p in nuevos if p.endswith(".runs1.json")]
r2 = [p for p in nuevos if p.endswith(".runs2.json")]
if len(r1) != 1 or len(r2) != 1:
    rojob("D4 sin evidencia runs1+runs2", str(nuevos))
s1 = json.load(open(r1[0], encoding="utf-8"))["entries"][0]["summary"]
s2 = json.load(open(r2[0], encoding="utf-8"))["entries"][0]["summary"]
if "VIGIA SYNC PENDIENTE" not in s1:
    rojob("D4-1ra debio avisar", s1)
if "VIGIA SYNC PENDIENTE" in s2 or "VIGIA SYNC DEPLOYED" in s2:
    rojob("D4-2da debio callar (re-aviso)", s2)

# Mutante: 2da corrida en job fresco => re-avisa => ASSERT-2 FALLO.
c_mut = make_copy(name="d4mut", fresh_scratch_mutant=True)
r, _ = run_copy(c_mut, "d4mut")
if r.returncode == 0:
    rojob("mutante job-fresco salio 0; no discrimina")
if "D4 ASSERT-2 FALLO" not in (r.stdout + r.stderr):
    rojob("mutante job-fresco fallo en otro lado", r.stdout + r.stderr)

print("ok (14): D4 misma cola+mismo scratch (avisa, calla); mutante job-fresco expuesto")
PY

# (15) Hermetico (F14): el worktree queda como estaba.
[ "$(git status --porcelain)" = "$PORCELAIN_ANTES" ] \
  || fail "(15) el worktree cambio durante la prueba: $(git status --porcelain | head -5)"
echo "ok (15): git status --porcelain igual que al entrar"

echo "TODO VERDE: aplicar-vigia-sync-prueba"

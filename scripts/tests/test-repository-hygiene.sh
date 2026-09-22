#!/bin/bash
# Regression de higiene del repo (Task 2 / 16.2, Step 1a).
#
# Lo generado/confidencial no se versiona: openclaw.json*, live-bus.env,
# tls/lego-data/**, agents/*/sessions/**, launchers generados y sus
# respaldos, arboles tablero-runbook.bak-*, tmp_* y logs/scripts
# incidentales confirmados. El retiro es solo del indice (sin history
# rewrite); el .gitignore impide que `git add -A` los resucite. El scan de
# secretos reporta archivo:linea sin imprimir jamas el contenido.
#
# Uso: bash scripts/tests/test-repository-hygiene.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
PYBIN=$(command -v python3 || command -v python) || fail "(0) sin python3 ni python en PATH"

TRACKED=$(mktemp) || exit 1
trap 'rm -f "$TRACKED"' EXIT
git ls-files >"$TRACKED" || fail "(0) git ls-files fallo"

# (0) Nada de lo enumerado sigue trackeado.
MAL=$(grep -E '(^|/)openclaw\.json[^/]*$|^live-bus\.env$|(^|/)tls/lego-data/|(^|/)agents/[^/]+/sessions/|(^|/)(gateway|node)\.(cmd|vbs)([^/]*)?$|\.bak[^/]*$|^tablero-runbook\.bak-[^/]*|^tmp_[^/]*$|^doctor-[^/]*\.log$|^doctor-fix-run\.ps1$|^scripts/restore-console\..*\.ps1$' "$TRACKED" || true)
[ -z "$MAL" ] || { printf '%s\n' "$MAL" | head -n 10 | sed 's/^/  /' >&2; fail "(0) basura trackeada (arriba, max 10)"; }
echo "ok (0): cero artefactos enumerados en el indice"

# (1) El .gitignore los cubre: check-ignore sobre cada ruta retirada.
while IFS= read -r ruta; do
  [ -n "$ruta" ] || continue
  git check-ignore -q "$ruta" 2>/dev/null \
    || fail "(1) $ruta no esta ignorada: un add -A la resucita"
done <<'RUTAS'
openclaw.json.broken-converttojson-20260919-024551
openclaw.json.clobbered.2026-09-19T06-45-52-223Z
live-bus.env
tls/lego-data/accounts/x/account.json
agents/main/sessions/x.jsonl
gateway.cmd
gateway.cmd.bak-pre-livebus
gateway.vbs
node.cmd
node.vbs
agents/implementer/agent/workshop-skills/s/SKILL.md.bak-20260912
gateway-watchdog.ps1.bak-20260921
tablero-runbook.bak-20260919-221133/x.ts
tmp_probe.txt
tmp_x.ps1
doctor-fix-20260910.log
doctor-fix-run.ps1
scripts/restore-console.pre-x.ps1
RUTAS
echo "ok (1): ignore cubre las 18 rutas retiradas"

# (2) Scan redactado de secretos sobre trackeados (texto, <=1MB).
"$PYBIN" - <<'PY' || exit 1
import re, subprocess, sys
# Literales partidos para que el allowlist no se delate a si mismo: el scan
# solo caza ocurrencias contiguas, y estas tuplas (archivo, texto) cubren
# fixtures falsos conocidos, nunca llaves reales en otro archivo.
allow = {
    ("scripts/tests/test-runtime-receipt.sh", "ghp_abcdefghi" + "jklmnopqrstuvwx" + "yza1B2"),
    ("scripts/tests/test-runtime-layout.sh", "ghp_abcdefghi" + "jklmnopqrstuvwx" + "yza1B2"),
    ("scripts/tests/test-runtime-receipt.sh", "-----BEGIN RSA PRIVATE " + "KEY-----"),
    ("scripts/tests/test-runtime-receipt.sh", "Bearer abcdef" + "ghijklmnop1234"),
    ("scripts/tests/test-skills-pr-ledger.sh", "ghp_abcdefghijk" + "lmnopqrstuvw" + "xyza1B2"),
    ("scripts/tests/test-runtime-cutover-transaction.sh", "sk-Test" + "CanaryCutover7"),
}
rx = re.compile(r"(?:gh[pousr]|github_pat)_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}"
                r"|xox[bpras]-[A-Za-z0-9-]+|bearer\s+[A-Za-z0-9._~+/-]{16,}={0,2}"
                r"|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----", re.I)
files = subprocess.run(["git", "ls-files", "-z"], capture_output=True, check=True,
                       text=True).stdout.split("\0")
mal = []
n = 0
for f in files:
    if not f:
        continue
    try:
        import os
        if os.path.getsize(f) > 1048576:
            continue
        with open(f, encoding="utf-8") as fh:
            for i, linea in enumerate(fh, 1):
                n += 1
                for m in rx.finditer(linea):
                    if (f, m.group(0)) in allow:
                        continue
                    mal.append(f"{f}:{i}")
    except (OSError, UnicodeDecodeError):
        continue
if mal:
    print("ROJO: (2) formas de secreto en trackeados (archivo:linea, sin contenido):")
    for x in mal[:15]:
        print(f"  {x}")
    print("  Retirar de HEAD y abrir decision de rotacion/historia con el dueno.")
    sys.exit(1)
print(f"ok (2): scan redactado limpio sobre {n} lineas", file=sys.stderr)
PY
echo "ok (2): scan redactado limpio"

# (3) Nota informativa (no bloquea): lo retirado persiste en historia; esta
# fase no reescribe historia por decision del plan.
cuenta=$(git log --all --oneline -- live-bus.env 'tls/lego-data/**' 'agents/*/sessions/**' openclaw.json.broken-converttojson-20260919-024551 2>/dev/null | wc -l | tr -d ' ')
echo "nota (3): historia conserva $cuenta commit(s) que tocan rutas sensibles retiradas (sin rewrite en esta fase)"

echo "TODO VERDE: repository-hygiene"

#!/usr/bin/env bash
# Un fallo al guardar un evento no debe corromper el ultimo progreso valido.
set -u
cd "$(dirname "$0")/../.." || exit 1
runbook=$PWD/docs/runbooks/autopilot-fase17.md
tmp_progress=$(mktemp -d) || exit 1
trap 'chmod 0700 "$tmp_progress/.saikit/progress" 2>/dev/null; rm -r "$tmp_progress"' EXIT
mkdir -p "$tmp_progress/.saikit/progress" || exit 1
progress=$tmp_progress/.saikit/progress/17.json
printf '%s\n' '{"eventos":[],"estado":"valido"}' > "$progress" || exit 1
chmod 0600 "$progress" || exit 1
chmod 0500 "$tmp_progress/.saikit/progress" || exit 1

out=$(
  {
    awk '/^  python3 - <<.PY./{capture=1} capture {print; if ($0=="PY") exit}' "$runbook"
    printf '%s\n' 'printf "CONTINUO_TRAS_FALLO\\n"'
  } | (cd "$tmp_progress" && bash) 2>&1
)
rc=$?
chmod 0700 "$tmp_progress/.saikit/progress" || exit 1
[ "$rc" -ne 0 ] || { printf 'FAIL: continuo tras fallo al guardar evento\n' >&2; exit 1; }
case "$out" in
  *CONTINUO_TRAS_FALLO*) printf 'FAIL: el bloque siguio tras el fallo\n' >&2; exit 1 ;;
esac
[ "$(cat "$progress")" = '{"eventos":[],"estado":"valido"}' ] || {
  printf 'FAIL: el progreso valido fue modificado\n' >&2
  exit 1
}

awk '/^  python3 - <<.PY./{capture=1} capture {print; if ($0=="PY") exit}' "$runbook" |
  (cd "$tmp_progress" && bash) || exit 1
python3 - "$progress" <<'PY' || exit 1
import json
import pathlib
import stat
import sys

p = pathlib.Path(sys.argv[1])
doc = json.loads(p.read_text(encoding='utf-8'))
assert doc['estado'] == 'valido'
assert len(doc['eventos']) == 1
assert doc['eventos'][0]['que'] == 'publicación inicial de progreso falló; reintentar en el siguiente cambio de estado'
assert stat.S_IMODE(p.stat().st_mode) == 0o600
PY
printf 'VERDE: un fallo de escritura conserva el progreso y detiene el arranque\n'

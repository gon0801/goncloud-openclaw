#!/usr/bin/env bash
# La apertura de Fase 17 usa un evento durable y no pisa la proyección previa.
set -u
cd "$(dirname "$0")/../.." || exit 1
runbook=$PWD/docs/runbooks/autopilot-fase17.md
client=$PWD/scripts/mac/progress-events.py
for action in 'queue-event --event-json' 'publish --corrida' 'sync --corrida'; do
  grep -qF "$action" "$runbook" || { echo "FAIL: falta $action" >&2; exit 1; }
done
if grep -qF 'runbook.progress.set' "$runbook"; then
  echo 'FAIL: la corrida nueva usa escritura completa obsoleta' >&2
  exit 1
fi
tmp_progress=$(mktemp -d) || exit 1
trap 'rm -r "$tmp_progress"' EXIT
mkdir -p "$tmp_progress/.saikit/progress" || exit 1
progress=$tmp_progress/.saikit/progress/17.json
event=$tmp_progress/.saikit/progress/17-opened.event.json
printf '%s\n' '{"estado":"valido"}' > "$progress" || exit 1
printf '%s\n' 'sin modificar' > "$tmp_progress/foreign" || exit 1

opening=$(awk '/^python3 - <<.PY./{capture=1} capture {print; if ($0=="PY") exit}' "$runbook")
[ -n "$opening" ] || { echo 'FAIL: falta bloque de apertura' >&2; exit 1; }
ln -s "$tmp_progress/foreign" "$event" || exit 1
out=$(printf '%s\nprintf "CONTINUO_TRAS_FALLO\\n"\n' "$opening" | (cd "$tmp_progress" && bash) 2>&1)
rc=$?
[ "$rc" -ne 0 ] || { echo 'FAIL: continuo tras ruta insegura' >&2; exit 1; }
case "$out" in
  *CONTINUO_TRAS_FALLO*) echo 'FAIL: el bloque siguio tras fallo' >&2; exit 1 ;;
esac
[ "$(cat "$progress")" = '{"estado":"valido"}' ] || {
  echo 'FAIL: la proyección previa fue modificada' >&2
  exit 1
}
[ "$(cat "$tmp_progress/foreign")" = 'sin modificar' ] || {
  echo 'FAIL: el destino del enlace fue modificado' >&2
  exit 1
}

rm "$event" || exit 1
for attempt in 1 2; do
  printf '%s\n' "$opening" | (cd "$tmp_progress" && bash) || exit 1
  python3 "$client" --state-dir "$tmp_progress/client" queue-event --event-json "$event" >/dev/null || exit 1
done
python3 - "$tmp_progress" <<'PY' || exit 1
import json
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
event = json.loads((root / '.saikit/progress/17-opened.event.json').read_text())
assert event['kind'] == 'run.opened'
assert event['id'] == 'fase17-opened-v1'
assert event['corrida'] == event['doc']['corrida'] == 'fase17-centro-tareas'
assert event['phaseAlias'] is True
assert event['roundBudget'] == {'A': 2, 'B': 2, 'C': 2, 'D': 2}
queue = list((root / 'client/runs/fase17-centro-tareas/queue').glob('*.json'))
assert len(queue) == 1 and json.loads(queue[0].read_text()) == event
assert stat.S_IMODE((root / '.saikit/progress/17-opened.event.json').stat().st_mode) == 0o600
assert (root / '.saikit/progress/17.json').read_text() == '{"estado":"valido"}\n'
PY
printf 'VERDE: apertura segura, durable e idempotente; proyección previa intacta\n'

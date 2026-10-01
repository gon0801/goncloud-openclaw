#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  baseline) ;;
  *) printf 'Unknown or unimplemented agent-work runtime case: %s\n' "${1:-}" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
map_file="$repo_root/docs/evidence/agent-work/runtime-map.json"
source_root="${AGENT_WORK_RUNTIME_SOURCE:-$(python3 - "$map_file" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['runtime']['localCheckout'])
PY
)}"
python3 - "$map_file" "$source_root" <<'PY'
import hashlib, json, pathlib, subprocess, sys
m = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2]).resolve()
assert (root / '.git').exists(), f'No source checkout: {root}'
base = m['runtime']['sourceBaseSha']
subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', base, 'HEAD'], check=True)
for path in m['paths'].values():
    assert (root / path).is_file(), f'Mapped path missing: {path}'
package = json.loads((root / 'package.json').read_text())
assert package['version'] == m['runtime']['sourceVersion']
head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
diff = subprocess.check_output(['git', '-C', str(root), 'diff', '--binary', 'HEAD'])
print(json.dumps({'candidateSha': head, 'candidateDiffSha256': hashlib.sha256(diff).hexdigest()}, sort_keys=True), flush=True)
PY
cd "$source_root"
node scripts/run-vitest.mjs src/gateway/agent-turn/agent-wait-dedupe.test.ts
AGENT_WORK_RUNTIME_SOURCE="$source_root" python3 "$repo_root/scripts/agent-work/probe-native-restart.py"

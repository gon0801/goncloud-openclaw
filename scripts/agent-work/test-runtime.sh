#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
case "$case_name" in
  baseline) test_file='src/gateway/agent-turn/agent-wait-dedupe.test.ts'; test_pattern=''; probe_restart=1 ;;
  registration_identity)
    test_file='src/agents/tasks/managed-task.store.test.ts'
    test_pattern='deduplicates a logical key|deduplicates director retries'
    probe_restart=0 ;;
  result_receipt)
    test_file='src/agents/tasks/managed-task.store.test.ts'
    test_pattern='accepts only the current producer|does not store malformed JSON|rejects an empty or unversioned review|persists PermissionRequired'
    probe_restart=0 ;;
  admission_restart)
    test_file='src/agents/tasks/managed-task.admission.test.ts'
    test_pattern=''
    probe_restart=0 ;;
  requester_queue)
    test_file='src/agents/subagents/registry/subagent-registry.requester-wake.e2e.test.ts'
    test_pattern="restores a managed collector's requester wake after restart"
    probe_restart=0 ;;
  handling_atomic)
    test_file='src/agents/tasks/managed-task.handling.test.ts'
    test_pattern='commits one decision, child, and receipt|rolls back the whole decision|rejects extra children atomically'
    probe_restart=0 ;;
  handling_unresolved)
    test_file='src/agents/tasks/managed-task.handling.test.ts'
    test_pattern='keeps a result pending across agent_end|archives a result received after cancellation|preserves an uncertain external effect'
    probe_restart=0 ;;
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
if [ -n "$test_pattern" ]; then
  node scripts/run-vitest.mjs "$test_file" --testNamePattern "$test_pattern"
else
  node scripts/run-vitest.mjs "$test_file"
fi
if [ "$probe_restart" -eq 1 ]; then
  AGENT_WORK_RUNTIME_SOURCE="$source_root" python3 "$repo_root/scripts/agent-work/probe-native-restart.py"
fi

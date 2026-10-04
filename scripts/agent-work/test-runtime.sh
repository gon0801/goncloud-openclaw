#!/usr/bin/env bash
set -euo pipefail

case_name="${1:-}"
extra_test_files=()
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
    test_file='src/gateway/server.managed-task-requester.e2e.test.ts'
    extra_test_files=('src/agents/subagents/registry/subagent-registry.requester-wake.e2e.test.ts')
    test_pattern='restart: true|does not deliver an unreported managed result after restart \((busy|deleted) requester\)'
    probe_restart=0 ;;
  handling_atomic)
    test_file='src/agents/tasks/managed-task.handling.test.ts'
    test_pattern='commits one decision, child, and receipt|rolls back the whole decision|rejects extra children atomically'
    probe_restart=0 ;;
  handling_unresolved)
    test_file='src/agents/tasks/managed-task.handling.test.ts'
    test_pattern='keeps a result pending across agent_end|archives a result received after cancellation|serializes cancellation against a competing continuation|preserves an uncertain external effect'
    probe_restart=0 ;;
  idle_72h)
    test_file='src/agents/subagents/registry/subagent-registry.requester-wake.e2e.test.ts'
    test_pattern="does not deliver an unreported managed result after restart \(idle_72h requester\)"
    probe_restart=0 ;;
  projection_gateway)
    test_file='src/gateway/server-methods/managed-tasks.test.ts'
    test_pattern='serves and acknowledges a durable projection over an authenticated Gateway connection'
    probe_restart=0 ;;
  resource_release)
    test_file='src/agents/tasks/managed-task.host-closure.test.ts'
    test_pattern=''
    probe_restart=0 ;;
  budget_tree)
    test_file='src/agents/tasks/managed-task.budget.test.ts'
    test_pattern='shares model-call capacity across children|holds uncertain call capacity across retries and restart|allows one automatic recovery call per root'
    probe_restart=0 ;;
  budget_context)
    test_file='src/agents/tasks/managed-task.budget.test.ts'
    test_pattern='rejects incomplete runtime budget and context shapes|counts context components once|retains full reservation when terminal provider usage is absent'
    probe_restart=0 ;;
  budget_evasion)
    test_file='src/agents/tasks/managed-task.native-report.test.ts'
    test_pattern='keeps root creation within the managed run lifetime'
    probe_restart=0 ;;
  waiting_reason)
    test_file='src/agents/tasks/managed-task.admission.test.ts'
    extra_test_files=('src/agents/tasks/managed-task.store.test.ts' 'src/agents/tasks/managed-task.provider-stream.test.ts')
    test_pattern='lets one emitter claim, keeps a crash uncertain|does not store malformed JSON|persists a transport wait when the reserved HTTP request loses its connection'
    probe_restart=0 ;;
  recovery_limit)
    test_file='src/agents/tasks/managed-task.budget.test.ts'
    extra_test_files=('src/agents/tasks/managed-task.provider-stream.test.ts')
    test_pattern='allows one automatic recovery call per root|blocks an SDK Responses retry before its second HTTP dispatch'
    probe_restart=0 ;;
  recovery_queue)
    test_file='src/agents/tasks/managed-task.recovery.test.ts'
    extra_test_files=('src/agents/tasks/managed-task.recovery.siblings.test.ts')
    test_pattern=''
    probe_restart=0 ;;
  delegation_bypass)
    test_file='src/agents/tools/sessions-managed-delegation.test.ts'
    test_pattern='rejects sessions_spawn before any child is created|rejects sessions_send before Gateway delivery|does not apply the managed guard to an ordinary run'
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
if [ "$case_name" = projection_gateway ]; then
  if [ ! -f dist/entry.js ]; then
    printf 'Build the isolated OpenClaw CLI before projection_gateway\n' >&2
    exit 2
  fi
  export AGENT_WORK_G_ROOT="$repo_root"
fi
if [ -n "$test_pattern" ]; then
  node scripts/run-vitest.mjs "$test_file" "${extra_test_files[@]}" --testNamePattern "$test_pattern"
else
  node scripts/run-vitest.mjs "$test_file" "${extra_test_files[@]}"
fi
if [ "$probe_restart" -eq 1 ]; then
  AGENT_WORK_RUNTIME_SOURCE="$source_root" python3 "$repo_root/scripts/agent-work/probe-native-restart.py"
fi

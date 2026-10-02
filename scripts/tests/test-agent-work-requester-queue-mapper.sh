#!/usr/bin/env bash
# Verifica que requester_queue seleccione los títulos vigentes sin iniciar Vitest.
set -euo pipefail
cd "$(dirname "$0")/../.."
mapper="${1:-scripts/agent-work/test-runtime.sh}"

set -- requester_queue
# El mapeo termina antes de repo_root; el resto valida checkout y ejecuta Vitest.
source <(awk '/^repo_root=/{exit} {print}' "$mapper")
export TEST_FILE="$test_file" TEST_PATTERN="$test_pattern"
export TEST_EXTRAS="${extra_test_files[*]}"

python3 - <<'PY'
import json, os, pathlib, re

repo = pathlib.Path.cwd()
runtime = pathlib.Path(os.environ.get("AGENT_WORK_RUNTIME_SOURCE") or
    json.loads((repo / "docs/evidence/agent-work/runtime-map.json").read_text())["runtime"]["localCheckout"])
primary = os.environ["TEST_FILE"]
extras = os.environ["TEST_EXTRAS"].split()
assert primary == "src/gateway/server.managed-task-requester.e2e.test.ts", primary
assert extras == ["src/agents/subagents/registry/subagent-registry.requester-wake.e2e.test.ts"], extras
gateway_template = "registers, admits, reports, and resolves a managed task through the authenticated Gateway ($requesterAgentId -> $targetAgentId, isolated: $isolatedSession, restart: $restartAfterResult, replay: $replayAfterTurnStart)"
managed_template = "does not deliver an unreported managed result after restart (%s requester)"
if runtime.exists():
    gateway = (runtime / primary).read_text()
    collector = (runtime / extras[0]).read_text()
    support = (runtime / "src/agents/subagents/registry/subagent-registry.requester-wake.managed.test-support.ts").read_text()
    assert gateway_template in gateway and gateway.count("restartAfterResult: true") >= 2
    assert 'registerManagedRequesterQueueTests' in collector
    assert managed_template in support and 'it.each(["idle", "deleted", "busy", "idle_72h"]' in support
gateway_restart = gateway_template.replace("$requesterAgentId", "ingenieria").replace("$targetAgentId", "adversary").replace("$isolatedSession", "false").replace("$restartAfterResult", "true").replace("$replayAfterTurnStart", "undefined")
pattern = re.compile(os.environ["TEST_PATTERN"])
assert pattern.search(gateway_restart), gateway_restart
assert not pattern.search(gateway_restart.replace("restart: true", "restart: false"))
for state in ("busy", "deleted"):
    assert pattern.search(managed_template.replace("%s", state)), state
for state in ("idle", "idle_72h"):
    assert not pattern.search(managed_template.replace("%s", state)), state
assert not pattern.search("restores a managed collector's requester wake after restart")
print("ok: requester_queue selecciona Gateway restart y busy/deleted; excluye título retirado")
PY

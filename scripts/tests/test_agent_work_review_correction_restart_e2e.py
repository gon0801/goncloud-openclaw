#!/usr/bin/env python3
"""review_correction_restart: a review with changes reaches the requester after a Gateway crash.

The requester's model (the harness provider, scripted) wakes on the durable result,
inspects it and resolves with one correction child. Nobody reminds it: the test never
calls inspect or resolve itself after the restart.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager  # noqa: E402
from routing import prepare_request  # noqa: E402
from spool import atomic_json  # noqa: E402
from test_agent_work_cli_gateway_e2e import FakeCliSession  # noqa: E402
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    ADAPTER, CLI_SESSION, HOST_ID, INSTANCE, LoopGateway, built_runtime, certified_coverage,
    loop_route, wait_for)

SCRIPTED = {"CROSS_TOOLS_PROFILE": "full", "CROSS_PROVIDER_SCRIPT": "review-correction"}
REVIEWED_SHA = "a" * 40


class ReviewCorrectionRestartE2E(unittest.TestCase):
    def test_changes_after_a_gateway_crash_register_one_correction_without_a_reminder(self):
        runtime = built_runtime(self)
        with tempfile.TemporaryDirectory(prefix="agent-work-review-restart-") as temporary:
            root = Path(temporary)
            first = LoopGateway(runtime, root, extra_env=SCRIPTED)
            _, certified = certified_coverage()
            host = Host(HOST_ID, root / "host")
            backend = FakeCliSession()
            manager = ResourceManager(host.spool, HOST_ID, backend)
            delivered = []

            def fake_cli(assignment_ref, session):
                operation = json.loads(Path(assignment_ref).read_text())
                delivered.append(operation)
                atomic_json(Path(operation["acceptRef"]), {
                    "schema": "agent-work.accept.v1", **{field: operation[field] for field in (
                        "hostId", "taskId", "generation", "instanceId", "claimId", "capability")}})

            try:
                request = prepare_request(coverage=certified, **loop_route(root, first.state_dir))
                with mock.patch.dict(os.environ, first.env):
                    task_id = first.tool("submit", request, "loop-submit-turn")["taskId"]
                    first.tool("admit", {"taskId": task_id, "admissionKey": "review-attempt"},
                               "loop-admit-turn")
                    client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), HOST_ID, first.url)
                    claimed = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                             instance_id=INSTANCE, session=CLI_SESSION,
                                             workspace_root=root / "workspace", deliver=fake_cli,
                                             coverage=certified)
                    self.assertEqual(claimed.status, "delivered")
            finally:
                first.kill()

            second = LoopGateway(runtime, root, reuse_state=True, extra_env=SCRIPTED)
            try:
                self.assertNotEqual(second.pid, first.pid, "the Gateway did not restart")
                before = second.call("tasks")
                self.assertEqual([(task["taskId"], task["hasResult"]) for task in before["tasks"]],
                                 [(task_id, False)], "the restart lost or changed the task")
                operation = delivered[0]
                findings = root / "workspace" / "findings.txt"
                findings.write_text("VEREDICTO cambios: falta la prueba del borde\n")
                atomic_json(Path(operation["resultRef"]), {
                    "schema": "agent-work.result.v1", "kind": "produced",
                    "hostId": operation["hostId"], "taskId": operation["taskId"],
                    "generation": operation["generation"], "instanceId": operation["instanceId"],
                    "producerId": operation["producerId"], "capability": operation["capability"],
                    "observedRevision": operation["inputRevision"],
                    "typedPayload": {"verdict": "changes", "findingsRef": "findings.txt"},
                    "artifactRef": str(findings),
                    "digest": hashlib.sha256(findings.read_bytes()).hexdigest(),
                })
                with mock.patch.dict(os.environ, second.env):
                    client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), HOST_ID, second.url)
                    self.assertEqual(len(host.flush(HOST_ID, client.report_host_result)), 1)

                rows = wait_for(lambda: (lambda value: value if value["handlings"] else None)(
                    second.call("tasks")), 60)
                self.assertTrue(rows, f"the requester never resolved; provider: {second.provider_requests()}")
                time.sleep(10)
                rows = second.call("tasks")
                self.assertEqual(rows["handlings"], [task_id])
                self.assertEqual([(c["parentTaskId"], c["slot"]) for c in rows["children"]],
                                 [(task_id, "corregir")])
                child = rows["children"][0]["childTaskId"]
                contracts = {task["taskId"]: task["resultContract"] for task in rows["tasks"]}
                self.assertEqual(contracts, {task_id: "review.v1", child: "ready.v1"})
                reviews = [task["taskId"] for task in rows["tasks"]
                           if task["resultContract"] == "review.v1"
                           and task["inputRevision"].get("sha") == REVIEWED_SHA]
                self.assertEqual(reviews, [task_id], "a new review of the same SHA was registered")
                answered = [request["answered"] for request in second.provider_requests()]
                self.assertEqual(second.provider_requests()[0]["wakeTasks"], [task_id],
                                 "the requester acted before its durable wake")
                self.assertEqual(answered, ["managed_tasks_inspect", "managed_tasks_resolve", "message"])
                offered = second.provider_requests()[0]["toolNames"]
                self.assertIn("managed_tasks_resolve", offered)
                print(f"REVIEW_CORRECTION_RESTART pid1={first.pid} pid2={second.pid} "
                      f"handlings={len(rows['handlings'])} children={len(rows['children'])} "
                      f"provider={answered}", flush=True)
            finally:
                second.close()


if __name__ == "__main__":
    unittest.main()

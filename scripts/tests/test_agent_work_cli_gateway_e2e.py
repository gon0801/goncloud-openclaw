#!/usr/bin/env python3
"""Native requester -> authenticated Gateway -> G host, without CLI hooks."""

import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from contracts import OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager  # noqa: E402
from spool import atomic_json  # noqa: E402

FIXTURE = ROOT / "scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs"


class FakeCliSession:
    boot_id = "fixture-boot"

    def __init__(self):
        self.live = {"fixture-worker": {"bootId": self.boot_id, "nonce": "",
                                         "sessionName": "fixture-worker"}}
        self.stops = []
        self.revocations = []

    def mark(self, session, nonce):
        current = self.live.get(session)
        if current and current["nonce"] not in ("", nonce):
            raise ValueError("fixture session ownership conflict")
        self.live[session] = {"bootId": self.boot_id, "nonce": nonce, "sessionName": session}

    def observe(self, session):
        return self.live.get(session)

    def stop(self, identity):
        self.stops.append(identity)
        return False

    def revoke(self, identity):
        if self.observe(identity["sessionName"]) != identity:
            return False
        self.revocations.append(identity)
        self.live[identity["sessionName"]] = {**identity, "nonce": ""}
        return True


class NativeCliGatewayE2E(unittest.TestCase):
    def test_requester_claim_brief_delivery_report_and_blocked_replay(self):
        source = os.environ.get("AGENT_WORK_RUNTIME_SOURCE")
        if not source:
            self.skipTest("set AGENT_WORK_RUNTIME_SOURCE to a built R checkout")
        runtime = Path(source).resolve()
        stamp = json.loads((runtime / "dist/.buildstamp").read_text())
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=runtime, text=True).strip()
        self.assertEqual(stamp["head"], head, "R buildstamp is stale for this checkout")
        for required in ("openclaw.mjs", "scripts/tsx.mjs", "src/gateway/test-helpers.e2e.ts"):
            self.assertTrue((runtime / required).is_file(), f"R source missing {required}")

        with tempfile.TemporaryDirectory(prefix="agent-work-cli-gateway-") as temporary:
            root = Path(temporary)
            gateway_state = root / "gateway"
            gateway_state.mkdir()
            token = "cross-cli-isolated-token"
            env = {**os.environ, "AGENT_WORK_RUNTIME_SOURCE": str(runtime),
                   "OPENCLAW_STATE_DIR": str(gateway_state),
                   "OPENCLAW_CONFIG_PATH": str(gateway_state / "openclaw.json"),
                   "OPENCLAW_GATEWAY_TOKEN": token, "CROSS_GATEWAY_TOKEN": token}
            harness = subprocess.Popen(
                ["node", "--import", str(runtime / "scripts/tsx.mjs"), str(FIXTURE)],
                cwd=runtime, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1,
            )
            output = queue.Queue()
            logs = []

            def collect():
                for line in harness.stdout:
                    logs.append(line)
                    output.put(line)

            threading.Thread(target=collect, daemon=True).start()

            def message():
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    try:
                        line = output.get(timeout=1)
                    except queue.Empty:
                        if harness.poll() is not None:
                            break
                        continue
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if value.get("type") in ("ready", "result", "error"):
                        self.assertNotEqual(value["type"], "error", value.get("error"))
                        return value
                self.fail("R Gateway fixture stopped or timed out: " + "".join(logs)[-4000:])

            def request(action, args, run_id):
                harness.stdin.write(json.dumps({"op": "tool", "action": action,
                                                "args": args, "runId": run_id}) + "\n")
                harness.stdin.flush()
                return message()["result"]

            try:
                ready = message()
                self.assertEqual(ready["type"], "ready")
                client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), "e2e-host", ready["url"])
                host = Host("e2e-host", root / "host")
                backend = FakeCliSession()
                manager = ResourceManager(host.spool, "e2e-host", backend)
                brief = b"Review the fixture change and return one verdict.\n"
                assignment = {
                    "target": {"kind": "cli", "hostId": "e2e-host", "adapterId": "codex"},
                    "instructionRef": {"ref": "artifact:fixture-source",
                                       "digest": "sha256:" + hashlib.sha256(brief).hexdigest()},
                    "inputRevision": {"kind": "code", "repository": "fixture",
                                      "sha": "a" * 40},
                    "resultContract": "review.v1", "continuation": {"kind": "requester"},
                }
                with mock.patch.dict(os.environ, env):
                    submitted = request("submit", {"key": "cross-cli-review",
                                                   "assignment": assignment}, "submit-turn")
                    task_id = submitted["taskId"]
                    self.assertEqual(submitted["state"], "registered")
                    admitted = request("admit", {"taskId": task_id,
                                                 "admissionKey": "cross-cli-attempt"}, "admit-turn")
                    self.assertEqual(admitted["state"], "host-pending")
                    deliveries = []

                    def fake_cli(assignment_ref, session):
                        operation = json.loads(Path(assignment_ref).read_text())
                        artifact = root / "workspace" / "review.txt"
                        artifact.write_text("VEREDICTO aprobado\n")
                        result = {
                            "schema": "agent-work.result.v1", "kind": "produced",
                            "hostId": operation["hostId"], "taskId": operation["taskId"],
                            "generation": operation["generation"],
                            "instanceId": operation["instanceId"],
                            "producerId": operation["producerId"],
                            "capability": operation["capability"],
                            "observedRevision": operation["inputRevision"],
                            "typedPayload": {"verdict": "approved", "evidenceRef": "review.txt"},
                            "artifactRef": str(artifact),
                            "digest": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                        }
                        atomic_json(Path(operation["resultRef"]), result)
                        deliveries.append((operation["taskId"], session))

                    dispatch = dict(host=host, manager=manager, adapter_id="codex",
                                    instance_id="fixture-instance", session="fixture-worker",
                                    workspace_root=root / "workspace", deliver=fake_cli,
                                    coverage={"hostAdapterCoverage": {
                                        "e2e-host": {"codex": "certified"}}})
                    first = claim_cli_once(client, **dispatch)
                    replay = claim_cli_once(client, **dispatch)
                    self.assertEqual(first.status, "delivered")
                    self.assertEqual(replay.status, "delivered")
                    self.assertEqual(deliveries, [(task_id, "fixture-worker")])
                    self.assertEqual(manager.counts()["active"], 1)
                    receipts = host.flush("e2e-host", client.report_host_result)
                    self.assertEqual(len(receipts), 1)
                    self.assertEqual(host.flush("e2e-host", client.report_host_result), [])
                    key = OperationKey("e2e-host", task_id, receipts[0]["generation"],
                                       "fixture-instance")
                    closed = manager.close(key, {"kind": "result", "receipt": receipts[0]["receiptId"]})
                    self.assertEqual(closed.state, "ReleasedAdopted")
                    self.assertEqual(backend.stops, [])
                    self.assertEqual(len(backend.revocations), 1)
                    self.assertIsNotNone(backend.observe("fixture-worker"))
                    snapshot = request("inspect", {"taskId": task_id}, "inspect-turn")
                    self.assertEqual(snapshot["handlingState"], "pending-handling")
                    self.assertEqual(snapshot["result"]["payload"]["verdict"], "approved")
                    decision = {"kind": "blocked", "reason": "fixture-review-complete"}
                    resolved = request("resolve", {"receipt": snapshot["resultReceipt"],
                                                   "decision": decision}, "resolve-turn")
                    repeat = request("resolve", {"receipt": snapshot["resultReceipt"],
                                                 "decision": decision}, "resolve-replay-turn")
                    self.assertEqual(resolved, repeat)
                    final = request("inspect", {"taskId": task_id}, "final-inspect-turn")
                    self.assertEqual(final["handlingState"], "handled")
                    self.assertEqual(final["handlingDecision"], decision)
                    self.assertEqual(deliveries, [(task_id, "fixture-worker")])
                    print("CLI_GATEWAY_E2E submit=1 admit=1 delivery=1 report=1 blocked=1", flush=True)
            finally:
                if harness.poll() is None:
                    try:
                        harness.stdin.write('{"op":"stop"}\n')
                        harness.stdin.flush()
                        harness.wait(timeout=30)
                    except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
                        harness.terminate()
                        harness.wait(timeout=5)
                harness.stdin.close()
                harness.stdout.close()


if __name__ == "__main__":
    unittest.main()

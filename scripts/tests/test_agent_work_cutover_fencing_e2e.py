#!/usr/bin/env python3
"""T11 :298 cutover_fencing against the real R Gateway: an old cron is drained, never cancelled,
never asks again, and ownership moves to the native route by generation only with one emitter."""
import hashlib
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    ADAPTER, CLI_SESSION, HOST_ID, INSTANCE, LoopGateway, built_runtime, certified_coverage, loop_route, wait_for)
from test_agent_work_cli_gateway_e2e import FakeCliSession  # noqa: E402
import cutover_live  # noqa: E402
from contracts import OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager  # noqa: E402
from routing import prepare_request  # noqa: E402
from spool import Spool, atomic_json  # noqa: E402

EVERY_MS = 3000
CRON = "vigia-viejo"


class HarnessClient:
    def __init__(self, gateway):
        self.gateway = gateway

    def call(self, method, params):
        return self.gateway.call("rpc", method=method, params=params)


class CutoverFencingE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        self.temp = tempfile.TemporaryDirectory(prefix="agent-work-cutover-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # The repo profile keeps maxContextTokens unknown; a rehearsal opens with a measured stand-in.
        limits = json.loads((ROOT / "docs/evidence/agent-work/limits.json").read_text())
        limits["productionProfile"]["values"]["maxContextTokens"] = 2_000_000
        self.limits = self.root / "rehearsal-limits.json"
        self.limits.write_text(json.dumps(limits))

    def start(self, managed_enabled, adapter=ADAPTER):
        gateway = LoopGateway(self.runtime, self.root, extra_env={
            "CROSS_CRON_ENABLED": "1", "CROSS_MANAGED_ENABLED": "1" if managed_enabled else "0"})
        self.addCleanup(gateway.close)
        job = gateway.call("rpc", method="cron.add", params={
            "name": CRON, "agentId": "main", "enabled": True,
            "schedule": {"kind": "every", "everyMs": EVERY_MS},
            "sessionTarget": "isolated", "wakeMode": "now",
            "payload": {"kind": "agentTurn", "message": f"cutover-cron-{CRON} look at the loop"},
            "delivery": {"mode": "none"}})
        self.spool = Spool(self.root / "host-spool", HOST_ID)
        (self.root / "host").mkdir(exist_ok=True)
        entry = {"id": "loop:encargos", "legacyCrons": [CRON], "host": HOST_ID, "adapter": adapter,
                 "spools": [str(self.root / "host-spool"), str(self.root / "host")]}
        self.state = self.root / "cutover-state.json"
        cutover_live.prepare(self.state, entry)
        return gateway, job["id"], HarnessClient(gateway)

    def cron(self, client):
        jobs = client.call("cron.list", {"includeDisabled": True})["jobs"]
        return next(job for job in jobs if job["name"] == CRON)

    def marked_requests(self, gateway, since_ms=0):
        return [request for request in gateway.provider_requests()
                if CRON in request.get("cronMarkers", []) and request["at"] >= since_ms]

    def test_two_emitters_never_transfer(self):
        gateway, _, client = self.start(managed_enabled=True)
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "two emitters for loop:encargos"):
            cutover_live.apply(self.state, client, now_ms=lambda: int(time.time() * 1000), limits_path=self.limits)
        self.assertTrue(self.cron(client)["enabled"])
        self.assertEqual(json.loads(self.state.read_text())["generation"], 1)

    def test_an_in_flight_turn_is_drained_then_the_old_cron_never_asks_again(self):
        gateway, job_id, client = self.start(managed_enabled=False)
        gateway.call("hold", marker=CRON)
        self.assertTrue(wait_for(lambda: self.marked_requests(gateway), 30), "the old cron never ran")
        now = lambda: int(time.time() * 1000)  # noqa: E731
        with self.assertRaisesRegex(cutover_live.CutoverRefused, f"{CRON} has a turn in flight"):
            cutover_live.apply(self.state, client, now_ms=now, limits_path=self.limits)
        self.assertTrue(self.cron(client)["enabled"], "a refused cutover must not touch the cron")
        gateway.call("release")
        result = cutover_live.apply(self.state, client, now_ms=now, wait_seconds=30, limits_path=self.limits)
        state = json.loads(self.state.read_text())
        self.assertEqual((result, state["owner"], state["generation"]), ("transferred", "native", 2))
        suspended_at = state["suspended"][job_id]["disabledAtMs"]
        self.assertFalse(self.cron(client)["enabled"])
        cancelled = [run for run in client.call("cron.runs", {"id": job_id})["entries"]
                     if "disabled by operator" in (run.get("error") or "")]
        self.assertEqual(cancelled, [], "the in-flight turn was cancelled instead of drained")
        time.sleep(3 * EVERY_MS / 1000)
        self.assertEqual(self.marked_requests(gateway, since_ms=suspended_at), [])
        self.assertEqual([run for run in client.call("cron.runs", {"id": job_id})["entries"]
                          if run["ts"] > suspended_at], [])
        managed = client.call("config.get", {})["resolved"]["managedTasks"]
        self.assertEqual((managed["enabled"], managed["hosts"][HOST_ID]["adapters"]), (True, [ADAPTER]))

    def test_an_uncertain_admission_blocks_the_transfer(self):
        gateway, _, client = self.start(managed_enabled=False)
        operation = {"taskId": "task-uncertain", "generation": 1}
        self.spool.register("op-uncertain", "instance-uncertain", "digest", "assignment:x", operation)
        self.assertTrue(self.spool.begin_delivery("op-uncertain"))
        self.assertTrue(self.spool.delivery_uncertain("op-uncertain", "task-uncertain", "incident",
                                                      "{}", "incident-digest"))
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "uncertain admission task-uncertain"):
            cutover_live.apply(self.state, client, now_ms=lambda: int(time.time() * 1000), wait_seconds=10, limits_path=self.limits)
        self.assertEqual(json.loads(self.state.read_text())["owner"], "legacy")

    def test_adoption_keeps_the_cli_session_and_delivers_a_result_captured_across_it(self):
        gateway, _, client = self.start(managed_enabled=True, adapter="codex")
        coverage, certified = certified_coverage()
        request = prepare_request(coverage=certified, **loop_route(self.root, gateway.state_dir))
        projection = GatewayProjectionClient(str(self.runtime / "openclaw.mjs"), HOST_ID, gateway.url)
        host = Host(HOST_ID, self.root / "host")
        backend = FakeCliSession()
        manager = ResourceManager(host.spool, HOST_ID, backend)
        with mock.patch.dict(os.environ, gateway.env):
            task_id = gateway.tool("submit", request, "cutover-submit-turn")["taskId"]
            gateway.tool("admit", {"taskId": task_id, "admissionKey": "cutover-attempt"}, "cutover-admit-turn")
            delivered = []

            def fake_cli(assignment_ref, session):
                operation = json.loads(Path(assignment_ref).read_text())
                delivered.append(operation)
                atomic_json(Path(operation["acceptRef"]), {
                    "schema": "agent-work.accept.v1", **{field: operation[field] for field in (
                        "hostId", "taskId", "generation", "instanceId", "claimId", "capability")}})

            first = claim_cli_once(projection, host=host, manager=manager, adapter_id=ADAPTER,
                                   instance_id=INSTANCE, session=CLI_SESSION,
                                   workspace_root=self.root / "workspace", deliver=fake_cli,
                                   coverage=certified)
            self.assertEqual(first.status, "delivered")
            operation = delivered[0]
            artifact = self.root / "workspace" / "review.txt"
            artifact.write_text("VEREDICTO aprobado\n")
            atomic_json(Path(operation["resultRef"]), {
                "schema": "agent-work.result.v1", "kind": "produced",
                "hostId": operation["hostId"], "taskId": operation["taskId"],
                "generation": operation["generation"], "instanceId": operation["instanceId"],
                "producerId": operation["producerId"], "capability": operation["capability"],
                "observedRevision": operation["inputRevision"],
                "typedPayload": {"verdict": "approved", "evidenceRef": "review.txt"},
                "artifactRef": str(artifact), "digest": hashlib.sha256(artifact.read_bytes()).hexdigest()})
            key = OperationKey(HOST_ID, task_id, operation["generation"], INSTANCE)
            host.take_acceptance(HOST_ID, key)
            host.collect(HOST_ID, key)
            self.assertEqual([result["taskId"] for result in host.pending(HOST_ID)], [task_id])
            session_before = backend.observe(CLI_SESSION)
            result = cutover_live.apply(self.state, client, now_ms=lambda: int(time.time() * 1000),
                                        wait_seconds=30, limits_path=self.limits)
            self.assertEqual(result, "transferred")
            self.assertEqual([result["taskId"] for result in host.pending(HOST_ID)], [task_id],
                             "the captured result was lost in the transfer")
            receipts = host.flush(HOST_ID, projection.report_host_result)
            self.assertEqual([receipt["taskId"] for receipt in receipts], [task_id])
            self.assertEqual(host.pending(HOST_ID), [])
            self.assertEqual((backend.stops, backend.observe(CLI_SESSION)), ([], session_before))
            managed = client.call("config.get", {})["resolved"]["managedTasks"]
            self.assertEqual(sorted(managed["hosts"][HOST_ID]["adapters"]), sorted([ADAPTER, "codex"]))

    def test_unknown_limits_refuse_before_any_cron_is_touched(self):
        gateway, _, client = self.start(managed_enabled=False)
        limits = self.root / "limits.json"
        limits.write_text(json.dumps({"productionProfile": {"values": {"maxContextTokens": None}}}))
        with self.assertRaisesRegex(cutover_live.CutoverRefused,
                                    "production limits are unknown: maxContextTokens"):
            cutover_live.apply(self.state, client, now_ms=lambda: int(time.time() * 1000),
                               wait_seconds=10, limits_path=limits)
        state = json.loads(self.state.read_text())
        self.assertEqual((state["owner"], state["generation"], state["suspended"]), ("legacy", 1, {}))
        self.assertTrue(self.cron(client)["enabled"], "a refused cutover suspended the old cron")

    def test_an_interrupted_transfer_resumes_without_suspending_again(self):
        gateway, job_id, client = self.start(managed_enabled=False)
        client.call("cron.update", {"id": job_id, "patch": {"enabled": False}})
        state = json.loads(self.state.read_text())
        state.update(owner="transferring", generation=2,
                     suspended={job_id: {"name": CRON, "job": {}, "disabledAtMs": int(time.time() * 1000)}})
        self.state.write_text(json.dumps(state))
        result = cutover_live.apply(self.state, client, now_ms=lambda: int(time.time() * 1000),
                                    wait_seconds=30, limits_path=self.limits)
        state = json.loads(self.state.read_text())
        self.assertEqual((result, state["owner"], state["generation"]), ("transferred", "native", 2))
        self.assertFalse(self.cron(client)["enabled"])
        self.assertTrue(client.call("config.get", {})["resolved"]["managedTasks"]["enabled"])


if __name__ == "__main__":
    unittest.main()

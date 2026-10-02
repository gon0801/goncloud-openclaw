#!/usr/bin/env python3
"""Crash boundaries between native task results and the progress queue."""

import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts" / "mac"))
from contracts import AuthorizedOperation, OperationKey, operation_id  # noqa: E402
from host import Host  # noqa: E402
import native_gateway  # noqa: E402
from native_gateway import GatewayProjectionClient, main as gateway_main, transfer_gateway_projections  # noqa: E402
from progress_bridge import event_id, projection_digest, transfer_host_projection, transfer_projection  # noqa: E402
from spool import atomic_json, canonical  # noqa: E402
from corrida_worker import task_handoffs  # noqa: E402
from corrida_worker.reconcile import reconcile  # noqa: E402
from corrida_worker.state import reduce_events, state_from_record  # noqa: E402


class ProjectionTransferTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.evidence_root = self.root / "evidence"
        self.evidence_root.mkdir()
        self.state_dir = self.root / "progress"
        self.evidence = self.evidence_root / "review.txt"
        self.evidence.write_text("VEREDICTO aprobado\n", encoding="utf-8")
        key = json.dumps(["round.verdict", "run-1", "B3", "try-1", 1],
                         ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        event_id = "evt-" + hashlib.sha256(key.encode()).hexdigest()[:32]
        self.pending = {
            "taskId": "task-one",
            "generation": 1,
            "resultDigest": "sha256:" + "a" * 64,
            "eventId": event_id,
            "destination": {
                "publisherHostId": "host-one",
                "corrida": "run-1",
                "carril": "B3",
                "intento": "try-1",
                "ronda": 1,
            },
            "result": {
                "kind": "verdict",
                "sha": "b" * 40,
                "verdict": "aprobado",
                "evidenceRef": "review.txt",
                "contentHash": hashlib.sha256(self.evidence.read_bytes()).hexdigest(),
            },
        }
        # The native runtime uses the same canonical semantic digest.
        self.pending["projectionDigest"] = projection_digest(self.pending)

    def transfer(self, acknowledge):
        return transfer_projection(
            self.pending,
            host_id="host-one",
            evidence_root=self.evidence_root,
            progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            acknowledge_native=acknowledge,
        )

    def test_projection_crash_after_result_ack_reuses_one_durable_event(self):
        receipts = []

        def lose_first_ack(receipt):
            receipts.append(receipt)
            if len(receipts) == 1:
                raise ConnectionError("native ACK lost")
            return receipt

        with self.assertRaises(ConnectionError):
            self.transfer(lose_first_ack)
        queued = list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))
        self.assertEqual(len(queued), 1)
        first_bytes = queued[0].read_bytes()
        receipt = self.transfer(lose_first_ack)
        self.assertEqual(queued[0].read_bytes(), first_bytes)
        self.assertEqual(len(receipts), 2)
        self.assertEqual(receipts[0], receipts[1])
        self.assertEqual(receipt["eventId"], self.pending["eventId"])
        self.assertEqual(receipt["contentHash"], self.pending["result"]["contentHash"])
        self.assertEqual(receipt["queueHash"], hashlib.sha256(first_bytes).hexdigest())

    def test_changed_evidence_or_foreign_host_cannot_confirm_transfer(self):
        acknowledgements = []
        self.evidence.write_text("VEREDICTO cambios\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "evidencia"):
            self.transfer(acknowledgements.append)
        self.assertEqual(acknowledgements, [])
        self.evidence.write_text("VEREDICTO aprobado\n", encoding="utf-8")
        self.pending["destination"]["publisherHostId"] = "other-host"
        self.pending["projectionDigest"] = projection_digest(self.pending)
        with self.assertRaisesRegex(ValueError, "host"):
            self.transfer(acknowledgements.append)
        self.assertEqual(acknowledgements, [])

    def test_lost_queue_ack_recovers_the_same_event_without_native_ack(self):
        original_run = subprocess.run
        calls = 0
        acknowledged = []

        def lose_first_response(*args, **kwargs):
            nonlocal calls
            response = original_run(*args, **kwargs)
            calls += 1
            if calls == 1:
                raise ConnectionError("queue response lost")
            return response

        with mock.patch("progress_bridge.subprocess.run", side_effect=lose_first_response):
            with self.assertRaises(ConnectionError):
                self.transfer(acknowledged.append)
        self.assertEqual(acknowledged, [])
        queued = list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))
        self.assertEqual(len(queued), 1)
        first_bytes = queued[0].read_bytes()
        receipt = self.transfer(lambda value: acknowledged.append(value) or value)
        self.assertEqual(queued[0].read_bytes(), first_bytes)
        self.assertEqual(acknowledged, [receipt])

    def test_ready_result_uses_the_same_durable_transfer(self):
        sha = "c" * 40
        self.evidence.write_text("LISTO " + sha + "\n", encoding="utf-8")
        self.pending["result"] = {
            "kind": "ready",
            "sha": sha,
            "evidenceRef": "review.txt",
            "contentHash": hashlib.sha256(self.evidence.read_bytes()).hexdigest(),
        }
        self.pending["eventId"] = event_id("round.ready", self.pending["destination"])
        self.pending["projectionDigest"] = projection_digest(self.pending)
        receipt = self.transfer(lambda value: value)
        event = self.state_dir / "runs" / "run-1" / "queue" / (receipt["eventId"] + ".json")
        self.assertEqual(json.loads(event.read_text())["kind"], "round.ready")

    def test_gateway_projection_drain_publishes_once_and_acknowledges(self):
        pending = self.pending.copy()
        class Client:
            host_id = "host-one"
            rows = [pending]
            receipts = []

            def list_pending(self, after_task_id=None, limit=100):
                return [row for row in self.rows if not after_task_id or row["taskId"] > after_task_id]

            def ack(self, receipt):
                self.receipts.append(receipt)
                self.rows = []
                return receipt

        client = Client()
        self.assertEqual(transfer_gateway_projections(
            client, evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
        ), 1)
        self.assertEqual(len(client.receipts), 1)
        self.assertEqual(client.rows, [])
        queued = list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))
        self.assertEqual(len(queued), 1)

    def test_gateway_client_uses_authenticated_cli_rpc_with_exact_receipt(self):
        receipt = {"taskId": "task-one", "queueHash": "f" * 64}
        responses = [
            subprocess.CompletedProcess([], 0, json.dumps({"projections": [self.pending]}), ""),
            subprocess.CompletedProcess([], 0, json.dumps(receipt), ""),
        ]
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://127.0.0.1:18789")
        with mock.patch("native_gateway.subprocess.run", side_effect=responses) as invoke:
            self.assertEqual(client.list_pending(), [self.pending])
            self.assertEqual(client.ack(receipt), receipt)
        list_command = invoke.call_args_list[0].args[0]
        ack_command = invoke.call_args_list[1].args[0]
        self.assertEqual(list_command[:4], ["/isolated/openclaw", "gateway", "call",
                                            "managedTasks.projections.list"])
        self.assertEqual(json.loads(list_command[list_command.index("--params") + 1]),
                         {"publisherHostId": "host-one", "limit": 100})
        self.assertEqual(ack_command[3], "managedTasks.projections.ack")
        self.assertEqual(list_command[list_command.index("--expect-url") + 1],
                         "ws://127.0.0.1:18789")
        self.assertEqual(json.loads(ack_command[ack_command.index("--params") + 1]),
                         {"publisherHostId": "host-one", "receipt": receipt})

    def test_host_spool_reports_to_gateway_once_after_lost_response(self):
        host, key, artifact_bytes = self.reported_host()
        result = host.result_snapshot("host-one", key)[0]
        result_id = hashlib.sha256(canonical(result).encode()).hexdigest()
        receipt = {"hostId": "host-one", "taskId": key.task_id,
                   "generation": key.generation, "instanceId": key.instance_id,
                   "producerId": result["producerId"], "resultId": result_id,
                   "receiptId": "native-result-digest"}
        responses = [
            subprocess.CompletedProcess([], 1, "", "lost Gateway response"),
            subprocess.CompletedProcess([], 0, json.dumps(receipt), ""),
        ]
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://127.0.0.1:18789")
        with mock.patch("native_gateway.subprocess.run", side_effect=responses) as invoke:
            with self.assertRaisesRegex(RuntimeError, "rejected request"):
                host.flush("host-one", client.report_host_result)
            self.assertEqual(host.pending("host-one"), [result])
            self.assertEqual(host.flush("host-one", client.report_host_result), [receipt])
        self.assertEqual(host.flush("host-one", client.report_host_result), [])
        commands = [call.args[0] for call in invoke.call_args_list]
        self.assertEqual(commands[0], commands[1])
        self.assertEqual(commands[0][3], "managedTasks.host.report")
        self.assertEqual(json.loads(commands[0][commands[0].index("--params") + 1]),
                         {"hostId": "host-one", "resultId": result_id, "result": result,
                          "artifactBase64": base64.b64encode(artifact_bytes).decode("ascii")})

    def test_large_host_artifact_uses_private_params_file_and_cleans_it(self):
        artifact_bytes = b"a" * 100_000
        result = {"hostId": "host-one", "digest": hashlib.sha256(artifact_bytes).hexdigest()}
        seen = []

        def invoke(command, **_):
            self.assertNotIn("--params", command)
            path = Path(command[command.index("--params-file") + 1])
            self.assertEqual(path.stat().st_mode & 0o077, 0)
            seen.append(path)
            payload = json.loads(path.read_text())
            self.assertEqual(base64.b64decode(payload["artifactBase64"]), artifact_bytes)
            return subprocess.CompletedProcess(command, 0, json.dumps({"ok": True}), "")

        client = GatewayProjectionClient("/isolated/openclaw", "host-one")
        with mock.patch("native_gateway.subprocess.run", side_effect=invoke):
            self.assertEqual(client.report_host_result(result, artifact_bytes), {"ok": True})
        self.assertEqual(len(seen), 1)
        self.assertFalse(seen[0].exists())

    def test_gateway_host_admission_binds_claim_before_delivery(self):
        assignment = {"hostId": "host-one", "taskId": "task-one", "generation": 1,
                      "instanceId": "instance-one", "producerId": "codex",
                      "capability": "secret", "claimId": "claim-one"}
        receipt = {"state": "host-admitted", "hostId": "host-one",
                   "instanceId": "instance-one", "claimId": "claim-one", "generation": 1}
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://127.0.0.1:18789")
        with mock.patch("native_gateway.subprocess.run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps(receipt), "")) as invoke:
            self.assertEqual(client.admit_host(assignment), receipt)
        command = invoke.call_args.args[0]
        self.assertEqual(command[3], "managedTasks.host.admit")
        self.assertEqual(json.loads(command[command.index("--params") + 1]), {
            "hostId": "host-one", "instanceId": "instance-one", "claimId": "claim-one",
            "capability": {"taskId": "task-one", "generation": 1,
                           "producerId": "codex", "token": "secret"}})
        with mock.patch("native_gateway.subprocess.run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({**receipt, "instanceId": "foreign"}), "")):
            with self.assertRaisesRegex(RuntimeError, "identity mismatch"):
                client.admit_host(assignment)

    def test_gateway_drain_entrypoint_requires_pinned_gateway_and_passes_paths(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--evidence-root", str(self.evidence_root),
                "--progress-state-dir", str(self.state_dir), "--progress-client", "/isolated/progress.py"]
        with mock.patch("native_gateway.transfer_gateway_projections", return_value=2) as transfer:
            with mock.patch("builtins.print") as output:
                self.assertEqual(gateway_main(args), 0)
        self.assertEqual(transfer.call_args.kwargs, {
            "evidence_root": str(self.evidence_root),
            "progress_state_dir": str(self.state_dir),
            "progress_client": "/isolated/progress.py",
            "host": None,
        })
        self.assertEqual(transfer.call_args.args[0].expected_url, "ws://127.0.0.1:18789")
        output.assert_called_once_with('{"transferred": 2}')
        with mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                gateway_main([arg for arg in args
                              if arg != "--expect-url" and arg != "ws://127.0.0.1:18789"])

        with mock.patch("native_gateway.transfer_gateway_projections", return_value=0) as transfer:
            with mock.patch("builtins.print"):
                gateway_main(args + ["--host-state-dir", str(self.root / "host")])
        self.assertEqual(transfer.call_args.kwargs["host"].host_id, "host-one")
        self.assertEqual(transfer.call_args.kwargs["host"].state_dir, self.root / "host")

    def test_gateway_flush_entrypoint_requires_host_spool(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--flush-results"]
        with mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                gateway_main(args)
        with mock.patch("native_gateway.Host") as host_type:
            host_type.return_value.flush.return_value = [{"receiptId": "native-one"}]
            with mock.patch("builtins.print") as output:
                self.assertEqual(gateway_main(args + ["--host-state-dir", str(self.root / "host")]), 0)
        host_type.assert_called_once_with("host-one", str(self.root / "host"))
        output.assert_called_once_with('{"reported": 1}')

    def test_watch_entrypoint_requires_host_and_restores_signal_handlers(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--evidence-root", str(self.evidence_root),
                "--progress-state-dir", str(self.state_dir),
                "--progress-client", "/isolated/progress.py", "--watch"]
        with mock.patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                gateway_main(args)
        old_term = signal.getsignal(signal.SIGTERM)
        old_int = signal.getsignal(signal.SIGINT)
        with mock.patch("native_gateway.watch_pump") as watch:
            self.assertEqual(gateway_main(args + ["--host-state-dir", str(self.root / "host")]), 0)
        self.assertEqual(watch.call_args.args[0].host_id, "host-one")
        self.assertEqual(signal.getsignal(signal.SIGTERM), old_term)
        self.assertEqual(signal.getsignal(signal.SIGINT), old_int)

    def test_gateway_entrypoint_imports_with_mac_system_python(self):
        system_python = Path("/usr/bin/python3")
        if not system_python.exists():
            self.skipTest("macOS system Python unavailable")
        completed = subprocess.run(
            [str(system_python), "-c", "import native_gateway"],
            cwd=ROOT / "scripts" / "agent-work", capture_output=True, text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_gateway_ack_loss_keeps_one_queued_event(self):
        pending = self.pending.copy()
        class Client:
            host_id = "host-one"
            rows = [pending]

            def list_pending(self, after_task_id=None, limit=100):
                return self.rows

            def ack(self, receipt):
                self.rows = []
                raise ConnectionError("native ACK response lost")

        client = Client()
        with self.assertRaises(ConnectionError):
            transfer_gateway_projections(
                client, evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
                progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            )
        queued = list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))
        self.assertEqual(len(queued), 1)
        self.assertEqual(transfer_gateway_projections(
            client, evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
        ), 0)
        self.assertEqual(len(list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))), 1)

    def test_mutating_source_after_validation_cannot_poison_event_id(self):
        original_run = subprocess.run
        original_bytes = self.evidence.read_bytes()

        def replace_source_before_client_reads(*args, **kwargs):
            self.evidence.write_text("VEREDICTO cambios\n", encoding="utf-8")
            return original_run(*args, **kwargs)

        with mock.patch("progress_bridge.subprocess.run",
                        side_effect=replace_source_before_client_reads):
            receipt = self.transfer(lambda value: value)
        base = self.state_dir / "runs" / "run-1"
        evidence = json.loads((base / "evidence" / (receipt["eventId"] + ".json")).read_text())
        self.assertEqual(evidence["contentHash"], self.pending["result"]["contentHash"])
        self.assertEqual(evidence["content"], original_bytes.decode())
        self.evidence.write_bytes(original_bytes)
        self.assertEqual(self.transfer(lambda value: value), receipt)

    def registered_host(self, *, revision=None, payload=None):
        workspace = self.root / "workspace"
        workspace.mkdir()
        brief = workspace / "brief.txt"
        brief.write_text("review")
        artifact = workspace / "review.txt"
        original = self.evidence.read_bytes()
        artifact.write_bytes(original)
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", self.pending["taskId"], 1, "instance-one")
        input_revision = {"kind": "code", "repository": "repo",
                          "sha": revision or self.pending["result"]["sha"]}
        operation = AuthorizedOperation(key, "adversary", "capability", "worker-one",
                                        str(workspace), str(brief), hashlib.sha256(brief.read_bytes()).hexdigest(),
                                        input_revision, "review.v1", "integration-claim")
        host.apply(key, operation, lambda *_: None,
                   lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                              "hostId": a["hostId"], "instanceId": a["instanceId"],
                              "generation": a["generation"]})
        result = {
            "schema": "agent-work.result.v1", "kind": "produced", "hostId": "host-one",
            "taskId": key.task_id, "generation": key.generation, "instanceId": key.instance_id,
            "producerId": "adversary", "capability": "capability",
            "observedRevision": input_revision,
            "typedPayload": payload or {"verdict": "approved", "evidenceRef": "review.txt"},
            "artifactRef": str(artifact),
            "digest": hashlib.sha256(original).hexdigest(),
        }
        return host, key, original, result, artifact

    def reported_host(self, *, revision=None, payload=None):
        host, key, original, result, artifact = self.registered_host(
            revision=revision, payload=payload)
        host.report("host-one", result)
        artifact.unlink()
        return Host("host-one", self.root / "host"), key, original

    def transfer_from_host(self, host, key, acknowledge):
        return transfer_host_projection(
            self.pending, host=host, operation_key=key,
            progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            acknowledge_native=acknowledge,
        )

    def test_host_snapshot_survives_workspace_deletion_before_projection(self):
        restarted, key, original = self.reported_host()
        receipt = self.transfer_from_host(restarted, key, lambda value: value)
        event = self.state_dir / "runs" / "run-1" / "evidence" / (receipt["eventId"] + ".json")
        self.assertEqual(json.loads(event.read_text())["content"], original.decode())

    def test_pump_reports_then_projects_once_across_repeated_idle_polls(self):
        host, _, _ = self.reported_host()
        pending = self.pending

        class Client:
            host_id = "host-one"

            def __init__(self):
                self.reports = []
                self.projections = []

            def report_host_result(self, result, artifact):
                self.reports.append((result, artifact))
                self.projections = [pending]
                return {field: result[field] for field in
                        ("hostId", "taskId", "generation", "instanceId", "producerId")} | {
                    "resultId": hashlib.sha256(canonical(result).encode()).hexdigest(),
                    "receiptId": "native-one",
                }

            def list_pending(self, after_task_id=None, limit=100):
                return self.projections

            def ack(self, receipt):
                self.projections = []
                return receipt

        client = Client()
        args = {"evidence_root": self.evidence_root, "progress_state_dir": self.state_dir,
                "progress_client": ROOT / "scripts" / "mac" / "progress-events.py"}
        self.assertEqual(native_gateway.pump_once(client, host=host, **args),
                         {"reported": 1, "transferred": 1})
        for _ in range(100):
            self.assertEqual(native_gateway.pump_once(client, host=host, **args),
                             {"reported": 0, "transferred": 0})
        self.assertEqual(len(client.reports), 1)
        self.assertEqual(len(list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))), 1)

    def test_pump_transfers_existing_projection_when_host_report_fails(self):
        class FailingHost:
            def flush(self, *_):
                raise RuntimeError("host report unavailable")

            def operation_key_for(self, *_):
                return None

        class Client:
            host_id = "host-one"

            def __init__(self):
                self.receipts = []

            def report_host_result(self, *_):
                raise AssertionError("host failure must precede Gateway report")

            def list_pending(self, after_task_id=None, limit=100):
                return [] if self.receipts else [pending]

            def ack(self, receipt):
                self.receipts.append(receipt)
                return receipt

        pending = self.pending
        client = Client()
        with self.assertRaisesRegex(RuntimeError, "host report unavailable"):
            native_gateway.pump_once(
                client, host=FailingHost(), evidence_root=self.evidence_root,
                progress_state_dir=self.state_dir,
                progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            )
        self.assertEqual(len(client.receipts), 1)
        self.assertEqual(len(list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))), 1)

    def test_delivery_latency_separates_detection_from_native_receipt(self):
        _, key, _, result, _ = self.registered_host()
        stop = threading.Event()
        times = {}

        class TimedHost(Host):
            def report(self, host_id, value):
                times["detected"] = time.monotonic()
                return super().report(host_id, value)

        class Client:
            host_id = "host-one"

            def __init__(self):
                self.calls = 0

            def report_host_result(self, value, artifact):
                self.calls += 1
                times["receipt"] = time.monotonic()
                stop.set()
                return {field: value[field] for field in
                        ("hostId", "taskId", "generation", "instanceId", "producerId")} | {
                    "resultId": hashlib.sha256(canonical(value).encode()).hexdigest(),
                    "receiptId": "native-one",
                }

            def list_pending(self, after_task_id=None, limit=100):
                return []

        client = Client()
        result_path = self.root / "host" / "inbox" / (operation_id(key) + ".json")

        def publish():
            times["write_started"] = time.monotonic()
            atomic_json(result_path, result)

        writer = threading.Timer(0.1, publish)
        deadline = threading.Timer(5, stop.set)
        writer.start()
        deadline.start()
        try:
            native_gateway.watch_pump(
                client, host=TimedHost("host-one", self.root / "host"),
                evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
                progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
                stop_event=stop, interval=0.05,
            )
        finally:
            stop.set()
            writer.join()
            deadline.cancel()
            deadline.join()
        self.assertEqual(client.calls, 1)
        self.assertLessEqual(times["detected"] - times["write_started"], 5)
        self.assertLessEqual(times["receipt"] - times["detected"], 5)

    def test_delivery_latency_acceptance_records_both_legs(self):
        _, key, _, result, _ = self.registered_host()
        stop = threading.Event()
        times = {}

        class TimedHost(Host):
            def report(self, host_id, value):
                times.setdefault("detected", time.monotonic())
                return super().report(host_id, value)

        host = TimedHost("host-one", self.root / "host")
        persist_receipt = host.spool.acknowledge

        def timed_acknowledge(operation_id, receipt):
            persist_receipt(operation_id, receipt)
            times["receipt_persisted"] = time.monotonic()
            stop.set()

        host.spool.acknowledge = timed_acknowledge

        class Client:
            host_id = "host-one"

            def report_host_result(self, value, artifact):
                return {field: value[field] for field in
                        ("hostId", "taskId", "generation", "instanceId", "producerId")} | {
                    "resultId": hashlib.sha256(canonical(value).encode()).hexdigest(),
                    "receiptId": "native-one",
                }

            def list_pending(self, after_task_id=None, limit=100):
                return []

        result_path = self.root / "host" / "inbox" / (operation_id(key) + ".json")

        def publish():
            atomic_json(result_path, result)
            times["written"] = time.monotonic()

        writer = threading.Timer(0.1, publish)
        deadline = threading.Timer(30, stop.set)
        writer.start()
        deadline.start()
        try:
            native_gateway.watch_pump(
                Client(), host=host,
                evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
                progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
                stop_event=stop, interval=0.05,
            )
        finally:
            stop.set()
            writer.join()
            deadline.cancel()
            deadline.join()
        self.assertIsNotNone(host.receipt("host-one", key),
                             "receipt must persist durably before timing assertions")
        write_to_detection = times["detected"] - times["written"]
        detection_to_receipt = times["receipt_persisted"] - times["detected"]
        print("DELIVERY_LATENCY " + json.dumps({
            "write_to_detection_s": round(write_to_detection, 3),
            "detection_to_persisted_receipt_s": round(detection_to_receipt, 3),
        }, sort_keys=True), flush=True)
        self.assertLessEqual(write_to_detection, 5,
                             "durable write to detection exceeded five seconds")
        self.assertLessEqual(detection_to_receipt, 5,
                             "detection to persisted receipt exceeded five seconds")

    def test_gateway_drain_uses_host_snapshot_after_workspace_disappears(self):
        restarted, _, original = self.reported_host()
        self.evidence.unlink()

        class Client:
            host_id = "host-one"
            receipts = []

            def list_pending(self, after_task_id=None, limit=100):
                return [] if after_task_id else [self_pending]

            def ack(self, receipt):
                self.receipts.append(receipt)
                return receipt

        self_pending = self.pending
        client = Client()
        self.assertEqual(transfer_gateway_projections(
            client, host=restarted, evidence_root=self.evidence_root,
            progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
        ), 1)
        event = self.state_dir / "runs" / "run-1" / "evidence" / (client.receipts[0]["eventId"] + ".json")
        self.assertEqual(json.loads(event.read_text())["content"], original.decode())

    def test_host_revision_mismatch_never_queues_or_acknowledges(self):
        restarted, key, _ = self.reported_host(revision="c" * 40)
        acknowledged = []
        with self.assertRaisesRegex(ValueError, "revisión"):
            self.transfer_from_host(restarted, key, acknowledged.append)
        self.assertEqual(acknowledged, [])
        self.assertFalse((self.state_dir / "runs" / "run-1" / "queue").exists())

    def test_host_verdict_mismatch_never_queues_or_acknowledges(self):
        restarted, key, _ = self.reported_host(payload={"verdict": "changes", "findingsRef": "review.txt"})
        acknowledged = []
        with self.assertRaisesRegex(ValueError, "veredicto"):
            self.transfer_from_host(restarted, key, acknowledged.append)
        self.assertEqual(acknowledged, [])
        self.assertFalse((self.state_dir / "runs" / "run-1" / "queue").exists())


class DirectorHandlingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-work-director-unit-")
        self.addCleanup(self.tmp.cleanup)
        self.record = {
            "schema": "corrida.v2",
            "lanes": [{
                "id": "l1",
                "estado": "activo",
                "events": [],
            }],
        }
        self.decision = {
            "kind": "continue",
            "children": [{
                "slot": "corregir",
                "assignment": {
                    "target": {"kind": "agent", "agentId": "ingenieria"},
                    "instructionRef": {"ref": "artifact:fix", "digest": "sha256:fix"},
                    "inputRevision": {"kind": "code", "repository": "repo", "sha": "a" * 40},
                    "resultContract": "review.v1",
                    "continuation": {"kind": "requester"},
                },
            }],
        }
        self.observation = {
            "lanes": {"l1": {"managed_task": {
                "caller": {
                    "kind": "director",
                    "authority": "director-token",
                    "corridaId": "run-1",
                    "decisionId": "decision-1",
                    "fence": "fence-1",
                },
                "receipt": {
                    "taskId": "task-1",
                    "generation": 1,
                    "resultDigest": "sha256:" + "b" * 64,
                },
                "decision": self.decision,
            }}}
        }

    def _apply(self, record, effect):
        kind = {
            "record_task_handling": "intent.task_handling",
            "record_task_gate": "intent.task_gate",
            "record_task_gate_receipt": "observed.task_gate",
        }.get(effect.op, "observed.task_handled")
        next_record, applied, duplicated = reduce_events(record, [{
            "lane": effect.lane,
            "kind": kind,
            "payload": effect.args,
        }])
        self.assertEqual((applied, duplicated), (1, 0))
        return next_record

    def _review_observation(self, typed_payload, *, decision=None):
        observation = copy.deepcopy(self.observation)
        managed = observation["lanes"]["l1"]["managed_task"]
        managed["result"] = {
            "kind": "produced",
            "observedRevision": {
                "kind": "code", "repository": "repo", "sha": "b" * 40,
            },
            "typedPayload": typed_payload,
            "artifactRef": "artifact:review",
        }
        if decision is not None:
            managed["decision"] = decision
        return observation

    def test_changes_derives_correction_from_typed_review_result(self):
        correction = {
            "target": {"kind": "agent", "agentId": "ingenieria"},
            "instructionRef": {"ref": "artifact:findings", "digest": "sha256:findings"},
            "inputRevision": {"kind": "code", "repository": "repo", "sha": "b" * 40},
            "resultContract": "review.v1",
            "continuation": {"kind": "requester"},
        }
        observation = self._review_observation(
            {"verdict": "changes", "findingsRef": "artifact:findings"},
            decision={"kind": "complete", "evidenceRef": "attacker-controlled"},
        )
        observation["lanes"]["l1"]["managed_task"]["correctionAssignment"] = correction

        _, effects = reconcile(state_from_record(self.record), observation)

        self.assertEqual([effect.op for effect in effects], ["record_task_handling"])
        self.assertEqual(effects[0].args["decision"], {
            "kind": "continue",
            "children": [{"slot": "corregir", "assignment": correction}],
        })

    def test_approved_derives_complete_and_current_gate_from_typed_review_result(self):
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
            decision={
                "kind": "continue",
                "children": [{"slot": "corregir", "assignment": {"bad": "decision"}}],
            },
        )
        evidence = Path(self.tmp.name) / "approved-gate.json"
        evidence.write_text(json.dumps({"repo": "o/r", "pr": 7}), encoding="utf-8")
        evidence_digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
        observation["lanes"]["l1"]["gate"] = {
            "action": "merge",
            "evidencePath": str(evidence),
            "evidenceDigest": evidence_digest,
        }

        _, effects = reconcile(state_from_record(self.record), observation)

        self.assertEqual([effect.op for effect in effects], ["record_task_handling"])
        self.assertEqual(effects[0].args["decision"], {
            "kind": "complete", "evidenceRef": "artifact:review",
        })
        self.assertEqual(effects[0].args["gate"], {
            "action": "merge", "sha": "b" * 40, "evidenceRef": "artifact:review",
            "evidencePath": str(evidence), "evidenceDigest": evidence_digest,
            "taskId": "task-1", "decisionId": "decision-1",
            "decisionDigest": effects[0].args["decisionDigest"],
        })

    def test_approved_receipt_plans_existing_gate_effect(self):
        evidence = Path(self.tmp.name) / "gate-evidence.json"
        evidence.write_text(
            json.dumps({"repo": "o/r", "pr": 7, "head": "b" * 40}),
            encoding="utf-8",
        )
        evidence_digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
            decision={"kind": "complete", "evidenceRef": "attacker-controlled"},
        )
        observation["lanes"]["l1"]["gate"] = {
            "action": "ci",
            "evidencePath": str(evidence),
            "evidenceDigest": evidence_digest,
        }
        _, effects = reconcile(state_from_record(self.record), observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), observation)
        receipt = {
            "taskId": "task-1",
            "resultDigest": "sha256:" + "b" * 64,
            "decisionDigest": effects[0].args["decisionDigest"],
            "childTaskIds": [],
        }
        handled = self._apply(
            durable,
            type(effects[0])("observed.task_handled", "l1", receipt),
        )

        _, effects = reconcile(state_from_record(handled), observation)

        self.assertEqual([effect.op for effect in effects], ["record_task_gate"])
        gate = effects[0].args
        self.assertEqual(gate["action"], "ci")
        self.assertEqual(gate["sha"], "b" * 40)
        self.assertEqual(gate["evidencePath"], str(evidence))
        self.assertEqual(gate["evidenceDigest"], evidence_digest)
        gated = self._apply(handled, effects[0])
        _, effects = reconcile(state_from_record(gated), observation)
        self.assertEqual([effect.op for effect in effects], ["execute_task_gate"])

    def test_approved_without_portable_gate_evidence_fails_closed(self):
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
        )
        observation["lanes"]["l1"]["gate"] = {"action": "ci"}

        with self.assertRaisesRegex(task_handoffs.TaskHandlingError, "evidencePath"):
            reconcile(state_from_record(self.record), observation)

    def test_gate_receipt_recovers_after_evidence_file_disappears(self):
        evidence = Path(self.tmp.name) / "recoverable-gate.json"
        evidence.write_text(
            json.dumps({"repo": "o/r", "pr": 7, "head": "b" * 40}),
            encoding="utf-8",
        )
        evidence_digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
        )
        observation["lanes"]["l1"]["gate"] = {
            "action": "ci",
            "evidencePath": str(evidence),
            "evidenceDigest": evidence_digest,
        }
        _, effects = reconcile(state_from_record(self.record), observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), observation)
        receipt = {
            "taskId": "task-1",
            "resultDigest": "sha256:" + "b" * 64,
            "decisionDigest": effects[0].args["decisionDigest"],
            "childTaskIds": [],
        }
        handled = self._apply(
            durable,
            type(effects[0])("observed.task_handled", "l1", receipt),
        )
        _, effects = reconcile(state_from_record(handled), observation)
        gated = self._apply(handled, effects[0])
        gate = effects[0].args
        gate_event = {
            "lane": "l1",
            "kind": "gate.allow",
            "payload": {
                "action": gate["action"],
                "sha": gate["sha"],
                "task_id": gate["taskId"],
                "decision_id": gate["decisionId"],
                "decision_digest": gate["decisionDigest"],
                "evidence_path": gate["evidencePath"],
                "evidence_digest": gate["evidenceDigest"],
                "code": "ci-ok",
                "reason": "",
            },
        }
        after_gate = reduce_events(gated, [gate_event])[0]
        evidence.unlink()

        _, effects = reconcile(state_from_record(after_gate), observation)

        self.assertEqual([effect.op for effect in effects], ["record_task_gate_receipt"])
        self.assertEqual(effects[0].args["gateKind"], "gate.allow")
        self.assertEqual(effects[0].args["evidenceDigest"], evidence_digest)

    def test_new_task_cannot_reuse_old_gate_verification(self):
        evidence = Path(self.tmp.name) / "first-task-gate.json"
        evidence.write_text(
            json.dumps({"repo": "o/r", "pr": 7, "head": "b" * 40}),
            encoding="utf-8",
        )
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
        )
        observation["lanes"]["l1"]["gate"] = {
            "action": "ci",
            "evidencePath": str(evidence),
            "evidenceDigest": hashlib.sha256(evidence.read_bytes()).hexdigest(),
        }
        _, effects = reconcile(state_from_record(self.record), observation)
        durable = self._apply(self.record, effects[0])

        new_observation = copy.deepcopy(observation)
        managed = new_observation["lanes"]["l1"]["managed_task"]
        managed["caller"]["decisionId"] = "decision-2"
        managed["receipt"]["taskId"] = "task-2"
        managed["result"]["typedPayload"]["evidenceRef"] = "artifact:new-review"
        managed["result"]["artifactRef"] = "artifact:new-review"
        managed["gate"] = {
            "action": "ci",
            "evidencePath": str(self.tmp.name + "/missing-new-task-gate.json"),
            "evidenceDigest": "0" * 64,
        }
        new_observation["lanes"]["l1"]["gate"] = managed["gate"]

        with self.assertRaisesRegex(task_handoffs.TaskHandlingError, "evidencePath"):
            reconcile(state_from_record(durable), new_observation)

    def test_new_director_identity_cannot_reuse_same_task_intent(self):
        _, effects = reconcile(state_from_record(self.record), self.observation)
        durable = self._apply(self.record, effects[0])
        for field, value in (
            ("authority", "another-director"),
            ("decisionId", "decision-2"),
            ("fence", "fence-2"),
        ):
            with self.subTest(field=field):
                observation = copy.deepcopy(self.observation)
                observation["lanes"]["l1"]["managed_task"]["caller"][field] = value
                with self.assertRaisesRegex(
                    task_handoffs.TaskHandlingError, "conflicts with durable intent"
                ):
                    reconcile(state_from_record(durable), observation)

    def test_director_persists_decision_before_native_resolve(self):
        _, effects = reconcile(state_from_record(self.record), self.observation)
        self.assertEqual([effect.op for effect in effects], ["record_task_handling"])
        durable = self._apply(self.record, effects[0])

        _, effects = reconcile(state_from_record(durable), self.observation)
        self.assertEqual([effect.op for effect in effects], ["resolve_task_handling"])
        self.assertEqual(effects[0].args["decision"], self.decision)

    def test_lost_resolve_ack_retries_the_same_correction(self):
        _, effects = reconcile(state_from_record(self.record), self.observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), self.observation)
        request = effects[0].args
        calls = []

        def resolver(value):
            calls.append(value)
            if len(calls) == 1:
                raise ConnectionError("resolve ACK lost")
            return {
                "taskId": value["receipt"]["taskId"],
                "resultDigest": value["receipt"]["resultDigest"],
                "decisionDigest": value["decisionDigest"],
                "childTaskIds": ["child-1"],
            }

        with self.assertRaises(ConnectionError):
            task_handoffs.resolve_task_handling(request, resolver)
        receipt = task_handoffs.resolve_task_handling(request, resolver)
        self.assertEqual(calls[0], calls[1])
        handled = self._apply(durable, type(effects[0])(
            "observed.task_handled", effects[0].lane, receipt
        ))
        _, remaining = reconcile(state_from_record(handled), self.observation)
        self.assertEqual(remaining, ())

    def test_two_consumers_share_one_native_effect(self):
        # Contract test: the injected resolver models R's idempotent resolve.
        # The live R Gateway operation remains an explicit dependency.
        _, effects = reconcile(state_from_record(self.record), self.observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), self.observation)
        request = effects[0].args
        native_effects = []
        receipts = {}

        def idempotent_resolver(value):
            key = (value["receipt"]["taskId"], value["decisionDigest"])
            if key not in receipts:
                native_effects.append(value["decision"])
                receipts[key] = {
                    "taskId": value["receipt"]["taskId"],
                    "resultDigest": value["receipt"]["resultDigest"],
                    "decisionDigest": value["decisionDigest"],
                    "childTaskIds": ["child-1"],
                }
            return receipts[key]

        first = task_handoffs.resolve_task_handling(request, idempotent_resolver)
        second = task_handoffs.resolve_task_handling(request, idempotent_resolver)
        self.assertEqual(first, second)
        self.assertEqual(native_effects, [self.decision])

    def test_gateway_resolver_sends_the_durable_intent_without_child_tokens(self):
        _, effects = reconcile(state_from_record(self.record), self.observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), self.observation)
        request = effects[0].args
        receipt = {
            "taskId": request["receipt"]["taskId"],
            "resultDigest": request["receipt"]["resultDigest"],
            "decisionDigest": request["decisionDigest"],
            "childTaskIds": ["child-1"],
        }
        with mock.patch(
            "corrida_worker.task_handoffs.subprocess.run",
            return_value=subprocess.CompletedProcess([], 0, json.dumps(receipt), ""),
        ) as invoke:
            self.assertEqual(
                task_handoffs.resolve_via_gateway(
                    request, openclaw_bin="/isolated/openclaw", expected_url="ws://gateway"
                ),
                receipt,
            )
        command = invoke.call_args.args[0]
        self.assertEqual(command[3], "managedTasks.resolve")
        params = json.loads(command[command.index("--params") + 1])
        self.assertEqual(params["decisionDigest"], request["decisionDigest"])
        self.assertNotIn("childProducerTokens", params)

    def test_existing_reconciler_persists_then_resolves_task_handling(self):
        # Keep the shell integration isolated from any user corrida state.
        state_dir = Path(tempfile.mkdtemp(prefix="agent-work-director-"))
        self.addCleanup(lambda: shutil.rmtree(state_dir, ignore_errors=True))
        corrida_dir = state_dir / "run-1"
        corrida_dir.mkdir()
        record_path = corrida_dir / "registro.json"
        record_path.write_text(json.dumps({
            "schema": "corrida.v2",
            "id": "run-1",
            "estado": "abierta",
            "lanes": [{"id": "l1", "estado": "activo", "events": []}],
        }), encoding="utf-8")
        observation_path = state_dir / "observation.json"
        observation_path.write_text(json.dumps(self.observation), encoding="utf-8")
        fake = state_dir / "openclaw"
        calls = state_dir / "resolve-calls.jsonl"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import json, pathlib, sys\n"
            "params = json.loads(sys.argv[sys.argv.index('--params') + 1])\n"
            f"path = pathlib.Path({str(calls)!r})\n"
            "with path.open('a', encoding='utf-8') as stream:\n"
            "    stream.write(json.dumps(params, sort_keys=True) + '\\n')\n"
            "print(json.dumps({'taskId': params['receipt']['taskId'],\n"
            "                  'resultDigest': params['receipt']['resultDigest'],\n"
            "                  'decisionDigest': params['decisionDigest'],\n"
            "                  'childTaskIds': ['child-1']}))\n",
            encoding="utf-8",
        )
        fake.chmod(0o700)
        env = dict(os.environ)
        env.update({
            "CORRIDA_STATE": str(state_dir),
            "OPENCLAW_BIN": str(fake),
            "OPENCLAW_EXPECT_URL": "ws://gateway",
            "CORR_TOPE_RED": "5",
        })
        completed = subprocess.run(
            ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "reconciliar", "run-1",
             "--observations", str(observation_path)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("EXECUTED record_task_handling l1", completed.stdout)
        self.assertIn("EXECUTED resolve_task_handling l1", completed.stdout)
        self.assertIn("CONVERGED", completed.stdout)
        events = json.loads(record_path.read_text(encoding="utf-8"))["lanes"][0]["events"]
        self.assertEqual([event["kind"] for event in events], [
            "intent.task_handling", "observed.task_handled",
        ])
        self.assertEqual(len(calls.read_text(encoding="utf-8").splitlines()), 1)

    def test_existing_reconciler_runs_approved_gate_once_with_real_evidence(self):
        state_dir = Path(tempfile.mkdtemp(prefix="agent-work-director-gate-"))
        self.addCleanup(lambda: shutil.rmtree(state_dir, ignore_errors=True))
        corrida_dir = state_dir / "run-1"
        corrida_dir.mkdir()
        record_path = corrida_dir / "registro.json"
        record_path.write_text(json.dumps({
            "schema": "corrida.v2",
            "id": "run-1",
            "estado": "abierta",
            "lanes": [{"id": "l1", "estado": "activo", "events": []}],
        }), encoding="utf-8")

        evidence = state_dir / "gate-evidence.json"
        evidence.write_text(json.dumps({
            "repo": "o/r",
            "pr": 7,
            "head": "b" * 40,
            "ci": {"sha": "b" * 40, "conclusion": "success"},
        }), encoding="utf-8")
        evidence_digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
        observation = self._review_observation(
            {"verdict": "approved", "evidenceRef": "artifact:review"},
            decision={"kind": "complete", "evidenceRef": "attacker-controlled"},
        )
        observation["lanes"]["l1"]["gate"] = {
            "action": "ci",
            "evidencePath": str(evidence),
            "evidenceDigest": evidence_digest,
        }
        observation_path = state_dir / "observation.json"
        observation_path.write_text(json.dumps(observation), encoding="utf-8")

        fake_openclaw = state_dir / "openclaw"
        resolve_calls = state_dir / "resolve-calls.jsonl"
        fake_openclaw.write_text(
            "#!/usr/bin/env python3\n"
            "import json, pathlib, sys\n"
            "params = json.loads(sys.argv[sys.argv.index('--params') + 1])\n"
            f"path = pathlib.Path({str(resolve_calls)!r})\n"
            "with path.open('a', encoding='utf-8') as stream:\n"
            "    stream.write(json.dumps(params, sort_keys=True) + '\\n')\n"
            "print(json.dumps({'taskId': params['receipt']['taskId'],\n"
            "                  'resultDigest': params['receipt']['resultDigest'],\n"
            "                  'decisionDigest': params['decisionDigest'],\n"
            "                  'childTaskIds': []}))\n",
            encoding="utf-8",
        )
        fake_openclaw.chmod(0o700)

        fake_gh = state_dir / "gh"
        fake_gh.write_text(
            "#!/bin/sh\n"
            "cat \"$T8_FAKE_PR\"\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o700)
        fake_pr = state_dir / "pr.json"
        fake_pr.write_text(json.dumps({
            "number": 7,
            "headRefOid": "b" * 40,
            "mergedAt": None,
            "mergeCommit": None,
            "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
        }), encoding="utf-8")

        env = dict(os.environ)
        env.update({
            "CORRIDA_STATE": str(state_dir),
            "OPENCLAW_BIN": str(fake_openclaw),
            "OPENCLAW_EXPECT_URL": "ws://gateway",
            "CORR_TOPE_RED": "8",
            "T8_FAKE_PR": str(fake_pr),
            "PATH": str(state_dir) + os.pathsep + env["PATH"],
        })
        command = [
            "bash", str(ROOT / "scripts" / "mac" / "corrida.sh"),
            "reconciliar", "run-1", "--observations", str(observation_path),
        ]
        first = subprocess.run(
            command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIn("EXECUTED record_task_handling l1", first.stdout)
        self.assertIn("EXECUTED resolve_task_handling l1", first.stdout)
        self.assertIn("EXECUTED record_task_gate l1", first.stdout)
        self.assertIn("EXECUTED execute_task_gate l1", first.stdout)
        self.assertIn("CONVERGED", first.stdout)

        record = json.loads(record_path.read_text(encoding="utf-8"))
        events = record["lanes"][0]["events"]
        self.assertEqual([event["kind"] for event in events], [
            "intent.task_handling", "observed.task_handled", "intent.task_gate",
            "gate.allow", "evidence.ci", "observed.task_gate",
        ])
        gate_event = next(event for event in events if event["kind"] == "gate.allow")
        self.assertEqual(gate_event["payload"]["action"], "ci")
        self.assertEqual(gate_event["payload"]["sha"], "b" * 40)
        self.assertEqual(gate_event["payload"]["task_id"], "task-1")
        self.assertEqual(gate_event["payload"]["decision_id"], "decision-1")
        self.assertEqual(gate_event["payload"]["evidence_path"], str(evidence))
        self.assertEqual(gate_event["payload"]["evidence_digest"], evidence_digest)
        self.assertNotIn("intent.merge", [event["kind"] for event in events])
        self.assertNotIn("intent.deploy", [event["kind"] for event in events])
        self.assertEqual(len(resolve_calls.read_text(encoding="utf-8").splitlines()), 1)

        second = subprocess.run(
            command, cwd=ROOT, env=env, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("CONVERGED 0", second.stdout)
        record_after_retry = json.loads(record_path.read_text(encoding="utf-8"))
        self.assertEqual(record_after_retry, record)
        self.assertEqual(len(resolve_calls.read_text(encoding="utf-8").splitlines()), 1)


if __name__ == "__main__":
    unittest.main()

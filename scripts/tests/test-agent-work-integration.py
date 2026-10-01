#!/usr/bin/env python3
"""Crash boundaries between native task results and the progress queue."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from contracts import AuthorizedOperation, OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient, main as gateway_main, transfer_gateway_projections  # noqa: E402
from progress_bridge import event_id, projection_digest, transfer_host_projection, transfer_projection  # noqa: E402


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

    def reported_host(self, *, revision=None, payload=None):
        workspace = self.root / "workspace"
        workspace.mkdir()
        brief = workspace / "brief.txt"
        brief.write_text("review")
        artifact = workspace / "review.txt"
        original = self.evidence.read_bytes()
        artifact.write_bytes(original)
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", self.pending["taskId"], 1, "instance-one")
        operation = AuthorizedOperation(key, "adversary", "capability", "worker-one",
                                        str(workspace), str(brief), hashlib.sha256(brief.read_bytes()).hexdigest())
        host.apply(key, operation, lambda *_: None)
        host.report("host-one", {
            "schema": "agent-work.result.v1", "kind": "produced", "hostId": "host-one",
            "taskId": key.task_id, "generation": key.generation, "instanceId": key.instance_id,
            "producerId": "adversary", "capability": "capability",
            "observedRevision": revision or self.pending["result"]["sha"],
            "typedPayload": payload or {"verdict": "approved", "evidenceRef": "review.txt"},
            "artifactRef": str(artifact),
            "digest": hashlib.sha256(original).hexdigest(),
        })
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


if __name__ == "__main__":
    unittest.main()

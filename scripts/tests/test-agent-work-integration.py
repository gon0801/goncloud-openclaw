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

    def test_host_snapshot_survives_workspace_deletion_before_projection(self):
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
            "observedRevision": self.pending["result"]["sha"],
            "typedPayload": {"verdict": "approved"}, "artifactRef": str(artifact),
            "digest": hashlib.sha256(original).hexdigest(),
        })
        artifact.unlink()
        restarted = Host("host-one", self.root / "host")
        receipt = transfer_host_projection(
            self.pending, host=restarted, operation_key=key,
            progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            acknowledge_native=lambda value: value,
        )
        event = self.state_dir / "runs" / "run-1" / "evidence" / (receipt["eventId"] + ".json")
        self.assertEqual(json.loads(event.read_text())["content"], original.decode())


if __name__ == "__main__":
    unittest.main()

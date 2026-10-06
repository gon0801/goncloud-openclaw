#!/usr/bin/env python3
"""Crash boundaries between native task results and the progress queue."""

import base64
import contextlib
import copy
import hashlib
import json
import io
import os
from pathlib import Path
import queue
import re
import secrets
import signal
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import warnings


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts" / "mac"))
from contracts import AuthorizedOperation, IncidentRejected, OperationKey, operation_id  # noqa: E402
from host import Host  # noqa: E402
import native_gateway  # noqa: E402
from native_gateway import GatewayProjectionClient, main as gateway_main, transfer_gateway_projections  # noqa: E402
from progress_bridge import event_id, projection_digest, transfer_host_projection, transfer_projection  # noqa: E402
from resources import (ResourceManager, TmuxBackend, approval_prompt_identity, approval_tail,  # noqa: E402
                       load_approval_pattern)
from spool import atomic_json, canonical, incident_identity  # noqa: E402
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

    def test_projection_crash_before_enqueue_rebuilds_the_same_event_from_pending(self):
        acknowledged = []
        before = copy.deepcopy(self.pending)

        with mock.patch("progress_bridge.subprocess.run",
                        side_effect=ConnectionError("crash before enqueue")):
            with self.assertRaises(ConnectionError):
                self.transfer(acknowledged.append)
        self.assertEqual(acknowledged, [])
        queue = self.state_dir / "runs" / "run-1" / "queue"
        self.assertEqual(list(queue.glob("*.json")) if queue.exists() else [], [])
        self.assertEqual(self.pending, before)

        receipt = self.transfer(lambda value: acknowledged.append(value) or value)
        queued = list(queue.glob("*.json"))
        self.assertEqual([path.name for path in queued], [self.pending["eventId"] + ".json"])
        event = json.loads(queued[0].read_text())
        self.assertEqual(event["id"], self.pending["eventId"])
        self.assertEqual(event["verdict"], "aprobado")
        self.assertEqual(event["sha"], self.pending["result"]["sha"])
        self.assertEqual(receipt["eventId"], self.pending["eventId"])
        self.assertEqual(receipt["contentHash"], self.pending["result"]["contentHash"])
        self.assertEqual(len(acknowledged), 1)

    def test_lost_transfer_ack_and_board_outage_converge_without_repeating_the_review(self):
        before = copy.deepcopy(self.pending)
        board = self.root / "openclaw"
        board.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
assert args[:2] == ['gateway', 'call'] and args[-1] == '--json'
method = args[2]
params = json.loads(args[args.index('--params') + 1])
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps({'method':method,'params':params})+'\\n')
mode = pathlib.Path(os.environ['FAKE_MODE']).read_text().strip()
if mode == 'offline':
    sys.exit(1)
if mode == 'lost-ack' and method == 'runbook.progress.event':
    calls = [json.loads(line) for line in pathlib.Path(os.environ['FAKE_LOG']).read_text().splitlines()]
    if len([item for item in calls if item['method'] == 'runbook.progress.event']) == 1:
        sys.exit(1)
if mode == 'warning-prefix':
    print('Config warning: optional plugin was skipped')
if method == 'runbook.progress.get':
    lanes = [{'id':'B3'}] if mode == 'open-race' else []
    if mode == 'worker-conflict':
        lanes = [{'id':'B3','worker':{'id':'new-worker'},'ultimo_evento':{'at':'2026-09-30T12:02:00Z'}}]
    if mode == 'worker-safe-conflict':
        lanes = [{'id':'B3','worker':None,'ultimo_evento':{'at':'2026-09-30T11:59:00Z'}}]
    if mode == 'worker-fractional-conflict':
        lanes = [{'id':'B3','worker':{'id':'worker-1'},'ultimo_evento':{'at':'2026-09-30T12:02:00.500Z'}}]
    if mode == 'worker-native-conflict':
        lanes = [{'id':'B3','worker':{'id':'old-worker'},'ultimo_evento':{'at':'2026-09-30T12:02:00Z'}}]
    print(json.dumps({'ok':True,'revision':7,'doc':{'schema':'runbook-progress.v1','corrida':'run-1','fase':'9','lead':{'actualizado':'now'},'carriles':lanes}}))
elif mode in ('open-race', 'open-race-mismatch') and method == 'runbook.progress.event' and params['kind'] == 'run.opened':
    print(json.dumps({'ok':False,'reason':'corrida ya existe'}))
elif mode == 'legacy-stale' and method == 'runbook.progress.event' and params['kind'] == 'run.opened':
    print(json.dumps({'ok':False,'reason':'legacy projection changed or invalid'}))
elif mode == 'legacy-stale-old' and method == 'runbook.progress.event' and params['id'] == 'opened-old':
    print(json.dumps({'ok':False,'reason':'legacy projection changed or invalid'}))
elif mode == 'wrong-sha':
    print(json.dumps({'ok':False,'razon':'SHA revisado distinto'}))
elif mode == 'worker-stale-generation':
    print(json.dumps({'ok':False,'reason':'worker anterior al estado del carril'}))
elif mode in ('revision-conflict-generic', 'worker-conflict', 'worker-fractional-conflict'):
    print(json.dumps({'ok':False,'reason':'revision conflict','revision':7}))
elif mode in ('revision-conflict', 'worker-safe-conflict', 'worker-native-conflict'):
    calls = [json.loads(line) for line in pathlib.Path(os.environ['FAKE_LOG']).read_text().splitlines()]
    events = [item for item in calls if item['method'] == 'runbook.progress.event']
    print(json.dumps({'ok':False,'reason':'revision conflict','revision':7} if len(events) == 1 else {'ok':True,'revision':8}))
else:
    print(json.dumps({'ok':True,'revision':8}))
""")
        board.chmod(0o755)
        mode = self.root / "mode"
        mode.write_text("ok")
        log = self.root / "board-calls.jsonl"
        acks = []
        receipts = []

        def lose_first_native_ack(receipt):
            acks.append(receipt)
            if len(acks) == 1:
                raise ConnectionError("native transfer ACK lost")
            receipts.append(receipt)
            return receipt

        def publish():
            return subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "mac" / "progress-events.py"),
                 "--state-dir", str(self.state_dir), "--openclaw-bin", str(board),
                 "publish", "--corrida", "run-1"],
                env=dict(os.environ, FAKE_LOG=str(log), FAKE_MODE=str(mode)),
                capture_output=True, text=True,
            )

        def board_event_calls():
            if not log.exists():
                return []
            return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()
                    if json.loads(line).get("method") == "runbook.progress.event"]

        run_dir = self.state_dir / "runs" / "run-1"
        evidence_path = run_dir / "evidence" / (self.pending["eventId"] + ".json")

        with self.assertRaises(ConnectionError):
            self.transfer(lose_first_native_ack)
        mode.write_text("offline")
        outaged = publish()
        self.assertNotEqual(outaged.returncode, 0, outaged.stderr)
        retained = evidence_path.read_bytes()
        self.assertEqual(board_event_calls(), [])

        receipt = self.transfer(lose_first_native_ack)
        mode.write_text("offline")
        outaged_again = publish()
        self.assertNotEqual(outaged_again.returncode, 0, outaged_again.stderr)
        self.assertEqual(evidence_path.read_bytes(), retained)
        self.assertEqual(board_event_calls(), [])

        mode.write_text("ok")
        recovered = publish()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(list((run_dir / "queue").glob("*.json")), [])
        self.assertEqual([path.name for path in (run_dir / "sent").glob("*.json")],
                         [self.pending["eventId"] + ".json"])
        events = board_event_calls()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["params"]["id"], self.pending["eventId"])

        sent_before = list((run_dir / "sent").glob("*.json"))
        queued_before = list((run_dir / "queue").glob("*.json"))
        replayed = self.transfer(lose_first_native_ack)
        final = publish()
        self.assertEqual(final.returncode, 0, final.stderr)
        self.assertEqual(replayed, receipt)
        self.assertEqual(board_event_calls(), events)
        self.assertEqual(list((run_dir / "queue").glob("*.json")), queued_before)
        self.assertEqual(list((run_dir / "sent").glob("*.json")), sent_before)
        self.assertEqual(evidence_path.read_bytes(), retained)
        self.assertEqual(self.pending, before)

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
        self.assertIn("--device-auth", commands[0])
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
                      "instanceId": "instance-one", "producerId": "codex", "adapterId": "codex",
                      "capability": "secret", "claimId": "claim-one"}
        receipt = {"state": "host-admitted", "hostId": "host-one",
                   "instanceId": "instance-one", "claimId": "claim-one", "generation": 1}
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://127.0.0.1:18789")
        with mock.patch("native_gateway.subprocess.run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps(receipt), "")) as invoke:
            self.assertEqual(client.admit_host(assignment), receipt)
        command = invoke.call_args.args[0]
        self.assertEqual(command[3], "managedTasks.host.admit")
        self.assertIn("--device-auth", command)
        self.assertEqual(json.loads(command[command.index("--params") + 1]), {
            "hostId": "host-one", "adapterId": "codex", "instanceId": "instance-one", "claimId": "claim-one",
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
            host_type.return_value.flush_closures.return_value = (0, [])
            with mock.patch("builtins.print") as output:
                self.assertEqual(gateway_main(args + ["--host-state-dir", str(self.root / "host")]), 0)
        host_type.assert_called_once_with("host-one", str(self.root / "host"))
        output.assert_called_once_with('{"closed": 0, "reported": 1}')

    def test_flush_results_sends_results_before_closures_and_fails_on_errors(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--flush-results",
                "--host-state-dir", str(self.root / "host")]
        order = []
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("native_gateway.Host") as host_type:
            host = host_type.return_value
            host.flush.side_effect = lambda *_: order.append("results") or [{"receiptId": "r1"}]
            host.flush_closures.side_effect = lambda *_: order.append("closures") or (2, ["op-x: gateway down"])
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = gateway_main(args)
        self.assertEqual(code, 1)
        self.assertEqual(order, ["results", "closures"])
        self.assertEqual(stdout.getvalue().strip().splitlines()[-1], '{"closed": 2, "reported": 1}')
        self.assertIn("op-x: gateway down", stderr.getvalue())

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

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

        client = Client()
        args = {"evidence_root": self.evidence_root, "progress_state_dir": self.state_dir,
                "progress_client": ROOT / "scripts" / "mac" / "progress-events.py"}
        self.assertEqual(native_gateway.pump_once(client, host=host, **args),
                         {"reported": 1, "transferred": 1, "closed": 0, "incidents": 0})
        for _ in range(100):
            self.assertEqual(native_gateway.pump_once(client, host=host, **args),
                             {"reported": 0, "transferred": 0, "closed": 0, "incidents": 0})
        self.assertEqual(len(client.reports), 1)
        self.assertEqual(len(list((self.state_dir / "runs" / "run-1" / "queue").glob("*.json"))), 1)

    def test_pump_transfers_existing_projection_when_host_report_fails(self):
        class FailingHost:
            def flush(self, *_):
                raise RuntimeError("host report unavailable")

            def flush_closures(self, *_):
                return 0, []

            def flush_incidents(self, *_):
                return 0, []

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

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

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

    def test_pump_closure_failure_does_not_block_projections(self):
        class ClosureFailingHost:
            def flush(self, *_):
                return []

            def flush_closures(self, *_):
                return 0, ["op-x: gateway down"]

            def flush_incidents(self, *_):
                return 0, []

            def operation_key_for(self, *_):
                return None

        class Client:
            host_id = "host-one"

            def __init__(self):
                self.receipts = []

            def report_host_result(self, *_):
                return {field: self.pending[field] for field in
                        ("hostId", "taskId", "generation", "instanceId", "producerId")} | {
                    "resultId": "r", "receiptId": "native-one"}

            def list_pending(self, after_task_id=None, limit=100):
                return [] if self.receipts else [self.pending]

            def ack(self, receipt):
                self.receipts.append(receipt)
                return receipt

            def close_host(self, *_):
                raise AssertionError("closure failures come from the host double")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

        client = Client()
        client.pending = self.pending
        with self.assertRaisesRegex(RuntimeError, "op-x: gateway down"):
            native_gateway.pump_once(
                client, host=ClosureFailingHost(), evidence_root=self.evidence_root,
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

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

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
        times = {}
        result_path = self.root / "host" / "inbox" / (operation_id(key) + ".json")

        class ControlledClock:
            now = 0.0
            stopped = False
            published = False

            def is_set(self):
                return self.stopped

            def set(self):
                self.stopped = True

            def wait(self, interval):
                if not self.published:
                    self.now += 0.001
                    atomic_json(result_path, result)
                    times["written"] = self.now
                    self.published = True
                    self.now += interval - 0.001
                else:
                    self.now += interval
                if self.now >= 15:
                    self.set()

        clock = ControlledClock()

        class TimedHost(Host):
            def report(self, host_id, value):
                times.setdefault("detected", clock.now)
                return super().report(host_id, value)

        host = TimedHost("host-one", self.root / "host")
        persist_receipt = host.spool.acknowledge

        def timed_acknowledge(operation_id, receipt):
            clock.now += float(os.environ.get("AGENT_WORK_TEST_ACK_DELAY_SECONDS", "0"))
            persist_receipt(operation_id, receipt)
            times["receipt_persisted"] = clock.now
            clock.set()

        host.spool.acknowledge = timed_acknowledge

        class Client:
            host_id = "host-one"

            def report_host_result(self, value, artifact):
                clock.now += 0.25
                return {field: value[field] for field in
                        ("hostId", "taskId", "generation", "instanceId", "producerId")} | {
                    "resultId": hashlib.sha256(canonical(value).encode()).hexdigest(),
                    "receiptId": "native-one",
                }

            def list_pending(self, after_task_id=None, limit=100):
                return []

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

        native_gateway.watch_pump(
            Client(), host=host,
            evidence_root=self.evidence_root, progress_state_dir=self.state_dir,
            progress_client=ROOT / "scripts" / "mac" / "progress-events.py",
            stop_event=clock, interval=5.0,
        )
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

    def _changes_observation(self):
        observation = self._review_observation(
            {"verdict": "changes", "findingsRef": "artifact:findings"},
        )
        observation["lanes"]["l1"]["managed_task"]["correctionAssignment"] = {
            "target": {"kind": "agent", "agentId": "ingenieria"},
            "instructionRef": {"ref": "artifact:findings", "digest": "sha256:findings"},
            "inputRevision": {"kind": "code", "repository": "repo", "sha": "b" * 40},
            "resultContract": "review.v1",
            "continuation": {"kind": "requester"},
        }
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

    def test_lost_resolve_response_replans_the_same_durable_correction(self):
        observation = self._changes_observation()
        _, effects = reconcile(state_from_record(self.record), observation)
        durable = self._apply(self.record, effects[0])
        _, effects = reconcile(state_from_record(durable), observation)
        self.assertEqual([effect.op for effect in effects], ["resolve_task_handling"])
        planned = copy.deepcopy(effects[0].args)

        def lost_resolver(value):
            raise ConnectionError("resolve response lost")

        with self.assertRaises(ConnectionError):
            task_handoffs.resolve_task_handling(effects[0].args, lost_resolver)

        replayed = json.loads(json.dumps(durable))
        _, effects = reconcile(state_from_record(replayed), observation)
        self.assertEqual([effect.op for effect in effects], ["resolve_task_handling"])
        self.assertEqual(effects[0].args, planned)
        self.assertEqual(effects[0].args["decision"]["children"][0]["slot"], "corregir")

        changed = copy.deepcopy(observation)
        changed["lanes"]["l1"]["managed_task"]["correctionAssignment"] = {
            **observation["lanes"]["l1"]["managed_task"]["correctionAssignment"],
            "instructionRef": {"ref": "artifact:other-findings", "digest": "sha256:other"},
        }
        with self.assertRaisesRegex(task_handoffs.TaskHandlingError, "conflicts with durable intent"):
            reconcile(state_from_record(durable), changed)

    def test_two_consumers_plan_one_identical_intent(self):
        observation = self._changes_observation()
        _, first_effects = reconcile(state_from_record(self.record), observation)
        _, second_effects = reconcile(state_from_record(self.record), observation)
        self.assertEqual([effect.op for effect in first_effects], ["record_task_handling"])
        self.assertEqual(first_effects[0].args, second_effects[0].args)

        durable = self._apply(self.record, first_effects[0])
        _, applied, duplicated = reduce_events(durable, [{
            "lane": second_effects[0].lane,
            "kind": "intent.task_handling",
            "payload": second_effects[0].args,
        }])
        self.assertEqual((applied, duplicated), (0, 1))

        _, effects = reconcile(state_from_record(durable), observation)
        self.assertEqual([effect.op for effect in effects], ["resolve_task_handling"])

    def test_failed_result_returns_to_the_registered_requester(self):
        requester_assignment = {
            "target": {"kind": "agent", "agentId": "operaciones"},
            "instructionRef": {"ref": "artifact:retry", "digest": "sha256:retry"},
            "inputRevision": {"kind": "code", "repository": "repo", "sha": "b" * 40},
            "resultContract": "review.v1",
            "continuation": {"kind": "requester"},
        }
        observation = copy.deepcopy(self.observation)
        managed = observation["lanes"]["l1"]["managed_task"]
        managed["result"] = {"kind": "failed", "reasonRef": "artifact:reason"}
        managed["requesterAssignment"] = requester_assignment
        managed["decision"] = {"kind": "complete", "evidenceRef": "attacker-controlled"}

        _, effects = reconcile(state_from_record(self.record), observation)
        self.assertEqual([effect.op for effect in effects], ["record_task_handling"])
        self.assertEqual(effects[0].args["decision"], {
            "kind": "continue",
            "children": [{"slot": "solicitante", "assignment": requester_assignment}],
        })

        cancelled = copy.deepcopy(observation)
        cancelled["lanes"]["l1"]["managed_task"]["result"] = {
            "kind": "executor-cancelled", "reasonRef": "artifact:reason",
        }
        _, effects = reconcile(state_from_record(self.record), cancelled)
        self.assertEqual(effects[0].args["decision"], {
            "kind": "continue",
            "children": [{"slot": "solicitante", "assignment": requester_assignment}],
        })

        inside = copy.deepcopy(observation)
        inside["lanes"]["l1"]["managed_task"]["result"] = {
            "kind": "failed", "reasonRef": "artifact:reason",
            "requesterAssignment": {"target": {"kind": "agent", "agentId": "intruso"}},
        }
        _, effects = reconcile(state_from_record(self.record), inside)
        self.assertEqual(effects[0].args["decision"], {
            "kind": "continue",
            "children": [{"slot": "solicitante", "assignment": requester_assignment}],
        })

        orphaned = copy.deepcopy(observation)
        del orphaned["lanes"]["l1"]["managed_task"]["requesterAssignment"]
        with self.assertRaisesRegex(task_handoffs.TaskHandlingError, "requester assignment"):
            reconcile(state_from_record(self.record), orphaned)

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

    def test_real_authenticated_gateway_resolve_replays_after_lost_response(self):
        """Exercise R registration/result, G intent/retry, and one gate effect."""
        runtime_source = os.environ.get("AGENT_WORK_RUNTIME_SOURCE")
        if not runtime_source:
            self.skipTest("set AGENT_WORK_RUNTIME_SOURCE to run the cross-repository Gateway test")
        runtime_root = Path(runtime_source).resolve()
        required = (
            runtime_root / "openclaw.mjs",
            runtime_root / "scripts" / "tsx.mjs",
            runtime_root / "src" / "gateway" / "test-helpers.e2e.ts",
        )
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            self.fail("R Gateway test harness is incomplete: " + ", ".join(missing))

        state_dir = Path(tempfile.mkdtemp(prefix="agent-work-director-gateway-"))
        self.addCleanup(lambda: shutil.rmtree(state_dir, ignore_errors=True))
        gateway_state = state_dir / "gateway-state"
        gateway_state.mkdir()
        config_path = gateway_state / "openclaw.json"
        token = "t8-cross-repository-gateway-token"
        output_queue = queue.Queue()
        harness = subprocess.Popen(
            [
                "node",
                "--import",
                str(runtime_root / "scripts" / "tsx.mjs"),
                str(ROOT / "scripts/tests/fixtures/agent-work/managed-task-gateway-harness.mjs"),
            ],
            cwd=runtime_root,
            env={
                **os.environ,
                "AGENT_WORK_RUNTIME_SOURCE": str(runtime_root),
                "OPENCLAW_STATE_DIR": str(gateway_state),
                "OPENCLAW_CONFIG_PATH": str(config_path),
                "OPENCLAW_GATEWAY_TOKEN": token,
                "CROSS_GATEWAY_TOKEN": token,
            },
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        def collect_output():
            assert harness.stdout is not None
            for line in harness.stdout:
                output_queue.put(line)

        threading.Thread(target=collect_output, daemon=True).start()

        def next_message(timeout=120):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    line = output_queue.get(timeout=min(1, deadline - time.monotonic()))
                except queue.Empty:
                    if harness.poll() is not None:
                        break
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(message, dict) and message.get("type") in ("ready", "result", "error"):
                    return message
            captured = []
            while True:
                try:
                    captured.append(output_queue.get_nowait())
                except queue.Empty:
                    break
            self.fail("R Gateway harness did not answer: " + "".join(captured)[-4000:])

        def request(command):
            assert harness.stdin is not None
            harness.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
            harness.stdin.flush()
            message = next_message()
            if message.get("type") == "error":
                self.fail("R Gateway harness error: " + str(message.get("error")))
            return message.get("result")

        try:
            ready = next_message()
            self.assertEqual(ready.get("type"), "ready")
            gateway_url = ready["url"]
            caller = {
                "kind": "director",
                "authority": "director-cross-test",
                "corridaId": "cross-run",
                "decisionId": "cross-decision",
                "fence": "cross-fence",
            }
            seeded = request({"op": "seed", "caller": caller})
            task = seeded["task"]
            result = seeded["result"]
            revision = seeded["revision"]
            payload = seeded["payload"]
            receipt = {
                "taskId": result["taskId"],
                "generation": result["generation"],
                "resultDigest": result["resultDigest"],
            }
            self.assertEqual(task["taskId"], receipt["taskId"])
            self.assertEqual(payload["verdict"], "approved")

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
                "head": revision["sha"],
                "ci": {"sha": revision["sha"], "conclusion": "success"},
            }), encoding="utf-8")
            evidence_digest = hashlib.sha256(evidence.read_bytes()).hexdigest()
            managed_task = {
                "caller": caller,
                "receipt": receipt,
                "result": {
                    "kind": "produced",
                    "observedRevision": revision,
                    "typedPayload": payload,
                    "artifactRef": "artifact:review",
                },
            }
            observation_path = state_dir / "observation.json"
            observation_path.write_text(json.dumps({
                "lanes": {"l1": {
                    "managed_task": managed_task,
                    "gate": {
                        "action": "ci",
                        "evidencePath": str(evidence),
                        "evidenceDigest": evidence_digest,
                    },
                }},
            }), encoding="utf-8")

            lost_response = state_dir / "lost-response.json"
            call_count = state_dir / "gateway-call-count"
            gateway_bin = state_dir / "openclaw-lost-response"
            gateway_bin.write_text(
                "#!/usr/bin/env python3\n"
                "import pathlib, subprocess, sys\n"
                f"actual = {str(runtime_root / 'openclaw.mjs')!r}\n"
                f"count_path = pathlib.Path({str(call_count)!r})\n"
                f"lost_path = pathlib.Path({str(lost_response)!r})\n"
                "count = int(count_path.read_text()) if count_path.exists() else 0\n"
                "count += 1\n"
                "count_path.write_text(str(count))\n"
                "completed = subprocess.run([actual, *sys.argv[1:]], capture_output=True, text=True)\n"
                "if count == 1:\n"
                "    lost_path.write_text(completed.stdout)\n"
                "    sys.stderr.write('simulated lost Gateway response\\n')\n"
                "    raise SystemExit(75)\n"
                "sys.stdout.write(completed.stdout)\n"
                "sys.stderr.write(completed.stderr)\n"
                "raise SystemExit(completed.returncode)\n",
                encoding="utf-8",
            )
            gateway_bin.chmod(0o700)
            fake_gh = state_dir / "gh"
            fake_gh.write_text(
                "#!/bin/sh\n"
                f"cat {str(state_dir / 'pr.json')!r}\n",
                encoding="utf-8",
            )
            fake_gh.chmod(0o700)
            (state_dir / "pr.json").write_text(json.dumps({
                "number": 7,
                "headRefOid": revision["sha"],
                "mergedAt": None,
                "mergeCommit": None,
                "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
            }), encoding="utf-8")
            env = {
                **os.environ,
                "AGENT_WORK_RUNTIME_SOURCE": str(runtime_root),
                "CORRIDA_STATE": str(state_dir),
                "CORR_REPO_RAIZ": str(ROOT),
                "OPENCLAW_BIN": str(gateway_bin),
                "OPENCLAW_EXPECT_URL": gateway_url,
                "OPENCLAW_GATEWAY_TOKEN": token,
                "OPENCLAW_CONFIG_PATH": str(config_path),
                "OPENCLAW_STATE_DIR": str(gateway_state),
                "CORR_TOPE_RED": "45",
                "PATH": str(state_dir) + os.pathsep + os.environ["PATH"],
            }
            command = [
                "bash",
                str(ROOT / "scripts/mac/corrida.sh"),
                "reconciliar",
                "run-1",
                "--observations",
                str(observation_path),
            ]
            first = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertNotEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertIn("EXECUTED record_task_handling l1", first.stdout)
            self.assertTrue(lost_response.is_file(), first.stdout + first.stderr)
            self.assertEqual(call_count.read_text(encoding="utf-8"), "1")
            first_record = json.loads(record_path.read_text(encoding="utf-8"))
            self.assertEqual(
                [event["kind"] for event in first_record["lanes"][0]["events"]],
                ["intent.task_handling"],
            )

            second = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertIn("EXECUTED resolve_task_handling l1", second.stdout)
            self.assertIn("EXECUTED execute_task_gate l1", second.stdout)
            self.assertIn("CONVERGED", second.stdout)
            self.assertEqual(call_count.read_text(encoding="utf-8"), "2")
            final_record = json.loads(record_path.read_text(encoding="utf-8"))
            events = final_record["lanes"][0]["events"]
            self.assertEqual([event["kind"] for event in events], [
                "intent.task_handling",
                "observed.task_handled",
                "intent.task_gate",
                "gate.allow",
                "evidence.ci",
                "observed.task_gate",
            ])
            self.assertEqual(sum(event["kind"] == "gate.allow" for event in events), 1)
            gate_event = next(event for event in events if event["kind"] == "gate.allow")
            self.assertEqual(gate_event["payload"]["task_id"], receipt["taskId"])
            self.assertEqual(gate_event["payload"]["decision_id"], caller["decisionId"])
            self.assertEqual(gate_event["payload"]["evidence_digest"], evidence_digest)
            lost_receipt = json.loads(lost_response.read_text(encoding="utf-8"))
            self.assertEqual(lost_receipt["taskId"], receipt["taskId"])
            self.assertEqual(lost_receipt["childTaskIds"], [])

            inspected = request({
                "op": "inspect",
                "caller": caller,
                "taskId": receipt["taskId"],
            })
            self.assertEqual(inspected["handlingState"], "handled")
            self.assertEqual(inspected["handlingDecision"], {
                "kind": "complete",
                "evidenceRef": payload["evidenceRef"],
            })
            self.assertEqual(inspected["handlingReceipt"]["childTaskIds"], [])
            self.assertEqual(inspected["handlingReceipt"], lost_receipt)

            second_retry = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(second_retry.returncode, 0, second_retry.stderr)
            self.assertIn("CONVERGED 0", second_retry.stdout)
            self.assertEqual(json.loads(record_path.read_text(encoding="utf-8")), final_record)
            self.assertEqual(call_count.read_text(encoding="utf-8"), "2")
        finally:
            if harness.poll() is None:
                try:
                    request({"op": "stop"})
                except (BrokenPipeError, OSError, AssertionError):
                    pass
                try:
                    harness.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    harness.terminate()
                    try:
                        harness.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        harness.kill()
                        harness.wait()
            for stream in (harness.stdin, harness.stdout):
                if stream is not None:
                    stream.close()


class CliClaimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.host = Host("host-one", self.root / "host")
        self.brief = b"Review the assigned change.\n" * 190
        self.digest = hashlib.sha256(self.brief).hexdigest()
        self.assignment = {
            "target": {"kind": "cli", "hostId": "host-one", "adapterId": "codex"},
            "instructionRef": {"ref": "artifact:" + self.digest,
                               "digest": "sha256:" + self.digest},
            "inputRevision": {"kind": "artifact", "digest": "sha256:" + "a" * 64},
            "resultContract": "review.v1",
            "continuation": {"kind": "requester"},
        }
        self.claim = {
            "taskId": "task-one", "generation": 1, "claimId": "claim-one",
            "hostId": "host-one", "adapterId": "codex", "instanceId": "instance-one",
            "capability": {"taskId": "task-one", "generation": 1,
                           "producerId": "codex", "token": "secret"},
            "assignment": self.assignment,
        }
        self.coverage = {"hostAdapterCoverage": {"host-one": {"codex": "certified"}}}

    def test_gateway_claim_and_brief_use_bound_identity_and_bounded_ranges(self):
        responses = [
            subprocess.CompletedProcess([], 0, json.dumps(self.claim), ""),
            subprocess.CompletedProcess([], 0, json.dumps({
                "taskId": "task-one", "claimId": "claim-one",
                "digest": "sha256:" + self.digest, "size": len(self.brief),
                "offset": 4096, "dataBase64": base64.b64encode(self.brief[4096:]).decode(),
            }), ""),
            subprocess.CompletedProcess([], 0, "null", ""),
        ]
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://127.0.0.1:18789")
        with mock.patch("native_gateway.subprocess.run", side_effect=responses) as invoke:
            self.assertEqual(client.claim_host("codex", "instance-one"), self.claim)
            self.assertEqual(client.brief_chunk("codex", "instance-one", "task-one",
                                                "claim-one", 4096, 4096)["offset"], 4096)
            self.assertIsNone(client.claim_host("codex", "instance-one"))
        commands = [entry.args[0] for entry in invoke.call_args_list]
        self.assertEqual([command[3] for command in commands],
                         ["managedTasks.host.claim", "managedTasks.host.brief", "managedTasks.host.claim"])
        self.assertTrue(all("--device-auth" in command for command in commands))
        self.assertEqual(json.loads(commands[0][commands[0].index("--params") + 1]),
                         {"hostId": "host-one", "adapterId": "codex", "instanceId": "instance-one"})
        self.assertEqual(json.loads(commands[1][commands[1].index("--params") + 1]),
                         {"hostId": "host-one", "adapterId": "codex", "instanceId": "instance-one",
                          "taskId": "task-one", "claimId": "claim-one", "offset": 4096,
                          "length": 4096})

    def test_claim_replay_and_close_preserve_preexisting_user_session(self):
        class Backend:
            boot_id = "boot-one"

            def __init__(self):
                self.live = {"worker-one": {"bootId": self.boot_id, "nonce": "",
                                           "sessionName": "worker-one"}}
                self.stops = []
                self.revocations = []

            def mark(self, session, nonce):
                self.live[session] = {"bootId": self.boot_id, "nonce": nonce,
                                      "sessionName": session}

            def observe(self, session):
                return self.live.get(session)

            def stop(self, identity):
                self.stops.append(identity)
                self.live.pop(identity["sessionName"], None)
                return True

            def prove_absent(self, identity):
                return identity["sessionName"] not in self.live

            def revoke(self, identity):
                if self.observe(identity["sessionName"]) != identity:
                    return False
                self.revocations.append(identity)
                self.live[identity["sessionName"]] = {**identity, "nonce": ""}
                return True

        class Client:
            host_id = "host-one"

            def __init__(self, outer):
                self.outer = outer
                self.offsets = []
                self.admitted = []

            def claim_host(self, adapter_id, instance_id):
                return self.outer.claim

            def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
                self.offsets.append(offset)
                raw = self.outer.brief[offset:offset + length]
                return {"taskId": task_id, "claimId": claim_id,
                        "digest": "sha256:" + self.outer.digest,
                        "size": len(self.outer.brief), "offset": offset,
                        "dataBase64": base64.b64encode(raw).decode("ascii")}

            def admit_host(self, assignment):
                self.admitted.append(assignment)
                return {"state": "host-admitted", "hostId": "host-one",
                        "instanceId": "instance-one", "claimId": "claim-one", "generation": 1}

        backend = Backend()
        from resources import ResourceManager
        manager = ResourceManager(self.host.spool, "host-one", backend)
        client = Client(self)
        deliveries = []
        kwargs = dict(host=self.host, manager=manager, adapter_id="codex",
                      instance_id="instance-one", session="worker-one",
                      workspace_root=self.root / "workspace", deliver=lambda ref, session: deliveries.append(
                          (json.loads(Path(ref).read_text()), session)), coverage=self.coverage)
        first = native_gateway.claim_cli_once(client, **kwargs)
        second = native_gateway.claim_cli_once(client, **kwargs)
        self.assertEqual(first.status, "delivered")
        self.assertEqual(second.status, "delivered")
        self.assertEqual(len(deliveries), 1)
        self.assertEqual(deliveries[0][1], "worker-one")
        self.assertEqual(deliveries[0][0]["briefDigest"], self.digest)
        self.assertEqual(Path(deliveries[0][0]["briefRef"]).read_bytes(), self.brief)
        self.assertEqual(manager.counts()["active"], 1)
        self.assertEqual(client.offsets, [0, 4096])
        self.assertEqual(client.admitted[0]["adapterId"], "codex")
        key = OperationKey("host-one", "task-one", 1, "instance-one")
        evidence = {"kind": "result", "receipt": "durable-result-one"}
        self.assertEqual(manager.close(key, evidence).state, "ReleasedAdopted")
        self.assertEqual(manager.close(key, evidence).state, "ReleasedAdopted")
        self.assertEqual(backend.stops, [])
        self.assertEqual(len(backend.revocations), 1)
        self.assertEqual(backend.observe("worker-one"),
                         {"bootId": "boot-one", "nonce": "", "sessionName": "worker-one"})
        self.assertEqual(manager.counts()["active"], 0)

    def test_uncertified_route_never_claims(self):
        class Client:
            host_id = "host-one"

            def claim_host(self, *_):
                raise AssertionError("disabled route must not call gateway")

        with self.assertRaisesRegex(ValueError, "not certified"):
            native_gateway.claim_cli_once(Client(), host=self.host, manager=None,
                                          adapter_id="codex", instance_id="instance-one",
                                          session="worker-one", workspace_root=self.root,
                                          deliver=lambda *_: None,
                                          coverage={"hostAdapterCoverage": {"host-one": {"codex": "disabled"}}})

    def test_zero_generation_claim_is_rejected(self):
        claim = {**self.claim,
                 "generation": 0,
                 "capability": {**self.claim["capability"], "generation": 0}}

        class Client:
            host_id = "host-one"

            def claim_host(self, *_):
                return claim

        with self.assertRaisesRegex(ValueError, "host claim identity mismatch"):
            native_gateway.claim_cli_once(Client(), host=self.host, manager=None,
                                          adapter_id="codex", instance_id="instance-one",
                                          session="worker-one", workspace_root=self.root,
                                          deliver=lambda *_: None, coverage=self.coverage)

    def test_changed_brief_chunk_is_rejected_before_materialization(self):
        class Client:
            def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
                return {"taskId": task_id, "claimId": claim_id,
                        "digest": "sha256:" + self_digest, "size": 3, "offset": offset,
                        "dataBase64": base64.b64encode(b"bad").decode()}

        self_digest = self.digest
        with self.assertRaisesRegex(ValueError, "brief digest mismatch"):
            native_gateway._brief_to_workspace(Client(), self.claim, self.root / "workspace")
        self.assertEqual(list((self.root / "workspace" / "managed-briefs").iterdir()), [])


class ClosureBackend:
    def __init__(self):
        self.boot_id = "00000000-0000-0000-0000-000000000001"
        self.socket = "sock-closures"
        self.live = {}
        self.pane_gone_result = False

    def observe(self, session):
        return self.live.get(session)

    def revoke(self, identity):
        return True

    def stop(self, identity):
        for session, current in list(self.live.items()):
            if current == identity:
                del self.live[session]
                break
        return True

    def prove_absent(self, identity):
        return identity not in self.live.values()

    def launch(self, session, nonce, pid):
        self.live[session] = {
            "bootId": self.boot_id, "nonce": nonce, "socket": self.socket,
            "serverPid": 100, "serverStart": "server-birth",
            "sessionId": f"@{pid}", "paneId": f"%{pid}",
            "panePid": pid, "paneStart": f"start-{pid}",
        }

    def pane_gone(self, identity):
        return self.pane_gone_result


class ClosureFlushTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.backend = ClosureBackend()
        self.next_pid = 800

    def capture(self, calls, fail_task_ids=frozenset()):
        def close_to_runtime(assignment, state, reason, evidence_digest):
            calls.append({"taskId": assignment["taskId"], "generation": assignment["generation"],
                          "instanceId": assignment["instanceId"], "state": state, "reason": reason,
                          "evidenceDigest": evidence_digest, "adapterId": assignment.get("adapterId")})
            if assignment["taskId"] in fail_task_ids:
                raise RuntimeError("gateway unreachable")
            return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                    "state": state, "reason": reason, "evidenceDigest": evidence_digest,
                    "updatedAtMs": 1}
        return close_to_runtime

    def seed(self, task_id, instance_id, *, register=True):
        workspace = self.root / f"workspace-{instance_id}"
        workspace.mkdir()
        brief = workspace / "brief.txt"
        brief.write_text("closure seed")
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", task_id, 1, instance_id)
        if register:
            operation = AuthorizedOperation(
                key=key, producer_id="codex", capability="closure-secret",
                session=f"session-{instance_id}", workspace_ref=str(workspace), brief_ref=str(brief),
                brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
                input_revision={"kind": "code", "repository": "repo", "sha": "c" * 40},
                result_contract="review.v1", claim_id=f"claim-{instance_id}", adapter_id="codex")
            host.apply(key, operation, lambda *_: None,
                       lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                                  "hostId": a["hostId"], "instanceId": a["instanceId"],
                                  "generation": a["generation"]})
        manager = ResourceManager(host.spool, "host-one", self.backend, capacity=4)
        held = manager.reserve(key, f"session-{instance_id}", "UserAdopted")
        manager.begin_launch(key)
        self.backend.launch(f"session-{instance_id}", held.nonce, self.next_pid)
        self.next_pid += 1
        manager.attach(key)
        return host, manager, key

    def test_flush_sends_registered_closure_with_digest_and_adapter(self):
        host, manager, key = self.seed("task-close", "instance-a")
        self.backend.live.pop("session-instance-a")
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        calls = []
        closed, errors = host.flush_closures("host-one", self.capture(calls))
        self.assertEqual((closed, errors), (1, []))
        expected = hashlib.sha256(canonical(
            {"kind": "result", "receipt": "seed-result"}).encode()).hexdigest()
        self.assertEqual(calls, [{"taskId": "task-close", "generation": 1,
                                  "instanceId": "instance-a",
                                  "state": "CleanupPending",
                                  "reason": "adopted session unverifiable",
                                  "evidenceDigest": expected, "adapterId": "codex"}])
        last = host.spool.closure_last(operation_id(key))
        self.assertEqual((last["state"], last["reason"], last["evidence_digest"]),
                         ("CleanupPending", "adopted session unverifiable", expected))

    def test_flush_retries_after_network_error(self):
        host, manager, key = self.seed("task-close", "instance-a")
        self.backend.live.pop("session-instance-a")
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        calls = []
        closed, errors = host.flush_closures("host-one", self.capture(calls, {"task-close"}))
        self.assertEqual(closed, 0)
        self.assertEqual(len(errors), 1)
        self.assertIsNone(host.spool.closure_last(operation_id(key)))
        closed, errors = host.flush_closures("host-one", self.capture(calls))
        self.assertEqual((closed, errors), (1, []))
        self.assertEqual(len(calls), 2)
        with host.spool.connection() as db:
            row = db.execute("SELECT COUNT(*) FROM inbox_errors").fetchone()
        self.assertEqual(row[0], 0)

    def test_flush_second_pass_is_idempotent(self):
        host, manager, key = self.seed("task-close", "instance-a")
        self.backend.live.pop("session-instance-a")
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        calls = []
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (1, []))
        replay = []
        self.assertEqual(host.flush_closures("host-one", self.capture(replay)), (0, []))
        self.assertEqual(replay, [])

    def test_flush_pending_replaces_pending(self):
        host, manager, key = self.seed("task-close", "instance-a")
        self.backend.live.pop("session-instance-a")
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        calls = []
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (1, []))
        self.backend.pane_gone_result = True
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        calls.clear()
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (1, []))
        self.assertEqual(calls[0]["state"], "ReleasedAdopted")
        self.assertEqual(calls[0]["reason"], "adopted session gone")
        last = host.spool.closure_last(operation_id(key))
        self.assertEqual(last["state"], "ReleasedAdopted")

    def test_flush_never_sends_pending_after_accepted_terminal(self):
        host, manager_a, key_a = self.seed("task-term", "instance-1")
        _, manager_b, key_b = self.seed("task-term", "instance-2")
        self.backend.boot_id = "00000000-0000-0000-0000-000000000002"
        manager_a.close(key_a, {"kind": "result", "receipt": "seed-result"})
        self.backend.boot_id = "00000000-0000-0000-0000-000000000001"
        self.backend.live.pop("session-instance-2")
        manager_b.close(key_b, {"kind": "result", "receipt": "seed-result"})
        calls = []
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (1, []))
        self.assertEqual([call["instanceId"] for call in calls], ["instance-1"])
        self.assertEqual(calls[0]["state"], "ReleasedAdopted")
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (0, []))

    def test_flush_without_assignment_notes_inbox_error(self):
        host, manager, key = self.seed("task-orphan", "instance-orphan", register=False)
        manager.close(key, {"kind": "cancel", "receipt": "orphan-1"})
        calls = []
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (0, []))
        self.assertEqual(calls, [])
        with host.spool.connection() as db:
            row = db.execute("SELECT error FROM inbox_errors WHERE operation_id=?",
                             (operation_id(key),)).fetchone()
        self.assertEqual(row["error"], "closure without assignment")

    def test_flush_without_resources_table_returns_zero(self):
        host = Host("host-one", self.root / "host-empty")
        calls = []
        self.assertEqual(host.flush_closures("host-one", self.capture(calls)), (0, []))
        self.assertEqual(calls, [])

    def test_flush_locked_database_raises_oserror(self):
        host = Host("host-one", self.root / "host-locked")

        @contextlib.contextmanager
        def locked():
            class LockedConnection:
                def execute(self, *_):
                    raise sqlite3.OperationalError("database is locked")

            yield LockedConnection()

        with mock.patch.object(host.spool, "connection", locked):
            with self.assertRaisesRegex(OSError, "database is locked"):
                host.flush_closures("host-one", self.capture([]))

    def test_flush_results_reports_locked_closure_error_and_emits_json(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--flush-results",
                "--host-state-dir", str(self.root / "host-locked")]
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch("native_gateway.Host") as host_type:
            host = host_type.return_value
            host.flush.return_value = []
            host.flush_closures.side_effect = OSError("database is locked")
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = gateway_main(args)
        self.assertEqual(code, 1)
        self.assertEqual(stdout.getvalue().strip().splitlines()[-1], '{"closed": 0, "reported": 0}')
        self.assertIn("database is locked", stderr.getvalue())

    def test_flush_first_failure_continues_to_second(self):
        host, manager_a, key_a = self.seed("task-fail", "instance-1")
        _, manager_b, key_b = self.seed("task-pass", "instance-2")
        for session in ("session-instance-1", "session-instance-2"):
            self.backend.live.pop(session)
        manager_a.close(key_a, {"kind": "result", "receipt": "seed-result"})
        manager_b.close(key_b, {"kind": "result", "receipt": "seed-result"})
        calls = []

        def fail_once(assignment, state, reason, digest):
            calls.append(assignment["taskId"])
            if len(calls) == 1:
                raise RuntimeError("gateway unreachable")
            return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                    "state": state, "reason": reason, "evidenceDigest": digest,
                    "updatedAtMs": 1}

        closed, errors = host.flush_closures("host-one", fail_once)
        self.assertEqual(closed, 1)
        self.assertEqual(len(errors), 1)
        self.assertEqual(len(calls), 2)
        self.assertEqual(sorted(calls), ["task-fail", "task-pass"])
        lasts = [host.spool.closure_last(operation_id(key_a)) is None,
                 host.spool.closure_last(operation_id(key_b)) is None]
        self.assertEqual(sorted(lasts), [False, True])

    def test_flush_rejects_mismatched_receipt_and_stays_pending(self):
        host, manager, key = self.seed("task-close", "instance-a")
        self.backend.live.pop("session-instance-a")
        manager.close(key, {"kind": "result", "receipt": "seed-result"})
        client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://gateway")
        wrong = {"taskId": "task-other", "generation": 1, "state": "CleanupPending",
                 "reason": "adopted session unverifiable", "evidenceDigest": "0" * 64}
        with mock.patch.object(client, "_call", side_effect=lambda *_: dict(wrong)):
            closed, errors = host.flush_closures("host-one", client.close_host)
        self.assertEqual(closed, 0)
        self.assertEqual(len(errors), 1)
        self.assertIn("receipt", errors[0])
        self.assertIsNone(host.spool.closure_last(operation_id(key)))


class IncidentFlushTest(unittest.TestCase):
    INCIDENT = {"kind": "transport-unavailable", "episodeId": "session-closed-1",
                "evidenceRef": "artifact:closed"}
    EXPECTED_KEY = "host:1:transport-unavailable:session-closed-1"
    EXPECTED_DIGEST = hashlib.sha256(
        b'{"episodeId":"session-closed-1","evidenceRef":"artifact:closed",'
        b'"kind":"transport-unavailable"}').hexdigest()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def seed(self, task_id, instance_id, *, adapter_id="codex", generation=1):
        workspace = self.root / f"workspace-{instance_id}"
        workspace.mkdir()
        brief = workspace / "brief.txt"
        brief.write_text("incident seed")
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", task_id, generation, instance_id)
        operation = AuthorizedOperation(
            key=key, producer_id="codex", capability="incident-secret",
            session=f"session-{instance_id}", workspace_ref=str(workspace), brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "c" * 40},
            result_contract="review.v1", claim_id=f"claim-{instance_id}", adapter_id=adapter_id)
        host.apply(key, operation, lambda *_: None,
                   lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                              "hostId": a["hostId"], "instanceId": a["instanceId"],
                              "generation": a["generation"]})
        return host, key

    def incident_row(self, host, incident_key):
        with host.spool.connection() as db:
            row = db.execute("SELECT * FROM incidents WHERE incident_key=?",
                             (incident_key,)).fetchone()
        return dict(row) if row else None

    def test_record_incident_twice_keeps_one_row(self):
        host, key = self.seed("task-twice", "instance-twice")
        host.record_incident("host-one", key, self.INCIDENT)
        reopened = Host("host-one", self.root / "host")
        reopened.record_incident("host-one", key, self.INCIDENT)
        with reopened.spool.connection() as db:
            count = db.execute("SELECT COUNT(*) FROM incidents").fetchone()[0]
        self.assertEqual(count, 1)
        row = self.incident_row(reopened, self.EXPECTED_KEY)
        self.assertEqual(row["status"], "pending")
        self.assertEqual(row["incident_key"], self.EXPECTED_KEY)
        self.assertEqual(row["incident_digest"], self.EXPECTED_DIGEST)
        with self.assertRaises(ValueError):
            reopened.record_incident("host-one", key,
                                     {**self.INCIDENT, "evidenceRef": "artifact:recaptured"})
        self.assertEqual(self.incident_row(reopened, self.EXPECTED_KEY)["incident_digest"],
                         self.EXPECTED_DIGEST)

    def test_incident_identity_keys_per_kind(self):
        cases = [
            ("permission-required",
             {"kind": "permission-required", "promptIdentity": "prompt-1",
              "evidenceRef": "artifact:dialog"},
             "host:1:permission-required:prompt-1"),
            ("deadline-missed",
             {"kind": "deadline-missed", "episodeId": "late-1", "evidenceRef": "artifact:late"},
             "host:1:deadline-missed:late-1"),
            ("transport-unavailable", self.INCIDENT, self.EXPECTED_KEY),
            ("invalid-result",
             {"kind": "invalid-result", "episodeId": "bad-1", "evidenceRef": "artifact:bad"},
             "host:1:invalid-result:bad-1"),
        ]
        for kind, incident, expected in cases:
            with self.subTest(kind):
                self.assertEqual(incident_identity(1, incident)[0], expected)

    def test_record_incident_rejects_invalid_input(self):
        host, key = self.seed("task-main", "instance-main")
        _, zero_key = self.seed("task-zero", "instance-zero", generation=0)
        _, bare_key = self.seed("task-bare", "instance-bare", adapter_id="")
        ghost_key = OperationKey("host-one", "task-ghost", 1, "instance-ghost")
        bad_incidents = [
            ("extra key", {"kind": "transport-unavailable", "episodeId": "e-1",
                           "evidenceRef": "artifact:one", "extra": "nope"}),
            ("missing evidenceRef", {"kind": "transport-unavailable", "episodeId": "e-1"}),
            ("unknown kind", {"kind": "recovery-transport-failure", "episodeId": "e-1",
                              "evidenceRef": "artifact:one"}),
            ("episodeId too long", {"kind": "transport-unavailable", "episodeId": "e" * 257,
                                    "evidenceRef": "artifact:one"}),
            ("episodeId 258 utf16 units", {"kind": "transport-unavailable",
                                           "episodeId": "\U0001f4c9" * 129,
                                           "evidenceRef": "artifact:one"}),
            ("episodeId not text", {"kind": "transport-unavailable", "episodeId": 7,
                                    "evidenceRef": "artifact:one"}),
            ("not an object", ["transport-unavailable"]),
            ("permission without promptIdentity", {"kind": "permission-required",
                                                   "evidenceRef": "artifact:dialog"}),
        ]
        for name, incident in bad_incidents:
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    host.record_incident("host-one", key, incident)
        for name, args in [
                ("generation 0 operation", ("host-one", zero_key, self.INCIDENT)),
                ("operation without adapterId", ("host-one", bare_key, self.INCIDENT)),
                ("unknown operation", ("host-one", ghost_key, self.INCIDENT)),
                ("foreign host", ("host-two", key, self.INCIDENT))]:
            with self.subTest(name):
                with self.assertRaises(ValueError):
                    host.record_incident(*args)
        with host.spool.connection() as db:
            count = db.execute("SELECT COUNT(*) FROM incidents").fetchone()[0]
        self.assertEqual(count, 0)

    def test_flush_incidents_sends_once(self):
        host, key = self.seed("task-send", "instance-send")
        host.record_incident("host-one", key, self.INCIDENT)
        calls = []

        def send(assignment, incident):
            calls.append({"assignment": assignment, "incident": incident})
            return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                    "incidentKey": self.EXPECTED_KEY, "incidentDigest": self.EXPECTED_DIGEST}

        self.assertEqual(host.flush_incidents("host-one", send), (1, []))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["incident"], self.INCIDENT)
        assignment = calls[0]["assignment"]
        self.assertEqual((assignment["hostId"], assignment["taskId"], assignment["generation"],
                          assignment["instanceId"], assignment["adapterId"]),
                         ("host-one", "task-send", 1, "instance-send", "codex"))
        row = self.incident_row(host, self.EXPECTED_KEY)
        self.assertEqual(row["status"], "sent")
        self.assertEqual(json.loads(row["receipt_json"]),
                         {"taskId": "task-send", "generation": 1,
                          "incidentKey": self.EXPECTED_KEY,
                          "incidentDigest": self.EXPECTED_DIGEST})
        self.assertEqual(host.flush_incidents("host-one", send), (0, []))
        host.record_incident("host-one", key, self.INCIDENT)
        self.assertEqual(host.flush_incidents("host-one", send), (0, []))
        self.assertEqual(len(calls), 1)

    def test_flush_incidents_retries_after_lost_response(self):
        host, key = self.seed("task-lost", "instance-lost")
        host.record_incident("host-one", key, self.INCIDENT)
        calls = []

        def send(assignment, incident):
            calls.append(incident)
            if len(calls) == 1:
                raise TimeoutError("runtime stored the receipt but its ACK was lost")
            return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                    "incidentKey": self.EXPECTED_KEY, "incidentDigest": self.EXPECTED_DIGEST}

        sent, errors = host.flush_incidents("host-one", send)
        self.assertEqual((sent, len(errors)), (0, 1))
        self.assertEqual(self.incident_row(host, self.EXPECTED_KEY)["status"], "pending")
        self.assertEqual(host.flush_incidents("host-one", send), (1, []))
        self.assertEqual(calls, [self.INCIDENT, self.INCIDENT])
        self.assertEqual(host.flush_incidents("host-one", send), (0, []))
        self.assertEqual(len(calls), 2)

    def test_flush_incidents_marks_conflict_rejected_without_retry(self):
        host, key = self.seed("task-reject", "instance-reject")
        host.record_incident("host-one", key, self.INCIDENT)
        calls = []

        def rejecting_send(assignment, incident):
            calls.append(incident)
            raise IncidentRejected("Managed task incident conflict")

        sent, errors = host.flush_incidents("host-one", rejecting_send)
        self.assertEqual((sent, len(errors)), (0, 1))
        self.assertIn("Managed task incident conflict", errors[0])
        row = self.incident_row(host, self.EXPECTED_KEY)
        self.assertEqual(row["status"], "rejected")
        self.assertEqual(row["error"], "Managed task incident conflict")
        host.flush_incidents("host-one", rejecting_send)
        self.assertEqual(len(calls), 1)

        late = {"kind": "deadline-missed", "episodeId": "late-1", "evidenceRef": "artifact:late"}
        host.record_incident("host-one", key, late)
        failures = []

        def failing_send(assignment, incident):
            failures.append(incident)
            raise RuntimeError("gateway unreachable")

        sent, errors = host.flush_incidents("host-one", failing_send)
        self.assertEqual((sent, len(errors)), (0, 1))
        self.assertEqual(self.incident_row(host, "host:1:deadline-missed:late-1")["status"],
                         "pending")
        host.flush_incidents("host-one", failing_send)
        self.assertEqual(failures, [late, late])
        self.assertEqual(self.incident_row(host, self.EXPECTED_KEY)["status"], "rejected")


class IncidentClientTest(unittest.TestCase):
    INCIDENT = {"kind": "transport-unavailable", "episodeId": "session-closed-1",
                "evidenceRef": "artifact:closed"}
    EXPECTED_KEY = "host:1:transport-unavailable:session-closed-1"
    EXPECTED_DIGEST = hashlib.sha256(
        b'{"episodeId":"session-closed-1","evidenceRef":"artifact:closed",'
        b'"kind":"transport-unavailable"}').hexdigest()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.client = GatewayProjectionClient("/isolated/openclaw", "host-one",
                                              "ws://127.0.0.1:18789")
        self.assignment = {"hostId": "host-one", "taskId": "task-x", "generation": 1,
                           "instanceId": "instance-x", "producerId": "codex",
                           "capability": "incident-secret", "adapterId": "codex"}

    def seed(self, task_id, instance_id, *, state="host", adapter_id="codex", generation=1):
        workspace = self.root / f"workspace-{state}-{instance_id}"
        workspace.mkdir(parents=True)
        brief = workspace / "brief.txt"
        brief.write_text("incident seed")
        host = Host("host-one", self.root / state)
        key = OperationKey("host-one", task_id, generation, instance_id)
        operation = AuthorizedOperation(
            key=key, producer_id="codex", capability="incident-secret",
            session=f"session-{instance_id}", workspace_ref=str(workspace), brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "c" * 40},
            result_contract="review.v1", claim_id=f"claim-{instance_id}", adapter_id=adapter_id)
        host.apply(key, operation, lambda *_: None,
                   lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                              "hostId": a["hostId"], "instanceId": a["instanceId"],
                              "generation": a["generation"]})
        return host, key

    def incident_row(self, host, incident_key):
        with host.spool.connection() as db:
            row = db.execute("SELECT * FROM incidents WHERE incident_key=?",
                             (incident_key,)).fetchone()
        return dict(row) if row else None

    def receipt(self, task_id="task-x", **changes):
        base = {"taskId": task_id, "generation": 1,
                "incidentKey": self.EXPECTED_KEY, "incidentDigest": self.EXPECTED_DIGEST}
        return {**base, **changes}

    def rejection(self, message, error_type="gateway_request_error"):
        return subprocess.CompletedProcess(
            [], 1, json.dumps({"ok": False, "error": {"type": error_type,
                                                      "code": "INVALID_REQUEST",
                                                      "message": message,
                                                      "retryable": False}}), "")

    def test_client_sends_exact_params_and_checks_receipt(self):
        with mock.patch("native_gateway.subprocess.run",
                        return_value=subprocess.CompletedProcess(
                            [], 0, json.dumps(self.receipt()), "")) as invoke:
            receipt = self.client.report_host_incident(self.assignment, self.INCIDENT)
        self.assertEqual(receipt, self.receipt())
        command = invoke.call_args.args[0]
        self.assertEqual(command[:4], ["/isolated/openclaw", "gateway", "call",
                                       "managedTasks.host.incident"])
        self.assertIn("--device-auth", command)
        self.assertEqual(json.loads(command[command.index("--params") + 1]),
                         {"hostId": "host-one", "adapterId": "codex",
                          "instanceId": "instance-x",
                          "capability": {"taskId": "task-x", "generation": 1,
                                         "producerId": "codex", "token": "incident-secret"},
                          "incident": self.INCIDENT})
        for changes in ({"taskId": "other"}, {"generation": 2},
                        {"incidentKey": "host:1:transport-unavailable:other"},
                        {"incidentDigest": "b" * 64}):
            with self.subTest(changes):
                with mock.patch("native_gateway.subprocess.run",
                                return_value=subprocess.CompletedProcess(
                                    [], 0, json.dumps(self.receipt(**changes)), "")):
                    with self.assertRaisesRegex(RuntimeError, "receipt identity mismatch"):
                        self.client.report_host_incident(self.assignment, self.INCIDENT)
        for name, assignment in [
                ("without adapterId", {**self.assignment, "adapterId": None}),
                ("empty adapterId", {**self.assignment, "adapterId": ""}),
                ("generation 0", {**self.assignment, "generation": 0}),
                ("generation True", {**self.assignment, "generation": True})]:
            with self.subTest(name):
                with mock.patch("native_gateway.subprocess.run") as invoke:
                    with self.assertRaises(ValueError):
                        self.client.report_host_incident(assignment, self.INCIDENT)
                self.assertFalse(invoke.called)

    def test_lost_response_resends_the_same_incident(self):
        host, key = self.seed("task-lost", "instance-lost")
        host.record_incident("host-one", key, self.INCIDENT)
        responses = [
            subprocess.CompletedProcess([], 1, "", "lost Gateway response"),
            subprocess.CompletedProcess([], 0, json.dumps(self.receipt(task_id="task-lost")), ""),
        ]
        with mock.patch("native_gateway.subprocess.run", side_effect=responses) as invoke:
            sent, errors = host.flush_incidents("host-one", self.client.report_host_incident)
            self.assertEqual((sent, len(errors)), (0, 1))
            self.assertIn("rejected request", errors[0])
            self.assertEqual(self.incident_row(host, self.EXPECTED_KEY)["status"], "pending")
            self.assertEqual(host.flush_incidents("host-one", self.client.report_host_incident),
                             (1, []))
            self.assertEqual(host.flush_incidents("host-one", self.client.report_host_incident),
                             (0, []))
        self.assertEqual(invoke.call_count, 2)
        commands = [call.args[0] for call in invoke.call_args_list]
        self.assertEqual(commands[0], commands[1])

    def test_definitive_rejection_is_not_retried(self):
        host, key = self.seed("task-reject", "instance-reject", state="host-reject")
        host.record_incident("host-one", key, self.INCIDENT)
        with mock.patch("native_gateway.subprocess.run",
                        return_value=self.rejection("Managed task incident conflict")) as invoke:
            sent, errors = host.flush_incidents("host-one", self.client.report_host_incident)
        self.assertEqual((sent, len(errors)), (0, 1))
        self.assertIn("Managed task incident conflict", errors[0])
        row = self.incident_row(host, self.EXPECTED_KEY)
        self.assertEqual(row["status"], "rejected")
        self.assertEqual(row["error"], "Managed task incident conflict")
        with mock.patch("native_gateway.subprocess.run") as invoke:
            self.assertEqual(host.flush_incidents("host-one", self.client.report_host_incident),
                             (0, []))
            self.assertEqual(invoke.call_count, 0)

        with self.subTest("other error type is not definitive"):
            other_host, other_key = self.seed("task-other", "instance-other", state="host-other")
            fresh = {"kind": "invalid-result", "episodeId": "bad-1",
                     "evidenceRef": "artifact:bad"}
            other_host.record_incident("host-one", other_key, fresh)
            with mock.patch("native_gateway.subprocess.run",
                            return_value=self.rejection(
                                "Managed task incident conflict", error_type="other_error")):
                sent, errors = other_host.flush_incidents(
                    "host-one", self.client.report_host_incident)
            self.assertEqual((sent, len(errors)), (0, 1))
            self.assertEqual(
                self.incident_row(other_host, "host:1:invalid-result:bad-1")["status"],
                "pending")

        host, key = self.seed("task-retry", "instance-retry", state="host-retry")
        late = {"kind": "deadline-missed", "episodeId": "late-1", "evidenceRef": "artifact:late"}
        host.record_incident("host-one", key, late)
        unauthorized = self.rejection("Managed host device or adapter is not authorized")
        with mock.patch("native_gateway.subprocess.run",
                        side_effect=[unauthorized, unauthorized]) as invoke:
            sent, errors = host.flush_incidents("host-one", self.client.report_host_incident)
            self.assertEqual((sent, len(errors)), (0, 1))
            self.assertEqual(
                self.incident_row(host, "host:1:deadline-missed:late-1")["status"], "pending")
            self.assertEqual(invoke.call_count, 1)
            host.flush_incidents("host-one", self.client.report_host_incident)
            self.assertEqual(invoke.call_count, 2)


class IncidentPumpTest(unittest.TestCase):
    INCIDENT = {"kind": "transport-unavailable", "episodeId": "session-closed-1",
                "evidenceRef": "artifact:closed"}
    EXPECTED_KEY = "host:1:transport-unavailable:session-closed-1"
    EXPECTED_DIGEST = hashlib.sha256(
        b'{"episodeId":"session-closed-1","evidenceRef":"artifact:closed",'
        b'"kind":"transport-unavailable"}').hexdigest()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def seed(self, task_id, instance_id):
        workspace = self.root / f"workspace-{instance_id}"
        workspace.mkdir(parents=True)
        brief = workspace / "brief.txt"
        brief.write_text("incident seed")
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", task_id, 1, instance_id)
        operation = AuthorizedOperation(
            key=key, producer_id="codex", capability="incident-secret",
            session=f"session-{instance_id}", workspace_ref=str(workspace), brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "c" * 40},
            result_contract="review.v1", claim_id=f"claim-{instance_id}", adapter_id="codex")
        host.apply(key, operation, lambda *_: None,
                   lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                              "hostId": a["hostId"], "instanceId": a["instanceId"],
                              "generation": a["generation"]})
        return host, key

    def pump_args(self, name):
        return {"evidence_root": self.root / f"evidence-{name}",
                "progress_state_dir": self.root / f"progress-{name}",
                "progress_client": str(self.root / f"progress-events-{name}.py")}

    def test_pump_incident_failure_does_not_block_results(self):
        events = []

        class IncidentFailingHost:
            def flush(self, *_):
                events.append("results")
                return []

            def flush_closures(self, *_):
                events.append("closures")
                return 0, []

            def flush_incidents(self, *_):
                events.append("incidents")
                raise OSError("database is locked")

            def operation_key_for(self, *_):
                return None

        class Client:
            host_id = "host-one"

            def report_host_result(self, *_):
                raise AssertionError("no results are pending in this test")

            def list_pending(self, after_task_id=None, limit=100):
                return []

            def close_host(self, *_):
                raise AssertionError("closure failures come from the host double")

            def report_host_incident(self, *_):
                raise AssertionError("incident failures come from the host double")

        client = Client()
        with self.assertRaises(Exception) as caught:
            native_gateway.pump_once(
                client, host=IncidentFailingHost(), cli_claim=lambda: events.append("claim"),
                **self.pump_args("failure"),
            )
        self.assertIs(type(caught.exception), RuntimeError)
        self.assertIn("database is locked", str(caught.exception))
        self.assertEqual(events, ["results", "closures", "incidents", "claim"])

    def test_pump_sends_an_incident_once_across_idle_polls(self):
        host, key = self.seed("task-idle", "instance-idle")
        host.record_incident("host-one", key, self.INCIDENT)
        calls = []

        class RecordingClient:
            host_id = "host-one"

            def report_host_result(self, *_):
                raise AssertionError("no results are pending in this test")

            def list_pending(self, after_task_id=None, limit=100):
                return []

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, assignment, incident):
                calls.append((assignment, incident))
                return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                        "incidentKey": IncidentPumpTest.EXPECTED_KEY,
                        "incidentDigest": IncidentPumpTest.EXPECTED_DIGEST}

        client = RecordingClient()
        self.assertEqual(native_gateway.pump_once(client, host=host, **self.pump_args("idle")),
                         {"reported": 0, "transferred": 0, "closed": 0, "incidents": 1})
        for _ in range(100):
            self.assertEqual(native_gateway.pump_once(client, host=host, **self.pump_args("idle")),
                             {"reported": 0, "transferred": 0, "closed": 0, "incidents": 0})
        self.assertEqual(len(calls), 1)


class SilentFailureTest(unittest.TestCase):
    OP_ID = "8557dce188b70f89bf47a35740de23ad29e83fbc9fad56773eee13cc66d32571"
    CLOSED = {"kind": "transport-unavailable", "episodeId": "session-closed",
              "evidenceRef": "host-operation:8557dce188b70f89bf47a35740de23ad29e83fbc9fad56773eee13cc66d32571"}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.backend = ClosureBackend()
        self.next_pid = 900

    def seed(self, task_id="task-silent", instance_id="instance-silent", deliver=lambda *_: None):
        workspace = self.root / f"workspace-{instance_id}"
        workspace.mkdir()
        brief = workspace / "brief.txt"
        brief.write_text("silent seed")
        host = Host("host-one", self.root / "host")
        key = OperationKey("host-one", task_id, 1, instance_id)
        manager = ResourceManager(host.spool, "host-one", self.backend, capacity=4)
        session = f"session-{instance_id}"
        held = manager.reserve(key, session, "UserAdopted")
        manager.begin_launch(key)
        self.backend.launch(session, held.nonce, self.next_pid)
        self.next_pid += 1
        manager.attach(key)
        operation = AuthorizedOperation(
            key=key, producer_id="codex", capability="silent-secret", session=session,
            workspace_ref=str(workspace), brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "c" * 40},
            result_contract="review.v1", claim_id=f"claim-{instance_id}", adapter_id="codex")
        observation = host.apply(key, operation, deliver,
                                 lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                                            "hostId": a["hostId"], "instanceId": a["instanceId"],
                                            "generation": a["generation"]})
        return host, manager, key, observation

    def close_session(self, key):
        self.backend.live.pop(f"session-{key.instance_id}")
        self.backend.pane_gone_result = True

    def rows(self, host):
        with host.spool.connection() as db:
            return [(row["incident_key"], row["status"], row["incident_json"])
                    for row in db.execute("SELECT * FROM incidents ORDER BY incident_key")]

    def write_result(self, host, key, *, valid):
        assignment = json.loads(host.spool.get(operation_id(key))["operation_json"])
        if not valid:
            atomic_json(Path(assignment["resultRef"]),
                        {"schema": "agent-work.result.v1", "kind": "produced"})
            return
        artifact = Path(assignment["workspaceRef"]) / "review.txt"
        artifact.write_text("VEREDICTO aprobado\n")
        atomic_json(Path(assignment["resultRef"]), {
            "schema": "agent-work.result.v1", "kind": "produced",
            "hostId": assignment["hostId"], "taskId": assignment["taskId"],
            "generation": assignment["generation"], "instanceId": assignment["instanceId"],
            "producerId": assignment["producerId"], "capability": assignment["capability"],
            "observedRevision": assignment["inputRevision"],
            "typedPayload": {"verdict": "approved", "evidenceRef": "review.txt"},
            "artifactRef": str(artifact),
            "digest": hashlib.sha256(artifact.read_bytes()).hexdigest()})

    def test_closed_session_records_one_transport_incident_across_100_passes(self):
        with mock.patch("spool.time.time", return_value=1000.0):
            host, manager, key, _ = self.seed()
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1001.0,
                                                     deadline_seconds=60), [])
        self.assertEqual(self.rows(host), [])
        self.close_session(key)
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1002.0,
                                                     deadline_seconds=60),
                         ["host:1:transport-unavailable:session-closed"])
        for second in range(99):
            self.assertEqual(Host("host-one", self.root / "host").detect_silent_failures(
                "host-one", manager.session_gone, now=1060.0 + second, deadline_seconds=60), [])
        self.assertEqual(self.rows(host), [(
            "host:1:transport-unavailable:session-closed", "pending",
            '{"episodeId":"session-closed","evidenceRef":"host-operation:'
            '8557dce188b70f89bf47a35740de23ad29e83fbc9fad56773eee13cc66d32571",'
            '"kind":"transport-unavailable"}')])
        _, _, other, _ = self.seed("task-other", "instance-other")
        self.close_session(other)
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=2000.0),
                         ["host:1:transport-unavailable:session-closed"])
        with host.spool.connection() as db:
            self.assertEqual([row[0] for row in db.execute("SELECT task_id FROM incidents ORDER BY task_id")],
                             ["task-other", "task-silent"])

    def test_closed_session_requires_positive_proof(self):
        host, manager, key, _ = self.seed()
        self.backend.live.pop("session-instance-silent")
        with self.subTest("pane pid still answers"):
            self.backend.pane_gone_result = False
            self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1.0), [])
        with self.subTest("another tmux server"):
            self.backend.pane_gone_result = True
            self.backend.socket = "sock-other"
            self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1.0), [])
            self.backend.socket = "sock-closures"
        with self.subTest("tmux unreadable"):
            def unreadable(session):
                raise OSError("tmux socket busy")
            with mock.patch.object(self.backend, "observe", unreadable):
                self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1.0), [])
        with self.subTest("result unreadable"):
            with mock.patch.object(Host, "collect", side_effect=OSError("disk busy")):
                self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1.0), [])
        self.assertEqual(self.rows(host), [])

    def test_invalid_result_is_one_incident_and_a_valid_result_still_reports(self):
        with mock.patch("spool.time.time", return_value=1000.0):
            host, manager, key, _ = self.seed()
        self.write_result(host, key, valid=False)
        self.close_session(key)
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=9000.0,
                                                     deadline_seconds=60),
                         ["host:1:invalid-result:invalid-result"])
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=9001.0,
                                                     deadline_seconds=60), [])
        self.assertEqual([row[0] for row in self.rows(host)], ["host:1:invalid-result:invalid-result"])
        self.write_result(host, key, valid=True)
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=9002.0,
                                                     deadline_seconds=60), [])
        self.assertEqual([(result["taskId"], result["typedPayload"]["verdict"])
                          for result in host.pending("host-one")], [("task-silent", "approved")])

    def test_deadline_counts_from_durable_delivery_once(self):
        with mock.patch("spool.time.time", return_value=1000.0):
            host, manager, key, _ = self.seed()
        self.assertEqual(Host("host-one", self.root / "host").spool.delivered_at(self.OP_ID), 1000.0)
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=10.0 ** 9), [])
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1059.0,
                                                     deadline_seconds=60), [])
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=1060.0,
                                                     deadline_seconds=60),
                         ["host:1:deadline-missed:deadline"])
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=5000.0,
                                                     deadline_seconds=60), [])
        self.assertEqual([row[0] for row in self.rows(host)], ["host:1:deadline-missed:deadline"])
        for invalid in (0, -1, True, "60"):
            with self.subTest(deadline=invalid):
                with self.assertRaises(ValueError):
                    host.detect_silent_failures("host-one", manager.session_gone, now=5000.0,
                                                deadline_seconds=invalid)

    def test_uncertain_and_reported_operations_never_raise_incidents(self):
        def lost(*_):
            raise OSError("tmux send-keys failed")
        host, manager, uncertain, observation = self.seed("task-uncertain", "instance-uncertain", lost)
        self.assertEqual(observation.status, "uncertain")
        self.close_session(uncertain)
        _, _, reported, _ = self.seed("task-reported", "instance-reported")
        self.write_result(host, reported, valid=True)
        self.assertEqual(len(host.pending("host-one")), 1)
        self.backend.live.pop("session-instance-reported")
        self.assertEqual(host.detect_silent_failures("host-one", manager.session_gone, now=10.0 ** 9,
                                                     deadline_seconds=60), [])
        self.assertEqual(self.rows(host), [])

    def test_pump_detects_before_sending_and_sends_once(self):
        host, manager, key, _ = self.seed()
        self.close_session(key)
        calls = []

        class RecordingClient:
            host_id = "host-one"

            def report_host_result(self, *_):
                raise AssertionError("no results are pending in this test")

            def list_pending(self, after_task_id=None, limit=100):
                return []

            def close_host(self, *_):
                raise AssertionError("no closures are pending in this test")

            def report_host_incident(self, assignment, incident):
                calls.append((assignment["taskId"], incident))
                key_, digest = incident_identity(assignment["generation"], incident)
                return {"taskId": assignment["taskId"], "generation": assignment["generation"],
                        "incidentKey": key_, "incidentDigest": digest}

        def watch():
            return host.detect_silent_failures("host-one", manager.session_gone, now=2.0)

        args = {"evidence_root": self.root / "evidence", "progress_state_dir": self.root / "progress",
                "progress_client": str(self.root / "progress-events.py")}
        client = RecordingClient()
        self.assertEqual(native_gateway.pump_once(client, host=host, cli_watch=watch, **args),
                         {"reported": 0, "transferred": 0, "closed": 0, "incidents": 1, "detected": 1})
        for _ in range(100):
            self.assertEqual(native_gateway.pump_once(client, host=host, cli_watch=watch, **args),
                             {"reported": 0, "transferred": 0, "closed": 0, "incidents": 0,
                              "detected": 0})
        self.assertEqual(calls, [("task-silent", self.CLOSED)])

    def test_pump_watch_failure_does_not_block_incidents(self):
        events = []

        class Host_:
            def flush(self, *_):
                events.append("results")
                return []

            def flush_closures(self, *_):
                events.append("closures")
                return 0, []

            def flush_incidents(self, *_):
                events.append("incidents")
                return 0, []

            def operation_key_for(self, *_):
                return None

        class Client:
            host_id = "host-one"

            def list_pending(self, after_task_id=None, limit=100):
                return []

            def report_host_result(self, *_):
                raise AssertionError("unexpected result")

            def close_host(self, *_):
                raise AssertionError("unexpected closure")

            def report_host_incident(self, *_):
                raise AssertionError("unexpected incident")

        def watch():
            events.append("watch")
            raise OSError("tmux socket busy")

        with self.assertRaises(Exception) as caught:
            native_gateway.pump_once(
                Client(), host=Host_(), cli_claim=lambda: events.append("claim"), cli_watch=watch,
                evidence_root=self.root / "e", progress_state_dir=self.root / "p",
                progress_client=str(self.root / "c.py"))
        self.assertIs(type(caught.exception), RuntimeError)
        self.assertIn("tmux socket busy", str(caught.exception))
        self.assertEqual(events, ["results", "closures", "watch", "incidents", "claim"])

    def test_watch_entrypoint_wires_cli_watch_with_the_host_deadline(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--evidence-root", str(self.root / "e"),
                "--progress-state-dir", str(self.root / "p"), "--progress-client", "/isolated/c.py",
                "--watch", "--host-state-dir", str(self.root / "host")]
        cli = ["--cli-adapter-id", "codex", "--cli-instance-id", "instance-one",
               "--cli-session", "worker-one", "--cli-workspace-root", str(self.root / "w"),
               "--cli-tmux-socket", "sock-watch"]
        with mock.patch("native_gateway.watch_pump") as watch:
            gateway_main(args)
        self.assertIsNone(watch.call_args.kwargs["cli_watch"])
        with mock.patch("native_gateway.watch_pump") as watch:
            gateway_main(args + cli + ["--cli-deadline-seconds", "900"])
        wired = watch.call_args.kwargs["cli_watch"]
        with mock.patch.object(Host, "detect_silent_failures", return_value=[]) as detect, \
                mock.patch("time.time", return_value=4242.0):
            self.assertEqual(wired(), [])
        self.assertEqual(detect.call_args.args[0], "host-one")
        self.assertIs(detect.call_args.args[1].__func__, ResourceManager.session_gone)
        self.assertEqual(detect.call_args.kwargs["now"], 4242.0)
        self.assertEqual(detect.call_args.kwargs["deadline_seconds"], 900.0)
        stop = threading.Event()
        with mock.patch("native_gateway.pump_once", side_effect=lambda *_, **__: stop.set() or {}) as pump:
            native_gateway.watch_pump(object(), host=None, evidence_root=None, progress_state_dir=None,
                                      progress_client=None, stop_event=stop, cli_watch=wired)
        self.assertIs(pump.call_args.kwargs.get("cli_watch"), wired)
        with mock.patch("sys.stderr"), mock.patch("native_gateway.watch_pump") as never:
            with self.assertRaises(SystemExit):
                gateway_main(args + cli + ["--cli-deadline-seconds", "0"])
        never.assert_not_called()


class PromptBackend(ClosureBackend):
    """ClosureBackend whose panes show a scripted screen; liveness of capture is TmuxBackend's job."""

    def __init__(self):
        super().__init__()
        self.screens = {}
        self.sessions = {}

    def launch(self, session, nonce, pid):
        super().launch(session, nonce, pid)
        self.sessions[f"%{pid}"] = session

    def capture(self, identity):
        screen = self.screens.get(self.sessions.get(identity["paneId"]))
        if isinstance(screen, Exception):
            raise screen
        return screen


class SilentPromptTest(unittest.TestCase):
    LIB_SH = ROOT / "scripts" / "mac" / "corrida" / "lib.sh"
    WATCHER = ROOT / "scripts" / "mac" / "tmux-activity-watch.sh"
    # Measured zcode dialog (test-tmux-activity-watch.sh 2f) with a braille spinner and a clock on
    # the waiting line, and an ASCII spinner with a token counter on the last line.
    BLOCKED = ("Permission - Bash\nHigh risk tools require explicit approval\n sed -n 1,2p tipos.d.ts\n"
               "> Allow once\n  Always allow in this project\n  Deny\n"
               "⠋ Waiting for approval 0:07 (7s)\n girando |  ↑ 1.2k tokens\n")
    # Measured claude dialog (test-tmux-activity-watch.sh 2g).
    PROCEED = (" Detected a destructive delete command:\n rm -rf /tmp/e1verif /tmp/mig1.log\n"
               " Run it? [plugin:claude-code-harness]\n Do you want to proceed?\n   1. Yes\n   2. No\n"
               " Esc to cancel  Tab to amend\n")
    IDLE = "trabajo normal\n esc to interrupt\n"
    BLOCKED_ID = "prompt-a676f37c2271c679cf49abcbd92eb67d3d1935dc493645b761f5f28bee18bea1"
    PROCEED_ID = "prompt-7d94515e70c2994a231d611d9a75feb4b34c8c89d290da292dc115ae5ac52ff3"
    ONCE_ID = "prompt-168511d24d9ee03122b3200f929be11eaaedad45cb0ecb20a95f549b3e3f4d0f"
    BLOCKED_1 = "host:1:permission-required:" + BLOCKED_ID + "-1"
    BLOCKED_2 = "host:1:permission-required:" + BLOCKED_ID + "-2"
    BLOCKED_3 = "host:1:permission-required:" + BLOCKED_ID + "-3"
    PROCEED_1 = "host:1:permission-required:" + PROCEED_ID + "-1"
    PROCEED_2 = "host:1:permission-required:" + PROCEED_ID + "-2"
    OP_ID = SilentFailureTest.OP_ID

    seed = SilentFailureTest.seed
    close_session = SilentFailureTest.close_session
    rows = SilentFailureTest.rows
    write_result = SilentFailureTest.write_result

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.backend = PromptBackend()
        self.next_pid = 900

    def watch(self, host, manager, *, now, deadline=None):
        def read(key):
            return manager.prompt_identity(key, load_approval_pattern(self.LIB_SH))
        return host.detect_silent_failures("host-one", manager.session_gone, now=now, deadline_seconds=deadline,
                                           prompt_identity=read)

    def step(self, manager, screen, *, now=1.0):
        """One pass with the default task's pane showing screen, from a freshly opened Host."""
        self.backend.screens["session-instance-silent"] = screen
        return self.watch(Host("host-one", self.root / "host"), manager, now=now)

    def keys(self, host):
        return [row[0] for row in self.rows(host)]

    def test_lib_sh_pattern_compiles_cleanly_and_matches_the_measured_dialogs(self):
        re.purge()
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            pattern = load_approval_pattern(self.LIB_SH)
        self.assertEqual([str(warning.message) for warning in caught], [])
        self.assertIn("APROBACION_RE='" + pattern.pattern.replace("[\\[", "[[") + "'\n", self.LIB_SH.read_text())
        measured = ["Do you want to proceed?", "> Allow once", "Would you like to allow this network access?",
                    " Run this command?", "  $ echo hola > /tmp/pp-cursor-agent.txt Waiting for approval...",
                    "  Do you trust the contents of this directory?", "  Trust this folder?",
                    "  Press enter to confirm or esc to go back", "  navigate  Enter select  Esc exit",
                    "  Use arrow keys to navigate, Enter to select, or press the key shown",
                    " Overwrite existing config? [y/N]", " Continue? (yes/no)"]
        for line in measured:
            with self.subTest(dialog=line):
                self.assertIsNotNone(pattern.search(line))
        idle = [" ? for shortcuts", " esc to interrupt",
                " yolo  K3-256k thinking: high   @: mention files | ! to run a shell command",
                "  Auto mode (shift + tab to cycle)", "  tab agents  ctrl+p commands",
                "  Shift+Tab:mode  |  Ctrl+x:shortcuts", " /help commands  /status details",
                " Voice input ( + v to start)", " Ask Codex to do anything",
                " Wait for the active turn or press Ctrl+C before running a slash command.",
                "Continue y/n", "y/n"]
        for line in idle:
            with self.subTest(idle=line):
                self.assertIsNone(pattern.search(line))
        missing = self.root / "lib.sh"
        missing.write_text("APPROVAL_RE='allow once'\n")
        with self.assertRaisesRegex(ValueError, "APROBACION_RE"):
            load_approval_pattern(missing)

    def test_prompt_identity_ignores_clocks_spinners_tokens_and_the_cursor(self):
        pattern = load_approval_pattern(self.LIB_SH)
        self.assertEqual(approval_prompt_identity(self.BLOCKED, pattern), self.BLOCKED_ID)
        repaints = {
            "clock on the dialog line": self.BLOCKED.replace("0:07 (7s)", "1:02:03 (12.5s)"),
            "braille spinner on the dialog line": self.BLOCKED.replace("⠋", "⠙"),
            "ascii spinner and token counter": self.BLOCKED.replace("girando |  ↑ 1.2k", "girando /  ↑ 3.4k"),
            "cursor moved": self.BLOCKED.replace("> Allow once\n  Always", "  Allow once\n> Always"),
        }
        for name, screen in repaints.items():
            with self.subTest(name):
                self.assertEqual(approval_prompt_identity(screen, pattern), self.BLOCKED_ID)
        self.assertEqual(approval_prompt_identity(self.PROCEED, pattern), self.PROCEED_ID)
        work = "".join(f"linea de trabajo {n}\n" for n in range(14))
        self.assertEqual(approval_prompt_identity("> Allow once\n" + work, pattern), self.ONCE_ID)
        self.assertEqual(approval_prompt_identity("> Allow once\n" + work.replace("\n", "\n\n  \n"), pattern),
                         self.ONCE_ID)
        self.assertIsNone(approval_prompt_identity("> Allow once\n" + work + "linea de trabajo 14\n", pattern))
        self.assertIsNone(approval_prompt_identity(self.IDLE, pattern))

    def test_tail_is_the_watcher_tail(self):
        source = self.WATCHER.read_text()
        function = source[source.index("approval_tail() {"):]
        function = function[:function.index("\n}\n") + 3]
        lines = re.search(r"^APPROVAL_TAIL_LINES=\$\{APPROVAL_TAIL_LINES:-(\d+)\}$", source, re.M).group(1)
        screens = [self.BLOCKED, self.PROCEED,
                   "> Allow once\n" + "".join(f"trabajo {n} 3s\n\n" for n in range(20)),
                   "a b\n \n\t\n \r\nreloj 12:34:56 1.5h 0.25s 7m\n… café ⠋\n", ""]
        for screen in screens:
            with self.subTest(screen=screen[:24]):
                watcher = subprocess.run(["bash", "-c", function + "approval_tail"], input=screen.encode(),
                                         capture_output=True, check=True,
                                         env={**os.environ, "LC_ALL": "C", "APPROVAL_TAIL_LINES": lines})
                self.assertEqual(approval_tail(screen), watcher.stdout.decode("ascii").splitlines())

    @unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
    def test_capture_reads_only_the_recorded_pane_with_real_tmux(self):
        tmux = shutil.which("tmux")
        socket = f"agent-work-prompt-{os.getpid()}-{secrets.token_hex(4)}"
        socket_file = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / socket

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-f", "/dev/null", "-L", socket, *args], capture_output=True, text=True)

        self.addCleanup(lambda: socket_file.unlink() if socket_file.exists() else None)
        self.addCleanup(tmux_cmd, "kill-server")

        def start(session, text="Permission - Bash\\n> Allow once\\n  Deny\\n", painted="Allow once"):
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", session, "-x", "80", "-y", "20", "/bin/sh", "-c",
                                      f"printf '{text}'; exec /bin/sleep 30").returncode, 0)
            for _ in range(100):
                if painted in tmux_cmd("capture-pane", "-p", "-t", f"={session}:").stdout:
                    return
                time.sleep(0.05)
            self.fail(f"{session} never painted {painted}")

        start("worker")
        start("keeper")
        start("idle", "trabajo normal\\n", "trabajo normal")
        backend = TmuxBackend(tmux, socket)
        host = Host("host-one", self.root / "host")
        manager = ResourceManager(host.spool, "host-one", backend, capacity=2)
        key = OperationKey("host-one", "task-tmux", 1, "instance-tmux")
        idle = OperationKey("host-one", "task-idle", 1, "instance-idle")
        for resource, session in ((key, "worker"), (idle, "idle")):
            held = manager.reserve(resource, session, "UserAdopted")
            manager.begin_launch(resource)
            backend.mark(session, held.nonce)
            self.assertEqual(manager.attach(resource).state, "Running")
        identity = backend.observe("worker")
        self.assertEqual(backend.capture(identity).split("\n")[:3], ["Permission - Bash", "> Allow once", "  Deny"])
        pattern = load_approval_pattern(self.LIB_SH)
        self.assertEqual(manager.prompt_identity(key, pattern), self.ONCE_ID)
        self.assertEqual(manager.prompt_identity(idle, pattern), "")
        self.assertEqual(tmux_cmd("kill-session", "-t", "=worker").returncode, 0)
        self.assertIsNone(backend.capture(identity))
        self.assertIsNone(manager.prompt_identity(key, pattern))
        start("worker")
        self.assertIsNone(backend.capture(identity))
        self.assertIsNone(manager.prompt_identity(key, pattern))
        self.assertEqual(tmux_cmd("kill-server").returncode, 0)
        start("worker")
        self.assertEqual(tmux_cmd("display-message", "-p", "-t", "=worker:", "#{pane_id}").stdout.strip(),
                         identity["paneId"])
        self.assertIsNone(backend.capture(identity))
        self.assertIsNone(manager.prompt_identity(key, pattern))

    def test_one_dialog_is_one_incident_across_100_repainted_passes(self):
        host, manager, key, _ = self.seed()
        self.assertEqual(self.step(manager, self.BLOCKED), [])
        self.assertEqual(self.step(manager, self.BLOCKED), [self.BLOCKED_1])
        for second in range(98):
            repainted = self.BLOCKED.replace("girando |", "girando " + "|/-\\"[second % 4]).replace(
                "0:07", f"0:{second % 60:02d}").replace("⠋", "⠙" if second % 2 else "⠋")
            self.assertEqual(self.step(manager, repainted, now=2.0 + second), [])
        self.assertEqual(self.rows(host), [(
            self.BLOCKED_1, "pending",
            '{"evidenceRef":"host-operation:8557dce188b70f89bf47a35740de23ad29e83fbc9fad56773eee13cc66d32571",'
            '"kind":"permission-required",'
            '"promptIdentity":"prompt-a676f37c2271c679cf49abcbd92eb67d3d1935dc493645b761f5f28bee18bea1-1"}')])

    def test_the_same_dialog_after_two_clean_passes_is_a_new_episode_across_host_restarts(self):
        host, manager, key, _ = self.seed()
        passes = [(self.BLOCKED, []), (self.BLOCKED, [self.BLOCKED_1]), (self.IDLE, []), (self.IDLE, []),
                  (self.BLOCKED, []), (self.BLOCKED, [self.BLOCKED_2]), (self.BLOCKED, [])]
        for number, (screen, expected) in enumerate(passes):
            self.assertEqual(self.step(manager, screen), expected, f"pass {number}")
        self.assertEqual(self.keys(host), [self.BLOCKED_1, self.BLOCKED_2])
        # The episode lives in the spool file, not in this process.
        with contextlib.closing(sqlite3.connect(self.root / "host" / "host.sqlite")) as db:
            self.assertEqual(db.execute("SELECT open_identity,episode,candidate,seen,clean FROM dialog_watch "
                                        "WHERE operation_id=?", (self.OP_ID,)).fetchall(),
                             [(self.BLOCKED_ID, 2, None, 0, 0)])

    def test_one_clean_pass_does_not_close_the_episode(self):
        host, manager, key, _ = self.seed()
        passes = [(self.BLOCKED, []), (self.BLOCKED, [self.BLOCKED_1]), (self.IDLE, []),
                  (self.BLOCKED, []), (self.BLOCKED, []), (self.IDLE, []), (self.BLOCKED, [])]
        for number, (screen, expected) in enumerate(passes):
            self.assertEqual(self.step(manager, screen), expected, f"pass {number}")
        self.assertEqual(self.keys(host), [self.BLOCKED_1])

    def test_a_dialog_seen_in_single_passes_never_counts(self):
        host, manager, key, _ = self.seed()
        for number, screen in enumerate([self.BLOCKED, self.IDLE, self.BLOCKED, self.IDLE, self.PROCEED,
                                         self.IDLE, self.IDLE, self.BLOCKED, self.IDLE]):
            self.assertEqual(self.step(manager, screen), [], f"pass {number}")
        self.assertEqual(self.rows(host), [])

    def test_a_yes_no_line_in_the_output_for_one_pass_raises_nothing(self):
        host, manager, key, _ = self.seed()
        output = "".join(f"npm warn deprecated paquete-{n}\n" for n in range(20))
        self.assertEqual(self.step(manager, output + "Overwrite existing config? [y/N] y\n"), [])
        self.assertEqual(self.step(manager, output + "Overwrite existing config? [y/N] y\n" + output), [])
        self.assertEqual(self.step(manager, output + "listo\n"), [])
        self.assertEqual(self.rows(host), [])

    def test_a_different_dialog_without_a_clean_gap_is_another_episode(self):
        host, manager, key, _ = self.seed()
        passes = [(self.BLOCKED, []), (self.BLOCKED, [self.BLOCKED_1]), (self.IDLE, []), (self.PROCEED, []),
                  (self.PROCEED, [self.PROCEED_2]), (self.BLOCKED, []), (self.PROCEED, []), (self.BLOCKED, []),
                  (self.BLOCKED, [self.BLOCKED_3])]
        for number, (screen, expected) in enumerate(passes):
            self.assertEqual(self.step(manager, screen), expected, f"pass {number}")
        self.assertEqual(self.keys(host), [self.PROCEED_2, self.BLOCKED_1, self.BLOCKED_3])

    def test_a_crash_while_saving_the_dialog_neither_repeats_nor_skips_an_episode(self):
        host, manager, key, _ = self.seed()
        self.assertEqual(self.step(manager, self.BLOCKED), [])
        with mock.patch("spool.Spool.save_dialog_state", side_effect=OSError("disk full")):
            try:
                self.step(manager, self.BLOCKED)
            except OSError:
                pass
        # The dialog goes away right after the crash and the same wording comes back later.
        passes = [(self.IDLE, []), (self.IDLE, []), (self.BLOCKED, []), (self.BLOCKED, [self.BLOCKED_2])]
        for number, (screen, expected) in enumerate(passes):
            self.assertEqual(self.step(manager, screen), expected, f"pass {number} after the crash")
        self.assertEqual(self.keys(host), [self.BLOCKED_1, self.BLOCKED_2])

    def test_dialog_and_deadline_are_two_incidents(self):
        with mock.patch("spool.time.time", return_value=1000.0):
            host, manager, key, _ = self.seed()
        self.backend.screens["session-instance-silent"] = self.PROCEED
        self.assertEqual(self.watch(host, manager, now=1059.0, deadline=60), [])
        self.assertEqual(self.watch(host, manager, now=1060.0, deadline=60),
                         [self.PROCEED_1, "host:1:deadline-missed:deadline"])
        self.assertEqual(self.watch(host, manager, now=5000.0, deadline=60), [])
        self.assertEqual(self.keys(host), ["host:1:deadline-missed:deadline", self.PROCEED_1])

    def test_closed_session_or_invalid_result_wins_over_the_dialog(self):
        host, manager, closed, _ = self.seed("task-closed", "instance-closed")
        _, _, invalid, _ = self.seed("task-invalid", "instance-invalid")
        self.backend.screens["session-instance-closed"] = self.PROCEED
        self.backend.screens["session-instance-invalid"] = self.PROCEED
        self.close_session(closed)
        self.write_result(host, invalid, valid=False)
        self.assertEqual(self.watch(host, manager, now=1.0),
                         ["host:1:transport-unavailable:session-closed", "host:1:invalid-result:invalid-result"])
        self.assertEqual(self.watch(host, manager, now=2.0), [])
        self.assertEqual(self.watch(host, manager, now=3.0), [])
        self.assertEqual(self.keys(host),
                         ["host:1:invalid-result:invalid-result", "host:1:transport-unavailable:session-closed"])

    def test_unreadable_unbound_or_released_panes_are_neither_dialog_nor_clean(self):
        host, manager, key, _ = self.seed()
        try:
            self.assertEqual(self.step(manager, OSError("tmux socket busy")), [])
        except OSError as exc:
            self.fail(f"an unreadable pane escaped the pass: {exc}")
        self.assertEqual(self.step(manager, self.BLOCKED), [])
        self.assertEqual(self.step(manager, self.BLOCKED), [self.BLOCKED_1])
        for screen in (OSError("tmux socket busy"), OSError("tmux socket busy"), None, None):
            self.assertEqual(self.step(manager, screen), [])
        self.assertEqual(self.step(manager, self.BLOCKED), [])
        self.assertEqual(self.step(manager, self.BLOCKED), [])
        self.assertEqual(manager.close(key, {"kind": "cancel", "receipt": "cancel-1"}).state, "ReleasedAdopted")
        self.assertEqual(self.step(manager, self.PROCEED), [])
        self.assertEqual(self.step(manager, self.PROCEED), [])
        self.assertEqual(self.keys(host), [self.BLOCKED_1])

    def test_watch_entrypoint_reads_dialogs_with_the_lib_sh_pattern(self):
        args = ["--openclaw-bin", "/isolated/openclaw", "--host-id", "host-one",
                "--expect-url", "ws://127.0.0.1:18789", "--evidence-root", str(self.root / "e"),
                "--progress-state-dir", str(self.root / "p"), "--progress-client", "/isolated/c.py",
                "--watch", "--host-state-dir", str(self.root / "host"),
                "--cli-adapter-id", "codex", "--cli-instance-id", "instance-one",
                "--cli-session", "worker-one", "--cli-workspace-root", str(self.root / "w"),
                "--cli-tmux-socket", "sock-watch"]
        with mock.patch("native_gateway.watch_pump") as watch:
            gateway_main(args)
        with mock.patch.object(Host, "detect_silent_failures", return_value=[]) as detect:
            self.assertEqual(watch.call_args.kwargs["cli_watch"](), [])
        reader = detect.call_args.kwargs.get("prompt_identity")
        self.assertTrue(callable(reader), "main must pass prompt_identity to the detector")
        key = OperationKey("host-one", "task-x", 1, "instance-one")
        with mock.patch.object(ResourceManager, "prompt_identity", autospec=True,
                               return_value="prompt-x") as read:
            self.assertEqual(reader(key), "prompt-x")
        manager, seen_key, pattern = read.call_args.args
        self.assertIs(manager, detect.call_args.args[1].__self__)
        self.assertEqual(seen_key, key)
        self.assertEqual(pattern.pattern, load_approval_pattern(self.LIB_SH).pattern)
        self.assertIsNotNone(pattern.search("DO YOU WANT TO PROCEED?"))


    def test_the_episode_and_its_incident_commit_together(self):
        for table in ("incidents", "dialog_watch"):
            with self.subTest(crash_writing=table):
                self.setUp()
                host, manager, key, _ = self.seed()
                self.assertEqual(self.step(manager, self.BLOCKED), [])
                with contextlib.closing(sqlite3.connect(self.root / "host" / "host.sqlite")) as db:
                    for event in ("INSERT", "UPDATE"):
                        db.execute(f"CREATE TRIGGER crash_{event} BEFORE {event} ON {table} "
                                   "BEGIN SELECT RAISE(ABORT, 'disk full'); END")
                    db.commit()
                with self.assertRaises(sqlite3.DatabaseError):
                    self.step(manager, self.BLOCKED)
                with contextlib.closing(sqlite3.connect(self.root / "host" / "host.sqlite")) as db:
                    db.execute("DROP TRIGGER crash_INSERT")
                    db.execute("DROP TRIGGER crash_UPDATE")
                    db.commit()
                self.assertEqual(self.rows(host), [], "an incident was kept without its episode")
                self.assertEqual(self.step(manager, self.BLOCKED), [self.BLOCKED_1],
                                 "an episode was kept without its incident")

    def test_a_pane_without_a_resource_row_is_neither_dialog_nor_clean(self):
        host, manager, key, _ = self.seed()
        with host.spool.connection() as db:
            db.execute("DELETE FROM resources")
        try:
            self.assertIsNone(manager.prompt_identity(key, load_approval_pattern(self.LIB_SH)))
            self.assertEqual(self.step(manager, self.BLOCKED), [])
        except ValueError as exc:
            self.fail(f"a pane without a resource row escaped the pass: {exc}")

    def shim_backend(self, text):
        shim = self.root / "tmux-shim"
        shim.write_text(f"#!/bin/sh\nprintf '{text}'\n")
        shim.chmod(0o755)
        return TmuxBackend(str(shim), "sock-shim", boot_id="1.000000")

    def test_capture_replaces_bytes_that_are_not_utf8(self):
        backend = self.shim_backend("\\377> Allow once\\n")
        identity = {"sessionName": "worker", "paneId": "%0"}
        with mock.patch.object(TmuxBackend, "observe", return_value=identity):
            try:
                self.assertEqual(backend.capture(identity), "\ufffd> Allow once\n")
            except UnicodeDecodeError as exc:
                self.fail(f"a byte that is not UTF-8 escaped capture: {exc}")

    def test_capture_rejects_a_pane_replaced_while_it_was_read(self):
        backend = self.shim_backend("> Allow once\\n")
        identity = {"sessionName": "worker", "paneId": "%0"}
        with mock.patch.object(TmuxBackend, "observe", side_effect=[identity, None]):
            self.assertIsNone(backend.capture(identity))

    def test_idle_passes_stop_writing_once_the_episode_is_closed(self):
        host, manager, key, _ = self.seed()
        for screen in (self.BLOCKED, self.BLOCKED, self.IDLE, self.IDLE):
            self.step(manager, screen)
        with mock.patch("spool.Spool.save_dialog_state") as save, mock.patch("spool.Spool._put_dialog") as put:
            for _ in range(20):
                self.assertEqual(self.step(manager, self.IDLE), [])
        save.assert_not_called()
        put.assert_not_called()
        with contextlib.closing(sqlite3.connect(self.root / "host" / "host.sqlite")) as db:
            self.assertEqual(db.execute("SELECT open_identity,episode,candidate,seen,clean FROM dialog_watch").fetchall(),
                             [(None, 1, None, 0, 2)])

class ClientCloseTest(unittest.TestCase):
    def setUp(self):
        self.client = GatewayProjectionClient("/isolated/openclaw", "host-one", "ws://gateway")
        self.assignment = {"hostId": "host-one", "taskId": "task-x", "generation": 2,
                           "instanceId": "instance-x", "producerId": "codex",
                           "capability": "tok", "adapterId": "codex"}

    def receipt(self, **changes):
        base = {"taskId": "task-x", "generation": 2, "state": "CleanupPending",
                "reason": "reason-text", "evidenceDigest": "a" * 64, "updatedAtMs": 5}
        return {**base, **changes}

    def test_close_host_sends_contract_params_and_accepts_matching_receipt(self):
        seen = {}

        def fake_call(method, params, **kwargs):
            seen["method"] = method
            seen["params"] = params
            return self.receipt()

        with mock.patch.object(self.client, "_call", side_effect=fake_call):
            receipt = self.client.close_host(self.assignment, "CleanupPending",
                                             "reason-text", "a" * 64)
        self.assertEqual(seen["method"], "managedTasks.host.close")
        self.assertEqual(seen["params"], {
            "hostId": "host-one", "instanceId": "instance-x", "adapterId": "codex",
            "capability": {"taskId": "task-x", "generation": 2,
                           "producerId": "codex", "token": "tok"},
            "state": "CleanupPending", "reason": "reason-text",
            "evidenceDigest": "a" * 64,
        })
        self.assertEqual(receipt["updatedAtMs"], 5)

    def test_close_host_omits_absent_adapter(self):
        assignment = {**self.assignment, "adapterId": None}
        seen = {}

        def fake_call(method, params, **kwargs):
            seen["params"] = params
            return self.receipt(state="ReleasedAdopted", reason="adopted session gone")

        with mock.patch.object(self.client, "_call", side_effect=fake_call):
            self.client.close_host(assignment, "ReleasedAdopted", "adopted session gone", "a" * 64)
        self.assertNotIn("adapterId", seen["params"])

    def test_close_host_rejects_mismatched_receipt_identity(self):
        for changes in ({"taskId": "other"}, {"generation": 3},
                        {"state": "AbsenceVerified"}, {"evidenceDigest": "b" * 64}):
            with mock.patch.object(self.client, "_call", side_effect=lambda *_: self.receipt(**changes)):
                with self.assertRaisesRegex(RuntimeError, "closure receipt identity mismatch"):
                    self.client.close_host(self.assignment, "CleanupPending", "reason-text", "a" * 64)

    def test_close_host_rejects_invalid_boundary(self):
        with self.assertRaisesRegex(ValueError, "generation"):
            self.client.close_host({**self.assignment, "generation": 0},
                                   "CleanupPending", "reason-text", "a" * 64)
        with self.assertRaisesRegex(ValueError, "state"):
            self.client.close_host(self.assignment, "Closing", "reason-text", "a" * 64)
        with self.assertRaisesRegex(ValueError, "reason"):
            self.client.close_host(self.assignment, "CleanupPending", "", "a" * 64)
        with self.assertRaisesRegex(ValueError, "digest"):
            self.client.close_host(self.assignment, "CleanupPending", "reason-text", "zz")


if __name__ == "__main__":
    unittest.main()

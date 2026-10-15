#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from dataclasses import replace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))

from contracts import AuthorizedOperation, OperationKey
from cutover_live import uncertain_operations
import host
from host import Host, main as host_main, operation_id


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class HostReceipts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-work-host-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.brief = self.workspace / "brief.txt"
        self.brief.write_text("Revisa el cambio.\n")
        self.artifact = self.workspace / "evidence.txt"
        self.artifact.write_text("pruebas verdes\n")
        self.host = Host("mac-test", self.root / "host")
        self.key = OperationKey("mac-test", "task-1", 2, "instance-1")
        self.operation = AuthorizedOperation(
            key=self.key,
            producer_id="reviewer",
            capability="secret-bound-to-task-1-generation-2",
            session="worker-1",
            workspace_ref=str(self.workspace),
            brief_ref=str(self.brief),
            brief_digest=digest(self.brief.read_bytes()),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
            result_contract="review.v1",
            claim_id="claim-1",
        )

    def admit(self, assignment):
        return {"state": "host-admitted", "claimId": assignment["claimId"],
                "hostId": assignment["hostId"], "instanceId": assignment["instanceId"],
                "generation": assignment["generation"]}

    def apply(self, key, operation, deliver):
        return self.host.apply(key, operation, deliver, self.admit)

    def report(self, **overrides):
        body = {
            "schema": "agent-work.result.v1",
            "kind": "produced",
            "hostId": "mac-test",
            "taskId": "task-1",
            "generation": 2,
            "instanceId": "instance-1",
            "producerId": "reviewer",
            "capability": self.operation.capability,
            "observedRevision": self.operation.input_revision,
            "typedPayload": {"verdict": "approved", "evidenceRef": "evidence.txt"},
            "artifactRef": str(self.artifact),
            "digest": digest(self.artifact.read_bytes()),
        }
        body.update(overrides)
        return body

    def test_host_receipts_replay_and_lost_ack(self):
        deliveries = []
        first = self.apply(self.key, self.operation, lambda ref, session: deliveries.append((ref, session)))
        self.assertEqual(first.status, "delivered")
        self.assertEqual(len(deliveries), 1)
        self.assertEqual(deliveries[0][1], "worker-1")
        assignment = json.loads(Path(deliveries[0][0]).read_text())
        self.assertEqual(assignment["taskId"], "task-1")
        self.assertEqual(assignment["generation"], 2)
        self.assertEqual(assignment["claimId"], "claim-1")

        with self.assertRaisesRegex(ValueError, "active instance"):
            other_key = OperationKey("mac-test", "task-2", 1, "instance-1")
            self.apply(other_key, replace(self.operation, key=other_key), lambda *_: None)

        report = self.report()
        results = [self.host.report("mac-test", report) for _ in range(100)]
        self.assertEqual(len({r.result_id for r in results}), 1)
        self.assertEqual(len(list((self.root / "host" / "results").glob("*.json"))), 1)
        self.assertEqual(len(deliveries), 1)

        expected = {
            "hostId": "mac-test", "taskId": "task-1", "generation": 2,
            "instanceId": "instance-1", "producerId": "reviewer",
            "resultId": results[0].result_id, "receiptId": "native-receipt-1",
        }
        calls = []
        def runtime_report(payload, artifact_bytes):
            calls.append((payload, artifact_bytes))
            if len(calls) == 1:
                raise TimeoutError("runtime stored receipt but its ACK was lost")
            return expected

        with self.assertRaises(TimeoutError):
            self.host.flush("mac-test", runtime_report)
        self.assertEqual(len(self.host.pending("mac-test")), 1)
        self.assertEqual(self.host.flush("mac-test", runtime_report), [expected])
        self.assertEqual(self.host.flush("mac-test", runtime_report), [])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls, [(report, self.artifact.read_bytes())] * 2)
        reopened = Host("mac-test", self.root / "host")
        self.assertEqual(reopened.report("mac-test", report).result_id, results[0].result_id)
        self.assertEqual(reopened.receipt("mac-test", self.key), expected)
        self.assertEqual(reopened.apply(self.key, self.operation,
                                        lambda *_: self.fail("duplicate delivery"),
                                        self.admit).status, "acknowledged")

    def test_host_requires_native_admission_before_delivery(self):
        delivered = []
        with self.assertRaisesRegex(ValueError, "admission receipt mismatch"):
            self.host.apply(self.key, self.operation, lambda *_: delivered.append(True),
                            lambda a: {**self.admit(a), "instanceId": "foreign"})
        self.assertEqual(delivered, [])
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "registered")
        self.assertEqual(self.apply(self.key, self.operation,
                                    lambda *_: delivered.append(True)).status, "delivered")
        self.assertEqual(delivered, [True])

    def test_cli_that_reads_only_the_assignment_gets_accepted_and_reported(self):
        operation = replace(self.operation, adapter_id="opencode")
        observation = self.apply(self.key, operation, lambda *_: None)
        self.assertEqual(observation.status, "typed")
        assignment = json.loads(Path(observation.assignment_ref).read_text())
        protocol = assignment["protocol"]
        self.assertEqual(set(protocol["fill"]), {"typedPayload", "artifactRef", "digest"})
        Path(assignment["acceptRef"]).write_text(json.dumps(protocol["accept"]))
        Path(assignment["resultRef"]).write_text(json.dumps({
            **protocol["result"],
            "typedPayload": {"verdict": "approved", "evidenceRef": "evidence.txt"},
            "artifactRef": str(self.artifact),
            "digest": digest(self.artifact.read_bytes()),
        }))
        self.assertTrue(self.host.take_acceptance("mac-test", self.key))
        self.assertIsNotNone(self.host.collect("mac-test", self.key))
        self.assertEqual(self.host.pending("mac-test"), [self.report()])

    def test_a_cli_result_with_extra_fields_reaches_the_runtime_with_only_its_schema(self):
        # Live canary 2026-10-11: GLM copied claimId into result.v1, and R's strict schema refused the report.
        operation = replace(self.operation, adapter_id="opencode")
        observation = self.apply(self.key, operation, lambda *_: None)
        assignment = json.loads(Path(observation.assignment_ref).read_text())
        protocol = assignment["protocol"]
        # Live canary 8 2026-10-12: deepseek staged the accept object in /tmp, and opencode asked for /tmp.
        self.assertEqual(protocol["steps"][0],
                         "Before any other work, write the accept object as JSON to acceptRef, atomically: create "
                         "the temporary file inside the directory that holds acceptRef (never in /tmp or any other "
                         "directory), write the JSON there, then rename it onto acceptRef.")
        self.assertEqual(protocol["steps"][2],
                         "Write, as JSON to resultRef and atomically in the same way (a temporary file inside the "
                         "directory that holds resultRef, never in /tmp, renamed onto resultRef), one object: "
                         "exactly the fields shown in result with their values unchanged, plus artifactRef, digest "
                         "and typedPayload as three more fields at the top level of that same object, each holding "
                         "what fill describes for it. Do not write a field named fill. Write no other field.")
        # Live first task of qwen 2026-10-13 (task 15190266): it nested the three fields under "fill".
        self.assertEqual(sorted(protocol["fill"]), ["artifactRef", "digest", "typedPayload"])
        # Live canary A 2026-10-13: glm left a helper script in /tmp and `rm /tmp/…` ended its session.
        self.assertEqual(protocol["steps"][3],
                         "Keep every helper script and scratch file inside the directory that holds acceptRef, and "
                         "create, read or delete nothing in /tmp or anywhere else outside workspaceRef and that "
                         "directory: the CLI denies those commands.")
        self.assertEqual(len(protocol["steps"]), 4)
        Path(assignment["acceptRef"]).write_text(json.dumps(protocol["accept"]))
        Path(assignment["resultRef"]).write_text(json.dumps({
            **protocol["result"],
            "claimId": assignment["claimId"],
            "typedPayload": {"verdict": "approved", "evidenceRef": "evidence.txt"},
            "artifactRef": str(self.artifact),
            "digest": digest(self.artifact.read_bytes()),
        }))
        self.assertTrue(self.host.take_acceptance("mac-test", self.key))
        self.assertIsNotNone(self.host.collect("mac-test", self.key))
        self.assertEqual(self.host.pending("mac-test"), [self.report()])

    def test_lost_native_admission_ack_retries_before_first_delivery(self):
        delivered = []
        admissions = []

        def lost_ack(assignment):
            admissions.append(assignment["claimId"])
            raise TimeoutError("native admission committed but ACK lost")

        with self.assertRaises(TimeoutError):
            self.host.apply(self.key, self.operation, lambda *_: delivered.append(True), lost_ack)
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "registered")
        self.assertEqual(self.apply(self.key, self.operation,
                                    lambda *_: delivered.append(True)).status, "delivered")
        self.assertEqual(admissions, ["claim-1"])
        self.assertEqual(delivered, [True])

    def test_host_receipts_snapshot_survives_workspace_mutation_restart_and_lost_ack(self):
        self.apply(self.key, self.operation, lambda *_: None)
        report = self.report()
        original = self.artifact.read_bytes()
        result_id = self.host.report("mac-test", report).result_id
        self.artifact.write_text("changed after ACK\n")
        restarted = Host("mac-test", self.root / "host")
        self.assertEqual(restarted.result_snapshot("mac-test", self.key), (report, original))
        calls = []
        def runtime(result, artifact_bytes):
            calls.append((result, artifact_bytes))
            if len(calls) == 1:
                raise TimeoutError("runtime ACK lost")
            return {"hostId": "mac-test", "taskId": "task-1", "generation": 2,
                    "instanceId": "instance-1", "producerId": "reviewer",
                    "resultId": result_id, "receiptId": "native-r1"}
        with self.assertRaises(TimeoutError):
            restarted.flush("mac-test", runtime)
        self.artifact.unlink()
        self.assertEqual(restarted.report("mac-test", report).result_id, result_id)
        with self.assertRaisesRegex(ValueError, "observed revision mismatch"):
            restarted.report("mac-test", dict(report, observedRevision="other-revision"))
        self.assertEqual(len(list((self.root / "host" / "artifacts" / operation_id(self.key)).glob("*.bin"))), 1)
        self.assertEqual(Host("mac-test", self.root / "host").flush("mac-test", runtime)[0]["resultId"], result_id)
        self.assertEqual(calls, [(report, original), (report, original)])

    def test_host_receipts_a_result_r_refuses_does_not_hold_back_the_others(self):
        self.apply(self.key, self.operation, lambda *_: None)
        self.host.report("mac-test", self.report())
        second = OperationKey("mac-test", "task-2", 2, "instance-2")
        self.apply(second, replace(self.operation, key=second, session="worker-2"), lambda *_: None)
        self.host.report("mac-test", self.report(taskId="task-2", instanceId="instance-2"))
        sent = []

        def runtime(result, artifact_bytes):
            sent.append(result["taskId"])
            if len(sent) == 1:
                raise RuntimeError("native projection Gateway rejected request")
            return {**{field: result[field] for field in ("hostId", "taskId", "generation", "instanceId",
                                                          "producerId")},
                    "resultId": digest(json.dumps(result, ensure_ascii=False, sort_keys=True,
                                                  separators=(",", ":")).encode()),
                    "receiptId": "native-r2"}

        with self.assertRaisesRegex(RuntimeError, "rejected request"):
            self.host.flush("mac-test", runtime)
        self.assertEqual(sorted(sent), ["task-1", "task-2"], "a result R refused held back the others")
        refused = sent[0]
        self.assertEqual([result["taskId"] for result in self.host.pending("mac-test")], [refused])
        refused_key = self.key if refused == "task-1" else second
        self.assertEqual(self.host.inbox_errors("mac-test"),
                         [{"operationId": operation_id(refused_key), "taskId": refused,
                           "error": "report failed: native projection Gateway rejected request"}])

    def test_host_receipts_tampered_snapshot_blocks_delivery(self):
        self.apply(self.key, self.operation, lambda *_: None)
        report = self.report()
        self.host.report("mac-test", report)
        second = OperationKey("mac-test", "task-2", 2, "instance-2")
        self.apply(second, replace(self.operation, key=second, session="worker-2"), lambda *_: None)
        second_report = self.report(taskId="task-2", instanceId="instance-2")
        second_id = self.host.report("mac-test", second_report).result_id
        snapshot = self.root / "host" / "artifacts" / operation_id(self.key) / (digest(json.dumps(
            report, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()) + ".bin")
        self.assertEqual(snapshot.stat().st_mode & 0o777, 0o400)
        snapshot.chmod(0o600)
        snapshot.write_bytes(b"tampered")
        sent = []
        with self.assertRaisesRegex(ValueError, "snapshot digest"):
            self.host.result_snapshot("mac-test", self.key)
        def runtime(result, artifact_bytes):
            sent.append(result["taskId"])
            return {"hostId": "mac-test", "taskId": "task-2", "generation": 2,
                    "instanceId": "instance-2", "producerId": "reviewer",
                    "resultId": second_id, "receiptId": "native-r2"}
        self.assertEqual(len(self.host.flush("mac-test", runtime)), 1)
        self.assertEqual(sent, ["task-2"])
        self.assertEqual(self.host.inbox_errors("mac-test"), [{"operationId": operation_id(self.key),
                                                               "taskId": "task-1",
                                                               "error": "artifact snapshot digest mismatch"}])

    def test_host_receipts_restart_after_snapshot_before_result_record(self):
        self.apply(self.key, self.operation, lambda *_: None)
        report = self.report()
        inbox = self.root / "host" / "inbox" / f"{operation_id(self.key)}.json"
        inbox.write_text(json.dumps(report))
        original = self.artifact.read_bytes()
        record = self.host.spool.record
        def interrupted(*args):
            raise OSError("crash before result record")
        self.host.spool.record = interrupted
        with self.assertRaisesRegex(OSError, "crash before result record"):
            self.host.report("mac-test", report)
        self.host.spool.record = record
        self.artifact.unlink()
        restarted = Host("mac-test", self.root / "host")
        self.assertEqual(restarted.pending("mac-test"), [report])
        self.assertEqual(restarted.result_snapshot("mac-test", self.key), (report, original))

    def test_host_receipts_fifo_snapshot_does_not_block_other_results(self):
        self.apply(self.key, self.operation, lambda *_: None)
        report = self.report()
        self.host.report("mac-test", report)
        second = OperationKey("mac-test", "task-2", 2, "instance-2")
        self.apply(second, replace(self.operation, key=second, session="worker-2"), lambda *_: None)
        second_report = self.report(taskId="task-2", instanceId="instance-2")
        second_id = self.host.report("mac-test", second_report).result_id
        snapshot = self.root / "host" / "artifacts" / operation_id(self.key) / (
            digest(json.dumps(report, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()) + ".bin")
        snapshot.unlink()
        os.mkfifo(snapshot)
        script = (
            "import json,sys; from pathlib import Path; from host import Host; "
            "host=Host('mac-test',Path(sys.argv[1])); sent=[]; "
            "receipt=lambda result, artifact_bytes: sent.append(result['taskId']) or "
            "{'hostId':'mac-test','taskId':'task-2','generation':2,'instanceId':'instance-2',"
            "'producerId':'reviewer','resultId':sys.argv[2],'receiptId':'native-r2'}; "
            "host.flush('mac-test',receipt); print(json.dumps({'sent':sent,'errors':host.inbox_errors('mac-test')}))"
        )
        completed = subprocess.run([sys.executable, "-c", script, str(self.root / "host"), second_id],
                                   env=dict(os.environ, PYTHONPATH=str(ROOT / "scripts" / "agent-work")),
                                   capture_output=True, text=True, timeout=3)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        output = json.loads(completed.stdout)
        self.assertEqual(output["sent"], ["task-2"])
        self.assertEqual(output["errors"][0]["operationId"], operation_id(self.key))

    def test_host_receipts_partial_report_is_refused(self):
        self.apply(self.key, self.operation, lambda *_: None)
        with self.assertRaisesRegex(ValueError, "partial final result"):
            self.host.report("mac-test", self.report(typedPayload="solo texto"))
        self.assertEqual(self.host.pending("mac-test"), [])

    def test_host_receipts_reject_partial_foreign_old_and_exit_only(self):
        self.apply(self.key, self.operation, lambda *_: None)
        for changed in (
            {"artifactRef": str(self.workspace / "missing.txt")},
            {"capability": "someone-else"},
            {"generation": 1},
            {"observedRevision": "another-revision"},
            {"digest": "0" * 64},
            {"schema": "agent-work.result.v0"},
        ):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                self.host.report("mac-test", self.report(**changed))
        self.assertEqual(self.host.pending("mac-test"), [])
        with self.assertRaisesRegex(ValueError, "hostId"):
            self.host.pending("other-host")
        with self.assertRaisesRegex(ValueError, "another hostId"):
            Host("other-host", self.root / "host")
        self.host.report("mac-test", self.report())
        with self.assertRaisesRegex(ValueError, "receipt"):
            self.host.flush("mac-test", lambda _, artifact_bytes: {"receiptId": "wrong"})
        self.assertEqual(len(self.host.pending("mac-test")), 1)

    def test_host_receipts_exit_zero_without_report_is_not_a_result(self):
        self.apply(self.key, self.operation, lambda *_: None)
        self.assertEqual(subprocess.run(["true"], check=False).returncode, 0)
        self.assertIsNone(self.host.collect("mac-test", self.key))
        self.assertEqual(self.host.pending("mac-test"), [])

    def test_host_receipts_concurrent_finals_keep_one_file_and_one_result(self):
        self.apply(self.key, self.operation, lambda *_: None)
        reports = [self.report(), self.report(typedPayload={"verdict": "changes", "findingsRef": "review.txt"})]
        def send(report):
            try:
                return self.host.report("mac-test", report).result_id
            except ValueError:
                return "conflict"
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(send, reports))
        self.assertEqual(outcomes.count("conflict"), 1)
        stored = json.loads(next((self.root / "host" / "results").glob("*.json")).read_text())
        self.assertEqual(digest(json.dumps(stored, ensure_ascii=False, sort_keys=True,
                                           separators=(",", ":")).encode()), next(x for x in outcomes if x != "conflict"))
        self.assertEqual(len(self.host.pending("mac-test")), 1)

    def test_host_receipts_restart_collects_registered_inbox_before_flush(self):
        self.apply(self.key, self.operation, lambda *_: None)
        inbox = self.root / "host" / "inbox" / f"{operation_id(self.key)}.json"
        partial = inbox.with_suffix(".tmp")
        partial.write_text(json.dumps(self.report()))
        restarted = Host("mac-test", self.root / "host")
        self.assertEqual(restarted.pending("mac-test"), [])
        os.replace(partial, inbox)
        self.assertEqual(len(restarted.pending("mac-test")), 1)
        expected_id = digest(json.dumps(self.report(), ensure_ascii=False, sort_keys=True,
                                        separators=(",", ":")).encode())
        self.assertEqual(restarted.pending("mac-test")[0]["taskId"], "task-1")
        receipt = {"hostId": "mac-test", "taskId": "task-1", "generation": 2,
                   "instanceId": "instance-1", "producerId": "reviewer",
                   "resultId": expected_id, "receiptId": "native-receipt-after-restart"}
        self.assertEqual(restarted.flush("mac-test", lambda _, artifact_bytes: receipt), [receipt])
        self.assertEqual(Host("mac-test", self.root / "host").pending("mac-test"), [])

    def test_host_receipts_invalid_inbox_does_not_block_other_results(self):
        self.apply(self.key, self.operation, lambda *_: None)
        key2 = OperationKey("mac-test", "task-2", 2, "instance-2")
        op2 = replace(self.operation, key=key2, session="worker-2")
        self.apply(key2, op2, lambda *_: None)
        bad = self.root / "host" / "inbox" / f"{operation_id(self.key)}.json"
        bad.mkdir()
        good = self.root / "host" / "inbox" / f"{operation_id(key2)}.json"
        report2 = self.report(taskId="task-2", instanceId="instance-2")
        partial = good.with_suffix(".tmp")
        partial.write_text(json.dumps(report2))
        os.replace(partial, good)
        restarted = Host("mac-test", self.root / "host")
        sent = []
        def runtime_report(result, artifact_bytes):
            sent.append(result)
            return {"hostId": "mac-test", "taskId": "task-2", "generation": 2,
                    "instanceId": "instance-2", "producerId": "reviewer",
                    "resultId": digest(json.dumps(result, ensure_ascii=False, sort_keys=True,
                                                  separators=(",", ":")).encode()),
                    "receiptId": "native-receipt-2"}
        receipts = restarted.flush("mac-test", runtime_report)
        self.assertEqual(len(receipts), 1)
        self.assertEqual([item["taskId"] for item in sent], ["task-2"])
        self.assertEqual(restarted.inbox_errors("mac-test"), [{
            "operationId": operation_id(self.key), "taskId": "task-1",
            "error": "result reference is not a regular file"}])
        bad.rmdir()
        bad.write_text(json.dumps(self.report()))
        self.assertEqual([result["taskId"] for result in restarted.pending("mac-test")], ["task-1"])
        self.assertEqual(restarted.inbox_errors("mac-test"), [])

    def watch(self, now):
        return self.host.detect_run_failures("mac-test", lambda key: None, now=now, accept_deadline_seconds=30,
                                             result_deadline_seconds=30)

    def uncertain_adapter_delivery(self):
        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        operation = replace(self.operation, adapter_id="codex")
        self.assertEqual(self.apply(self.key, operation, lost).status, "uncertain")
        return operation, operation_id(self.key)

    def test_operator_verdict_settles_an_uncertain_delivery_without_typing_again(self):
        operation, op_id = self.uncertain_adapter_delivery()
        attempted = self.host.spool.attempted_at(op_id)
        self.assertEqual(self.watch(attempted + 60), ["host:2:transport-unavailable:delivery-unaccepted"])
        self.assertEqual(self.host.spool.get(op_id)["status"], "uncertain")
        state = str(self.root / "host")
        self.assertEqual(uncertain_operations([state]), ["task-1"])

        with self.assertRaisesRegex(ValueError, "verdict"):
            host_main(["resolve-delivery", "mac-test", state, "task-1", "2", "retype", "no"])
        with self.assertRaisesRegex(ValueError, "reason"):
            host_main(["resolve-delivery", "mac-test", state, "task-1", "2", "abandoned", " "])
        reason = "el pane no muestra la referencia; se cancela en R"
        self.assertEqual(host_main(["resolve-delivery", "mac-test", state, "task-1", "2", "abandoned", reason]),
                         "abandoned")
        self.assertEqual(self.host.spool.get(op_id)["status"], "abandoned")
        self.assertEqual(uncertain_operations([state]), [], "a settled delivery must not block the cutover")
        with self.host.spool.connection() as db:
            self.assertEqual([tuple(row) for row in db.execute(
                "SELECT previous_status, verdict, reason FROM delivery_verdicts WHERE operation_id=?", (op_id,))],
                [("uncertain", "abandoned", reason)])
        retyped = []
        self.assertEqual(self.apply(self.key, operation, lambda *args: retyped.append(args)).status, "abandoned")
        self.assertEqual(retyped, [], "an abandoned delivery was typed again")
        self.assertEqual(self.watch(attempted + 9999), [])
        with self.assertRaisesRegex(ValueError, "not attempted or uncertain"):
            self.host.resolve_delivery("mac-test", self.key, "delivered", "otra vez")

    def test_operator_verdict_delivered_starts_the_silent_failure_clock(self):
        _, op_id = self.uncertain_adapter_delivery()
        self.assertEqual(uncertain_operations([str(self.root / "host")]), ["task-1"])
        self.assertEqual(self.host.resolve_delivery("mac-test", self.key, "delivered",
                                                    "el pane muestra al CLI trabajando en la referencia"), "delivered")
        self.assertEqual(self.host.spool.get(op_id)["status"], "delivered")
        self.assertEqual(uncertain_operations([str(self.root / "host")]), [])
        self.assertEqual(self.watch(self.host.spool.delivered_at(op_id) + 60), ["host:2:deadline-missed:deadline"])


def git(repo, *args):
    env = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                   check=True, env=env, capture_output=True)


class GitPhoto(unittest.TestCase):
    """Los comandos git detrás de repo_photo (bots de SUA-03): un git que tarda más de su timeout
    no se escapa como TimeoutExpired, y las variables de repositorio heredadas no mudan la foto."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="agent-work-git-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "base")

    def test_a_timed_out_git_command_raises_oserror_and_not_timeoutexpired(self):
        with mock.patch.object(host.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired(cmd="git", timeout=60)):
            with self.assertRaisesRegex(OSError, "timed out"):
                host._git(str(self.repo), "rev-parse", "HEAD")

    def test_a_timed_out_git_status_kills_its_child_and_raises_oserror(self):
        # El mismo contrato que _git, plazo de pared incluido: un git status que no termina en su
        # plazo (un lock, un disco lento que gotea datos sin parar) no cuelga la pasada del host
        # para siempre. Al vencer el plazo, el hijo muere a la fuerza y el fallo sale como
        # OSError, que repo_photo convierte en PhotoFailed.
        falso = self.root / "bin"
        falso.mkdir()
        (falso / "git").write_text("#!/bin/sh\ni=0\nwhile [ $i -lt 200 ]; do\n"
                                   "  printf '?? borrador.txt\\0'\n  i=$((i+1))\n  sleep 0.05\n"
                                   "done\n")
        (falso / "git").chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": f"{falso}{os.pathsep}{os.environ['PATH']}"}):
            spawned = []
            real_popen = host.subprocess.Popen

            def registrar(*args, **kwargs):
                hijo = real_popen(*args, **kwargs)
                spawned.append(hijo)
                return hijo

            with mock.patch.object(host.subprocess, "Popen", side_effect=registrar):
                with self.assertRaisesRegex(OSError, "git status timed out in"):
                    host._status_digest(str(self.repo), "status", "--porcelain=v1", "-z",
                                        "--untracked-files=all", timeout=2)
        self.assertIsNotNone(spawned[0].poll(), "the timed-out git status child stayed alive")
        self.assertLess(spawned[0].returncode, 0, "the child died of old age, not of the kill")

    def test_inherited_git_repository_variables_do_not_move_the_photo(self):
        other = self.root / "otro"
        other.mkdir()
        git(other, "init", "-q")
        git(other, "commit", "-q", "--allow-empty", "-m", "otro")
        # Sin rastrear a propósito: el status quimérico tiene que verlo.
        (other / "propio.txt").write_text("del otro repo\n")
        with mock.patch.dict(os.environ, {"GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other)}):
            photo = host.repo_photo(str(self.repo))
        self.assertEqual(photo, host.repo_photo(str(self.repo)),
                         "the photo followed the inherited GIT_DIR instead of the task's repo")

    def test_the_contents_of_untracked_files_travel_in_the_status(self):
        untracked = self.repo / "borrador.txt"
        untracked.write_text("versión de antes\n")
        before = host.repo_photo(str(self.repo))
        untracked.write_text("versión que el revisor escribió\n")
        after = host.repo_photo(str(self.repo))
        self.assertIn("status", host.photo_changes(before, after),
                      "overwriting an untracked file changed no field of the photo")
        self.assertNotIn("head", host.photo_changes(before, after))

    def test_the_local_exclude_rules_travel_in_the_photo(self):
        before = host.repo_photo(str(self.repo))
        self.assertEqual(set(before), set(host.PHOTO_FIELDS))
        exclude = self.repo / ".git" / "info" / "exclude"
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text("secreto.py\n")
        (self.repo / "secreto.py").write_text("planted\n")
        after = host.repo_photo(str(self.repo))
        self.assertEqual(host.photo_changes(before, after), ["exclude"],
                         "an exclude rule that hides a planted file changed no field of the photo")

    def test_a_repo_without_commits_fails_closed_and_a_non_repo_does_not(self):
        unborn = self.root / "por-nacer"
        unborn.mkdir()
        git(unborn, "init", "-q")
        with self.assertRaises(host.PhotoFailed):
            host.repo_photo(str(unborn))
        self.assertTrue(issubclass(host.PhotoFailed, OSError),
                        "the after-photo path may only catch OSError, never a bare failure")
        vacio = self.root / "no-repo"
        vacio.mkdir()
        with self.assertRaises(OSError) as raised:
            host.repo_photo(str(vacio))
        self.assertNotIsInstance(raised.exception, host.PhotoFailed,
                                 "a folder that is not a repo keeps the G2 path (no photo, launch proceeds)")


if __name__ == "__main__":
    unittest.main()

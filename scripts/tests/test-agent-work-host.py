#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from dataclasses import replace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))

from contracts import AuthorizedOperation, OperationKey
from cutover_live import uncertain_operations
from host import (CliAdapter, DeliveryDeferred, Host, ShellAdapterTransport, TmuxTransport, cli_adapter,
                  SGR, main as host_main, operation_id, read_composer, same_text)

COMPOSER_CLI = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "composer-cli.py"
# capture-pane -e of opencode 1.18.35 on its default theme, 2026-10-10: the home screen, a session
# with its sidebar, an operator's draft, the host's reference for /x/assignments/op-1.json, and the
# "Update Available" dialog of the first live canary over the home screen's placeholder.
OPENCODE_SCREENS = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "opencode"
# tmux names a pane after its foreground process; the python double shows as Python on macOS.
PYTHON_DOUBLE = CliAdapter(tuple(sorted({"Python", Path(sys.executable).name,
                                         Path(os.path.realpath(sys.executable)).name})))
GRUVBOX, BRIGHT, RESET = "\x1b[38;2;146;131;116m", "\x1b[38;2;238;238;238m", "\x1b[0m"
SHELL = "PS1='❯ ' bash --noprofile --norc -i"


def opencode_screen(name):
    return (OPENCODE_SCREENS / f"{name}.ans").read_text()


def opencode_box(*rows):
    """An opencode input box as capture-pane -e paints it, wide enough for one row per line."""
    return "\n".join(["┃", *(f"┃  {row}" for row in rows), "┃", "┃  Build · GLM-5.3-Flash Z.AI Coding Plan",
                      "╹" + "▀" * 399, ""])


class ScriptedTmux(TmuxTransport):
    """The production transport over a scripted tmux: one opencode pane, its screens in order."""

    def __init__(self, *screens, adapter_id="opencode"):
        super().__init__("tmux", "unused", cli_adapter(adapter_id), sleep=lambda _: None)
        self.screens = list(screens)
        self.keys = []

    def _tmux(self, *args):
        out = {"list-panes": "%1\topencode.exe\n", "display-message": "oc\topencode.exe\n"}.get(args[0], "")
        if args[0] == "capture-pane":
            out = self.screens.pop(0) if len(self.screens) > 1 else self.screens[0]
        if args[0] == "send-keys":
            self.keys.append(args[-1])
        return subprocess.CompletedProcess(args, 0, out, "")


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

    @staticmethod
    def wait_for(predicate, seconds=5):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(0.05)
        return False

    @staticmethod
    def reference_text(assignment_ref):
        return (f"Open assignment JSON at {assignment_ref}. First write agent-work.accept.v1 atomically to "
                "acceptRef with schema, hostId, taskId, generation, instanceId, claimId and capability copied "
                "from the assignment. Then follow briefRef and write agent-work.result.v1 atomically to resultRef.")

    def composer_session(self, mode):
        """A composer CLI double on its own tmux server; returns its socket, a tmux runner and the submitted log."""
        if not shutil.which("tmux"):
            self.skipTest("tmux not installed")
        socket = f"agent-work-composer-{os.getpid()}-{mode}"
        submitted = self.root / f"submitted-{mode}.log"

        def tmux_cmd(*args):
            return subprocess.run(["tmux", "-f", "/dev/null", "-L", socket, *args], capture_output=True, text=True)

        socket_file = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / socket
        self.addCleanup(socket_file.unlink, missing_ok=True)
        self.addCleanup(tmux_cmd, "kill-server")
        self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-1", "-c", str(self.workspace),
                                  sys.executable, str(COMPOSER_CLI), str(submitted), mode).returncode, 0)
        self.assertTrue(self.wait_for(lambda: "❯" in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout),
                        "the composer double never painted its prompt")
        return socket, tmux_cmd, submitted

    def test_tmux_delivery_waits_for_the_text_and_never_types_over_the_operator(self):
        socket, tmux_cmd, submitted = self.composer_session("0.15")
        tmux_cmd("send-keys", "-t", "=worker-1:", "-l", "--", "borrador de David")
        self.assertTrue(self.wait_for(
            lambda: "borrador de David" in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout))
        transport = TmuxTransport("tmux", socket, PYTHON_DOUBLE)
        self.assertEqual(self.apply(self.key, self.operation, transport.deliver).status, "deferred")
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "deferred")
        self.assertIsNone(self.host.spool.attempted_at(operation_id(self.key)))
        screen = tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout
        self.assertIn("❯ borrador de David", screen)
        self.assertNotIn("Open assignment", screen, "the host typed over the operator's text")
        self.assertFalse(submitted.exists(), "Enter reached the operator's text")
        self.assertEqual(tmux_cmd("show-environment", "-t", "=worker-1", "AGENT_WORK_MANAGED").returncode, 1)

        tmux_cmd("send-keys", "-t", "=worker-1:", "C-u")
        self.assertTrue(self.wait_for(
            lambda: "borrador" not in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout))
        observation = self.apply(self.key, self.operation, transport.deliver)
        self.assertEqual(observation.status, "delivered")
        self.assertTrue(self.wait_for(lambda: self.host.collect("mac-test", self.key)))
        self.assertEqual(submitted.read_text(), self.reference_text(observation.assignment_ref) + "\n")

    def test_tmux_delivery_withholds_enter_when_the_composer_does_not_show_the_text(self):
        socket, tmux_cmd, submitted = self.composer_session("no-echo")
        observation = self.apply(self.key, self.operation, TmuxTransport("tmux", socket, PYTHON_DOUBLE).deliver)
        self.assertEqual(observation.status, "uncertain")
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "attempted")
        time.sleep(0.5)
        self.assertFalse(submitted.exists(), "Enter was pressed on text the composer never showed")
        retyped = []
        self.assertEqual(self.apply(self.key, self.operation, lambda *args: retyped.append(args)).status, "uncertain")
        self.assertEqual(retyped, [], "an uncertain delivery was typed again")

    def test_tmux_delivery_is_deferred_while_the_session_is_unreachable(self):
        socket, tmux_cmd, _ = self.composer_session("0")
        tmux_cmd("kill-server")
        observation = self.apply(self.key, self.operation, TmuxTransport("tmux", socket, PYTHON_DOUBLE).deliver)
        self.assertEqual(observation.status, "deferred")
        self.assertEqual(self.apply(self.key, self.operation, lambda *_: None).status, "delivered")

    def test_composer_reading_counts_text_whatever_its_colour(self):
        placeholders = cli_adapter("opencode").placeholders
        self.assertEqual(read_composer(opencode_screen("home-empty"), "opencode.exe", placeholders), ("VACIO", ""))
        self.assertEqual(read_composer(opencode_screen("home-empty"), "opencode.exe"),
                         ("REAL", 'Ask anything… "Fix a TODO in the codebase"'),
                         "a placeholder no one measured for the adapter is text")
        self.assertEqual(read_composer(opencode_screen("session-empty"), "opencode.exe", placeholders), ("VACIO", ""),
                         "the session sidebar beside the input box is not composer text")
        self.assertEqual(read_composer(opencode_screen("session-draft"), "opencode.exe", placeholders),
                         ("REAL", "borrador del operador"))
        self.assertEqual(read_composer(opencode_box(f"{GRUVBOX}borrador del operador{RESET}"), "opencode", placeholders),
                         ("REAL", "borrador del operador"), "a theme that draws input grey hides no draft")
        self.assertEqual(read_composer("┃  hola\n┃  Build · GLM-5.3-Flash\n", "opencode")[0], "DESCONOCIDO")
        self.assertEqual(read_composer("salida vieja\n❯ \x1b[2mTry \"fix lint errors\"\x1b[22m\n\n", "node"),
                         ("REAL", 'Try "fix lint errors"'), "a ghost suggestion is text to an unmeasured adapter")
        self.assertEqual(read_composer("❯ hola\n" + "─" * 20 + "\n", "claude"), ("REAL", "hola"))
        self.assertEqual(read_composer("❯ \n" + "─" * 20 + "\n", "claude"), ("VACIO", ""))
        self.assertEqual(read_composer("Do you want to proceed?\n❯ 1. Yes\n  2. No\n", "claude")[0], "DESCONOCIDO")
        self.assertEqual(read_composer("Update available\n› Update now\n  2. Skip\n", "codex")[0], "DESCONOCIDO")
        self.assertEqual(read_composer("❯ Open assignment JSON at /x.json. First write agent-work.accept.v\n"
                                       "1 atomically to acceptRef\n", "python3"),
                         ("REAL", "Open assignment JSON at /x.json. First write agent-work.accept.v\n"
                                  "1 atomically to acceptRef"), "a wrapped line that starts with a digit is no menu")
        self.assertEqual(read_composer("working...\n", "python3")[0], "DESCONOCIDO")
        self.assertEqual(read_composer("", "opencode")[0], "DESCONOCIDO")
        self.assertTrue(same_text("Open assignment\nJSON at /x.json", "Open assignment JSON at /x.json"))
        self.assertFalse(same_text("Open assignment JSON at /y.json", "Open assignment JSON at /x.json"))

    def test_opencode_delivery_never_types_over_a_draft_the_theme_draws_grey(self):
        transport = ScriptedTmux(opencode_box(f"{GRUVBOX}borrador del operador{RESET}"))
        with self.assertRaisesRegex(DeliveryDeferred, "borrador del operador"):
            transport.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(transport.keys, [], "the host typed over a grey draft")

    def test_opencode_delivery_never_types_over_a_bright_draft(self):
        transport = ScriptedTmux(opencode_screen("session-draft"))
        with self.assertRaisesRegex(DeliveryDeferred, "borrador del operador"):
            transport.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(transport.keys, [])

    def test_opencode_delivery_waits_while_a_dialog_covers_the_placeholder(self):
        screen = opencode_screen("update-dialog")
        self.assertEqual(read_composer(screen, "opencode.exe", cli_adapter("opencode").placeholders)[0],
                         "DESCONOCIDO")
        transport = ScriptedTmux(screen)
        with self.assertRaisesRegex(DeliveryDeferred, "DESCONOCIDO"):
            transport.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(transport.keys, [], "the dialog took the keys of the reference")

    def test_opencode_composer_is_empty_when_the_sidebar_prints_on_the_box_border(self):
        screen = opencode_screen("permission-rejected")
        self.assertIn("▀▀▀    main", SGR.sub("", screen))
        self.assertEqual(read_composer(screen, "opencode.exe", cli_adapter("opencode").placeholders), ("VACIO", ""))

    def test_opencode_delivery_types_over_the_real_placeholder_and_submits(self):
        reference = self.reference_text("/x/assignments/op-1.json")
        for before, after in (("home-empty", "home-reference"), ("session-empty", "session-reference")):
            transport = ScriptedTmux(opencode_screen(before), opencode_screen(after))
            transport.deliver("/x/assignments/op-1.json", "oc")
            self.assertEqual(transport.keys, [reference, "Enter"], before)

    def test_an_adapter_nobody_measured_is_known_only_by_its_command(self):
        self.assertEqual(cli_adapter("codex"), CliAdapter(("codex",)))

    def test_opencode_delivery_presses_enter_once_a_long_reference_finishes_drawing(self):
        reference = self.reference_text("/x/assignments/op-1.json")
        partial = opencode_box(f"{BRIGHT}{reference[:90]}{RESET}")
        drawn = ScriptedTmux(opencode_screen("home-empty"), partial, opencode_box(f"{BRIGHT}{reference}{RESET}"))
        drawn.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(drawn.keys, [reference, "Enter"])
        stuck = ScriptedTmux(opencode_screen("home-empty"), partial)
        with self.assertRaisesRegex(RuntimeError, "Enter withheld"):
            stuck.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(stuck.keys, [reference], "Enter went out on a reference the composer never finished")

    def test_opencode_delivery_withholds_enter_when_a_grey_draft_shares_the_composer(self):
        reference = self.reference_text("/x/assignments/op-1.json")
        transport = ScriptedTmux(opencode_screen("home-empty"),
                                 opencode_box(f"{GRUVBOX}borrador del operador{RESET}", f"{BRIGHT}{reference}{RESET}"))
        with self.assertRaisesRegex(RuntimeError, "Enter withheld"):
            transport.deliver("/x/assignments/op-1.json", "oc")
        self.assertEqual(transport.keys, [reference], "Enter went out over the operator's draft")

    def shell_session(self):
        """A tmux server of its own whose session worker-1 is a bash with a ❯ prompt."""
        if not shutil.which("tmux"):
            self.skipTest("tmux not installed")
        socket = f"agent-work-shell-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run(["tmux", "-f", "/dev/null", "-L", socket, *args], capture_output=True, text=True)

        socket_file = Path(os.environ.get("TMUX_TMPDIR") or "/tmp") / f"tmux-{os.getuid()}" / socket
        self.addCleanup(socket_file.unlink, missing_ok=True)
        self.addCleanup(tmux_cmd, "kill-server")
        self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-1", "-x", "220", "-y", "50", SHELL).returncode, 0)
        self.assertTrue(self.wait_for(lambda: "❯" in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout))
        return socket, tmux_cmd

    def test_tmux_delivery_never_types_into_a_shell_prompt(self):
        socket, tmux_cmd = self.shell_session()
        transport = TmuxTransport("tmux", socket, cli_adapter("opencode"))
        self.assertEqual(self.apply(self.key, self.operation, transport.deliver).status, "deferred")
        time.sleep(0.3)
        self.assertNotIn("Open assignment", tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout,
                         "the reference reached the operator's shell")

    def test_tmux_delivery_stays_in_the_pinned_pane_when_the_operator_opens_windows(self):
        socket, tmux_cmd, submitted = self.composer_session("0.15")
        transport = TmuxTransport("tmux", socket, PYTHON_DOUBLE)
        self.assertEqual(transport.composer("worker-1"), ("VACIO", ""))
        # C-b c: a new window, now the active one, with the operator's shell.
        self.assertEqual(tmux_cmd("new-window", "-t", "=worker-1", SHELL).returncode, 0)
        self.assertTrue(self.wait_for(lambda: "❯" in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout))
        # A second CLI of the same kind, in a third window, does not move the pin.
        other = self.root / "submitted-other.log"
        self.assertEqual(tmux_cmd("new-window", "-d", "-t", "=worker-1", sys.executable, str(COMPOSER_CLI),
                                  str(other), "0.15").returncode, 0)
        self.assertTrue(self.wait_for(lambda: len([command for command in tmux_cmd(
            "list-panes", "-s", "-t", "=worker-1", "-F", "#{pane_current_command}").stdout.split()
            if command in PYTHON_DOUBLE.commands]) == 2))
        observation = self.apply(self.key, self.operation, transport.deliver)
        self.assertEqual(observation.status, "delivered")
        self.assertTrue(self.wait_for(lambda: self.host.collect("mac-test", self.key)))
        self.assertEqual(submitted.read_text(), self.reference_text(observation.assignment_ref) + "\n")
        self.assertFalse(other.exists(), "the reference went to the other CLI")
        self.assertNotIn("Open assignment", tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout,
                         "the reference reached the operator's shell in the active window")

    def test_tmux_delivery_defers_when_the_pane_does_not_run_the_adapter(self):
        socket, tmux_cmd, submitted = self.composer_session("0.15")
        self.assertEqual(self.apply(self.key, self.operation,
                                    TmuxTransport("tmux", socket, cli_adapter("opencode")).deliver).status, "deferred")
        transport = TmuxTransport("tmux", socket, PYTHON_DOUBLE)
        self.assertEqual(transport.composer("worker-1"), ("VACIO", ""))
        pane = transport.panes["worker-1"]
        self.assertEqual(tmux_cmd("respawn-pane", "-k", "-t", pane, SHELL).returncode, 0)
        self.assertTrue(self.wait_for(lambda: "❯" in tmux_cmd("capture-pane", "-p", "-t", pane).stdout))
        self.assertEqual(self.apply(self.key, self.operation, transport.deliver).status, "deferred")
        time.sleep(0.3)
        self.assertNotIn("Open assignment", tmux_cmd("capture-pane", "-p", "-t", pane).stdout)
        self.assertFalse(submitted.exists())

    def uncertain_adapter_delivery(self):
        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        operation = replace(self.operation, adapter_id="codex")
        self.assertEqual(self.apply(self.key, operation, lost).status, "uncertain")
        return operation, operation_id(self.key)

    def test_operator_verdict_settles_an_uncertain_delivery_without_typing_again(self):
        operation, op_id = self.uncertain_adapter_delivery()
        attempted = self.host.spool.attempted_at(op_id)
        self.assertEqual(len(self.host.settle_deliveries("mac-test", now=attempted + 60, deadline_seconds=30)), 1)
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
        self.assertEqual(self.host.settle_deliveries("mac-test", now=attempted + 9999, deadline_seconds=30), [])
        with self.assertRaisesRegex(ValueError, "not attempted or uncertain"):
            self.host.resolve_delivery("mac-test", self.key, "delivered", "otra vez")

    def test_operator_verdict_delivered_starts_the_silent_failure_clock(self):
        _, op_id = self.uncertain_adapter_delivery()
        self.assertEqual(uncertain_operations([str(self.root / "host")]), ["task-1"])
        self.assertEqual(self.host.resolve_delivery("mac-test", self.key, "delivered",
                                                    "el pane muestra al CLI trabajando en la referencia"), "delivered")
        self.assertEqual(self.host.spool.get(op_id)["status"], "delivered")
        self.assertEqual(uncertain_operations([str(self.root / "host")]), [])
        detected = self.host.detect_silent_failures("mac-test", lambda key: False,
                                                    now=self.host.spool.delivered_at(op_id) + 60,
                                                    deadline_seconds=30)
        self.assertEqual(detected, ["host:2:deadline-missed:deadline"])

    def test_host_receipts_tmux_cli_without_hooks(self):
        if not shutil.which("tmux"):
            self.skipTest("tmux not installed")
        socket = "agent-work-host-" + str(os.getpid())
        def tmux_cmd(*args):
            return subprocess.run(["tmux", "-L", socket, *args], capture_output=True, text=True)
        cli = self.root / "fake-cli.py"
        cli.write_text(
            "import hashlib,json,os,pathlib,re,sys\n"
            "line=sys.stdin.readline()\n"
            "ref=re.search(r'(/[^ ]+\\.json)',line).group(1)\n"
            "a=json.loads(pathlib.Path(ref).read_text())\n"
            "p=pathlib.Path(a['workspaceRef'])/'evidence.txt'\n"
            "out=pathlib.Path(a['resultRef'])\n"
            "r={'schema':'agent-work.result.v1','kind':'produced','hostId':a['hostId'],"
            "'taskId':a['taskId'],'generation':a['generation'],'instanceId':a['instanceId'],"
            "'producerId':a['producerId'],'capability':a['capability'],"
            "'observedRevision':a['inputRevision'],'typedPayload':{'verdict':'approved','evidenceRef':'evidence.txt'},"
            "'artifactRef':str(p),'digest':hashlib.sha256(p.read_bytes()).hexdigest()}\n"
            "tmp=out.with_suffix('.tmp');tmp.write_text(json.dumps(r));os.replace(tmp,out)\n"
            "print('FAKE-RESULT-WRITTEN',flush=True)\n"
            "sys.stdin.readline()\n"
        )
        submitted = self.root / "worker-1-submitted.log"
        try:
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-1", "-c", str(self.workspace),
                                      sys.executable, str(COMPOSER_CLI), str(submitted), "0.15").returncode, 0)
            self.assertTrue(self.wait_for(lambda: "❯" in tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout))
            transport = TmuxTransport("tmux", socket, PYTHON_DOUBLE)
            observation = self.apply(self.key, self.operation, transport.deliver)
            self.assertEqual(observation.status, "delivered")
            self.assertEqual(tmux_cmd("show-environment", "-t", "=worker-1", "AGENT_WORK_MANAGED").stdout.strip(),
                             "AGENT_WORK_MANAGED=1")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.host.collect("mac-test", self.key):
                time.sleep(0.1)
            self.assertEqual(len(self.host.pending("mac-test")), 1, tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout)
            self.assertEqual(self.host.pending("mac-test")[0]["typedPayload"],
                             {"verdict": "approved", "evidenceRef": "evidence.txt"})
            self.assertEqual(submitted.read_text(), self.reference_text(observation.assignment_ref) + "\n",
                             "the CLI did not get exactly the reference, once")

            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-2", "-c", str(self.workspace),
                                      sys.executable, str(cli)).returncode, 0)
            shim = self.root / "tmux-shim"
            shim.write_text(f'#!/bin/sh\nexec {shutil.which("tmux")} -L {socket} "$@"\n')
            shim.chmod(0o700)
            key2 = OperationKey("mac-test", "task-2", 2, "instance-2")
            op2 = replace(self.operation, key=key2, session="worker-2")
            adapter = ShellAdapterTransport(ROOT / "scripts" / "mac" / "corrida.sh", "run-test", "lane-test",
                                            "worker-test", "mac-test", self.root / "host", str(shim))
            self.assertEqual(self.apply(key2, op2, adapter.deliver).status, "delivered")
            self.assertEqual(tmux_cmd("show-environment", "-t", "=worker-2", "AGENT_WORK_MANAGED").stdout.strip(),
                             "AGENT_WORK_MANAGED=1")
            ref = str(self.root / "host" / "assignments" / f"{operation_id(key2)}.json")
            env = dict(os.environ, TMUX_BIN=str(shim), AGENT_WORK_HOST_STATE_DIR=str(self.root / "host"))
            foreign = subprocess.run(["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "adaptador",
                                      "deliver-ref", "run-test", "lane-test", "worker-test", "worker-2",
                                      "foreign-host", ref], capture_output=True, text=True, env=env)
            self.assertNotEqual(foreign.returncode, 0)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.host.collect("mac-test", key2):
                time.sleep(0.1)
            self.assertEqual(len(self.host.pending("mac-test")), 2)

            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-3", "-c", str(self.workspace),
                                      sys.executable, str(cli)).returncode, 0)
            key3 = OperationKey("mac-test", "task-3", 2, "instance-3")
            op3 = replace(self.operation, key=key3, session="worker-3")
            def via_launcher(ref, session):
                env = dict(os.environ, TMUX_BIN=str(shim), AGENT_WORK_REF=ref, AGENT_WORK_SESSION=session)
                command = (f'. "{ROOT / "scripts" / "mac" / "corrida" / "lanzar-sesion.sh"}"; '
                           'marcas_lock_refrescar() { :; }; '
                           'lanzar_sesion_entregar_referencia "$AGENT_WORK_SESSION" "$AGENT_WORK_REF"')
                sent = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True)
                self.assertEqual(sent.returncode, 0, sent.stderr)

            self.assertEqual(self.apply(key3, op3, via_launcher).status, "delivered")
            self.assertEqual(tmux_cmd("show-environment", "-t", "=worker-3", "AGENT_WORK_MANAGED").stdout.strip(),
                             "AGENT_WORK_MANAGED=1")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.host.collect("mac-test", key3):
                time.sleep(0.1)
            self.assertEqual(len(self.host.pending("mac-test")), 3)
        finally:
            tmux_cmd("kill-server")


if __name__ == "__main__":
    unittest.main()

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
from host import Host, ShellAdapterTransport, TmuxTransport, operation_id


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
        )

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
            "observedRevision": "abc123",
            "typedPayload": {"verdict": "pass"},
            "artifactRef": str(self.artifact),
            "digest": digest(self.artifact.read_bytes()),
        }
        body.update(overrides)
        return body

    def test_host_receipts_replay_and_lost_ack(self):
        deliveries = []
        first = self.host.apply(self.key, self.operation, lambda ref, session: deliveries.append((ref, session)))
        self.assertEqual(first.status, "delivered")
        self.assertEqual(len(deliveries), 1)
        self.assertEqual(deliveries[0][1], "worker-1")
        assignment = json.loads(Path(deliveries[0][0]).read_text())
        self.assertEqual(assignment["taskId"], "task-1")
        self.assertEqual(assignment["generation"], 2)

        with self.assertRaisesRegex(ValueError, "active instance"):
            other_key = OperationKey("mac-test", "task-2", 1, "instance-1")
            self.host.apply(other_key, replace(self.operation, key=other_key), lambda *_: None)

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
        def runtime_report(payload):
            calls.append(payload)
            if len(calls) == 1:
                raise TimeoutError("runtime stored receipt but its ACK was lost")
            return expected

        with self.assertRaises(TimeoutError):
            self.host.flush("mac-test", runtime_report)
        self.assertEqual(len(self.host.pending("mac-test")), 1)
        self.assertEqual(self.host.flush("mac-test", runtime_report), [expected])
        self.assertEqual(self.host.flush("mac-test", runtime_report), [])
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0], calls[1])
        reopened = Host("mac-test", self.root / "host")
        self.assertEqual(reopened.report("mac-test", report).result_id, results[0].result_id)
        self.assertEqual(reopened.receipt("mac-test", self.key), expected)

    def test_host_receipts_reject_partial_foreign_old_and_exit_only(self):
        self.host.apply(self.key, self.operation, lambda *_: None)
        for changed in (
            {"artifactRef": str(self.workspace / "missing.txt")},
            {"capability": "someone-else"},
            {"generation": 1},
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
            self.host.flush("mac-test", lambda _: {"receiptId": "wrong"})
        self.assertEqual(len(self.host.pending("mac-test")), 1)

    def test_host_receipts_exit_zero_without_report_is_not_a_result(self):
        self.host.apply(self.key, self.operation, lambda *_: None)
        self.assertEqual(subprocess.run(["true"], check=False).returncode, 0)
        self.assertIsNone(self.host.collect("mac-test", self.key))
        self.assertEqual(self.host.pending("mac-test"), [])

    def test_host_receipts_concurrent_finals_keep_one_file_and_one_result(self):
        self.host.apply(self.key, self.operation, lambda *_: None)
        reports = [self.report(observedRevision="revision-one"), self.report(observedRevision="revision-two")]
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
            "'observedRevision':'abc123','typedPayload':{'verdict':'pass'},"
            "'artifactRef':str(p),'digest':hashlib.sha256(p.read_bytes()).hexdigest()}\n"
            "tmp=out.with_suffix('.tmp');tmp.write_text(json.dumps(r));os.replace(tmp,out)\n"
            "print('FAKE-RESULT-WRITTEN',flush=True)\n"
            "sys.stdin.readline()\n"
        )
        try:
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-1", "-c", str(self.workspace),
                                      sys.executable, str(cli)).returncode, 0)
            transport = TmuxTransport("tmux", socket)
            observation = self.host.apply(self.key, self.operation, transport.deliver)
            self.assertEqual(observation.status, "delivered")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.host.collect("mac-test", self.key):
                time.sleep(0.1)
            self.assertEqual(len(self.host.pending("mac-test")), 1, tmux_cmd("capture-pane", "-p", "-t", "=worker-1:").stdout)
            self.assertEqual(self.host.pending("mac-test")[0]["typedPayload"], {"verdict": "pass"})

            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker-2", "-c", str(self.workspace),
                                      sys.executable, str(cli)).returncode, 0)
            shim = self.root / "tmux-shim"
            shim.write_text(f'#!/bin/sh\nexec {shutil.which("tmux")} -L {socket} "$@"\n')
            shim.chmod(0o700)
            key2 = OperationKey("mac-test", "task-2", 2, "instance-2")
            op2 = replace(self.operation, key=key2, session="worker-2")
            adapter = ShellAdapterTransport(ROOT / "scripts" / "mac" / "corrida.sh", "run-test", "lane-test",
                                            "worker-test", "mac-test", self.root / "host", str(shim))
            self.assertEqual(self.host.apply(key2, op2, adapter.deliver).status, "delivered")
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

            self.assertEqual(self.host.apply(key3, op3, via_launcher).status, "delivered")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not self.host.collect("mac-test", key3):
                time.sleep(0.1)
            self.assertEqual(len(self.host.pending("mac-test")), 3)
        finally:
            tmux_cmd("kill-server")


if __name__ == "__main__":
    unittest.main()

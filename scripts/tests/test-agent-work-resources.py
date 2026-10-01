#!/usr/bin/env python3
import json
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))

from contracts import AuthorizedOperation, OperationKey
from host import Host
from resources import ResourceManager, TmuxBackend


class FakeBackend:
    def __init__(self):
        self.boot_id = "boot-one"
        self.live = {}
        self.stops = []
        self.revokes = []
        self.fail_stop = False
        self.detached = False
        self.offline = False

    def observe(self, session):
        if self.offline:
            raise OSError("host unreachable")
        return self.live.get(session)

    def stop(self, identity):
        self.stops.append(identity)
        if self.fail_stop:
            return False
        for session, current in list(self.live.items()):
            if current == identity:
                del self.live[session]
                break
        return True

    def prove_absent(self, identity):
        return identity not in self.live.values() and not self.detached

    def revoke(self, identity):
        self.revokes.append(identity)
        return True

    def launch(self, session, nonce, pid):
        self.live[session] = {
            "bootId": self.boot_id, "nonce": nonce,
            "serverPid": 100, "serverStart": "server-birth",
            "sessionId": f"@{pid}", "paneId": f"%{pid}",
            "panePid": pid, "paneStart": f"start-{pid}",
        }


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-work-resources-")
        self.addCleanup(self.tmp.cleanup)
        self.host = Host("host-test", Path(self.tmp.name) / "host")
        self.backend = FakeBackend()
        self.manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=2)
        self.key = OperationKey("host-test", "task-1", 1, "instance-1")

    def test_resource_identity_pid_reuse_boot_change_and_adoption(self):
        reservation = self.manager.reserve(self.key, "worker-1", "TaskCreated")
        self.assertEqual(self.manager.reserve(self.key, "worker-1", "TaskCreated"), reservation)
        self.assertTrue(self.manager.begin_launch(self.key).launch_now)
        self.assertFalse(self.manager.begin_launch(self.key).launch_now)
        self.backend.launch("worker-1", reservation.nonce, 501)
        self.assertEqual(self.manager.attach(self.key).state, "Running")
        self.backend.live["worker-1"]["paneStart"] = "reused-pid-birth"
        self.assertEqual(self.manager.close(self.key, {"kind": "result", "receipt": "r1"}).state, "CleanupPending")
        self.assertEqual(self.backend.stops, [])
        self.backend.live["worker-1"]["serverStart"] = "restarted-tmux-server"
        self.assertEqual(self.manager.close(self.key, {"kind": "result", "receipt": "r1"}).state, "CleanupPending")
        self.assertEqual(self.backend.stops, [])
        self.backend.boot_id = "boot-two"
        self.assertEqual(self.manager.close(self.key, {"kind": "result", "receipt": "r1"}).state, "AbsenceVerified")
        self.assertEqual(self.backend.stops, [])

        adopted = OperationKey("host-test", "task-2", 1, "instance-2")
        held = self.manager.reserve(adopted, "user-owned", "UserAdopted")
        self.manager.begin_launch(adopted)
        self.backend.launch("user-owned", held.nonce, 502)
        self.assertEqual(self.manager.attach(adopted).state, "Running")
        self.assertEqual(self.manager.close(adopted, {"kind": "result", "receipt": "r2"}).state, "ReleasedAdopted")
        self.assertEqual(self.backend.stops, [])
        self.assertIn("user-owned", self.backend.live)
        self.assertEqual(len(self.backend.revokes), 1)

    def test_resource_close_reservation_crash_stop_failure_and_detached_child(self):
        reserved = self.manager.reserve(self.key, "worker-1", "TaskCreated")
        self.assertEqual(self.manager.close(self.key, {"kind": "cancel", "receipt": "c1"}).state,
                         "AbsenceVerified")
        self.assertEqual(self.manager.close(self.key, {"kind": "cancel", "receipt": "c1"}).state,
                         "AbsenceVerified")
        second = OperationKey("host-test", "task-2", 1, "instance-2")
        held = self.manager.reserve(second, "worker-2", "TaskCreated")
        self.manager.begin_launch(second)
        self.assertEqual(self.manager.close(second, {"kind": "cancel", "receipt": "c2"}).state,
                         "CleanupPending")
        self.backend.launch("worker-2", held.nonce, 602)
        self.assertEqual(self.manager.attach(second).state, "CleanupPending")
        restarted_manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=2)
        self.backend.offline = True
        self.assertEqual(restarted_manager.close(second, {"kind": "cancel", "receipt": "c2"}).state,
                         "CleanupPending")
        self.assertEqual(restarted_manager.counts()["active"], 1)
        self.backend.offline = False
        self.backend.fail_stop = True
        self.assertEqual(restarted_manager.close(second, {"kind": "cancel", "receipt": "c2"}).state,
                         "CleanupPending")
        self.assertEqual(len(self.backend.live), 1)
        self.backend.fail_stop = False
        self.backend.detached = True
        self.assertEqual(restarted_manager.close(second, {"kind": "cancel", "receipt": "c2"}).state,
                         "CleanupPending")
        self.assertEqual(self.manager.counts()["active"], 1)
        self.backend.detached = False
        self.assertEqual(restarted_manager.close(second, {"kind": "cancel", "receipt": "c2"}).state,
                         "AbsenceVerified")
        self.assertEqual(self.manager.counts()["active"], 0)
        self.assertEqual(reserved.state, "Reserved")

    def test_resource_close_pending_holds_host_capacity_and_pool_is_separate(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=2)
        manager.reserve(self.key, "worker-1", "TaskCreated")
        manager.begin_launch(self.key)
        self.assertEqual(manager.close(self.key, {"kind": "cancel", "receipt": "c1"}).state,
                         "CleanupPending")
        pool_key = OperationKey("host-test", "pool-1", 1, "pool-instance")
        manager.reserve(pool_key, "pool-worker", "IntentionalPool")
        self.assertEqual(manager.counts(), {"active": 2, "history": 0, "pool": 1})
        with self.assertRaisesRegex(ValueError, "capacity"):
            manager.reserve(OperationKey("host-test", "replacement", 1, "instance-new"),
                            "replacement", "TaskCreated")

    def test_resource_100_cycles_no_orphans_or_pool_leaks(self):
        for number in range(100):
            key = OperationKey("host-test", f"task-{number}", 1, f"instance-{number}")
            session = f"worker-{number}"
            held = self.manager.reserve(key, session, "TaskCreated")
            self.manager.begin_launch(key)
            self.backend.launch(session, held.nonce, 1000 + number)
            self.assertEqual(self.manager.attach(key).state, "Running")
            self.assertEqual(self.manager.close(key, {"kind": "result", "receipt": str(number)}).state,
                             "AbsenceVerified")
        self.assertEqual(self.backend.live, {})
        self.assertEqual(self.manager.counts(), {"active": 0, "history": 100, "pool": 0})

    def test_resource_identity_tmux_socket_and_adopted_session(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-resource-{os.getpid()}"
        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)
        backend = TmuxBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=2)
        try:
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "owned", "/bin/sleep", "30").returncode, 0)
            brief = Path(self.tmp.name) / "brief.txt"
            brief.write_text("sandbox task")
            assignment = AuthorizedOperation(
                key=self.key, producer_id="fake", capability="sandbox-secret", session="owned",
                workspace_ref=self.tmp.name, brief_ref=str(brief),
                brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest())
            reference = self.host.apply(self.key, assignment, lambda *_: None).assignment_ref
            owned = manager.reserve(self.key, "owned", "TaskCreated")
            self.assertTrue(manager.begin_launch(self.key).launch_now)
            backend.mark("owned", owned.nonce)
            with self.assertRaisesRegex(ValueError, "another resource"):
                backend.mark("owned", "foreign-nonce")
            self.assertEqual(manager.attach(self.key).state, "Running")
            evidence = Path(self.tmp.name) / "cancel.json"
            evidence.write_text('{"kind":"cancel","receipt":"sandbox-cancel-1"}')
            closed = subprocess.run([sys.executable, str(ROOT / "scripts" / "agent-work" / "resources.py"),
                                     "close", "--host-id", "host-test", "--state-dir", str(self.host.state_dir),
                                     "--assignment", reference, "--evidence", str(evidence),
                                     "--tmux-socket", socket, "--tmux-bin", tmux],
                                    capture_output=True, text=True)
            self.assertEqual(closed.returncode, 0, closed.stderr)
            self.assertEqual(json.loads(closed.stdout)["state"], "CleanupPending")
            self.assertNotEqual(tmux_cmd("has-session", "-t", "=owned").returncode, 0)
            self.assertEqual(manager.counts()["active"], 1)

            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "adopted", "/bin/sleep", "30").returncode, 0)
            key2 = OperationKey("host-test", "task-2", 1, "instance-2")
            adopted = manager.reserve(key2, "adopted", "UserAdopted")
            manager.begin_launch(key2)
            backend.mark("adopted", adopted.nonce)
            self.assertEqual(manager.attach(key2).state, "Running")
            self.assertEqual(manager.close(key2, {"kind": "result", "receipt": "r2"}).state,
                             "ReleasedAdopted")
            self.assertEqual(tmux_cmd("has-session", "-t", "=adopted").returncode, 0)
            self.assertEqual(tmux_cmd("display-message", "-p", "-t", "=adopted:",
                                      "#{@agent_work_resource_nonce}").stdout.strip(), "")
        finally:
            tmux_cmd("kill-server")

    def test_resource_tmux_replacement_is_never_marked_stopped_or_revoked(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-race-{os.getpid()}"
        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)
        backend = TmuxBackend(tmux, socket)
        def new_worker():
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "worker", "/bin/sleep 30").returncode, 0)
        def replace():
            self.assertEqual(tmux_cmd("kill-session", "-t", "=worker").returncode, 0)
            new_worker()
        try:
            for action in ("mark", "stop", "revoke"):
                new_worker()
                backend.mark("worker", "old_nonce")
                old = backend.observe("worker")
                if action == "mark":
                    original = backend._tmux
                    swapped = False
                    def swap_on_read(*args):
                        nonlocal swapped
                        result = original(*args)
                        if not swapped and args[0] in ("show-environment", "display-message"):
                            swapped = True
                            replace()
                        return result
                    backend._tmux = swap_on_read
                    try:
                        with self.assertRaises((OSError, ValueError)):
                            backend.mark("worker", "old_nonce")
                    finally:
                        backend._tmux = original
                else:
                    original = backend.observe
                    def swap_on_observe(session):
                        seen = original(session)
                        self.assertEqual(seen, old)
                        replace()
                        backend.mark("worker", "replacement_nonce")
                        return seen
                    backend.observe = swap_on_observe
                    try:
                        self.assertFalse(getattr(backend, action)(old))
                    finally:
                        backend.observe = original
                self.assertEqual(tmux_cmd("has-session", "-t", "=worker").returncode, 0)
                marker = backend.observe("worker")["nonce"]
                self.assertEqual(marker, "" if action == "mark" else "replacement_nonce")
                self.assertEqual(tmux_cmd("kill-session", "-t", "=worker").returncode, 0)
        finally:
            tmux_cmd("kill-server")

    def _managed_shell(self):
        root = Path(self.tmp.name)
        state = root / "runs"
        run = state / "run-1"
        run.mkdir(parents=True)
        evidence = root / "receipt.json"
        evidence.write_text('{"kind":"result","receipt":"native-r1"}')
        assignment = root / "assignment.json"
        assignment.write_text('{}')
        reg = run / "registro.json"
        reg.write_text(json.dumps({
            "id": "run-1", "estado": "abierta", "schema": "corrida.v2",
            "sesiones": [{"nombre": "managed-1", "host_id": "host-test",
                          "encargo_ref": str(assignment)}],
            "lanes": [{"id": "lane-1", "session": "managed-1",
                       "resource_receipt_ref": str(evidence)}],
        }))
        tmux = root / "tmux-shim"
        tmux.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >>\"$FAKE_TMUX_LOG\"\n"
            "case \"$1\" in\n"
            " show-environment) case \"$*\" in *OPENCLAW_WATCH_RUN) echo OPENCLAW_WATCH_RUN=run-1;;"
            " *OPENCLAW_WATCH) echo OPENCLAW_WATCH=1;; esac;;\n"
            " capture-pane) echo screen;;\n"
            "esac\n"
        )
        tmux.chmod(0o700)
        resource = root / "resource-shim.py"
        resource.write_text(
            "import json,os\n"
            "with open(os.environ['FAKE_RESOURCE_LOG'],'a') as stream: stream.write(os.environ['FAKE_RESOURCE_STATE']+'\\n')\n"
            "print(json.dumps({'state':os.environ['FAKE_RESOURCE_STATE'],'reason':'test'}))\n"
        )
        env = dict(os.environ, CORRIDA_STATE=str(state), TMUX_BIN=str(tmux),
                   FAKE_TMUX_LOG=str(root / "tmux.log"), FAKE_RESOURCE_LOG=str(root / "resource.log"),
                   AGENT_WORK_HOST_STATE_DIR=str(root / "host"), AGENT_WORK_TMUX_SOCKET="isolated-test",
                   AGENT_WORK_RESOURCE_BIN=str(resource))
        return root, reg, evidence, env

    def test_resource_close_managed_termination_keeps_marks_while_pending(self):
        root, reg, evidence, env = self._managed_shell()
        command = ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                   "run-1", "managed-1", "--evidence", str(evidence)]
        missing = subprocess.run(command[:-2], env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                 capture_output=True, text=True)
        self.assertNotEqual(missing.returncode, 0)
        pending = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="CleanupPending"),
                                 capture_output=True, text=True)
        self.assertNotEqual(pending.returncode, 0)
        self.assertNotIn("set-environment", (root / "tmux.log").read_text() if (root / "tmux.log").exists() else "")
        self.assertEqual(json.loads(reg.read_text())["estado"], "abierta")
        verified = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                  capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertIn("set-environment", (root / "tmux.log").read_text())

    def test_resource_close_cerrar_blocks_on_managed_pending(self):
        root, reg, evidence, env = self._managed_shell()
        shell = ('. "' + str(ROOT / "scripts" / "mac" / "corrida" / "lib.sh") + '"; '
                 'AQUI="' + str(ROOT / "scripts" / "mac" / "corrida") + '"; '
                 '. "' + str(ROOT / "scripts" / "mac" / "corrida" / "cerrar.sh") + '"; '
                 'cerrar_archivar_lanes run-1 "' + str(reg) + '"')
        pending = subprocess.run(["bash", "-c", shell], env=dict(env, FAKE_RESOURCE_STATE="CleanupPending"),
                                 capture_output=True, text=True)
        self.assertNotEqual(pending.returncode, 0)
        self.assertTrue((root / "runs" / "run-1" / "archive" / "lane-1" / "transcript.txt").exists())
        self.assertEqual(json.loads(reg.read_text())["estado"], "abierta")
        verified = subprocess.run(["bash", "-c", shell], env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                  capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(verified.stderr, "")
        self.assertEqual((root / "resource.log").read_text().splitlines(),
                         ["CleanupPending", "AbsenceVerified"])


if __name__ == "__main__":
    unittest.main()

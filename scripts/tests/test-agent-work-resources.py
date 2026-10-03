#!/usr/bin/env python3
import json
import hashlib
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))

from contracts import AuthorizedOperation, OperationKey
from host import Host
from resources import (AccountBusyError, AGENT_USER, AgentesBackend, CommandOutcome,
                       LOCK_ARGV, ResourceManager, TmuxBackend, parse_agent_ps)


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

    def test_resource_close_recovers_marked_launch_without_prior_attach(self):
        held = self.manager.reserve(self.key, "worker-1", "TaskCreated")
        self.manager.begin_launch(self.key)
        self.backend.launch("worker-1", held.nonce, 603)
        evidence = {"kind": "cancel", "receipt": "c1"}
        self.assertEqual(self.manager.close(self.key, evidence).state, "CleanupPending")
        self.assertEqual(self.manager.close(self.key, evidence).state, "AbsenceVerified")
        self.assertEqual(len(self.backend.stops), 1)
        self.assertEqual(self.backend.live, {})

        foreign = OperationKey("host-test", "task-2", 1, "instance-2")
        self.manager.reserve(foreign, "worker-2", "TaskCreated")
        self.manager.begin_launch(foreign)
        self.backend.launch("worker-2", "foreign-nonce", 604)
        self.assertEqual(self.manager.close(foreign, {"kind": "cancel", "receipt": "c2"}).state,
                         "CleanupPending")
        self.assertEqual(len(self.backend.stops), 1)
        self.assertIn("worker-2", self.backend.live)

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

    def test_resource_100_cycles_real_tmux_processes_leave_no_own_processes(self):
        tmux = shutil.which("tmux")
        if not tmux or not shutil.which("pgrep"):
            self.skipTest("tmux or pgrep not installed")
        socket = f"b31-cycles-{os.getpid()}"
        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)
        backend = TmuxBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=130)
        cli = Path(self.tmp.name) / "b31-cycles-cli.py"
        cli.write_text(
            "import subprocess,sys,time\n"
            "subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)',sys.argv[1]])\n"
            "time.sleep(120)\n"
        )
        nonces = []

        def nonce_gone(nonce):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if subprocess.run(["pgrep", "-f", "--", nonce], capture_output=True).returncode != 0:
                    return True
                time.sleep(0.05)
            return False

        try:
            for number in range(100):
                key = OperationKey("host-test", f"b31-cycle-{number}", 1, f"b31-instance-{number}")
                session = f"b31c{number}"
                ownership = "IntentionalPool" if number % 10 == 0 else "TaskCreated"
                held = manager.reserve(key, session, ownership)
                manager.begin_launch(key)
                self.assertEqual(tmux_cmd("new-session", "-d", "-s", session, sys.executable,
                                          str(cli), held.nonce).returncode, 0)
                backend.mark(session, held.nonce)
                self.assertEqual(manager.attach(key).state, "Running")
                self.assertEqual(manager.close(key, {"kind": "result", "receipt": f"cycle-{number}"}).state,
                                 "CleanupPending")
                self.assertNotEqual(tmux_cmd("has-session", "-t", f"={session}").returncode, 0)
                nonces.append(held.nonce)
                self.assertTrue(nonce_gone(held.nonce), f"cycle {number} left processes with its nonce")
            self.assertEqual(manager.counts(), {"active": 100, "history": 0, "pool": 10})
            for nonce in nonces:
                self.assertNotEqual(subprocess.run(["pgrep", "-f", "--", nonce],
                                                   capture_output=True).returncode, 0)
        finally:
            tmux_cmd("kill-server")
            for nonce in nonces:
                out = subprocess.run(["pgrep", "-f", "--", nonce], capture_output=True, text=True)
                for pid in out.stdout.split():
                    if not pid.isdigit():
                        continue
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except ProcessLookupError:
                        pass

    def test_resource_identity_adopted_without_nonce_and_claim_replay_close_reclose(self):
        naked = OperationKey("host-test", "task-2", 1, "instance-2")
        self.manager.reserve(naked, "user-naked", "UserAdopted")
        self.manager.begin_launch(naked)
        self.backend.launch("user-naked", "", 502)
        self.assertEqual(self.manager.attach(naked).state, "CleanupPending")
        self.assertEqual(self.manager.close(naked, {"kind": "result", "receipt": "r2"}).state,
                         "CleanupPending")
        self.assertEqual(self.backend.stops, [])
        self.assertEqual(self.backend.revokes, [])
        self.assertIn("user-naked", self.backend.live)

        claimed = OperationKey("host-test", "task-3", 1, "instance-3")
        held = self.manager.reserve(claimed, "user-claimed", "UserAdopted")
        self.assertTrue(self.manager.begin_launch(claimed).launch_now)
        self.backend.launch("user-claimed", held.nonce, 503)
        self.assertEqual(self.manager.attach(claimed).state, "Running")
        self.assertEqual(self.manager.reserve(claimed, "user-claimed", "UserAdopted").state, "Running")
        self.assertFalse(self.manager.begin_launch(claimed).launch_now)
        self.assertEqual(self.manager.close(claimed, {"kind": "result", "receipt": "r3"}).state,
                         "ReleasedAdopted")
        self.assertEqual(self.manager.close(claimed, {"kind": "result", "receipt": "r3"}).state,
                         "ReleasedAdopted")
        self.assertEqual(len(self.backend.revokes), 1)
        self.assertEqual(self.backend.stops, [])
        self.assertIn("user-claimed", self.backend.live)
        self.assertEqual(self.manager.counts(), {"active": 1, "history": 1, "pool": 0})

    def test_resource_close_lost_result_ack_never_closes_the_resource(self):
        brief = Path(self.tmp.name) / "brief.txt"
        brief.write_text("ack lost sandbox")
        assignment = AuthorizedOperation(
            key=self.key, producer_id="fake", capability="ack-secret", session="acked",
            workspace_ref=self.tmp.name, brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
            result_contract="review.v1", claim_id="ack-claim")
        reference = self.host.apply(self.key, assignment, lambda *_: None,
                                    lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                                               "hostId": a["hostId"], "instanceId": a["instanceId"],
                                               "generation": a["generation"]}).assignment_ref
        self.manager.reserve(self.key, "acked", "TaskCreated")
        evidence = Path(self.tmp.name) / "result.json"
        evidence.write_text('{"kind":"result","receipt":"lost-ack-1"}')
        closed = subprocess.run([sys.executable, str(ROOT / "scripts" / "agent-work" / "resources.py"),
                                 "close", "--host-id", "host-test", "--state-dir", str(self.host.state_dir),
                                 "--assignment", reference, "--evidence", str(evidence),
                                 "--tmux-socket", f"b31-ack-{os.getpid()}"],
                                capture_output=True, text=True)
        self.assertNotEqual(closed.returncode, 0, closed.stdout)
        self.assertIn("receipt", closed.stderr)
        self.assertEqual(self.manager.counts()["active"], 1)

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
                brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
                input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
                result_contract="review.v1", claim_id="sandbox-claim")
            reference = self.host.apply(self.key, assignment, lambda *_: None,
                                        lambda a: {"state": "host-admitted", "claimId": a["claimId"],
                                                   "hostId": a["hostId"], "instanceId": a["instanceId"],
                                                   "generation": a["generation"]}).assignment_ref
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

    def test_resource_identity_tmux_replacement_never_marks_stops_or_revokes(self):
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

    def test_resource_close_detached_child_keeps_mac_closure_pending(self):
        if sys.platform != "darwin":
            self.skipTest("macOS process proof")
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-detached-{os.getpid()}"
        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)
        backend = TmuxBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend)
        child_ref = Path(self.tmp.name) / "detached-child.json"
        token = f"agent-work-detached-{os.getpid()}"
        launcher = Path(self.tmp.name) / "launch-detached.py"
        launcher.write_text(
            "import json,subprocess,sys,time\n"
            "from pathlib import Path\n"
            "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)',sys.argv[2]],"
            "start_new_session=True)\n"
            "start=subprocess.run(['ps','-o','lstart=','-p',str(child.pid)],capture_output=True,text=True).stdout.strip()\n"
            "Path(sys.argv[1]).write_text(json.dumps({'pid':child.pid,'start':start}))\n"
            "time.sleep(60)\n"
        )
        child = None
        try:
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "owned", sys.executable,
                                      str(launcher), str(child_ref), token).returncode, 0)
            deadline = time.monotonic() + 5
            while not child_ref.exists() and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertTrue(child_ref.exists(), "detached child did not start")
            child = json.loads(child_ref.read_text())
            held = manager.reserve(self.key, "owned", "TaskCreated")
            manager.begin_launch(self.key)
            backend.mark("owned", held.nonce)
            self.assertEqual(manager.attach(self.key).state, "Running")
            self.assertEqual(manager.close(self.key, {"kind": "cancel", "receipt": "detached-test"}).state,
                             "CleanupPending")
            self.assertNotEqual(tmux_cmd("has-session", "-t", "=owned").returncode, 0)
            self.assertEqual(backend._start(str(child["pid"])), child["start"])
            self.assertEqual(manager.counts()["active"], 1)
        finally:
            tmux_cmd("kill-server")
            if child and backend._start(str(child["pid"])) == child["start"]:
                command = subprocess.run(["ps", "-o", "command=", "-p", str(child["pid"])],
                                         capture_output=True, text=True).stdout
                if token in command:
                    os.kill(child["pid"], signal.SIGTERM)

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

    def test_resource_close_partial_binding_keeps_marked_session(self):
        root, reg, evidence, env = self._managed_shell()
        record = json.loads(reg.read_text())
        del record["sesiones"][0]["encargo_ref"]
        reg.write_text(json.dumps(record))
        command = ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                   "run-1", "managed-1", "--evidence", str(evidence)]
        result = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        log = root / "tmux.log"
        self.assertNotIn("set-environment", log.read_text() if log.exists() else "")

    def test_resource_close_termination_rejects_duplicate_session_identity(self):
        root, reg, evidence, env = self._managed_shell()
        record = json.loads(reg.read_text())
        record["sesiones"].insert(0, dict(record["sesiones"][0]))
        reg.write_text(json.dumps(record))
        command = ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                   "run-1", "managed-1", "--evidence", str(evidence)]
        result = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        log = root / "tmux.log"
        self.assertNotIn("set-environment", log.read_text() if log.exists() else "")

    def test_resource_close_cerrar_rejects_duplicate_session_identity(self):
        root, reg, _, env = self._managed_shell()
        record = json.loads(reg.read_text())
        record["sesiones"].insert(0, {"nombre": "managed-1"})
        reg.write_text(json.dumps(record))
        shell = ('. "' + str(ROOT / "scripts" / "mac" / "corrida" / "lib.sh") + '"; '
                 'AQUI="' + str(ROOT / "scripts" / "mac" / "corrida") + '"; '
                 '. "' + str(ROOT / "scripts" / "mac" / "corrida" / "cerrar.sh") + '"; '
                 'cerrar_archivar_lanes run-1 "' + str(reg) + '"')
        result = subprocess.run(["bash", "-c", shell], env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((root / "resource.log").exists())

    def test_resource_close_cerrar_rejects_unbound_duplicate_lane(self):
        root, reg, _, env = self._managed_shell()
        record = json.loads(reg.read_text())
        record["lanes"].append({"id": "lane-2", "session": "managed-1"})
        reg.write_text(json.dumps(record))
        shell = ('. "' + str(ROOT / "scripts" / "mac" / "corrida" / "lib.sh") + '"; '
                 'AQUI="' + str(ROOT / "scripts" / "mac" / "corrida") + '"; '
                 '. "' + str(ROOT / "scripts" / "mac" / "corrida" / "cerrar.sh") + '"; '
                 'cerrar_archivar_lanes run-1 "' + str(reg) + '"')
        result = subprocess.run(["bash", "-c", shell], env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((root / "resource.log").exists())

    def test_resource_close_cerrar_requires_lane_for_managed_session(self):
        root, reg, _, env = self._managed_shell()
        record = json.loads(reg.read_text())
        record["lanes"] = []
        reg.write_text(json.dumps(record))
        shell = ('. "' + str(ROOT / "scripts" / "mac" / "corrida" / "lib.sh") + '"; '
                 'AQUI="' + str(ROOT / "scripts" / "mac" / "corrida") + '"; '
                 '. "' + str(ROOT / "scripts" / "mac" / "corrida" / "cerrar.sh") + '"; '
                 'cerrar_archivar_lanes run-1 "' + str(reg) + '"')
        result = subprocess.run(["bash", "-c", shell], env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((root / "resource.log").exists())

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

    AGENTES_LD = (
        "user/502 = {\n"
        "\ttype = user\n"
        "\tservices = {\n"
        "\t\t    9042   (pe) \tcom.apple.accessibility.mediaaccessibilityd\n"
        "\t\t     515      - \tcom.apple.lsd\n"
        "\t}\n"
        "}\n"
    )
    AGENTES_PS_FULL = (
        "4242 1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/python3 -c import time; time.sleep(30) b32nonce1\n"
        "4243 1 Sat Oct  3 09:00:01 2026 /usr/libexec/remotemanagementd worker\n"
        "515 1 Sat Oct  3 09:00:02 2026 /usr/libexec/xpcproxy com.apple.lsd\n"
    )
    AGENTES_PS_AFTER_TERM = (
        "4243 1 Sat Oct  3 09:00:01 2026 /usr/libexec/remotemanagementd worker\n"
    )
    KILL_ARGV_PREFIX = ["/usr/bin/lockf", "-t", "30", "-k", "/private/tmp/b32-agentes.lock",
                        "sudo", "-n", "-u", "agentes", "/bin/kill", "-TERM"]

    def _agentes_running(self, backend, session, capacity=1):
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=capacity)
        key = OperationKey("host-test", f"task-{session}", 1, f"instance-{session}")
        held = manager.reserve(key, session, "TaskCreated")
        manager.begin_launch(key)
        identity = {"bootId": backend.boot_id, "nonce": held.nonce, "socket": backend.socket,
                    "sessionName": session, "serverPid": 400, "serverStart": "server-birth",
                    "sessionId": "@9", "paneId": "%9", "panePid": 4242, "paneStart": "pane-birth"}
        backend.observe = lambda _session: identity
        backend.stop = lambda _identity: True
        self.assertEqual(manager.attach(key).state, "Running")
        return manager, key

    def _tmux_shim(self):
        log = Path(self.tmp.name) / "tmux.log"
        shim = Path(self.tmp.name) / "tmux-shim"
        shim.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"" + str(log) + "\"\n")
        shim.chmod(0o700)
        return shim, log

    def test_resource_close_agentes_apple_services_excluded_and_kill_argv(self):
        state = {"ps": self.AGENTES_PS_FULL}
        calls = []

        def ps_reader():
            return CommandOutcome(0, state["ps"])

        def launchd_reader():
            return CommandOutcome(0, self.AGENTES_LD)

        def runner(argv):
            calls.append(list(argv))
            if argv[:1] == ["ps"]:
                return CommandOutcome(0, "Sat Oct  3 09:00:00 2026 "
                                         "/opt/homebrew/bin/python3 -c import time; "
                                         "time.sleep(30) b32nonce1\n")
            state["ps"] = self.AGENTES_PS_AFTER_TERM
            return CommandOutcome(0, "")

        backend = AgentesBackend("/usr/bin/true", "ag-exclude", ps_reader=ps_reader,
                                 launchd_reader=launchd_reader, runner=runner, grace_seconds=0.5)
        manager, key = self._agentes_running(backend, "ag-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        kills = [call for call in calls if "/bin/kill" in call]
        self.assertEqual(kills, [self.KILL_ARGV_PREFIX + ["4242"]])
        containment = backend.last_containment
        self.assertEqual([entry["pid"] for entry in containment["before"]], [4242, 4243])
        self.assertFalse(containment["before"][1]["signalable"])
        self.assertEqual(containment["signals"],
                         [{"argv": self.KILL_ARGV_PREFIX + ["4242"], "rc": 0}])
        self.assertEqual([entry["pid"] for entry in containment["after"]], [4243])
        self.assertFalse(containment["after"][0]["signalable"])

    def test_resource_close_agentes_ghost_label_pid0_blocks_without_signals(self):
        ld_ghost = (
            "user/502 = {\n"
            "\tservices = {\n"
            "\t\t       0      - \tb32-feedface\n"
            "\t\t     515      - \tcom.apple.lsd\n"
            "\t}\n"
            "}\n"
        )
        calls = []
        backend = AgentesBackend("/usr/bin/true", "ag-ghost",
                                 ps_reader=lambda: CommandOutcome(0, ""),
                                 launchd_reader=lambda: CommandOutcome(0, ld_ghost),
                                 runner=lambda argv: calls.append(list(argv)) or CommandOutcome(0, ""),
                                 grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-ghost-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(calls, [])
        ghost = backend.last_containment["before"][0]
        self.assertEqual((ghost["pid"], ghost["label"], ghost["signalable"],
                          ghost["reason"]),
                         (0, "b32-feedface", False, "launchd label may be relaunched"))
        self.assertEqual(backend.last_containment["signals"], [])
        self.assertEqual([entry["label"] for entry in backend.last_containment["after"]],
                         ["b32-feedface"])

    def test_resource_close_agentes_reader_failure_pending_without_signals(self):
        variants = (
            ("launchd-rc", lambda: CommandOutcome(0, self.AGENTES_PS_FULL),
             lambda: CommandOutcome(1, "launchctl: operation failed\n")),
            ("services-block-missing", lambda: CommandOutcome(0, self.AGENTES_PS_FULL),
             lambda: CommandOutcome(0, "user/502 = {\n\ttype = user\n}\n")),
            ("ps-rc", lambda: CommandOutcome(1, "ps: nobody\n"),
             lambda: CommandOutcome(0, self.AGENTES_LD)),
            ("launchd-rc-valid-text", lambda: CommandOutcome(0, self.AGENTES_PS_FULL),
             lambda: CommandOutcome(1, self.AGENTES_LD)),
            ("ps-rc-valid-text", lambda: CommandOutcome(1, self.AGENTES_PS_FULL),
             lambda: CommandOutcome(0, self.AGENTES_LD)),
        )
        for name, ps_reader, launchd_reader in variants:
            with self.subTest(name):
                calls = []
                backend = AgentesBackend("/usr/bin/true", f"ag-fail-{name}",
                                         ps_reader=ps_reader, launchd_reader=launchd_reader,
                                         runner=lambda argv: calls.append(list(argv)) or CommandOutcome(0, ""),
                                         grace_seconds=0.2)
                manager, key = self._agentes_running(backend, f"ag-fail-session-{name}", capacity=5)
                view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
                self.assertEqual(view.state, "CleanupPending")
                self.assertEqual(view.reason, "host unavailable")
                self.assertEqual(calls, [])

    def test_resource_close_agentes_lstart_change_skips_signal(self):
        ps_lstart_a = ("700 1 Sat Oct  3 09:00:00 2026 "
                       "/opt/homebrew/bin/python3 -c import time; time.sleep(30) b32n4\n")
        ps_lstart_b = ("700 1 Sun Nov  1 10:00:00 2026 "
                       "/opt/homebrew/bin/python3 -c import time; time.sleep(30) b32n4\n")
        reads = [ps_lstart_a, ps_lstart_b]
        calls = []

        def ps_reader():
            return CommandOutcome(0, reads.pop(0) if reads else ps_lstart_b)

        backend = AgentesBackend("/usr/bin/true", "ag-lstart", ps_reader=ps_reader,
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=lambda argv: calls.append(list(argv)) or CommandOutcome(0, ""),
                                 grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-lstart-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(calls, [])
        self.assertEqual(backend.last_containment["signals"], [])

    def test_resource_identity_agentes_prelaunch_busy_refuses_launch(self):
        shim, log = self._tmux_shim()
        calls = []
        busy_ps = ("999 1 Sat Oct  3 09:00:00 2026 "
                   "/opt/homebrew/bin/python3 -c import time; time.sleep(30) b32n5\n")
        backend = AgentesBackend(str(shim), "ag-busy",
                                 ps_reader=lambda: CommandOutcome(0, busy_ps),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=lambda argv: calls.append(list(argv)) or CommandOutcome(0, ""))
        with self.assertRaisesRegex(AccountBusyError, "999"):
            backend.launch("ag-x", ["/usr/bin/true"])
        self.assertEqual(calls, [])
        self.assertFalse(log.exists())

    def test_resource_close_agentes_survivor_holds_capacity_then_verifies(self):
        survivor_ps = ("4242 1 Sat Oct  3 09:00:00 2026 "
                       "/opt/homebrew/bin/python3 -c import time; time.sleep(30) b32n6\n")
        state = {"ps": survivor_ps}
        calls = []

        def ps_reader():
            return CommandOutcome(0, state["ps"])

        def runner(argv):
            calls.append(list(argv))
            if argv[:1] == ["ps"]:
                return CommandOutcome(0, "Sat Oct  3 09:00:00 2026 "
                                         "/opt/homebrew/bin/python3 -c import time; "
                                         "time.sleep(30) b32n6\n")
            return CommandOutcome(0, "")

        backend = AgentesBackend("/usr/bin/true", "ag-survivor", ps_reader=ps_reader,
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=runner, grace_seconds=0.3)
        manager, key = self._agentes_running(backend, "ag-survivor-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "descendant absence unverified")
        self.assertEqual(manager.counts()["active"], 1)
        kills = [call for call in calls if "/bin/kill" in call]
        self.assertEqual(len(kills), 1)
        state["ps"] = ""
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "AbsenceVerified")
        self.assertEqual(manager.counts()["active"], 0)
        self.assertEqual(len([call for call in calls if "/bin/kill" in call]), 1)
        self.assertEqual(backend.last_containment["before"], [])
        self.assertEqual(backend.last_containment["after"], [])

    def test_resource_close_agentes_stop_failed_holds_without_signals_until_retried(self):
        state = {"observe": "identity", "stop": False}
        calls = []
        identity_box = {}

        backend = AgentesBackend("/usr/bin/true", "ag-stopfail",
                                 ps_reader=lambda: CommandOutcome(0, ""),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=lambda argv: calls.append(list(argv)) or CommandOutcome(0, ""),
                                 grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-stopfail-1")
        identity_box["value"] = backend.observe("ag-stopfail-1")

        def observe(_session):
            return identity_box["value"] if state["observe"] == "identity" else None

        def stop(_identity):
            return state["stop"]

        backend.observe = observe
        backend.stop = stop
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "stop failed")
        self.assertEqual(calls, [])
        self.assertEqual(manager.counts()["active"], 1)
        state["stop"] = True
        state["observe"] = "gone"
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "AbsenceVerified")
        self.assertEqual(calls, [])
        self.assertEqual(manager.counts()["active"], 0)

    def test_resource_identity_agentes_happy_launch_and_presence_clear(self):
        shim, _log = self._tmux_shim()
        calls = []
        workdir = "/private/tmp/b32-ag-fixed"

        def runner(argv):
            calls.append(list(argv))
            if "/usr/bin/mktemp" in argv:
                return CommandOutcome(0, workdir + "\n")
            return CommandOutcome(0, "")

        backend = AgentesBackend(str(shim), "ag-happy",
                                 ps_reader=lambda: CommandOutcome(0, ""),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=runner)
        made = backend.launch("ag-x", ["/opt/homebrew/bin/python3", "-c",
                                       "import time; time.sleep(30)", "b32n7"])
        self.assertEqual(made, workdir)
        self.assertEqual(len(calls), 2)
        self.assertIn("/usr/bin/mktemp", calls[0])
        self.assertEqual(calls[0][:len(LOCK_ARGV)], LOCK_ARGV)
        panel = calls[1]
        self.assertEqual(panel[:len(LOCK_ARGV)], LOCK_ARGV)
        for token in ("new-session", "sudo", "-n", "-u", "agentes"):
            self.assertIn(token, panel)
        self.assertIn("PATH=/opt/homebrew/bin:/usr/bin:/bin", panel)
        self.assertIn("TMPDIR=" + workdir, panel)
        self.assertIn(str(shim), panel)
        self.assertIn("run", panel)
        self.assertEqual(backend.account_presence(), ())

    def test_resource_identity_agentes_multiline_argv_never_makes_a_phantom_row(self):
        multiline_ps = ("4242 1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/python3 -c 'import os\n"
                        "701 1 Sat Oct  3 09:00:00 2026 /bin/injected -c fake\n"
                        "time.sleep(30)' b32n8\n")
        calls = []
        backend = AgentesBackend("/usr/bin/true", "ag-multiline",
                                 ps_reader=lambda: CommandOutcome(0, multiline_ps),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=lambda argv: calls.append(list(argv))
                                 or (CommandOutcome(1, "") if argv[:1] == ["ps"] else CommandOutcome(0, "")),
                                 grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-multiline-1")
        presence = backend.account_presence()
        self.assertEqual([entry.pid for entry in presence], [701, 4242])
        self.assertIn("/bin/injected -c fake", presence[0].command)
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual([call for call in calls if "/bin/kill" in call], [])

    REAL_DETACHED_LAUNCHER = (
        "import os,sys,time\n"
        "nonce=sys.argv[1]\n"
        "if os.fork()==0:\n"
        "    os.setsid()\n"
        "    if os.fork()==0:\n"
        "        os.closerange(0,3)\n"
        "        time.sleep(120)\n"
        "    os._exit(0)\n"
        "time.sleep(120)\n"
    )
    REAL_TERM_IGNORING_LAUNCHER = (
        "import os,signal,sys,time\n"
        "nonce=sys.argv[1]\n"
        "if os.fork()==0:\n"
        "    os.setsid()\n"
        "    if os.fork()==0:\n"
        "        os.closerange(0,3)\n"
        "        signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "        time.sleep(120)\n"
        "    os._exit(0)\n"
        "time.sleep(120)\n"
    )

    def _require_agentes_account(self):
        if sys.platform != "darwin":
            self.skipTest("macOS agent account proof")
        if not shutil.which("tmux"):
            self.fail("tmux not installed")
        probe = subprocess.run(["sudo", "-n", "-u", "agentes", "/usr/bin/true"],
                               capture_output=True)
        if probe.returncode != 0:
            self.fail("sudo -n -u agentes is not available")

    def _agentes_rows(self):
        done = subprocess.run(["ps", "-o", "pid=,ppid=,lstart=,command=", "-U", "agentes"],
                              capture_output=True, text=True)
        return parse_agent_ps(done.stdout) if done.returncode == 0 else ()

    def _registered_nonce(self, nonce):
        return {(row.pid, row.lstart) for row in self._agentes_rows() if nonce in row.command}

    def _sweep_registered(self, registered, nonce):
        for row in self._agentes_rows():
            if nonce not in row.command or (row.pid, row.lstart) not in registered:
                continue
            argv = LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/bin/kill", "-TERM", str(row.pid)]
            subprocess.run(argv, capture_output=True)

    def _nonce_gone(self, nonce, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if subprocess.run(["pgrep", "-f", "--", nonce], capture_output=True).returncode != 0:
                return True
            time.sleep(0.1)
        return False

    def test_resource_close_real_detached_children_proven_absent(self):
        self._require_agentes_account()
        tmux = shutil.which("tmux")
        socket = f"b32-ag-detached-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        backend = AgentesBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=1)
        nonce = ""
        registered = set()
        try:
            held = manager.reserve(self.key, "ag-owned", "TaskCreated")
            manager.begin_launch(self.key)
            nonce = held.nonce
            backend.launch("ag-owned", ["/opt/homebrew/bin/python3", "-c",
                                        self.REAL_DETACHED_LAUNCHER, nonce])
            backend.mark("ag-owned", nonce)
            self.assertEqual(manager.attach(self.key).state, "Running")
            registered = self._registered_nonce(nonce)
            self.assertTrue(registered, "detached grandchild did not reach the agent account")
            self.assertEqual(manager.close(self.key, {"kind": "cancel", "receipt": "c1"}).state,
                             "AbsenceVerified")
            self.assertTrue(backend.last_containment,
                            "account proof must record its containment report")
            self.assertTrue(backend.last_containment["signals"],
                            "the detached grandchild must be swept by a recorded signal")
            self.assertTrue(self._nonce_gone(nonce), "nonce processes survived an AbsenceVerified close")
        finally:
            tmux_cmd("kill-server")
            self._sweep_registered(registered, nonce)

    def test_resource_close_real_launchd_label_stays_pending(self):
        self._require_agentes_account()
        tmux = shutil.which("tmux")
        socket = f"b32-ag-submit-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        backend = AgentesBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=1)
        nonce = ""
        label = ""
        registered = set()
        try:
            held = manager.reserve(self.key, "ag-sub", "TaskCreated")
            manager.begin_launch(self.key)
            nonce = held.nonce
            label = f"b32-{nonce}"
            backend.launch("ag-sub", ["/opt/homebrew/bin/python3", "-c",
                                      "import time; time.sleep(120)", nonce])
            staging = Path(tempfile.mkdtemp(prefix="b32-", dir="/private/tmp"))
            staging.chmod(0o755)
            plist = staging / f"{label}.plist"
            plist.write_text(
                f"<?xml version='1.0' encoding='UTF-8'?>\n"
                f"<!DOCTYPE plist PUBLIC '-//Apple//DTD PLIST 1.0//EN' "
                f"'http://www.apple.com/DTDs/PropertyList-1.0.dtd'>\n"
                f"<plist version='1.0'><dict>\n"
                f"<key>Label</key><string>{label}</string>\n"
                f"<key>ProgramArguments</key><array>\n"
                f"<string>/opt/homebrew/bin/python3</string><string>-c</string>\n"
                f"<string>import time; time.sleep(120)</string><string>{nonce}</string>\n"
                f"</array>\n"
                f"<key>KeepAlive</key><false/>\n"
                f"<key>RunAtLoad</key><true/>\n"
                f"</dict></plist>\n")
            self.addCleanup(shutil.rmtree, staging, ignore_errors=True)
            bootstrapped = subprocess.run(["sudo", "-n", "-u", "agentes", "/bin/launchctl",
                                           "bootstrap", "user/502", str(plist)],
                                          capture_output=True, text=True)
            if bootstrapped.returncode == 5 and "Input/output error" in bootstrapped.stderr:
                self.skipTest("user/502 Background-only: bootstrap/load give EIO 5 "
                              "until David starts a real agentes login session")
            self.assertEqual(bootstrapped.returncode, 0, bootstrapped.stderr)
            backend.mark("ag-sub", nonce)
            self.assertEqual(manager.attach(self.key).state, "Running")
            registered = self._registered_nonce(nonce)
            self.assertGreaterEqual(len(registered), 2, "pane child and launchd child expected")
            self.assertEqual(manager.close(self.key, {"kind": "cancel", "receipt": "c1"}).state,
                             "CleanupPending")
            printed = subprocess.run(["sudo", "-n", "-u", "agentes", "/bin/launchctl",
                                      "print", f"user/502/{label}"], capture_output=True)
            self.assertEqual(printed.returncode, 0, "launchd label must remain in user/502")
            self.assertTrue(self._nonce_gone(nonce), "launchd child should be gone after containment")
        finally:
            if label:
                removed = subprocess.run(["sudo", "-n", "-u", "agentes", "/bin/launchctl",
                                          "remove", label], capture_output=True)
                if removed.returncode != 0:
                    subprocess.run(["sudo", "-n", "-u", "agentes", "/bin/launchctl",
                                    "bootout", f"user/502/{label}"], capture_output=True)
            tmux_cmd("kill-server")
            self._sweep_registered(registered, nonce)

    def test_resource_close_real_term_ignoring_survivor_stays_pending(self):
        self._require_agentes_account()
        tmux = shutil.which("tmux")
        socket = f"b32-ag-ignorer-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        backend = AgentesBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=1)
        nonce = ""
        registered = set()
        gone = True
        try:
            held = manager.reserve(self.key, "ag-ignore", "TaskCreated")
            manager.begin_launch(self.key)
            nonce = held.nonce
            backend.launch("ag-ignore", ["/opt/homebrew/bin/python3", "-c",
                                         self.REAL_TERM_IGNORING_LAUNCHER, nonce])
            backend.mark("ag-ignore", nonce)
            self.assertEqual(manager.attach(self.key).state, "Running")
            registered = self._registered_nonce(nonce)
            view = manager.close(self.key, {"kind": "cancel", "receipt": "c1"})
            self.assertEqual(view.state, "CleanupPending")
            self.assertEqual(view.reason, "descendant absence unverified")
            survivors = [row for row in self._agentes_rows()
                         if nonce in row.command and (row.pid, row.lstart) in registered]
            self.assertTrue(survivors, "the TERM-ignoring survivor must still be present")
        finally:
            tmux_cmd("kill-server")
            for row in self._agentes_rows():
                if nonce and nonce in row.command and (row.pid, row.lstart) in registered:
                    subprocess.run(["sudo", "-n", "-u", "agentes", "/bin/kill",
                                    "-KILL", str(row.pid)], capture_output=True)
            if nonce:
                gone = self._nonce_gone(nonce)
        if not gone:
            self.fail("TERM-ignoring survivor was not killed in cleanup")

    def test_resource_100_cycles_real_account_absence_verified(self):
        self._require_agentes_account()
        tmux = shutil.which("tmux")
        socket = f"b32-ag-cycles-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        backend = AgentesBackend(tmux, socket)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=1)
        nonces = []
        try:
            for number in range(100):
                key = OperationKey("host-test", f"b32ag-task-{number}", 1,
                                   f"b32ag-instance-{number}")
                session = f"b32ag{number}"
                held = manager.reserve(key, session, "TaskCreated")
                manager.begin_launch(key)
                backend.launch(session, ["/opt/homebrew/bin/python3", "-c",
                                         "import time; time.sleep(30)", held.nonce])
                backend.mark(session, held.nonce)
                self.assertEqual(manager.attach(key).state, "Running")
                self.assertEqual(manager.close(key, {"kind": "result",
                                                     "receipt": f"cycle-{number}"}).state,
                                 "AbsenceVerified")
                self.assertTrue(self._nonce_gone(held.nonce),
                                f"cycle {number} left processes with its nonce")
                nonces.append(held.nonce)
        finally:
            tmux_cmd("kill-server")
            for nonce in nonces:
                self._sweep_registered(self._registered_nonce(nonce), nonce)
        pooled = ResourceManager(self.host.spool, "host-test", FakeBackend(), capacity=10)
        for number in range(10):
            pooled.reserve(OperationKey("host-test", f"b32ag-pool-{number}", 1,
                                        f"b32ag-pool-instance-{number}"),
                           f"b32agpool{number}", "IntentionalPool")
        self.assertEqual(manager.counts(), {"active": 10, "history": 100, "pool": 10})


if __name__ == "__main__":
    unittest.main()

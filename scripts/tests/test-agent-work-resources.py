#!/usr/bin/env python3
import base64
import json
import hashlib
import os
import re
import secrets
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))

from contracts import AuthorizedOperation, OperationKey, operation_id
from host import Host, cli_adapter, read_composer, reject_permission_dialog
from spool import canonical
from native_gateway import (GatewayProjectionClient, claim_cli_once, close_only, pump_once,
                            read_spool_resources)
from resources import (AccountBusyError, AGENT_USER, AgentesBackend, AgentProcess, CommandOutcome,
                       LOCK_ARGV, ResourceManager, TmuxBackend, parse_agent_ps)


class FakeBackend:
    def __init__(self):
        self.boot_id = "00000000-0000-0000-0000-000000000001"
        self.socket = "sock-test"
        self.live = {}
        self.stops = []
        self.revokes = []
        self.fail_stop = False
        self.detached = False
        self.offline = False
        self.pane_gone_result = False
        self.pane_gone_error = None

    def observe(self, session):
        if self.offline:
            raise OSError("host unreachable")
        return self.live.get(session)

    def pane_gone(self, identity):
        if self.pane_gone_error is not None:
            raise self.pane_gone_error
        return self.pane_gone_result

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

    def mark(self, session, nonce):
        self.live[session]["nonce"] = nonce

    def launch(self, session, nonce, pid):
        self.live[session] = {
            "bootId": self.boot_id, "nonce": nonce, "socket": self.socket,
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
        self.backend.boot_id = "00000000-0000-0000-0000-000000000002"
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

    def adopt(self, manager, key, pid):
        """The host adopts the operator's opencode session "oc" for key, as claim_cli_once does."""
        held = manager.reserve(key, "oc", "UserAdopted")
        manager.begin_launch(key)
        self.backend.launch("oc", held.nonce, pid)
        self.assertEqual(manager.attach(key).state, "Running")
        brief = Path(self.tmp.name) / "brief.txt"
        brief.write_text("revisa el cambio")
        return AuthorizedOperation(
            key=key, producer_id="opencode", capability=f"cap-{key.task_id}", session="oc",
            workspace_ref=self.tmp.name, brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
            result_contract="review.v1", claim_id=f"claim-{key.task_id}")

    @staticmethod
    def admit(assignment):
        return {"state": "host-admitted", "claimId": assignment["claimId"], "hostId": assignment["hostId"],
                "instanceId": assignment["instanceId"], "generation": assignment["generation"]}

    def test_an_abandoned_delivery_releases_the_adopted_session_and_frees_the_instance(self):
        with self.host.spool.connection() as db:
            db.executescript("""
                DROP INDEX one_active_per_instance;
                CREATE UNIQUE INDEX one_active_per_instance ON operations(instance_id)
                    WHERE status != 'acknowledged';
                PRAGMA user_version=0;
            """)
        host = Host("host-test", self.host.state_dir)
        manager = ResourceManager(host.spool, "host-test", self.backend, capacity=1)
        abandoned = self.adopt(manager, self.key, 701)

        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        self.assertEqual(host.apply(self.key, abandoned, lost, self.admit).status, "uncertain")
        self.assertEqual(host.resolve_delivery("host-test", self.key, "abandoned", "un diálogo se comió la referencia"),
                         "abandoned")
        with host.spool.connection() as db:
            self.assertEqual(tuple(db.execute("SELECT state, reason FROM resources WHERE operation_id=?",
                                              (operation_id(self.key),)).fetchone()),
                             ("ReleasedAdopted", "delivery abandoned"))
        self.assertEqual((self.backend.stops, self.backend.revokes), ([], []), "abandoning touched the CLI")
        self.assertIn("oc", self.backend.live)

        following = OperationKey("host-test", "task-2", 1, "instance-1")
        self.assertEqual(host.apply(following, self.adopt(manager, following, 702), lambda *_: None,
                                    self.admit).status, "delivered")
        artifact = Path(self.tmp.name) / "late.txt"
        artifact.write_text("resultado tardío")
        host.report("host-test", {
            "schema": "agent-work.result.v1", "kind": "produced", "hostId": "host-test", "taskId": "task-1",
            "generation": 1, "instanceId": "instance-1", "producerId": "opencode", "capability": "cap-task-1",
            "observedRevision": abandoned.input_revision, "typedPayload": {"verdict": "approved"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(artifact.read_bytes()).hexdigest()})
        self.assertEqual(host.spool.get(operation_id(self.key))["status"], "abandoned",
                         "a late result put the abandoned operation back on the instance")
        self.assertEqual(len(host.pending("host-test")), 1)

    def operation(self, key):
        brief = Path(self.tmp.name) / "brief.txt"
        brief.write_text("revisa el cambio")
        return AuthorizedOperation(
            key=key, producer_id="opencode", capability=f"cap-{key.task_id}", session="oc",
            workspace_ref=self.tmp.name, brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
            result_contract="review.v1", claim_id=f"claim-{key.task_id}")

    def test_the_session_of_an_abandoned_delivery_is_adopted_again_by_its_instance(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-readopt-{os.getpid()}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        def session_nonce():
            return tmux_cmd("display-message", "-p", "-t", "=oc:", "#{@agent_work_resource_nonce}").stdout.strip()

        self.addCleanup(tmux_cmd, "kill-server")
        self.assertEqual(tmux_cmd("new-session", "-d", "-s", "oc", "/bin/sleep", "60").returncode, 0)
        cli_pid = tmux_cmd("display-message", "-p", "-t", "=oc:", "#{pane_pid}").stdout.strip()
        manager = ResourceManager(self.host.spool, "host-test", TmuxBackend(tmux, socket), capacity=1)

        def adopt(key):
            manager.reserve(key, "oc", "UserAdopted")
            self.assertTrue(manager.begin_launch(key).launch_now)
            manager.mark(key)
            self.assertEqual(manager.attach(key).state, "Running")

        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        adopt(self.key)
        self.assertEqual(self.host.apply(self.key, self.operation(self.key), lost, self.admit).status, "uncertain")
        self.host.resolve_delivery("host-test", self.key, "abandoned", "un diálogo se comió la referencia")
        self.assertTrue(manager.can_take("instance-1"))

        following = OperationKey("host-test", "task-2", 1, "instance-1")
        adopt(following)
        self.assertEqual(session_nonce(), manager._row(following)["nonce"])
        self.assertEqual(self.host.apply(following, self.operation(following), lambda *_: None,
                                         self.admit).status, "delivered")
        self.assertEqual(manager.counts(), {"active": 1, "history": 1, "pool": 0})
        self.assertEqual(tmux_cmd("display-message", "-p", "-t", "=oc:", "#{pane_pid}").stdout.strip(), cli_pid,
                         "re-adopting the session stopped the operator's CLI")

        intruder = OperationKey("host-test", "task-3", 1, "instance-2")
        roomy = ResourceManager(self.host.spool, "host-test", TmuxBackend(tmux, socket), capacity=2)
        roomy.reserve(intruder, "oc", "UserAdopted")
        roomy.begin_launch(intruder)
        with self.assertRaisesRegex(ValueError, "another resource"):
            roomy.mark(intruder)
        self.assertEqual(session_nonce(), manager._row(following)["nonce"], "a live resource lost its session")

    def test_the_pump_gives_an_adopted_session_back_once_r_acknowledges_its_result(self):
        class Client:
            host_id = "host-test"

            def __init__(self):
                self.closures = []

            def report_host_result(self, result, _):
                return {**{field: result[field] for field in ("hostId", "taskId", "generation", "instanceId",
                                                              "producerId")},
                        "resultId": hashlib.sha256(canonical(result).encode()).hexdigest(), "receiptId": "rcpt-1"}

            def close_host(self, assignment, state, reason, _):
                self.closures.append((assignment["taskId"], state, reason))
                return {}

            def list_pending(self, **_):
                return []

            def report_host_incident(self, *_):
                raise AssertionError("no incident was recorded")

        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        operation = self.adopt(manager, self.key, 704)
        self.assertEqual(self.host.apply(self.key, operation, lambda *_: None, self.admit).status, "delivered")
        identity = self.backend.live["oc"]
        artifact = Path(self.tmp.name) / "review.txt"
        artifact.write_text("aprobado")
        self.host.report("host-test", {
            "schema": "agent-work.result.v1", "kind": "produced", "hostId": "host-test", "taskId": "task-1",
            "generation": 1, "instanceId": "instance-1", "producerId": "opencode", "capability": "cap-task-1",
            "observedRevision": operation.input_revision, "typedPayload": {"verdict": "approved"},
            "artifactRef": str(artifact), "digest": hashlib.sha256(artifact.read_bytes()).hexdigest()})
        self.assertFalse(manager.can_take("instance-1"))

        client = Client()
        self.assertEqual(pump_once(client, host=self.host, evidence_root=self.tmp.name,
                                   progress_state_dir=self.tmp.name, progress_client="unused",
                                   cli_release=manager.release_acknowledged),
                         {"reported": 1, "transferred": 0, "published": 0, "closed": 1, "incidents": 0, "released": 1})
        with self.host.spool.connection() as db:
            self.assertEqual(tuple(db.execute("SELECT state, evidence_json FROM resources WHERE operation_id=?",
                                              (operation_id(self.key),)).fetchone()),
                             ("ReleasedAdopted", '{"kind":"result","receipt":"rcpt-1"}'))
        self.assertEqual(client.closures, [("task-1", "ReleasedAdopted", "")])
        self.assertTrue(manager.can_take("instance-1"), "the next task found the host full")
        self.assertEqual((self.backend.stops, self.backend.revokes), ([], [identity]),
                         "releasing stopped the operator's CLI")
        self.assertIn("oc", self.backend.live)

    def test_opening_a_spool_from_before_b9_releases_sessions_its_abandoned_deliveries_hold(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        self.host.apply(self.key, self.adopt(manager, self.key, 703), lambda *_: None, self.admit)
        with self.host.spool.connection() as db:
            db.execute("UPDATE operations SET status='abandoned' WHERE operation_id=?", (operation_id(self.key),))
            db.executescript("""
                DROP INDEX one_active_per_instance;
                CREATE UNIQUE INDEX one_active_per_instance ON operations(instance_id)
                    WHERE status != 'acknowledged';
                PRAGMA user_version=0;
            """)
        self.assertFalse(manager.can_take("instance-2"))

        host = Host("host-test", self.host.state_dir)
        with host.spool.connection() as db:
            self.assertEqual(tuple(db.execute("SELECT state, reason FROM resources WHERE operation_id=?",
                                              (operation_id(self.key),)).fetchone()),
                             ("ReleasedAdopted", "delivery abandoned"))
        self.assertTrue(ResourceManager(host.spool, "host-test", self.backend, capacity=1).can_take("instance-2"))
        self.assertEqual(self.backend.stops, [], "the migration stopped the operator's CLI")

    def cancelling_client(self, cancellations):
        class Client:
            host_id = "host-test"

            def __init__(self):
                self.reads, self.closures = [], []

            def host_cancellation(self, assignment):
                self.reads.append(assignment["taskId"])
                return cancellations.get(assignment["taskId"])

            def close_host(self, assignment, state, reason, digest):
                self.closures.append((assignment["taskId"], state, reason, digest))
                return {}

            def list_pending(self, **_):
                return []

            def report_host_result(self, *_):
                raise AssertionError("a cancelled task has no result to report")

            def report_host_incident(self, *_):
                raise AssertionError("no incident was recorded")

        return Client()

    def held_opencode(self, manager, key, pid):
        operation = replace(self.adopt(manager, key, pid), adapter_id="opencode")
        self.assertEqual(self.host.apply(key, operation, lambda *_: None, self.admit).status, "typed")
        self.host.spool.delivered(operation_id(key))
        return operation

    def cancel_pass(self, client, manager, dialogs, claims):
        def reject(identity):
            dialogs.append(identity)
            return "rejected"

        return pump_once(client, host=self.host, evidence_root=self.tmp.name, progress_state_dir=self.tmp.name,
                         progress_client="unused",
                         cli_cancel=lambda: manager.release_cancelled(client.host_cancellation, reject),
                         cli_claim=lambda: claims.append(manager.can_take("instance-1")))

    def test_the_pump_releases_a_task_r_cancelled_and_frees_the_host_in_the_same_pass(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        self.held_opencode(manager, self.key, 705)
        identity = self.backend.live["oc"]
        client, dialogs, claims = self.cancelling_client({"task-1": "cancel-1"}), [], []
        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims),
                         {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0, "claimed": 0,
                          "cancelled": 1})
        with self.host.spool.connection() as db:
            self.assertEqual(tuple(db.execute("SELECT state, evidence_json FROM resources WHERE operation_id=?",
                                              (operation_id(self.key),)).fetchone()),
                             ("ReleasedAdopted", '{"kind":"cancel","receipt":"cancel-1"}'))
        self.assertEqual(client.closures, [("task-1", "ReleasedAdopted", "", hashlib.sha256(
            b'{"kind":"cancel","receipt":"cancel-1"}').hexdigest())])
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "cancelled")
        self.assertEqual(self.host.spool.cancellation(operation_id(self.key)),
                         {"operation_id": operation_id(self.key), "cancellation_id": "cancel-1",
                          "dialog": "rejected"})
        self.assertEqual(dialogs, [identity], "the permission dialog was not answered before the release")
        self.assertEqual(claims, [True], "the claim of the same pass found the host full")
        self.assertEqual((self.backend.stops, self.backend.revokes), ([], [identity]),
                         "cancelling stopped the operator's CLI")
        self.assertIn("oc", self.backend.live)

        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims),
                         {"reported": 0, "transferred": 0, "published": 0, "closed": 0, "incidents": 0, "claimed": 0,
                          "cancelled": 0})
        self.assertEqual((client.reads, len(client.closures), len(dialogs)), (["task-1"], 1, 1))
        following = OperationKey("host-test", "task-2", 1, "instance-1")
        self.assertEqual(self.host.apply(following, self.adopt(manager, following, 706), lambda *_: None,
                                         self.admit).status, "delivered")

    def test_a_task_r_did_not_cancel_keeps_its_session(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        self.held_opencode(manager, self.key, 707)
        client, dialogs, claims = self.cancelling_client({}), [], []
        for _ in range(2):
            self.assertEqual(self.cancel_pass(client, manager, dialogs, claims),
                             {"reported": 0, "transferred": 0, "published": 0, "closed": 0, "incidents": 0, "claimed": 0,
                              "cancelled": 0})
        self.assertEqual(client.reads, ["task-1", "task-1"])
        with self.host.spool.connection() as db:
            self.assertEqual(tuple(db.execute("SELECT state, evidence_json FROM resources WHERE operation_id=?",
                                              (operation_id(self.key),)).fetchone()), ("Running", None))
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "delivered")
        self.assertEqual((client.closures, dialogs, self.backend.revokes), ([], [], []))
        self.assertFalse(manager.can_take("instance-2"))

    def test_a_cancellation_whose_release_failed_retries_without_asking_r_again(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        self.held_opencode(manager, self.key, 708)
        client, dialogs, claims = self.cancelling_client({"task-1": "cancel-1"}), [], []

        def reject_then_drop(identity):
            dialogs.append(identity)
            self.backend.offline = True
            return "rejected"

        with self.assertRaisesRegex(RuntimeError, "cancelled; resource CleanupPending: host unavailable"):
            pump_once(client, host=self.host, evidence_root=self.tmp.name, progress_state_dir=self.tmp.name,
                      progress_client="unused",
                      cli_cancel=lambda: manager.release_cancelled(client.host_cancellation, reject_then_drop))
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "cancelled")
        self.assertFalse(manager.can_take("instance-1"))
        self.backend.offline = False
        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims),
                         {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0, "claimed": 0,
                          "cancelled": 1})
        self.assertEqual((client.reads, len(dialogs)), (["task-1"], 1))
        self.assertEqual([closure[1:3] for closure in client.closures],
                         [("CleanupPending", "host unavailable"), ("ReleasedAdopted", "")])
        self.assertEqual(claims, [True])

    def test_r_gets_the_closure_of_an_abandoned_delivery_once_it_cancels_the_task(self):
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        operation = replace(self.adopt(manager, self.key, 709), adapter_id="opencode")

        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        self.assertEqual(self.host.apply(self.key, operation, lost, self.admit).status, "uncertain")
        self.host.resolve_delivery("host-test", self.key, "abandoned", "un diálogo se comió la referencia")
        cancellations, dialogs, claims = {}, [], []
        client = self.cancelling_client(cancellations)
        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims)["closed"], 0)
        self.assertEqual((client.reads, client.closures), (["task-1"], []))
        cancellations["task-1"] = "cancel-1"
        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims),
                         {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0, "claimed": 0,
                          "cancelled": 1})
        self.assertEqual(client.closures, [("task-1", "ReleasedAdopted", "delivery abandoned", hashlib.sha256(
            b'{"kind":"cancel","receipt":"cancel-1"}').hexdigest())])
        self.assertEqual(self.cancel_pass(client, manager, dialogs, claims)["closed"], 0)
        self.assertEqual((client.reads, len(client.closures), dialogs), (["task-1", "task-1"], 1, []))
        self.assertEqual(self.host.spool.get(operation_id(self.key))["status"], "abandoned")
        self.assertEqual((self.backend.stops, self.backend.revokes), ([], []), "the closure touched the CLI")

    def dialog_retry(self, outcomes, key=None):
        """A task R cancelled while its adopted pane answers each Esc with the next of outcomes. Returns the
        Gateway client, the Esc attempts so far and one pump pass: its closure count, or its error."""
        key = key or self.key
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        self.held_opencode(manager, key, 720)
        client = self.cancelling_client({key.task_id: "cancel-1"})
        script, tried = list(outcomes), []

        def reject(identity):
            tried.append(identity)
            return script.pop(0)

        def one_pass():
            try:
                return pump_once(client, host=self.host, evidence_root=self.tmp.name,
                                 progress_state_dir=self.tmp.name, progress_client="unused",
                                 cli_cancel=lambda: manager.release_cancelled(client.host_cancellation,
                                                                              reject))["closed"]
            except RuntimeError as exc:
                return str(exc)

        return client, tried, one_pass

    def test_a_permission_dialog_the_esc_left_on_screen_keeps_the_session_and_is_retried(self):
        client, tried, one_pass = self.dialog_retry(
            ["left: permission dialog visible but Esc did not close it", "rejected"])
        op_id = operation_id(self.key)
        self.assertEqual(one_pass(), f"{op_id}: cancelled; permission dialog left: permission dialog visible but "
                                     "Esc did not close it, attempt 1 of 3; the session stays held")
        self.assertEqual(self.resource(self.key), ("Running", ""))
        self.assertEqual((client.closures, self.backend.revokes), ([], []), "the host let go of the pane")
        self.assertEqual(self.host.spool.cancellation(op_id)["dialog"], None)
        self.assertEqual(one_pass(), 1)
        self.assertEqual(client.closures, [("task-1", "ReleasedAdopted", "", hashlib.sha256(
            b'{"kind":"cancel","receipt":"cancel-1"}').hexdigest())])
        self.assertEqual(self.host.spool.cancellation(op_id)["dialog"], "rejected")
        self.assertEqual(one_pass(), 0)
        self.assertEqual((len(tried), client.reads), (2, ["task-1"]))

    def test_a_permission_dialog_that_never_closes_is_released_after_three_attempts(self):
        still = "left: permission dialog visible but Esc did not close it"
        client, tried, one_pass = self.dialog_retry([still] * 3)
        op_id = operation_id(self.key)
        self.assertEqual([one_pass() for _ in range(4)], [
            f"{op_id}: cancelled; permission dialog {still}, attempt 1 of 3; the session stays held",
            f"{op_id}: cancelled; permission dialog {still}, attempt 2 of 3; the session stays held",
            f"{op_id}: cancelled; permission dialog {still} after 3 attempts",
            0])
        self.assertEqual(len(tried), 3)
        self.assertEqual(self.resource(self.key), ("ReleasedAdopted", ""))
        self.assertEqual(self.host.spool.cancellation(op_id)["dialog"], f"{still} after 3 attempts")
        self.assertEqual([closure[1:3] for closure in client.closures], [("ReleasedAdopted", "")])

    def test_any_other_dialog_outcome_releases_the_session_in_the_same_pass(self):
        for index, outcome in enumerate(("left: no empty composer after the reject key", "left: pane unverifiable",
                                         "left: reject key not sent")):
            with self.subTest(outcome):
                key = OperationKey("host-test", f"task-left-{index}", 1, "instance-1")
                client, tried, one_pass = self.dialog_retry([outcome], key)
                self.assertEqual(one_pass(), f"{operation_id(key)}: cancelled; permission dialog {outcome}")
                self.assertEqual(self.resource(key), ("ReleasedAdopted", ""))
                self.assertEqual(self.host.spool.cancellation(operation_id(key))["dialog"], outcome)
                self.assertEqual(([closure[1] for closure in client.closures], len(tried)),
                                 (["ReleasedAdopted"], 1))

    def orphan(self, attached):
        """claim_cli_once adopts the operator's session "oc" for task-1, and the host dies before registering
        the operation: right after reserve, or after attach. Returns the manager a restarted host opens."""
        brief = b"revisa el cambio"
        digest = hashlib.sha256(brief).hexdigest()
        claim = {"hostId": "host-test", "adapterId": "opencode", "instanceId": "instance-1", "taskId": "task-1",
                 "generation": 1, "claimId": "claim-task-1",
                 "capability": {"taskId": "task-1", "generation": 1, "producerId": "opencode", "token": "cap-task-1"},
                 "assignment": {"target": {"kind": "cli", "hostId": "host-test", "adapterId": "opencode"},
                                "inputRevision": {"kind": "code", "repository": "repo", "sha": "a" * 40},
                                "resultContract": "review.v1",
                                "instructionRef": {"ref": "artifact:" + digest, "digest": "sha256:" + digest}}}

        class Client:
            host_id = "host-test"

            def claim_host(self, *_):
                return claim

            def brief_chunk(self, adapter_id, instance_id, task_id, claim_id, offset, length):
                return {"taskId": task_id, "claimId": claim_id, "digest": "sha256:" + digest, "offset": offset,
                        "size": len(brief), "dataBase64": base64.b64encode(brief[offset:offset + length]).decode()}

            def admit_host(self, _):
                raise AssertionError("the host died before admitting")

        class HostDied(Exception):
            pass

        self.backend.launch("oc", "", 730)
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        with mock.patch.object(*((self.host, "apply") if attached else (manager, "begin_launch")),
                               side_effect=HostDied), self.assertRaises(HostDied):
            claim_cli_once(Client(), host=self.host, manager=manager, adapter_id="opencode",
                           instance_id="instance-1", session="oc", workspace_root=self.tmp.name,
                           deliver=lambda *_: None,
                           coverage={"hostAdapterCoverage": {"host-test": {"opencode": "certified"}}})
        self.assertIsNone(self.host.spool.get(operation_id(self.key)))
        return ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)

    def orphan_pass(self, client, manager, dialogs):
        return pump_once(client, host=self.host, evidence_root=self.tmp.name, progress_state_dir=self.tmp.name,
                         progress_client="unused",
                         cli_cancel=lambda: manager.release_cancelled(client.host_cancellation, dialogs.append))

    def test_a_reservation_whose_host_died_before_registering_closes_once_r_cancels_its_task(self):
        for attached, reason in ((False, "adopted session never marked"), (True, "")):
            with self.subTest(attached=attached):
                self.setUp()
                manager = self.orphan(attached)
                self.assertFalse(manager.can_take("instance-2"))
                client, dialogs = self.cancelling_client({"task-1": "cancel-1"}), []
                asked = []
                read = client.host_cancellation
                client.host_cancellation = lambda assignment: asked.append(assignment) or read(assignment)
                self.assertEqual(self.orphan_pass(client, manager, dialogs),
                                 {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0,
                                  "cancelled": 1})
                self.assertEqual(asked, [{"hostId": "host-test", "taskId": "task-1", "generation": 1,
                                          "instanceId": "instance-1", "producerId": "opencode",
                                          "capability": "cap-task-1", "adapterId": "opencode"}])
                self.assertEqual(self.resource(self.key), ("ReleasedAdopted", reason))
                self.assertEqual(client.closures, [("task-1", "ReleasedAdopted", reason, hashlib.sha256(
                    b'{"kind":"cancel","receipt":"cancel-1"}').hexdigest())])
                self.assertTrue(manager.can_take("instance-2"))
                self.assertEqual(manager.reserve(OperationKey("host-test", "task-2", 1, "instance-2"), "oc2",
                                                 "UserAdopted").state, "Reserved")
                self.assertEqual(self.orphan_pass(client, manager, dialogs)["closed"], 0)
                self.assertEqual((len(asked), len(client.closures)), (1, 1), "R was asked or told twice")
                self.assertEqual((dialogs, self.backend.stops), ([], []), "the release typed or stopped")
                self.assertEqual(len(self.backend.revokes), int(attached))
                self.assertIn("oc", self.backend.live, "the release ended the operator's session")

    def test_a_reservation_r_did_not_cancel_keeps_its_session(self):
        manager = self.orphan(attached=False)
        client, dialogs = self.cancelling_client({}), []
        for _ in range(2):
            self.assertEqual(self.orphan_pass(client, manager, dialogs)["cancelled"], 0)
        self.assertEqual((client.reads, client.closures, dialogs), (["task-1", "task-1"], [], []))
        self.assertEqual(self.resource(self.key), ("Reserved", ""))
        self.assertFalse(manager.can_take("instance-2"))

    def test_a_reservation_without_its_claim_is_never_closed(self):
        self.manager.reserve(self.key, "oc", "UserAdopted")
        manager = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        client, dialogs = self.cancelling_client({"task-1": "cancel-1"}), []
        self.assertEqual(self.orphan_pass(client, manager, dialogs)["cancelled"], 0)
        self.assertEqual((client.reads, client.closures), ([], []))
        self.assertEqual(self.resource(self.key), ("Reserved", ""))

    def test_a_full_host_never_asks_r_for_a_claim(self):
        class Client:
            host_id = "host-test"

            def __init__(self):
                self.claims = []

            def claim_host(self, adapter_id, instance_id):
                self.claims.append(instance_id)
                return None

        coverage = {"hostAdapterCoverage": {"host-test": {"opencode": "certified"}}}

        def claims(manager, instance_id):
            client = Client()
            self.assertIsNone(claim_cli_once(client, host=self.host, manager=manager, adapter_id="opencode",
                                             instance_id=instance_id, session="oc", workspace_root=self.tmp.name,
                                             deliver=lambda *_: None, coverage=coverage))
            return client.claims

        full = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        full.reserve(self.key, "oc", "UserAdopted")
        self.assertEqual(claims(full, "instance-2"), [], "R bound a task to a host with no room for it")
        self.assertEqual(claims(full, "instance-1"), ["instance-1"],
                         "the instance cannot replay the claim its unfinished operation came from")
        roomy = ResourceManager(self.host.spool, "host-test", self.backend, capacity=2)
        self.assertEqual(claims(roomy, "instance-2"), ["instance-2"])

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
            "import json,os,subprocess,sys,time\n"
            "from pathlib import Path\n"
            "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)',sys.argv[2]],"
            "start_new_session=True)\n"
            "start=subprocess.run(['ps','-o','lstart=','-p',str(child.pid)],capture_output=True,text=True,"
            "env={**os.environ,'TZ':'UTC','LC_ALL':'C'}).stdout.strip()\n"
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
            if child:
                command = subprocess.run(["ps", "-o", "command=", "-p", str(child["pid"])],
                                         capture_output=True, text=True).stdout
                if token in command:
                    os.kill(child["pid"], signal.SIGTERM)

    def test_resource_identity_survives_timezone_and_locale_shift(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-tzshift-{os.getpid()}"
        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)
        try:
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", "shifty", "/bin/sleep", "120").returncode, 0)
            with mock.patch.dict(os.environ, {"TZ": "America/Vancouver", "LANG": "en_CA.UTF-8"}):
                reserve_backend = TmuxBackend(tmux, socket)
                manager = ResourceManager(self.host.spool, "host-test", reserve_backend, capacity=2)
                held = manager.reserve(self.key, "shifty", "TaskCreated")
                self.assertTrue(manager.begin_launch(self.key).launch_now)
                reserve_backend.mark("shifty", held.nonce)
                self.assertEqual(manager.attach(self.key).state, "Running")
                saved = reserve_backend.observe("shifty")
            self.assertTrue(saved)
            with mock.patch.dict(os.environ, {"TZ": "UTC", "LANG": "en_US.UTF-8"}):
                close_backend = TmuxBackend(tmux, socket)
                self.assertEqual(close_backend.boot_id, reserve_backend.boot_id)
                self.assertEqual(close_backend.observe("shifty"), saved)
                restarted = ResourceManager(self.host.spool, "host-test", close_backend, capacity=2)
                view = restarted.close(self.key, {"kind": "cancel", "receipt": "tz-shift"})
            self.assertEqual(view.state, "CleanupPending")
            self.assertEqual(view.reason, "descendant absence unverified")
        finally:
            tmux_cmd("kill-server")

    def drift_host(self, before_boot, after_boot):
        """A TaskCreated and an adopted resource, each on a tmux server of the test's own, held under one
        boottime reading and closed by a host restarted under another. Returns each close's (state, reason)
        and whether each tmux session is still there."""
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        host = Host("host-test", Path(self.tmp.name) / f"drift-{before_boot}-{after_boot}")
        closed, alive = {}, {}
        for session, owner in (("made", "TaskCreated"), ("adopted", "UserAdopted")):
            socket = f"agent-work-boot-{os.getpid()}-{secrets.token_hex(3)}"

            def tmux_cmd(*args, socket=socket):
                return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

            self.addCleanup(tmux_cmd, "kill-server")
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", session, "/bin/sleep", "120").returncode, 0)
            key = OperationKey("host-test", f"task-{session}", 1, f"instance-{session}")
            before = ResourceManager(host.spool, "host-test", TmuxBackend(tmux, socket, before_boot), capacity=2)
            before.reserve(key, session, owner)
            self.assertTrue(before.begin_launch(key).launch_now)
            before.mark(key)
            self.assertEqual(before.attach(key).state, "Running")
            after = ResourceManager(host.spool, "host-test", TmuxBackend(tmux, socket, after_boot), capacity=2)
            view = after.close(key, {"kind": "cancel", "receipt": f"c-{session}"})
            closed[session] = (view.state, view.reason)
            alive[session] = tmux_cmd("has-session", "-t", f"={session}").returncode == 0
        return closed, alive

    def test_a_host_restarted_in_the_same_boot_keeps_its_resources_across_boottime_drift(self):
        for before_boot, after_boot in (("1790061849.260675", "1790061849.202788"),
                                        ("1790061849.999990", "1790061850.000020")):
            with self.subTest(f"{before_boot} then {after_boot}"):
                closed, alive = self.drift_host(before_boot, after_boot)
                self.assertEqual(closed, {"made": ("CleanupPending", "descendant absence unverified"),
                                          "adopted": ("ReleasedAdopted", "")})
                self.assertEqual(alive, {"made": False, "adopted": True})

    def test_a_real_reboot_is_still_told_apart_from_boottime_drift(self):
        closed, alive = self.drift_host("1790061849.260675", "1790150000.000001")
        self.assertEqual(closed, {"made": ("AbsenceVerified", ""),
                                  "adopted": ("CleanupPending", "adopted identity uncertain")})
        self.assertEqual(alive, {"made": True, "adopted": True}, "a reboot verdict stopped a session")

    def test_a_stopped_session_is_gone_while_another_session_shares_its_tmux_server(self):
        tmux = shutil.which("tmux")
        if not tmux:
            self.skipTest("tmux not installed")
        socket = f"agent-work-stop-{os.getpid()}-{secrets.token_hex(3)}"

        def tmux_cmd(*args):
            return subprocess.run([tmux, "-L", socket, *args], capture_output=True, text=True)

        self.addCleanup(tmux_cmd, "kill-server")
        for session in ("made", "neighbour"):
            self.assertEqual(tmux_cmd("new-session", "-d", "-s", session, "/bin/sleep", "120").returncode, 0)
        manager = ResourceManager(self.host.spool, "host-test", TmuxBackend(tmux, socket, "1790061849.260675"))
        manager.reserve(self.key, "made", "TaskCreated")
        self.assertTrue(manager.begin_launch(self.key).launch_now)
        manager.mark(self.key)
        self.assertEqual(manager.attach(self.key).state, "Running")
        view = manager.close(self.key, {"kind": "cancel", "receipt": "c-made"})
        self.assertEqual((view.state, view.reason), ("CleanupPending", "descendant absence unverified"))
        self.assertEqual({session: tmux_cmd("has-session", "-t", f"={session}").returncode
                          for session in ("made", "neighbour")}, {"made": 1, "neighbour": 0})

    def test_resource_close_legacy_boot_identity_stays_pending(self):
        self.backend.boot_id = "{ sec = 1790061849, usec = 36070 } Tue Sep 22 00:24:09 2026"
        held = self.manager.reserve(self.key, "legacy-boot", "TaskCreated")
        self.assertTrue(self.manager.begin_launch(self.key).launch_now)
        self.backend.launch("legacy-boot", held.nonce, 701)
        self.assertEqual(self.manager.attach(self.key).state, "Running")
        self.backend.boot_id = "00000000-0000-0000-0000-000000000002"
        view = self.manager.close(self.key, {"kind": "cancel", "receipt": "legacy-boot"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "boot identity unrecognized")

    def _adopted(self, key, session, pid):
        held = self.manager.reserve(key, session, "UserAdopted")
        self.assertTrue(self.manager.begin_launch(key).launch_now)
        self.backend.launch(session, held.nonce, pid)
        self.assertEqual(self.manager.attach(key).state, "Running")

    def test_resource_close_adopted_alive_pane_stays_pending(self):
        key = OperationKey("host-test", "task-gone", 1, "instance-alive")
        self._adopted(key, "adopted-alive", 711)
        self.backend.live.pop("adopted-alive")
        view = self.manager.close(key, {"kind": "cancel", "receipt": "alive-1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "adopted session unverifiable")
        self.assertEqual(self.backend.revokes, [])

    def test_resource_close_adopted_foreign_socket_stays_pending(self):
        key = OperationKey("host-test", "task-gone", 1, "instance-foreign")
        held = self.manager.reserve(key, "adopted-foreign", "UserAdopted")
        self.assertTrue(self.manager.begin_launch(key).launch_now)
        self.backend.launch("adopted-foreign", held.nonce, 712)
        self.backend.live["adopted-foreign"]["socket"] = "another-sock"
        self.assertEqual(self.manager.attach(key).state, "Running")
        self.backend.live.pop("adopted-foreign")
        self.backend.pane_gone_result = True
        view = self.manager.close(key, {"kind": "cancel", "receipt": "foreign-1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "adopted session unverifiable")
        self.assertEqual(self.backend.revokes, [])

    def test_resource_close_adopted_gone_positive_proof_releases(self):
        key = OperationKey("host-test", "task-gone", 1, "instance-gone")
        self._adopted(key, "adopted-gone", 713)
        self.backend.live.pop("adopted-gone")
        self.backend.pane_gone_result = True
        view = self.manager.close(key, {"kind": "cancel", "receipt": "gone-1"})
        self.assertEqual(view.state, "ReleasedAdopted")
        self.assertEqual(view.reason, "adopted session gone")
        self.assertEqual(self.backend.revokes, [])

    def test_resource_close_adopted_reused_pid_stays_pending(self):
        key = OperationKey("host-test", "task-gone", 1, "instance-reuse")
        self._adopted(key, "adopted-reuse", 714)
        self.backend.live.pop("adopted-reuse")
        view = self.manager.close(key, {"kind": "cancel", "receipt": "reuse-1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "adopted session unverifiable")
        self.assertEqual(self.backend.revokes, [])

    def pending_adopted(self, instance_id, pid):
        """An adopted resource a pass left CleanupPending with its result evidence: tmux was unreachable."""
        key = OperationKey("host-test", f"task-{instance_id}", 1, instance_id)
        self._adopted(key, "canario", pid)
        self.backend.offline = True
        self.assertEqual(self.manager.close(key, {"kind": "result", "receipt": "rcpt"}).state, "CleanupPending")
        self.backend.offline = False
        return key

    def resource(self, key):
        with self.host.spool.connection() as db:
            return tuple(db.execute("SELECT state, reason FROM resources WHERE operation_id=?",
                                    (operation_id(key),)).fetchone())

    def test_a_pending_adopted_session_that_still_carries_our_mark_is_not_released(self):
        key = self.pending_adopted("canario-2", 716)
        self.backend.live["canario"]["paneStart"] = "another-pane-birth"
        self.assertEqual(self.manager.retry_cleanup(), (0, []))
        self.assertEqual(self.resource(key), ("CleanupPending", "adopted identity uncertain"))
        self.assertEqual(self.backend.revokes, [])

    def test_an_adopted_session_the_host_cannot_attribute_stays_pending(self):
        key = self.pending_adopted("canario-2", 717)
        theirs = {**self.backend.live["canario"], "nonce": "f" * 32, "paneStart": "another-pane-birth"}
        for case, pane, socket, reason in (
                ("unobservable", None, "sock-test", "host unavailable"),
                ("another tmux server", {**theirs, "socket": "another-sock"}, "another-sock",
                 "adopted identity uncertain"),
                ("a mark that is no nonce", {**theirs, "nonce": "not-a-nonce"}, "sock-test",
                 "adopted identity uncertain")):
            with self.subTest(case):
                self.backend.offline = pane is None
                self.backend.socket = socket
                if pane is not None:
                    self.backend.live["canario"] = pane
                self.assertEqual(self.manager.retry_cleanup(), (0, []))
                self.assertEqual(self.resource(key), ("CleanupPending", reason))
        self.assertEqual(self.backend.revokes, [])

    def test_resource_close_adopted_ps_failure_stays_pending(self):
        key = OperationKey("host-test", "task-gone", 1, "instance-psfail")
        self._adopted(key, "adopted-psfail", 715)
        self.backend.live.pop("adopted-psfail")
        self.backend.pane_gone_error = OSError("ps read failed")
        view = self.manager.close(key, {"kind": "cancel", "receipt": "psfail-1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual(view.reason, "host unavailable")
        self.assertEqual(self.backend.revokes, [])

    def test_pane_gone_requires_rc1_with_silent_streams(self):
        backend = TmuxBackend("tmux", "sock-pscheck")
        survivor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            self.assertFalse(backend.pane_gone({"panePid": survivor.pid}))
        finally:
            survivor.kill()
            survivor.wait()
        self.assertTrue(backend.pane_gone({"panePid": survivor.pid}))
        self.assertFalse(backend.pane_gone({"panePid": "not-a-pid"}))
        self.assertFalse(backend.pane_gone({}))
        self.assertFalse(backend.pane_gone({"panePid": -1}))
        self.assertFalse(backend.pane_gone({"panePid": 99999999999}))
        self.assertFalse(backend.pane_gone({"panePid": 0}))

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
        gateway = root / "gateway-shim.py"
        gateway.write_text(
            "import os,sys\n"
            "with open(os.environ['FAKE_RESOURCE_LOG'],'a') as stream: stream.write('flush\\n')\n"
            "with open(os.environ['FAKE_GATEWAY_LOG'],'a') as stream: stream.write(' '.join(sys.argv[1:])+'\\n')\n"
            "calls=open(os.environ['FAKE_RESOURCE_LOG']).read().splitlines().count('flush')\n"
            "sys.exit(1 if str(calls) in os.environ.get('FAKE_FLUSH_FAIL','').split(',') else 0)\n"
        )
        env = dict(os.environ, CORRIDA_STATE=str(state), TMUX_BIN=str(tmux),
                   FAKE_TMUX_LOG=str(root / "tmux.log"), FAKE_RESOURCE_LOG=str(root / "resource.log"),
                   FAKE_GATEWAY_LOG=str(root / "gateway.log"), OPENCLAW_BIN="/fake/openclaw",
                   AGENT_WORK_HOST_STATE_DIR=str(root / "host"), AGENT_WORK_TMUX_SOCKET="isolated-test",
                   AGENT_WORK_RESOURCE_BIN=str(resource), AGENT_WORK_GATEWAY_BIN=str(gateway),
                   AGENT_WORK_EXPECT_URL="ws://127.0.0.1:18789")
        return root, reg, evidence, env

    def _unmanaged_shell(self):
        root, reg, evidence, env = self._managed_shell()
        reg.write_text(json.dumps({
            "id": "run-1", "estado": "abierta", "schema": "corrida.v2",
            "sesiones": [{"nombre": "libre-1"}],
            "lanes": [{"id": "lane-1", "session": "libre-1"}],
        }))
        return root, reg, env

    def _log_lines(self, path):
        return path.read_text().splitlines() if path.exists() else []

    def test_resource_close_managed_termination_flushes_results_before_and_after_the_close(self):
        root, reg, evidence, env = self._managed_shell()
        command = ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                   "run-1", "managed-1", "--evidence", str(evidence)]
        done = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self._log_lines(root / "resource.log"), ["flush", "AbsenceVerified", "flush"])
        flush = ("--flush-results --openclaw-bin /fake/openclaw --host-id host-test "
                 "--expect-url ws://127.0.0.1:18789 --host-state-dir " + str(root / "host"))
        self.assertEqual(self._log_lines(root / "gateway.log"), [flush, flush])
        self.assertIn("set-environment", (root / "tmux.log").read_text())

    def test_resource_close_flush_argv_is_accepted_by_the_real_gateway_cli(self):
        root, reg, evidence, env = self._managed_shell()
        env["AGENT_WORK_GATEWAY_BIN"] = str(ROOT / "scripts" / "agent-work" / "native_gateway.py")
        done = subprocess.run(["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                               "run-1", "managed-1", "--evidence", str(evidence)],
                              env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"), capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self._log_lines(root / "resource.log"), ["AbsenceVerified"])
        self.assertTrue((root / "host" / "host.sqlite").is_file())

    def test_resource_close_failed_flush_keeps_the_session_marked(self):
        root, reg, evidence, env = self._managed_shell()
        command = ["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                   "run-1", "managed-1", "--evidence", str(evidence)]
        before = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified",
                                                  FAKE_FLUSH_FAIL="1"), capture_output=True, text=True)
        self.assertNotEqual(before.returncode, 0)
        self.assertIn("resultados sin entregar a R; no se cierra", before.stderr)
        self.assertEqual(self._log_lines(root / "resource.log"), ["flush"])
        after = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified",
                                                 FAKE_FLUSH_FAIL="3"), capture_output=True, text=True)
        self.assertNotEqual(after.returncode, 0)
        self.assertIn("cerrado aqui, R sin avisar", after.stderr)
        self.assertEqual(self._log_lines(root / "resource.log"), ["flush", "flush", "AbsenceVerified", "flush"])
        self.assertNotIn("set-environment", "\n".join(self._log_lines(root / "tmux.log")))
        retried = subprocess.run(command, env=dict(env, FAKE_RESOURCE_STATE="AbsenceVerified"),
                                 capture_output=True, text=True)
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertIn("set-environment", (root / "tmux.log").read_text())

    def test_resource_close_unmanaged_termination_never_calls_the_gateway(self):
        root, reg, env = self._unmanaged_shell()
        done = subprocess.run(["bash", str(ROOT / "scripts" / "mac" / "corrida.sh"), "terminar-sesion",
                               "run-1", "libre-1"], env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "terminada libre-1\n")
        self.assertIn("set-environment", (root / "tmux.log").read_text())
        self.assertFalse((root / "resource.log").exists())
        self.assertFalse((root / "gateway.log").exists())

    def test_resource_close_cerrar_unmanaged_lane_never_calls_the_gateway(self):
        root, reg, env = self._unmanaged_shell()
        shell = ('. "' + str(ROOT / "scripts" / "mac" / "corrida" / "lib.sh") + '"; '
                 'AQUI="' + str(ROOT / "scripts" / "mac" / "corrida") + '"; '
                 '. "' + str(ROOT / "scripts" / "mac" / "corrida" / "cerrar.sh") + '"; '
                 'cerrar_archivar_lanes run-1 "' + str(reg) + '"')
        done = subprocess.run(["bash", "-c", shell], env=env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((root / "runs" / "run-1" / "archive" / "lane-1" / "transcript.txt").exists())
        self.assertFalse((root / "resource.log").exists())
        self.assertFalse((root / "gateway.log").exists())

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
                         ["flush", "CleanupPending", "flush", "AbsenceVerified", "flush"])

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
        "  502 4242     1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/python3 -c import time; time.sleep(30) b32nonce1\n"
        "  502 4243     1 Sat Oct  3 09:00:01 2026 /usr/libexec/remotemanagementd worker\n"
        "  502  515     1 Sat Oct  3 09:00:02 2026 /usr/libexec/xpcproxy com.apple.lsd\n"
    )
    AGENTES_PS_AFTER_TERM = (
        "  502 4243     1 Sat Oct  3 09:00:01 2026 /usr/libexec/remotemanagementd worker\n"
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
            ("ps-A-rc", lambda: CommandOutcome(1, "ps: nobody\n"),
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

    def test_resource_close_agentes_empty_account_reads_clear_and_launch_proceeds(self):
        # ps -A lists every user; a healthy empty agent account is output with
        # only foreign uid rows, and that must read as clear, not as failure.
        foreign_ps = (
            "  501  4021     1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/fake-cli run-1\n"
            "    0     1     0 Fri Jan  1 00:00:00 2026 /sbin/launchd\n"
        )
        shim, _log = self._tmux_shim()
        calls = []

        def runner(argv):
            calls.append(list(argv))
            if argv[:1] == ["ps"]:
                return CommandOutcome(1, "")
            if "/usr/bin/mktemp" in argv:
                return CommandOutcome(0, "/private/tmp/b32-ag-empty\n")
            return CommandOutcome(0, "")

        backend = AgentesBackend(str(shim), "ag-empty",
                                 ps_reader=lambda: CommandOutcome(0, foreign_ps),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=runner, grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-empty-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "AbsenceVerified")
        made = backend.launch("ag-empty-2", ["/opt/homebrew/bin/python3", "-c",
                                             "import time; time.sleep(30)", "b32n9"])
        self.assertEqual(made, "/private/tmp/b32-ag-empty")
        self.assertTrue(any("/usr/bin/mktemp" in call for call in calls))

    def test_resource_close_agentes_apple_label_on_user_binary_stays_signalable(self):
        # A live com.apple.* label pointing at an account-owned user binary is
        # forgeable text: the process stays present and signalable, and only a
        # real OS binary under the label is excluded.
        fake_label_ld = (
            "user/502 = {\n"
            "\tservices = {\n"
            "\t\t   4242   (pe) \tcom.apple.fake\n"
            "\t\t    515      - \tcom.apple.lsd\n"
            "\t}\n"
            "}\n"
        )
        calls = []
        backend = AgentesBackend("/usr/bin/true", "ag-fakelabel",
                                 ps_reader=lambda: CommandOutcome(
                                     0,
                                     "  502 4242     1 Sat Oct  3 09:00:00 2026 "
                                     "/opt/homebrew/bin/python3 -c import time; "
                                     "time.sleep(120) b32n10\n"),
                                 launchd_reader=lambda: CommandOutcome(0, fake_label_ld),
                                 runner=lambda argv: calls.append(list(argv))
                                 or (CommandOutcome(0, "Sat Oct  3 09:00:00 2026 "
                                                    "/opt/homebrew/bin/python3 -c import time; "
                                                    "time.sleep(120) b32n10\n")
                                     if argv[:1] == ["ps"] else CommandOutcome(0, "")),
                                 grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-fakelabel-1")
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending")
        self.assertEqual([call for call in calls if "/bin/kill" in call],
                         [self.KILL_ARGV_PREFIX + ["4242"]])

    def test_resource_close_agentes_lstart_change_skips_signal(self):
        ps_lstart_a = ("  502  700     1 Sat Oct  3 09:00:00 2026 "
                       "/opt/homebrew/bin/python3 -c import time; time.sleep(30) b32n4\n")
        ps_lstart_b = ("  502  700     1 Sun Nov  1 10:00:00 2026 "
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
        busy_ps = ("  502  999     1 Sat Oct  3 09:00:00 2026 "
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
        survivor_ps = ("  502 4242     1 Sat Oct  3 09:00:00 2026 "
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

    def test_resource_close_crash_between_reserve_and_launch_with_host_unreachable_keeps_capacity(self):
        # A11: the host died after reserving and does not answer; nothing frees the slot.
        self.manager.reserve(self.key, "worker-1", "TaskCreated")
        self.manager.begin_launch(self.key)
        self.backend.offline = True
        restarted = ResourceManager(self.host.spool, "host-test", self.backend, capacity=1)
        view = restarted.close(self.key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual((view.state, view.reason), ("CleanupPending", "host unavailable"))
        with self.assertRaisesRegex(ValueError, "capacity"):
            restarted.reserve(OperationKey("host-test", "replacement", 1, "instance-new"),
                              "replacement", "TaskCreated")

    def test_resource_close_hung_tmux_times_out_as_host_unavailable(self):
        # B4-37: a tmux client that never answers is an unreachable host, never a missing session.
        hung = Path(self.tmp.name) / "tmux-hung"
        hung.write_text("#!/bin/sh\nexec sleep 30\n")
        hung.chmod(0o700)
        backend = TmuxBackend(str(hung), "sock-hung", boot_id="1.000001", timeout=0.5)
        manager = ResourceManager(self.host.spool, "host-test", backend, capacity=1)
        manager.reserve(self.key, "worker-1", "UserAdopted")
        manager.begin_launch(self.key)
        started = time.monotonic()
        attached = manager.attach(self.key)
        closed = manager.close(self.key, {"kind": "cancel", "receipt": "c1"})
        self.assertLess(time.monotonic() - started, 5, "a hung tmux froze the host loop")
        self.assertEqual((attached.state, attached.reason), ("CleanupPending", "host unavailable"))
        self.assertEqual((closed.state, closed.reason), ("CleanupPending", "host unavailable"))
        self.assertFalse(manager.session_gone(self.key))
        with self.assertRaisesRegex(ValueError, "capacity"):
            manager.reserve(OperationKey("host-test", "replacement", 1, "instance-new"), "replacement", "TaskCreated")

    def test_resource_close_session_gone_with_a_surviving_descendant_still_holds(self):
        # A13: after a failed stop, a vanished session is not absence while a descendant lives.
        survivor = "  502 4242     1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/python3 -c x SURV\n"
        state = {"ps": "", "observe": "identity", "stop": False}
        backend = AgentesBackend("/usr/bin/true", "ag-stopfail2",
                                 ps_reader=lambda: CommandOutcome(0, state["ps"]),
                                 launchd_reader=lambda: CommandOutcome(0, self.AGENTES_LD),
                                 runner=lambda argv: CommandOutcome(0, ""), grace_seconds=0.2)
        manager, key = self._agentes_running(backend, "ag-stopfail2-1")
        identity = backend.observe("ag-stopfail2-1")
        backend.observe = lambda _session: identity if state["observe"] == "identity" else None
        backend.stop = lambda _identity: state["stop"]
        self.assertEqual(manager.close(key, {"kind": "cancel", "receipt": "c1"}).reason, "stop failed")
        state.update(stop=True, observe="gone", ps=survivor)
        view = manager.close(key, {"kind": "cancel", "receipt": "c1"})
        self.assertEqual(view.state, "CleanupPending", "the session vanished but a descendant survived")
        self.assertEqual(manager.counts()["active"], 1)
        state["ps"] = ""
        self.assertEqual(manager.close(key, {"kind": "cancel", "receipt": "c1"}).state, "AbsenceVerified")

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
        multiline_ps = ("  502 4242     1 Sat Oct  3 09:00:00 2026 /opt/homebrew/bin/python3 -c 'import os\n"
                        "  502  701     1 Sat Oct  3 09:00:00 2026 /bin/injected -c fake\n"
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
        "ready=sys.argv[2] if len(sys.argv) > 2 else None\n"
        "if os.fork()==0:\n"
        "    os.setsid()\n"
        "    if os.fork()==0:\n"
        "        os.closerange(0,3)\n"
        "        signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "        if ready:\n"
        "            open(ready, 'w').close()\n"
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
        done = subprocess.run(["ps", "-A", "-o", "uid=,pid=,ppid=,lstart=,command="],
                              capture_output=True, text=True)
        return parse_agent_ps(done.stdout) if done.returncode == 0 else ()

    def _registered_nonce(self, nonce):
        return {(row.pid, row.lstart) for row in self._agentes_rows() if nonce in row.command}

    def _kill_nonce(self, nonce, timeout=10.0):
        # Relee ps en cada vuelta: un nieto del doble fork puede nacer despues de la foto `registered`.
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rows = [row for row in self._agentes_rows() if nonce in row.command]
            if not rows:
                return True
            for row in rows:
                subprocess.run(LOCK_ARGV + ["sudo", "-n", "-u", AGENT_USER, "/bin/kill", "-KILL",
                                            str(row.pid)], capture_output=True)
            time.sleep(0.1)
        return False

    def test_resource_close_cleanup_kills_nonce_processes_born_after_the_snapshot(self):
        nonce = "b32-late-nonce"
        late = AgentProcess(4242, "Wed Oct  7 21:00:00 2026", f"/opt/homebrew/bin/python3 -c x {nonce}")
        other = AgentProcess(4343, "Wed Oct  7 21:00:00 2026", "/opt/homebrew/bin/python3 -c x otro")
        listings = iter([(late, other), (other,)])
        killed = []

        def run(argv, **kwargs):
            killed.append(argv[-1])
            return subprocess.CompletedProcess(argv, 0, "", "")

        with mock.patch.object(self, "_agentes_rows", side_effect=lambda: next(listings)), \
                mock.patch.object(subprocess, "run", side_effect=run):
            self.assertTrue(self._kill_nonce(nonce))
        self.assertEqual(killed, ["4242"])

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
            if nonce:
                self._kill_nonce(nonce)

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
            if nonce:
                self._kill_nonce(nonce)

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
            # The survivor ignores SIGTERM only once it says so: closing earlier kills it like any
            # other process, and the test found nothing (about 1 run in 5 failed that way).
            ready_dir = Path(tempfile.mkdtemp(prefix="ag-ignore-ready-", dir="/tmp"))  # agentes cannot reach $TMPDIR
            ready_dir.chmod(0o777)
            self.addCleanup(shutil.rmtree, ready_dir, True)
            ready = ready_dir / "ignoring"
            backend.launch("ag-ignore", ["/opt/homebrew/bin/python3", "-c",
                                         self.REAL_TERM_IGNORING_LAUNCHER, nonce, str(ready)])
            backend.mark("ag-ignore", nonce)
            deadline = time.monotonic() + 15
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertTrue(ready.exists(), "the survivor never started ignoring SIGTERM")
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
            if nonce:
                gone = self._kill_nonce(nonce)
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
                self._kill_nonce(nonce)
        pooled = ResourceManager(self.host.spool, "host-test", FakeBackend(), capacity=10)
        for number in range(10):
            pooled.reserve(OperationKey("host-test", f"b32ag-pool-{number}", 1,
                                        f"b32ag-pool-instance-{number}"),
                           f"b32agpool{number}", "IntentionalPool")
        self.assertEqual(manager.counts(), {"active": 10, "history": 100, "pool": 10})


class LegacyAdoptionTests(unittest.TestCase):
    """The two canary spools R still counted open on 2026-10-11, rebuilt on a tmux server of the test's own:
    an abandoned delivery R later cancelled (mac-local) and an acknowledged one left CleanupPending once a
    newer host marked the same pane (mac-local-b)."""

    SCREENS = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "opencode"
    SCREEN_CLI = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "screen-cli.py"
    FAKE_R = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "fake-r-host.py"

    def setUp(self):
        self.tmux_bin = shutil.which("tmux")
        if not self.tmux_bin:
            self.skipTest("tmux not installed")
        self.socket = f"agent-work-legacy-{os.getpid()}-{secrets.token_hex(3)}"
        self.addCleanup(self.tmux, "kill-server")
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-work-legacy-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.keys = self.root / "canario.keys"
        screen = str(self.SCREENS / "session-empty.ans")
        started = self.tmux("new-session", "-d", "-s", "canario", "-x", "160", "-y", "40", "--", sys.executable,
                            str(self.SCREEN_CLI), screen, screen, str(self.keys))
        self.assertEqual(started.returncode, 0, started.stderr)
        self.cli_pid = self.pane_field("pane_pid")
        self.backend = TmuxBackend(self.tmux_bin, self.socket)

    def tmux(self, *args):
        return subprocess.run([self.tmux_bin, "-L", self.socket, *args], capture_output=True, text=True)

    def pane_field(self, field):
        return self.tmux("display-message", "-p", "-t", "=canario:", "#{" + field + "}").stdout.strip()

    def adopt(self, host, instance_id, task_id, session="canario"):
        manager = ResourceManager(host.spool, "host-test", self.backend)
        key = OperationKey("host-test", task_id, 1, instance_id)
        manager.reserve(key, session, "UserAdopted")
        self.assertTrue(manager.begin_launch(key).launch_now)
        manager.mark(key)
        self.assertEqual(manager.attach(key).state, "Running")
        brief = self.root / "brief.txt"
        brief.write_text("revisa el cambio")
        operation = AuthorizedOperation(
            key=key, producer_id="opencode", capability=f"cap-{task_id}", session=session,
            workspace_ref=str(self.root), brief_ref=str(brief),
            brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40},
            result_contract="review.v1", claim_id=f"claim-{task_id}", adapter_id="opencode")
        return manager, key, operation

    def delivered(self, host, instance_id, task_id, session="canario"):
        manager, key, operation = self.adopt(host, instance_id, task_id, session)
        self.assertEqual(host.apply(key, operation, lambda *_: None, ResourceTests.admit).status, "typed")
        host.spool.delivered(operation_id(key))
        return key

    def close_only(self, spool_dir, state, log):
        """One closing pass over the spool, against the fake R of state: its report and whether it failed."""
        with mock.patch.dict(os.environ, {"FAKE_R_STATE": str(state), "FAKE_R_LOG": str(log)}):
            before = read_spool_resources(spool_dir)
            host = Host("host-test", spool_dir)
            return close_only(GatewayProjectionClient(str(self.FAKE_R), "host-test", "ws://127.0.0.1:1"), host=host,
                              manager=ResourceManager(host.spool, "host-test", self.backend), before=before)

    def test_a_closing_pass_reports_each_resource_as_the_spool_held_it_before_migrating(self):
        spool_dir = self.root / "pre-b9"
        host = Host("host-test", spool_dir)
        key = self.delivered(host, "canario-1", "task-a")
        with host.spool.connection() as db:
            db.execute("UPDATE operations SET status='abandoned' WHERE operation_id=?", (operation_id(key),))
            db.execute("PRAGMA user_version=0")
        state = self.root / "r-state.json"
        state.write_text(json.dumps({"cancellations": {}, "results": [], "closures": {}}))
        report, failed = self.close_only(spool_dir, state, self.root / "r-calls.jsonl")
        self.assertEqual([(r["before"], r["after"]) for r in report["resources"]],
                         [(["Running", ""], ["ReleasedAdopted", "delivery abandoned"])])
        self.assertEqual((failed, report["errors"]), (False, []))

    def acknowledged_then_unreachable(self, host, instance_id, task_id):
        """R acknowledged the result, and the pass that gave the session back found tmux unreachable."""
        manager, key, operation = self.adopt(host, instance_id, task_id)
        self.assertEqual(host.apply(key, operation, lambda *_: None, ResourceTests.admit).status, "typed")
        host.spool.delivered(operation_id(key))
        artifact = self.root / f"{task_id}.txt"
        artifact.write_text("aprobado")
        result = {"schema": "agent-work.result.v1", "kind": "produced", "hostId": "host-test", "taskId": task_id,
                  "generation": 1, "instanceId": instance_id, "producerId": "opencode",
                  "capability": f"cap-{task_id}", "observedRevision": operation.input_revision,
                  "typedPayload": {"verdict": "approved"}, "artifactRef": str(artifact),
                  "digest": hashlib.sha256(artifact.read_bytes()).hexdigest()}
        host.report("host-test", result)
        host.flush("host-test", lambda result, _: {
            **{field: result[field] for field in ("hostId", "taskId", "generation", "instanceId", "producerId")},
            "resultId": hashlib.sha256(canonical(result).encode()).hexdigest(), "receiptId": f"rcpt-{task_id}"})
        unreachable = ResourceManager(host.spool, "host-test",
                                      TmuxBackend(str(self.root / "no-tmux"), self.socket, self.backend.boot_id))
        self.assertEqual(unreachable.close(key, {"kind": "result", "receipt": f"rcpt-{task_id}"}).reason,
                         "host unavailable")
        return manager, key

    def state(self, host, key):
        with host.spool.connection() as db:
            return tuple(db.execute("SELECT state, reason FROM resources WHERE operation_id=?",
                                    (operation_id(key),)).fetchone())

    def test_a_pending_adopted_session_a_newer_host_marked_is_released_without_touching_the_pane(self):
        old = Host("host-test", self.root / "mac-local-b")
        manager, key = self.acknowledged_then_unreachable(old, "canario-2", "task-b")
        closures = []

        class Client:
            host_id = "host-test"

            def close_host(self, assignment, state, reason, _):
                closures.append((assignment["taskId"], state, reason))
                return {}

            def report_host_result(self, *_):
                raise AssertionError("the result was already acknowledged")

            def report_host_incident(self, *_):
                raise AssertionError("no incident was recorded")

            def list_pending(self, **_):
                return []

        old.flush_closures("host-test", Client().close_host)
        self.assertEqual(self.tmux("set-option", "-u", "-t", "=canario:", TmuxBackend.NONCE_OPTION).returncode, 0)
        newer = Host("host-test", self.root / "mac-local-c")
        newer_manager, newer_key, _ = self.adopt(newer, "canario-3", "task-c")
        newer_mark = newer_manager._row(newer_key)["nonce"]

        def one_pass():
            return pump_once(Client(), host=old, evidence_root=self.tmp.name, progress_state_dir=self.tmp.name,
                             progress_client="unused", cli_release=manager.release_acknowledged,
                             cli_retry=manager.retry_cleanup)

        self.assertEqual(one_pass(), {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0,
                                      "released": 0, "recovered": 1})
        self.assertEqual(self.state(old, key), ("ReleasedAdopted", "adopted mark superseded"))
        self.assertEqual(closures, [("task-b", "CleanupPending", "host unavailable"),
                                    ("task-b", "ReleasedAdopted", "adopted mark superseded")])
        self.assertEqual(one_pass()["closed"], 0)
        self.assertEqual(len(closures), 2, "R got the terminal closure twice")
        time.sleep(0.3)
        self.assertEqual(self.keys.read_text() if self.keys.exists() else "", "", "a key reached the pane")
        self.assertEqual((self.pane_field(TmuxBackend.NONCE_OPTION), self.pane_field("pane_pid")),
                         (newer_mark, self.cli_pid), "the release touched the newer host's pane")
        self.assertEqual(self.state(newer, newer_key), ("Running", ""))

    def test_a_pending_adopted_session_whose_mark_was_cleared_is_released_without_touching_the_pane(self):
        old = Host("host-test", self.root / "mac-local-b")
        manager, key = self.acknowledged_then_unreachable(old, "canario-2", "task-b")
        closures = []

        class Client:
            host_id = "host-test"

            def close_host(self, assignment, state, reason, _):
                closures.append((assignment["taskId"], state, reason))
                return {}

            def report_host_result(self, *_):
                raise AssertionError("the result was already acknowledged")

            def report_host_incident(self, *_):
                raise AssertionError("no incident was recorded")

            def list_pending(self, **_):
                return []

        old.flush_closures("host-test", Client().close_host)
        self.assertEqual(self.tmux("set-option", "-u", "-t", "=canario:", TmuxBackend.NONCE_OPTION).returncode, 0)
        revokes = []
        revoke = self.backend.revoke
        self.backend.revoke = lambda identity: revokes.append(identity) or revoke(identity)

        def one_pass():
            return pump_once(Client(), host=old, evidence_root=self.tmp.name, progress_state_dir=self.tmp.name,
                             progress_client="unused", cli_release=manager.release_acknowledged,
                             cli_retry=manager.retry_cleanup)

        self.assertEqual(one_pass(), {"reported": 0, "transferred": 0, "published": 0, "closed": 1, "incidents": 0,
                                      "released": 0, "recovered": 1})
        self.assertEqual(self.state(old, key), ("ReleasedAdopted", "adopted mark cleared"))
        self.assertEqual(closures, [("task-b", "CleanupPending", "host unavailable"),
                                    ("task-b", "ReleasedAdopted", "adopted mark cleared")])
        self.assertEqual(one_pass()["closed"], 0)
        self.assertEqual((len(closures), revokes), (2, []), "R got the closure twice, or the host revoked a mark")
        time.sleep(0.3)
        self.assertEqual(self.keys.read_text() if self.keys.exists() else "", "", "a key reached the pane")
        self.assertEqual((self.pane_field(TmuxBackend.NONCE_OPTION), self.pane_field("pane_pid")),
                         ("", self.cli_pid), "the release touched the operator's pane")

    def test_a_closing_pass_fails_while_r_refuses_a_closure(self):
        spool_dir = self.root / "refused"
        host = Host("host-test", spool_dir)
        _, key = self.acknowledged_then_unreachable(host, "canario-2", "task-b")
        state = self.root / "r-state.json"
        state.write_text(json.dumps({"cancellations": {}, "results": [], "closures": {}}))
        report, failed = self.close_only(spool_dir, state, self.root / "r-calls.jsonl")
        self.assertEqual(report["errors"], [
            f"{operation_id(key)}: native projection Gateway rejected request managedTasks.host.close: "
            "Managed host closure requires a final result or cancellation"])
        self.assertEqual((failed, report["rClosures"]), (True, []))

    def test_a_closing_pass_closes_both_legacy_spools_once_and_asks_r_for_no_work(self):
        spool_dir = self.root / "legacy"
        host = Host("host-test", spool_dir)
        manager, abandoned, operation = self.adopt(host, "canario-1", "task-a")

        def lost(*_):
            raise RuntimeError("the keys may have reached the pane")

        self.assertEqual(host.apply(abandoned, operation, lost, ResourceTests.admit).status, "uncertain")
        host.resolve_delivery("host-test", abandoned, "abandoned", "un diálogo se comió la referencia")
        _, pending = self.acknowledged_then_unreachable(host, "canario-2", "task-b")
        newer_mark = secrets.token_hex(16)
        self.assertEqual(self.tmux("set-option", "-t", "=canario:", TmuxBackend.NONCE_OPTION, newer_mark).returncode,
                         0)
        state, log = self.root / "r-state.json", self.root / "r-calls.jsonl"
        state.write_text(json.dumps({"cancellations": {"task-a": "cancel-a"}, "results": ["task-b"],
                                     "closures": {}}))
        report, failed = self.close_only(spool_dir, state, log)
        self.assertFalse(failed, report["errors"])
        again, failed_again = self.close_only(spool_dir, state, log)
        self.assertFalse(failed_again, again["errors"])
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        methods = [call["method"] for call in calls]
        cancel_digest = hashlib.sha256(b'{"kind":"cancel","receipt":"cancel-a"}').hexdigest()
        result_digest = hashlib.sha256(b'{"kind":"result","receipt":"rcpt-task-b"}').hexdigest()
        self.assertEqual(sorted((call["params"]["capability"]["taskId"], call["params"]["instanceId"],
                                 call["params"]["state"], call["params"]["reason"], call["params"]["evidenceDigest"])
                                for call in calls if call["method"] == "managedTasks.host.close"),
                         [("task-a", "canario-1", "ReleasedAdopted", "delivery abandoned", cancel_digest),
                          ("task-b", "canario-2", "ReleasedAdopted", "adopted mark superseded", result_digest)])
        self.assertEqual(set(methods), {"managedTasks.host.cancellation", "managedTasks.host.close"})
        self.assertEqual(sorted((r["taskId"], r["state"]) for r in report["rClosures"]),
                         [("task-a", "ReleasedAdopted"), ("task-b", "ReleasedAdopted")])
        self.assertEqual(sorted((r["taskId"], r["before"][0], r["after"][0]) for r in report["resources"]),
                         [("task-a", "ReleasedAdopted", "ReleasedAdopted"),
                          ("task-b", "CleanupPending", "ReleasedAdopted")])
        self.assertEqual(again["rClosures"], [], "a second pass sent the closures again")
        self.assertEqual(self.state(host, pending), ("ReleasedAdopted", "adopted mark superseded"))
        time.sleep(0.3)
        self.assertEqual(self.keys.read_text() if self.keys.exists() else "", "", "a key reached the pane")
        self.assertEqual((self.pane_field(TmuxBackend.NONCE_OPTION), self.pane_field("pane_pid")),
                         (newer_mark, self.cli_pid))


class PermissionDialogTests(unittest.TestCase):
    """opencode 1.18.35 screens captured 2026-10-11, painted in panes of a tmux server of the test's own."""

    SCREENS = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "opencode"
    SCREEN_CLI = ROOT / "scripts" / "tests" / "fixtures" / "agent-work" / "screen-cli.py"

    def setUp(self):
        self.tmux_bin = shutil.which("tmux")
        if not self.tmux_bin:
            self.skipTest("tmux not installed")
        self.socket = f"agent-work-dialog-{os.getpid()}-{secrets.token_hex(3)}"
        self.addCleanup(self.tmux, "kill-server")
        self.tmp = tempfile.TemporaryDirectory(prefix="agent-work-dialog-")
        self.addCleanup(self.tmp.cleanup)
        self.backend = TmuxBackend(self.tmux_bin, self.socket)
        self.adapter = cli_adapter("opencode")

    def tmux(self, *args):
        return subprocess.run([self.tmux_bin, "-L", self.socket, *args], capture_output=True, text=True)

    def pane(self, session, screen, after="permission-rejected", mark=None):
        log = Path(self.tmp.name) / f"{session}.keys"
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", line) for name in (screen, after)
                 for line in (self.SCREENS / f"{name}.ans").read_text().rstrip("\n").split("\n")]
        width = str(max(len(line) for line in lines) + 2)
        height = str(max(len((self.SCREENS / f"{name}.ans").read_text().rstrip("\n").split("\n"))
                         for name in (screen, after)))
        started = self.tmux("new-session", "-d", "-s", session, "-x", width, "-y", height, "--", sys.executable,
                            str(self.SCREEN_CLI), str(self.SCREENS / f"{screen}.ans"),
                            str(self.SCREENS / f"{after}.ans"), str(log))
        self.assertEqual(started.returncode, 0, started.stderr)
        if mark is None:
            self.backend.mark(session, f"nonce-{session}")
        else:
            mark()
        identity = self.backend.observe(session)
        deadline, shown = time.monotonic() + 5, None
        while time.monotonic() < deadline:
            time.sleep(0.05)
            screen = self.backend.capture(identity) or ""
            if screen.strip() and screen == shown:
                break
            shown = screen
        return identity, log

    def keys(self, log):
        time.sleep(0.5)
        return log.read_text() if log.exists() else ""

    def test_a_cancelled_task_denies_the_permission_dialog_and_leaves_an_empty_composer(self):
        identity, log = self.pane("oc", "permission-dialog")
        self.assertEqual(reject_permission_dialog(self.backend, identity, self.adapter), "rejected")
        self.assertEqual(self.keys(log), "Escape\n", "the dialog got an answer other than a denial")
        self.assertEqual(read_composer(self.backend.capture(identity), "opencode", self.adapter.placeholders),
                         ("VACIO", ""))
        self.assertEqual(self.backend.observe("oc"), identity, "denying the dialog touched the session")

    def test_a_pane_without_the_permission_dialog_is_left_untouched(self):
        for session, screen, outcome in (("empty", "session-empty", "none"), ("draft", "session-draft", "none"),
                                         ("update", "update-dialog", "left: opencode dialog open")):
            identity, log = self.pane(session, screen)
            self.assertEqual(reject_permission_dialog(self.backend, identity, self.adapter), outcome, screen)
            self.assertEqual(self.keys(log), "", f"a key reached the {screen} pane")
        identity, log = self.pane("moved", "permission-dialog")
        self.assertEqual(reject_permission_dialog(self.backend, {**identity, "nonce": "another-resource"},
                                                  self.adapter), "left: pane unverifiable")
        self.assertEqual(self.keys(log), "", "a key reached a pane the host no longer holds")

    def test_a_cancelled_task_whose_dialog_outlives_the_esc_keeps_its_mark_until_the_last_attempt(self):
        host = Host("host-test", Path(self.tmp.name) / "host")
        manager = ResourceManager(host.spool, "host-test", self.backend)
        key = OperationKey("host-test", "task-1", 1, "instance-1")
        manager.reserve(key, "stuck", "UserAdopted")
        self.assertTrue(manager.begin_launch(key).launch_now)
        _, log = self.pane("stuck", "permission-dialog", "permission-dialog", mark=lambda: manager.mark(key))
        self.assertEqual(manager.attach(key).state, "Running")
        nonce = manager._row(key)["nonce"]
        brief = Path(self.tmp.name) / "brief.txt"
        brief.write_text("revisa el cambio")
        operation = AuthorizedOperation(
            key=key, producer_id="opencode", capability="cap-task-1", session="stuck", workspace_ref=self.tmp.name,
            brief_ref=str(brief), brief_digest=hashlib.sha256(brief.read_bytes()).hexdigest(),
            input_revision={"kind": "code", "repository": "repo", "sha": "a" * 40}, result_contract="review.v1",
            claim_id="claim-task-1", adapter_id="opencode")
        self.assertEqual(host.apply(key, operation, lambda *_: None, ResourceTests.admit).status, "typed")
        host.spool.delivered(operation_id(key))

        def reject(identity):
            return reject_permission_dialog(self.backend, identity, self.adapter, settle_seconds=0.1,
                                            wait_seconds=0.5)

        still = (f"{operation_id(key)}: cancelled; permission dialog left: permission dialog visible but Esc did "
                 "not close it")
        passes = []
        for _ in range(4):
            outcome = manager.release_cancelled(lambda _: "cancel-1", reject)
            mark = self.tmux("display-message", "-p", "-t", "=stuck:", "#{" + TmuxBackend.NONCE_OPTION + "}")
            passes.append((outcome, mark.stdout.strip(), self.keys(log).count("Escape")))
        self.assertEqual(passes, [
            ((0, [f"{still}, attempt 1 of 3; the session stays held"]), nonce, 1),
            ((0, [f"{still}, attempt 2 of 3; the session stays held"]), nonce, 2),
            ((1, [f"{still} after 3 attempts"]), "", 3),
            ((0, []), "", 3)])
        self.assertEqual(self.keys(log), "Escape\nEscape\nEscape\n", "the dialog got an answer other than a denial")

    def test_an_esc_that_leaves_the_dialog_on_screen_is_told_apart_from_a_composer_that_did_not_empty(self):
        for session, after, outcome in (
                ("stuck", "permission-dialog", "left: permission dialog visible but Esc did not close it"),
                ("drafted", "session-draft", "left: no empty composer after the reject key")):
            identity, log = self.pane(session, "permission-dialog", after)
            self.assertEqual(reject_permission_dialog(self.backend, identity, self.adapter), outcome, after)
            self.assertEqual(self.keys(log), "Escape\n", f"the {after} pane got other keys")

if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""cli_silent_failure: each silent failure of main's adopted CLI is one incident and one wake.

The R Gateway runs in the main_cli_loop harness with its counting model provider. The CLI is
a double inside a real tmux pane on a private server. The pump, the detector, the tmux backend
and the transport are the ones native_gateway.main wires for --watch with a CLI route.
"""

import faulthandler
import hashlib
import os
from pathlib import Path
import secrets
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
sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts import OperationKey, operation_id  # noqa: E402
from host import Host, TmuxTransport  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once, watch_pump  # noqa: E402
from resources import ResourceManager, TmuxBackend, load_approval_pattern  # noqa: E402
from routing import prepare_request  # noqa: E402
from spool import canonical  # noqa: E402
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    ADAPTER, HOST_ID, LOOP_SESSION, LoopGateway, built_runtime, certified_coverage, loop_route,
    wait_for)

SILENT_CLI = ROOT / "scripts/tests/fixtures/agent-work/silent-cli.py"
LIB_SH = ROOT / "scripts/mac/corrida/lib.sh"
PUMP_INTERVAL = 0.5
DEADLINE_SECONDS = 6.0
IDLE_PASSES = 5
# SilentPromptTest.PROCEED_ID: identity of the measured claude dialog the double paints.
PROCEED_ID = "prompt-7d94515e70c2994a231d611d9a75feb4b34c8c89d290da292dc115ae5ac52ff3"
# A hung Gateway, pump or pane must fail the run, never stall it.
RUN_LIMIT_SECONDS = 900


class TmuxCli:
    """The CLI double on its own tmux server, started without the user's tmux config."""

    session = "silent-cli"

    def __init__(self, cause):
        self.tmux = shutil.which("tmux")
        self.socket = f"agent-work-silent-{os.getpid()}-{secrets.token_hex(4)}"
        self.socket_file = (Path(os.environ.get("TMUX_TMPDIR") or "/tmp")
                            / f"tmux-{os.getuid()}" / self.socket)
        started = self._tmux("new-session", "-d", "-s", self.session, "-x", "200", "-y", "50",
                             sys.executable, "-u", str(SILENT_CLI), cause)
        if started.returncode:
            raise RuntimeError("tmux could not start the CLI double: " + started.stderr)
        if not wait_for(lambda: "silent-cli ready" in self.screen(), 15):
            self.close()
            raise RuntimeError("the CLI double never painted its prompt")

    def _tmux(self, *args):
        return subprocess.run([self.tmux, "-f", "/dev/null", "-L", self.socket, *args],
                              capture_output=True, text=True)

    def screen(self):
        return self._tmux("capture-pane", "-p", "-t", f"={self.session}:").stdout

    def close(self):
        self._tmux("kill-server")
        if self.socket_file.exists():
            self.socket_file.unlink()


class CountingClient(GatewayProjectionClient):
    """The real Gateway client; it also keeps every incident RPC the pump attempts."""

    def __init__(self, *args):
        super().__init__(*args)
        self.incident_reports = []

    def report_host_incident(self, assignment, incident):
        self.incident_reports.append(incident)
        return super().report_host_incident(assignment, incident)


class Pump:
    """watch_pump in a thread, as native_gateway.main runs it with --watch."""

    def __init__(self, client, host, root, cli_watch):
        self.stop_event = threading.Event()
        self.error = None

        def run():
            try:
                watch_pump(client, host=host, evidence_root=str(root / "evidence"),
                           progress_state_dir=str(root / "progress"),
                           progress_client=str(root / "progress-client-unused"),
                           stop_event=self.stop_event, interval=PUMP_INTERVAL, cli_watch=cli_watch)
            except BaseException as exc:  # a dead pump must fail the case, not hide in a thread
                self.error = exc

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=60)
        return not self.thread.is_alive()


def incident_rows(host):
    with host.spool.connection() as db:
        return [(row["task_id"], row["incident_key"], row["status"], row["incident_json"])
                for row in db.execute("SELECT * FROM incidents ORDER BY task_id, incident_key")]


class CliSilentFailureE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = built_runtime(unittest.TestCase())
        if not shutil.which("tmux"):
            raise AssertionError("cli_silent_failure runs the CLI double in a real tmux pane")
        temporary = tempfile.TemporaryDirectory(prefix="agent-work-cli-silent-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        cls.gateway = LoopGateway(cls.runtime, cls.root)
        cls.addClassCleanup(cls.gateway.close)
        _, cls.certified = certified_coverage()
        cls.approval = load_approval_pattern(LIB_SH)

    def silent_case(self, cause, incident_id, *, deadline):
        """Submit from main's loop session, deliver to the double, then watch it with the pump."""
        gateway = self.gateway
        root = self.root / cause
        root.mkdir()
        cli = TmuxCli(cause)
        self.addCleanup(cli.close)
        host = Host(HOST_ID, root / "host")
        manager = ResourceManager(host.spool, HOST_ID, TmuxBackend(cli.tmux, cli.socket))
        client = CountingClient(str(self.runtime / "openclaw.mjs"), HOST_ID, gateway.url)
        route = dict(loop_route(root, gateway.state_dir), key=f"encargos-loop-{cause}")
        request = prepare_request(coverage=self.certified, **route)
        instance = f"silent-{cause}"
        with mock.patch.dict(os.environ, gateway.env):
            start = len(gateway.provider_requests())
            queued_before = {row["id"] for row in gateway.call("deliveries")}

            def new_queue_rows():
                # A settled row keeps its id but loses its session and context to a tombstone.
                return [(row["id"], row["status"]) for row in gateway.call("deliveries")
                        if row["id"] not in queued_before]

            task_id = gateway.tool("submit", request, f"{cause}-submit-turn")["taskId"]
            context_key = f"task:{task_id}"
            gateway.tool("admit", {"taskId": task_id, "admissionKey": f"{cause}-attempt"},
                         f"{cause}-admit-turn")
            observed = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                      instance_id=instance, session=cli.session,
                                      workspace_root=root / "workspace",
                                      deliver=TmuxTransport(cli.tmux, cli.socket).deliver,
                                      coverage=self.certified)
            # Typing is not delivery: the double's own acceptance is (cli_delivery_acceptance).
            self.assertIn(observed.status, ("typed", "delivered"))
            key = OperationKey(HOST_ID, task_id, 1, instance)
            op_id = operation_id(key)
            self.assertTrue(wait_for(lambda: host.take_acceptance(HOST_ID, key), 15),
                            f"the CLI double never accepted; screen={cli.screen()!r}")
            delivered_at = host.spool.delivered_at(op_id)
            incident = {"kind": cause, **incident_id, "evidenceRef": f"host-operation:{op_id}"}
            incident_key = f"host:1:{cause}:{next(iter(incident_id.values()))}"
            wake_id = hashlib.sha256(
                f"managed-task-incident:{task_id}:1:{incident_key}".encode()).hexdigest()

            passes = []

            def cli_watch():
                # The cli_watch of native_gateway.main, recording each pass and its clock.
                now = time.time()
                found = host.detect_silent_failures(
                    HOST_ID, manager.session_gone, now=now, deadline_seconds=deadline,
                    prompt_identity=lambda key: manager.prompt_identity(key, self.approval))
                passes.append((now, found))
                return found

            pump = Pump(client, host, root, cli_watch)
            try:
                recorded = wait_for(lambda: incident_rows(host), 40)
                self.assertTrue(recorded, f"no durable incident; passes={passes} "
                                          f"pump_error={pump.error} screen={cli.screen()!r}")
                settled = wait_for(lambda: [row for row in new_queue_rows() if row[1] != "pending"], 30)
                self.assertTrue(settled, f"the incident never woke the requester; queue={new_queue_rows()}")
                wakes = wait_for(lambda: gateway.provider_requests()[start:], 15)
                self.assertTrue(wakes, "the settled wake never reached the model provider")
                wake_pass = len(passes)
                # Keep watching: the closed session, the dialog, the invalid report or the missed
                # deadline is still there, and the pump must not turn it into another wake.
                quiet = wait_for(lambda: len(passes) >= wake_pass + IDLE_PASSES and (
                    deadline is None or sum(now >= delivered_at + deadline for now, _ in passes) >= 2), 60)
                self.assertTrue(quiet, f"the pump stopped watching after the wake; passes={passes}")
            finally:
                self.assertTrue(pump.stop(), "the pump did not stop")
            self.assertIsNone(pump.error)
            # The same failure an hour and a day later is still the same incident: nothing new.
            for later in (3600, 86400):
                late = host.detect_silent_failures(
                    HOST_ID, manager.session_gone, now=time.time() + later, deadline_seconds=deadline,
                    prompt_identity=lambda key: manager.prompt_identity(key, self.approval))
                self.assertEqual(late, [], f"a pass {later}s later raised {late}")

            after = gateway.provider_requests()[start:]
            self.assertEqual(len(after), 1, f"the incident woke a model {len(after)} times")
            self.assertEqual(new_queue_rows(), [(wake_id, "completed")])
            # The model was told this task's incident and its cause.
            self.assertIn({"taskId": task_id, "kind": cause}, after[0].get("incidentWakes", []))
            # The turn ran with this task's wake in flight toward the session that submitted it.
            in_flight = [row for row in after[0]["startedDeliveries"] if row["contextKey"] == context_key]
            self.assertEqual([row["sessionKey"] for row in in_flight], [LOOP_SESSION])
            self.assertEqual(gateway.call("sessions"), [LOOP_SESSION])
            self.assertEqual([key for _, found in passes for key in found], [incident_key])
            self.assertEqual(client.incident_reports, [incident], "the pump sent the incident again")
            self.assertEqual(incident_rows(host), [(task_id, incident_key, "sent", canonical(incident))])
            snapshot = gateway.tool("inspect", {"taskId": task_id}, f"{cause}-inspect-turn")
            self.assertEqual(snapshot["incidents"], [incident])
            self.assertIsNone(snapshot["result"])
            idle = len(passes) - wake_pass
            latency = (after[0]["at"] - in_flight[0]["enqueuedAt"]) / 1000
            print(f"CLI_SILENT_FAILURE_E2E cause={cause} incident={incident_key} "
                  f"detections={len([key for _, found in passes for key in found])} "
                  f"incident_rpcs={len(client.incident_reports)} wake_requests={len(after)} "
                  f"wake_latency_s={latency:.2f} passes={len(passes)} idle_passes_after_wake={idle} "
                  f"session={LOOP_SESSION} deadline_s={deadline}", flush=True)
            return passes, delivered_at

    def test_closed_session_without_report(self):
        self.silent_case("transport-unavailable", {"episodeId": "session-closed"},
                         deadline=DEADLINE_SECONDS)

    def test_permission_dialog(self):
        # No deadline here: a dialog and a missed deadline are two incidents by design
        # (SilentPromptTest.test_dialog_and_deadline_are_two_incidents).
        self.silent_case("permission-required", {"promptIdentity": PROCEED_ID + "-1"}, deadline=None)

    def test_deadline_missed(self):
        passes, delivered_at = self.silent_case("deadline-missed", {"episodeId": "deadline"},
                                                deadline=DEADLINE_SECONDS)
        early = [found for now, found in passes if now < delivered_at + DEADLINE_SECONDS]
        self.assertGreaterEqual(len(early), 2, "the pump never watched before the deadline")
        self.assertEqual([key for found in early for key in found], [])

    def test_invalid_report(self):
        self.silent_case("invalid-result", {"episodeId": "invalid-result"}, deadline=DEADLINE_SECONDS)


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

#!/usr/bin/env python3
"""cli_delivery_acceptance: typing a reference or seeing it on screen is not a delivery.

The R Gateway runs in the main_cli_loop harness with its counting model provider. The CLI is
a double inside a real tmux pane on a private server that never accepts what it is given. The
pump runs both CLI hooks native_gateway.main wires for --watch: the claim, replayed on every
pass, and the detector.
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
from native_gateway import claim_cli_once, watch_pump  # noqa: E402
from resources import ResourceManager, TmuxBackend, load_approval_pattern  # noqa: E402
from routing import prepare_request  # noqa: E402
from spool import canonical  # noqa: E402
from test_agent_work_cli_silent_failure_e2e import CountingClient, incident_rows  # noqa: E402
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    ADAPTER, HOST_ID, LOOP_SESSION, LoopGateway, built_runtime, certified_coverage, loop_route,
    wait_for)

DELIVERY_CLI = ROOT / "scripts/tests/fixtures/agent-work/delivery-cli.py"
LIB_SH = ROOT / "scripts/mac/corrida/lib.sh"
PUMP_INTERVAL = 0.5
DEADLINE_SECONDS = 12.0
IDLE_PASSES = 5
UNACCEPTED = {"kind": "transport-unavailable", "episodeId": "delivery-unaccepted"}
INCIDENT_KEY = "host:1:transport-unavailable:delivery-unaccepted"
# A hung Gateway, pump or pane must fail the run, never stall it.
RUN_LIMIT_SECONDS = 600


class TmuxCli:
    """The CLI double on its own tmux server, started without the user's tmux config."""

    session = "delivery-cli"

    def __init__(self, mode, received):
        self.tmux = shutil.which("tmux")
        self.received = received
        self.socket = f"agent-work-delivery-{os.getpid()}-{secrets.token_hex(4)}"
        self.socket_file = (Path(os.environ.get("TMUX_TMPDIR") or "/tmp")
                            / f"tmux-{os.getuid()}" / self.socket)
        started = self._tmux("new-session", "-d", "-s", self.session, "-x", "200", "-y", "50",
                             "-e", f"DELIVERY_CLI_RECEIVED={received}",
                             sys.executable, "-u", str(DELIVERY_CLI), mode)
        if started.returncode:
            raise RuntimeError("tmux could not start the CLI double: " + started.stderr)
        if not wait_for(lambda: "delivery-cli ready" in self.screen(), 15):
            self.close()
            raise RuntimeError("the CLI double never painted its prompt")

    def _tmux(self, *args):
        return subprocess.run([self.tmux, "-f", "/dev/null", "-L", self.socket, *args],
                              capture_output=True, text=True)

    def screen(self):
        # -J joins wrapped lines, so a long typed reference reads as one line.
        return self._tmux("capture-pane", "-p", "-J", "-t", f"={self.session}:").stdout

    def close(self):
        self._tmux("kill-server")
        if self.socket_file.exists():
            self.socket_file.unlink()


class Pump:
    """watch_pump in a thread with both CLI hooks, as native_gateway.main runs it with --watch."""

    def __init__(self, client, host, root, cli_claim, cli_watch):
        self.stop_event = threading.Event()
        self.error = None

        def run():
            try:
                watch_pump(client, host=host, evidence_root=str(root / "evidence"),
                           progress_state_dir=str(root / "progress"),
                           progress_client=str(root / "progress-client-unused"),
                           stop_event=self.stop_event, interval=PUMP_INTERVAL,
                           cli_claim=cli_claim, cli_watch=cli_watch)
            except BaseException as exc:  # a dead pump must fail the case, not hide in a thread
                self.error = exc

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=60)
        return not self.thread.is_alive()


class CliDeliveryAcceptanceE2E(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = built_runtime(unittest.TestCase())
        if not shutil.which("tmux"):
            raise AssertionError("cli_delivery_acceptance runs the CLI double in a real tmux pane")
        temporary = tempfile.TemporaryDirectory(prefix="agent-work-cli-delivery-")
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        cls.gateway = LoopGateway(cls.runtime, cls.root)
        cls.addClassCleanup(cls.gateway.close)
        _, cls.certified = certified_coverage()
        cls.approval = load_approval_pattern(LIB_SH)

    def unaccepted_case(self, mode):
        """Submit from main's loop session, type the reference once, and let the pump judge it."""
        gateway = self.gateway
        root = self.root / mode
        root.mkdir()
        cli = TmuxCli(mode, root / "pane-input.log")
        self.addCleanup(cli.close)
        host = Host(HOST_ID, root / "host")
        manager = ResourceManager(host.spool, HOST_ID, TmuxBackend(cli.tmux, cli.socket))
        client = CountingClient(str(self.runtime / "openclaw.mjs"), HOST_ID, gateway.url)
        route = dict(loop_route(root, gateway.state_dir), key=f"encargos-loop-{mode}")
        request = prepare_request(coverage=self.certified, **route)
        instance = f"delivery-{mode}"
        transport = TmuxTransport(cli.tmux, cli.socket)
        typed = []

        def deliver(assignment_ref, session):
            # The real tmux transport, counted: the text reaches the pane every time.
            typed.append(assignment_ref)
            transport.deliver(assignment_ref, session)

        claims = []

        def cli_claim():
            # The cli_claim of native_gateway.main, recording what each replay observed.
            observed = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                      instance_id=instance, session=cli.session,
                                      workspace_root=root / "workspace", deliver=deliver,
                                      coverage=self.certified)
            claims.append(observed.status if observed else None)
            return observed

        passes = []

        def cli_watch():
            # The cli_watch of native_gateway.main, recording each pass and its clock.
            now = time.time()
            found = host.detect_silent_failures(
                HOST_ID, manager.session_gone, now=now, deadline_seconds=DEADLINE_SECONDS,
                prompt_identity=lambda key: manager.prompt_identity(key, self.approval))
            passes.append((now, found))
            return found

        with mock.patch.dict(os.environ, gateway.env):
            start = len(gateway.provider_requests())
            queued_before = {row["id"] for row in gateway.call("deliveries")}

            def new_queue_rows():
                # A settled row keeps its id but loses its session and context to a tombstone.
                return [(row["id"], row["status"]) for row in gateway.call("deliveries")
                        if row["id"] not in queued_before]

            task_id = gateway.tool("submit", request, f"{mode}-submit-turn")["taskId"]
            context_key = f"task:{task_id}"
            gateway.tool("admit", {"taskId": task_id, "admissionKey": f"{mode}-attempt"},
                         f"{mode}-admit-turn")
            typed_at = time.time()
            observed = cli_claim()
            self.assertIsNotNone(observed, "the host claimed nothing")
            self.assertEqual(observed.status, "typed",
                             f"typing the reference counted as a delivery; screen={cli.screen()!r}")
            self.assertEqual(typed, [observed.assignment_ref])
            # Literal gate (opcion A): los bytes exactos que TmuxTransport.deliver deja en el pane:
            # su texto mas un Enter (un newline en el terminal del doble). Se compara byte por byte
            # al final: cierra por construccion el retecleo dentro del primer reclamo, donde una
            # linea base tomada tras el reclamo ya contendria el reintento.
            expected = ((f"Open assignment JSON at {observed.assignment_ref}. First write "
                         "agent-work.accept.v1 atomically to acceptRef with schema, hostId, taskId, "
                         "generation, instanceId, claimId and capability copied from the assignment. "
                         "Then follow briefRef and write agent-work.result.v1 atomically to resultRef.\n").encode())
            # What the one delivery leaves in the pane: its text and one Enter (a newline in the
            # double's terminal). Any byte after it, the reference or not, is typing again.
            delivery_bytes = wait_for(lambda: cli.received.exists() and cli.received.read_bytes().endswith(b"\n")
                                      and cli.received.read_bytes(), 2)
            self.assertTrue(delivery_bytes, "the delivery never reached the pane")
            key = OperationKey(HOST_ID, task_id, 1, instance)
            op_id = operation_id(key)
            incident = {**UNACCEPTED, "evidenceRef": f"host-operation:{op_id}"}
            wake_id = hashlib.sha256(
                f"managed-task-incident:{task_id}:1:{INCIDENT_KEY}".encode()).hexdigest()

            pump = Pump(client, host, root, cli_claim, cli_watch)
            try:
                recorded = wait_for(lambda: incident_rows(host), 40)
                self.assertTrue(recorded, f"no durable incident; passes={passes} claims={claims} "
                                          f"pump_error={pump.error} screen={cli.screen()!r}")
                settled = wait_for(lambda: [row for row in new_queue_rows() if row[1] != "pending"], 30)
                self.assertTrue(settled, f"the incident never woke the requester; queue={new_queue_rows()}")
                wakes = wait_for(lambda: gateway.provider_requests()[start:], 15)
                self.assertTrue(wakes, "the settled wake never reached the model provider")
                wake_pass, wake_claims = len(passes), len(claims)
                # Keep pumping: every pass replays the claim and judges the delivery again, and
                # neither may type the reference again or raise another wake.
                quiet = wait_for(lambda: len(passes) >= wake_pass + IDLE_PASSES
                                 and len(claims) >= wake_claims + IDLE_PASSES, 60)
                self.assertTrue(quiet, f"the pump stopped after the wake; passes={passes} claims={claims}")
            finally:
                self.assertTrue(pump.stop(), "the pump did not stop")
            self.assertIsNone(pump.error)
            self.assertEqual(typed, [observed.assignment_ref],
                             f"the reference was typed {len(typed)} times; claims={claims}")
            # The same unaccepted delivery an hour and a day later is still the same incident.
            for later in (3600, 86400):
                # The claim replays an hour and a day later too, and still never retypes.
                with mock.patch("time.time", return_value=time.time() + later):
                    self.assertEqual(cli_claim().status, "uncertain")
                self.assertEqual(typed, [observed.assignment_ref], f"a claim {later}s later retyped")
                late = host.detect_silent_failures(
                    HOST_ID, manager.session_gone, now=time.time() + later,
                    deadline_seconds=DEADLINE_SECONDS,
                    prompt_identity=lambda key: manager.prompt_identity(key, self.approval))
                self.assertEqual(late, [], f"a pass {later}s later raised {late}")

            def landed():
                return cli.received.read_bytes().decode("utf-8", "replace").count(observed.assignment_ref)

            # Counted where it lands, over the whole case: whatever path typed it, at any time,
            # it reached the pane once. The double logs within a tick, so give it time to land.
            wait_for(lambda: landed() > 1, 2)
            self.assertEqual(landed(), 1, f"the reference reached the pane {landed()} times")
            self.assertEqual(cli.received.read_bytes(), delivery_bytes,
                             "something else reached the pane after the delivery: "
                             f"{cli.received.read_bytes()[len(delivery_bytes):]!r}")
            self.assertEqual(cli.received.read_bytes(), expected,
                             "the pane did not receive exactly one delivery: "
                             f"{cli.received.read_bytes()!r}")
            self.assertEqual(host.spool.get(op_id)["status"], "uncertain")
            early = [found for now, found in passes if now < typed_at + DEADLINE_SECONDS]
            self.assertGreaterEqual(len(early), 2, "the pump never judged before the deadline")
            self.assertEqual([key for found in early for key in found], [])
            replays = [status for status in claims[1:] if status is not None]
            self.assertGreaterEqual(len(replays), IDLE_PASSES, f"the claim was never replayed; claims={claims}")
            self.assertEqual(set(replays), {"uncertain"})
            after = gateway.provider_requests()[start:]
            self.assertEqual(len(after), 1, f"the incident woke a model {len(after)} times")
            self.assertEqual(new_queue_rows(), [(wake_id, "completed")])
            self.assertIn({"taskId": task_id, "kind": "transport-unavailable"},
                          after[0].get("incidentWakes", []))
            in_flight = [row for row in after[0]["startedDeliveries"] if row["contextKey"] == context_key]
            self.assertEqual([row["sessionKey"] for row in in_flight], [LOOP_SESSION])
            self.assertEqual([key for _, found in passes for key in found], [INCIDENT_KEY])
            self.assertEqual(client.incident_reports, [incident], "the pump sent the incident again")
            self.assertEqual(incident_rows(host), [(task_id, INCIDENT_KEY, "sent", canonical(incident))])
            snapshot = gateway.tool("inspect", {"taskId": task_id}, f"{mode}-inspect-turn")
            self.assertEqual(snapshot["incidents"], [incident])
            self.assertIsNone(snapshot["result"])
            screen = cli.screen()
            latency = (after[0]["at"] - in_flight[0]["enqueuedAt"]) / 1000
            print(f"CLI_DELIVERY_ACCEPTANCE_E2E case={mode} incident={INCIDENT_KEY} "
                  f"typed={len(typed)} claim_replays={len(replays)} "
                  f"detections={len([key for _, found in passes for key in found])} "
                  f"incident_rpcs={len(client.incident_reports)} wake_requests={len(after)} "
                  f"wake_latency_s={latency:.2f} passes={len(passes)} "
                  f"reference_on_screen={observed.assignment_ref in screen} "
                  f"session={LOOP_SESSION} deadline_s={DEADLINE_SECONDS}", flush=True)
            return observed, screen

    def test_phantom_suggestion_in_the_composer(self):
        observed, screen = self.unaccepted_case("phantom")
        # The reference sits in the composer as a ghost suggestion: seeing it is not delivering it.
        self.assertIn(observed.assignment_ref, screen)

    def test_busy_session_that_never_took_the_input(self):
        observed, screen = self.unaccepted_case("busy")
        self.assertIn("Working...", screen)
        self.assertNotIn(observed.assignment_ref, screen)


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

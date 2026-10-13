#!/usr/bin/env python3
"""ruta_viva: a "por CLI" task through the live route, against the real R Gateway.

main's durable session asks as it does in production: `encargo.py preparar`, `brief.py`, then the native
submit and admit tools. The host is native_gateway.py with the arguments lanzar-encargos.sh gives it, one
process, and it reaches the harness's Gateway through R's own CLI with --device-auth. opencode is the double
of test-agent-work-sesion.py, a real process inside the slot's group, held at a gate the case opens.

Each case has its own Gateway state, spool, task repo, tmux server and slot group, so it shares nothing with
this machine's host. It skips while its group holds a process, because closing a task sweeps that group.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from test_agent_work_main_cli_loop_e2e import HOST_ID, LOOP_SESSION, LoopGateway, built_runtime, wait_for  # noqa: E402
import brief  # noqa: E402
import encargo  # noqa: E402
from contracts import OperationKey, operation_id  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient  # noqa: E402
from sesion import GroupBoundaryBackend  # noqa: E402
from spool import canonical  # noqa: E402

# The opencode double lives in a file whose name cannot be imported.
_spec = importlib.util.spec_from_file_location("sesion_doubles", ROOT / "scripts/tests/test-agent-work-sesion.py")
doubles = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(doubles)

GATEWAY = ROOT / "scripts/agent-work/native_gateway.py"
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
# The group whose processes are the slot of a case's host. It is not agent-work-enc1, the slot of this machine's
# host: _appserverusr is a macOS group the operator's account already belongs to and no process runs with, so
# a case and a live task never share a boundary. The host closes the same way whatever group it is given.
SLOT_GROUP = os.environ.get("AGENT_WORK_E2E_SLOT_GROUP", "_appserverusr")
INSTANCE = "enc-1"
# Not the default model: it reaches `opencode -m` only if the brief's header crossed R untouched.
MODEL = "zai-coding-plan/glm-5.3"
ARTIFACT = b"hecho por el doble\n"
# Long enough to catch a wake raised while opencode works: the first wake of a Gateway takes about 6 s.
WORK_SECONDS = 15.0
# opencode as the host launches it: every launch is counted, and the double starts once the gate opens.
GATED_OPENCODE = """#!/bin/sh
here=$(dirname "$0")
if [ "$1" = run ]; then
  echo "$$" >> "$here/launches"
  while [ ! -e "$here/go" ]; do /bin/sleep 0.1; done
fi
exec "$here/doble" "$@"
"""
# R's CLI as the host calls it: every call is noted, and a report can lose its answer after R took it.
NOTED_OPENCLAW = """#!/bin/sh
here=$(dirname "$0")
echo "$3" >> "$here/rpc"
if [ "$3" = managedTasks.host.report ] && /bin/rm "$here/lose-report" 2>/dev/null; then
  "__R__" "$@" >/dev/null 2>&1
  exit 1
fi
exec "__R__" "$@"
"""
UNAUTHORIZED = "Managed host device or adapter is not authorized"


def said(main, argv):
    """What a command of this repo prints, as (exit code, JSON)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = main(argv)
    return code, json.loads(out.getvalue())


def sha256(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(shutil.which("tmux"), "needs tmux")
class RutaVivaE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        temp = tempfile.TemporaryDirectory(prefix="agent-work-ruta-viva-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.socket = f"ruta-viva-{os.getpid()}-{self.id().rsplit('.', 1)[-1][-24:]}"
        try:
            self.slot = GroupBoundaryBackend(TMUX, self.socket, SLOT_GROUP)
        except ValueError as missing:
            self.skipTest(f"{missing}; name a group this user belongs to in AGENT_WORK_E2E_SLOT_GROUP")
        busy = self.slot.boundary()
        if busy:
            self.skipTest(f"the group {SLOT_GROUP} holds live processes and this case would sweep them: "
                          f"{'; '.join(map(str, busy))}")
        self.state = self.root / "state"
        self.spool = self.state / INSTANCE
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, text in (("opencode", GATED_OPENCODE), ("doble", doubles.OPENCODE_DOUBLE),
                           ("openclaw", NOTED_OPENCLAW.replace("__R__", str(self.runtime / "openclaw.mjs")))):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        (self.bin / "version").write_text("1.18.35\n")
        (self.bin / "listing").write_text(doubles.LISTING)
        (self.bin / "case").write_text("result")
        self.repo = self.root / "dev" / "demo"
        self.repo.mkdir(parents=True)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        for command in (["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q",
                                         "--allow-empty", "-m", "base"]):
            subprocess.run(["git", "-C", str(self.repo), *command], check=True, env=env, capture_output=True)
        self.addCleanup(self.clean_slot)
        subprocess.run([TMUX, "-L", self.socket, "-f", "/dev/null", "new-session", "-d", "-s", "keeper", "sleep 600"],
                       check=True, cwd=self.root)
        self.gateway = LoopGateway(self.runtime, self.root, extra_env={"CROSS_HOST_ADAPTER": "opencode"})
        self.addCleanup(self.gateway.close)
        self.log = self.root / "host.log"
        self.addCleanup(self.stop_host)
        self.start_host()
        self.reached((self.state / "host.json").exists, 30, "the host never wrote its beat")

    def start_host(self):
        """A host process over this case's spool: the first one, or the one that replaces a dead one."""
        with self.log.open("a") as log:
            self.host = subprocess.Popen(
                [sys.executable, str(GATEWAY), "--openclaw-bin", str(self.bin / "openclaw"),
                 "--host-id", HOST_ID, "--expect-url", self.gateway.url, "--host-state-dir", str(self.spool),
                 "--state-root", str(self.state), "--evidence-root", str(self.state / "evidence"),
                 "--progress-state-dir", str(self.root / "progress"), "--progress-client", "unused", "--watch",
                 "--cli-instance-id", INSTANCE, "--cli-tmux-socket", self.socket, "--tmux-bin", TMUX,
                 "--workspace-root", str(self.root / "dev"), "--opencode-bin", str(self.bin / "opencode"),
                 "--slot-group", SLOT_GROUP],
                cwd=ROOT, env={**self.gateway.env, "LANG": "en_US.UTF-8"}, stdout=log, stderr=subprocess.STDOUT)

    def stop_host(self):
        if self.host.poll() is None:
            self.host.terminate()
            try:
                self.host.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.host.kill()
                self.host.wait()
        return self.host.returncode

    def clean_slot(self):
        socket = subprocess.run([TMUX, "-L", self.socket, "display-message", "-p", "#{socket_path}"],
                                capture_output=True, text=True).stdout.strip()
        subprocess.run([TMUX, "-L", self.socket, "kill-server"], capture_output=True)
        if socket.endswith(f"/{self.socket}"):
            with contextlib.suppress(OSError):
                os.unlink(socket)
        launched = set(self.launches())
        for process in self.slot.boundary():
            if process.pid in launched:
                with contextlib.suppress(ProcessLookupError):
                    os.kill(process.pid, signal.SIGKILL)
        deadline = time.monotonic() + 5
        while self.slot.boundary() and time.monotonic() < deadline:
            time.sleep(0.05)

    def reached(self, predicate, seconds, what):
        value = wait_for(predicate, seconds)
        if not value:
            self.fail(f"{what} in {seconds} s; host log: {self.log.read_text()[-3000:]}")
        return value

    def launches(self):
        """The pid of every `opencode run` the host started."""
        with contextlib.suppress(FileNotFoundError):
            return [int(line) for line in (self.bin / "launches").read_text().split()]
        return []

    def ask(self):
        """main asks for the task as it does in production: what `preparar` answers, what `brief.py` publishes,
        then the native submit and admit. Returns the task's id."""
        where = ["--checkout", str(ROOT), "--state-root", str(self.state), "--opencode", str(self.bin / "opencode"),
                 "--workspace-root", str(self.root / "dev")]
        code, ready = said(encargo.main, [*where, "preparar", "--repo", str(self.repo), "--modelo", MODEL])
        self.assertEqual((code, ready["ok"], ready["modelo"]), (0, True, MODEL), ready)
        text = self.root / "brief.txt"
        text.write_text("Deja el saludo en b22-doble.txt.\n")
        code, fragments = said(brief.main, ["--root", str(self.gateway.state_dir), "--file", str(text),
                                            *ready["briefArgs"]])
        self.assertEqual(code, 0)
        self.revision = ready["inputRevision"]
        request = {"taskKey": "ruta-viva", "assignment": {
            **fragments, "inputRevision": self.revision, "resultContract": "ready.v1",
            "continuation": {"kind": "requester"}}}
        submitted = self.gateway.tool("submit", request, "ruta-viva-submit")
        admitted = self.gateway.tool("admit", {"taskId": submitted["taskId"], "admissionKey": "ruta-viva-1"},
                                     "ruta-viva-admit")
        self.assertEqual((submitted["state"], admitted["state"]), ("registered", "host-pending"))
        return submitted["taskId"]

    def inspect(self, task_id):
        return self.gateway.tool("inspect", {"taskId": task_id}, "ruta-viva-inspect")

    def estado(self, task_id):
        return said(encargo.main, ["--checkout", str(ROOT), "--state-root", str(self.state),
                                   "--opencode", str(self.bin / "opencode"), "estado", "--tarea", task_id])[1]

    def sessions(self):
        listed = subprocess.run([TMUX, "-L", self.socket, "list-sessions", "-F", "#{session_name}"],
                                capture_output=True, text=True)
        return sorted(listed.stdout.split())

    def calls(self, name):
        """How many times the host called managedTasks.host.<name>."""
        with contextlib.suppress(FileNotFoundError):
            return (self.bin / "rpc").read_text().split().count(f"managedTasks.host.{name}")
        return 0

    def sent(self):
        """How many times the host sent R each call that changes a task."""
        return {name: self.calls(name) for name in ("admit", "incident", "report", "close")}

    def opencode_runs(self, case):
        """The gate is open from the start: the double does what the case says as soon as it is launched."""
        (self.bin / "case").write_text(case)
        (self.bin / "go").touch()

    def closed_in_r(self, task_id, evidence):
        """The host stops, and this is the closure R must hold: the one row of the task, with the digest of
        the evidence the host closed on and of its own proof that the slot was left empty."""
        self.reached(lambda: self.gateway.call("closures"), 120, "the host never closed the task in R")
        self.assertEqual(self.stop_host(), 0, self.log.read_text()[-3000:])
        operation = operation_id(OperationKey(HOST_ID, task_id, 1, INSTANCE))
        proof = json.loads(Host(HOST_ID, self.spool).spool.closure_proof(operation))
        self.assertEqual((proof["pane_gone"], proof["session_gone"], proof["boundary_after"]), (True, True, []))
        self.assertEqual(self.gateway.call("closures"), [{
            "taskId": task_id, "generation": 1, "hostId": HOST_ID, "instanceId": INSTANCE, "state": "AbsenceVerified",
            "reason": "", "evidenceDigest": sha256(canonical({"evidence": evidence, "proof": proof}).encode())}])
        self.assertEqual((self.sessions(), self.slot.boundary()), (["keeper"], ()))

    def settled(self, wake_id):
        """The session queue once R processed its one wake."""
        rows = self.reached(lambda: [row for row in self.gateway.call("deliveries") if row["status"] != "pending"],
                            30, "the wake never settled")
        self.assertEqual([(row["id"], row["status"]) for row in rows], [(wake_id, "completed")])
        self.assertEqual(len(self.gateway.call("deliveries")), 1)

    def asked_of_main(self):
        """What R asked main's model about, one entry per request to the provider: (results, incidents)."""
        return [(request["wakeTasks"], request["incidentWakes"]) for request in self.gateway.provider_requests()]

    def test_a_task_goes_from_main_to_opencode_and_back_and_r_keeps_the_proof_of_its_closure(self):
        task_id = self.ask()
        claim = json.dumps({"hostId": HOST_ID, "adapterId": "opencode", "instanceId": INSTANCE})
        stranger = subprocess.run(
            [str(self.runtime / "openclaw.mjs"), "gateway", "call", "managedTasks.host.claim", "--json",
             "--expect-url", self.gateway.url, "--params", claim], env=self.gateway.env, capture_output=True, text=True)
        self.assertEqual((stranger.returncode, json.loads(stranger.stdout)["error"]["message"]), (1, UNAUTHORIZED),
                         "R handed the task to a caller that did not show the host's device")
        self.reached(self.launches, 90, "the host never launched opencode")
        opened, quiet_until = time.time(), time.monotonic() + WORK_SECONDS
        while time.monotonic() < quiet_until:
            self.assertEqual((self.gateway.call("deliveries"), self.gateway.provider_requests()), ([], []),
                             "R woke a session or asked a model while opencode worked")
            time.sleep(0.5)
        window = time.time() - opened
        self.reached(lambda: self.calls("claim") > 1, 60, "the host never asked R again for the task it holds")
        (self.bin / "go").touch()

        wakes = self.reached(self.gateway.provider_requests, 120, "the report never woke main's session")
        self.settled(sha256(f"managed-task-result:{task_id}:1".encode()))
        snapshot = self.inspect(task_id)
        self.assertEqual((snapshot["deliveryState"], snapshot["handlingState"], snapshot["incidents"]),
                         ("result-recorded", "pending-handling", []))
        result = snapshot["result"]
        self.assertEqual((result["kind"], result["payload"], result["observedRevision"], result["evidenceContentHash"]),
                         ("produced", {"evidenceRef": "b22-doble.txt"}, self.revision, sha256(ARTIFACT)))
        self.closed_in_r(task_id, {"kind": "result", "receipt": snapshot["resultReceipt"]["resultDigest"]})
        decision = {"kind": "complete", "evidenceRef": "b22-doble.txt"}
        self.gateway.tool("resolve", {"receipt": snapshot["resultReceipt"], "decision": decision}, "ruta-viva-resolve")
        handled = self.inspect(task_id)
        self.assertEqual((handled["handlingState"], handled["handlingDecision"]), ("handled", decision))

        self.assertEqual(self.asked_of_main(), [([task_id], [])])
        in_flight = wakes[0]["startedDeliveries"]
        self.assertEqual([(row["sessionKey"], row["contextKey"]) for row in in_flight],
                         [(LOOP_SESSION, f"task:{task_id}")])
        latency = (wakes[0]["at"] - in_flight[0]["enqueuedAt"]) / 1000
        self.assertLess(latency, window, "the window opencode worked in is too short to have caught a wake")
        self.assertEqual(self.gateway.call("sessions"), [LOOP_SESSION])

        self.assertEqual((len(self.launches()), self.sent()), (1, {"admit": 1, "incident": 0, "report": 1, "close": 1}))
        seen = json.loads((self.bin / "seen.json").read_text())
        self.assertEqual((seen["cwd"], seen["PWD"], seen["rgid"], seen["argv"][:3], seen["argv"][8:10]),
                         (str(self.repo), str(self.repo), self.slot.gid, ["run", "-m", MODEL], ["--title", task_id]))
        self.assertEqual((self.repo / "b22-doble.txt").read_bytes(), ARTIFACT)
        estado = self.estado(task_id)
        self.assertEqual((estado["estado"], estado["cierre"], estado["modelo"], estado["carpetaDeSesion"],
                          estado["explicacion"]), ("acknowledged", "AbsenceVerified", MODEL, str(self.repo), None))
        print(f"RUTA_VIVA_E2E case=result task={task_id} launches=1 rpc={self.sent()} window_s={window:.1f} "
              f"window_provider_requests=0 closure=AbsenceVerified wake_latency_s={latency:.2f} wake_requests=1",
              flush=True)

    def test_a_task_main_cancels_while_opencode_works_dies_in_the_slot_and_r_keeps_the_proof(self):
        self.opencode_runs("hang")
        task_id = self.ask()
        self.reached((self.bin / "seen.json").exists, 90, "the host never launched opencode")
        working = self.launches()[0]
        self.assertIn(working, [process.pid for process in self.slot.boundary()])
        cancelled = self.gateway.tool("cancel", {"taskId": task_id, "reason": "ya no hace falta"}, "ruta-viva-cancel")
        self.closed_in_r(task_id, {"kind": "cancel", "receipt": cancelled["cancellationId"]})
        with self.assertRaises(ProcessLookupError):
            os.kill(working, 0)
        snapshot = self.inspect(task_id)
        self.assertEqual((snapshot["deliveryState"], snapshot["handlingState"], snapshot["result"]),
                         ("registered", "cancelled", None))
        estado = self.estado(task_id)
        self.assertEqual((estado["estado"], estado["cierre"]), ("cancelled", "AbsenceVerified"))
        # main cancelled it itself: R has nothing to tell it.
        self.assertEqual((self.gateway.call("deliveries"), self.asked_of_main()), ([], []))
        self.assertEqual((len(self.launches()), self.sent()), (1, {"admit": 1, "incident": 0, "report": 0, "close": 1}))
        print(f"RUTA_VIVA_E2E case=cancel task={task_id} launches=1 killed={working} rpc={self.sent()} "
              "closure=AbsenceVerified wake_requests=0", flush=True)

    def test_a_launch_that_fails_reaches_r_as_one_incident_and_wakes_main_once(self):
        self.opencode_runs("error")
        task_id = self.ask()
        self.reached(self.gateway.provider_requests, 120, "the incident never woke main's session")
        self.settled(sha256(f"managed-task-incident:{task_id}:1:host:1:transport-unavailable:launch-failed".encode()))
        operation = operation_id(OperationKey(HOST_ID, task_id, 1, INSTANCE))
        snapshot = self.inspect(task_id)
        self.assertEqual((snapshot["deliveryState"], snapshot["handlingState"], snapshot["incidents"]),
                         ("registered", "awaiting-result", [{
                             "kind": "transport-unavailable", "episodeId": "launch-failed",
                             "evidenceRef": f"host-operation:{operation}"}]))
        self.assertEqual(self.gateway.call("closures"), [])
        estado = self.estado(task_id)
        self.assertEqual((estado["estado"], estado["cierre"], estado["salida"], estado["explicacion"]["causa"]),
                         ("uncertain", None, 1, "launch-failed"))
        # main does what the wake tells it: the task will not continue.
        cancelled = self.gateway.tool("cancel", {"taskId": task_id, "reason": "no arrancó"}, "ruta-viva-cancel")
        self.closed_in_r(task_id, {"kind": "cancel", "receipt": cancelled["cancellationId"]})
        self.assertEqual(self.asked_of_main(), [([], [{"taskId": task_id, "kind": "transport-unavailable"}])])
        self.assertEqual((len(self.launches()), self.sent()), (1, {"admit": 1, "incident": 1, "report": 0, "close": 1}))
        print(f"RUTA_VIVA_E2E case=launch-failed task={task_id} launches=1 rpc={self.sent()} wake_requests=1 "
              "closure=AbsenceVerified", flush=True)

    def test_a_host_killed_while_opencode_works_comes_back_to_its_session_and_launches_nothing_new(self):
        task_id = self.ask()
        self.reached(self.launches, 90, "the host never launched opencode")
        self.host.kill()
        self.host.wait()
        asked = self.calls("claim")
        self.start_host()
        self.reached(lambda: self.calls("claim") > asked, 60, "the host that came back never asked R for its task")
        (self.bin / "go").touch()
        self.reached(self.gateway.provider_requests, 120, "the report never woke main's session")
        self.settled(sha256(f"managed-task-result:{task_id}:1".encode()))
        snapshot = self.inspect(task_id)
        self.assertEqual((snapshot["deliveryState"], snapshot["result"]["evidenceContentHash"]),
                         ("result-recorded", sha256(ARTIFACT)))
        self.closed_in_r(task_id, {"kind": "result", "receipt": snapshot["resultReceipt"]["resultDigest"]})
        self.assertEqual((len(self.launches()), self.sent()), (1, {"admit": 1, "incident": 0, "report": 1, "close": 1}))
        self.assertEqual(self.asked_of_main(), [([task_id], [])])
        print(f"RUTA_VIVA_E2E case=host-sigkill task={task_id} launches=1 rpc={self.sent()} wake_requests=1 "
              "closure=AbsenceVerified", flush=True)

    def test_a_report_whose_answer_is_lost_is_sent_again_and_r_keeps_one_result_and_refuses_another(self):
        self.opencode_runs("result")
        (self.bin / "lose-report").touch()
        task_id = self.ask()
        self.reached(self.gateway.provider_requests, 120, "the report never woke main's session")
        self.settled(sha256(f"managed-task-result:{task_id}:1".encode()))
        receipt = self.inspect(task_id)["resultReceipt"]["resultDigest"]
        self.closed_in_r(task_id, {"kind": "result", "receipt": receipt})
        sent = self.sent()
        self.assertEqual((len(self.launches()), sent), (1, {"admit": 1, "incident": 0, "report": 2, "close": 1}))

        # A different result for the same task: R refuses it and keeps the first.
        reported, _ = Host(HOST_ID, self.spool).result_snapshot(HOST_ID, OperationKey(HOST_ID, task_id, 1, INSTANCE))
        other = b"otro contenido\n"
        client = GatewayProjectionClient(str(self.bin / "openclaw"), HOST_ID, self.gateway.url)
        with mock.patch.dict(os.environ, self.gateway.env):
            with self.assertRaisesRegex(RuntimeError, "managedTasks.host.report: Managed task result conflict$"):
                client.report_host_result({**reported, "digest": sha256(other)}, other)
        snapshot = self.inspect(task_id)
        self.assertEqual((snapshot["resultReceipt"]["resultDigest"], snapshot["result"]["evidenceContentHash"]),
                         (receipt, sha256(ARTIFACT)))
        self.assertEqual((self.asked_of_main(), len(self.gateway.call("deliveries"))), ([([task_id], [])], 1))
        print(f"RUTA_VIVA_E2E case=lost-ack task={task_id} launches=1 rpc={sent} conflict_refused=1 wake_requests=1 "
              "closure=AbsenceVerified", flush=True)


if __name__ == "__main__":
    unittest.main()

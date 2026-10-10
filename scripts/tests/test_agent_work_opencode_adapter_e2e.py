#!/usr/bin/env python3
"""opencode_adapter: main's loop session hands managed tasks to a real opencode session on GLM.

Opt-in with AGENT_WORK_OPENCODE_LIVE=1: it spends GLM quota (zai-coding-plan) and needs
opencode logged in, so CI never runs it. Nothing here is a double except the requester's
model: the R Gateway runs in-process as in main_cli_loop, and the host, TmuxTransport,
ResourceManager and pump are the production ones, on a private tmux server. Two tasks go
to the same adopted session, as the claw loop sends them.
"""

import faulthandler
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from host import Host, TmuxTransport, read_acceptance  # noqa: E402
from native_gateway import claim_cli_once  # noqa: E402
from resources import ResourceManager, TmuxBackend, load_approval_pattern  # noqa: E402
from routing import prepare_request  # noqa: E402
from contracts import operation_id  # noqa: E402
from test_agent_work_cli_delivery_acceptance_e2e import Pump  # noqa: E402
from test_agent_work_cli_silent_failure_e2e import CountingClient, incident_rows  # noqa: E402
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    LOOP_SESSION, LoopGateway, built_runtime, wait_for)

HOST_ID, ADAPTER = "mac-local", "opencode"
MODEL = "zai-coding-plan/glm-5.3-flash"
SESSION = "opencode-loop"
INSTANCE = "opencode-loop-host"
TASKS = 2
DRAFT = "borrador del operador"
TASK_SECONDS = 300
RUN_LIMIT_SECONDS = 900
LIB_SH = ROOT / "scripts/mac/corrida/lib.sh"
REVISION = {"kind": "code", "repository": "opencode-cert", "sha": "c" * 40}
STARTED = time.monotonic()


def log(event):
    print(f"OPENCODE_E2E t={time.monotonic() - STARTED:6.1f}s {event}", flush=True)


def redacted(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as exc:
        return f"<{exc.__class__.__name__}: {exc}>"
    if isinstance(value, dict) and "capability" in value:
        value["capability"] = "<redacted>"
    return json.dumps(value, sort_keys=True)


class OpencodeSession:
    """opencode on its own tmux server, launched as the runbook says for an adopted worker."""

    def __init__(self, workspace, host_dir):
        self.tmux = shutil.which("tmux")
        self.socket = f"agent-work-opencode-{os.getpid()}-{secrets.token_hex(4)}"
        self.socket_file = (Path(os.environ.get("TMUX_TMPDIR") or "/tmp")
                            / f"tmux-{os.getuid()}" / self.socket)
        opencode = shutil.which("opencode") or "/opt/homebrew/bin/opencode"
        # The assignment, acceptRef and resultRef live in the host state, outside the workspace,
        # and opencode asks before it touches any directory outside its own.
        config = {"permission": {"external_directory": {f"{host_dir}/**": "allow"}}}
        started = self._tmux("new-session", "-d", "-s", SESSION, "-x", "200", "-y", "50",
                             "-c", str(workspace),
                             "-e", f"OPENCODE_CONFIG_CONTENT={json.dumps(config)}",
                             "-e", "OPENCODE_DISABLE_AUTOUPDATE=1",
                             # The alarm ends opencode, and with it this tmux server, even if the
                             # harness dies past its own deadline without running its cleanups.
                             "perl", "-e", f"alarm {RUN_LIMIT_SECONDS + 60}; exec @ARGV",
                             opencode, "-m", MODEL)
        if started.returncode:
            raise RuntimeError("tmux could not start opencode: " + started.stderr)

    def _tmux(self, *args):
        return subprocess.run([self.tmux, "-f", "/dev/null", "-L", self.socket, *args],
                              capture_output=True, text=True, timeout=10)

    def screen(self):
        return self._tmux("capture-pane", "-p", "-J", "-t", f"={SESSION}:").stdout

    def type(self, text):
        self._tmux("send-keys", "-t", f"={SESSION}:", "-l", "--", text)

    def erase(self, count):
        self._tmux("send-keys", "-t", f"={SESSION}:", *["BSpace"] * count)

    def close(self):
        self._tmux("kill-server")
        if self.socket_file.exists():
            self.socket_file.unlink()


class RecordingTransport(TmuxTransport):
    """The production transport; each time it types, the composer it typed into is read first."""

    def __init__(self, *args):
        super().__init__(*args)
        self.typed = []

    def state(self):
        try:
            return self.composer(SESSION)
        except OSError as exc:
            return "DESCONOCIDO", str(exc)

    def _tmux(self, *args):
        if args[0] == "send-keys" and "-l" in args:
            self.typed.append((self.composer(SESSION)[0], args[-1]))
        return super()._tmux(*args)


def brief_for(number, line):
    return (f"Managed task {number} of the opencode adapter certification.\n"
            f"In your current working directory create the file cert-{number}.txt whose whole "
            f"content is the line `{line}` followed by one newline.\n"
            "Then report it exactly as the assignment explains. This task's result contract is "
            f'ready.v1, so its typed payload is {{"evidenceRef": "cert-{number}.txt"}} and its '
            "artifact is that file.\nDo nothing else.\n").encode()


class OpencodeAdapterE2E(unittest.TestCase):
    def test_main_loop_hands_tasks_to_an_adopted_opencode_session(self):
        if os.environ.get("AGENT_WORK_OPENCODE_LIVE") != "1":
            self.skipTest("set AGENT_WORK_OPENCODE_LIVE=1 to spend GLM quota on a live opencode run")
        runtime = built_runtime(self)
        self.assertTrue(shutil.which("tmux"), "the adapter runs in a real tmux pane")
        root = Path(tempfile.mkdtemp(prefix="agent-work-opencode-")).resolve()
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        workspace, host_dir = root / "workspace", root / "host"
        workspace.mkdir()
        subprocess.run(["git", "init", "-q", "-b", "main", str(workspace)], check=True)
        coverage = json.loads((ROOT / "docs/evidence/agent-work/coverage.json").read_text())
        coverage["hostAdapterCoverage"][HOST_ID][ADAPTER] = "certified"
        gateway = LoopGateway(runtime, root, extra_env={"CROSS_HOST_ADAPTER": ADAPTER})
        self.addCleanup(gateway.close)
        cli = OpencodeSession(workspace, host_dir)
        self.addCleanup(cli.close)
        log(f"gateway={gateway.url} socket={cli.socket} model={MODEL} workspace={workspace}")
        transport = RecordingTransport(cli.tmux, cli.socket)
        ready = wait_for(lambda: transport.state()[0] == "VACIO", 60)
        self.assertTrue(ready, f"opencode never showed an empty composer; screen={cli.screen()!r}")
        log("opencode composer VACIO")

        host = Host(HOST_ID, host_dir)
        manager = ResourceManager(host.spool, HOST_ID, TmuxBackend(cli.tmux, cli.socket))
        client = CountingClient(str(runtime / "openclaw.mjs"), HOST_ID, gateway.url)
        approval = load_approval_pattern(LIB_SH)
        claims = []

        def cli_claim():
            observed = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                      instance_id=INSTANCE, session=SESSION,
                                      workspace_root=workspace, deliver=transport.deliver,
                                      coverage=coverage)
            claims.append(observed.status if observed else None)
            return observed

        def cli_watch():
            return host.detect_silent_failures(
                HOST_ID, manager.session_gone, now=time.time(), deadline_seconds=TASK_SECONDS,
                prompt_identity=lambda key: manager.prompt_identity(key, approval))

        def diagnose(task_id):
            key = host.operation_key_for(HOST_ID, task_id, 1)
            lines = [f"claims={claims}", f"typed={[state for state, _ in transport.typed]}",
                     f"inbox_errors={host.inbox_errors(HOST_ID)}", f"incidents={incident_rows(host)}"]
            if key is not None:
                assignment = json.loads(host.spool.get(operation_id(key))["operation_json"])
                lines += [f"status={host.spool.get(operation_id(key))['status']}",
                          f"accept={redacted(assignment['acceptRef'])}",
                          f"result={redacted(assignment['resultRef'])}"]
            return "\n".join(lines + ["screen:", cli.screen()])

        def submit(number, line):
            brief = root / f"brief-{number}.txt"
            brief.write_bytes(brief_for(number, line))
            request = prepare_request(requester="main", target=f"{HOST_ID}/{ADAPTER}",
                                      key=f"opencode-cert-{number}", brief=brief,
                                      instruction_root=gateway.state_dir, input_revision=REVISION,
                                      result_contract="ready.v1", coverage=coverage)
            task_id = gateway.tool("submit", request, f"opencode-submit-{number}")["taskId"]
            admitted = gateway.tool("admit", {"taskId": task_id, "admissionKey": f"opencode-{number}"},
                                    f"opencode-admit-{number}")
            self.assertEqual(admitted["state"], "host-pending")
            log(f"task {number} submitted and admitted taskId={task_id}")
            return task_id

        pump = None
        with mock.patch.dict(os.environ, gateway.env):
            try:
                lines = {n: f"opencode-cert-{n} {secrets.token_hex(8)}" for n in range(1, TASKS + 1)}
                task_id = submit(1, lines[1])
                # The operator is writing in the composer: the host must wait, not type over it.
                cli.type(DRAFT)
                self.assertTrue(wait_for(lambda: transport.state() == ("REAL", DRAFT), 10),
                                f"the draft never showed; screen={cli.screen()!r}")
                observed = cli_claim()
                self.assertEqual(observed.status, "deferred", diagnose(task_id))
                self.assertEqual(transport.typed, [], "the host typed over the operator's draft")
                self.assertEqual(transport.state(), ("REAL", DRAFT))
                self.assertNotIn("Open assignment", cli.screen())
                log("draft in the composer: claim deferred, nothing typed")
                cli.erase(len(DRAFT))
                self.assertTrue(wait_for(lambda: transport.state()[0] == "VACIO", 10))
                pump = Pump(client, host, root, cli_claim, cli_watch)
                for number in range(1, TASKS + 1):
                    if number > 1:
                        task_id = submit(number, lines[number])
                    deadline = time.monotonic() + TASK_SECONDS
                    receipt = None
                    while receipt is None:
                        self.assertIsNone(pump.error, diagnose(task_id))
                        self.assertEqual(incident_rows(host), [], diagnose(task_id))
                        self.assertEqual(host.inbox_errors(HOST_ID), [], diagnose(task_id))
                        self.assertLess(time.monotonic(), deadline, "no result in time\n" + diagnose(task_id))
                        key = host.operation_key_for(HOST_ID, task_id, 1)
                        receipt = key and host.receipt(HOST_ID, key)
                        time.sleep(1)
                    op_id = operation_id(key)
                    assignment = json.loads(host.spool.get(op_id)["operation_json"])
                    self.assertTrue(read_acceptance(assignment), "accept.v1 is not bound to the assignment")
                    self.assertIsNotNone(host.spool.delivered_at(op_id), "the host never saw the acceptance")
                    log(f"task {number} accepted and reported receipt={receipt['receiptId']}")

                    expected = f"{lines[number]}\n".encode()
                    result, artifact = host.result_snapshot(HOST_ID, key)
                    self.assertEqual(artifact, expected)
                    self.assertEqual((workspace / f"cert-{number}.txt").read_bytes(), expected)
                    self.assertEqual(result["kind"], "produced")
                    self.assertEqual(result["digest"], hashlib.sha256(expected).hexdigest())
                    self.assertEqual(result["typedPayload"], {"evidenceRef": f"cert-{number}.txt"})
                    self.assertEqual(result["observedRevision"], REVISION)

                    wakes = wait_for(lambda: [r for r in gateway.provider_requests()
                                              if task_id in r["wakeTasks"]], 60)
                    self.assertTrue(wakes, "the result never woke main's loop session")
                    in_flight = [(row["sessionKey"], row["contextKey"])
                                 for row in wakes[0]["startedDeliveries"]
                                 if row["contextKey"] == f"task:{task_id}"]
                    self.assertEqual(in_flight, [(LOOP_SESSION, f"task:{task_id}")])
                    snapshot = gateway.tool("inspect", {"taskId": task_id}, f"opencode-inspect-{number}")
                    log(f"task {number} gateway result={json.dumps(snapshot['result'], sort_keys=True)}")
                    self.assertEqual(snapshot["incidents"], [])
                    self.assertEqual(snapshot["result"]["payload"], {"evidenceRef": f"cert-{number}.txt"})
                    self.assertEqual(snapshot["result"]["kind"], "produced")
                    self.assertEqual(snapshot["result"]["evidenceContentHash"],
                                     hashlib.sha256(expected).hexdigest())
                    gateway.tool("resolve", {"receipt": snapshot["resultReceipt"], "decision": {
                        "kind": "complete", "evidenceRef": f"cert-{number}.txt"}}, f"opencode-resolve-{number}")
                    handled = gateway.tool("inspect", {"taskId": task_id}, f"opencode-handled-{number}")
                    self.assertEqual(handled["handlingState"], "handled")
                    closed = manager.close(key, {"kind": "result", "receipt": receipt["receiptId"]})
                    self.assertEqual(closed.state, "ReleasedAdopted")
                    log(f"task {number} woke {LOOP_SESSION}, handled, session released and kept")
            finally:
                if pump is not None:
                    self.assertTrue(pump.stop(), "the pump did not stop")
            self.assertIsNone(pump.error)
            self.assertEqual(client.incident_reports, [])
            self.assertEqual([state for state, _ in transport.typed], ["VACIO"] * TASKS,
                             "the host typed into a composer that was not empty")
            self.assertTrue(all(re.fullmatch(r"Open assignment JSON at \S+\.json\. .*", text)
                                for _, text in transport.typed))
            sessions = gateway.call("sessions")
            self.assertEqual(sessions, [LOOP_SESSION])
            self.assertIsNotNone(manager.backend.observe(SESSION), "closing the task stopped opencode")
            log(f"OPENCODE_ADAPTER_E2E tasks={TASKS} typed={len(transport.typed)} "
                f"deferred_over_draft=1 incidents=0 sessions={sessions} claims={len(claims)}")


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

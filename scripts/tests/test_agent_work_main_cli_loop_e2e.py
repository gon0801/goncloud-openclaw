#!/usr/bin/env python3
"""main_cli_loop: main asks a CLI in an adopted mac-local session from its durable loop session.

The R Gateway runs in-process in the harness with a loopback model provider that
counts every request. The CLI is a double; the route, host, and transport are real.
"""

import copy
import hashlib
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from contracts import OperationKey  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager  # noqa: E402
from routing import RouteUnavailable, prepare_request  # noqa: E402
from spool import atomic_json  # noqa: E402
from test_agent_work_cli_gateway_e2e import FIXTURE, FakeCliSession  # noqa: E402

LOOP_SESSION = "agent:main:encargos-loop"
FOREIGN_SESSIONS = ("agent:main:main", "agent:main:vigia-mac")
FOREIGN_PREFIX = "agent:main:sim9-"
HOST_ID, ADAPTER = "mac-local", "claude_opus"
INSTANCE = "loop-instance"
CLI_SESSION = "fixture-worker"
# Same bytes as the harness fixture brief, so its artifact resolver accepts the digest.
BRIEF = b"Review the fixture change and return one verdict.\n"
CLI_WORK_SECONDS = 8.0
CRON_REFUSAL = "Managed task requires a durable requester session, not an isolated cron run"


class HarnessError(RuntimeError):
    pass


def built_runtime(test):
    source = os.environ.get("AGENT_WORK_RUNTIME_SOURCE")
    if not source:
        test.skipTest("set AGENT_WORK_RUNTIME_SOURCE to a built R checkout")
    runtime = Path(source).resolve()
    stamp = json.loads((runtime / "dist/.buildstamp").read_text())
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=runtime, text=True).strip()
    test.assertEqual(stamp["head"], head, "R buildstamp is stale for this checkout")
    return runtime


class LoopGateway:
    """The cli_gateway harness, configured for main's loop session and a counting provider."""

    def __init__(self, runtime, root, reuse_state=False, extra_env=None):
        # reuse_state starts a second Gateway process over the first one's durable state.
        self.state_dir = root / "gateway"
        self.state_dir.mkdir(exist_ok=reuse_state)
        token = "main-cli-loop-isolated-token"
        self.env = {**os.environ, "AGENT_WORK_RUNTIME_SOURCE": str(runtime),
                    "OPENCLAW_STATE_DIR": str(self.state_dir),
                    "OPENCLAW_CONFIG_PATH": str(self.state_dir / "openclaw.json"),
                    "OPENCLAW_GATEWAY_TOKEN": token, "CROSS_GATEWAY_TOKEN": token,
                    "CROSS_REQUESTER_AGENT_ID": "main",
                    "CROSS_REQUESTER_SESSION_KEY": LOOP_SESSION,
                    "CROSS_HOST_ID": HOST_ID, "CROSS_HOST_ADAPTER": ADAPTER,
                    "CROSS_PROVIDER": "loopback", **(extra_env or {})}
        self.process = subprocess.Popen(
            ["node", "--import", str(runtime / "scripts/tsx.mjs"), str(FIXTURE)],
            cwd=runtime, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        self.output = queue.Queue()
        self.logs = []
        threading.Thread(target=self._collect, daemon=True).start()
        try:
            ready = self._message()
            self.url, self.pid = ready["url"], ready["pid"]
        except BaseException:
            self.close()
            raise

    def _collect(self):
        for line in self.process.stdout:
            self.logs.append(line)
            self.output.put(line)

    def _message(self):
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            try:
                line = self.output.get(timeout=1)
            except queue.Empty:
                if self.process.poll() is not None:
                    break
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if value.get("type") == "error":
                raise HarnessError(value.get("error"))
            if value.get("type") in ("ready", "result"):
                return value
        raise HarnessError("R Gateway fixture stopped or timed out: " + "".join(self.logs)[-4000:])

    def call(self, op, **fields):
        self.process.stdin.write(json.dumps({"op": op, **fields}) + "\n")
        self.process.stdin.flush()
        return self._message()["result"]

    def tool(self, action, args, run_id, session_key=None):
        fields = {"action": action, "args": args, "runId": run_id}
        if session_key is not None:
            fields["sessionKey"] = session_key
        return self.call("tool", **fields)

    def provider_requests(self):
        return self.call("provider")["requests"]

    def kill(self):
        """The Gateway dies without a clean stop, as in a crash."""
        self.process.kill()
        self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write('{"op":"stop"}\n')
                self.process.stdin.flush()
                self.process.wait(timeout=30)
            except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
                self.process.terminate()
                self.process.wait(timeout=5)
        self.process.stdin.close()
        self.process.stdout.close()


def wait_for(predicate, timeout):
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(0.25)


def loop_route(root, instruction_root):
    brief = root / "brief.txt"
    brief.write_bytes(BRIEF)
    return dict(requester="main", target=f"{HOST_ID}/{ADAPTER}", key="encargos-loop-review",
                brief=brief, instruction_root=instruction_root,
                input_revision={"kind": "code", "repository": "fixture", "sha": "a" * 40},
                result_contract="review.v1")


def certified_coverage():
    coverage = json.loads((ROOT / "docs/evidence/agent-work/coverage.json").read_text())
    certified = copy.deepcopy(coverage)
    certified["hostAdapterCoverage"][HOST_ID][ADAPTER] = "certified"
    return coverage, certified


class MainCliLoopE2E(unittest.TestCase):
    def test_loop_session_requests_cli_and_only_its_session_wakes(self):
        runtime = built_runtime(self)
        with tempfile.TemporaryDirectory(prefix="agent-work-main-cli-loop-") as temporary:
            root = Path(temporary)
            gateway = LoopGateway(runtime, root)
            try:
                coverage, certified = certified_coverage()
                route = loop_route(root, gateway.state_dir)
                with self.assertRaisesRegex(RouteUnavailable, "not certified"):
                    prepare_request(coverage=coverage, **route)
                request = prepare_request(coverage=certified, **route)
                self.assertEqual(request["assignment"]["target"],
                                 {"kind": "cli", "hostId": HOST_ID, "adapterId": ADAPTER})
                client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), HOST_ID, gateway.url)
                host = Host(HOST_ID, root / "host")
                backend = FakeCliSession()
                manager = ResourceManager(host.spool, HOST_ID, backend)
                with mock.patch.dict(os.environ, gateway.env):
                    submitted = gateway.tool("submit", request, "loop-submit-turn")
                    task_id = submitted["taskId"]
                    context_key = f"task:{task_id}"
                    self.assertEqual(submitted["state"], "registered")
                    admitted = gateway.tool("admit", {"taskId": task_id,
                                                      "admissionKey": "encargos-loop-attempt"},
                                            "loop-admit-turn")
                    self.assertEqual(admitted["state"], "host-pending")
                    window_opened = time.time()
                    window_start = len(gateway.provider_requests())

                    delivered = []

                    def fake_cli(assignment_ref, session):
                        operation = json.loads(Path(assignment_ref).read_text())
                        delivered.append((operation, session))
                        # The CLI takes the assignment with its own acceptance before working.
                        atomic_json(Path(operation["acceptRef"]), {
                            "schema": "agent-work.accept.v1", **{field: operation[field] for field in (
                                "hostId", "taskId", "generation", "instanceId", "claimId", "capability")}})

                    first = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                           instance_id=INSTANCE, session=CLI_SESSION,
                                           workspace_root=root / "workspace", deliver=fake_cli,
                                           coverage=certified)
                    self.assertEqual(first.status, "delivered")
                    self.assertEqual([(op["taskId"], session) for op, session in delivered],
                                     [(task_id, CLI_SESSION)])
                    operation = delivered[0][0]
                    # The CLI works. No session wake and no provider request may happen meanwhile.
                    working_until = time.monotonic() + CLI_WORK_SECONDS
                    while time.monotonic() < working_until:
                        self.assertEqual(gateway.call("deliveries"), [])
                        time.sleep(0.5)
                    artifact = root / "workspace" / "review.txt"
                    artifact.write_text("VEREDICTO aprobado\n")
                    atomic_json(Path(operation["resultRef"]), {
                        "schema": "agent-work.result.v1", "kind": "produced",
                        "hostId": operation["hostId"], "taskId": operation["taskId"],
                        "generation": operation["generation"],
                        "instanceId": operation["instanceId"],
                        "producerId": operation["producerId"],
                        "capability": operation["capability"],
                        "observedRevision": operation["inputRevision"],
                        "typedPayload": {"verdict": "approved", "evidenceRef": "review.txt"},
                        "artifactRef": str(artifact),
                        "digest": hashlib.sha256(artifact.read_bytes()).hexdigest(),
                    })
                    in_window = gateway.provider_requests()[window_start:]
                    window_seconds = time.time() - window_opened
                    self.assertEqual(in_window, [], "provider requests while the CLI worked")

                    receipts = host.flush(HOST_ID, client.report_host_result)
                    self.assertEqual(len(receipts), 1)
                    key = OperationKey(HOST_ID, task_id, receipts[0]["generation"], INSTANCE)
                    closed = manager.close(key, {"kind": "result", "receipt": receipts[0]["receiptId"]})
                    self.assertEqual(closed.state, "ReleasedAdopted")
                    self.assertEqual(backend.stops, [])
                    self.assertEqual(len(backend.revocations), 1)
                    self.assertIsNotNone(backend.observe(CLI_SESSION))

                    # Positive control: the same counter sees the requester's wake after the report.
                    wakes = wait_for(lambda: [r for r in gateway.provider_requests()
                                              if task_id in r["wakeTasks"]], 30)
                    self.assertTrue(wakes, "the report never woke the requester session; "
                                    f"session queue: {gateway.call('deliveries')}")
                    # The Gateway processes the wake itself: the turn starts with this task's
                    # delivery in flight toward the submitting session, then settles it.
                    in_flight = wakes[0]["startedDeliveries"]
                    self.assertEqual([(row["sessionKey"], row["contextKey"]) for row in in_flight],
                                     [(LOOP_SESSION, context_key)])
                    wake_id = hashlib.sha256(
                        f"managed-task-result:{task_id}:{receipts[0]['generation']}".encode()
                    ).hexdigest()
                    deliveries = wait_for(lambda: [
                        (row["id"], row["status"]) for row in gateway.call("deliveries")
                        if row["status"] != "pending"], 15)
                    self.assertEqual(deliveries, [(wake_id, "completed")])
                    self.assertEqual(len(gateway.call("deliveries")), 1)
                    # From the durable wake row to the provider, on the Gateway clock: a wake
                    # raised while the CLI worked would have reached the counter in the window.
                    latency = (wakes[0]["at"] - in_flight[0]["enqueuedAt"]) / 1000
                    self.assertLess(latency, window_seconds,
                                    "the CLI window is too short to have caught a wake")
                    sessions = gateway.call("sessions")
                    self.assertEqual(sessions, [LOOP_SESSION])
                    for foreign in FOREIGN_SESSIONS:
                        self.assertNotIn(foreign, sessions)
                    self.assertFalse([s for s in sessions if s.startswith(FOREIGN_PREFIX)])

                    snapshot = gateway.tool("inspect", {"taskId": task_id}, "loop-inspect-turn")
                    self.assertEqual(snapshot["handlingState"], "pending-handling")
                    self.assertEqual(snapshot["result"]["payload"]["verdict"], "approved")
                    decision = {"kind": "blocked", "reason": "fixture-review-complete"}
                    gateway.tool("resolve", {"receipt": snapshot["resultReceipt"],
                                             "decision": decision}, "loop-resolve-turn")
                    final = gateway.tool("inspect", {"taskId": task_id}, "loop-final-inspect-turn")
                    self.assertEqual(final["handlingState"], "handled")
                    after_report = gateway.provider_requests()[window_start:]
                    self.assertEqual(after_report, wakes, "the report woke a model more than once")
                    self.assertEqual(len(wakes), 1)
                    self.assertEqual(len(delivered), 1)
                    print(f"MAIN_CLI_LOOP_E2E requester={LOOP_SESSION} submit=1 admit=1 delivery=1 "
                          f"window_s={window_seconds:.1f} window_provider_requests={len(in_window)} "
                          f"report=1 wake_latency_s={latency:.2f} wake_requests={len(wakes)} "
                          f"provider_after_report={len(after_report)} session_queue={deliveries} "
                          f"sessions={sessions} close={closed.state} stops={len(backend.stops)}",
                          flush=True)
            finally:
                gateway.close()

    def test_isolated_cron_run_cannot_submit(self):
        runtime = built_runtime(self)
        with tempfile.TemporaryDirectory(prefix="agent-work-main-cli-cron-") as temporary:
            root = Path(temporary)
            gateway = LoopGateway(runtime, root)
            try:
                _, certified = certified_coverage()
                request = prepare_request(coverage=certified, **loop_route(root, gateway.state_dir))
                cron_run = f"agent:main:cron:encargos-vigia:run:{uuid.uuid4()}"
                with self.assertRaises(HarnessError) as refused:
                    gateway.tool("submit", request, "cron-submit-turn", session_key=cron_run)
                self.assertIn(CRON_REFUSAL, str(refused.exception))
                self.assertEqual(gateway.call("deliveries"), [])
                self.assertEqual(gateway.provider_requests(), [])
                # The refusal left nothing: the durable loop session registers the same key fresh.
                accepted = gateway.tool("submit", request, "loop-submit-turn")
                self.assertEqual(accepted["state"], "registered")
                print(f"MAIN_CLI_LOOP_CRON_REFUSED session={cron_run} refused=1 "
                      f"loop_submit={accepted['state']}", flush=True)
            finally:
                gateway.close()


if __name__ == "__main__":
    unittest.main()

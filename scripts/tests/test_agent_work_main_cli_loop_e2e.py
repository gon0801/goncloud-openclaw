#!/usr/bin/env python3
"""main_cli_loop: the R Gateway harness of main's durable loop session, and what it refuses.

The R Gateway runs in-process in the harness with a loopback model provider that
counts every request.
"""

import copy
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


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from routing import prepare_request  # noqa: E402

FIXTURE = ROOT / "scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs"
LOOP_SESSION = "agent:main:encargos-loop"
HOST_ID, ADAPTER = "mac-local", "fixture-cli-b"  # id de juguete (SUA-04, 4.6): ningún host implementa claude_opus
# Same bytes as the harness fixture brief, so its artifact resolver accepts the digest.
BRIEF = b"Review the fixture change and return one verdict.\n"
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
    """The R Gateway harness, configured for main's loop session and a counting provider."""

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

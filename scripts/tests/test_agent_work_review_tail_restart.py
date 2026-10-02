#!/usr/bin/env python3
"""A review survives a lost tmux tail and a new director process."""

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "scripts/tests/fixtures/agent-work/managed-task-gateway-harness.mjs"


class ReviewTailRestartTest(unittest.TestCase):
    def test_review_tail_restart(self):
        runtime_source = os.environ.get("AGENT_WORK_RUNTIME_SOURCE")
        if not runtime_source:
            self.skipTest("set AGENT_WORK_RUNTIME_SOURCE to the built R source checkout")
        runtime = Path(runtime_source).resolve()
        for required in ("openclaw.mjs", "scripts/tsx.mjs", "src/gateway/test-helpers.e2e.ts"):
            self.assertTrue((runtime / required).is_file(), f"R source missing {required}")
        self.assertIsNotNone(shutil.which("tmux"), "tmux is required for this E2E case")

        with tempfile.TemporaryDirectory(prefix="agent-work-review-tail-") as temporary:
            state = Path(temporary)
            gateway_state = state / "gateway"
            gateway_state.mkdir()
            token = "review-tail-restart-isolated-token"
            output = queue.Queue()
            logs = []
            harness = subprocess.Popen(
                ["node", "--import", str(runtime / "scripts/tsx.mjs"), str(FIXTURE)],
                cwd=runtime,
                env={**os.environ, "AGENT_WORK_RUNTIME_SOURCE": str(runtime),
                     "OPENCLAW_STATE_DIR": str(gateway_state),
                     "OPENCLAW_CONFIG_PATH": str(gateway_state / "openclaw.json"),
                     "OPENCLAW_GATEWAY_TOKEN": token, "CROSS_GATEWAY_TOKEN": token},
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )

            def collect():
                for line in harness.stdout:
                    logs.append(line)
                    output.put(line)

            threading.Thread(target=collect, daemon=True).start()

            def message():
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    try:
                        line = output.get(timeout=1)
                    except queue.Empty:
                        if harness.poll() is not None:
                            break
                        continue
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if value.get("type") in ("ready", "result", "error"):
                        self.assertNotEqual(value["type"], "error", value.get("error"))
                        return value
                captured = []
                while not output.empty():
                    captured.append(output.get_nowait())
                self.fail("R Gateway harness did not answer or exited: " + "".join(logs)[-4000:])

            def request(command):
                harness.stdin.write(json.dumps(command) + "\n")
                harness.stdin.flush()
                return message()["result"]

            socket = "agent-work-tail-" + str(os.getpid())
            tmux = ["tmux", "-L", socket]
            try:
                ready = message()
                self.assertEqual(ready["type"], "ready")
                caller = {"kind": "director", "authority": "tail-director",
                          "corridaId": "tail-run", "decisionId": "tail-decision",
                          "fence": "tail-fence"}
                seeded = request({"op": "seed", "caller": caller,
                                  "payload": {"verdict": "changes", "findingsRef": "artifact:findings"},
                                  "budgetProfile": {
                                      "maxConcurrentTasks": 8, "maxDepth": 8, "maxChildren": 4,
                                      "maxModelCalls": 32, "maxInputTokens": 1000000,
                                      "maxOutputTokens": 100000, "maxCacheReadTokens": 1000000,
                                      "maxContextTokens": 100000, "maxTreeTokens": 1100000,
                                      "maxAutomaticRecoveryCalls": 1,
                                  }})
                task_id = seeded["task"]["taskId"]
                before = request({"op": "inspect", "caller": caller, "taskId": task_id})
                self.assertEqual(before["handlingState"], "pending-handling")
                self.assertEqual(before["result"]["payload"]["verdict"], "changes")

                # The review is genuinely outside the requester's visible tail.
                subprocess.run(tmux + ["new-session", "-d", "-s", "requester", "-x", "100",
                                       "-y", "40", "bash", "--noprofile", "--norc"], check=True)
                subprocess.run(tmux + ["send-keys", "-t", "requester",
                                       "printf 'REVIEW_RESULT_VISIBLE_ONCE\\n'; for i in {1..120}; do printf 'later-line-%03d\\n' \"$i\"; done",
                                       "Enter"], check=True)
                for _ in range(50):
                    tail = subprocess.check_output(
                        tmux + ["capture-pane", "-p", "-S", "-80", "-t", "requester"], text=True)
                    if "later-line-120" in tail:
                        break
                    time.sleep(0.1)
                self.assertIn("later-line-120", tail)
                self.assertNotIn("REVIEW_RESULT_VISIBLE_ONCE", tail)
                subprocess.run(tmux + ["kill-session", "-t", "requester"], check=True)

                # A fresh requester process consumes the native snapshot. The
                # observation is built from inspect, never from the seed reply.
                snapshot = request({"op": "inspect", "caller": caller, "taskId": task_id})
                self.assertEqual(snapshot["handlingState"], "pending-handling")
                receipt = snapshot["resultReceipt"]
                result = snapshot["result"]
                self.assertEqual(receipt["taskId"], task_id)
                self.assertEqual(result["payload"]["findingsRef"], "artifact:findings")
                correction = {
                    "target": {"kind": "agent", "agentId": "ingenieria"},
                    "instructionRef": {"ref": result["payload"]["findingsRef"], "digest": "sha256:findings"},
                    "inputRevision": result["observedRevision"],
                    "resultContract": "review.v1",
                    "continuation": {"kind": "requester"},
                }
                run_dir = state / "tail-run"
                run_dir.mkdir()
                record = run_dir / "registro.json"
                record.write_text(json.dumps({"schema": "corrida.v2", "id": "tail-run",
                                              "estado": "abierta",
                                              "lanes": [{"id": "l1", "estado": "activo", "events": []}]}))
                observation = state / "observation.json"
                observation.write_text(json.dumps({"lanes": {"l1": {"managed_task": {
                    "caller": caller, "receipt": receipt,
                    "result": {"kind": result["kind"],
                               "observedRevision": result["observedRevision"],
                               "typedPayload": result["payload"],
                               "artifactRef": result["artifactRef"]},
                    "correctionAssignment": correction,
                }}}}))
                env = {**os.environ, "CORRIDA_STATE": str(state), "CORR_REPO_RAIZ": str(ROOT),
                       "OPENCLAW_BIN": str(runtime / "openclaw.mjs"),
                       "OPENCLAW_EXPECT_URL": ready["url"], "OPENCLAW_GATEWAY_TOKEN": token,
                       "OPENCLAW_CONFIG_PATH": str(gateway_state / "openclaw.json"),
                       "OPENCLAW_STATE_DIR": str(gateway_state), "CORR_TOPE_RED": "30"}
                command = ["bash", str(ROOT / "scripts/mac/corrida.sh"), "reconciliar",
                           "tail-run", "--observations", str(observation)]
                resumed = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                         text=True, timeout=120)
                self.assertEqual(resumed.returncode, 0, resumed.stdout + resumed.stderr)
                events = json.loads(record.read_text())["lanes"][0]["events"]
                self.assertEqual([event["kind"] for event in events],
                                 ["intent.task_handling", "observed.task_handled"])
                self.assertEqual(events[0]["payload"]["decision"]["kind"], "continue")
                self.assertEqual(events[0]["payload"]["decision"]["children"][0]["slot"], "corregir")
                accepted = request({"op": "inspect", "caller": caller, "taskId": task_id})
                self.assertEqual(accepted["handlingState"], "handled")
                self.assertEqual(accepted["handlingDecision"], events[0]["payload"]["decision"])
                self.assertEqual(len(accepted["handlingReceipt"]["childTaskIds"]), 1)
                print("REVIEW_TAIL_RESTART native_result=changes tail_lines=80 correction_children=1", flush=True)
            finally:
                subprocess.run(tmux + ["kill-server"], capture_output=True)
                if harness.poll() is None:
                    try:
                        request({"op": "stop"})
                        harness.wait(timeout=30)
                    except (BrokenPipeError, OSError, AssertionError, subprocess.TimeoutExpired):
                        harness.terminate()
                        harness.wait(timeout=5)
                harness.stdin.close()
                harness.stdout.close()


if __name__ == "__main__":
    unittest.main()

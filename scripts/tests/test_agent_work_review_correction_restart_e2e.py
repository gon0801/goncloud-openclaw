#!/usr/bin/env python3
"""review_tail_restart: the reviewer's verdict leaves the last 80 lines, the Gateway crashes,
and the requester still registers and admits one correction that the CLI accepts.

The reviewer is a CLI double in a real tmux pane. The requester's model is the harness provider,
scripted: it wakes on the durable result, inspects it, resolves it with one correction child and
admits that child. Nobody reminds it: the test never calls inspect, resolve or admit after the
restart.
"""

import faulthandler
import os
from pathlib import Path
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
from contracts import OperationKey  # noqa: E402
from host import Host, TmuxTransport  # noqa: E402
from native_gateway import GatewayProjectionClient, claim_cli_once  # noqa: E402
from resources import ResourceManager, TmuxBackend  # noqa: E402
from routing import prepare_request  # noqa: E402
from test_agent_work_main_cli_loop_e2e import (  # noqa: E402
    ADAPTER, HOST_ID, LoopGateway, built_runtime, certified_coverage, loop_route, wait_for)

REVIEW_CLI = ROOT / "scripts/tests/fixtures/agent-work/review-cli.py"
VERDICT = "VEREDICTO cambios: falta la prueba del borde"
SCRIPTED = {"CROSS_TOOLS_PROFILE": "full", "CROSS_PROVIDER_SCRIPT": "review-correction"}
REVIEWED_SHA = "a" * 40
# A hung Gateway or pane must fail the run, never stall it.
RUN_LIMIT_SECONDS = 600


class ReviewCli:
    """The reviewer double on its own tmux server, started without the user's tmux config."""

    session = "review-cli"

    def __init__(self):
        self.tmux = shutil.which("tmux")
        self.socket = f"agent-work-review-{os.getpid()}-{secrets.token_hex(4)}"
        self.socket_file = (Path(os.environ.get("TMUX_TMPDIR") or "/tmp")
                            / f"tmux-{os.getuid()}" / self.socket)
        started = self._tmux("new-session", "-d", "-s", self.session, "-x", "200", "-y", "50",
                             sys.executable, "-u", str(REVIEW_CLI))
        if started.returncode:
            raise RuntimeError("tmux could not start the reviewer double: " + started.stderr)
        if not wait_for(lambda: "review-cli ready" in self.capture("-50"), 15):
            self.close()
            raise RuntimeError("the reviewer double never painted its prompt")

    def _tmux(self, *args):
        return subprocess.run([self.tmux, "-f", "/dev/null", "-L", self.socket, *args],
                              capture_output=True, text=True)

    def capture(self, start):
        # "-80" is what the watcher's alert tells the agent to read (tmux-activity-watch.sh:664):
        # 80 history lines plus the 50-row screen, so "out of it" means out of the last 130 lines.
        return self._tmux("capture-pane", "-p", "-t", f"={self.session}:", "-S", start).stdout

    def close(self):
        self._tmux("kill-server")
        if self.socket_file.exists():
            self.socket_file.unlink()


class ReviewTailRestartE2E(unittest.TestCase):
    def test_verdict_out_of_the_tail_and_a_crash_still_give_one_accepted_correction(self):
        runtime = built_runtime(self)
        if not shutil.which("tmux"):
            raise AssertionError("review_tail_restart runs the reviewer double in a real tmux pane")
        with tempfile.TemporaryDirectory(prefix="agent-work-review-tail-") as temporary:
            root = Path(temporary)
            _, certified = certified_coverage()
            cli = ReviewCli()
            self.addCleanup(cli.close)
            host = Host(HOST_ID, root / "host")
            manager = ResourceManager(host.spool, HOST_ID, TmuxBackend(cli.tmux, cli.socket))
            deliver = TmuxTransport(cli.tmux, cli.socket).deliver
            first = LoopGateway(runtime, root, extra_env=SCRIPTED)
            try:
                request = prepare_request(coverage=certified, **loop_route(root, first.state_dir))
                with mock.patch.dict(os.environ, first.env):
                    task_id = first.tool("submit", request, "loop-submit-turn")["taskId"]
                    first.tool("admit", {"taskId": task_id, "admissionKey": "review-attempt"},
                               "loop-admit-turn")
                    client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), HOST_ID, first.url)
                    claimed = claim_cli_once(client, host=host, manager=manager, adapter_id=ADAPTER,
                                             instance_id="review-instance", session=cli.session,
                                             workspace_root=root / "workspace", deliver=deliver,
                                             coverage=certified)
                    self.assertIn(claimed.status, ("typed", "delivered"))
                    review_key = OperationKey(HOST_ID, task_id, 1, "review-instance")
                    self.assertTrue(wait_for(lambda: host.take_acceptance(HOST_ID, review_key), 15),
                                    f"the reviewer never accepted; pane={cli.capture('-50')!r}")
                    # A managed pane is invisible to the old watcher: nothing re-reviews it by looking.
                    self.assertEqual(cli._tmux("show-environment", "-t", f"={cli.session}",
                                               "AGENT_WORK_MANAGED").stdout.strip(),
                                     "AGENT_WORK_MANAGED=1", "the reviewer pane is visible to the watcher")
                    # The reviewer delivered: its verdict was printed and is no longer in the tail.
                    self.assertTrue(wait_for(lambda: VERDICT in cli.capture("-"), 15),
                                    "the reviewer never printed its verdict")
                    self.assertTrue(wait_for(lambda: "review-cli review done" in cli.capture("-80"), 15),
                                    "the reviewer never finished its output")
                    in_tail = VERDICT in cli.capture("-80")
                    self.assertFalse(in_tail, "the verdict is still in the last 80 lines")
            finally:
                first.kill()

            second = LoopGateway(runtime, root, reuse_state=True, extra_env=SCRIPTED)
            try:
                self.assertNotEqual(second.pid, first.pid, "the Gateway did not restart")
                before = second.call("tasks")
                self.assertEqual([(task["taskId"], task["hasResult"]) for task in before["tasks"]],
                                 [(task_id, False)], "the restart lost or changed the task")
                with mock.patch.dict(os.environ, second.env):
                    client = GatewayProjectionClient(str(runtime / "openclaw.mjs"), HOST_ID, second.url)
                    receipts = host.flush(HOST_ID, client.report_host_result)
                    self.assertEqual(len(receipts), 1)
                    closed = manager.close(review_key, {"kind": "result",
                                                        "receipt": receipts[0]["receiptId"]})
                    self.assertEqual(closed.state, "ReleasedAdopted")

                    rows = wait_for(lambda: (lambda value: value if value["children"] else None)(
                        second.call("tasks")), 60)
                    self.assertTrue(rows, f"the requester never resolved; provider: {second.provider_requests()}")
                    child = rows["children"][0]["childTaskId"]
                    # The correction reaches the same CLI and is accepted by it, not only by R.
                    def claim_correction():
                        # None while no admitted task waits for this host.
                        observed = claim_cli_once(
                            client, host=host, manager=manager, adapter_id=ADAPTER,
                            instance_id="correction-instance", session=cli.session,
                            workspace_root=root / "workspace", deliver=deliver, coverage=certified)
                        return observed is not None and observed.status in ("typed", "delivered")

                    corrected = wait_for(claim_correction, 60)
                    self.assertTrue(corrected, f"the correction was never claimed; provider: "
                                               f"{second.provider_requests()}")
                    child_key = OperationKey(HOST_ID, child, 1, "correction-instance")
                    accepted = wait_for(lambda: host.take_acceptance(HOST_ID, child_key), 15)
                    self.assertTrue(accepted, f"the CLI never accepted the correction; pane={cli.capture('-50')!r}")

                time.sleep(10)
                rows = second.call("tasks")
                self.assertEqual(rows["handlings"], [task_id])
                self.assertEqual([(c["parentTaskId"], c["slot"]) for c in rows["children"]],
                                 [(task_id, "corregir")])
                tasks = {task["taskId"]: task for task in rows["tasks"]}
                self.assertEqual({key: task["resultContract"] for key, task in tasks.items()},
                                 {task_id: "review.v1", child: "ready.v1"})
                root_assignment = request["assignment"]
                self.assertEqual(tasks[child]["inputRevision"], root_assignment["inputRevision"],
                                 "the correction is not on the reviewed revision")
                self.assertEqual(tasks[child]["target"], root_assignment["target"],
                                 "the correction goes to another target")
                reviews = [key for key, task in tasks.items() if task["resultContract"] == "review.v1"
                           and task["inputRevision"].get("sha") == REVIEWED_SHA]
                self.assertEqual(reviews, [task_id], "a new review of the same SHA was registered")
                requests = second.provider_requests()
                self.assertEqual(requests[0]["wakeTasks"], [task_id],
                                 "the requester acted before its durable wake")
                answered = [request["answered"] for request in requests]
                self.assertEqual(answered, ["managed_tasks_inspect", "managed_tasks_resolve",
                                            "managed_tasks_admit", "message"])
                self.assertIn("managed_tasks_resolve", requests[0]["toolNames"])
                print(f"REVIEW_TAIL_RESTART verdict_in_tail_80={int(in_tail)} pid1={first.pid} pid2={second.pid} "
                      f"handlings={len(rows['handlings'])} children={len(rows['children'])} "
                      f"correction_accepted={int(bool(accepted))} provider={answered}", flush=True)
            finally:
                second.close()


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

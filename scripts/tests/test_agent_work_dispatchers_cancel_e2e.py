#!/usr/bin/env python3
"""dispatchers_cancel: two dispatchers, a cancellation and a stale callback against a real R Gateway.

Two dispatchers register the same request, the CLI does the work, one dispatcher cancels, and
the Gateway dies with kill -9. On a second Gateway over the same state the other dispatcher, who
never saw the cancellation, admits and resolves again, and the host's callback for the cancelled
generation arrives late. The cancellation is the durable order everyone ends up under: one task,
no continuation of the cancelled generation, no second CLI delivery and no wake, counted from
outside the Gateway as in crash_boundaries.
"""

import faulthandler
import os
from pathlib import Path
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
# The module, not the class: a TestCase imported here would run all its cases too.
import test_agent_work_crash_boundaries_e2e as boundaries  # noqa: E402
from test_agent_work_crash_boundaries_e2e import HOST_ID, HarnessError, lines  # noqa: E402
from routing import prepare_request  # noqa: E402
from test_agent_work_main_cli_loop_e2e import loop_route  # noqa: E402

RUN_LIMIT_SECONDS = 900


class DispatchersCancelE2E(unittest.TestCase):
    # The same Gateway, host and counters as crash_boundaries, without inheriting its cases.
    setUp = boundaries.CrashBoundariesE2E.setUp
    gateway = boundaries.CrashBoundariesE2E.gateway
    crash = boundaries.CrashBoundariesE2E.crash
    client = boundaries.CrashBoundariesE2E.client
    claim = boundaries.CrashBoundariesE2E.claim
    review_done = boundaries.CrashBoundariesE2E.review_done
    wakes = boundaries.CrashBoundariesE2E.wakes

    def test_two_dispatchers_a_cancellation_and_a_stale_callback_keep_one_durable_order(self):
        first = self.gateway()
        try:
            request = prepare_request(coverage=self.certified, **loop_route(self.root, first.state_dir))
            with mock.patch.dict(os.environ, first.env):
                task_id = first.tool("submit", request, "dispatcher-1")["taskId"]
                try:
                    again = first.tool("submit", request, "dispatcher-2")["taskId"]
                except HarnessError as error:
                    self.fail(f"the second dispatcher could not recover the task: {error}")
                self.assertEqual(again, task_id, "the second dispatcher registered another task")
                first.tool("admit", {"taskId": task_id, "admissionKey": "dispatch-admission"}, "dispatcher-1-admit")
                self.assertIn(self.claim(self.client(first)).status, ("typed", "delivered"))
                self.review_done(task_id)
                first.tool("cancel", {"taskId": task_id, "reason": "dispatcher-1 withdrew"}, "dispatcher-1-cancel")
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            with mock.patch.dict(os.environ, second.env):
                # dispatcher-2 never saw the cancellation and repeats its own steps.
                with self.assertRaisesRegex(HarnessError, "Managed task is not awaiting an agent result",
                                            msg="the readmission of the cancelled task was not refused for the cancellation"):
                    second.tool("admit", {"taskId": task_id, "admissionKey": "dispatcher-2-admission"},
                                "dispatcher-2-admit")
                claims = [self.claim(self.client(second)) for _ in range(3)]
                self.assertEqual(claims, [None, None, None], "the host was offered the cancelled task again")
                # The host's callback for the cancelled generation arrives late.
                receipts = self.host.flush(HOST_ID, self.client(second).report_host_result)
                self.assertEqual([(r["taskId"], r["generation"]) for r in receipts], [(task_id, 1)],
                                 "the stale callback was not taken")
                snapshot = second.tool("inspect", {"taskId": task_id}, "dispatcher-2-inspect")
                self.assertEqual((snapshot["handlingState"], snapshot["deliveryState"]),
                                 ("cancelled", "result-recorded"), "the stale callback reopened the task")
                assignment = request["assignment"]
                continuation = {"kind": "continue", "children": [{"slot": "corregir", "assignment": {
                    "target": assignment["target"], "instructionRef": assignment["instructionRef"],
                    "inputRevision": assignment["inputRevision"], "resultContract": "ready.v1",
                    "continuation": {"kind": "requester"}}}]}
                with self.assertRaisesRegex(HarnessError, "Managed task is cancelled",
                                            msg="the cancelled generation accepted a continuation"):
                    second.tool("resolve", {"receipt": snapshot["resultReceipt"], "decision": continuation},
                                "dispatcher-2-resolve")
            time.sleep(boundaries.SETTLE_SECONDS)
            rows = second.call("tasks")
            self.assertEqual([(t["taskId"], t["hasResult"]) for t in rows["tasks"]], [(task_id, True)],
                             "the dispatchers left more than one task")
            self.assertEqual((rows["handlings"], rows["children"]), ([], []), "the cancellation left a continuation")
            cli = lines(self.cli_log)
            self.assertEqual([(e["taskId"], e["generation"]) for e in cli if e["event"] == "accepted"],
                             [(task_id, 1)], "the CLI was handed the work more than once")
            self.assertEqual(self.wakes(task_id), [], "a cancelled task woke a dispatcher")
            self.assertEqual(self.host.pending(HOST_ID), [], "the host still holds the stale callback")
            print(f"DISPATCHERS_CANCEL pids={self.pids} tasks={len(rows['tasks'])} handling={snapshot['handlingState']} "
                  f"children={len(rows['children'])} cli_accepted={len([e for e in cli if e['event'] == 'accepted'])} "
                  f"wakes={len(self.wakes(task_id))}", flush=True)
        finally:
            second.close()


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

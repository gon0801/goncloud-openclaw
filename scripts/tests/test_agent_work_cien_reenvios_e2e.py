#!/usr/bin/env python3
"""cien_reenvios: the same CLI result reported a hundred times against a real R Gateway.

The host reports one result and loses every acknowledgement but the last, so it repeats the
same report: fifty times to a first Gateway, which then dies with kill -9, and fifty more to a
second one over the same state. The domain result must not move: one task with its result,
the same receipt every time, one CLI delivery and one wake of the requester, counted from
outside the Gateway as in crash_boundaries.
"""

import faulthandler
import os
import time
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
# The module, not the class: a TestCase imported here would run all its cases too.
import test_agent_work_crash_boundaries_e2e as boundaries  # noqa: E402
from contracts import OperationKey  # noqa: E402
from test_agent_work_crash_boundaries_e2e import HOST_ID, LostAck, lines, wait_for  # noqa: E402
import native_gateway  # noqa: E402

REPORTS = 100
RUN_LIMIT_SECONDS = 900


class CienReenviosE2E(unittest.TestCase):
    # The same Gateway, host and counters as crash_boundaries, without inheriting its cases.
    setUp = boundaries.CrashBoundariesE2E.setUp
    gateway = boundaries.CrashBoundariesE2E.gateway
    crash = boundaries.CrashBoundariesE2E.crash
    client = boundaries.CrashBoundariesE2E.client
    claim = boundaries.CrashBoundariesE2E.claim
    review_done = boundaries.CrashBoundariesE2E.review_done
    reviewed = boundaries.CrashBoundariesE2E.reviewed
    wakes = boundaries.CrashBoundariesE2E.wakes
    assert_domain = boundaries.CrashBoundariesE2E.assert_domain

    def repeat(self, gateway, times, receipts):
        """Report the pending result `times` times, losing every acknowledgement."""
        client = self.client(gateway)

        def report_then_lose_the_ack(result, artifact):
            receipts.append(client.report_host_result(result, artifact))
            raise LostAck("the acknowledgement never reached the host")

        with mock.patch.dict(os.environ, gateway.env):
            for _ in range(times):
                try:
                    with self.assertRaises(LostAck):
                        self.host.flush(HOST_ID, report_then_lose_the_ack)
                except RuntimeError as error:
                    self.fail(f"R refused a repeated report: {error}")
                self.assertTrue(self.host.pending(HOST_ID), "the host dropped a result it never saw acknowledged")

    def test_the_same_result_reported_a_hundred_times_across_a_crash_is_recorded_once(self):
        receipts, sent = [], []
        real_run = native_gateway.subprocess.run

        def run(command, *args, **kwargs):
            # Counted below the client: a report counts only if its call to the Gateway ran.
            done = real_run(command, *args, **kwargs)
            if "managedTasks.host.report" in command and done.returncode == 0:
                sent.append(done)
            return done

        self.enterContext(mock.patch.object(native_gateway.subprocess, "run", run))
        first = self.gateway()
        try:
            task_id, _ = self.reviewed(first)
            self.repeat(first, REPORTS // 2, receipts)
            # The wake of the recorded result settles before the crash, so any later wake can
            # only come from a repeated report.
            self.assertTrue(wait_for(lambda: self.wakes(task_id), 60), "the first Gateway never woke the requester")
            self.assertTrue(wait_for(lambda: not [d for d in first.call("deliveries")
                                                  if d["managedTaskDelivery"]], 60),
                            f"the wake never settled: {first.call('deliveries')}")
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            self.repeat(second, REPORTS // 2 - 1, receipts)
            with mock.patch.dict(os.environ, second.env):
                try:
                    receipts += self.host.flush(HOST_ID, self.client(second).report_host_result)
                except RuntimeError as error:
                    self.fail(f"R refused a repeated report: {error}")
            self.assertEqual(len(receipts), REPORTS)
            self.assertEqual(len(sent), REPORTS, "a repeated report never reached the Gateway")
            self.assertEqual({r["receiptId"] for r in receipts}, {receipts[0]["receiptId"]},
                             "a repeated report got another receipt")
            self.assert_domain(second, task_id, "A2")
            reports = len(lines(self.provider_log))
            print(f"CIEN_REENVIOS reports={len(receipts)} receipts={len({r['receiptId'] for r in receipts})} "
                  f"wakes={len(self.wakes(task_id))} provider_requests={reports} sent={len(sent)} pids={self.pids}",
                  flush=True)
        finally:
            second.close()


    def test_a_report_with_the_same_id_and_another_digest_is_rejected(self):
        gateway = self.gateway()
        try:
            task_id, _ = self.reviewed(gateway)
            key = OperationKey(HOST_ID, task_id, 1, "crash-instance")
            self.assertEqual(len(self.host.pending(HOST_ID)), 1)
            result, artifact = self.host.result_snapshot(HOST_ID, key)
            with mock.patch.dict(os.environ, gateway.env):
                client = self.client(gateway)
                receipts = self.host.flush(HOST_ID, client.report_host_result)
            self.assertEqual(len(receipts), 1)
            original = receipts[0]["receiptId"]
            self.assertEqual(self.host.pending(HOST_ID), [], "the acknowledged result is still pending")
            # The same task with another digest: same identity, another payload, and the
            # artifact still matches the original digest on our side.
            forged = dict(result)
            forged["typedPayload"] = {"verdict": "changes", "findingsRef": "findings-b40.txt"}
            with mock.patch.dict(os.environ, gateway.env):
                # G's transport wraps every Gateway refusal alike; the conflict itself is pinned
                # by the refusal plus the original receipt kept below.
                with self.assertRaisesRegex(RuntimeError, "native projection Gateway rejected request",
                                            msg="R took a second digest for the same task"):
                    client.report_host_result(forged, artifact)
                snapshot = gateway.tool("inspect", {"taskId": task_id}, "inspect-turn")
            self.assertEqual(snapshot["resultReceipt"],
                             {"taskId": task_id, "generation": 1, "resultDigest": original},
                             "the rejected report moved the original receipt")
            self.assertTrue(wait_for(lambda: self.wakes(task_id), 60),
                            "the requester was never woken by the original report")
            time.sleep(boundaries.SETTLE_SECONDS)
            self.assertEqual(len(self.wakes(task_id)), 1,
                             "the rejected report woke the requester again")
            print(f"DIGEST_CONFLICT pids={self.pids} receipts=1 original_kept=1 wakes=1", flush=True)
        finally:
            gateway.close()


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

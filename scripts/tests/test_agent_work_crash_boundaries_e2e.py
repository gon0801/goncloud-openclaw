#!/usr/bin/env python3
"""crash_boundaries: the spec's crash boundaries against a real R Gateway that dies with kill -9.

Each case crashes the Gateway at one boundary, starts a second one over the same durable
state and checks the domain result: one task, one CLI delivery, one result with the same
receipt, and one wake of the requester. Two counters live outside the Gateway and survive
the crash: the provider appends every model request to a file, and the CLI double appends
every acceptance to another one.

Boundaries of docs/superpowers/specs/2026-09-30-encargos-agentes-design.md covered here:
- B1, before delivery: a second dispatcher recovers the task the dead one registered;
- B3, between admission and answer: the CLI already took the assignment, and the restart
  neither types it again nor admits it again;
- B4, between result and ACK: R recorded the result and the ACK was lost, so the host
  repeats the same report and gets the same receipt without a second wake;
- B5, between decision and its receipt: the requester's correction is committed and the
  Gateway dies before the model sees it, so the redelivered wake recovers the same child;
- B7, cancellation and a late result: the requester cancels, the Gateway dies, and the result
  that arrives afterwards is archived without waking anyone or allowing a continuation.
"""

import faulthandler
import json
import os
from pathlib import Path
import shutil
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
    ADAPTER, HOST_ID, HarnessError, LoopGateway, built_runtime, certified_coverage, loop_route, wait_for)
from test_agent_work_review_correction_restart_e2e import SCRIPTED, ReviewCli  # noqa: E402

RUN_LIMIT_SECONDS = 900
# After the last step, how long a late duplicate (a second wake or a second delivery) gets to show.
SETTLE_SECONDS = 20


def lines(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


class LostAck(Exception):
    pass


class CrashBoundariesE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        if not shutil.which("tmux"):
            raise AssertionError("crash_boundaries runs the CLI double in a real tmux pane")
        temporary = tempfile.TemporaryDirectory(prefix="agent-work-crash-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.provider_log = self.root / "provider.jsonl"
        self.cli_log = self.root / "cli.jsonl"
        _, self.certified = certified_coverage()
        self.cli = ReviewCli(str(self.cli_log))
        self.addCleanup(self.cli.close)
        self.host = Host(HOST_ID, self.root / "host")
        self.manager = ResourceManager(self.host.spool, HOST_ID, TmuxBackend(self.cli.tmux, self.cli.socket))
        self.deliver = TmuxTransport(self.cli.tmux, self.cli.socket).deliver
        self.pids = []

    def gateway(self, reuse_state=False, **env):
        gateway = LoopGateway(self.runtime, self.root, reuse_state=reuse_state,
                              extra_env={"CROSS_PROVIDER_LOG": str(self.provider_log), **env})
        self.pids.append(gateway.pid)
        return gateway

    def crash(self, gateway):
        gateway.kill()
        with self.assertRaises(ProcessLookupError, msg="the crashed Gateway is still alive"):
            os.kill(gateway.pid, 0)

    def client(self, gateway):
        return GatewayProjectionClient(str(self.runtime / "openclaw.mjs"), HOST_ID, gateway.url)

    def claim(self, client, instance_id="crash-instance"):
        return claim_cli_once(client, host=self.host, manager=self.manager, adapter_id=ADAPTER,
                              instance_id=instance_id, session=self.cli.session,
                              workspace_root=self.root / "workspace", deliver=self.deliver,
                              coverage=self.certified)

    def review_done(self, task_id):
        """The CLI accepted the assignment and left its result file; nothing is reported yet."""
        key = OperationKey(HOST_ID, task_id, 1, "crash-instance")
        self.assertTrue(wait_for(lambda: self.host.take_acceptance(HOST_ID, key), 15),
                        f"the CLI never accepted; pane={self.cli.capture('-50')!r}")
        self.assertTrue(wait_for(lambda: "review-cli review done" in self.cli.capture("-"), 15),
                        "the CLI never finished its review")
        self.assertTrue(wait_for(lambda: self.host.pending(HOST_ID), 15), "the CLI left no result")
        return key

    def wakes(self, task_id):
        return [r for r in lines(self.provider_log) if task_id in r["wakeTasks"]]

    def assert_domain(self, gateway, task_id, boundary):
        """One task with its result, typed once into the CLI, and one wake of the requester."""
        self.assertTrue(wait_for(lambda: self.wakes(task_id), 60),
                        f"the requester was never woken; provider: {lines(self.provider_log)}")
        time.sleep(SETTLE_SECONDS)
        tasks = gateway.call("tasks")
        self.assertEqual([(t["taskId"], t["hasResult"]) for t in tasks["tasks"]], [(task_id, True)],
                         "the crash lost the result or registered another task")
        self.assertEqual(tasks["children"], [], "a child appeared without a decision")
        cli = lines(self.cli_log)
        self.assertEqual([(e["taskId"], e["generation"]) for e in cli if e["event"] == "accepted"],
                         [(task_id, 1)], "the CLI was handed the assignment more than once")
        wakes = self.wakes(task_id)
        self.assertEqual(len(wakes), 1, f"the requester was woken more than once: {wakes}")
        self.assertEqual(self.host.pending(HOST_ID), [], "the host still holds an unacknowledged result")
        requests = lines(self.provider_log)
        by_gateway = [sum(r["gatewayPid"] == pid for r in requests) for pid in self.pids]
        print(f"CRASH_BOUNDARY {boundary} pids={self.pids} tasks={len(tasks['tasks'])} "
              f"cli_accepted={len([e for e in cli if e['event'] == 'accepted'])} "
              f"wakes={len(wakes)} provider_by_gateway={by_gateway}", flush=True)

    def test_before_delivery_a_second_dispatcher_recovers_the_task(self):
        first = self.gateway()
        try:
            request = prepare_request(coverage=self.certified, **loop_route(self.root, first.state_dir))
            with mock.patch.dict(os.environ, first.env):
                task_id = first.tool("submit", request, "dispatcher-1")["taskId"]
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            with mock.patch.dict(os.environ, second.env):
                try:
                    again = second.tool("submit", request, "dispatcher-2")
                except HarnessError as error:
                    self.fail(f"a second dispatcher could not recover the task: {error}")
                self.assertEqual(again["taskId"], task_id, "a second dispatcher registered another task")
                second.tool("admit", {"taskId": task_id, "admissionKey": "crash-admission"}, "admit-turn")
                client = self.client(second)
                self.assertIn(self.claim(client).status, ("typed", "delivered"))
                self.review_done(task_id)
                receipts = self.host.flush(HOST_ID, client.report_host_result)
                self.assertEqual(len(receipts), 1)
            self.assert_domain(second, task_id, "B1")
        finally:
            second.close()

    def test_between_admission_and_answer_the_restart_never_hands_it_over_again(self):
        first = self.gateway()
        try:
            request = prepare_request(coverage=self.certified, **loop_route(self.root, first.state_dir))
            with mock.patch.dict(os.environ, first.env):
                task_id = first.tool("submit", request, "submit-turn")["taskId"]
                first.tool("admit", {"taskId": task_id, "admissionKey": "crash-admission"}, "admit-turn")
                self.assertIn(self.claim(self.client(first)).status, ("typed", "delivered"))
                self.review_done(task_id)
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            with mock.patch.dict(os.environ, second.env):
                client = self.client(second)
                # The host loop keeps claiming after the restart; R hands back the same claim and the
                # host sees it already delivered, so nothing is typed into the CLI again.
                claims = [self.claim(client).status for _ in range(3)]
                self.assertFalse({"typed", "delivered"} & set(claims), "the restart typed the assignment again")
                print(f"CLAIMS_AFTER_RESTART {claims}", flush=True)
                readmitted = second.tool("admit", {"taskId": task_id, "admissionKey": "crash-admission"},
                                         "admit-again-turn")
                self.assertEqual(readmitted, {"taskId": task_id, "state": "host-admitted"},
                                 "the restart admitted it again")
                receipts = self.host.flush(HOST_ID, client.report_host_result)
                self.assertEqual([(r["taskId"], r["generation"]) for r in receipts], [(task_id, 1)])
            self.assert_domain(second, task_id, "B3")
        finally:
            second.close()

    def test_between_result_and_ack_the_host_repeats_the_same_report(self):
        first = self.gateway()
        try:
            request = prepare_request(coverage=self.certified, **loop_route(self.root, first.state_dir))
            with mock.patch.dict(os.environ, first.env):
                task_id = first.tool("submit", request, "submit-turn")["taskId"]
                first.tool("admit", {"taskId": task_id, "admissionKey": "crash-admission"}, "admit-turn")
                client = self.client(first)
                self.assertIn(self.claim(client).status, ("typed", "delivered"))
                self.review_done(task_id)
                recorded = []

                def report_then_lose_the_ack(result, artifact):
                    recorded.append(client.report_host_result(result, artifact))
                    raise LostAck("the Gateway died before its answer reached the host")

                with self.assertRaises(LostAck):
                    self.host.flush(HOST_ID, report_then_lose_the_ack)
                self.assertEqual(len(recorded), 1)
                self.assertTrue(self.host.pending(HOST_ID), "the host dropped a result it never saw acknowledged")
                # The wake of the recorded result runs and settles before the crash, so a second
                # wake after the restart can only come from the repeated report.
                self.assertTrue(wait_for(lambda: self.wakes(task_id), 60), "the first Gateway never woke the requester")
                self.assertTrue(wait_for(lambda: not [d for d in first.call("deliveries")
                                                      if d["managedTaskDelivery"]], 60),
                                f"the wake never settled: {first.call('deliveries')}")
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            with mock.patch.dict(os.environ, second.env):
                try:
                    receipts = self.host.flush(HOST_ID, self.client(second).report_host_result)
                except RuntimeError as error:
                    self.fail(f"R refused the repeated report: {error}")
            self.assertEqual([r["receiptId"] for r in receipts], [recorded[0]["receiptId"]],
                             "the repeated report got another receipt")
            self.assert_domain(second, task_id, "B4")
        finally:
            second.close()

    def reviewed(self, gateway, admission_key="crash-admission"):
        """Submit, admit and let the CLI review; its result is left unreported on the host."""
        request = prepare_request(coverage=self.certified, **loop_route(self.root, gateway.state_dir))
        with mock.patch.dict(os.environ, gateway.env):
            task_id = gateway.tool("submit", request, "submit-turn")["taskId"]
            gateway.tool("admit", {"taskId": task_id, "admissionKey": admission_key}, "admit-turn")
            self.assertIn(self.claim(self.client(gateway)).status, ("typed", "delivered"))
            self.review_done(task_id)
        return task_id, request

    def test_between_decision_and_its_receipt_the_restart_recovers_the_same_child(self):
        first = self.gateway(**SCRIPTED, CROSS_PROVIDER_HOLD="admit")
        try:
            task_id, _ = self.reviewed(first)
            with mock.patch.dict(os.environ, first.env):
                receipts = self.host.flush(HOST_ID, self.client(first).report_host_result)
                self.assertEqual(len(receipts), 1)
                closed = self.manager.close(OperationKey(HOST_ID, task_id, 1, "crash-instance"),
                                            {"kind": "result", "receipt": receipts[0]["receiptId"]})
                self.assertEqual(closed.state, "ReleasedAdopted")
            # The model resolved and the decision is committed; its next request, the one that would
            # admit the child, is held, so the Gateway dies before the model sees the receipt.
            held = wait_for(lambda: [r for r in lines(self.provider_log)
                                     if r["answered"] == "managed_tasks_admit"], 60)
            self.assertTrue(held, f"the first Gateway never decided: {lines(self.provider_log)}")
            decided = first.call("tasks")
            self.assertEqual(decided["handlings"], [task_id], "the decision was not committed before the crash")
            self.assertEqual(len(decided["children"]), 1)
            child = decided["children"][0]["childTaskId"]
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True, **SCRIPTED)
        try:
            with mock.patch.dict(os.environ, second.env):
                client = self.client(second)

                def claim_correction():
                    observed = self.claim(client, "correction-instance")
                    return observed is not None and observed.status in ("typed", "delivered")

                self.assertTrue(wait_for(claim_correction, 90),
                                f"the correction was never admitted; provider: {lines(self.provider_log)}")
                key = OperationKey(HOST_ID, child, 1, "correction-instance")
                self.assertTrue(wait_for(lambda: self.host.take_acceptance(HOST_ID, key), 15),
                                "the CLI never accepted the correction")
            time.sleep(SETTLE_SECONDS)
            rows = second.call("tasks")
            self.assertEqual(rows["handlings"], [task_id])
            self.assertEqual([(c["parentTaskId"], c["slot"], c["childTaskId"]) for c in rows["children"]],
                             [(task_id, "corregir", child)], "the restart decided another correction")
            reviews = [t["taskId"] for t in rows["tasks"] if t["resultContract"] == "review.v1"]
            self.assertEqual(reviews, [task_id], "a new review of the same SHA was registered")
            cli = lines(self.cli_log)
            self.assertEqual([(e["taskId"], e["generation"]) for e in cli if e["event"] == "accepted"],
                             [(task_id, 1), (child, 1)], "the CLI did not get the review and one correction")
            acting = {pid: [r["answered"] for r in lines(self.provider_log)
                            if r["gatewayPid"] == pid and r["answered"] != "message"] for pid in self.pids}
            decide = ["managed_tasks_inspect", "managed_tasks_resolve", "managed_tasks_admit"]
            # The first admit was held and never ran; the redelivered wake decides again with the same keys.
            self.assertEqual(acting[first.pid], decide, "the first Gateway did not decide before the crash")
            self.assertEqual(acting[second.pid], decide, "the restart did not recover the decision")
            print(f"CRASH_BOUNDARY B5 pids={self.pids} handlings={len(rows['handlings'])} "
                  f"children={len(rows['children'])} cli_accepted={len([e for e in cli if e['event'] == 'accepted'])} "
                  f"acting_first={acting[first.pid]} acting_second={acting[second.pid]}", flush=True)
        finally:
            second.close()

    def test_a_cancellation_then_a_late_result_wakes_nobody(self):
        first = self.gateway()
        try:
            task_id, request = self.reviewed(first)
            with mock.patch.dict(os.environ, first.env):
                first.tool("cancel", {"taskId": task_id, "reason": "requester withdrew"}, "cancel-turn")
        finally:
            self.crash(first)
        second = self.gateway(reuse_state=True)
        try:
            with mock.patch.dict(os.environ, second.env):
                receipts = self.host.flush(HOST_ID, self.client(second).report_host_result)
                self.assertEqual([(r["taskId"], r["generation"]) for r in receipts], [(task_id, 1)],
                                 "the late result was not taken")
                snapshot = second.tool("inspect", {"taskId": task_id}, "inspect-turn")
                self.assertEqual((snapshot["handlingState"], snapshot["deliveryState"]),
                                 ("cancelled", "result-recorded"), "the late result was not archived as cancelled")
                assignment = request["assignment"]
                continuation = {"kind": "continue", "children": [{"slot": "corregir", "assignment": {
                    "target": assignment["target"], "instructionRef": assignment["instructionRef"],
                    "inputRevision": assignment["inputRevision"], "resultContract": "ready.v1",
                    "continuation": {"kind": "requester"}}}]}
                with self.assertRaisesRegex(HarnessError, "Managed task is cancelled",
                                            msg="the cancelled generation accepted a continuation"):
                    second.tool("resolve", {"receipt": snapshot["resultReceipt"], "decision": continuation},
                                "resolve-turn")
            time.sleep(SETTLE_SECONDS)
            self.assertEqual(self.wakes(task_id), [], "a cancelled task woke the requester")
            rows = second.call("tasks")
            self.assertEqual((rows["handlings"], rows["children"]), ([], []), "the cancellation left a continuation")
            cli = lines(self.cli_log)
            self.assertEqual([(e["taskId"], e["generation"]) for e in cli if e["event"] == "accepted"],
                             [(task_id, 1)], "the CLI was handed the assignment more than once")
            self.assertEqual(self.host.pending(HOST_ID), [], "the host still holds the late result")
            print(f"CRASH_BOUNDARY B7 pids={self.pids} handling={snapshot['handlingState']} "
                  f"delivery={snapshot['deliveryState']} wakes=0 children=0 "
                  f"cli_accepted={len([e for e in cli if e['event'] == 'accepted'])}", flush=True)
        finally:
            second.close()

if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

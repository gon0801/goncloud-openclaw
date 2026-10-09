#!/usr/bin/env python3
"""delivery_latency_r: the two legs of T10's delivery latency, on a real clock against a real R Gateway.

The CLI double writes its result (a rename without fsync, so the first leg errs long); the production pump (watch_pump, one-second poll) detects
it in a code-only pass and reports it to the Gateway; the host commits the receipt. Detection is
the first Host.report the pump makes for that result, as in the controlled-clock case
(delivery_latency); the receipt is the Spool.acknowledge commit. Each leg must stay within 5 s.

One real run proves both legs against R; it does not prove the worst case. A loop that skips
result scans can still pass here. The worst case under the designed poll is the controlled-clock
case (delivery_latency).
"""

import faulthandler
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
# The module, not the class: a TestCase imported here would run all its cases too.
import test_agent_work_crash_boundaries_e2e as boundaries  # noqa: E402
from test_agent_work_crash_boundaries_e2e import HOST_ID, wait_for  # noqa: E402
from contracts import OperationKey, operation_id  # noqa: E402
from host import Host  # noqa: E402
from native_gateway import watch_pump  # noqa: E402

LIMIT_SECONDS = 5
RUN_LIMIT_SECONDS = 600


class DeliveryLatencyR(unittest.TestCase):
    # The same Gateway, host and CLI double as crash_boundaries, without inheriting its cases.
    setUp = boundaries.CrashBoundariesE2E.setUp
    gateway = boundaries.CrashBoundariesE2E.gateway
    client = boundaries.CrashBoundariesE2E.client
    claim = boundaries.CrashBoundariesE2E.claim
    submitted = boundaries.CrashBoundariesE2E.submitted

    def test_report_detected_and_receipted_within_five_seconds_each_against_r(self):
        times = {}

        class TimedHost(Host):
            def report(self, host_id, value):
                times.setdefault("detected", time.time())
                return super().report(host_id, value)

        gateway = self.gateway()
        try:
            task_id = self.submitted(gateway)
            key = OperationKey(HOST_ID, task_id, 1, "crash-instance")
            host = TimedHost(HOST_ID, self.root / "host")
            acknowledge = host.spool.acknowledge

            def timed_acknowledge(op_id, receipt):
                acknowledge(op_id, receipt)
                times.setdefault("receipt_persisted", time.time())

            host.spool.acknowledge = timed_acknowledge
            stop = threading.Event()
            with mock.patch.dict(os.environ, gateway.env), tempfile.TemporaryDirectory() as progress:
                client = self.client(gateway)
                pump = threading.Thread(target=watch_pump, args=(client,), kwargs=dict(
                    host=host, evidence_root=progress, progress_state_dir=progress,
                    progress_client=str(Path(progress) / "unused-progress-client"), stop_event=stop))
                pump.start()
                try:
                    self.assertIn(self.claim(client).status, ("typed", "delivered"))
                    self.assertTrue(wait_for(lambda: "receipt_persisted" in times, 60),
                                    f"the pump never committed a receipt: {times}")
                finally:
                    stop.set()
                    pump.join(60)
            result_ref = Path(json.loads(host.spool.get(operation_id(key))["operation_json"])["resultRef"])
            times["written"] = result_ref.stat().st_mtime
            detection = times["detected"] - times["written"]
            receipt = times["receipt_persisted"] - times["detected"]
            print("DELIVERY_LATENCY_R " + json.dumps({
                "write_to_detection_seconds": round(detection, 3),
                "detection_to_receipt_seconds": round(receipt, 3), "limit_seconds": LIMIT_SECONDS}),
                flush=True)
            self.assertGreaterEqual(detection, 0, "the result was detected before it was written")
            self.assertLessEqual(detection, LIMIT_SECONDS, "detection took longer than 5 s")
            self.assertLessEqual(receipt, LIMIT_SECONDS, "the durable receipt took longer than 5 s")
            self.assertIsNotNone(host.receipt(HOST_ID, key), "the receipt was not persisted")
        finally:
            gateway.close()


if __name__ == "__main__":
    faulthandler.dump_traceback_later(RUN_LIMIT_SECONDS, exit=True)
    unittest.main()

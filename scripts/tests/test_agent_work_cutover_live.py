#!/usr/bin/env python3
"""cutover_live decisions without a Gateway (VEREDICTO-T11-b-r1): an entry that does not match the
Gateway refuses, a lost drain race does not wedge the cutover, and a restarting Gateway is waited for."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import cutover_live  # noqa: E402

NOW = 1_000_000_000_000
PROFILE = {"maxConcurrentTasks": 5, "maxDepth": 2, "maxChildren": 6, "maxModelCalls": 2160,
           "maxInputTokens": 10, "maxOutputTokens": 10, "maxCacheReadTokens": 10,
           "maxContextTokens": 10, "maxTreeTokens": 10, "maxAutomaticRecoveryCalls": 1}


class FakeGateway:
    """cron.list / cron.update / cron.runs / config.get / config.patch with R's observable effects."""

    def __init__(self, jobs, cancel_on_disable=False, unavailable=None):
        self.jobs = jobs
        self.managed = {"enabled": False, "hosts": {}}
        self.runs = {}
        self.cancel_on_disable = cancel_on_disable
        # Method -> how many of its next calls fail as a restarting Gateway; "*" for every method.
        self.unavailable = dict(unavailable or {})

    def call(self, method, params):
        key = method if self.unavailable.get(method) else "*" if self.unavailable.get("*") else None
        if key:
            self.unavailable[key] -= 1
            raise cutover_live.GatewayUnavailable(f"{method}: Gateway not reachable (restarting)")
        if method == "cron.list":
            return {"jobs": [dict(job) for job in self.jobs]}
        if method == "config.get":
            return {"hash": "h", "resolved": {"managedTasks": self.managed}}
        if method == "config.patch":
            self.managed = json.loads(params["raw"])["managedTasks"]
            return {"ok": True}
        if method == "cron.update":
            job = next(job for job in self.jobs if job["id"] == params["id"])
            job.update(params["patch"])
            if self.cancel_on_disable:
                self.runs.setdefault(job["id"], []).append(
                    {"ts": NOW + 5, "error": "Cron job disabled by operator."})
            return {"ok": True}
        if method == "cron.runs":
            return {"entries": self.runs.get(params["id"], [])}
        raise AssertionError(method)


def job(name="vigia-viejo", job_id="j1"):
    return {"id": job_id, "name": name, "enabled": True, "state": {"nextRunAtMs": NOW + 120_000}}


class CutoverLiveTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.limits = self.root / "limits.json"
        self.limits.write_text(json.dumps({"productionProfile": {"values": PROFILE}}))
        (self.root / "spool").mkdir()
        self.state = self.root / "state.json"

    def entry(self, **changes):
        entry = {"id": "loop:x", "legacyCrons": ["vigia-viejo"], "host": "mini", "adapter": "claude_opus",
                 "deviceId": "device", "instructionRoot": str(self.root), "spools": [str(self.root / "spool")]}
        entry.update(changes)
        cutover_live.prepare(self.state, entry)
        return entry

    def apply(self, gateway, now=NOW, wait_seconds=0):
        return cutover_live.apply(self.state, gateway, now_ms=lambda: now, wait_seconds=wait_seconds,
                                  sleep=lambda _: None, limits_path=self.limits)

    def test_an_old_cron_the_gateway_does_not_have_refuses_instead_of_leaving_two_emitters(self):
        gateway = FakeGateway([job("vigia-real", "jreal")])
        self.entry()
        with self.assertRaisesRegex(cutover_live.CutoverRefused,
                                    "loop:x names vigia-viejo, which matches 0 Gateway crons"):
            self.apply(gateway)
        self.assertEqual((gateway.jobs[0]["enabled"], gateway.managed["enabled"]), (True, False))

    def test_a_spool_that_does_not_exist_refuses(self):
        gateway = FakeGateway([job()])
        self.entry(spools=[str(self.root / "no-such-spool")])
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "spool .*no-such-spool does not exist"):
            self.apply(gateway)
        self.assertTrue(gateway.jobs[0]["enabled"])

    def test_a_lost_drain_race_refuses_once_and_the_same_command_then_resumes(self):
        gateway = FakeGateway([job()], cancel_on_disable=True)
        self.entry()
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "vigia-viejo was cancelled instead of drained"):
            self.apply(gateway)
        state = json.loads(self.state.read_text())
        self.assertEqual(list(state["cancelled"]), ["j1"])
        self.assertEqual(self.apply(gateway, now=NOW + 60_000), "transferred")
        self.assertEqual(json.loads(self.state.read_text())["owner"], "native")

    def test_a_restarting_gateway_is_waited_for_at_every_step(self):
        # The first call of every step fails: the pre-check, the fence, the suspension and the check.
        gateway = FakeGateway([job()], cancel_on_disable=False,
                              unavailable={"config.get": 1, "cron.list": 2, "cron.update": 1, "cron.runs": 1})
        self.entry()
        self.assertEqual(self.apply(gateway, wait_seconds=30), "transferred")
        self.assertFalse(gateway.jobs[0]["enabled"])

    def test_a_gateway_that_stays_unavailable_refuses_after_the_wait(self):
        gateway = FakeGateway([job()], unavailable={"*": 10_000})
        self.entry()
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "Gateway not reachable"):
            self.apply(gateway, wait_seconds=0)
        self.assertTrue(gateway.jobs[0]["enabled"])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""T11 :300-:301: the rollback with the real binaries on a copy of the live gateway. The previous
2026.9.7 cannot open the migrated schema, so the pre-install snapshot comes back; the old cron is
never re-enabled, host result spools are never touched, and every failure leaves the candidate
running with admission frozen.

Needs AGENT_WORK_CUTOVER_CANDIDATE_PREFIX (R package installed), AGENT_WORK_CUTOVER_PREVIOUS_PREFIX
(openclaw@2026.9.7 installed) and AGENT_WORK_CUTOVER_COPY (consistent copy of the live state)."""
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work" / "runtime"))
import cutover_live  # noqa: E402
from ensayo_host import EnsayoHost  # noqa: E402
from spool import Spool  # noqa: E402

PORT = 18797
CRON = "vigia-ensayo"


def prefixes(test):
    names = ("AGENT_WORK_CUTOVER_CANDIDATE_PREFIX", "AGENT_WORK_CUTOVER_PREVIOUS_PREFIX", "AGENT_WORK_CUTOVER_COPY")
    values = [os.environ.get(name) for name in names]
    if not all(values):
        test.skipTest("set " + ", ".join(names) + " for the rollback rehearsal")
    return [Path(value) for value in values]


class Rollback:
    """A host whose next restore can fail once, as a crash between restore and start."""

    def __init__(self, host, crash_after_restore=False, crash_before_stop=False):
        self.host, self.crash, self.crash_stop = host, crash_after_restore, crash_before_stop

    def stop(self):
        if self.crash_stop:
            self.crash_stop = False
            raise KeyboardInterrupt("crash before stopping the candidate")
        self.host.stop()

    def restore(self, snapshot):
        self.host.restore(snapshot)
        if self.crash:
            self.crash = False
            raise KeyboardInterrupt("crash after restore")

    def start(self, prefix, skip_cron=True):
        return self.host.start(prefix, skip_cron=skip_cron)


class CutoverRollbackE2E(unittest.TestCase):
    def setUp(self):
        self.candidate, self.previous, self.copy = prefixes(self)
        # As in production: the previous binary runs with the old cron, the photo is taken before the
        # install, and only then the candidate migrates the base.
        self.host = EnsayoHost.create(self.copy, self.previous, PORT)
        self.addCleanup(shutil.rmtree, self.host.root, True)
        self.addCleanup(self.host.stop)
        self.host.start(self.previous)
        self.client = cutover_live.CliClient(str(self.host.cli))
        self.job = self.client.call("cron.add", {
            "name": CRON, "agentId": "main", "enabled": True,
            "schedule": {"kind": "every", "everyMs": 300000}, "sessionTarget": "isolated",
            "wakeMode": "now", "payload": {"kind": "agentTurn", "message": f"cutover-cron-{CRON}"},
            "delivery": {"mode": "none"}})["id"]
        self.host.stop()
        self.snapshot = self.host.root / "foto-pre-instalacion"
        self.snapshot.mkdir()
        shutil.copyfile(self.host.state / "state/openclaw.sqlite", self.snapshot / "openclaw.sqlite")
        for agent in (self.host.state / "agents").iterdir():
            shutil.copyfile(agent / "agent/openclaw-agent.sqlite", self.snapshot / f"agent-{agent.name}.sqlite")
        shutil.copyfile(self.copy / "openclaw.json", self.snapshot / "openclaw.json")
        self.host.start(self.candidate)
        spool = Spool(self.host.root / "host-spool", "mac-local")
        spool.register("op-pending", "instance-1", "digest", "assignment:x", {"taskId": "task-1", "generation": 1})
        self.spool_file = self.host.root / "host-spool" / "host.sqlite"
        self.spool_digest = hashlib.sha256(self.spool_file.read_bytes()).hexdigest()
        limits = json.loads((ROOT / "docs/evidence/agent-work/limits.json").read_text())
        limits["productionProfile"]["values"]["maxContextTokens"] = 2_000_000
        self.limits = self.host.root / "limits-ensayo.json"
        self.limits.write_text(json.dumps(limits))
        self.state = self.host.root / "cutover-state.json"
        (self.host.root / "instructions").mkdir()
        cutover_live.prepare(self.state, {
            "id": "ensayo:vigia", "legacyCrons": [CRON], "host": "mac-local", "adapter": "claude_opus",
            "spools": [str(self.host.root / "host-spool")], "deviceId": "ensayo-device",
            "instructionRoot": str(self.host.root / "instructions"), "runTimeoutSeconds": 3600})
        self.assertEqual(cutover_live.apply(self.state, self.client, lambda: int(time.time() * 1000),
                                            wait_seconds=120, limits_path=self.limits), "transferred")
        self.assertEqual(self.host.schema(), 27)

    def cron_enabled(self):
        return next(job["enabled"] for job in self.client.call("cron.list", {"includeDisabled": True})["jobs"]
                    if job["id"] == self.job)

    def assert_spool_untouched(self):
        self.assertEqual(hashlib.sha256(self.spool_file.read_bytes()).hexdigest(), self.spool_digest)

    def assert_candidate_frozen(self):
        managed = self.client.call("config.get", {})["resolved"].get("managedTasks", {})
        self.assertFalse(managed.get("enabled"), "admission must stay frozen after a failed rollback")

    def rollback(self, host=None, previous=None, snapshot=None):
        return cutover_live.rollback(self.state, host or Rollback(self.host), lambda: self.client,
                                     self.candidate, previous or self.previous, snapshot or self.snapshot)

    def test_rollback_returns_the_previous_binary_on_the_snapshot_and_keeps_the_old_cron_suspended(self):
        self.assertEqual(self.rollback(), "rolled-back; old crons stay suspended")
        self.assertEqual(self.host.schema(), 19)
        self.assertIn("(c074824)", os.popen(f"{self.host.cli} --version").read())
        self.assertNotIn("managedTasks", self.host.config())
        self.assertFalse(self.cron_enabled(), "the restored snapshot re-enabled the old cron")
        state = json.loads(self.state.read_text())
        self.assertEqual((state["owner"], state["generation"], state["rollback"]["phase"]), ("legacy", 3, "done"))
        self.assert_spool_untouched()

    def test_a_bad_snapshot_keeps_the_candidate_running_with_admission_frozen(self):
        bad = self.host.root / "bad-snapshot"
        bad.mkdir()
        (bad / "openclaw.sqlite").write_bytes(b"not a database")
        shutil.copyfile(self.snapshot / "openclaw.json", bad / "openclaw.json")
        with self.assertRaisesRegex(cutover_live.RollbackFailed, "snapshot database is unreadable"):
            self.rollback(snapshot=bad)
        self.assertEqual(self.host.schema(), 27)
        self.assertIn("(818f0fd)", os.popen(f"{self.host.cli} --version").read())
        self.assert_candidate_frozen()
        self.assert_spool_untouched()

    def test_a_previous_binary_that_does_not_start_leaves_the_candidate_frozen_on_the_snapshot(self):
        broken = self.host.root / "broken-previous"
        (broken / "bin").mkdir(parents=True)
        (broken / "bin/openclaw").write_text("#!/bin/sh\necho 'previous binary is missing' >&2\nexit 1\n")
        (broken / "bin/openclaw").chmod(0o755)
        with self.assertRaisesRegex(cutover_live.RollbackFailed, "previous binary did not start"):
            self.rollback(previous=broken)
        self.assertIn("(818f0fd)", os.popen(f"{self.host.cli} --version").read())
        self.assert_candidate_frozen()
        self.assertFalse(self.cron_enabled())
        self.assertEqual(json.loads(self.state.read_text())["rollback"]["phase"], "failed-candidate-frozen")
        self.assert_spool_untouched()

    def test_a_rollback_interrupted_before_stopping_leaves_the_candidate_frozen(self):
        with self.assertRaises(KeyboardInterrupt):
            self.rollback(host=Rollback(self.host, crash_before_stop=True))
        self.assertEqual(json.loads(self.state.read_text())["rollback"]["phase"], "frozen")
        self.assertIn("(818f0fd)", os.popen(f"{self.host.cli} --version").read())
        self.assert_candidate_frozen()
        self.assert_spool_untouched()

    def test_an_interrupted_rollback_resumes_without_reviving_the_old_cron(self):
        with self.assertRaises(KeyboardInterrupt):
            self.rollback(host=Rollback(self.host, crash_after_restore=True))
        self.assertEqual(json.loads(self.state.read_text())["rollback"]["phase"], "frozen")
        self.assertEqual(self.rollback(), "rolled-back; old crons stay suspended")
        self.assertFalse(self.cron_enabled())
        self.assertEqual(self.host.schema(), 19)
        self.assert_spool_untouched()


if __name__ == "__main__":
    unittest.main()

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "scripts/agent-work/cutover.py"


class CutoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.package = self.base / "runtime.tgz"
        self.package.write_bytes(b"reviewed runtime fixture")
        self.manifest = self.base / "manifest.json"
        self.manifest.write_text(json.dumps({
            "schema": 1, "sourceSha": "a" * 40,
            "package": str(self.package),
            "packageSha256": hashlib.sha256(self.package.read_bytes()).hexdigest(),
            "schemaCompatibility": "previous-binary-readable",
        }))
        self.state = self.base / "state.json"
        self.state.write_text(json.dumps({
            "scope": "test/engineering", "generation": 1,
            "owner": "legacy", "admission": "frozen", "capture": True,
            "cron": {"id": "old-five-minute", "suspended": False,
                     "inFlight": 0, "postSuspendRequests": 0},
            "emitters": ["legacy", "native"], "activeSessions": ["user-session"],
            "uncertainAdmissions": [], "pendingResults": ["result-1"],
            "binary": "previous", "config": "previous",
        }))
        self.auth = self.base / "authorization.json"
        self.auth.write_text(json.dumps({
            "manifestSha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            "scope": "test/engineering", "generation": 2,
            "operations": ["apply", "rollback"], "recordedBy": "fixture-operator",
        }))

    def run_cli(self, command, *extra, ok=True):
        p = subprocess.run([sys.executable, str(CLI), command,
                            "--manifest", str(self.manifest), "--state", str(self.state),
                            "--simulation", *extra], capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout)
        return p

    def read_state(self):
        return json.loads(self.state.read_text())

    def write_state(self, **changes):
        state = self.read_state()
        state.update(changes)
        self.state.write_text(json.dumps(state))

    def test_cutover_fencing_preserves_capture_pending_and_session(self):
        self.run_cli("prepare")
        self.run_cli("apply", "--authorization", str(self.auth), ok=False)
        self.write_state(cron={"id": "old-five-minute", "suspended": True,
                               "inFlight": 0, "postSuspendRequests": 0},
                         emitters=["legacy"], uncertainAdmissions=[])
        self.run_cli("apply", "--authorization", str(self.auth))
        state = self.read_state()
        self.assertEqual((state["owner"], state["generation"], state["admission"]),
                         ("native", 2, "enabled"))
        self.assertEqual(state["emitters"], ["native"])
        self.assertTrue(state["capture"])
        self.assertEqual(state["pendingResults"], ["result-1"])
        self.assertEqual(state["activeSessions"], ["user-session"])
        self.run_cli("rollback", "--authorization", str(self.auth))
        state = self.read_state()
        self.assertEqual((state["owner"], state["binary"], state["config"]),
                         ("legacy", "previous", "previous"))
        self.assertTrue(state["cron"]["suspended"])
        self.assertTrue(state["capture"])
        self.assertEqual(state["pendingResults"], ["result-1"])

    def test_old_authorization_cannot_reuse_generation_after_rollback(self):
        self.run_cli("prepare")
        self.write_state(cron={"id": "old-five-minute", "suspended": True,
                               "inFlight": 0, "postSuspendRequests": 0},
                         emitters=["legacy"])
        self.run_cli("apply", "--authorization", str(self.auth))
        self.run_cli("rollback", "--authorization", str(self.auth))
        self.run_cli("apply", "--authorization", str(self.auth), ok=False)
        self.assertEqual((self.read_state()["owner"], self.read_state()["generation"]),
                         ("legacy", 3))

    def test_uncertainty_or_old_cron_in_flight_fails_closed(self):
        self.run_cli("prepare")
        for change in [
            {"uncertainAdmissions": ["claim-1"]},
            {"cron": {"id": "old-five-minute", "suspended": True,
                      "inFlight": 1, "postSuspendRequests": 0}},
            {"cron": {"id": "old-five-minute", "suspended": True,
                      "inFlight": 0, "postSuspendRequests": 1}},
        ]:
            state = self.read_state()
            state.update(change)
            state["cron"] = change.get("cron", {"id": "old-five-minute",
                                                  "suspended": True, "inFlight": 0,
                                                  "postSuspendRequests": 0})
            state["uncertainAdmissions"] = change.get("uncertainAdmissions", [])
            self.state.write_text(json.dumps(state))
            self.run_cli("apply", "--authorization", str(self.auth), ok=False)
            self.assertEqual(self.read_state()["owner"], "legacy")

    def test_authorization_and_artifact_are_pinned(self):
        self.run_cli("prepare")
        self.run_cli("apply", ok=False)
        self.package.write_bytes(b"changed")
        self.run_cli("prepare", ok=False)
        self.assertEqual(self.read_state()["owner"], "legacy")

    def test_failed_rollback_freezes_admission_and_keeps_new_binary(self):
        self.run_cli("prepare")
        self.write_state(cron={"id": "old-five-minute", "suspended": True,
                               "inFlight": 0, "postSuspendRequests": 0},
                         emitters=["legacy"])
        self.run_cli("apply", "--authorization", str(self.auth))
        self.write_state(rollbackFailure=True)
        self.run_cli("rollback", "--authorization", str(self.auth), ok=False)
        state = self.read_state()
        self.assertEqual(state["admission"], "frozen")
        self.assertEqual(state["binary"], "candidate")
        self.assertEqual(state["pendingResults"], ["result-1"])
        self.assertTrue(state["capture"])

    def test_schema_incompatible_rollback_freezes_without_downgrade(self):
        self.run_cli("prepare")
        self.write_state(cron={"id": "old-five-minute", "suspended": True,
                               "inFlight": 0, "postSuspendRequests": 0},
                         emitters=["legacy"])
        self.run_cli("apply", "--authorization", str(self.auth))
        manifest = json.loads(self.manifest.read_text())
        manifest["schemaCompatibility"] = "previous-binary-unreadable"
        self.manifest.write_text(json.dumps(manifest))
        self.auth.write_text(json.dumps({**json.loads(self.auth.read_text()),
                                         "manifestSha256": hashlib.sha256(self.manifest.read_bytes()).hexdigest()}))
        self.run_cli("rollback", "--authorization", str(self.auth), ok=False)
        state = self.read_state()
        self.assertEqual((state["binary"], state["admission"]), ("candidate", "frozen"))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""cutover_live decisions without a Gateway (VEREDICTO-T11-b-r1): an entry that does not match the
Gateway refuses, a lost drain race does not wedge the cutover, and a restarting Gateway is waited for."""
import contextlib
import copy
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import cutover_live  # noqa: E402

NOW = 1_000_000_000_000
PROFILE = {"maxConcurrentTasks": 5, "maxDepth": 2, "maxChildren": 6, "maxModelCalls": 2160,
           "maxInputTokens": 10, "maxOutputTokens": 10, "maxCacheReadTokens": 10,
           "maxContextTokens": 10, "maxTreeTokens": 10, "maxAutomaticRecoveryCalls": 1}


def merged(base, patch):
    if not isinstance(base, dict) or not isinstance(patch, dict):
        return patch
    result = dict(base)
    for key, value in patch.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = merged(base.get(key), value)
    return result


def shrunk_arrays(base, after, path="managedTasks"):
    if isinstance(base, list):
        return [] if isinstance(after, list) and all(item in after for item in base) else [path]
    if not isinstance(base, dict):
        return []
    after = after if isinstance(after, dict) else {}
    return [found for key, value in base.items() for found in shrunk_arrays(value, after.get(key), f"{path}.{key}")]


class FakeGateway:
    """cron.list / cron.update / cron.runs / config.get / config.patch with R's observable effects."""

    def __init__(self, jobs, cancel_on_disable=False, unavailable=None, managed=None):
        self.jobs = jobs
        self.managed = managed or {"enabled": False, "hosts": {}}
        self.runs = {}
        self.patches = []
        self.cancel_on_disable = cancel_on_disable
        # Method -> how many of its next calls fail as a restarting Gateway; "*" for every method.
        self.unavailable = dict(unavailable or {})
        # Method -> how many of its next calls are refused outright, as a killed or rejecting call.
        self.refused = {}

    def call(self, method, params):
        key = method if self.unavailable.get(method) else "*" if self.unavailable.get("*") else None
        if key:
            self.unavailable[key] -= 1
            raise cutover_live.GatewayUnavailable(f"{method}: Gateway not reachable (restarting)")
        if self.refused.get(method):
            self.refused[method] -= 1
            raise cutover_live.CutoverRefused(f"{method}: connection reset")
        if method == "cron.list":
            return {"jobs": [dict(job) for job in self.jobs]}
        if method == "config.get":
            return {"hash": self.hash(), "resolved": {"managedTasks": self.managed}}
        if method == "config.patch":
            # R's config.patch: a merge patch on the config it was read from, never silently shortening an array.
            if params["baseHash"] != self.hash():
                raise cutover_live.CutoverRefused("config.patch: config changed since last load")
            after = merged(self.managed, json.loads(params["raw"])["managedTasks"])
            unconfirmed = [path for path in shrunk_arrays(self.managed, after)
                           if path not in params.get("replacePaths", [])]
            if unconfirmed:
                raise cutover_live.CutoverRefused(
                    f"config.patch would remove entries from array path(s): {', '.join(unconfirmed)}")
            self.patches.append(json.loads(params["raw"]))
            self.managed = after
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

    def hash(self):
        return hashlib.sha256(json.dumps(self.managed, sort_keys=True).encode()).hexdigest()


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

    def cli(self, gateway, *args):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(cutover_live, "CliClient", lambda binary: gateway), \
                mock.patch.object(sys, "argv", ["cutover_live.py", *args]), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cutover_live.main()
        return code, out.getvalue().strip(), err.getvalue().strip()

    def test_the_first_cutover_names_main_as_the_only_requester(self):
        gateway = FakeGateway([job()])
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(gateway.managed["requesters"], ["main"])

    def test_the_cutover_adds_main_to_an_operator_requester_list_and_drops_nothing(self):
        gateway = FakeGateway([job()], managed={"enabled": False, "hosts": {}, "requesters": ["ingenieria"]})
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(gateway.managed["requesters"], ["ingenieria", "main"])

    def test_revert_closes_the_entry_then_re_enables_its_old_crons_and_keeps_the_spool(self):
        gateway = FakeGateway([job(), job("otro-cron", "j2")])
        gateway.jobs[1]["enabled"] = False
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        result = self.root / "spool" / "result.json"
        result.write_text('{"pending": true}')
        self.assertEqual(self.cli(gateway, "revert", "--state", str(self.state)),
                         (0, "reverted; old crons re-enabled", ""))
        self.assertEqual(gateway.managed["enabled"], False)
        self.assertEqual([(cron["id"], cron["enabled"]) for cron in gateway.jobs], [("j1", True), ("j2", False)])
        state = json.loads(self.state.read_text())
        self.assertEqual((state["owner"], state["generation"], state["revert"]), ("legacy", 3, {"phase": "done"}))
        self.assertEqual(result.read_text(), '{"pending": true}')
        patches = len(gateway.patches)
        self.assertEqual(self.cli(gateway, "revert", "--state", str(self.state)), (0, "already reverted", ""))
        self.assertEqual(len(gateway.patches), patches)

    def test_revert_removes_only_its_adapter_when_the_host_keeps_another(self):
        gateway = FakeGateway([job()], managed={"enabled": True, "instructionRoot": str(self.root),
                                                "hosts": {"mini": {"deviceId": "device", "adapters": ["codex"]}}})
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(gateway.managed["hosts"]["mini"]["adapters"], ["claude_opus", "codex"])
        self.assertEqual(cutover_live.revert(self.state, gateway, sleep=lambda _: None), "reverted; old crons re-enabled")
        self.assertEqual((gateway.managed["enabled"], gateway.managed["hosts"]["mini"]["adapters"]), (True, ["codex"]))
        self.assertTrue(gateway.jobs[0]["enabled"])

    def test_revert_drops_a_host_left_without_adapters_while_another_host_stays_open(self):
        gateway = FakeGateway([job()], managed={"enabled": True, "instructionRoot": str(self.root),
                                                "hosts": {"pc": {"deviceId": "pc-device", "adapters": ["codex"]}}})
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(cutover_live.revert(self.state, gateway, sleep=lambda _: None), "reverted; old crons re-enabled")
        self.assertEqual((gateway.managed["enabled"], gateway.managed["hosts"]),
                         (True, {"pc": {"deviceId": "pc-device", "adapters": ["codex"]}}))

    def test_a_revert_interrupted_between_its_steps_resumes_without_patching_again(self):
        gateway = FakeGateway([job()])
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        gateway.refused = {"cron.update": 1}
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "cron.update: connection reset"):
            cutover_live.revert(self.state, gateway, sleep=lambda _: None)
        state = json.loads(self.state.read_text())
        self.assertEqual((state["owner"], state["revert"]), ("native", {"phase": "frozen"}))
        self.assertEqual((gateway.managed["enabled"], gateway.jobs[0]["enabled"]), (False, False))
        patches = len(gateway.patches)
        self.assertEqual(cutover_live.revert(self.state, gateway, sleep=lambda _: None), "reverted; old crons re-enabled")
        self.assertEqual((len(gateway.patches), gateway.jobs[0]["enabled"]), (patches, True))

    def test_revert_refuses_an_entry_that_was_never_transferred(self):
        gateway = FakeGateway([job()])
        self.entry()
        self.assertEqual(self.cli(gateway, "revert", "--state", str(self.state)),
                         (1, "", "cutover: loop:x was never transferred; nothing to revert"))
        self.assertEqual((gateway.patches, gateway.jobs[0]["enabled"]), ([], True))

    def test_an_entry_transferred_again_after_a_revert_reverts_again(self):
        gateway = FakeGateway([job()])
        self.entry()
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(cutover_live.revert(self.state, gateway, sleep=lambda _: None), "reverted; old crons re-enabled")
        self.assertEqual(self.apply(gateway), "transferred")
        self.assertEqual(cutover_live.revert(self.state, gateway, sleep=lambda _: None), "reverted; old crons re-enabled")
        self.assertEqual((gateway.managed["enabled"], gateway.jobs[0]["enabled"]), (False, True))

    def test_freeze_closes_all_admission_without_a_state_file(self):
        gateway = FakeGateway([job()], managed={"enabled": True, "instructionRoot": str(self.root),
                                                "hosts": {"mini": {"deviceId": "device", "adapters": ["codex"]}}})
        self.assertEqual(self.cli(gateway, "freeze"), (0, "frozen", ""))
        self.assertEqual((gateway.managed["enabled"], gateway.managed["hosts"]["mini"]["adapters"]), (False, ["codex"]))

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

    def test_a_profile_missing_a_limit_is_unknown_too(self):
        partial = {field: value for field, value in PROFILE.items() if field != "maxTreeTokens"}
        self.limits.write_text(json.dumps({"productionProfile": {"values": partial}}))
        gateway = FakeGateway([job()])
        self.entry()
        with self.assertRaisesRegex(cutover_live.CutoverRefused, "production limits are unknown: maxTreeTokens"):
            self.apply(gateway)
        self.assertTrue(gateway.jobs[0]["enabled"])

    def test_a_cli_that_does_not_answer_counts_as_an_unavailable_gateway(self):
        slow = self.root / "slow-openclaw"
        slow.write_text("#!/bin/sh\nsleep 5\n")
        slow.chmod(0o755)
        with self.assertRaisesRegex(cutover_live.GatewayUnavailable, "cron.list: no answer in 1 s"):
            cutover_live.CliClient(str(slow), timeout=1).call("cron.list", {})

    def test_the_spool_reader_closes_its_connection(self):
        import gc
        import warnings
        (self.root / "spool" / "host.sqlite").touch()
        import sqlite3
        with sqlite3.connect(self.root / "spool" / "host.sqlite") as db:
            db.execute("CREATE TABLE operations (operation_json TEXT, status TEXT)")
        db.close()
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always", ResourceWarning)
            self.assertEqual(cutover_live.uncertain_operations([str(self.root / "spool")]), [])
            gc.collect()
        self.assertEqual([str(warning.message) for warning in caught if warning.category is ResourceWarning], [])


DEEPSEEK, KIMI = "opencode@opencode-go/deepseek-v4-pro", "opencode@opencode-go/kimi-k3"
# The shape of the Mini's config: managedTasks as the cutover left it, and neighbours the patch must not touch.
LIVE_CONFIG = {
    "agents": {"entries": {"main": {"model": {"primary": "opencode-go-resp/muse-spark-1.3-contributor"},
                                    "subagents": {"allowAgents": ["main", "ingenieria"]}}}},
    "managedTasks": {"enabled": True, "instructionRoot": "/Users/gon/.openclaw/workspace/managed-instructions",
                     "requesters": ["main"], "runTimeoutSeconds": 3600, "profile": PROFILE,
                     "hosts": {"mac-local": {"deviceId": "device-mac", "adapters": ["opencode"]}}},
    "skills": {"load": {"watch": True}},
}


class AdaptersTest(unittest.TestCase):
    """cutover_live.py adapters against a copy of the Mini's config, through the openclaw CLI double."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config = self.root / "openclaw.json"
        self.config.write_text(json.dumps(LIVE_CONFIG))
        self.log = self.root / "calls.jsonl"
        self.env = {**os.environ, "OPENCLAW_BIN": str(ROOT / "scripts/tests/fixtures/agent-work/openclaw-config-double.py"),
                    "OPENCLAW_DOUBLE_CONFIG": str(self.config), "OPENCLAW_DOUBLE_LOG": str(self.log)}

    def run_cli(self, *args):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/agent-work/cutover_live.py"), "adapters",
                               "--host", "mac-local", *args], capture_output=True, text=True, env=self.env, timeout=60)
        return done.returncode, done.stdout.strip(), done.stderr.strip()

    def methods(self):
        return [json.loads(line)["method"] for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_adding_aliases_appends_them_and_keeps_every_other_key(self):
        self.assertEqual(self.run_cli("--add", DEEPSEEK, "--add", KIMI),
                         (0, json.dumps({"host": "mac-local", "adapters": ["opencode", DEEPSEEK, KIMI]}), ""))
        expected = copy.deepcopy(LIVE_CONFIG)
        expected["managedTasks"]["hosts"]["mac-local"]["adapters"] = ["opencode", DEEPSEEK, KIMI]
        self.assertEqual(json.loads(self.config.read_text()), expected)
        patches = [json.loads(line)["params"] for line in self.log.read_text().splitlines()
                   if json.loads(line)["method"] == "config.patch"]
        self.assertEqual(len(patches), 1)
        self.assertEqual(json.loads(patches[0]["raw"]),
                         {"managedTasks": {"hosts": {"mac-local": {"adapters": ["opencode", DEEPSEEK, KIMI]}}}})
        self.assertNotIn("replacePaths", patches[0])

    def test_running_it_again_patches_nothing(self):
        self.run_cli("--add", DEEPSEEK)
        before = self.config.read_text()
        self.assertEqual(self.run_cli("--add", DEEPSEEK, "--add", "opencode"),
                         (0, json.dumps({"host": "mac-local", "adapters": ["opencode", DEEPSEEK]}), ""))
        self.assertEqual(self.config.read_text(), before)
        self.assertEqual(self.methods(), ["config.get", "config.patch", "config.get", "config.get"])

    def test_a_dry_run_prints_the_patch_and_writes_nothing(self):
        self.assertEqual(self.run_cli("--add", DEEPSEEK, "--dry-run"),
                         (0, json.dumps({"patch": {"managedTasks": {"hosts": {"mac-local": {
                             "adapters": ["opencode", DEEPSEEK]}}}}}, sort_keys=True), ""))
        self.assertEqual(json.loads(self.config.read_text()), LIVE_CONFIG)
        self.assertEqual(self.methods(), ["config.get"])

    def test_an_adapter_without_a_tested_route_is_refused_before_any_write(self):
        self.assertEqual(self.run_cli("--add", DEEPSEEK, "--add", "opencode@opencode-go/glm-5.3", "--add", "claude_opus"),
                         (1, "", "cutover: mac-local has no tested route for opencode@opencode-go/glm-5.3, claude_opus"))
        self.assertEqual(json.loads(self.config.read_text()), LIVE_CONFIG)
        self.assertEqual(self.methods(), ["config.get"])

    def test_a_host_that_is_not_open_is_refused(self):
        closed = copy.deepcopy(LIVE_CONFIG)
        closed["managedTasks"]["enabled"] = False
        self.config.write_text(json.dumps(closed))
        self.assertEqual(self.run_cli("--add", DEEPSEEK),
                         (1, "", "cutover: mac-local is not open; a cutover opens it first"))
        self.assertEqual(json.loads(self.config.read_text()), closed)

    def test_the_restart_after_the_patch_is_waited_for(self):
        coverage = json.loads((ROOT / "docs/evidence/agent-work/coverage.json").read_text())
        gateway = FakeGateway([], managed=copy.deepcopy(LIVE_CONFIG["managedTasks"]),
                              unavailable={"config.get": 1})
        real_call = gateway.call

        def restarting(method, params):
            answer = real_call(method, params)
            if method == "config.patch":
                gateway.unavailable["config.get"] = 3
            return answer

        gateway.call = restarting
        self.assertEqual(cutover_live.add_adapters(gateway, "mac-local", [DEEPSEEK], coverage, wait_seconds=30,
                                                   sleep=lambda _: None), ["opencode", DEEPSEEK])
        self.assertEqual(gateway.patches, [{"managedTasks": {"hosts": {"mac-local": {"adapters": ["opencode", DEEPSEEK]}}}}])
        self.assertEqual(gateway.unavailable["config.get"], 0)

if __name__ == "__main__":
    unittest.main()

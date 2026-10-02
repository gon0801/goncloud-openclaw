#!/usr/bin/env python3
"""Requester-side routing contract for managed tasks."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from routing import prepare_request, RouteUnavailable  # noqa: E402
import routing  # noqa: E402


class AgentsRouting(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.brief = self.root / "brief.txt"
        self.brief.write_text("Review revision aaaa", encoding="utf-8")
        self.instructions = self.root / "instructions"
        self.instructions.mkdir()
        self.revision = {"kind": "code", "repository": "repo", "sha": "a" * 40}
        self.coverage = json.loads((ROOT / "docs/evidence/agent-work/coverage.json").read_text())

    def request(self, requester, target, *, coverage=None):
        return prepare_request(requester=requester, target=target, key="review-r1",
                               brief=self.brief, instruction_root=self.instructions,
                               input_revision=self.revision, result_contract="review.v1",
                               coverage=coverage or self.coverage)

    def test_ingenieria_to_adversary_preserves_target_and_brief(self):
        request = self.request("ingenieria", "adversary")
        self.assertEqual(request["assignment"]["target"], {"kind": "agent", "agentId": "adversary"})
        self.assertEqual(request["key"], "review-r1")
        self.assertEqual(request["assignment"]["continuation"], {"kind": "requester"})
        ref = request["assignment"]["instructionRef"]
        self.assertEqual((self.instructions / ref["ref"].split(":")[1]).read_bytes(),
                         self.brief.read_bytes())
        self.assertEqual(self.request("ingenieria", "adversary"), request)

    def test_operaciones_to_ingenieria_keeps_operaciones_as_requester(self):
        request = self.request("operaciones", "ingenieria")
        self.assertEqual(request["assignment"]["target"], {"kind": "agent", "agentId": "ingenieria"})
        self.assertEqual(request["assignment"]["continuation"], {"kind": "requester"})

    def test_remote_cli_requires_certified_host_adapter(self):
        with self.assertRaisesRegex(RouteUnavailable, "windows-remote/codex"):
            self.request("ingenieria", "windows-remote/codex")
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["windows-remote"]["codex"] = "certified"
        request = self.request("ingenieria", "windows-remote/codex", coverage=certified)
        self.assertEqual(request["assignment"]["target"],
                         {"kind": "cli", "hostId": "windows-remote", "adapterId": "codex"})

    def test_outside_managed_perimeter_is_rejected(self):
        with self.assertRaisesRegex(RouteUnavailable, "route"):
            self.request("scout", "adversary")

    def test_agent_instructions_call_the_guarded_route_and_keep_legacy_outside(self):
        main_skill = (ROOT / "agents/main/agent/workshop-skills/agent-dispatch/SKILL.md").read_text()
        self.assertIn("managed_tasks_submit", main_skill)
        self.assertIn("fuera de ese perímetro conservan el flujo", main_skill)
        for agent, target in (("ingenieria", "adversary"), ("operaciones", "ingenieria")):
            skill = ROOT / f"agents/{agent}/agent/workshop-skills/managed-task-routing/SKILL.md"
            self.assertTrue(skill.is_file(), f"missing managed route skill for {agent}")
            content = skill.read_text()
            self.assertIn(f"--requester {agent} --target {target}", content)
            self.assertIn("scripts/agent-work/routing.py", content)
            self.assertIn("managed_tasks_submit", content)
            self.assertIn("managed_tasks_admit", content)
            self.assertIn("Fuera del perímetro gestionado", content)

    def test_cli_prints_native_submit_parameters(self):
        command = [sys.executable, str(ROOT / "scripts/agent-work/routing.py"),
                   "--requester", "ingenieria", "--target", "adversary",
                   "--key", "review-r1", "--brief", str(self.brief),
                   "--instruction-root", str(self.instructions),
                   "--revision-json", json.dumps(self.revision),
                   "--result-contract", "review.v1"]
        output = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(output.stdout), self.request("ingenieria", "adversary"))

    def test_parallel_preparation_never_observes_partial_artifact(self):
        writing = threading.Event()
        release = threading.Event()
        original_open = routing.os.open
        result = []
        first = True

        def paused_open(path, flags, mode=0o777):
            nonlocal first
            fd = original_open(path, flags, mode)
            if first:
                first = False
                writing.set()
                release.wait(2)
            return fd

        def first_request():
            try:
                result.append(self.request("ingenieria", "adversary"))
            except Exception as exc:  # asserted below
                result.append(exc)

        with mock.patch("routing.os.open", side_effect=paused_open):
            thread = threading.Thread(target=first_request)
            thread.start()
            self.assertTrue(writing.wait(2))
            try:
                second = self.request("ingenieria", "adversary")
            finally:
                release.set()
                thread.join(2)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0], second)


if __name__ == "__main__":
    unittest.main()

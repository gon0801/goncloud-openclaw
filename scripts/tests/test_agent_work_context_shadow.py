#!/usr/bin/env python3
"""T12 shadow measure of maxContextTokens: provider.payload.measured events from the agent databases."""
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts/agent-work/runtime/medir-contexto-sombra.py"


def agent_db(state, agent, events):
    path = state / "agents" / agent / "agent" / "openclaw-agent.sqlite"
    path.parent.mkdir(parents=True)
    with closing(sqlite3.connect(path)) as db:
        db.execute("CREATE TABLE trajectory_runtime_events (event_json TEXT)")
        db.executemany("INSERT INTO trajectory_runtime_events VALUES (?)", [(json.dumps(event),) for event in events])
        db.commit()


def measured(bytes_, ts="2026-10-10T00:00:00Z", provider="openai"):
    return {"type": "provider.payload.measured", "ts": ts, "provider": provider,
            "data": {"bytes": bytes_, "provider": provider, "api": "openai-responses", "modelId": "m"}}


class ContextShadowTest(unittest.TestCase):
    def run_tool(self, state, *agents):
        return subprocess.run([sys.executable, str(TOOL), str(state), *agents], capture_output=True, text=True)

    def test_the_limit_is_the_largest_measured_body_in_the_perimeter_times_one_and_a_half(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            agent_db(state, "ingenieria", [measured(1000), measured(4000), {"type": "provider.prompt.observed"}])
            agent_db(state, "adversary", [measured(2500, ts="2026-10-11T00:00:00Z")])
            agent_db(state, "main", [measured(900_000)])
            run = self.run_tool(state, "ingenieria", "adversary")
            self.assertEqual(run.returncode, 0, run.stderr)
            report = json.loads(run.stdout)
            self.assertEqual(report["maxContextTokens"], 6000)
            self.assertEqual(report["byAgent"]["ingenieria"], {"n": 2, "max": 4000, "p95": 4000})
            self.assertEqual(report["byAgent"]["adversary"], {"n": 1, "max": 2500, "p95": 2500})
            self.assertEqual((report["from"], report["to"]), ("2026-10-10T00:00:00Z", "2026-10-11T00:00:00Z"))

    def test_no_measured_call_leaves_the_limit_unknown(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            agent_db(state, "ingenieria", [{"type": "provider.prompt.observed"}])
            run = self.run_tool(state, "ingenieria")
            self.assertEqual(run.returncode, 1)
            self.assertEqual(json.loads(run.stdout)["maxContextTokens"], None)
            self.assertIn("no provider.payload.measured events for ingenieria", run.stderr)


if __name__ == "__main__":
    unittest.main()

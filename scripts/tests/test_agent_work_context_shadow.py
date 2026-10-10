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
VERIFY = ROOT / "scripts/agent-work/runtime/verificar-medida-sombra.py"
BYTES_PER_TOKEN = ROOT / "scripts/agent-work/runtime/medir-bytes-por-token.py"


def load_verify():
    import importlib.util
    spec = importlib.util.spec_from_file_location("verificar_medida_sombra", VERIFY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def agent_db(state, agent, events):
    path = state / "agents" / agent / "agent" / "openclaw-agent.sqlite"
    path.parent.mkdir(parents=True)
    with closing(sqlite3.connect(path)) as db:
        db.execute("CREATE TABLE trajectory_runtime_events (event_json TEXT)")
        db.executemany("INSERT INTO trajectory_runtime_events VALUES (?)", [(json.dumps(event),) for event in events])
        db.commit()


def measured(bytes_, ts="2026-10-10T00:00:00Z", provider="opencode-go-resp", api="openai-responses"):
    return {"type": "provider.payload.measured", "ts": ts, "provider": provider,
            "data": {"bytes": bytes_, "provider": provider, "api": api, "modelId": "m"}}


class ContextShadowTest(unittest.TestCase):
    def run_tool(self, state, *agents):
        return subprocess.run([sys.executable, str(TOOL), str(state), *agents], capture_output=True, text=True)

    def test_the_limit_is_the_largest_measured_body_in_the_perimeter_times_one_and_a_half(self):
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            agent_db(state, "ingenieria", [measured(1000), measured(4000), {"type": "provider.prompt.observed"},
                                           measured(50_000, provider="opencode-go-2", api="openai-completions")])
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
            agent_db(state, "ingenieria", [{"type": "provider.prompt.observed"},
                                           measured(3000, api="openai-completions")])
            run = self.run_tool(state, "ingenieria")
            self.assertEqual(run.returncode, 1)
            self.assertEqual(json.loads(run.stdout)["maxContextTokens"], None)
            self.assertIn("no Responses provider.payload.measured events for ingenieria", run.stderr)

    def test_the_rehearsal_check_ignores_live_traffic_already_in_the_copy(self):
        verify = load_verify()
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            agent_db(state, "main", [measured(900_000, ts="2026-10-10T05:15:11.883Z"),
                                     measured(4000, ts="2026-10-10T18:00:01.000Z")])
            databases = sorted(state.glob("agents/*/agent/openclaw-agent.sqlite"))
            events = verify.measured_since(databases, "2026-10-10T18:00:00.000Z")
            self.assertEqual(events, [4000])
            self.assertTrue(verify.faithful([4000], events))
            self.assertFalse(verify.faithful([4000], verify.measured_since(databases, "")))
            self.assertFalse(verify.faithful([], []))

    def test_bytes_per_token_pairs_each_call_with_the_next_usage_of_its_run_even_compressed(self):
        from compression import zstd
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            path = state / "agents" / "main" / "agent" / "openclaw-agent.sqlite"
            path.parent.mkdir(parents=True)
            usage = lambda when, tokens: {"timestamp": when, "message": {
                "role": "assistant", "__openclaw": {"runId": "run-1"},
                "usage": {"input": 0, "cacheRead": tokens, "cacheWrite": 0}}}
            with closing(sqlite3.connect(path)) as db:
                db.execute("CREATE TABLE trajectory_runtime_events (session_id TEXT, seq INT, run_id TEXT, event_json TEXT)")
                db.execute("CREATE TABLE transcript_events (session_id TEXT, seq INT, event_json TEXT, event_zstd BLOB)")
                db.execute("INSERT INTO trajectory_runtime_events VALUES ('s', 1, 'run-1', ?)",
                           (json.dumps(measured(6600, ts="2026-10-10T10:00:01.000Z")),))
                db.execute("INSERT INTO transcript_events VALUES ('s', 1, ?, NULL)",
                           (json.dumps(usage("2026-10-10T10:00:00.000Z", 999)),))
                db.execute("INSERT INTO transcript_events VALUES ('s', 2, NULL, ?)",
                           (zstd.compress(json.dumps(usage("2026-10-10T10:00:05.000Z", 1000)).encode()),))
                db.commit()
            run = subprocess.run([sys.executable, str(BYTES_PER_TOKEN), str(state), "main"],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            report = json.loads(run.stdout)
            self.assertEqual((report["n"], report["max"], report["largest"]["tokens"]), (1, 6.6, 1000))


if __name__ == "__main__":
    unittest.main()

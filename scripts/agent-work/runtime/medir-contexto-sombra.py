#!/usr/bin/env python3
"""Shadow measure of maxContextTokens (T12): R bounds a managed call by the UTF-8 bytes of its request
body, and R from 2026-10-10 records that size on every provider call as the trajectory event
provider.payload.measured. This reads those events read-only from the agent databases of a gateway
state directory, for the agents in the managed perimeter, and proposes the limit as max x 1.5.

Usage: medir-contexto-sombra.py <state-dir> <agent> [<agent> ...]
Prints {"maxContextTokens": n|null, "byAgent": {...}, "from": ts, "to": ts}; exits 1 if an agent has
no measured call, so an unknown value never becomes a limit.
"""
import json
import math
import sqlite3
import sys
from contextlib import closing
from pathlib import Path


def measured(database):
    with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as db:
        rows = db.execute("SELECT event_json FROM trajectory_runtime_events "
                          "WHERE event_json LIKE '%provider.payload.measured%'").fetchall()
    events = [json.loads(row[0]) for row in rows]
    return [event for event in events if event.get("type") == "provider.payload.measured"]


def p95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    state, agents = Path(sys.argv[1]), sys.argv[2:]
    by_agent, times, missing = {}, [], []
    for agent in agents:
        database = state / "agents" / agent / "agent" / "openclaw-agent.sqlite"
        events = measured(database) if database.is_file() else []
        sizes = [event["data"]["bytes"] for event in events]
        if not sizes:
            missing.append(agent)
            continue
        by_agent[agent] = {"n": len(sizes), "max": max(sizes), "p95": p95(sizes)}
        times += [event["ts"] for event in events if event.get("ts")]
    largest = max((value["max"] for value in by_agent.values()), default=None)
    report = {"maxContextTokens": None if missing or largest is None else math.ceil(largest * 1.5),
              "byAgent": by_agent, "from": min(times, default=None), "to": max(times, default=None)}
    print(json.dumps(report, sort_keys=True))
    if missing:
        print("no provider.payload.measured events for " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

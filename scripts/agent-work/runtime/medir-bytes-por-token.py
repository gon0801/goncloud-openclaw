#!/usr/bin/env python3
"""Bytes per input token of real provider calls, to turn a model's context window (tokens) into the
byte unit that R applies to maxContextTokens (the UTF-8 size of the request body).

Each provider.payload.measured event (dispatch of one Responses call) is paired with the first
assistant usage of the same run reported after it; transcript rows stored compressed (event_zstd)
count too. Input tokens are input + cacheRead + cacheWrite, the denominator the budget charges.

Usage: medir-bytes-por-token.py <state-dir> <agent> [<agent> ...]
Prints {"n": .., "min": .., "p50": .., "p95": .., "max": .., "largest": {...}}; exits 1 with no pair.
"""
import json
import sqlite3
import sys
from compression import zstd
from contextlib import closing
from datetime import datetime
from pathlib import Path


def epoch_ms(value):
    if isinstance(value, (int, float)):
        return float(value)
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000


def pairs(database):
    with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as db:
        measured = db.execute("SELECT run_id, event_json FROM trajectory_runtime_events "
                              "WHERE event_json LIKE '%provider.payload.measured%'").fetchall()
        transcript = db.execute("SELECT event_json, event_zstd FROM transcript_events").fetchall()
    usages = {}
    for raw, packed in transcript:
        event = json.loads(raw if raw is not None else zstd.decompress(packed).decode())
        message = event.get("message") or {}
        run = (message.get("__openclaw") or {}).get("runId")
        usage = message.get("usage") or {}
        tokens = sum(usage.get(key) or 0 for key in ("input", "cacheRead", "cacheWrite"))
        if message.get("role") == "assistant" and run and tokens > 0:
            at = event.get("timestamp") or message.get("timestamp")
            usages.setdefault(run, []).append((epoch_ms(at), tokens))
    found = []
    for run, raw in measured:
        event = json.loads(raw)
        data = event.get("data") or {}
        if event.get("type") != "provider.payload.measured" or data.get("api") != "openai-responses":
            continue
        sent = epoch_ms(event["ts"])
        later = sorted(item for item in usages.get(run, []) if item[0] >= sent)
        if later:
            found.append({"bytes": data["bytes"], "tokens": later[0][1], "ts": event["ts"], "runId": run})
    return found


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    state = Path(sys.argv[1])
    found = []
    for agent in sys.argv[2:]:
        database = state / "agents" / agent / "agent" / "openclaw-agent.sqlite"
        if database.is_file():
            found += [{**pair, "agent": agent} for pair in pairs(database)]
    if not found:
        print(json.dumps({"n": 0}))
        return 1
    ratios = sorted(pair["bytes"] / pair["tokens"] for pair in found)
    pick = lambda q: round(ratios[min(len(ratios) - 1, int(q * len(ratios)))], 2)
    largest = max(found, key=lambda pair: pair["bytes"])
    print(json.dumps({"n": len(ratios), "min": round(ratios[0], 2), "p50": pick(0.5), "p95": pick(0.95),
                      "max": round(ratios[-1], 2),
                      "largest": {**largest, "ratio": round(largest["bytes"] / largest["tokens"], 2)}},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

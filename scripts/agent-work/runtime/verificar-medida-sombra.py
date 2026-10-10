#!/usr/bin/env python3
"""Check that the shadow measure is faithful: in the sandboxed rehearsal of a copy of the live
gateway, with every provider pointed at a local capture server, one real turn per session; the
bytes each provider request body had on the wire must equal the provider.payload.measured event R
recorded for it in the agent database (what medir-contexto-sombra.py reads on the live host).

A replay on a copy does not reproduce the live context (the live gateway rebuilds history the copy
lacks), so it cannot measure the limit itself; it only proves the event measures the real body.

Usage: verificar-medida-sombra.py <copy> <candidate-prefix> <agent>:<session-key> [...]
Prints one JSON line per request and {"faithful": bool, "pairs": [[wire, event], ...]}.
"""
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
import json
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ensayo_host import EnsayoHost  # noqa: E402

CAPTURED = []


def responses_events(model):
    item = {"type": "message", "id": f"msg_{uuid.uuid4().hex}", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": "OK", "annotations": []}]}
    return [{"type": "response.output_item.added", "output_index": 0, "item": item},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": {
                "id": f"resp_{uuid.uuid4().hex}", "status": "completed", "model": model, "output": [item],
                "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}}]


def chat_events(model):
    return [{"id": "c1", "object": "chat.completion.chunk", "model": model,
             "choices": [{"index": 0, "delta": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}]


class Capture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            model = json.loads(body).get("model")
        except ValueError:
            model = None
        CAPTURED.append({"path": self.path, "bytes": len(body), "model": model,
                         "session": self.headers.get("x-ensayo-session")})
        events = responses_events(model) if self.path.endswith("/responses") else chat_events(model)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        for event in events:
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


def measured_since(databases, since):
    """Event sizes from this rehearsal only: a fresh copy of the live gateway already holds real traffic."""
    sizes = []
    for database in databases:
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as db:
            rows = db.execute("SELECT event_json FROM trajectory_runtime_events "
                              "WHERE event_json LIKE '%provider.payload.measured%'").fetchall()
        for (raw,) in rows:
            event = json.loads(raw)
            if event.get("type") == "provider.payload.measured" and event.get("ts", "") >= since:
                sizes.append(event["data"]["bytes"])
    return sizes


def faithful(wire, events):
    return bool(wire) and sorted(wire) == sorted(events)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    copy, prefix, targets = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Capture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/v1"
    host = EnsayoHost.create(copy, prefix, 18795)
    config = host.config()
    for provider in config.get("models", {}).get("providers", {}).values():
        provider["baseUrl"] = base
    # The copy has no workspaces, and an agent refuses to reseed one it already attested: give every
    # agent a fresh workspace, which the gateway seeds. Bootstrap files are small next to the history.
    fresh = host.root / "workspaces"

    def reseat(node, path=""):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "workspace" and isinstance(value, str):
                    node[key] = str(fresh / (path.strip(".").replace(".", "-") or "default"))
                else:
                    reseat(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                reseat(value, f"{path}.{index}")
    reseat(config)
    host.write_config(config)
    started = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    host.start(prefix)
    summary = {}
    try:
        for target in targets:
            agent, session = target.split(":", 1)
            before = len(CAPTURED)
            run = subprocess.run([str(host.cli), "agent", "--agent", agent, "--session-key", session,
                                  "--message", "Medición de contexto del ensayo: contesta solo OK.",
                                  "--timeout", "300", "--json"], capture_output=True, text=True, timeout=400)
            requests = CAPTURED[before:]
            for request in requests:
                print(json.dumps({**request, "target": target}), flush=True)
            summary[target] = {"rc": run.returncode, "requests": len(requests),
                               "maxBytes": max((request["bytes"] for request in requests), default=None),
                               "error": None if run.returncode == 0 else (run.stderr or run.stdout)[-300:]}
    finally:
        host.stop()
        server.shutdown()
    events = measured_since(sorted((host.state / "agents").glob("*/agent/openclaw-agent.sqlite")), started)
    wire = [request["bytes"] for request in CAPTURED]
    pairs = list(zip(sorted(wire), sorted(events)))
    ok = faithful(wire, events)
    print(json.dumps({"faithful": ok, "pairs": pairs, "bySession": summary, "ensayo": str(host.root)}))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

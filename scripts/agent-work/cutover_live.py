#!/usr/bin/env python3
"""Live adoption of one managed entry (T11 :298-:299): drain and suspend its old crons, then move
ownership to the native route by generation. Every step reads the Gateway; nothing assumes.

Usage: cutover_live.py prepare|inspect|apply --state <file> [--entry <entry.json>] [--wait-seconds N]
The Gateway is reached with `openclaw gateway call` (OPENCLAW_BIN, default ~/.openclaw/bin/openclaw).
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "agent-work-cutover.v2"
LIMITS = Path(__file__).resolve().parents[2] / "docs/evidence/agent-work/limits.json"
# A drained cron must not start again before it is disabled: its next run stays this far away.
NEXT_RUN_MARGIN_MS = 1000


class CutoverRefused(RuntimeError):
    pass


class GatewayUnavailable(CutoverRefused):
    """The Gateway refused the call but said a retry may succeed (for example, while it restarts)."""


def write_state(path, state):
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(state, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def prepare(path, entry):
    path = Path(path)
    if path.exists():
        state = json.loads(path.read_text())
        if state["entry"] != entry:
            raise CutoverRefused(f"{path} already prepares another entry")
        return state
    state = {"schema": SCHEMA, "entry": entry, "generation": 1, "owner": "legacy", "suspended": {}}
    write_state(path, state)
    return state


def uncertain_operations(spool_dirs):
    found = []
    for directory in spool_dirs:
        database = Path(directory) / "host.sqlite"
        if not database.exists():
            continue
        with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as db:
            for operation_json, in db.execute(
                    "SELECT operation_json FROM operations WHERE status IN ('attempted','uncertain')"):
                found.append(json.loads(operation_json)["taskId"])
    return found


def observe(client, entry):
    jobs = client.call("cron.list", {"includeDisabled": True})["jobs"]
    legacy = [job for job in jobs if job["name"] in entry["legacyCrons"] or job["id"] in entry["legacyCrons"]]
    managed = client.call("config.get", {})["resolved"].get("managedTasks", {})
    adapters = managed.get("hosts", {}).get(entry["host"], {}).get("adapters", [])
    return {
        "legacy": legacy,
        "native": bool(managed.get("enabled")) and entry["adapter"] in adapters,
        "uncertain": uncertain_operations(entry.get("spools", [])),
    }


def fence_problems(entry, seen, now_ms):
    """Why ownership cannot move now; empty when the old crons can be suspended without cancelling."""
    problems = []
    enabled = [job for job in seen["legacy"] if job["enabled"]]
    if seen["native"] and enabled:
        problems.append(f"two emitters for {entry['id']}: {', '.join(job['name'] for job in enabled)} and "
                        f"{entry['host']}/{entry['adapter']}")
    for task in seen["uncertain"]:
        problems.append(f"uncertain admission {task} needs reconciliation")
    for job in seen["legacy"]:
        state = job.get("state") or {}
        if state.get("runningAtMs"):
            problems.append(f"{job['name']} has a turn in flight")
        elif job["enabled"] and (state.get("nextRunAtMs") or 0) - now_ms < NEXT_RUN_MARGIN_MS:
            problems.append(f"{job['name']} is about to run")
    return problems


def native_patch(entry, config, limits):
    """The managedTasks patch that opens the entry, or why it cannot open; checked before any write."""
    values = limits["productionProfile"]["values"]
    unknown = sorted(field for field, value in values.items() if value is None)
    if unknown:
        raise CutoverRefused("production limits are unknown: " + ", ".join(unknown))
    managed = config["resolved"].get("managedTasks", {})
    host = managed.get("hosts", {}).get(entry["host"], {})
    device = host.get("deviceId") or entry.get("deviceId")
    root = managed.get("instructionRoot") or entry.get("instructionRoot")
    missing = [name for name, value in (("deviceId", device), ("instructionRoot", root)) if not value]
    if missing:
        raise CutoverRefused(f"{entry['id']} needs {', '.join(missing)} to open {entry['host']}/{entry['adapter']}")
    return {"managedTasks": {
        "enabled": True, "instructionRoot": root, "profile": values,
        "runTimeoutSeconds": managed.get("runTimeoutSeconds") or entry.get("runTimeoutSeconds", 3600),
        "hosts": {entry["host"]: {"deviceId": device,
                                  "adapters": sorted(set(host.get("adapters", [])) | {entry["adapter"]})}}}}


def apply(path, client, now_ms, wait_seconds=0, sleep=time.sleep, limits_path=LIMITS):
    path = Path(path)
    state = json.loads(path.read_text())
    entry = state["entry"]
    if state["owner"] == "native":
        return "already native"
    limits = json.loads(Path(limits_path).read_text())
    if state["owner"] == "transferring":
        return finish_transfer(path, state, client, limits, wait_seconds, sleep)
    native_patch(entry, client.call("config.get", {}), limits)
    deadline = time.monotonic() + wait_seconds
    while True:
        seen = observe(client, entry)
        problems = fence_problems(entry, seen, now_ms())
        if not problems:
            break
        if time.monotonic() >= deadline:
            raise CutoverRefused("; ".join(problems))
        sleep(0.25)
    for job in seen["legacy"]:
        if not job["enabled"]:
            continue
        state["suspended"][job["id"]] = {"name": job["name"], "job": job, "disabledAtMs": now_ms()}
        write_state(path, state)
        client.call("cron.update", {"id": job["id"], "patch": {"enabled": False}})
    seen = observe(client, entry)
    for job in seen["legacy"]:
        if job["enabled"] or (job.get("state") or {}).get("runningAtMs"):
            raise CutoverRefused(f"{job['name']} did not stop")
        record = state["suspended"].get(job["id"])
        if record:
            cancelled = [run for run in client.call("cron.runs", {"id": job["id"]})["entries"]
                         if run["ts"] >= record["disabledAtMs"] and "disabled by operator" in (run.get("error") or "")]
            if cancelled:
                raise CutoverRefused(f"{job['name']} was cancelled instead of drained")
    state["owner"], state["generation"] = "transferring", state["generation"] + 1
    write_state(path, state)
    return finish_transfer(path, state, client, limits, wait_seconds, sleep)


def finish_transfer(path, state, client, limits, wait_seconds, sleep):
    """Open the native route; resumable, since changing managedTasks restarts the Gateway."""
    entry = state["entry"]
    deadline = time.monotonic() + max(wait_seconds, 60)
    patched = False
    while True:
        try:
            if observe(client, entry)["native"]:
                break
            if not patched:
                config = client.call("config.get", {})
                patch = native_patch(entry, config, limits)
                # R guards managedTasks.enabled behind an optimistic write: the patch names the config it read.
                client.call("config.patch", {"raw": json.dumps(patch), "baseHash": config["hash"]})
                patched = True
                continue
        except GatewayUnavailable:
            pass
        if time.monotonic() >= deadline:
            raise CutoverRefused(f"{entry['host']}/{entry['adapter']} did not open")
        sleep(0.5)
    state["owner"] = "native"
    write_state(path, state)
    return "transferred"


class CliClient:
    def __init__(self, binary):
        self.binary = binary

    def call(self, method, params):
        run = subprocess.run([self.binary, "gateway", "call", method, "--params", json.dumps(params), "--json"],
                             capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            text = run.stderr.strip() or run.stdout.strip()
            try:
                error = json.loads(run.stdout).get("error", {})
            except ValueError:
                error = {}
            # A restarting Gateway refuses the socket (transport error) or closes admission (retryable).
            retryable = error.get("retryable") or error.get("type") == "gateway_transport_error"
            raise (GatewayUnavailable if retryable else CutoverRefused)(f"{method}: {text}")
        return json.loads(run.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "inspect", "apply"))
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--entry", type=Path)
    parser.add_argument("--wait-seconds", type=float, default=0)
    parser.add_argument("--limits", type=Path, default=LIMITS)
    args = parser.parse_args()
    client = CliClient(os.environ.get("OPENCLAW_BIN", str(Path.home() / ".openclaw/bin/openclaw")))
    try:
        if args.command == "prepare":
            print(json.dumps(prepare(args.state, json.loads(args.entry.read_text())), sort_keys=True))
        elif args.command == "inspect":
            state = json.loads(args.state.read_text())
            seen = observe(client, state["entry"])
            print(json.dumps({"state": state, "problems": fence_problems(state["entry"], seen,
                                                                          int(time.time() * 1000))}, sort_keys=True))
        else:
            print(apply(args.state, client, lambda: int(time.time() * 1000), args.wait_seconds,
                        limits_path=args.limits))
    except CutoverRefused as refused:
        print(f"cutover: {refused}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Live adoption of one managed entry (T11 :298-:299): drain and suspend its old crons, then move
ownership to the native route by generation. Every step reads the Gateway; nothing assumes.

Usage: cutover_live.py prepare|inspect|apply --state <file> [--entry <entry.json>] [--wait-seconds N]
The Gateway is reached with `openclaw gateway call` (OPENCLAW_BIN, default ~/.openclaw/bin/openclaw).
"""
import argparse
from contextlib import closing
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
# R's ManagedTaskBudgetProfileSchema; a profile missing one of them is not a finite profile.
PROFILE_FIELDS = ("maxConcurrentTasks", "maxDepth", "maxChildren", "maxModelCalls", "maxInputTokens",
                  "maxOutputTokens", "maxCacheReadTokens", "maxContextTokens", "maxTreeTokens",
                  "maxAutomaticRecoveryCalls")
# A drained cron must not start again before it is disabled: its next run stays this far away.
NEXT_RUN_MARGIN_MS = 1000


class CutoverRefused(RuntimeError):
    pass


class RollbackFailed(CutoverRefused):
    """The rollback stopped; the candidate keeps running with admission frozen and results kept."""


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
        with closing(sqlite3.connect(f"file:{database}?mode=ro", uri=True)) as db:
            for operation_json, in db.execute(
                    "SELECT operation_json FROM operations WHERE status IN ('attempted','uncertain')"):
                found.append(json.loads(operation_json)["taskId"])
    return found


def observe(client, entry):
    jobs = client.call("cron.list", {"includeDisabled": True})["jobs"]
    matches = {name: [job for job in jobs if name in (job["name"], job["id"])] for name in entry["legacyCrons"]}
    managed = client.call("config.get", {})["resolved"].get("managedTasks", {})
    adapters = managed.get("hosts", {}).get(entry["host"], {}).get("adapters", [])
    spools = entry.get("spools", [])
    return {
        "legacy": [found[0] for found in matches.values() if len(found) == 1],
        # An entry that does not name exactly the Gateway's crons would leave an old emitter running.
        "unmatched": {name: len(found) for name, found in matches.items() if len(found) != 1},
        "missingSpools": [spool for spool in spools if not Path(spool).is_dir()],
        "native": bool(managed.get("enabled")) and entry["adapter"] in adapters,
        "uncertain": uncertain_operations(spools),
    }


def fence_problems(entry, seen, now_ms):
    """Why ownership cannot move now; empty when the old crons can be suspended without cancelling."""
    problems = [f"{entry['id']} names {name}, which matches {count} Gateway crons"
                for name, count in seen["unmatched"].items()]
    problems += [f"spool {spool} does not exist" for spool in seen["missingSpools"]]
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
    unknown = sorted({field for field, value in values.items() if value is None}
                     | {field for field in PROFILE_FIELDS if field not in values})
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


def retrying(step, deadline, sleep):
    """Run one Gateway step, waiting through a restart (GatewayUnavailable) until the deadline."""
    while True:
        try:
            return step()
        except GatewayUnavailable:
            if time.monotonic() >= deadline:
                raise
            sleep(0.5)


def apply(path, client, now_ms, wait_seconds=0, sleep=time.sleep, limits_path=LIMITS):
    path = Path(path)
    state = json.loads(path.read_text())
    entry = state["entry"]
    if state["owner"] == "native":
        return "already native"
    limits = json.loads(Path(limits_path).read_text())
    deadline = time.monotonic() + wait_seconds
    if state["owner"] == "transferring":
        return finish_transfer(path, state, client, limits, wait_seconds, sleep)
    retrying(lambda: native_patch(entry, client.call("config.get", {}), limits), deadline, sleep)
    while True:
        seen = retrying(lambda: observe(client, entry), deadline, sleep)
        problems = fence_problems(entry, seen, now_ms())
        if not problems:
            break
        if time.monotonic() >= deadline:
            raise CutoverRefused("; ".join(problems))
        sleep(0.25)
    disabled_now = []
    for job in seen["legacy"]:
        if not job["enabled"]:
            continue
        state["suspended"][job["id"]] = {"name": job["name"], "job": job, "disabledAtMs": now_ms()}
        write_state(path, state)
        retrying(lambda: client.call("cron.update", {"id": job["id"], "patch": {"enabled": False}}), deadline, sleep)
        disabled_now.append(job["id"])
    seen = retrying(lambda: observe(client, entry), deadline, sleep)
    for job in seen["legacy"]:
        if job["enabled"] or (job.get("state") or {}).get("runningAtMs"):
            raise CutoverRefused(f"{job['name']} did not stop")
    # Only a cron this run disabled can have been cancelled by it. A cancellation is recorded and
    # refuses once; the same command then resumes, since the cron is already suspended.
    for job_id in disabled_now:
        record = state["suspended"][job_id]
        runs = retrying(lambda: client.call("cron.runs", {"id": job_id}), deadline, sleep)["entries"]
        if any(run["ts"] >= record["disabledAtMs"] and "disabled by operator" in (run.get("error") or "")
               for run in runs):
            state.setdefault("cancelled", {})[job_id] = {"name": record["name"], "atMs": now_ms()}
            write_state(path, state)
            raise CutoverRefused(f"{record['name']} was cancelled instead of drained; check its last turn, "
                                 "then run apply again")
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


def snapshot_problems(snapshot, previous_schema):
    """A rollback snapshot is the pre-install photo: databases the previous binary reads, and its config."""
    snapshot = Path(snapshot)
    problems = []
    database = snapshot / "openclaw.sqlite"
    if not database.is_file():
        return [f"snapshot {snapshot} has no openclaw.sqlite"]
    try:
        with closing(sqlite3.connect(f"file:{database}?immutable=1", uri=True)) as db:
            version = db.execute("PRAGMA user_version").fetchone()[0]
            check = db.execute("PRAGMA quick_check").fetchone()[0]
    except sqlite3.DatabaseError as error:
        return [f"snapshot database is unreadable: {error}"]
    if version != previous_schema:
        problems.append(f"snapshot state schema is {version}, the previous binary reads {previous_schema}")
    if check != "ok":
        problems.append(f"snapshot database fails quick_check: {check}")
    config = snapshot / "openclaw.json"
    if not config.is_file():
        problems.append(f"snapshot {snapshot} has no openclaw.json")
    elif "managedTasks" in json.loads(config.read_text()):
        problems.append("snapshot config already has managedTasks; the previous binary rejects it")
    return problems


def freeze(client, wait_seconds=120, sleep=time.sleep):
    """Close native admission; the managedTasks change restarts the Gateway, so wait for it."""
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            config = client.call("config.get", {})
            if not config["resolved"].get("managedTasks", {}).get("enabled"):
                return
            client.call("config.patch", {"raw": json.dumps({"managedTasks": {"enabled": False}}),
                                         "baseHash": config["hash"]})
        except GatewayUnavailable:
            pass
        if time.monotonic() >= deadline:
            raise RollbackFailed("admission did not freeze")
        sleep(0.5)


def suspend_legacy(client, state):
    """The snapshot predates the cutover, so it holds the old crons enabled: suspend them again."""
    jobs = {job["id"]: job for job in client.call("cron.list", {"includeDisabled": True})["jobs"]}
    for job_id in state["suspended"]:
        if jobs.get(job_id, {}).get("enabled"):
            client.call("cron.update", {"id": job_id, "patch": {"enabled": False}})
    jobs = {job["id"]: job for job in client.call("cron.list", {"includeDisabled": True})["jobs"]}
    revived = [state["suspended"][job_id]["name"] for job_id in state["suspended"]
               if jobs.get(job_id, {}).get("enabled")]
    if revived:
        raise RollbackFailed(f"old crons came back enabled: {', '.join(revived)}")


def rollback(path, host, client_for, candidate, previous, snapshot, previous_schema=19):
    """Back to the previous binary and config. The previous binary cannot read the migrated schema, so
    the pre-install snapshot is restored; the entry's old crons stay suspended (never re-enabled here).
    Any failure keeps the candidate running with admission frozen; host result spools are never touched."""
    path = Path(path)
    state = json.loads(path.read_text())
    progress = state.setdefault("rollback", {"phase": "start"})
    problems = snapshot_problems(snapshot, previous_schema)
    if progress["phase"] == "start":
        if problems:
            freeze(client_for())
            raise RollbackFailed("; ".join(problems) + "; the candidate keeps running with admission frozen")
        freeze(client_for())
        progress["phase"] = "frozen"
        write_state(path, state)
    if progress["phase"] == "frozen":
        host.stop()
        host.restore(snapshot)
        progress["phase"] = "restored"
        write_state(path, state)
    if progress["phase"] == "restored":
        try:
            host.start(previous, skip_cron=True)
        except RuntimeError as error:
            # The restored config has no managedTasks: the candidate reopens the snapshot frozen. The
            # snapshot predates the cutover, so its old crons are enabled: suspend them here too.
            host.start(candidate, skip_cron=True)
            suspend_legacy(client_for(), state)
            progress["phase"] = "failed-candidate-frozen"
            write_state(path, state)
            raise RollbackFailed(f"previous binary did not start ({str(error).splitlines()[0]}); "
                                 "the candidate runs on the restored snapshot with admission frozen")
        suspend_legacy(client_for(), state)
        host.stop()
        host.start(previous, skip_cron=False)
        suspend_legacy(client_for(), state)
        state["owner"], state["generation"] = "legacy", state["generation"] + 1
        progress["phase"] = "done"
        write_state(path, state)
        return "rolled-back; old crons stay suspended"
    if progress["phase"] == "done":
        return "already rolled back"
    raise RollbackFailed(f"rollback stopped at {progress['phase']}; inspect before retrying")


class CliClient:
    def __init__(self, binary, timeout=120):
        self.binary, self.timeout = binary, timeout

    def call(self, method, params):
        try:
            run = subprocess.run([self.binary, "gateway", "call", method, "--params", json.dumps(params), "--json"],
                                 capture_output=True, text=True, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            raise GatewayUnavailable(f"{method}: no answer in {self.timeout} s") from None
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
            seen = retrying(lambda: observe(client, state["entry"]), time.monotonic() + args.wait_seconds, time.sleep)
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

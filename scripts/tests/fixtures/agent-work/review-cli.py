#!/usr/bin/env python3
"""Reviewer CLI double for review_tail_restart, run inside a real tmux pane.

For each assignment that TmuxTransport types it writes its own agent-work.accept.v1. The
first one is the review: it prints its verdict, pushes it out of the last 80 lines with
more output, and leaves the result file. Later ones (the correction) are only accepted.
With a path argument it appends its start and every acceptance there, so a test counts
what the CLI did from outside the Gateway.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys

VERDICT = "VEREDICTO cambios: falta la prueba del borde"
TRAILING_LINES = 200
# Bounded, so a pane left behind by a killed test closes on its own.
LINGER_SECONDS = 600


def atomic(path, value):
    pending = path.with_name(path.name + ".pending")
    pending.write_text(json.dumps(value))
    os.replace(pending, path)


def record(event, **fields):
    if len(sys.argv) > 1:
        with open(sys.argv[1], "a") as log:
            log.write(json.dumps({"event": event, "pid": os.getpid(), **fields}) + "\n")


def main():
    signal.alarm(LINGER_SECONDS)  # SIGALRM ends the double even while readline blocks
    record("started")
    print("review-cli ready", flush=True)
    reviewed = False
    while True:
        typed = sys.stdin.readline()
        if not typed:
            return
        match = re.search(r"Open assignment JSON at (\S+\.json)\. ", typed)
        if match is None:
            continue
        assignment = json.loads(Path(match.group(1)).read_text())
        atomic(Path(assignment["acceptRef"]), {"schema": "agent-work.accept.v1", **{
            field: assignment[field] for field in ("hostId", "taskId", "generation", "instanceId",
                                                   "claimId", "capability")}})
        record("accepted", taskId=assignment["taskId"], generation=assignment["generation"])
        print(f"review-cli accepted {assignment['taskId']}", flush=True)
        if reviewed:
            continue
        reviewed = True
        result = Path(assignment["resultRef"])
        workspace = Path(assignment["workspaceRef"])
        workspace.mkdir(parents=True, exist_ok=True)
        findings = workspace / "findings.txt"
        findings.write_text(VERDICT + "\n")
        print(VERDICT, flush=True)
        for number in range(TRAILING_LINES):
            print(f"review-cli trabajo posterior {number}", flush=True)
        print("review-cli review done", flush=True)
        atomic(result, {
            "schema": "agent-work.result.v1", "kind": "produced",
            "hostId": assignment["hostId"], "taskId": assignment["taskId"],
            "generation": assignment["generation"], "instanceId": assignment["instanceId"],
            "producerId": assignment["producerId"], "capability": assignment["capability"],
            "observedRevision": assignment["inputRevision"],
            "typedPayload": {"verdict": "changes", "findingsRef": "findings.txt"},
            "artifactRef": str(findings),
            "digest": hashlib.sha256(findings.read_bytes()).hexdigest(),
        })


if __name__ == "__main__":
    main()

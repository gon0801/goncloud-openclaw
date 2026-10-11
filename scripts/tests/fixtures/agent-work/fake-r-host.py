#!/usr/bin/env python3
"""An `openclaw gateway call` stand-in that answers the host RPCs of a closing pass the way R does.

State lives in $FAKE_R_STATE (JSON): {"cancellations": {taskId: cancellationId}, "results": [taskId],
"closures": {taskId: receipt}}. Every call is appended to $FAKE_R_LOG as {"method", "params"}.
managedTasks.host.claim is logged and answers null, so a test can count claims. Any other method fails
the way the Gateway rejects a request.
"""

import json
import os
import sys
import time
from pathlib import Path


def reject(message):
    print(json.dumps({"ok": False, "error": {"type": "gateway_request_error", "message": message}}))
    raise SystemExit(1)


def main(argv):
    method = argv[argv.index("call") + 1]
    params = json.loads(argv[argv.index("--params") + 1])
    with Path(os.environ["FAKE_R_LOG"]).open("a", encoding="utf-8") as log:
        log.write(json.dumps({"method": method, "params": params}, sort_keys=True) + "\n")
    state_path = Path(os.environ["FAKE_R_STATE"])
    state = json.loads(state_path.read_text())
    if method == "managedTasks.host.claim":
        print("null")
        return
    capability = params.get("capability", {})
    task_id, generation = capability.get("taskId"), capability.get("generation")
    if method == "managedTasks.host.cancellation":
        print(json.dumps({"taskId": task_id, "generation": generation,
                          "cancellationId": state["cancellations"].get(task_id)}))
        return
    if method == "managedTasks.host.close":
        terminal = params["state"] in ("AbsenceVerified", "ReleasedAdopted")
        if terminal and task_id not in state["results"] and task_id not in state["cancellations"]:
            reject("Managed host closure requires a final result or cancellation")
        entry = {"taskId": task_id, "generation": generation, "state": params["state"],
                 "reason": params["reason"], "evidenceDigest": params["evidenceDigest"]}
        existing = state["closures"].get(task_id)
        if existing and existing["state"] in ("AbsenceVerified", "ReleasedAdopted"):
            if {k: existing[k] for k in entry} != entry:
                reject("Managed host closure conflict")
            print(json.dumps(existing))
            return
        state["closures"][task_id] = {**entry, "updatedAtMs": int(time.time() * 1000)}
        state_path.write_text(json.dumps(state, sort_keys=True))
        print(json.dumps(state["closures"][task_id]))
        return
    reject(f"fake R does not serve {method}")


if __name__ == "__main__":
    main(sys.argv[1:])

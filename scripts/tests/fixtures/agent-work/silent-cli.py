#!/usr/bin/env python3
"""CLI double for cli_silent_failure, run inside a real tmux pane.

It reads the assignment that TmuxTransport types, accepts it as a CLI must (its own
agent-work.accept.v1), then fails in the way named by its argument and never writes a
valid report. permission-before-accept fails earlier: it opens the opencode permission
dialog instead of accepting.
"""

import json
import os
from pathlib import Path
import re
import sys
import time

# SilentPromptTest.PROCEED: the measured claude dialog (test-tmux-activity-watch.sh 2g).
DIALOG = (" Detected a destructive delete command:\n rm -rf /tmp/e1verif /tmp/mig1.log\n"
          " Run it? [plugin:claude-code-harness]\n Do you want to proceed?\n   1. Yes\n   2. No\n"
          " Esc to cancel  Tab to amend\n")
# The opencode 1.18.35 dialog of canary 8 (2026-10-12): the CLI staged its accept object in /tmp,
# outside the external_directory rule, and opencode asked before the acceptance was written.
OPENCODE_DIALOG = ("\n  ┃\n  ┃  △ Permission required\n  ┃    ← Access external directory /tmp\n  ┃\n"
                   "  ┃  Patterns\n  ┃\n  ┃  - /tmp/*\n  ┃\n"
                   "  ┃   Allow once   Allow always   Reject                               "
                   "ctrl+f fullscreen  ⇆ select  enter confirm\n")
# Bounded, so a pane left behind by a killed test closes on its own.
LINGER_SECONDS = 600


def main(cause):
    # The empty `❯` composer TmuxTransport waits for; the terminal echoes what is typed after it.
    sys.stdout.write("silent-cli ready\n❯ ")
    sys.stdout.flush()
    typed = sys.stdin.readline()
    match = re.search(r"Open assignment JSON at (\S+\.json)\. ", typed)
    if match is None:
        print("silent-cli saw no assignment", flush=True)
        time.sleep(LINGER_SECONDS)
        return
    assignment = json.loads(Path(match.group(1)).read_text())
    if cause == "permission-before-accept":
        sys.stdout.write(OPENCODE_DIALOG)
        sys.stdout.flush()
        time.sleep(LINGER_SECONDS)
        return
    accept = Path(assignment["acceptRef"])
    pending = accept.with_name(accept.name + ".pending")
    pending.write_text(json.dumps({"schema": "agent-work.accept.v1", **{
        field: assignment[field] for field in ("hostId", "taskId", "generation", "instanceId",
                                               "claimId", "capability")}}))
    os.replace(pending, accept)
    if cause == "transport-unavailable":
        return
    if cause == "invalid-result":
        target = Path(assignment["resultRef"])
        pending = target.with_name(target.name + ".pending")
        pending.write_text(json.dumps({"schema": "agent-work.result.v1", "kind": "produced",
                                       "taskId": assignment["taskId"]}))
        os.replace(pending, target)
    elif cause == "permission-required":
        sys.stdout.write(DIALOG)
        sys.stdout.flush()
    time.sleep(LINGER_SECONDS)


if __name__ == "__main__":
    main(sys.argv[1])

#!/usr/bin/env python3
"""CLI double with a `❯` composer, run inside a real tmux pane, for TmuxTransport.

Usage: composer-cli.py <submitted-log> <echo-delay-seconds | no-echo>

Keys are read raw. Typed text is painted after the composer prompt in the default colour,
each chunk after the echo delay (an Ink TUI renders a moment after the keys arrive); with
no-echo nothing is painted. Ctrl-U clears the composer. Enter submits: the line is appended
to the log, and a line that names an assignment JSON gets its agent-work.result.v1 written.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import select
import sys
import termios
import time
import tty

# Bounded, so a pane left behind by a killed test closes on its own.
LINGER_SECONDS = 600


def paint(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def submit(line, log):
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(line + "\n")
    match = re.search(r"(/\S+\.json)", line)
    if match is None:
        return
    assignment = json.loads(Path(match.group(1)).read_text())
    evidence = Path(assignment["workspaceRef"]) / "evidence.txt"
    result = Path(assignment["resultRef"])
    pending = result.with_name(result.name + ".pending")
    pending.write_text(json.dumps({
        "schema": "agent-work.result.v1", "kind": "produced", "hostId": assignment["hostId"],
        "taskId": assignment["taskId"], "generation": assignment["generation"],
        "instanceId": assignment["instanceId"], "producerId": assignment["producerId"],
        "capability": assignment["capability"], "observedRevision": assignment["inputRevision"],
        "typedPayload": {"verdict": "approved", "evidenceRef": "evidence.txt"},
        "artifactRef": str(evidence), "digest": hashlib.sha256(evidence.read_bytes()).hexdigest()}))
    os.replace(pending, result)


def main(log, mode):
    echo = mode != "no-echo"
    delay = float(mode) if echo else 0.0
    stdin = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin)
    tty.setraw(stdin)
    until = time.monotonic() + LINGER_SECONDS
    composer = ""
    try:
        paint("composer-cli ready\r\n❯ ")
        while time.monotonic() < until:
            if not select.select([stdin], [], [], 0.1)[0]:
                continue
            chunk = os.read(stdin, 4096).decode("utf-8", "replace")
            if echo:
                time.sleep(delay)
            for key in chunk:
                if key == "\r":
                    paint("\r\n")
                    submit(composer, log)
                    composer = ""
                    paint("❯ ")
                elif key == "\x15":
                    composer = ""
                    paint("\r\x1b[2K❯ ")
                elif key.isprintable():
                    composer += key
                    if echo:
                        paint(key)
    finally:
        termios.tcsetattr(stdin, termios.TCSANOW, saved)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

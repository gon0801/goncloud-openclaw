#!/usr/bin/env python3
"""CLI double for cli_delivery_acceptance, run inside a real tmux pane.

It never takes the assignment and never writes agent-work.accept.v1:

- phantom: a composer that paints what is typed as dimmed text, like a ghost suggestion,
  and never submits it (Enter does nothing). The screen shows the assignment path.
- busy: a session at work that paints its indicator and drops its input unprocessed, with no
  echo. The screen never shows the reference.

Every byte that reaches the pane is logged to DELIVERY_CLI_RECEIVED, so the test counts the
typing where it lands.
"""

import os
import select
import sys
import termios
import time

# Bounded, so a pane left behind by a killed test closes on its own.
LINGER_SECONDS = 600
TICK_SECONDS = 0.1
DIM, RESET = "\x1b[2m", "\x1b[0m"
RECEIVED = os.environ.get("DELIVERY_CLI_RECEIVED")


def received(chunk):
    if RECEIVED:
        with open(RECEIVED, "ab") as log:
            log.write(chunk)


def quiet_terminal():
    """No echo and no line mode: every key reaches the double as it arrives."""
    attributes = termios.tcgetattr(sys.stdin.fileno())
    attributes[3] &= ~(termios.ECHO | termios.ICANON)
    attributes[6][termios.VMIN] = 1
    attributes[6][termios.VTIME] = 0
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, attributes)


def phantom(until):
    quiet_terminal()
    sys.stdout.write("delivery-cli ready (phantom)\n> ")
    sys.stdout.flush()
    while time.monotonic() < until:
        ready, _, _ = select.select([sys.stdin.fileno()], [], [], TICK_SECONDS)
        if not ready:
            continue
        raw = os.read(sys.stdin.fileno(), 4096)
        received(raw)
        chunk = raw.decode("utf-8", "replace")
        # The suggestion stays in the composer: Enter submits nothing.
        shown = "".join(c for c in chunk if c.isprintable())
        if shown:
            sys.stdout.write(DIM + shown + RESET)
            sys.stdout.flush()


def busy(until):
    quiet_terminal()
    sys.stdout.write("delivery-cli ready (busy)\n")
    started = time.monotonic()
    while time.monotonic() < until:
        # Whatever was typed is logged and dropped: the session never took the input.
        while select.select([sys.stdin.fileno()], [], [], 0)[0]:
            received(os.read(sys.stdin.fileno(), 4096))
        sys.stdout.write(f"\r* Working... ({int(time.monotonic() - started)}s - esc to interrupt)")
        sys.stdout.flush()
        time.sleep(TICK_SECONDS)


def main(mode):
    until = time.monotonic() + LINGER_SECONDS
    {"phantom": phantom, "busy": busy}[mode](until)


if __name__ == "__main__":
    main(sys.argv[1])

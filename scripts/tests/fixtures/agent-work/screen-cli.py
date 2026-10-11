#!/usr/bin/env python3
"""A pane that paints a captured CLI screen, for the host's dialog handling in a real tmux pane.

Usage: screen-cli.py <screen.ans> <after.ans> <key-log>

Paints <screen.ans>, then reads keys raw. Each key is appended to <key-log> by name (Escape, Enter,
or its repr), and the pane repaints <after.ans>, as opencode closes its dialog on any answer.
"""

import os
import select
import sys
import termios
import time
import tty

# Bounded, so a pane left behind by a killed test closes on its own.
LINGER_SECONDS = 600
NAMES = {b"\x1b": "Escape", b"\r": "Enter", b"\n": "Enter"}


def paint(path):
    with open(path, encoding="utf-8") as stream:
        screen = stream.read().rstrip("\n")
    os.write(1, ("\x1b[2J\x1b[H" + screen.replace("\n", "\r\n")).encode())


def main(screen, after, log):
    paint(screen)
    saved = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        deadline = time.monotonic() + LINGER_SECONDS
        while time.monotonic() < deadline:
            if not select.select([0], [], [], 0.2)[0]:
                continue
            key = os.read(0, 1)
            with open(log, "a", encoding="utf-8") as stream:
                stream.write(NAMES.get(key, repr(key)) + "\n")
            paint(after)
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main(*sys.argv[1:])

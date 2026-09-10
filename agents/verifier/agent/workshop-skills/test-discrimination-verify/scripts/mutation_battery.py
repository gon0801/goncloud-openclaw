#!/usr/bin/env python3
"""Mutation battery for proving test discrimination.

One mutation per protected behavior; each run is classified ROJO / VERDE / INVALID.
INVALID means the run cannot judge discrimination (syntax error, or collected
count differs from baseline) -- never report INVALID as ROJO or VERDE.

Adapt the CONFIG block to the target repo, then run with the repo's venv python
from the repo root:

    .venv/bin/python mutation_battery.py

Every mutation is restored from the in-memory original after each run; the
original is also written to a backup file and hashed so restoration is provable.
"""

from __future__ import annotations

import ast
import hashlib
import pathlib
import re
import subprocess
import sys

# --- CONFIG -----------------------------------------------------------------
REPO = pathlib.Path.cwd()                    # run from the repo root
MODULE = REPO / "app/redaction.py"           # file under test (the protection)
TESTFILE = "tests/test_redaction.py"         # focused test file
PYTHON = str(REPO / ".venv/bin/python")      # interpreter for pytest + syntax
BACKUPDIR = pathlib.Path("/tmp/orbit_verify")

# Each entry: (name, old_exact_substring, new_substring). `old` must appear
# exactly once. The replacement must mirror the REAL bug shape (a syntactically
# valid revert), not a line deletion that raises IndentationError.
MUTATIONS: list[tuple[str, str, str]] = [
    # ("M01_floor_removed",
    #  "    if not value:\n        return\n",
    #  "    if not value or len(value) < 8:\n        return\n"),
]
# ----------------------------------------------------------------------------


def _run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=REPO, capture_output=True, text=True)


def _collected(python: str) -> int | None:
    out = _run([python, "-m", "pytest", TESTFILE, "--collect-only", "-q", "-p", "no:cacheprovider"])
    m = re.search(r"(\d+) tests collected", out.stdout)
    return int(m.group(1)) if m else None


def main() -> int:
    if not MODULE.exists():
        print(f"module not found: {MODULE}")
        return 2
    if not MUTATIONS:
        print("no mutations configured")
        return 2

    original = MODULE.read_text()
    backup = BACKUPDIR / (MODULE.name + ".orig")
    BACKUPDIR.mkdir(parents=True, exist_ok=True)
    backup.write_text(original)
    print("module sha256:", hashlib.sha256(original.encode()).hexdigest())

    baseline = _collected(PYTHON)
    print(f"baseline collected: {baseline}")
    if baseline is None:
        print("cannot establish baseline collected count; aborting")
        return 2

    verdicts: dict[str, str] = {}
    for name, old, new in MUTATIONS:
        if original.count(old) != 1:
            print(f"{name} | OLD_COUNT={original.count(old)} -> INVALID MUTATION DEFINITION")
            verdicts[name] = "INVALID"
            continue

        MODULE.write_text(original.replace(old, new))
        try:
            try:
                ast.parse(MODULE.read_text())
                syntax_ok = True
            except SyntaxError as exc:
                syntax_ok = False
                print(f"{name} | SyntaxError: {exc}")

            collected = _collected(PYTHON)
            out = _run([PYTHON, "-m", "pytest", TESTFILE, "-q", "--tb=short", "-rf",
                        "-p", "no:cacheprovider"]).stdout
            failed = re.findall(r"^FAILED (\S+)", out, re.M)
            errored = re.findall(r"^ERROR (\S+)", out, re.M)

            if not syntax_ok or collected != baseline:
                verdict = "INVALID"
            elif failed or errored:
                verdict = "ROJO"
            else:
                verdict = "VERDE"
        finally:
            MODULE.write_text(original)

        verdicts[name] = verdict
        print(f"{name} | syntax_ok={syntax_ok} collected={collected} | {verdict} | "
              f"failed={failed} errors={errored}")

    restored = MODULE.read_text() == original
    print("restored:", restored)
    print("summary:", {k: v for k, v in verdicts.items()})
    if not restored:
        print("RESTORATION FAILED - restore manually from", backup)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())

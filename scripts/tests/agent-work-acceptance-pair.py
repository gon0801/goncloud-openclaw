#!/usr/bin/env python3
"""Corre una vez cada prueba que cita la matriz de aceptación sobre el par G/R y escribe acceptance-pair.json.

Uso: AGENT_WORK_RUNTIME_SOURCE=<R construido> LANG=en_US.UTF-8 python3 scripts/tests/agent-work-acceptance-pair.py
Los logs quedan en docs/evidence/agent-work/par-final/. El estricto de test_agent_work_acceptance.py lo lee.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
from test_agent_work_acceptance import PAIR_DOC, matrix_refs, matrix_rows  # noqa: E402

OUT = ROOT / "docs/evidence/agent-work/par-final"
TIMEOUT = 3600
PY_RUNNER = r"""
import importlib.util, json, sys, unittest
import os
path, out, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
sys.path.insert(0, os.path.dirname(os.path.abspath(path)))
spec = importlib.util.spec_from_file_location("cited", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
suite = unittest.TestSuite()
def walk(item):
    if isinstance(item, unittest.TestSuite):
        for child in item:
            walk(child)
    elif item.id().rsplit(".", 1)[-1] in names:
        suite.addTest(item)
walk(unittest.defaultTestLoader.loadTestsFromModule(module))
status = {name: {"outcome": "missing", "skips": []} for name in names}
class Result(unittest.TextTestResult):
    def _set(self, test, outcome, skip=None):
        entry = status[test.id().rsplit(".", 1)[-1]]
        if entry["outcome"] in ("missing", "ok"):
            entry["outcome"] = outcome
        if skip is not None:
            entry["skips"].append(skip)
    def addSuccess(self, test):
        super().addSuccess(test); self._set(test, "ok")
    def addFailure(self, test, err):
        super().addFailure(test, err); self._set(test, "FAIL")
    def addError(self, test, err):
        super().addError(test, err); self._set(test, "ERROR")
    def addSkip(self, test, reason):
        super().addSkip(test, reason); self._set(test, "skipped", reason)
    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self._set(test, "FAIL")
unittest.TextTestRunner(verbosity=2, resultclass=Result).run(suite)
json.dump(status, open(out, "w"))
"""


def git(*args, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def run(index, label, command):
    log = OUT / f"{index:02d}-{label}.log"
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        stream.write("$ " + " ".join(command) + "\n")
        stream.flush()
        try:
            rc = subprocess.run(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            rc = 124
        seconds = round(time.monotonic() - started, 1)
        stream.write(f"\nrc={rc} seconds={seconds}\n")
    print(f"{label}: rc={rc} {seconds}s", flush=True)
    return rc, seconds, log


def main():
    r_root = os.environ.get("AGENT_WORK_RUNTIME_SOURCE")
    if not r_root:
        sys.exit("set AGENT_WORK_RUNTIME_SOURCE to a built R checkout")
    OUT.mkdir(parents=True, exist_ok=True)
    doc = {
        "schema": "agent-work-acceptance-pair.v1",
        "G": git("rev-parse", "HEAD").strip(),
        "gDirty": [line for line in git("status", "--porcelain").splitlines() if line != "?? out/"],
        "R": git("rev-parse", "HEAD", cwd=r_root).strip(),
        "rBuildCommit": json.loads((Path(r_root) / "dist/build-info.json").read_text())["commit"],
        "rDiffSha256": hashlib.sha256(subprocess.run(["git", "-C", r_root, "diff", "--binary", "HEAD"], check=True,
                                                     capture_output=True).stdout).hexdigest(),
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "runs": [],
    }
    refs = matrix_refs(matrix_rows())
    shell = [ref for ref in refs if ref.split("::")[0].endswith(".sh")]
    python = {}
    for ref in refs:
        path, name = ref.split("::")
        if path.endswith(".py"):
            python.setdefault(path, []).append(name)
    index = 0
    for ref in shell:
        path, case = ref.split("::")
        index += 1
        rc, seconds, log = run(index, f"{Path(path).stem}-{case}", ["bash", path, case])
        skipped = sum(int(n) for n in re.findall(r"skipped=(\d+)", log.read_text(encoding="utf-8")))
        doc["runs"].append({"ref": ref, "rc": rc, "seconds": seconds, "skips": [f"{skipped} (count)"] if skipped else [],
                            "log": str(log.relative_to(ROOT))})
    for path, names in python.items():
        index += 1
        status_file = OUT / f".{index:02d}.json"
        rc, seconds, log = run(index, Path(path).stem, [sys.executable, "-c", PY_RUNNER, path, str(status_file), *names])
        status = json.loads(status_file.read_text()) if status_file.exists() else {}
        if status_file.exists():
            status_file.unlink()
        for name in names:
            entry = status.get(name, {"outcome": "missing", "skips": []})
            doc["runs"].append({"ref": f"{path}::{name}", "rc": 0 if entry["outcome"] == "ok" and rc == 0 else 1,
                                "outcome": entry["outcome"], "seconds": seconds, "skips": entry["skips"],
                                "log": str(log.relative_to(ROOT))})
    doc["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    PAIR_DOC.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    failed = [run["ref"] for run in doc["runs"] if run["rc"] != 0]
    print(f"{len(doc['runs'])} refs, {len(failed)} failed" + (": " + ", ".join(failed) if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

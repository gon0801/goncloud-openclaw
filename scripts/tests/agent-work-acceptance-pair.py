#!/usr/bin/env python3
"""Corre una vez cada prueba que cita la matriz de aceptación sobre el par G/R y escribe acceptance-pair.json.

Uso: AGENT_WORK_RUNTIME_SOURCE=<R construido> LANG=en_US.UTF-8 python3 scripts/tests/agent-work-acceptance-pair.py
Los logs quedan en docs/evidence/agent-work/par-final/. El estricto de test_agent_work_acceptance.py lo lee.
Por omisión corre todo en orden (AGENT_WORK_PAIR_JOBS=1): en paralelo, en esta Mac fallan por carga pruebas
que miden tiempos o reinician procesos (B8, followups). Con AGENT_WORK_PAIR_JOBS>1 corre en tres carriles: los casos que corren vitest dentro de R (R_VITEST) uno tras otro, porque comparten la caché de R;
el resto en paralelo (AGENT_WORK_PAIR_JOBS) al mismo tiempo; y al final, solos, los que miden latencia o reinician muchas veces el gateway de R.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
from test_agent_work_acceptance import PAIR_DOC, matrix_refs, matrix_rows  # noqa: E402

OUT = ROOT / "docs/evidence/agent-work/par-final"
TIMEOUT = 3600
# Latency measurements: under load their gateway calls time out.
ALONE = ("delivery_latency",)
# Cases that run vitest inside R share R's compiled cache, so they run one after another.
R_VITEST = ("scripts/agent-work/test-runtime.sh::", "scripts/tests/test-agent-work-integration.sh::agents_routing",
            "scripts/tests/test-agent-work-integration.sh::delegation_bypass")
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
    jobs = []
    for ref in shell:
        path, case = ref.split("::")
        jobs.append(("shell", ref, f"{Path(path).stem}-{case}", ["bash", path, case]))
    for path, names in python.items():
        jobs.append(("python", path, Path(path).stem, names))
    jobs = [(index, *job) for index, job in enumerate(jobs, start=1)]

    def execute(job):
        index, kind, ref, label, payload = job
        if kind == "shell":
            rc, seconds, log = run(index, label, payload)
            skipped = sum(int(n) for n in re.findall(r"skipped=(\d+)", log.read_text(encoding="utf-8")))
            return [{"ref": ref, "rc": rc, "seconds": seconds, "skips": [f"{skipped} (count)"] if skipped else [],
                     "log": str(log.relative_to(ROOT))}]
        status_file = OUT / f".{index:02d}.json"
        rc, seconds, log = run(index, label, [sys.executable, "-c", PY_RUNNER, ref, str(status_file), *payload])
        status = json.loads(status_file.read_text()) if status_file.exists() else {}
        if status_file.exists():
            status_file.unlink()
        return [{"ref": f"{ref}::{name}",
                 "rc": 0 if status.get(name, {}).get("outcome") == "ok" and rc == 0 else 1,
                 "outcome": status.get(name, {"outcome": "missing"})["outcome"], "seconds": seconds,
                 "skips": status.get(name, {"skips": []})["skips"], "log": str(log.relative_to(ROOT))}
                for name in payload]

    alone = [job for job in jobs if job[1] == "shell" and job[2].split("::")[1].startswith(ALONE)]
    runtime = [job for job in jobs if job not in alone and job[2].startswith(R_VITEST)]
    parallel = [job for job in jobs if job not in alone and job not in runtime]
    results = {}
    workers = max(1, int(os.environ.get("AGENT_WORK_PAIR_JOBS", "1")))
    if workers == 1:
        alone, runtime, parallel = jobs, [], []
    with ThreadPoolExecutor(max_workers=workers + 1) as pool:
        serial = pool.submit(lambda: {job[0]: execute(job) for job in runtime})
        for job, runs in zip(parallel, pool.map(execute, parallel)):
            results[job[0]] = runs
        results.update(serial.result())
    for job in alone:
        results[job[0]] = execute(job)
    for index in sorted(results):
        doc["runs"].extend(results[index])
    doc["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    PAIR_DOC.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    failed = [run["ref"] for run in doc["runs"] if run["rc"] != 0]
    print(f"{len(doc['runs'])} refs, {len(failed)} failed" + (": " + ", ".join(failed) if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

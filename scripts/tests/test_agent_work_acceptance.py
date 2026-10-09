#!/usr/bin/env python3
"""Matriz de aceptación de T10 (plan :282): cada escenario y frontera del spec, con su prueba y su par G/R.

Sin argumentos comprueba la forma de la matriz y sus guardas. `AcceptanceStrictTest` exige además que todo
esté completo con un solo par de SHA y que `acceptance-pair.json` (lo escribe agent-work-acceptance-pair.py)
muestre cada prueba citada en verde sobre ese par: es el caso `acceptance` de test-agent-work-e2e.sh.
"""
import json
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs/evidence/agent-work/acceptance.md"
SPEC = ROOT / "docs/superpowers/specs/2026-09-30-encargos-agentes-design.md"
PLAN = ROOT / "docs/superpowers/plans/2026-09-30-encargos-agentes.md"
COVERAGE = {"completa", "parcial", "falta", "fuera-de-bloque"}
T10_CASES = ["review_tail_restart", "delivery_latency", "idle_72h", "resource_100_cycles", "cien_reenvios"]
SHA = re.compile(r"^[0-9a-f]{40}$")
REF = re.compile(r"`(?!/)(?![^`]*\.\./)([^`:]+)::([^`]+)`")
OUT_OF_BLOCK = {"A17": ("T11", "cutover_fencing"),
                "A8": ("T12", "mide 30 minutos sin novedades"),
                "T10:idle_72h": ("T12", "mide 30 minutos sin novedades")}
PAIR_DOC = ROOT / "docs/evidence/agent-work/acceptance-pair.json"
EMPTY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
AFTER_PAIR = re.compile(r"^docs/(evidence/agent-work/(acceptance-pair\.json|[^/]+\.md|par-final/[^/]+\.log)"
                        r"|superpowers/plans/[^/]+\.md)$")


def cites(path, name, text):
    if path.endswith(".py"):
        return name.startswith("test") and re.search(rf"^\s+def {re.escape(name)}\(", text, re.M) is not None
    labels = {label for line in re.findall(r"^\s*([A-Za-z0-9_|]+)\)", text, re.M) for label in line.split("|")}
    return name in labels or f'[ "${{1:-}}" = "{name}" ]' in text


def spec_table(header):
    lines = SPEC.read_text(encoding="utf-8").splitlines()
    start = lines.index(header)
    names = []
    for line in lines[start + 2:]:
        if not line.startswith("|"):
            break
        names.append(line.split("|")[1].strip())
    return names


def matrix_rows():
    rows = []
    for line in MATRIX.read_text(encoding="utf-8").splitlines():
        cells = [cell.strip() for cell in line.split("|")[1:-1]]
        if len(cells) == 8 and cells[0] not in ("id", "---"):
            rows.append(dict(zip(("id", "escenario", "cobertura", "pruebas", "G", "R", "recibo", "nota"), cells)))
    return rows


def matrix_refs(rows):
    refs = []
    for row in rows:
        for path, name in REF.findall(row["pruebas"]):
            if f"{path}::{name}" not in refs:
                refs.append(f"{path}::{name}")
    return refs


def out_of_block_problem(task, anchor):
    lines = PLAN.read_text(encoding="utf-8").splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith(f"### {task}.")]
    if not starts:
        return f"the plan has no {task}"
    section = []
    for line in lines[starts[0] + 1:]:
        if line.startswith("## ") or line.startswith("### "):
            break
        section.append(line)
    return None if anchor in "\n".join(section) else f"{task} does not hold '{anchor}'"


def pair_problems(refs, pair, doc, changed_since_pair):
    g_sha, r_sha = pair
    problems = []
    if doc["G"] != g_sha:
        problems.append(f"the run is of G {doc['G']}")
    if doc["R"] != r_sha:
        problems.append(f"the run is of R {doc['R']}")
    if doc["rBuildCommit"] != r_sha:
        problems.append(f"R was built at {doc['rBuildCommit']}, not at the pair")
    if doc["rDiffSha256"] != EMPTY_SHA256:
        problems.append("R had uncommitted changes")
    if doc["gDirty"]:
        problems.append("G had uncommitted changes: " + ", ".join(doc["gDirty"]))
    runs = {run["ref"]: run for run in doc["runs"]}
    for ref in refs:
        run = runs.get(ref)
        if run is None:
            problems.append(f"{ref} was not run")
            continue
        if run["rc"] != 0:
            problems.append(f"{ref} ended rc={run['rc']}")
        if ref.split("::")[0].endswith(".py") and run["skips"]:
            problems.append(f"{ref} skipped: " + "; ".join(run["skips"]))
    problems += [f"{path} changed after the pair" for path in changed_since_pair if not AFTER_PAIR.match(path)]
    return problems


class AcceptanceMatrixTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MATRIX.is_file(), "docs/evidence/agent-work/acceptance.md does not exist")
        self.rows = matrix_rows()

    def test_every_spec_scenario_boundary_and_t10_case_has_one_row(self):
        expected = [(f"A{i}", name) for i, name in
                    enumerate(spec_table("| Escenario | Aserción observable |"), 1)]
        expected += [(f"B{i}", name) for i, name in
                     enumerate(spec_table("| Frontera | Escritura durable y recuperación exigidas |"), 1)]
        expected += [(f"T10:{case}", case) for case in T10_CASES]
        self.assertEqual([(row["id"], row["escenario"]) for row in self.rows], expected)
        verifica = [line for line in PLAN.read_text(encoding="utf-8").splitlines()
                    if line.startswith("Verifica con `bash scripts/tests/test-agent-work-e2e.sh review_tail_restart`")]
        self.assertEqual(len(verifica), 1, "T10 lost its Verifica line")
        for case in T10_CASES[:-1]:
            self.assertIn(case, verifica[0], f"T10 no longer names {case}")
        self.assertIn("los cien reenvíos", verifica[0])
        exige = verifica[0].split("La aceptación exige también", 1)[1].split(" y los cien reenvíos", 1)[0]
        self.assertEqual(re.findall(r"`([a-z0-9_]+)`", exige), T10_CASES[1:-1], "T10 :287 changed its cases")

    def test_every_row_is_well_formed(self):
        for row in self.rows:
            with self.subTest(row=row["id"]):
                self.assertIn(row["cobertura"], COVERAGE)
                self.assertTrue(row["nota"], "a row needs its note")
                for side in ("G", "R"):
                    self.assertTrue(row[side] == "pendiente" or SHA.match(row[side]),
                                    f"{side} must be pendiente or a 40-hex SHA, got {row[side]!r}")
                self.assertEqual(row["cobertura"] == "fuera-de-bloque", row["id"] in OUT_OF_BLOCK,
                                 "only the rows in OUT_OF_BLOCK may be fuera-de-bloque")
                refs = REF.findall(row["pruebas"])
                if row["cobertura"] == "fuera-de-bloque":
                    task, anchor = OUT_OF_BLOCK[row["id"]]
                    self.assertTrue(row["nota"].startswith(task + ":"), "out of block must name its task")
                    self.assertIsNone(out_of_block_problem(task, anchor))
                    if not refs:
                        continue
                self.assertTrue(refs, "a covered row needs its tests as `path::name`")
                for path, name in refs:
                    target = ROOT / path
                    self.assertTrue(target.is_file(), f"{path} does not exist")
                    self.assertTrue(cites(path, name, target.read_text(encoding="utf-8")), f"{name} is not in {path}")
                self.assertRegex(row["recibo"], r"^docs/evidence/agent-work/[^/]+\.md$", "a receipt is an evidence page")
                self.assertTrue((ROOT / row["recibo"]).is_file(), f"receipt {row['recibo']} does not exist")


class AcceptanceGuardsTest(unittest.TestCase):
    RUNTIME_SH = ("case \"$1\" in\n"
                  "  idle_72h)\n"
                  "    test_pattern='restart: true|spawn children|depth' ;;\n"
                  "  resource_identity|resource_close|resource_100_cycles) exec run ;;\n"
                  "esac\n"
                  "if [ \"${1:-}\" = \"agents_routing\" ]; then\n")

    def test_a_shell_citation_must_be_a_case_the_runner_dispatches(self):
        for name in ("idle_72h", "resource_close", "resource_100_cycles", "agents_routing"):
            self.assertTrue(cites("x.sh", name, self.RUNTIME_SH), name)
        for name in ("restart", "children", "depth", "true"):
            self.assertFalse(cites("x.sh", name, self.RUNTIME_SH), name)

    def test_a_python_citation_must_be_a_test_method(self):
        text = "class T(unittest.TestCase):\n    def setUp(self):\n        pass\n    def test_one(self):\n        pass\n"
        self.assertTrue(cites("x.py", "test_one", text))
        self.assertFalse(cites("x.py", "setUp", text))
        self.assertFalse(cites("x.py", "test_two", text))

    def test_a_citation_path_must_be_relative_to_the_repo(self):
        self.assertEqual(REF.findall("`scripts/tests/a.py::test_one`"), [("scripts/tests/a.py", "test_one")])
        self.assertEqual(REF.findall("`/Users/x/a.py::test_one`"), [])
        self.assertEqual(REF.findall("`scripts/../../etc/a.py::test_one`"), [])

    def test_an_out_of_block_row_names_a_task_whose_plan_section_holds_it(self):
        self.assertEqual(out_of_block_problem("T12", "mide 30 minutos sin novedades"), None)
        self.assertEqual(out_of_block_problem("T11", "cutover_fencing"), None)
        self.assertEqual(out_of_block_problem("T11", "mide 30 minutos sin novedades"),
                         "T11 does not hold 'mide 30 minutos sin novedades'")
        self.assertEqual(out_of_block_problem("T13", "cutover_fencing"), "the plan has no T13")

    REFS = ["scripts/agent-work/test-runtime.sh::idle_72h",
            "scripts/tests/test-agent-work-host.sh::resource_close",
            "scripts/tests/t.py::test_one"]
    PAIR = ("a" * 40, "b" * 40)

    def pair(self, **changes):
        doc = {"G": "a" * 40, "R": "b" * 40, "rBuildCommit": "b" * 40, "rDiffSha256": EMPTY_SHA256,
               "gDirty": [], "runs": [
                   {"ref": "scripts/agent-work/test-runtime.sh::idle_72h", "rc": 0, "skips": []},
                   {"ref": "scripts/tests/test-agent-work-host.sh::resource_close", "rc": 0, "skips": ["1 (count)"]},
                   {"ref": "scripts/tests/t.py::test_one", "rc": 0, "skips": []}]}
        doc.update(changes)
        return doc

    def test_the_pair_run_must_cover_every_cited_test_green_on_the_pair(self):
        self.assertEqual(pair_problems(self.REFS, self.PAIR, self.pair(), []), [])
        runs = self.pair()["runs"]
        cases = {
            "the run is of G " + "c" * 40: self.pair(G="c" * 40),
            "R was built at " + "c" * 40 + ", not at the pair": self.pair(rBuildCommit="c" * 40),
            "R had uncommitted changes": self.pair(rDiffSha256="0" * 64),
            "G had uncommitted changes: M scripts/x.py": self.pair(gDirty=["M scripts/x.py"]),
            "scripts/tests/t.py::test_one was not run": self.pair(runs=runs[:2]),
            "scripts/tests/t.py::test_one ended rc=1": self.pair(runs=runs[:2] + [{**runs[2], "rc": 1}]),
            "scripts/tests/t.py::test_one skipped: set AGENT_WORK_RUNTIME_SOURCE":
                self.pair(runs=runs[:2] + [{**runs[2], "skips": ["set AGENT_WORK_RUNTIME_SOURCE"]}]),
        }
        for expected, doc in cases.items():
            with self.subTest(expected=expected):
                self.assertEqual(pair_problems(self.REFS, self.PAIR, doc, []), [expected])

    def test_only_evidence_prose_may_change_after_the_pair(self):
        allowed = ["docs/evidence/agent-work/acceptance.md", "docs/evidence/agent-work/acceptance-pair.json",
                   "docs/evidence/agent-work/par-final/01.log",
                   "docs/superpowers/plans/2026-09-30-encargos-agentes.md", "docs/evidence/agent-work/followups.md"]
        self.assertEqual(pair_problems(self.REFS, self.PAIR, self.pair(), allowed), [])
        for path in ("docs/evidence/agent-work/coverage.json", "scripts/agent-work/host.py",
                     "scripts/tests/test_agent_work_acceptance.py"):
            with self.subTest(path=path):
                self.assertEqual(pair_problems(self.REFS, self.PAIR, self.pair(), [path]),
                                 [f"{path} changed after the pair"])


class AcceptanceStrictTest(unittest.TestCase):
    def test_everything_is_complete_on_one_pair(self):
        rows = [row for row in matrix_rows() if row["cobertura"] != "fuera-de-bloque"]
        open_rows = [f"{row['id']} {row['cobertura']}" for row in rows if row["cobertura"] != "completa"]
        self.assertFalse(open_rows, "acceptance is incomplete: " + ", ".join(open_rows))
        pairs = {(row["G"], row["R"]) for row in rows}
        self.assertEqual(len(pairs), 1, f"acceptance needs one G/R pair, got {sorted(pairs)}")
        g_sha, r_sha = pairs.pop()
        self.assertRegex(g_sha, SHA)
        self.assertRegex(r_sha, SHA)
        known = subprocess.run(["git", "cat-file", "-e", f"{g_sha}^{{commit}}"], cwd=ROOT)
        self.assertEqual(known.returncode, 0, f"G {g_sha} is not a commit of this repo")
        ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", g_sha, "HEAD"], cwd=ROOT)
        self.assertEqual(ancestor.returncode, 0, f"G {g_sha} is not an ancestor of HEAD")
        r_repo = json.loads((ROOT / "docs/evidence/agent-work/runtime-map.json").read_text())["runtime"]["localCheckout"]
        r_known = subprocess.run(["git", "-C", r_repo, "cat-file", "-e", f"{r_sha}^{{commit}}"], capture_output=True)
        self.assertEqual(r_known.returncode, 0, f"R {r_sha} is not a commit of {r_repo}")
        self.assertTrue(PAIR_DOC.is_file(), "the pair run docs/evidence/agent-work/acceptance-pair.json is missing")
        changed = subprocess.run(["git", "diff", "--name-only", g_sha, "HEAD"], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.split()
        doc = json.loads(PAIR_DOC.read_text(encoding="utf-8"))
        self.assertEqual(pair_problems(matrix_refs(matrix_rows()), (g_sha, r_sha), doc, changed), [])


if __name__ == "__main__":
    unittest.main(defaultTest=["AcceptanceMatrixTest", "AcceptanceGuardsTest"])

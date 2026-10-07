#!/usr/bin/env python3
"""Matriz de aceptación de T10 (plan :282): cada escenario y frontera del spec, con su prueba y su par G/R.

Sin argumentos comprueba la forma de la matriz. `AcceptanceStrictTest` exige además que todo esté
completo con un solo par de SHA: es el caso `acceptance` de test-agent-work-e2e.sh.
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
REF = re.compile(r"`([^`:]+)::([^`]+)`")
OUT_OF_BLOCK = {"A17": "T11"}


def cites(path, name, text):
    if path.endswith(".py"):
        return re.search(rf"^\s*def {re.escape(name)}\(", text, re.M) is not None
    return re.search(rf"(^|[\s|\"])({re.escape(name)})(\)|\||\"\s*\])", text, re.M) is not None


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
                if row["cobertura"] == "fuera-de-bloque":
                    self.assertTrue(row["nota"].startswith(OUT_OF_BLOCK[row["id"]] + ":"),
                                    "out of block must name its task")
                    continue
                refs = REF.findall(row["pruebas"])
                self.assertTrue(refs, "a covered row needs its tests as `path::name`")
                for path, name in refs:
                    target = ROOT / path
                    self.assertTrue(target.is_file(), f"{path} does not exist")
                    self.assertTrue(cites(path, name, target.read_text(encoding="utf-8")), f"{name} is not in {path}")
                self.assertRegex(row["recibo"], r"^docs/evidence/agent-work/[^/]+\.md$", "a receipt is an evidence page")
                self.assertTrue((ROOT / row["recibo"]).is_file(), f"receipt {row['recibo']} does not exist")


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


if __name__ == "__main__":
    unittest.main(defaultTest="AcceptanceMatrixTest")

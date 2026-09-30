import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "u3a-progress.py"


def doc():
    return {
        "lead": {"actualizado": "2026-09-30T16:37:12Z"},
        "siguiente_paso": "viejo",
        "carriles": [
            {"id": "B1", "estado": "mergeado", "ronda": 2, "paso_loop": 5, "repo": "gon0801/goncloud-openclaw", "pr": 222, "ultimo_evento": None},
            {"id": "B2", "estado": "implementando", "ronda": 11, "paso_loop": 2, "repo": "gon0801/goncloud-openclaw", "pr": 226, "ultimo_evento": None},
            {"id": "B3", "estado": "pendiente", "ronda": 0, "paso_loop": 0, "repo": "gon0801/goncloud-openclaw", "pr": None, "rama": None, "ultimo_evento": None},
        ],
        "cola": [],
        "eventos": [],
    }


class ProgressTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "fase19.json").write_text(json.dumps(doc()))
        (self.root / "estado.md").write_text(
            "- B2 CERRADO 2026-09-30 12:44 EDT (merge be65298)\n"
            "- B3 ABIERTO 2026-09-30 12:49 EDT (19.2, ronda r1; rama u3a/b3-cierre)\n"
            "- Proxima accion: esperar LISTO-19.2-r1 de zcode.\n"
        )

    def sync(self):
        p = subprocess.run([sys.executable, str(SCRIPT), str(self.root)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads((self.root / "fase19.json").read_text())

    def test_closure_and_open_round_update_board(self):
        out = self.sync()
        self.assertEqual([c["estado"] for c in out["carriles"]], ["mergeado", "mergeado", "implementando"])
        self.assertEqual(out["carriles"][2]["ronda"], 1)
        self.assertEqual(out["carriles"][2]["rama"], "u3a/b3-cierre")
        self.assertEqual([q["avance"] for q in out["cola"]], [100, 100, 0])
        self.assertEqual(round(sum(q["avance"] for q in out["cola"]) / 3), 67)

    def test_verdict_advances_without_closing_block(self):
        before = self.sync()
        (self.root / "VEREDICTO-19.2-r1").write_text("VEREDICTO: CAMBIOS\n")
        after = self.sync()
        self.assertEqual(after["carriles"][2]["estado"], "implementando")
        self.assertGreater(after["cola"][2]["avance"], before["cola"][2]["avance"])
        self.assertEqual(after["cola"][2]["avance"], 50)
        self.assertEqual(round(sum(q["avance"] for q in after["cola"]) / 3), 83)
        self.assertEqual(after["carriles"][2]["ronda"], 1)

    def test_new_assignment_updates_round_without_a_verdict(self):
        self.sync()
        (self.root / "encargo-19.2-r2.md").write_text("Corregir hallazgos\n")
        out = self.sync()
        self.assertEqual(out["carriles"][2]["ronda"], 2)
        self.assertEqual(out["cola"][2]["avance"], 0)

    def test_open_block_preserves_review_and_blocked_states(self):
        (self.root / "VEREDICTO-19.2-r1").write_text("VEREDICTO: CAMBIOS\n")
        for status in ["atorado", "revision-cruzada", "auditoria-lead", "en-cola"]:
            with self.subTest(status=status):
                document = doc()
                document["carriles"][2].update(estado=status, detenido_por="esperando respuesta")
                (self.root / "fase19.json").write_text(json.dumps(document))
                out = self.sync()
                self.assertEqual(out["carriles"][2]["estado"], status)
                self.assertEqual(out["cola"][2]["avance"], 50)

    def test_record_persists_verdict_and_updates_progress(self):
        source = self.root / "respuesta.txt"
        source.write_text("VEREDICTO: CAMBIOS\nHallazgo reproducible\n")
        p = subprocess.run([
            sys.executable, str(SCRIPT), str(self.root),
            "--record", "VEREDICTO-19.2-r1", "--input", str(source),
        ], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((self.root / "VEREDICTO-19.2-r1").read_text(), source.read_text())
        self.assertEqual(self.sync()["cola"][2]["avance"], 50)

    def test_each_b3_verdict_moves_percentage_until_block_closes(self):
        (self.root / "VEREDICTO-19.2-r1").write_text("VEREDICTO: CAMBIOS\n")
        first = self.sync()
        (self.root / "VEREDICTO-19.2-r2").write_text("VEREDICTO: APROBADO\n")
        second = self.sync()
        self.assertEqual(first["cola"][2]["avance"], 50)
        self.assertEqual(second["cola"][2]["avance"], 67)
        with (self.root / "estado.md").open("a") as state:
            state.write("- B3 CERRADO 2026-10-01 12:00 EDT (merge completo)\n")
        closed = self.sync()
        self.assertEqual(closed["carriles"][2]["estado"], "mergeado")
        self.assertEqual(closed["cola"][2]["avance"], 100)

    def test_idempotent_and_no_count_for_listo_only(self):
        (self.root / "LISTO-19.2-r1").write_text("SHA abc\n")
        first = self.sync()
        second = self.sync()
        self.assertEqual(first, second)
        self.assertEqual(first["cola"][2]["avance"], 0)

    def test_publish_retries_unchanged_document_after_rejection(self):
        gateway = self.root / "gateway"
        gateway.write_text("#!/bin/sh\nprintf '%s\\n' '{\"ok\":false}'\n")
        gateway.chmod(0o755)
        args = [sys.executable, str(SCRIPT), str(self.root), "--publish", "--gateway", str(gateway)]
        first = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(first.returncode, 1)
        before = (self.root / "fase19.json").read_bytes()
        gateway.write_text("#!/bin/sh\nprintf '%s\\n' '{\"ok\":true}'\n")
        second = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(json.loads(second.stdout), {"ok": True})
        self.assertEqual((self.root / "fase19.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

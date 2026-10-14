#!/usr/bin/env python3
"""El importador de filas de Plans.md (SUA-02, I01): una fila importada conserva sus criterios."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from sistema_agentes.importar_plans import FilaAbierta, frases, importar, main  # noqa: E402

FIXTURE = ROOT / "scripts/tests/fixtures/importar-plans"
PLANS = (FIXTURE / "Plans.md").read_text(encoding="utf-8")
ALCANCE = "owner-01/repo-a"


def unidad(unit_id, title, depends, criterios):
    return {
        "unitId": unit_id,
        "title": title,
        "dependsOn": depends,
        "criteria": [
            {"criterionId": f"{unit_id}-{n}", "text": text, "verifier": "verifier"}
            for n, text in enumerate(criterios, start=1)
        ],
        "scope": {"repos": [ALCANCE], "mode": "implement"},
    }


class Importar(unittest.TestCase):
    maxDiff = None

    def test_una_fila_importada_conserva_sus_criterios(self):
        self.assertEqual(
            importar(PLANS, ["7.2", "7.3"], ALCANCE),
            {
                "request": {
                    "text": "La tabla existe en la base nueva\n"
                    "la base vieja abre igual. Su prueba falla sin la tabla\n"
                    "El tablero muestra la hora",
                    "coverage": [
                        {
                            "sentence": "La tabla existe en la base nueva",
                            "role": "criterion",
                            "criterionIds": ["7.2-1"],
                        },
                        {
                            "sentence": "la base vieja abre igual.",
                            "role": "criterion",
                            "criterionIds": ["7.2-2"],
                        },
                        {
                            "sentence": "Su prueba falla sin la tabla",
                            "role": "criterion",
                            "criterionIds": ["7.2-2"],
                        },
                        {
                            "sentence": "El tablero muestra la hora",
                            "role": "criterion",
                            "criterionIds": ["7.3-1"],
                        },
                    ],
                },
                "plan": {
                    "units": [
                        unidad(
                            "7.2",
                            "Guardar el arranque en la base",
                            [],
                            [
                                "La tabla existe en la base nueva",
                                "la base vieja abre igual. Su prueba falla sin la tabla",
                            ],
                        ),
                        unidad(
                            "7.3",
                            "Mostrar el arranque en el tablero",
                            ["7.2"],
                            [
                                "El tablero muestra la hora",
                            ],
                        ),
                    ],
                    "assumptions": ["La fila 7.1 está cerrada."],
                },
            },
        )

    def test_tres_filas_dejan_sus_dependencias_dentro_de_la_seleccion(self):
        plan = importar(PLANS, ["7.1", "7.2", "7.3"], ALCANCE)["plan"]
        self.assertEqual(
            [(u["unitId"], u["dependsOn"]) for u in plan["units"]],
            [("7.1", []), ("7.2", ["7.1"]), ("7.3", ["7.2", "7.1"])],
        )
        self.assertEqual(plan["assumptions"], [])
        self.assertEqual(plan["units"][0]["title"], "Medir el tiempo de arranque")

    def test_una_dependencia_abierta_fuera_de_la_seleccion_falla(self):
        with self.assertRaisesRegex(FilaAbierta, "la fila 7.5 depende de 7.4, que no está cerrada"):
            importar(PLANS, ["7.5"], ALCANCE)
        with self.assertRaisesRegex(KeyError, "Plans.md no tiene la fila 9.9"):
            importar(PLANS, ["9.9"], ALCANCE)

    def test_cada_frase_del_pedido_tiene_una_sola_entrada(self):
        for filas in (["7.2"], ["7.2", "7.3"], ["7.1", "7.2", "7.3"]):
            with self.subTest(filas=filas):
                entrada = importar(PLANS, filas, ALCANCE)
                del_texto = frases(entrada["request"]["text"])
                cubiertas = [e["sentence"] for e in entrada["request"]["coverage"]]
                self.assertEqual(sorted(set(del_texto)), sorted(cubiertas))
                self.assertEqual(len(cubiertas), len(set(cubiertas)))

    def test_partir_frases_sigue_la_regla_de_r(self):
        self.assertEqual(
            frases("Uno. Dos.\nTres\r\n\nCuatro.Cinco"),
            ["Uno.", "Dos.", "Tres", "Cuatro.Cinco"],
        )

    def test_la_linea_de_comando_contesta_una_linea_json(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(["--repo", str(FIXTURE), "--filas", "7.2", "--alcance", ALCANCE])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["plan"]["units"][0]["unitId"], "7.2")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = main(["--repo", str(FIXTURE), "--filas", "7.5", "--alcance", ALCANCE])
        self.assertEqual(
            (code, json.loads(out.getvalue())),
            (3, {"ok": False, "error": "la fila 7.5 depende de 7.4, que no está cerrada"}),
        )


if __name__ == "__main__":
    unittest.main()

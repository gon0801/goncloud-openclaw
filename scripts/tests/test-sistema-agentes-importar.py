#!/usr/bin/env python3
"""El importador de filas de Plans.md (SUA-02, I01): una fila importada conserva sus criterios."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from sistema_agentes.importar_plans import (  # noqa: E402
    FilaAbierta,
    FilaMalFormada,
    PedidoVacio,
    frases,
    importar,
    main,
)

FIXTURE = ROOT / "scripts/tests/fixtures/importar-plans"
PLANS = (FIXTURE / "Plans.md").read_text(encoding="utf-8")
ALCANCE = "owner-01/repo-a"
PEDIDO = "Haz las filas 7.2 y 7.3."


def criterio(criterion_id, text):
    return {"criterionId": criterion_id, "text": text, "verifier": "verifier"}


def unidad(unit_id, title, depends, criterios, propios=()):
    return {
        "unitId": unit_id,
        "title": title,
        "dependsOn": depends,
        "criteria": [criterio(f"{unit_id}-{n}", text) for n, text in enumerate(criterios, start=1)]
        + [criterio(f"{unit_id}-p{n}", text) for n, text in propios],
        "scope": {"repos": [ALCANCE], "mode": "implement"},
    }


def correr(argv, pedido=PEDIDO):
    """El CLI con el pedido por la entrada estándar: su código y su línea JSON."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), unittest.mock.patch("sys.stdin", io.StringIO(pedido)):
        code = main(argv)
    return code, json.loads(out.getvalue())


class Importar(unittest.TestCase):
    maxDiff = None

    def test_una_fila_importada_conserva_sus_criterios(self):
        self.assertEqual(
            importar(PLANS, ["7.2", "7.3"], ALCANCE, PEDIDO),
            {
                "request": {
                    "text": PEDIDO,
                    "coverage": [
                        {
                            "sentence": PEDIDO,
                            "role": "criterion",
                            "criterionIds": ["7.2-p1", "7.3-p1"],
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
                            [(1, PEDIDO)],
                        ),
                        unidad(
                            "7.3",
                            "Mostrar el arranque en el tablero",
                            ["7.2"],
                            ["El tablero muestra la hora"],
                            [(1, PEDIDO)],
                        ),
                    ],
                    "assumptions": ["La fila 7.1 está cerrada."],
                },
            },
        )

    def test_una_condicion_propia_de_david_se_conserva_con_su_papel(self):
        pedido = (
            "Haz las filas 7.2 y 7.3. No toques la base vieja.\n"
            "En la 7.3 la hora va en UTC.\n"
            "La tabla existe en la base nueva"
        )
        entrada = importar(PLANS, ["7.2", "7.3"], ALCANCE, pedido)
        self.assertEqual(entrada["request"]["text"], pedido)
        self.assertEqual(
            entrada["request"]["coverage"],
            [
                {
                    "sentence": "Haz las filas 7.2 y 7.3.",
                    "role": "criterion",
                    "criterionIds": ["7.2-p1", "7.3-p1"],
                },
                {
                    "sentence": "No toques la base vieja.",
                    "role": "criterion",
                    "criterionIds": ["7.2-p2", "7.3-p2"],
                },
                {
                    "sentence": "En la 7.3 la hora va en UTC.",
                    "role": "criterion",
                    "criterionIds": ["7.3-p3"],
                },
                {
                    "sentence": "La tabla existe en la base nueva",
                    "role": "criterion",
                    "criterionIds": ["7.2-1"],
                },
            ],
        )
        self.assertEqual(
            [[c["criterionId"] for c in u["criteria"]] for u in entrada["plan"]["units"]],
            [
                ["7.2-1", "7.2-2", "7.2-p1", "7.2-p2"],
                ["7.3-1", "7.3-p1", "7.3-p2", "7.3-p3"],
            ],
        )
        self.assertEqual(
            entrada["plan"]["units"][1]["criteria"][2:],
            [
                criterio("7.3-p2", "No toques la base vieja."),
                criterio("7.3-p3", "En la 7.3 la hora va en UTC."),
            ],
        )

    def test_una_barra_escapada_es_contenido_de_la_celda(self):
        unidad_76 = importar(PLANS, ["7.6"], ALCANCE, "Haz la 7.6.")["plan"]["units"][0]
        self.assertEqual(
            unidad_76["criteria"][:2],
            [
                criterio("7.6-1", "`a | b` imprime dos columnas"),
                criterio("7.6-2", "la prueba lo lee"),
            ],
        )
        with self.assertRaisesRegex(
            FilaMalFormada, r"la fila 7.7 tiene 5 columnas y el ledger pide 4 .*\\\|"
        ):
            importar(PLANS, ["7.7"], ALCANCE, "Haz la 7.7.")

    def test_tres_filas_dejan_sus_dependencias_dentro_de_la_seleccion(self):
        plan = importar(PLANS, ["7.1", "7.2", "7.3"], ALCANCE, PEDIDO)["plan"]
        self.assertEqual(
            [(u["unitId"], u["dependsOn"]) for u in plan["units"]],
            [("7.1", []), ("7.2", ["7.1"]), ("7.3", ["7.2", "7.1"])],
        )
        self.assertEqual(plan["assumptions"], [])
        self.assertEqual(plan["units"][0]["title"], "Medir el tiempo de arranque")

    def test_una_dependencia_abierta_fuera_de_la_seleccion_falla(self):
        with self.assertRaisesRegex(FilaAbierta, "la fila 7.5 depende de 7.4, que no está cerrada"):
            importar(PLANS, ["7.5"], ALCANCE, PEDIDO)
        with self.assertRaisesRegex(KeyError, "Plans.md no tiene la fila 9.9"):
            importar(PLANS, ["9.9"], ALCANCE, PEDIDO)
        with self.assertRaisesRegex(PedidoVacio, "el pedido de David está vacío"):
            importar(PLANS, ["7.2"], ALCANCE, " \n ")

    def test_cada_frase_del_pedido_tiene_una_sola_entrada(self):
        pedido = "Haz estas. No toques la base vieja.\nHaz estas.\nEl tablero muestra la hora"
        for filas in (["7.2"], ["7.2", "7.3"], ["7.1", "7.2", "7.3"]):
            with self.subTest(filas=filas):
                entrada = importar(PLANS, filas, ALCANCE, pedido)
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
        code, salida = correr(["--repo", str(FIXTURE), "--filas", "7.2", "--alcance", ALCANCE])
        self.assertEqual(code, 0)
        self.assertEqual(
            (salida["ok"], salida["request"]["text"], salida["plan"]["units"][0]["unitId"]),
            (True, PEDIDO, "7.2"),
        )
        self.assertEqual(
            correr(["--repo", str(FIXTURE), "--filas", "7.5", "--alcance", ALCANCE]),
            (3, {"ok": False, "error": "la fila 7.5 depende de 7.4, que no está cerrada"}),
        )

    def test_sin_plans_md_contesta_ok_false_y_no_un_traceback(self):
        for repo in (FIXTURE / "no-existe", FIXTURE.parent):
            with self.subTest(repo=repo):
                self.assertEqual(
                    correr(["--repo", str(repo), "--filas", "7.2", "--alcance", ALCANCE]),
                    (
                        3,
                        {
                            "ok": False,
                            "error": f"no se puede leer {repo / 'Plans.md'}: "
                            "No such file or directory",
                        },
                    ),
                )


if __name__ == "__main__":
    unittest.main()

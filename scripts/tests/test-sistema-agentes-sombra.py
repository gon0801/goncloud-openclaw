#!/usr/bin/env python3
"""La sombra del controlador (SUA-02, 4.9) contra un extracto de fixture, con la regla de R.

Corre `sombra.mjs` con el `decideLooseTask` de R, así que pide AGENT_WORK_RUNTIME_SOURCE. Sin R
no hay regla que comparar: el caso se salta.
"""

from __future__ import annotations

import json
import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOMBRA = ROOT / "scripts/sistema_agentes/sombra.mjs"
EXTRACTO = ROOT / "scripts/tests/fixtures/sombra/extracto.json"


def correr(r: Path) -> dict:
    salida = subprocess.run(
        [
            "node",
            "--import",
            str(r / "scripts/tsx.mjs"),
            str(SOMBRA),
            "--r",
            str(r),
            "--extracto",
            str(EXTRACTO),
        ],
        check=True,
        capture_output=True,
        text=True,
        cwd=r,
    )
    return json.loads(salida.stdout)


@unittest.skipUnless(
    os.environ.get("AGENT_WORK_RUNTIME_SOURCE"), "pide AGENT_WORK_RUNTIME_SOURCE con R"
)
class Sombra(unittest.TestCase):
    maxDiff = None

    def test_cada_tarea_recibe_la_propuesta_de_decide_con_los_hechos_previos(self):
        calculo = correr(Path(os.environ["AGENT_WORK_RUNTIME_SOURCE"]))
        self.assertEqual(
            [(f["taskId"], f["propuesta"], f["main"], f["coincide"]) for f in calculo["filas"]],
            [
                ("t-aceptar", "verificar-y-aceptar", "complete", True),
                ("t-corregir", "corregir", "continue", True),
                ("t-revision-aprobada", "verificar-y-aceptar", "complete", True),
                ("t-reintentar", "reintentar", "cancel", True),
                ("t-capacidad", "excepcion:CAPACIDAD_INCIERTA", "cancel", True),
                # El deadline-missed llegó después de la cancelación: no cuenta.
                ("t-permiso", "excepcion:NECESITA_DAVID", "cancel", True),
                ("t-dos-fallos", "excepcion:INESPERADO", "cancel", True),
                ("t-incidencia-tardia", "esperar", "cancel", False),
                # Una cancelación no consume el resultado: la sombra no lo ve.
                ("t-resultado-y-cancelacion", "esperar", "cancel", False),
                ("t-aceptar-con-incidencia", "verificar-y-aceptar", "complete", True),
                ("t-sin-decision", "verificar-y-aceptar", None, None),
            ],
        )
        self.assertEqual(
            calculo["resumen"], {"tareas": 11, "coinciden": 8, "noCoinciden": 2, "sinDecision": 1}
        )


if __name__ == "__main__":
    unittest.main()

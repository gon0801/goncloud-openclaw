#!/usr/bin/env python3
"""SUA-04 (4.3): la clasificación de la salida del banco del canario, sobre salidas de fixture.
Las líneas BANCO_E2E y los cierres son literales recortados de los banco.log de M-16
(~/.local/state/sua-loop/mediciones/m16*/banco.log)."""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import encargo  # noqa: E402

VERDE = (
    "test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for "
    "(__main__.BancoE2E.test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for) ... "
    "BANCO_E2E case=ingenieria task=c4431755-2494-4cab-bf95-2edee1ca4f9a conducta=ok suite_repo=pasa\n"
    "\n----------------------------------------------------------------------\nRan 1 test in 240.241s\n\nOK\n"
)
ROJO_CONDUCTA = (
    "test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for "
    "(__main__.BancoE2E.test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for) ... FAIL\n"
    "BANCO_E2E case=ingenieria task=b20dfd41-f96e-4406-b66a-29f59935f2d8 conducta=roja\n"
    "\n----------------------------------------------------------------------\nRan 1 test in 403.172s\n\nFAILED (failures=1)\n"
)
ROJO_LAUNCH = (
    "test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for "
    "(__main__.BancoE2E.test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for) ... ERROR\n"
    "Explicacion(causa='launch-failed', frase='opencode no incluyó el modelo en el plan')\n"
    "\n----------------------------------------------------------------------\nRan 1 test in 436.106s\n\nFAILED (errors=1)\n"
)
SKIP = (
    "test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for "
    "(__main__.BancoE2E.test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for) ... "
    "skipped 'sin AGENT_WORK_BANCO_REAL'\n"
    "\n----------------------------------------------------------------------\nRan 1 test in 0.012s\n\nOK (skipped=1)\n"
)


class ClasificarBanco(unittest.TestCase):
    def test_la_tabla(self):
        casos = [
            (VERDE, 0, "verde"),
            (ROJO_CONDUCTA, 1, "rojo"),
            (ROJO_LAUNCH, 1, "rojo"),
            # Un OK sin la línea del caso no es un canario verde: es el banco sin correrlo.
            ("test_x ... ok\n\nOK\n", 0, "infraestructura"),
            # Un FAIL del caso sin la línea del caso es del banco, no del modelo.
            ("test_x ... FAIL\n\nFAILED (failures=1)\n", 1, "infraestructura"),
            (SKIP, 0, "infraestructura"),
            # El banco no arranca: ni siquiera hay salida del caso.
            ("Traceback (most recent call last):\nModuleNotFoundError\n", 1, "infraestructura"),
            # Timeout del subproceso: lo dice el llamador con rc None.
            (VERDE, None, "infraestructura"),
        ]
        for salida, rc, esperado in casos:
            with self.subTest(esperado=esperado, rc=rc):
                self.assertEqual(encargo.clasificar_banco(salida, rc), esperado)


if __name__ == "__main__":
    unittest.main()

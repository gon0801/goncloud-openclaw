#!/usr/bin/env python3
"""SUA-04 (4.3): la clasificación de la salida del banco del canario, sobre salidas de fixture.
clasificar_banco devuelve (desenlace, causa): el desenlace lo dice la línea del banco, no un grep
sobre toda la salida (que confunde el log del host con el veredicto del modelo)."""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import encargo  # noqa: E402

VERDE = ("test_a_profiled_engineering ... BANCO_E2E case=ingenieria desenlace=verde causa=ninguna\n"
         "\n----------------------------------------------------------------------\nRan 1 test in 240.2s\n\nOK\n")
ROJO_DEFECTO = ("test_a_profiled_engineering ... FAIL\n"
                "BANCO_E2E case=ingenieria desenlace=rojo causa=defecto-sin-arreglar\n"
                "----------------------------------------------------------------------\nFAILED (failures=1)\n")
ROJO_CONDUCTA = ("test_a_profiled_engineering ... FAIL\n"
                 "BANCO_E2E case=ingenieria desenlace=rojo causa=conducta\n"
                 "----------------------------------------------------------------------\nFAILED (failures=1)\n")
ROJO_LAUNCH = ("test_a_profiled_engineering ... ERROR\n"
               "BANCO_E2E case=ingenieria desenlace=rojo causa=launch-failed\n"
               "----------------------------------------------------------------------\nFAILED (errors=1)\n")
# La salida real del caso vencido pega el log del host, que dice "nunca entregó resultado";
# la línea del banco es la que dice que fue la espera, no el modelo.
VENCIDO = ("test_a_profiled_engineering ... FAIL\n"
           "host mac-local: la tarea t-9 nunca entregó resultado en toda la ventana\n"
           "BANCO_E2E case=ingenieria desenlace=infraestructura causa=espera-sin-incidente\n"
           "----------------------------------------------------------------------\nFAILED (failures=1)\n")
MODELO_DISTINTO = ("test_a_profiled_engineering ... FAIL\n"
                   "BANCO_E2E case=ingenieria desenlace=infraestructura causa=modelo-distinto\n"
                   "----------------------------------------------------------------------\nFAILED (failures=1)\n")
# Mutación: el log del host trae las palabras que hoy vuelven rojo (launch-failed, proveedor,
# resultado) y aun así manda la línea. Si alguien vuelve a buscar en toda la salida, canta.
MUTACION = ("test_a_profiled_engineering ... FAIL\n"
            "Explicacion(causa='launch-failed', frase='el proveedor no contestó: el proceso nunca "
            "entregó resultado')\n"
            "BANCO_E2E case=ingenieria desenlace=infraestructura causa=modelo-distinto\n"
            "----------------------------------------------------------------------\nFAILED (failures=1)\n")


class ClasificarBanco(unittest.TestCase):
    """La tabla del contrato nuevo: cada línea BANCO_E2E con desenlace= es un literal del contrato
    nuevo del banco (4.3, ronda 3), no un log de M-16."""

    def test_la_tabla(self):
        casos = [
            (VERDE, 0, ("verde", None)),
            (ROJO_DEFECTO, 1, ("rojo", "defecto-sin-arreglar")),
            (ROJO_CONDUCTA, 1, ("rojo", "conducta")),
            (ROJO_LAUNCH, 1, ("rojo", "launch-failed")),
            (VENCIDO, 1, ("infraestructura", "espera-sin-incidente")),
            (MODELO_DISTINTO, 1, ("infraestructura", "modelo-distinto")),
            (MUTACION, 1, ("infraestructura", "modelo-distinto")),
            # Un OK sin la línea del caso no es un canario verde: el banco no dio desenlace.
            ("test_x ... ok\n\nOK\n", 0, ("infraestructura", "el banco no dio desenlace")),
            # Un FAIL sin la línea del caso es del banco, no del modelo.
            ("test_x ... FAIL\n\nFAILED\n", 1, ("infraestructura", "el banco no dio desenlace")),
            # El banco no arranca: ni siquiera hay salida del caso.
            ("Traceback (most recent call last):\nModuleNotFoundError\n", 1,
             ("infraestructura", "el banco no dio desenlace")),
            # Timeout del subproceso: lo dice el llamador con rc None.
            (VERDE, None, ("infraestructura", "el banco no dio desenlace")),
        ]
        for salida, rc, esperado in casos:
            with self.subTest(esperado=esperado, rc=rc):
                self.assertEqual(encargo.clasificar_banco(salida, rc), esperado)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""SUA-06 (4.1): proyeccion.py deriva sistema-agentes.proyeccion.v1 del snapshot de una raíz.

Cada fixture que produce salida pasa el validador del contrato sin hallazgos; los textos
sucios y el snapshot roto son ValueError con nombre. leer y listar corren contra un
openclaw de doble que registra su argv y contesta una respuesta fijada.
"""

import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import proyeccion  # noqa: E402
from sistema_agentes import contrato  # noqa: E402

FIXTURES = ROOT / "scripts/tests/fixtures/sistema-agentes/proyeccion-derivar"
AHORA = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)
STALE = 300000
INTERVALO = 300000
GATEWAY = "gateway-1"


def derivar_fixture(nombre, ahora=AHORA, notados=None, host_gateway=GATEWAY):
    snapshot = json.loads((FIXTURES / f"{nombre}.json").read_text(encoding="utf-8"))
    return proyeccion.derivar(
        snapshot, ahora, STALE, INTERVALO, notados or {}, host_gateway=host_gateway
    )


class Derivar(unittest.TestCase):
    def test_raiz_sin_criterios_progress_nulo(self):
        proyeccion_doc = derivar_fixture("raiz-sin-criterios")
        self.assertEqual(
            proyeccion_doc["progress"], {"declared": None, "observed": None, "accepted": None}
        )
        self.assertEqual([fila["unitId"] for fila in proyeccion_doc["units"]], ["unit-a", "unit-b"])
        estados = [(fila["unitId"], fila["state"]) for fila in proyeccion_doc["units"]]
        self.assertEqual(estados, [("unit-a", "pending"), ("unit-b", "ready")])
        for fila in proyeccion_doc["units"]:
            self.assertEqual((fila["executor"], fila["host"]), ("sin-asignar", GATEWAY))
        self.assertEqual(contrato.validar(proyeccion_doc), [])

    def test_raiz_estados_porcentajes_y_filas(self):
        proyeccion_doc = derivar_fixture("raiz-estados")
        self.assertEqual(
            proyeccion_doc["progress"], {"declared": 66, "observed": 66, "accepted": 33}
        )
        self.assertEqual(proyeccion_doc["rootId"], "root-estados")
        self.assertEqual(proyeccion_doc["planRevision"], 1)
        self.assertEqual(proyeccion_doc["generatedAt"], "2026-10-16T12:00:00Z")
        filas = {fila["unitId"]: fila for fila in proyeccion_doc["units"]}
        self.assertEqual(
            (filas["unit-a"]["state"], filas["unit-a"]["executor"], filas["unit-a"]["host"]),
            ("reported", "cli:banco-cli", "mac-local"),
        )
        self.assertEqual(
            (filas["unit-b"]["state"], filas["unit-b"]["executor"], filas["unit-b"]["host"],
             filas["unit-b"]["error"]),
            ("running", "agent:agent-b", GATEWAY, "transport-unavailable"),
        )
        self.assertEqual(
            (filas["unit-c"]["state"], filas["unit-c"]["executor"], filas["unit-c"]["host"],
             filas["unit-c"]["error"], filas["unit-c"]["modelId"]),
            ("accepted", "cli:verif-cli", "mini-local", None, None),
        )
        self.assertEqual(filas["unit-a"]["nextCheckAt"], "2026-10-16T12:05:00Z")
        self.assertEqual(contrato.validar(proyeccion_doc), [])

    def test_excepciones_fijan_nextcheckat(self):
        notados = {"exc-01": datetime(2026, 10, 16, 11, 30, 0, tzinfo=timezone.utc)}
        proyeccion_doc = derivar_fixture("excepciones", notados=notados)
        filas = {fila["unitId"]: fila for fila in proyeccion_doc["units"]}
        self.assertEqual(filas["unit-a"]["nextCheckAt"], "2026-10-16T12:30:00Z")
        self.assertEqual(filas["unit-b"]["nextCheckAt"], "2026-10-16T12:00:00Z")
        self.assertEqual(filas["unit-c"]["nextCheckAt"], "2026-10-16T12:05:00Z")
        self.assertTrue(all(fila["nextCheckAt"] for fila in proyeccion_doc["units"]))
        self.assertEqual(contrato.validar(proyeccion_doc), [])

    def test_deadline_anterior_gana_a_todo(self):
        snapshot = json.loads((FIXTURES / "excepciones.json").read_text(encoding="utf-8"))
        snapshot["meta"]["authority"]["deadline"] = "2026-10-16T11:00:00Z"
        notados = {"exc-01": datetime(2026, 10, 16, 11, 30, 0, tzinfo=timezone.utc)}
        proyeccion_doc = proyeccion.derivar(
            snapshot, AHORA, STALE, INTERVALO, notados, host_gateway=GATEWAY
        )
        self.assertEqual(
            [fila["nextCheckAt"] for fila in proyeccion_doc["units"]],
            ["2026-10-16T11:00:00Z"] * 3,
        )
        self.assertTrue(all(fila["nextCheckAt"] for fila in proyeccion_doc["units"]))
        self.assertEqual(contrato.validar(proyeccion_doc), [])

    def test_textos_sucios_son_valueerror_con_nombre(self):
        casos = [
            ("textos-sucios-script", "unitId"),
            ("textos-sucios-llave", "adapterId"),
            ("textos-sucios-ruta", "adapterId"),
        ]
        for fixture, campo in casos:
            with self.subTest(fixture=fixture):
                with self.assertRaisesRegex(ValueError, campo):
                    derivar_fixture(fixture)

    def test_snapshot_roto_es_valueerror_con_nombre(self):
        # Los bytes rotos se escriben aquí, no como fixture .json: el check-json del
        # pre-commit del repo rechaza un .json que no decodifica, y sin archivo roto
        # commiteado el chequeo del hook y el fixture conviven.
        with tempfile.TemporaryDirectory() as temp:
            roto = Path(temp) / "snapshot-roto.json"
            roto.write_bytes(b"esto { no es json")
            with self.assertRaisesRegex(ValueError, "snapshot-roto"):
                proyeccion.cargar_snapshot(roto)

    def test_host_gateway_requerido_cuando_una_fila_lo_necesita(self):
        with self.assertRaisesRegex(ValueError, "host_gateway"):
            derivar_fixture("raiz-sin-criterios", host_gateway=None)


if __name__ == "__main__":
    unittest.main()

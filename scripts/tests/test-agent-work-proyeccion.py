#!/usr/bin/env python3
"""SUA-06 (4.1): proyeccion.py deriva sistema-agentes.proyeccion.v1 del snapshot de una raíz.

Cada fixture que produce salida pasa el validador del contrato sin hallazgos; los textos
sucios y el snapshot roto son ValueError con nombre. leer y listar corren contra un
openclaw de doble que registra su argv y contesta una respuesta fijada.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
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


class CliDerivar(unittest.TestCase):
    SCRIPT = ROOT / "scripts/agent-work/proyeccion.py"

    def correr(self, *argumentos, extra_env=None):
        entorno = dict(os.environ, LANG="en_US.UTF-8")
        entorno.update(extra_env or {})
        return subprocess.run(
            [sys.executable, str(self.SCRIPT), *argumentos],
            capture_output=True,
            text=True,
            timeout=60,
            env=entorno,
            cwd=str(ROOT),
        )

    def test_derivar_imprime_la_proyeccion_del_fixture(self):
        hecho = self.correr(
            "derivar", str(FIXTURES / "raiz-estados.json"),
            "--stale-after-ms", "600000", "--intervalo-ms", str(INTERVALO),
            "--host-gateway", GATEWAY,
        )
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        impresa = json.loads(hecho.stdout)
        self.assertEqual(impresa["freshness"], {"staleAfterMs": 600000})
        self.assertEqual(contrato.validar(impresa), [])
        snapshot = json.loads((FIXTURES / "raiz-estados.json").read_text(encoding="utf-8"))
        esperada = proyeccion.derivar(
            snapshot,
            proyeccion._instante(impresa["generatedAt"], "generatedAt"),
            600000,
            INTERVALO,
            {},
            host_gateway=GATEWAY,
        )
        self.assertEqual(impresa, esperada)

    def test_derivar_con_notados(self):
        with tempfile.TemporaryDirectory() as temp:
            notados = Path(temp) / "notados.json"
            notados.write_text('{"exc-01": "2026-10-16T11:30:00Z"}', encoding="utf-8")
            hecho = self.correr(
                "derivar", str(FIXTURES / "excepciones.json"),
                "--stale-after-ms", str(STALE), "--intervalo-ms", str(INTERVALO),
                "--notados", str(notados), "--host-gateway", GATEWAY,
            )
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        impresa = json.loads(hecho.stdout)
        filas = {fila["unitId"]: fila for fila in impresa["units"]}
        self.assertEqual(filas["unit-a"]["nextCheckAt"], "2026-10-16T12:30:00Z")
        generado = proyeccion._instante(impresa["generatedAt"], "generatedAt")
        self.assertEqual(
            filas["unit-c"]["nextCheckAt"],
            proyeccion._fecha(generado + timedelta(milliseconds=INTERVALO)),
        )
        self.assertEqual(contrato.validar(impresa), [])

    def test_snapshot_roto_en_el_cli_sale_con_nombre(self):
        with tempfile.TemporaryDirectory() as temp:
            roto = Path(temp) / "snapshot-roto.json"
            roto.write_bytes(b"esto { no es json")
            hecho = self.correr(
                "derivar", str(roto),
                "--stale-after-ms", str(STALE), "--intervalo-ms", str(INTERVALO),
            )
        self.assertNotEqual(hecho.returncode, 0)
        self.assertIn("snapshot-roto", hecho.stderr)
        self.assertIn("proyeccion:", hecho.stderr)


class LeerListar(unittest.TestCase):
    SCRIPT = ROOT / "scripts/agent-work/proyeccion.py"
    LISTA = {"roots": [{"rootId": "root-estados", "state": "active",
                        "openedAt": "2026-10-16T09:05:00Z"}]}

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.log = self.tmp / "gateway.log"
        self.bin = self.tmp / "openclaw"
        self.bin.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "assert args[:2] == ['gateway', 'call'] and args[-1] == '--json'\n"
            "metodo = args[2]\n"
            "params = json.loads(args[args.index('--params') + 1])\n"
            "with open(os.environ['FAKE_LOG'], 'a') as f:\n"
            "    f.write(json.dumps({'method': metodo, 'params': params}) + '\\n')\n"
            "if metodo == 'managedTasks.root.read':\n"
            "    if params['rootId'] == 'root-estados':\n"
            "        print(pathlib.Path(os.environ['FAKE_SNAPSHOT']).read_text(), end='')\n"
            "    else:\n"
            "        print('null')\n"
            "else:\n"
            "    print(json.dumps(json.loads(os.environ['FAKE_LISTA'])))\n",
            encoding="utf-8",
        )
        self.bin.chmod(0o755)
        self.snapshot = FIXTURES / "raiz-estados.json"

    def correr(self, *argumentos, con_env=True):
        entorno = dict(os.environ, LANG="en_US.UTF-8", FAKE_LOG=str(self.log),
                       FAKE_SNAPSHOT=str(self.snapshot), FAKE_LISTA=json.dumps(self.LISTA))
        if con_env:
            entorno["OPENCLAW_BIN"] = str(self.bin)
        else:
            entorno.pop("OPENCLAW_BIN", None)
        return subprocess.run(
            [sys.executable, str(self.SCRIPT), *argumentos],
            capture_output=True, text=True, timeout=60, env=entorno, cwd=str(ROOT),
        )

    def llamadas(self):
        return [json.loads(linea) for linea in self.log.read_text().splitlines()]

    def test_leer_por_env_llama_root_read_y_deriva(self):
        hecho = self.correr(
            "leer", "--root", "root-estados",
            "--stale-after-ms", str(STALE), "--intervalo-ms", str(INTERVALO),
            "--host-gateway", GATEWAY,
        )
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        impresa = json.loads(hecho.stdout)
        self.assertEqual(impresa["schema"], "sistema-agentes.proyeccion.v1")
        self.assertEqual(impresa["rootId"], "root-estados")
        self.assertEqual(impresa["progress"], {"declared": 66, "observed": 66, "accepted": 33})
        self.assertEqual(contrato.validar(impresa), [])
        self.assertEqual(self.llamadas(), [
            {"method": "managedTasks.root.read", "params": {"rootId": "root-estados"}},
        ])

    def test_leer_por_flag_openclaw_bin(self):
        hecho = self.correr(
            "leer", "--root", "root-estados",
            "--stale-after-ms", str(STALE), "--intervalo-ms", str(INTERVALO),
            "--host-gateway", GATEWAY, "--openclaw-bin", str(self.bin),
            con_env=False,
        )
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        self.assertEqual(json.loads(hecho.stdout)["rootId"], "root-estados")

    def test_leer_raiz_desconocida_es_error_con_nombre(self):
        hecho = self.correr(
            "leer", "--root", "no-existe",
            "--stale-after-ms", str(STALE), "--intervalo-ms", str(INTERVALO),
        )
        self.assertEqual(hecho.returncode, 2)
        self.assertIn("no devolvió un snapshot", hecho.stderr)
        self.assertIn("no-existe", hecho.stderr)

    def test_listar_imprime_el_json_del_gateway(self):
        hecho = self.correr("listar")
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        self.assertEqual(json.loads(hecho.stdout), self.LISTA)
        self.assertEqual(self.llamadas(), [
            {"method": "managedTasks.root.list", "params": {}},
        ])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""SUA-07 (H0a): sistema_agentes.derivar es puro y Hermes (Windows) puede importarlo.

La importación del módulo corre con fcntl, subprocess y socket tachados de sys.modules
(valen None: `import` levanta ImportError, que es lo que pasa en Windows con fcntl).
Con el módulo así cargado se derivan los fixtures de proyeccion-derivar y la salida es
idéntica a la de proyeccion.derivar, que ahora lo reexporta. El CLI de proyeccion.py
sigue corriendo desde un cwd ajeno al repo, como lo llama el cron de la Mini.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import proyeccion  # noqa: E402

FIXTURES = ROOT / "scripts/tests/fixtures/sistema-agentes/proyeccion-derivar"
AHORA = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)
STALE = 300000
INTERVALO = 300000
GATEWAY = "gateway-1"
NOTADOS = {"exc-01": datetime(2026, 10, 16, 11, 30, 0, tzinfo=timezone.utc)}
TACHADAS = ("fcntl", "subprocess", "socket")


@contextmanager
def _tachadas(nombres):
    guardadas = {nombre: sys.modules.pop(nombre, None) for nombre in nombres}
    for nombre in nombres:
        sys.modules[nombre] = None
    try:
        yield
    finally:
        for nombre, previa in guardadas.items():
            if previa is None:
                sys.modules.pop(nombre, None)
            else:
                sys.modules[nombre] = previa


def _cargar_puro():
    """Ejecuta sistema_agentes/derivar.py de nuevo, sin tocar su entrada en sys.modules."""
    with _tachadas(TACHADAS):
        especificacion = importlib.util.find_spec("sistema_agentes.derivar")
        if especificacion is None or especificacion.loader is None:
            raise ImportError("sistema_agentes.derivar no se encontró")
        modulo = importlib.util.module_from_spec(especificacion)
        especificacion.loader.exec_module(modulo)
    return modulo


class ImportePuro(unittest.TestCase):
    def test_importa_con_las_bibliotecas_de_windows_tachadas(self):
        modulo = _cargar_puro()
        snapshot = json.loads((FIXTURES / "raiz-estados.json").read_text(encoding="utf-8"))
        proyeccion_doc = modulo.derivar(
            snapshot, AHORA, STALE, INTERVALO, NOTADOS, host_gateway=GATEWAY
        )
        self.assertEqual(proyeccion_doc["schema"], "sistema-agentes.proyeccion.v1")
        self.assertEqual(
            proyeccion_doc["progress"], {"declared": 66, "observed": 66, "accepted": 33}
        )

    def test_misma_salida_que_proyeccion_en_todos_los_fixtures(self):
        puro = _cargar_puro()
        for fixture in sorted(FIXTURES.glob("*.json")):
            with self.subTest(fixture=fixture.name):
                snapshot = json.loads(fixture.read_text(encoding="utf-8"))
                notados = NOTADOS if fixture.stem == "excepciones" else {}
                try:
                    esperada = proyeccion.derivar(
                        snapshot, AHORA, STALE, INTERVALO, notados, host_gateway=GATEWAY
                    )
                except ValueError as fallo:
                    esperada = (ValueError, str(fallo))
                try:
                    obtenida = puro.derivar(
                        snapshot, AHORA, STALE, INTERVALO, notados, host_gateway=GATEWAY
                    )
                except ValueError as fallo:
                    obtenida = (ValueError, str(fallo))
                self.assertEqual(obtenida, esperada)

    def test_proyeccion_reexporta_la_del_modulo_puro(self):
        self.assertEqual(proyeccion.derivar.__module__, "sistema_agentes.derivar")


class CliDesdeOtroCwd(unittest.TestCase):
    """El cron de la Mini corre `python3 <checkout>/scripts/agent-work/proyeccion.py`
    desde el cwd que sea: el sys.path que arma el script tiene que alcanzar
    sistema_agentes.derivar sin variables nuevas."""

    SCRIPT = ROOT / "scripts/agent-work/proyeccion.py"

    def correr(self, *argumentos):
        entorno = dict(os.environ, LANG="en_US.UTF-8")
        with tempfile.TemporaryDirectory() as temp:
            return subprocess.run(
                [sys.executable, str(self.SCRIPT), *argumentos],
                capture_output=True,
                text=True,
                timeout=60,
                env=entorno,
                cwd=temp,
            )

    def test_pasar_help_corre_desde_un_cwd_ajeno(self):
        hecho = self.correr("pasar", "--help")
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        self.assertIn("pasar", hecho.stdout)

    def test_derivar_corre_desde_un_cwd_ajeno(self):
        hecho = self.correr(
            "derivar",
            str(FIXTURES / "raiz-estados.json"),
            "--stale-after-ms",
            str(STALE),
            "--intervalo-ms",
            str(INTERVALO),
            "--host-gateway",
            GATEWAY,
        )
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        impresa = json.loads(hecho.stdout)
        self.assertEqual(impresa["schema"], "sistema-agentes.proyeccion.v1")
        self.assertEqual(impresa["rootId"], "root-estados")
        snapshot = json.loads((FIXTURES / "raiz-estados.json").read_text(encoding="utf-8"))
        esperada = proyeccion.derivar(
            snapshot,
            proyeccion._instante(impresa["generatedAt"], "generatedAt"),
            STALE,
            INTERVALO,
            {},
            host_gateway=GATEWAY,
        )
        self.assertEqual(impresa, esperada)


if __name__ == "__main__":
    unittest.main()

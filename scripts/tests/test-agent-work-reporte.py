#!/usr/bin/env python3
"""SUA-04 (4.5b): reporte.py arma el resultado del trabajador nativo, y su digest canónico
coincide con stableStringify de R. El validador de aquí reescribe en Python las reglas de
managed-task.json.ts (kind, el payload del contrato, artifactRef, digest e observedRevision)."""

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRIEF = ROOT / "scripts/agent-work/brief.py"
REPORTE = ROOT / "scripts/agent-work/reporte.py"
PERFILES = ROOT / "scripts/agent-work/contexto/perfiles.v1.json"
STABLE = Path(
    "/Users/dn/dev/wt/r-sua02-c-gate/packages/normalization-core/dist/stable-stringify.mjs"
)
_spec = importlib.util.spec_from_file_location("reporte_bajo_prueba", REPORTE)
REPORTE_MOD = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(REPORTE_MOD)


def canonico(documento) -> str:
    return json.dumps(documento, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validar_result(result, input_revision):
    """Las reglas de R para un result produced (managed-task.json.ts:84-97, validateResult)."""
    assert set(result) == {"kind", "payload", "artifactRef", "digest", "observedRevision"}, result
    assert result["kind"] == "produced"
    assert isinstance(result["artifactRef"], str) and result["artifactRef"]
    assert (
        result["digest"]
        == "sha256:" + hashlib.sha256(canonico(result["payload"]).encode()).hexdigest()
    )
    assert result["observedRevision"] == input_revision


class Reporte(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.root = self.tmp / "instrucciones"
        self.root.mkdir(mode=0o700)
        brief = subprocess.run(
            [
                sys.executable,
                "-I",
                str(BRIEF),
                "--root",
                str(self.root),
                "--perfil",
                "meli",
                "--perfiles",
                str(PERFILES),
                "--agente",
                "meli",
                "--contrato",
                "ready.v1",
            ],
            input=b"Contesta el marcador.\n",
            capture_output=True,
            cwd=self.tmp,
        )
        self.assertEqual(brief.returncode, 0, brief.stderr)
        self.fragments = json.loads(brief.stdout)
        digest = self.fragments["instructionRef"]["ref"].removeprefix("artifact:")
        self.tarea = (
            re.search(rb"^tarea: (\S+)$", (self.root / digest).read_bytes(), re.MULTILINE)
            .group(1)
            .decode()
        )
        self.artefacto = self.tmp / f"resultado-{self.tarea}.txt"
        self.artefacto.write_text("evidencia: sí\n")

    def reporte(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(REPORTE), *args],
            capture_output=True,
            text=True,
            cwd=self.tmp,
        )

    def test_arma_el_result_de_ready_y_pasa_el_validador(self):
        done = self.reporte(
            "--root",
            str(self.root),
            "--tarea",
            self.tarea,
            "--contrato",
            "ready.v1",
            "--artefacto",
            str(self.artefacto),
        )
        self.assertEqual(done.returncode, 0, done.stderr)
        result = json.loads(done.stdout)
        validar_result(result, self.fragments["inputRevision"])
        self.assertEqual(result["payload"], {"evidenceRef": str(self.artefacto)})
        self.assertEqual(result["artifactRef"], str(self.artefacto))

    def test_review_lleva_veredicto_y_su_forma(self):
        for veredicto, clave in (("approved", "evidenceRef"), ("changes", "findingsRef")):
            with self.subTest(veredicto=veredicto):
                done = self.reporte(
                    "--root",
                    str(self.root),
                    "--tarea",
                    self.tarea,
                    "--contrato",
                    "review.v1",
                    "--artefacto",
                    str(self.artefacto),
                    "--veredicto",
                    veredicto,
                )
                self.assertEqual(done.returncode, 0, done.stderr)
                result = json.loads(done.stdout)
                validar_result(result, self.fragments["inputRevision"])
                self.assertEqual(
                    result["payload"], {"verdict": veredicto, clave: str(self.artefacto)}
                )

    def test_errores_salen_con_su_frase_y_sin_result(self):
        casos = [
            (
                (
                    "--root",
                    str(self.root),
                    "--tarea",
                    "00000000-0000-4000-8000-000000000000",
                    "--contrato",
                    "ready.v1",
                    "--artefacto",
                    str(self.artefacto),
                ),
                "no encontré la instrucción",
            ),
            (
                (
                    "--root",
                    str(self.root),
                    "--tarea",
                    self.tarea,
                    "--contrato",
                    "ready.v1",
                    "--artefacto",
                    str(self.tmp / "no-esta.txt"),
                ),
                "el artefacto no existe",
            ),
            (
                (
                    "--root",
                    str(self.root),
                    "--tarea",
                    self.tarea,
                    "--contrato",
                    "otro.v1",
                    "--artefacto",
                    str(self.artefacto),
                ),
                "contrato desconocido",
            ),
            (
                (
                    "--root",
                    str(self.root),
                    "--tarea",
                    self.tarea,
                    "--contrato",
                    "review.v1",
                    "--artefacto",
                    str(self.artefacto),
                ),
                "review.v1 pide --veredicto",
            ),
        ]
        for args, frase in casos:
            with self.subTest(frase=frase):
                done = self.reporte(*args)
                self.assertEqual((done.returncode, done.stdout), (3, ""))
                self.assertIn(frase, done.stderr)


class CanonicoConR(unittest.TestCase):
    # stableStringify contra el canónico de spool (json.dumps ordenado, sin espacios,
    # ensure_ascii=False): llaves en desorden, unicode y números.
    CASOS = [
        {"evidenceRef": "/w/resultado-ñ.txt"},
        {"verdict": "approved", "evidenceRef": "/w/e.txt"},
        {"b": 1, "a": {"z": [3, 1.5, "sí"], "ñ": None}, "A": True},
    ]

    # F6 de G4b-r4: salidas del stableStringify real de R, grabadas con node el
    # 2026-10-16. Se comparan siempre, también en CI sin node ni el R construido.
    SALIDAS_STABLE = [
        '{"evidenceRef":"/w/resultado-ñ.txt"}',
        '{"evidenceRef":"/w/e.txt","verdict":"approved"}',
        '{"A":true,"a":{"z":[3,1.5,"sí"],"ñ":null},"b":1}',
    ]

    def test_fixture_literal_contra_el_canonico_de_reporte(self):
        for caso, salida in zip(self.CASOS, self.SALIDAS_STABLE, strict=True):
            with self.subTest(caso=caso):
                self.assertEqual(REPORTE_MOD.canonico(caso), salida)

    def test_python_lo_fija_contra_literales(self):
        # Los literales: el digest sale del texto canónico exacto, no de otra serialización.
        self.assertEqual(
            canonico({"verdict": "approved", "evidenceRef": "/w/e.txt"}),
            '{"evidenceRef":"/w/e.txt","verdict":"approved"}',
        )
        self.assertEqual(
            canonico({"b": 1, "a": {"z": [3, 1.5, "sí"], "ñ": None}, "A": True}),
            '{"A":true,"a":{"z":[3,1.5,"sí"],"ñ":null},"b":1}',
        )

    @unittest.skipUnless(
        shutil.which("node") and STABLE.is_file(),
        "sin node o sin el stableStringify construido de R: se salta",
    )
    def test_node_coincide_con_el_real(self):
        script = (
            "import { stableStringify } from " + json.dumps(str(STABLE)) + ";\n"
            "import { createHash } from 'node:crypto';\n"
            "let texto = '';\n"
            "process.stdin.on('data', (d) => { texto += d; });\n"
            "process.stdin.on('end', () => {\n"
            "  for (const caso of JSON.parse(texto)) {\n"
            "    const canonico = stableStringify(caso);\n"
            "    process.stdout.write(canonico + '\\n');\n"
            "    const digest = createHash('sha256').update(canonico).digest('hex');\n"
            "    process.stdout.write(digest + '\\n');\n"
            "  }\n});\n"
        )
        with tempfile.NamedTemporaryFile("w", suffix=".mjs", delete=False) as archivo:
            archivo.write(script)
            nombre = archivo.name
        try:
            done = subprocess.run(
                ["node", nombre], input=json.dumps(self.CASOS), capture_output=True, text=True
            )
        finally:
            os.unlink(nombre)
        self.assertEqual(done.returncode, 0, done.stderr)
        lineas = done.stdout.splitlines()
        for indice, caso in enumerate(self.CASOS):
            with self.subTest(caso=caso):
                self.assertEqual(lineas[2 * indice], canonico(caso))
                self.assertEqual(
                    lineas[2 * indice + 1], hashlib.sha256(canonico(caso).encode()).hexdigest()
                )


if __name__ == "__main__":
    unittest.main()

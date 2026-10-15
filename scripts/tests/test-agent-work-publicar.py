#!/usr/bin/env python3
"""El publicador nativo de SUA-03 (diseño, 4.3 y filas I11 de la sección 5).

Cada caso arma una publicación de juguete con `armar_publicacion` y corre la mitad --local del
módulo por subprocess, como la corre la Mini. La mitad Mac se prueba con ssh y scp de juguete.
El fixture usa los perfiles reales del repo, para que `meli` tenga su perfil por omisión y
`pers` y `main` la frase de sin perfil.
"""

from __future__ import annotations

import ast
import copy
import fcntl
import importlib.util
import itertools
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
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402

MODULO = ROOT / "scripts" / "agent-work" / "publicar-contexto.py"
MINI = "gon@mini-de-prueba"
LINEA_NUEVA = "línea nueva al inicio\n".encode()
LINEA_PROPIA = "línea mía después de publicar\n".encode()
EDICION_AJENA = "edición ajena\n".encode()
SALIDA_REMOTA = '{"ok": true, "generacion": 1, "agentes": {}, "skills": {}, "conflictos": 0}'
# Las skills que el manifiesto de juguete lista (los perfiles reales las declaran todas) y las
# que la publicación administra: el conjunto nativo de 4.3 es poteto-mode sin scripts/, las
# principle-* y poteto-openclaw; las skills de los perfiles de la ruta CLI no van al nativo.
SKILLS_DEL_MANIFIESTO = [
    "architect",
    "blast-radius",
    "how",
    "poteto-mode",
    "poteto-openclaw",
    "principle-x",
    "tdd",
    "why",
]
SKILLS_ADMINISTRADAS = ["poteto-mode", "poteto-openclaw", "principle-x"]
SSH_FALSO = """#!/bin/sh
# ssh de juguete: registra cada llamada y contesta lo que el publicador espera.
for arg in "$@"; do printf '%s\\n' "$arg" >> "$SUA_TEST_LOGS/ssh.log"; done
printf '%s\\n' --- >> "$SUA_TEST_LOGS/ssh.log"
case " $* " in
  *" agents "*)
    cat "$SUA_TEST_LOGS/agents.json"
    exit 0
    ;;
esac
case " $* " in
  *publicar-contexto.py*)
    codigo=$(cat "$SUA_TEST_LOGS/exit-code.txt" 2>/dev/null || true)
    [ -n "$codigo" ] || codigo=0
    printf '%s\\n' '__SALIDA__'
    exit "$codigo"
    ;;
esac
exit 0
""".replace("__SALIDA__", SALIDA_REMOTA)
SCP_FALSO = """#!/bin/sh
# scp de juguete: registra sus argumentos y no copia nada.
for arg in "$@"; do printf '%s\\n' "$arg" >> "$SUA_TEST_LOGS/scp.log"; done
printf '%s\\n' --- >> "$SUA_TEST_LOGS/scp.log"
exit 0
"""


class PublicadorNativo(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.home = self.tmp / "home"
        for skill in ("grok", "navegacion-estable"):
            # Skills ajenas que viven donde el publicador administra las suyas.
            ruta = self.home / ".openclaw" / "skills" / skill / "SKILL.md"
            ruta.parent.mkdir(parents=True)
            ruta.write_text(f"# skill ajena {skill}\n", encoding="utf-8")
        self.ids = ("meli", "pers", "main")
        self.texto_propio = {
            "meli": "Soy meli, sin salto final.",
            "pers": "Soy pers.\n",
            "main": "Soy main.\nAtiendo de a dos líneas.\n",
        }
        agentes = []
        for identificador in self.ids:
            espacio = self.home / "workspaces" / identificador
            espacio.mkdir(parents=True)
            (espacio / "AGENTS.md").write_text(self.texto_propio[identificador], encoding="utf-8")
            (espacio / "MEMORY.md").write_text(f"memoria de {identificador}\n", encoding="utf-8")
            (espacio / "memory").mkdir()
            (espacio / "memory" / "una.md").write_text(
                f"una nota de {identificador}\n", encoding="utf-8"
            )
            (espacio / "USER.md").write_text(f"usuario de {identificador}\n", encoding="utf-8")
            (espacio / "SOUL.md").write_text(f"alma de {identificador}\n", encoding="utf-8")
            agentes.append(
                {
                    "id": identificador,
                    "workspace": str(espacio),
                    "agentDir": str(espacio),
                    "isDefault": False,
                }
            )
        self.agentes = agentes
        self.agents_json = self.tmp / "agents.json"
        self.agents_json.write_text(
            json.dumps(agentes, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        self.perfiles = contexto.leer_json(contexto.PERFILES)
        # La fuente necesita toda skill que algún perfil declare, porque el manifiesto se arma
        # con los perfiles reales del repo.
        self.fuente = self.tmp / "fuente"
        for ruta, texto in {
            "skills/poteto-mode/SKILL.md": "poteto de juguete\n",
            "skills/poteto-mode/playbooks/feature.md": "1. paso de juguete\n",
            "skills/principle-x/SKILL.md": "principio de juguete\n",
            "skills/architect/SKILL.md": "architect de juguete\n",
            "skills/blast-radius/SKILL.md": "blast-radius de juguete\n",
            "skills/how/SKILL.md": "how de juguete\n",
            "skills/tdd/SKILL.md": "tdd de juguete\n",
            "skills/why/SKILL.md": "why de juguete\n",
            "skills/poteto-openclaw/SKILL.md": "b",
        }.items():
            destino = self.fuente / ruta
            destino.parent.mkdir(parents=True, exist_ok=True)
            destino.write_text(texto, encoding="utf-8")
        self.adaptaciones = {"opencode-run": b"a", "openclaw": b"b"}
        self.manifiesto = contexto.manifiesto(
            self.fuente,
            self.perfiles,
            repo="t",
            commit="t",
            version="0",
            generation=1,
            adaptaciones=self.adaptaciones,
            bloque=contexto.BLOQUE.read_bytes(),
        )
        self.assertEqual(
            sorted({archivo["path"].split("/")[1] for archivo in self.manifiesto["files"]}),
            SKILLS_DEL_MANIFIESTO,
        )
        especificacion = importlib.util.spec_from_file_location("publicar_contexto", MODULO)
        self.armador = importlib.util.module_from_spec(especificacion)
        especificacion.loader.exec_module(self.armador)
        self._contador = itertools.count()

    def armar(self, perfiles=None):
        """Carpeta de publicación nueva, como la arma la mitad Mac antes del scp."""
        carpeta = self.tmp / f"publicacion-{next(self._contador)}"
        self.armador.armar_publicacion(
            carpeta,
            self.manifiesto,
            perfiles or self.perfiles,
            self.agentes,
            fuente=self.fuente,
            script=MODULO,
        )
        self.publicacion = carpeta
        return carpeta

    def publicar(self, accion):
        """Corre la mitad --local por subprocess y exige una sola línea JSON en stdout."""
        resultado = subprocess.run(
            [
                sys.executable,
                "-I",
                str(MODULO),
                "--local",
                f"--{accion}",
                "--publicacion",
                str(self.publicacion),
                "--home",
                str(self.home),
                "--agentes-json",
                str(self.agents_json),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(resultado.stderr, "")
        lineas = resultado.stdout.splitlines()
        self.assertEqual(len(lineas), 1, resultado.stdout)
        return resultado.returncode, json.loads(lineas[0])

    def bloque_de(self, identificador, perfiles=None):
        return contexto.bloque(
            contexto.BLOQUE.read_text(encoding="utf-8"),
            self.manifiesto,
            contexto.perfil_por_omision(perfiles or self.perfiles, identificador),
        )

    def esperado_con_bloque(self, identificador, perfiles=None):
        propio = self.texto_propio[identificador].encode("utf-8")
        if not propio.endswith(b"\n"):
            propio += b"\n"
        return propio + self.bloque_de(identificador, perfiles).encode("utf-8")

    def agents_md(self, identificador):
        return (self.home / "workspaces" / identificador / "AGENTS.md").read_bytes()

    def foto_de_lo_no_adminado(self):
        """Bytes de todo lo que el publicador no debe tocar: memoria, usuario y skills ajenas."""
        foto = {}
        for identificador in self.ids:
            espacio = self.home / "workspaces" / identificador
            for ruta in sorted(espacio.rglob("*")):
                if ruta.is_file() and ruta.name != "AGENTS.md":
                    foto[str(ruta)] = ruta.read_bytes()
        for skill in ("grok", "navegacion-estable"):
            for ruta in sorted((self.home / ".openclaw" / "skills" / skill).rglob("*")):
                if ruta.is_file():
                    foto[str(ruta)] = ruta.read_bytes()
        return foto

    def comparar(self, foto):
        self.assertEqual(self.foto_de_lo_no_adminado(), foto)

    def foto_del_home(self):
        """Digest y mtime de cada archivo del home: lo que no se escribe no cambia su mtime."""
        return {
            str(ruta): (ruta.stat().st_mtime_ns, contexto.sha256(ruta.read_bytes()))
            for ruta in sorted(self.home.rglob("*"))
            if ruta.is_file()
        }

    def test_a_block_names_a_default_profile_only_when_the_agent_has_exactly_one(self):
        carpeta = self.armar()
        bloque = (carpeta / "bloques" / "meli.md").read_text(encoding="utf-8")
        self.assertEqual(bloque, self.bloque_de("meli"))
        self.assertIn("Tu perfil por omisión es `meli`.", bloque)
        self.assertNotIn(contexto.SIN_PERFIL, bloque)
        for identificador in ("pers", "main"):
            with self.subTest(agente=identificador):
                texto = (carpeta / "bloques" / f"{identificador}.md").read_text(encoding="utf-8")
                self.assertEqual(texto, self.bloque_de(identificador))
                self.assertIn("No tienes perfil por omisión", texto)
                self.assertNotIn("Tu perfil por omisión es", texto)
                self.assertNotIn("`meli`", texto)
        # Dos perfiles que nombran a meli: el bloque no elige ninguno de los dos.
        dos = copy.deepcopy(self.perfiles)
        segundo = copy.deepcopy(contexto.perfil(dos, "meli"))
        segundo["id"] = "meli-dos"
        dos["profiles"].append(segundo)
        self.assertIsNone(contexto.perfil_por_omision(dos, "meli"))
        carpeta_dos = self.armar(perfiles=dos)
        texto = (carpeta_dos / "bloques" / "meli.md").read_text(encoding="utf-8")
        self.assertEqual(texto, self.bloque_de("meli", dos))
        self.assertIn(contexto.SIN_PERFIL, texto)

    def test_the_publisher_touches_only_the_block_and_its_skills(self):
        self.armar()
        protegidos = self.foto_de_lo_no_adminado()
        codigo, lectura = self.publicar("leer")
        self.assertEqual(
            (codigo, lectura["ok"], lectura["generacion"], lectura["conflictos"]),
            (0, True, 1, 0),
        )
        self.comparar(protegidos)
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            (codigo, aplicar),
            (
                0,
                {
                    "ok": True,
                    "generacion": 1,
                    "agentes": {"meli": "publicado", "pers": "publicado", "main": "publicado"},
                    "skills": {skill: "publicado" for skill in SKILLS_ADMINISTRADAS},
                    "conflictos": 0,
                },
            ),
        )
        self.comparar(protegidos)
        for identificador in self.ids:
            self.assertEqual(self.agents_md(identificador), self.esperado_con_bloque(identificador))
        # La segunda aplicar no escribe nada: ni bytes ni mtime de ningún archivo del home.
        antes = self.foto_del_home()
        codigo, segunda = self.publicar("aplicar")
        self.assertEqual(
            (codigo, segunda),
            (
                0,
                {
                    "ok": True,
                    "generacion": 1,
                    "agentes": {identificador: "igual" for identificador in self.ids},
                    "skills": {skill: "igual" for skill in SKILLS_ADMINISTRADAS},
                    "conflictos": 0,
                },
            ),
        )
        self.assertEqual(self.foto_del_home(), antes)
        self.comparar(protegidos)
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(
            (codigo, revertir),
            (
                0,
                {
                    "ok": True,
                    "generacion": 1,
                    "agentes": {identificador: "revertido" for identificador in self.ids},
                    "skills": {skill: "quitado" for skill in SKILLS_ADMINISTRADAS},
                    "conflictos": 0,
                },
            ),
        )
        for identificador in self.ids:
            self.assertEqual(
                self.agents_md(identificador),
                self.texto_propio[identificador].encode("utf-8"),
            )
        for skill in SKILLS_ADMINISTRADAS:
            self.assertFalse((self.home / ".openclaw" / "skills" / skill).exists(), skill)
        estado = self.home / ".openclaw" / "skills" / ".sua-contexto.json"
        self.assertTrue(
            not estado.exists() or json.loads(estado.read_text()).get("generacion") is None
        )
        self.comparar(protegidos)

    def test_an_edited_block_is_a_conflict_not_an_overwrite(self):
        self.armar()
        self.publicar("leer")
        # El dueño puso un bloque del publicador con una línea cambiada a mano.
        bloque_editado = self.bloque_de("meli").replace(
            "Para trabajo de ingeniería", "EDITADO a mano", 1
        )
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(
            self.texto_propio["meli"].encode("utf-8") + b"\n" + bloque_editado.encode("utf-8")
        )
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["agentes"],
            {"meli": "conflicto: el bloque fue editado", "pers": "publicado", "main": "publicado"},
        )
        self.assertEqual(aplicar["skills"], {skill: "publicado" for skill in SKILLS_ADMINISTRADAS})
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        # El archivo de meli queda exactamente como lo dejó el dueño.
        self.assertEqual(
            meli.read_bytes(),
            self.texto_propio["meli"].encode("utf-8") + b"\n" + bloque_editado.encode("utf-8"),
        )
        self.assertEqual(self.agents_md("pers"), self.esperado_con_bloque("pers"))
        self.assertEqual(self.agents_md("main"), self.esperado_con_bloque("main"))

    def test_an_edit_between_read_and_apply_is_a_conflict(self):
        self.armar()
        self.publicar("leer")
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(LINEA_NUEVA + self.texto_propio["meli"].encode("utf-8"))
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["agentes"],
            {
                "meli": "conflicto: cambió después de --leer",
                "pers": "publicado",
                "main": "publicado",
            },
        )
        self.assertEqual(aplicar["skills"], {skill: "publicado" for skill in SKILLS_ADMINISTRADAS})
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        # meli conserva su línea nueva y no recibió bloque.
        self.assertEqual(meli.read_bytes(), LINEA_NUEVA + self.texto_propio["meli"].encode("utf-8"))
        self.assertNotIn(b"<!-- sua-contexto inicio", meli.read_bytes())
        self.assertEqual(self.agents_md("pers"), self.esperado_con_bloque("pers"))
        self.assertEqual(self.agents_md("main"), self.esperado_con_bloque("main"))

    def test_a_revert_never_undoes_an_edit_made_after_apply(self):
        self.armar()
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(codigo, 0)
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(meli.read_bytes() + LINEA_PROPIA)
        skill = self.home / ".openclaw" / "skills" / "poteto-mode" / "SKILL.md"
        skill.write_bytes(skill.read_bytes() + EDICION_AJENA)
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(
            revertir["agentes"],
            {
                "meli": "conflicto: cambió después de publicar",
                "pers": "revertido",
                "main": "revertido",
            },
        )
        self.assertEqual(
            revertir["skills"],
            {
                nombre: (
                    "conflicto: cambió después de publicar"
                    if nombre == "poteto-mode"
                    else "quitado"
                )
                for nombre in SKILLS_ADMINISTRADAS
            },
        )
        self.assertEqual((revertir["conflictos"], codigo), (2, 4))
        # Las ediciones posteriores quedan intactas.
        self.assertIn(LINEA_PROPIA, meli.read_bytes())
        self.assertIn(EDICION_AJENA, skill.read_bytes())
        # Los demás vuelven byte por byte al original y las demás skills desaparecen.
        for identificador in ("pers", "main"):
            self.assertEqual(
                self.agents_md(identificador), self.texto_propio[identificador].encode("utf-8")
            )
        for nombre in SKILLS_ADMINISTRADAS:
            if nombre != "poteto-mode":
                self.assertFalse((self.home / ".openclaw" / "skills" / nombre).exists(), nombre)

    def test_two_publishers_do_not_overlap(self):
        self.armar()
        # El candado lo toma el proceso de la prueba: el publicador debe rehusar sin escribir.
        carpeta_candado = self.home / ".openclaw" / "sua-contexto"
        carpeta_candado.mkdir(parents=True)
        candado = open(carpeta_candado / ".lock", "a+b")
        self.addCleanup(candado.close)
        fcntl.flock(candado.fileno(), fcntl.LOCK_EX)
        try:
            codigo, respuesta = self.publicar("aplicar")
        finally:
            fcntl.flock(candado.fileno(), fcntl.LOCK_UN)
        self.assertEqual(
            (codigo, respuesta), (3, {"ok": False, "error": "otro publicador en curso"})
        )
        for identificador in self.ids:
            self.assertEqual(
                self.agents_md(identificador),
                self.texto_propio[identificador].encode("utf-8"),
            )
            self.assertNotIn(b"<!-- sua-contexto inicio", self.agents_md(identificador))
        self.assertFalse((self.home / ".openclaw" / "skills" / ".sua-contexto.json").exists())
        for skill in SKILLS_ADMINISTRADAS:
            self.assertFalse((self.home / ".openclaw" / "skills" / skill).exists(), skill)

    def test_a_foreign_skill_with_a_managed_name_stops_that_skill(self):
        self.armar()
        ajena = self.home / ".openclaw" / "skills" / "poteto-mode"
        ajena.mkdir(parents=True)
        (ajena / "SKILL.md").write_text("# skill ajena con nombre administrado\n", encoding="utf-8")
        (ajena / "extra.md").write_text("archivo ajeno\n", encoding="utf-8")
        foto = {str(ruta): ruta.read_bytes() for ruta in sorted(ajena.rglob("*")) if ruta.is_file()}
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["skills"],
            {
                nombre: (
                    "conflicto: no es del publicador" if nombre == "poteto-mode" else "publicado"
                )
                for nombre in SKILLS_ADMINISTRADAS
            },
        )
        self.assertEqual(
            aplicar["agentes"],
            {identificador: "publicado" for identificador in self.ids},
        )
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        # La skill ajena quedó byte por byte igual.
        self.assertEqual(
            {str(ruta): ruta.read_bytes() for ruta in sorted(ajena.rglob("*")) if ruta.is_file()},
            foto,
        )
        for nombre in SKILLS_ADMINISTRADAS:
            if nombre != "poteto-mode":
                self.assertTrue((self.home / ".openclaw" / "skills" / nombre).is_dir(), nombre)

    def test_the_mac_half_uses_ssh_and_scp_and_reports_their_arguments(self):
        binarios = self.tmp / "bin"
        logs = self.tmp / "logs"
        binarios.mkdir()
        logs.mkdir()
        shutil.copy(self.agents_json, logs / "agents.json")
        for nombre, texto in (("ssh", SSH_FALSO), ("scp", SCP_FALSO)):
            ruta = binarios / nombre
            ruta.write_text(texto, encoding="utf-8")
            ruta.chmod(0o755)
        # Checkout de juguete: manifiesto sin archivos, para que armar no copie fuente alguna.
        vacio = {**self.manifiesto, "files": []}
        vacio["digest"] = contexto.digest_de(vacio)
        contexto_dir = self.tmp / "checkout" / "scripts" / "agent-work" / "contexto"
        contexto_dir.mkdir(parents=True)
        (contexto_dir / "poteto.v1.json").write_text(
            json.dumps(vacio, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        (contexto_dir / "generaciones.json").write_text(
            json.dumps({"1": vacio["digest"]}) + "\n", encoding="utf-8"
        )
        shutil.copy(contexto.PERFILES, contexto_dir / "perfiles.v1.json")
        for salida in ("0", "4"):
            with self.subTest(salida=salida):
                (logs / "exit-code.txt").write_text(salida + "\n", encoding="utf-8")
                for registro in ("ssh.log", "scp.log"):
                    (logs / registro).unlink(missing_ok=True)
                resultado = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        str(MODULO),
                        "--aplicar",
                        "--mini",
                        MINI,
                        "--checkout",
                        str(self.tmp / "checkout"),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=60,
                    env={
                        **os.environ,
                        "PATH": str(binarios) + os.pathsep + os.environ["PATH"],
                        "SUA_TEST_LOGS": str(logs),
                    },
                )
                self.assertEqual(resultado.stderr, "")
                self.assertEqual(resultado.stdout.splitlines(), [SALIDA_REMOTA])
                self.assertEqual(resultado.returncode, int(salida))
                llamadas_ssh = self.llamadas(logs / "ssh.log")
                # La lista de agentes se pidió por ssh, con --mini en la llamada.
                self.assertTrue(
                    any(MINI in llamada and "agents" in llamada for llamada in llamadas_ssh)
                )
                llamadas_scp = self.llamadas(logs / "scp.log")
                self.assertTrue(
                    any(
                        any(arg.startswith("/tmp/") for arg in llamada)
                        and any(arg.startswith(f"{MINI}:/tmp/") for arg in llamada)
                        for llamada in llamadas_scp
                    )
                )
                nombre = None
                for llamada in llamadas_ssh:
                    for arg in llamada:
                        coincide = re.fullmatch(r"/tmp/([^/]+)/publicar-contexto\.py", arg)
                        if coincide:
                            nombre = coincide.group(1)
                self.assertIsNotNone(nombre)
                # La llamada remota es exactamente la del contrato.
                self.assertIn(
                    [
                        MINI,
                        "python3",
                        f"/tmp/{nombre}/publicar-contexto.py",
                        "--local",
                        "--aplicar",
                        "--publicacion",
                        f"/tmp/{nombre}",
                    ],
                    llamadas_ssh,
                )

    def llamadas(self, registro):
        """Las llamadas de un log de juguete: argumentos por línea, --- entre llamadas."""
        llamadas, actual = [], []
        for linea in registro.read_text(encoding="utf-8").splitlines():
            if linea == "---":
                llamadas.append(actual)
                actual = []
            else:
                actual.append(linea)
        if actual:
            llamadas.append(actual)
        return llamadas


class Sintaxis(unittest.TestCase):
    def test_the_local_half_parses_as_python_3_9(self):
        fuente = MODULO.read_text(encoding="utf-8")
        ast.parse(fuente, filename=str(MODULO), feature_version=(3, 9))
        resultado = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                "import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3,9))",
                str(MODULO),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual((resultado.returncode, resultado.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()

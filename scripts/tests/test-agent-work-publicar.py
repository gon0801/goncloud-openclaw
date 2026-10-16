#!/usr/bin/env python3
"""El publicador nativo de SUA-03 (diseño, 4.3 y filas I11 de la sección 5).

Cada caso arma una publicación de juguete con `armar_publicacion` y corre la mitad --local del
módulo por subprocess, como la corre la Mini. La mitad Mac se prueba con ssh y scp de juguete.
El fixture usa los perfiles reales del repo, para que `meli` tenga su perfil por omisión y
`pers` y `main` la frase de sin perfil.
"""

from __future__ import annotations

import ast
import contextlib
import copy
import fcntl
import importlib.util
import io
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
from unittest import mock

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
SCP_FALSO_ROTO = """#!/bin/sh
# scp de juguete que falla: registra sus argumentos y sale 1 sin copiar nada.
for arg in "$@"; do printf '%s\\n' "$arg" >> "$SUA_TEST_LOGS/scp.log"; done
printf '%s\\n' --- >> "$SUA_TEST_LOGS/scp.log"
exit 1
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

    def armar_generacion(self, generation, cambios=None, quitados=None, perfiles=None):
        """Publicación de una generación nueva: la fuente de la generación 1 con los cambios
        dados (y sin los archivos quitados), su manifiesto y su carpeta."""
        fuente = self.tmp / f"fuente-{generation}"
        shutil.copytree(self.fuente, fuente)
        for ruta, texto in (cambios or {}).items():
            destino = fuente / ruta
            destino.parent.mkdir(parents=True, exist_ok=True)
            destino.write_text(texto, encoding="utf-8")
        for ruta in quitados or ():
            (fuente / ruta).unlink()
        manifiesto = contexto.manifiesto(
            fuente,
            perfiles or self.perfiles,
            repo="t",
            commit="t",
            version="0",
            generation=generation,
            adaptaciones=self.adaptaciones,
            bloque=contexto.BLOQUE.read_bytes(),
        )
        carpeta = self.tmp / f"publicacion-{next(self._contador)}"
        self.armador.armar_publicacion(
            carpeta,
            manifiesto,
            perfiles or self.perfiles,
            self.agentes,
            fuente=fuente,
            script=MODULO,
        )
        self.publicacion = carpeta
        return carpeta

    def armar_sin_skill(self, generation, nombre):
        """Publicación de una generación de la que sale una skill: fuera de la fuente y de
        las skills que declaran los perfiles, como una skill que deja de administrarse."""
        fuente = self.tmp / f"fuente-{generation}"
        shutil.copytree(self.fuente, fuente)
        shutil.rmtree(fuente / "skills" / nombre)
        perfiles = copy.deepcopy(self.perfiles)
        for perfil in perfiles["profiles"]:
            perfil["skills"] = [s for s in perfil["skills"] if s != nombre]
        manifiesto = contexto.manifiesto(
            fuente,
            perfiles,
            repo="t",
            commit="t",
            version="0",
            generation=generation,
            adaptaciones=self.adaptaciones,
            bloque=contexto.BLOQUE.read_bytes(),
        )
        carpeta = self.tmp / f"publicacion-{next(self._contador)}"
        self.armador.armar_publicacion(
            carpeta, manifiesto, perfiles, self.agentes, fuente=fuente, script=MODULO
        )
        self.publicacion = carpeta
        return carpeta

    def skill_del_home(self, nombre):
        return self.home / ".openclaw" / "skills" / nombre / "SKILL.md"

    def respaldo_de_generacion(self, generation, nombre):
        return (
            self.home
            / ".openclaw"
            / "sua-contexto"
            / str(generation)
            / "skills"
            / nombre
            / "SKILL.md"
        )

    def publicar(self, accion, agentes_json=None):
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
                str(agentes_json or self.agents_json),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(resultado.stderr, "")
        lineas = resultado.stdout.splitlines()
        self.assertEqual(len(lineas), 1, resultado.stdout)
        return resultado.returncode, json.loads(lineas[0])

    def revertir_con_copia_que_falla(self):
        """La reversa en proceso con la copia rota a medias (C6 de SUA03-G5c): el
        fallo se inyecta en copytree y no depende de permisos, así que también
        falla cuando quien corre lee un archivo 000 (un runner como root)."""

        def copia_que_falla(origen, destino, **kwargs):
            destino.mkdir(parents=True)
            (destino / "SKILL.md").write_text("a medias\n", encoding="utf-8")
            raise OSError("copia rota a medias")

        salida = io.StringIO()
        with mock.patch.object(self.armador.shutil, "copytree", copia_que_falla):
            with contextlib.redirect_stdout(salida):
                codigo = self.armador.main(
                    [
                        "--local",
                        "--revertir",
                        "--publicacion",
                        str(self.publicacion),
                        "--home",
                        str(self.home),
                        "--agentes-json",
                        str(self.agents_json),
                    ]
                )
        lineas = salida.getvalue().splitlines()
        return codigo, json.loads(lineas[-1]) if lineas else {}

    def estado_del_home(self):
        return json.loads(
            (self.home / ".openclaw" / "skills" / ".sua-contexto.json").read_text(encoding="utf-8")
        )

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

    def test_revert_keeps_the_skills_the_generation_did_not_rewrite(self):
        # B1 del veredicto r1: la generación 2 reescribe principle-x y deja las otras igual;
        # la reversa devuelve principle-x a los bytes de la 1 y deja las otras con ellos.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        bytes_de_generacion_1 = {
            nombre: self.skill_del_home(nombre).read_bytes() for nombre in SKILLS_ADMINISTRADAS
        }
        self.armar_generacion(2, cambios={"skills/principle-x/SKILL.md": "principio v2\n"})
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["skills"],
            {
                "poteto-mode": "igual",
                "poteto-openclaw": "igual",
                "principle-x": "publicado",
            },
        )
        self.assertEqual(codigo, 0)
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(
            revertir["skills"],
            {
                "poteto-mode": "igual",
                "poteto-openclaw": "igual",
                "principle-x": "revertido",
            },
        )
        self.assertEqual((revertir["conflictos"], codigo), (0, 0))
        for nombre in SKILLS_ADMINISTRADAS:
            self.assertEqual(
                self.skill_del_home(nombre).read_bytes(), bytes_de_generacion_1[nombre], nombre
            )
        estado = json.loads(
            (self.home / ".openclaw" / "skills" / ".sua-contexto.json").read_text(encoding="utf-8")
        )
        self.assertEqual(estado["generacion"], 1)

    def test_reapplying_a_generation_never_stomps_its_backup(self):
        # B2 del veredicto r1: tras publicar la generación 2, una edición de la skill en el
        # home es conflicto; la re-aplicación no pisa el respaldo ni la edición.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/poteto-mode/SKILL.md": "poteto v2\n"})
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["poteto-mode"], "publicado")
        self.assertEqual(codigo, 0)
        respaldo = self.respaldo_de_generacion(2, "poteto-mode")
        self.assertEqual(respaldo.read_bytes(), b"poteto de juguete\n")
        skill = self.skill_del_home("poteto-mode")
        skill.write_bytes(skill.read_bytes() + EDICION_AJENA)
        self.publicar("leer")
        codigo, segunda = self.publicar("aplicar")
        self.assertEqual(
            segunda["skills"],
            {
                "poteto-mode": "conflicto: cambió después de publicar",
                "poteto-openclaw": "igual",
                "principle-x": "igual",
            },
        )
        self.assertEqual((segunda["conflictos"], codigo), (1, 4))
        self.assertEqual(skill.read_bytes(), b"poteto v2\n" + EDICION_AJENA)
        self.assertEqual(respaldo.read_bytes(), b"poteto de juguete\n")

    def test_a_revert_refuses_while_another_publisher_holds_the_lock(self):
        # S1 del veredicto r1: el candado también es de --revertir, y no cambia nada.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        carpeta_candado = self.home / ".openclaw" / "sua-contexto"
        candado = open(carpeta_candado / ".lock", "a+b")
        self.addCleanup(candado.close)
        fcntl.flock(candado.fileno(), fcntl.LOCK_EX)
        foto = self.foto_del_home()
        try:
            codigo, respuesta = self.publicar("revertir")
        finally:
            fcntl.flock(candado.fileno(), fcntl.LOCK_UN)
        self.assertEqual(
            (codigo, respuesta), (3, {"ok": False, "error": "otro publicador en curso"})
        )
        self.assertEqual(self.foto_del_home(), foto)

    def test_applying_a_generation_removes_the_files_it_dropped_from_a_skill(self):
        # S2 del veredicto r1: un archivo que la publicación ya no trae sale del home.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        quitado = self.home / ".openclaw" / "skills" / "poteto-mode" / "playbooks" / "feature.md"
        self.assertTrue(quitado.exists())
        self.armar_generacion(2, quitados=["skills/poteto-mode/playbooks/feature.md"])
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["poteto-mode"], "publicado")
        self.assertEqual(codigo, 0)
        self.assertFalse(quitado.exists())
        self.assertTrue(self.skill_del_home("poteto-mode").exists())

    def test_a_half_marked_block_is_a_conflict_not_an_append(self):
        # S3 del veredicto r1: media marca es una edición del bloque, no su ausencia.
        self.armar()
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(
            self.texto_propio["meli"].encode("utf-8") + b"\n<!-- sua-contexto inicio -->\n"
        )
        foto = meli.read_bytes()
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["agentes"]["meli"], "conflicto: el bloque fue editado")
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        self.assertEqual(meli.read_bytes(), foto)

    def test_reapplying_a_generation_leaves_the_previous_state_untouched(self):
        # S5 del veredicto r1: el estado anterior de la generación se escribe una vez; una
        # segunda --aplicar, aunque traiga conflicto, no lo reescibe.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/principle-x/SKILL.md": "principio v2\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        ancla = self.home / ".openclaw" / "sua-contexto" / "2" / "estado-anterior.json"
        bytes_del_ancla = ancla.read_bytes()
        self.assertEqual(json.loads(bytes_del_ancla)["generacion"], 1)
        skill = self.skill_del_home("poteto-mode")
        skill.write_bytes(skill.read_bytes() + EDICION_AJENA)
        self.publicar("leer")
        codigo, segunda = self.publicar("aplicar")
        self.assertEqual(segunda["skills"]["poteto-mode"], "conflicto: cambió después de publicar")
        self.assertEqual(codigo, 4)
        self.assertEqual(ancla.read_bytes(), bytes_del_ancla)

    def test_a_revert_after_reapplying_keeps_the_edit_made_after_a_previous_revert(self):
        # CR1 del anexo de CodeRabbit: revertir, editar fuera del bloque, reaplicar la
        # misma generación y revertir otra vez deja la línea del dueño, byte por byte.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/poteto-mode/SKILL.md": "poteto v2\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        self.publicar("revertir")
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(meli.read_bytes() + LINEA_PROPIA)
        del_dueno = meli.read_bytes()
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["agentes"]["meli"], "publicado")
        self.assertEqual(codigo, 0)
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(revertir["agentes"]["meli"], "revertido")
        self.assertIn(LINEA_PROPIA, meli.read_bytes())
        self.assertEqual(meli.read_bytes(), del_dueno)

    def test_an_edit_outside_the_block_survives_as_a_named_conflict(self):
        # CR1b del anexo de CodeRabbit: sin reversa de por medio. Tras aplicar la gen 2,
        # el dueño agrega una línea fuera del bloque de meli y le borra el bloque a pers;
        # la reversa nombra el conflicto de meli, conserva su línea y el estado sigue en
        # la generación 2.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2)
        self.publicar("leer")
        self.publicar("aplicar")
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        pers = self.home / "workspaces" / "pers" / "AGENTS.md"
        meli.write_bytes(meli.read_bytes() + LINEA_PROPIA)
        pers.write_bytes(self.texto_propio["pers"].encode("utf-8"))
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["agentes"], {"meli": "igual", "pers": "publicado", "main": "igual"}
        )
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(revertir["agentes"]["meli"], "conflicto: cambió después de publicar")
        self.assertEqual(revertir["agentes"]["pers"], "revertido")
        self.assertEqual((revertir["conflictos"], codigo), (1, 4))
        self.assertIn(LINEA_PROPIA, meli.read_bytes())
        self.assertEqual(self.estado_del_home()["generacion"], 2)

    def test_a_conflicted_revert_keeps_the_state_until_it_finishes(self):
        # CR2 del anexo de CodeRabbit: una reversa con conflicto conserva en el estado lo
        # que sigue publicado; deshecha la edición, otra --revertir termina y quita la skill.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        publicado = self.armador.digest_de_carpeta(self.publicacion / "skills" / "poteto-mode")
        skill = self.skill_del_home("poteto-mode")
        skill.write_bytes(b"editada en la mini\n")
        codigo, primera = self.publicar("revertir")
        self.assertEqual(primera["skills"]["poteto-mode"], "conflicto: cambió después de publicar")
        self.assertEqual((primera["conflictos"], codigo), (1, 4))
        estado = self.estado_del_home()
        self.assertEqual(estado["generacion"], 1)
        self.assertEqual(estado["skills"], {"poteto-mode": publicado})
        skill.write_bytes(b"poteto de juguete\n")
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["poteto-mode"], "igual")
        codigo, segunda = self.publicar("revertir")
        self.assertEqual((segunda["conflictos"], codigo), (0, 0))
        self.assertEqual(segunda["skills"]["poteto-mode"], "quitado")
        self.assertFalse(skill.exists())
        self.assertIsNone(self.estado_del_home()["generacion"])

    def test_a_revert_does_not_compare_what_the_generation_did_not_rewrite(self):
        # D3: la generación 2 solo reescribe a meli y principle-x; el dueño edita fuera
        # del bloque de pers (que la generación no tocó) y edita poteto-mode; la reversa
        # los deja "igual" sin compararlos y las dos ediciones quedan byte por byte.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/principle-x/SKILL.md": "principio v2\n"})
        solo_meli = self.tmp / "agents-solo-meli.json"
        solo_meli.write_text(json.dumps([self.agentes[0]]) + "\n", encoding="utf-8")
        self.publicar("leer", solo_meli)
        codigo, aplicar = self.publicar("aplicar", solo_meli)
        self.assertEqual(aplicar["agentes"], {"meli": "publicado"})
        pers = self.home / "workspaces" / "pers" / "AGENTS.md"
        pers.write_bytes(pers.read_bytes() + LINEA_PROPIA)
        del_dueno = pers.read_bytes()
        skill = self.skill_del_home("poteto-mode")
        skill.write_bytes(skill.read_bytes() + EDICION_AJENA)
        edicion = skill.read_bytes()
        codigo, revertir = self.publicar("revertir")
        self.assertEqual((revertir["conflictos"], codigo), (0, 0))
        self.assertEqual(
            revertir["agentes"], {"meli": "revertido", "pers": "igual", "main": "igual"}
        )
        self.assertEqual(
            revertir["skills"],
            {"poteto-mode": "igual", "poteto-openclaw": "igual", "principle-x": "revertido"},
        )
        self.assertEqual(pers.read_bytes(), del_dueno)
        self.assertEqual(skill.read_bytes(), edicion)

    def test_reapplying_an_older_generation_reverts_back_to_the_newest(self):
        # D5: el estado anterior de una generación se reescribe cuando la generación
        # publicada es otra; reaplicar la gen 2 después de la 3 y revertir vuelve a la 3.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        publicacion_2 = self.armar_generacion(
            2, cambios={"skills/poteto-mode/SKILL.md": "poteto v2\n"}
        )
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(3, cambios={"skills/poteto-mode/SKILL.md": "poteto v3\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        self.publicacion = publicacion_2
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["poteto-mode"], "publicado")
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(revertir["skills"]["poteto-mode"], "revertido")
        self.assertEqual(self.estado_del_home()["generacion"], 3)
        self.assertEqual(self.skill_del_home("poteto-mode").read_bytes(), b"poteto v3\n")

    def test_an_agents_md_keeps_its_0644_through_apply_and_revert(self):
        # N4 (F1 de DeepSeek): la escritura atómica no baja el modo del AGENTS.md.
        self.armar()
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        self.assertEqual(meli.stat().st_mode & 0o777, 0o644)
        self.publicar("leer")
        self.publicar("aplicar")
        self.assertEqual(meli.stat().st_mode & 0o777, 0o644)
        self.publicar("revertir")
        self.assertEqual(meli.stat().st_mode & 0o777, 0o644)

    def test_an_executable_file_of_a_published_skill_arrives_executable(self):
        # N4 (F1 de DeepSeek): el modo del archivo de la publicación llega al home.
        self.armar()
        ejecutable = self.publicacion / "skills" / "poteto-mode" / "playbooks" / "feature.md"
        os.chmod(ejecutable, 0o755)
        self.publicar("leer")
        self.publicar("aplicar")
        destino = self.home / ".openclaw" / "skills" / "poteto-mode" / "playbooks" / "feature.md"
        self.assertEqual(destino.stat().st_mode & 0o777, 0o755)

    def test_a_managed_skill_deleted_on_the_mini_is_a_conflict(self):
        # C4 (DeepSeek F7): borrar una skill administrada es una edición; re-aplicar no
        # la recrea en silencio.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        borrada = self.home / ".openclaw" / "skills" / "poteto-mode"
        shutil.rmtree(borrada)
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(
            aplicar["skills"]["poteto-mode"], "conflicto: se borró después de publicar"
        )
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        self.assertFalse(borrada.exists())
        self.assertEqual(
            self.estado_del_home()["skills"]["poteto-mode"],
            self.armador.digest_de_carpeta(self.publicacion / "skills" / "poteto-mode"),
        )

    def test_a_skill_that_leaves_the_manifest_is_removed_with_its_backup(self):
        # C8 (fila L2 de G5): una skill administrada que la generación nueva ya no trae
        # sale del home y del estado, con su respaldo para la reversa.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_sin_skill(2, "principle-x")
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["principle-x"], "quitado")
        self.assertEqual(codigo, 0)
        self.assertFalse((self.home / ".openclaw" / "skills" / "principle-x").exists())
        estado = self.estado_del_home()
        self.assertNotIn("principle-x", estado["skills"])
        respaldo = self.respaldo_de_generacion(2, "principle-x")
        self.assertEqual(respaldo.read_bytes(), b"principio de juguete\n")

    def test_a_dropped_skill_edited_on_the_mini_is_a_conflict(self):
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        editada = self.skill_del_home("principle-x")
        editada.write_bytes(editada.read_bytes() + EDICION_AJENA)
        self.armar_sin_skill(2, "principle-x")
        self.publicar("leer")
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["skills"]["principle-x"], "conflicto: cambió después de publicar")
        self.assertEqual((aplicar["conflictos"], codigo), (1, 4))
        self.assertIn(EDICION_AJENA, editada.read_bytes())
        self.assertIn("principle-x", self.estado_del_home()["skills"])

    def test_the_revert_brings_back_a_skill_that_left_the_manifest(self):
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_sin_skill(2, "principle-x")
        self.publicar("leer")
        self.publicar("aplicar")
        self.assertFalse((self.home / ".openclaw" / "skills" / "principle-x").exists())
        codigo, revertir = self.publicar("revertir")
        self.assertEqual(revertir["skills"]["principle-x"], "revertido")
        self.assertEqual((revertir["conflictos"], codigo), (0, 0))
        self.assertEqual(self.skill_del_home("principle-x").read_bytes(), b"principio de juguete\n")
        self.assertEqual(self.estado_del_home()["generacion"], 1)
        self.assertIn("principle-x", self.estado_del_home()["skills"])

    def test_the_revert_restores_the_profiles_of_the_previous_generation(self):
        # C5 (DeepSeek F3): perfiles.v1.json queda dentro de la reversa, sin CAS (el
        # archivo es solo del publicador); la primera publicación lo quita al revertir.
        perfiles_b = copy.deepcopy(self.perfiles)
        perfiles_b["profiles"][0]["purpose"] = "Propósito de la generación 2\n"
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        destino = self.home / ".local" / "share" / "agent-work" / "perfiles.v1.json"
        foto_a = destino.read_bytes()
        self.armar_generacion(2, perfiles=perfiles_b)
        self.publicar("leer")
        self.publicar("aplicar")
        self.assertNotEqual(destino.read_bytes(), foto_a)
        self.publicar("revertir")
        self.assertEqual(destino.read_bytes(), foto_a)
        self.publicar("revertir")
        self.assertFalse(destino.exists())

    def test_a_failed_skill_backup_copy_leaves_the_previous_backup_whole(self):
        # C2: el respaldo de una skill se arma en una carpeta temporal hermana y se pone
        # en su lugar con os.replace, de modo que una copia a medias no rompa el respaldo.
        origen = self.tmp / "origen-respaldo"
        (origen / "intern").mkdir(parents=True)
        (origen / "SKILL.md").write_text("nueva\n", encoding="utf-8")
        respaldo = self.tmp / "respaldos" / "poteto-mode"
        respaldo.mkdir(parents=True)
        (respaldo / "SKILL.md").write_text("respaldo anterior\n", encoding="utf-8")
        copia_real = shutil.copytree

        def copia_que_falla(Origen, destino, **kwargs):
            destino.mkdir(parents=True)
            (destino / "SKILL.md").write_text("a medias\n", encoding="utf-8")
            raise OSError("se acabó el disco")

        with mock.patch.object(self.armador.shutil, "copytree", copia_que_falla):
            with self.assertRaises(OSError):
                self.armador.respalda_carpeta(origen, respaldo)
        self.assertEqual((respaldo / "SKILL.md").read_bytes(), b"respaldo anterior\n")
        self.assertEqual(copia_real, shutil.copytree)
        self.assertEqual(
            [p.name for p in respaldo.parent.iterdir()],
            ["poteto-mode"],
            "la copia a medias quedó tirada en la carpeta de respaldos",
        )

    def test_a_failed_final_replace_restores_what_was_set_aside(self):
        # C4 de SUA03-G5c: lo apartado (.viejo-*) se borra solo después de que entra
        # el os.replace final; si ese replace falla, lo apartado vuelve a su lugar.
        origen = self.tmp / "origen-c4"
        (origen / "intern").mkdir(parents=True)
        (origen / "SKILL.md").write_text("nueva\n", encoding="utf-8")
        destino = self.tmp / "respaldos" / "poteto-mode"
        destino.mkdir(parents=True)
        (destino / "SKILL.md").write_text("de antes\n", encoding="utf-8")
        reemplazo_real = os.replace
        llamadas = []

        def reemplazo_que_falla_en_la_segunda(fuente, meta, **kwargs):
            llamadas.append(1)
            if len(llamadas) == 2:
                raise OSError("replace final roto")
            return reemplazo_real(fuente, meta, **kwargs)

        with mock.patch.object(self.armador.os, "replace", reemplazo_que_falla_en_la_segunda):
            with self.assertRaises(OSError):
                self.armador.respalda_carpeta(origen, destino)
        self.assertEqual((destino / "SKILL.md").read_bytes(), b"de antes\n")
        self.assertEqual([p.name for p in destino.parent.iterdir()], ["poteto-mode"])

    def test_a_failed_restore_keeps_what_was_set_aside_and_raises_the_first_error(self):
        # B1 de G5d: si también falla devolver lo apartado, no se borra lo
        # apartado y se propaga el error original, no el de la devolución.
        origen = self.tmp / "origen-b1"
        (origen / "intern").mkdir(parents=True)
        (origen / "SKILL.md").write_text("nueva\n", encoding="utf-8")
        destino = self.tmp / "respaldos" / "poteto-mode"
        destino.mkdir(parents=True)
        (destino / "SKILL.md").write_text("de antes\n", encoding="utf-8")
        reemplazo_real = os.replace
        llamadas = []

        def reemplazo_que_falla_desde_la_segunda(fuente, meta, **kwargs):
            llamadas.append(1)
            if len(llamadas) == 2:
                raise OSError("replace final roto")
            if len(llamadas) == 3:
                raise OSError("devolución rota")
            return reemplazo_real(fuente, meta, **kwargs)

        with mock.patch.object(self.armador.os, "replace", reemplazo_que_falla_desde_la_segunda):
            with self.assertRaises(OSError) as atrapado:
                self.armador.respalda_carpeta(origen, destino)
        self.assertEqual(str(atrapado.exception), "replace final roto")
        apartados = [p for p in destino.parent.iterdir() if p.name.startswith(".viejo-")]
        self.assertEqual(len(apartados), 1)
        self.assertEqual((apartados[0] / "vieja" / "SKILL.md").read_bytes(), b"de antes\n")

    def test_two_reverts_in_a_row_do_not_invent_a_conflict(self):
        # C1a (R1 del veredicto r3): una edición del dueño fuera del bloque entre la gen 2
        # y la gen 3 que pasó por --leer no conflicta la segunda reversa.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/poteto-mode/SKILL.md": "poteto v2\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.write_bytes(meli.read_bytes() + LINEA_PROPIA)
        self.publicar("leer")
        self.armar_generacion(3, cambios={"skills/poteto-mode/SKILL.md": "poteto v3\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        codigo, primera = self.publicar("revertir")
        self.assertEqual(primera["agentes"]["meli"], "revertido")
        self.assertEqual((primera["conflictos"], codigo), (0, 0))
        self.assertIn(LINEA_PROPIA, meli.read_bytes())
        codigo, segunda = self.publicar("revertir")
        self.assertEqual(
            segunda["agentes"]["meli"], "revertido", "la segunda reversa inventó conflicto"
        )
        self.assertEqual((segunda["conflictos"], codigo), (0, 0))
        self.assertEqual(self.estado_del_home()["generacion"], 1)

    def test_an_agents_md_in_0640_keeps_its_mode_through_apply_and_revert(self):
        # C1b (R2 del veredicto r3): el modo del AGENTS.md sobrevive escribir y revertir.
        self.armar()
        meli = self.home / "workspaces" / "meli" / "AGENTS.md"
        meli.chmod(0o640)
        self.publicar("leer")
        self.publicar("aplicar")
        self.assertEqual(meli.stat().st_mode & 0o777, 0o640)
        self.publicar("revertir")
        self.assertEqual(meli.stat().st_mode & 0o777, 0o640)

    def test_an_agent_missing_from_the_revert_does_not_conflict_on_the_next_apply(self):
        # C1c (R3 del veredicto r3): un agente que falta de la lista durante la reversa
        # conserva su lugar en el estado; la siguiente --aplicar no lo ve como editado.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        solo_pers_y_main = self.tmp / "agents-sin-meli.json"
        restantes = [a for a in self.agentes if a["id"] != "meli"]
        solo_pers_y_main.write_text(json.dumps(restantes) + "\n", encoding="utf-8")
        self.publicar("revertir", solo_pers_y_main)
        codigo, aplicar = self.publicar("aplicar")
        self.assertEqual(aplicar["agentes"]["meli"], "igual")

    def test_the_revert_keeps_the_profiles_a_generation_did_not_change(self):
        # B1 del veredicto r1: una gen 2 con los mismos perfiles deja foto en 2/; la
        # reversa devuelve los bytes de gen 1 y no borra el archivo.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        destino = self.home / ".local" / "share" / "agent-work" / "perfiles.v1.json"
        foto = destino.read_bytes()
        self.armar_generacion(2, cambios={"skills/poteto-mode/SKILL.md": "poteto 2\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        huella = self.home / ".openclaw" / "sua-contexto" / "2" / "perfiles.v1.json"
        self.assertEqual(huella.read_bytes(), foto, "la gen 2 no dejó la foto de sus perfiles")
        self.publicar("revertir")
        self.assertTrue(destino.exists(), "la reversa de gen 2 borró perfiles.v1.json")
        self.assertEqual(destino.read_bytes(), foto)

    def test_reapplying_the_first_publication_and_reverting_removes_the_profiles(self):
        # B1 del veredicto r1: la marca de ausencia de la primera publicación sobrevive al
        # reintento de --aplicar, y la reversa quita el archivo.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        destino = self.home / ".local" / "share" / "agent-work" / "perfiles.v1.json"
        self.assertTrue(destino.exists())
        self.publicar("leer")
        self.publicar("aplicar")
        self.publicar("revertir")
        self.assertFalse(destino.exists())

    def test_the_revert_ignores_leftover_temp_folders_in_the_backups(self):
        # N1 del veredicto r1: los temporales .<nombre>.* que respalda_carpeta deja si la
        # matan a media copia no son skills; la reversa no los copia al home.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        basura = self.home / ".openclaw" / "sua-contexto" / "1" / "skills" / ".poteto-mode.xyz"
        (basura / "intern").mkdir(parents=True)
        (basura / "SKILL.md").write_text("copia a medias\n", encoding="utf-8")
        codigo, revertir = self.publicar("revertir")
        self.assertFalse((self.home / ".openclaw" / "skills" / ".poteto-mode.xyz").exists())

    def test_the_restore_of_a_dropped_skill_is_atomic_when_the_copy_fails(self):
        # B3 (Minor de CodeRabbit en #307): la restauración de una skill que salió del
        # manifiesto copia a un temporal hermano y entra con os.replace; una copia que
        # falla a medias no deja destino a medias y la segunda reversa la restaura.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_sin_skill(2, "principle-x")
        self.publicar("leer")
        self.publicar("aplicar")
        self.assertFalse((self.home / ".openclaw" / "skills" / "principle-x").exists())
        respaldo = self.home / ".openclaw" / "sua-contexto" / "2" / "skills" / "principle-x"
        self.assertTrue(respaldo.is_dir())
        (respaldo / "extra.md").write_bytes(b"otro archivo del respaldo\n")
        codigo, respuesta = self.revertir_con_copia_que_falla()
        self.assertEqual(codigo, 3, respuesta)
        destino = self.home / ".openclaw" / "skills" / "principle-x"
        self.assertFalse(destino.exists(), "quedó una restauración a medias")
        self.assertEqual(
            [
                p.name
                for p in destino.parent.iterdir()
                if p.name.startswith(".") and p.name != ".sua-contexto.json"
            ],
            [],
        )
        codigo, revertir = self.publicar("revertir")
        self.assertEqual((revertir["conflictos"], codigo), (0, 0))
        self.assertEqual(revertir["skills"]["principle-x"], "revertido")
        self.assertEqual(self.skill_del_home("principle-x").read_bytes(), b"principio de juguete\n")

    def test_a_failed_restore_of_a_managed_skill_keeps_the_published_one(self):
        # F4 (DeepSeek Low): la restauración de una skill administrada con respaldo es
        # atómica; una copia que falla a medias deja la skill publicada en su sitio y la
        # segunda reversa restaura sin conflicto.
        self.armar()
        self.publicar("leer")
        self.publicar("aplicar")
        self.armar_generacion(2, cambios={"skills/poteto-mode/SKILL.md": "poteto v2\n"})
        self.publicar("leer")
        self.publicar("aplicar")
        publicada = self.skill_del_home("poteto-mode").read_bytes()
        respaldo = self.home / ".openclaw" / "sua-contexto" / "2" / "skills" / "poteto-mode"
        self.assertTrue(respaldo.is_dir())
        codigo, respuesta = self.revertir_con_copia_que_falla()
        self.assertEqual(codigo, 3, respuesta)
        self.assertEqual(
            self.skill_del_home("poteto-mode").read_bytes(),
            publicada,
            "la skill publicada desapareció con la copia fallida",
        )
        codigo, revertir = self.publicar("revertir")
        self.assertEqual((revertir["conflictos"], codigo), (0, 0))
        self.assertEqual(revertir["skills"]["poteto-mode"], "revertido")
        self.assertEqual(self.skill_del_home("poteto-mode").read_bytes(), b"poteto de juguete\n")

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
                # C6: toda llamada ssh y scp lleva las opciones de no colgarse.
                for llamada in llamadas_ssh:
                    if not any("agents" in argumento for argumento in llamada):
                        continue
                    for opcion in self.armador.SSH_OPCIONES:
                        self.assertIn(opcion, llamada)
                llamadas_scp = self.llamadas(logs / "scp.log")
                self.assertTrue(
                    any(
                        any(arg.startswith("/tmp/") for arg in llamada)
                        and any(arg.startswith(f"{MINI}:/tmp/") for arg in llamada)
                        for llamada in llamadas_scp
                    )
                )
                for llamada in llamadas_scp:
                    for opcion in self.armador.SSH_OPCIONES:
                        self.assertIn(opcion, llamada)
                nombre = None
                for llamada in llamadas_ssh:
                    for arg in llamada:
                        coincide = re.fullmatch(r"/tmp/([^/]+)/publicar-contexto\.py", arg)
                        if coincide:
                            nombre = coincide.group(1)
                self.assertIsNotNone(nombre)
                # La llamada remota es exactamente la del contrato, con sus opciones y sin
                # timeout duro (C6): la Mini puede tardar lo que tarde la publicación.
                self.assertIn(
                    [
                        *self.armador.SSH_OPCIONES,
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

    def test_the_publisher_answers_a_line_of_json_when_ssh_expires(self):
        # C6 (DeepSeek F4): un ssh que se pasa del timeout contesta Rechazo (línea JSON,
        # salida 3) y no un traceback con el candado tomado.
        self.assertEqual(self.armador.TIMEOUT_AGENTES, 120)
        self.assertEqual(self.armador.TIMEOUT_SCP, 300)
        self.assertEqual(self.armador.TIMEOUT_BORRADO, 60)
        expirado = subprocess.TimeoutExpired(cmd="ssh", timeout=120)
        with mock.patch.object(self.armador.subprocess, "run", side_effect=expirado):
            with self.assertRaises(self.armador.Rechazo):
                self.armador.agentes_por_ssh(MINI)
            with self.assertRaises(self.armador.Rechazo):
                self.armador.listar_agentes(None)

    def test_the_mac_half_refuses_a_source_that_disagrees_with_the_manifest(self):
        # S4 del veredicto r1: la mitad Mac valida cada archivo de la fuente contra el
        # manifiesto y no copia nada si uno no coincide.
        binarios = self.tmp / "bin-s4"
        logs = self.tmp / "logs-s4"
        binarios.mkdir()
        logs.mkdir()
        shutil.copy(self.agents_json, logs / "agents.json")
        for nombre, texto in (("ssh", SSH_FALSO), ("scp", SCP_FALSO)):
            ruta = binarios / nombre
            ruta.write_text(texto, encoding="utf-8")
            ruta.chmod(0o755)
        contexto_dir = self.tmp / "checkout-s4" / "scripts" / "agent-work" / "contexto"
        contexto_dir.mkdir(parents=True)
        (contexto_dir / "poteto.v1.json").write_text(
            json.dumps(self.manifiesto, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        (contexto_dir / "generaciones.json").write_text(
            json.dumps({"1": self.manifiesto["digest"]}) + "\n", encoding="utf-8"
        )
        shutil.copy(contexto.PERFILES, contexto_dir / "perfiles.v1.json")
        # La fuente que el manifiesto nombra trae un archivo cuyo contenido no es el fijado:
        # el HOME falso redirige `fuente_del_paquete` a este árbol.
        mala = (
            self.tmp
            / "home-falso"
            / ".claude"
            / "plugins"
            / "cache"
            / "pstack-claude"
            / "pstack"
            / "0"
            / "skills"
            / "poteto-mode"
            / "SKILL.md"
        )
        mala.parent.mkdir(parents=True)
        mala.write_text("otro contenido\n", encoding="utf-8")
        resultado = subprocess.run(
            [
                sys.executable,
                "-I",
                str(MODULO),
                "--aplicar",
                "--mini",
                MINI,
                "--checkout",
                str(self.tmp / "checkout-s4"),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env={
                **os.environ,
                "HOME": str(self.tmp / "home-falso"),
                "PATH": str(binarios) + os.pathsep + os.environ["PATH"],
                "SUA_TEST_LOGS": str(logs),
            },
        )
        self.assertEqual(resultado.stderr, "")
        lineas = resultado.stdout.splitlines()
        self.assertEqual(len(lineas), 1)
        respuesta = json.loads(lineas[0])
        self.assertFalse(respuesta["ok"])
        self.assertIn("no coincide con el manifiesto", respuesta["error"])
        self.assertEqual(resultado.returncode, 3)
        self.assertFalse((logs / "scp.log").exists())

    def test_the_mac_half_removes_its_staging_folder_on_the_mini_after_the_copy(self):
        # L1 del veredicto r1: el scp no deja su carpeta en /tmp de la Mini; se borra por
        # ssh al final, también cuando la mitad Mini falla, y solo si el scp salió bien.
        binarios = self.tmp / "bin-l1"
        logs = self.tmp / "logs-l1"
        binarios.mkdir()
        logs.mkdir()
        shutil.copy(self.agents_json, logs / "agents.json")
        # Checkout de juguete con manifiesto sin archivos, para que armar no copie fuente.
        vacio = {**self.manifiesto, "files": []}
        vacio["digest"] = contexto.digest_de(vacio)
        contexto_dir = self.tmp / "checkout-vacio" / "scripts" / "agent-work" / "contexto"
        contexto_dir.mkdir(parents=True)
        (contexto_dir / "poteto.v1.json").write_text(
            json.dumps(vacio, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        (contexto_dir / "generaciones.json").write_text(
            json.dumps({"1": vacio["digest"]}) + "\n", encoding="utf-8"
        )
        shutil.copy(contexto.PERFILES, contexto_dir / "perfiles.v1.json")
        for salida, scp_falso in (("0", SCP_FALSO), ("4", SCP_FALSO), ("1", SCP_FALSO_ROTO)):
            with self.subTest(salida=salida):
                for nombre, texto in (("ssh", SSH_FALSO), ("scp", scp_falso)):
                    ruta = binarios / nombre
                    ruta.write_text(texto, encoding="utf-8")
                    ruta.chmod(0o755)
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
                        str(self.tmp / "checkout-vacio"),
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
                self.assertEqual(resultado.returncode, int(salida))
                llamadas_ssh = self.llamadas(logs / "ssh.log")
                nombre = None
                for llamada in llamadas_ssh:
                    for argumento in llamada:
                        coincide = re.fullmatch(
                            r"/tmp/(sua-contexto-[^/]+)/publicar-contexto\.py", argumento
                        )
                        if coincide:
                            nombre = coincide.group(1)
                if salida == "1":
                    # El scp falló: no hubo carpeta remota ni borrado.
                    self.assertIsNone(nombre)
                    for llamada in llamadas_ssh:
                        self.assertNotIn("rm", llamada)
                else:
                    self.assertIsNotNone(nombre)
                    self.assertIn(
                        [*self.armador.SSH_OPCIONES, MINI, "rm", "-rf", f"/tmp/{nombre}"],
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

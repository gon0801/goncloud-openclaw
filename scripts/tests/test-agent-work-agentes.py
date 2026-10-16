#!/usr/bin/env python3
"""SUA-04 (4.5): descubrir agentes contra una lista viva de fixture y sondear con una Mini falsa."""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import agentes  # noqa: E402

PERFILES = {
    "schema": "agent-work.perfiles.v1",
    "profiles": [
        {
            "id": "ingenieria",
            "routes": [
                {"host": "mini-native", "executor": "native", "agentId": "ingenieria"},
                {"host": "mini-native", "executor": "native", "agentId": "fantasma"},
            ],
        },
        {
            "id": "revision",
            "routes": [{"host": "mini-native", "executor": "native", "agentId": "reviewer"}],
        },
    ],
    "agents": [{"agentId": "pers", "status": "sin-perfil"}],
}


def filas(agentes_json):
    return agentes.descubrir(PERFILES, agentes_json, requesters=("main",))


class Descubrir(unittest.TestCase):
    def test_estados(self):
        viva = [
            {"id": "main"},
            {"id": "ingenieria"},
            {"id": "reviewer"},
            {"id": "pers"},
            {"id": "nuevo"},
        ]
        por_id = {fila.get("agentId"): fila for fila in filas(viva)}
        self.assertEqual(por_id["ingenieria"]["estado"], "con-perfil")
        self.assertEqual(por_id["pers"]["estado"], "sin-perfil")
        self.assertEqual(por_id["nuevo"]["estado"], "alta-sin-registrar")
        # Un solicitante no es trabajador ni alta.
        self.assertNotIn("main", por_id)
        incompletos = [f for f in filas(viva) if f["estado"] == "perfil-incompleto"]
        self.assertEqual(
            [(f["perfil"], f["agentId"]) for f in incompletos], [("ingenieria", "fantasma")]
        )

    def test_un_solicitante_que_tambien_es_trabajador_se_clasifica(self):
        # B1: requesters trae también a trabajadores (ingenieria, reviewer...). El salto de
        # solicitante vale solo para quien no tiene perfil ni está en agents (hoy main).
        viva = [{"id": "main"}, {"id": "ingenieria"}]
        filas = agentes.descubrir(PERFILES, viva, requesters=("main", "ingenieria", "reviewer"))
        por_id = {f["agentId"]: f for f in filas if "perfil" not in f}
        self.assertEqual(por_id["ingenieria"]["estado"], "con-perfil")
        self.assertEqual(por_id["reviewer"]["estado"], "retirado")
        self.assertNotIn("main", por_id)

    def test_retirado(self):
        viva = [{"id": "main"}, {"id": "ingenieria"}]
        # La fila del agente (sin "perfil") dice retirado; la de su perfil dice perfil-incompleto.
        por_id = {fila["agentId"]: fila for fila in filas(viva) if "perfil" not in fila}
        self.assertEqual(por_id["reviewer"]["estado"], "retirado")
        self.assertEqual(por_id["pers"]["estado"], "retirado")
        self.assertIn(
            ("revision", "reviewer"),
            [
                (f["perfil"], f["agentId"])
                for f in filas(viva)
                if f["estado"] == "perfil-incompleto"
            ],
        )


class FakeMini:
    """Un ssh y un openclaw falsos: la tarea aparece cuando el turno a main corre."""

    def __init__(
        self,
        *,
        tarea=True,
        registrada=False,
        marcador=True,
        entregas=0,
        memoria_cambia=False,
        spawn=False,
        concurrente=False,
        turno_cortado=False,
        reporta=True,
        en_texto=False,
    ):
        self.tarea, self.registrada, self.con_marcador = tarea, registrada, marcador
        self.entregas, self.memoria_cambia, self.spawn = entregas, memoria_cambia, spawn
        self.concurrente, self.turno_cortado = concurrente, turno_cortado
        self.en_texto = en_texto
        self.reporta = reporta
        self.tarea_id = "87b98ddf-12b4-466f-94f1-632a6c688ff5" if en_texto else "t-sonda"
        self.artefacto_ruta = "/w/ingenieria/631c9409-7488-44ca-9c87-5d4ce810c4d2.txt"
        self.artefacto_concurrente = "/w/ingenieria/aaaaaaaa-1111-4222-8333-444444444444.txt"
        self.borrados = []
        self.borrado_pedidos = []
        self.artefacto_falta = False
        self.llamadas = []
        self.memoria = "aaa  memory/notas.md\n"
        self.turno_corrido = False

    def __call__(self, argv, entrada=None, timeout=None):
        self.llamadas.append((argv, entrada))
        texto = " ".join(argv)
        if "-c" in argv:
            # El ssh real une el argv y lo corre el shell de login de la Mini, que es
            # zsh: un -c sin citar se rompe ahí aunque aquí parezca un argv (B1 de G4b-r3).
            shell = shutil.which("zsh") or shutil.which("sh")
            if shell:
                sintaxis = subprocess.run(
                    [shell, "-n", "-c", texto], capture_output=True, text=True
                )
                if sintaxis.returncode != 0:
                    return 1, "", sintaxis.stderr.strip()
        if "agents list" in texto:
            return (
                0,
                json.dumps(
                    [
                        {"id": "main", "workspace": "/w/main"},
                        {"id": "ingenieria", "workspace": "/w/ingenieria"},
                    ]
                ),
                "",
            )
        if "find memory" in texto:
            return 0, self.memoria, ""
        if "cat >" in texto:
            return 0, "", ""
        if "agent --agent main" in texto:
            if self.turno_cortado:
                return 1, "", "ssh no contestó en 900s"
            self.turno_corrido = True
            if self.memoria_cambia:
                self.memoria = "bbb  memory/notas.md\n"
            # Sin taskId reportado (F8): un main que no declara su tarea gestionada.
            if self.en_texto:
                return (
                    0,
                    (
                        "managed_tasks_submit creó la tarea, taskId: "
                        "87b98ddf-12b4-466f-94f1-632a6c688ff5, admitida"
                    ),
                    "",
                )
            return 0, json.dumps({"taskId": "t-sonda"} if self.reporta else {}), ""
        if entrada and "BORRAR_ARTEFACTO" in entrada:
            ruta = json.loads(argv[2].strip("'"))["ruta"]
            self.borrado_pedidos.append(ruta)
            if ruta.startswith("/w/ingenieria/") and ".." not in ruta and ";" not in ruta:
                self.borrados.append(ruta)
                return 0, json.dumps({"borrado": True, "causa": None}), ""
            return 0, json.dumps({"borrado": False, "causa": "fuera del workspace"}), ""
        if entrada and "LEER_ARTEFACTO" in entrada:
            ruta = json.loads(argv[2].strip("'"))["ruta"]
            if self.artefacto_falta and ruta == self.artefacto_ruta:
                return 1, "", "No such file or directory"
            if ruta == self.artefacto_concurrente:
                return 0, "trabajo real de otro\n", ""
            return 0, "SONDA-7\n" if self.con_marcador else "otro texto\n", ""
        if argv[1] == "-":
            # F6: el código llega por stdin y el pedido como argumento ya citado. Sin
            # stdin válido el fake no contesta: un regreso a -c lo cantan los flujos.
            if not entrada or "managed_tasks" not in entrada:
                raise AssertionError("el ayudante debe llegar por stdin")
            tareas = []
            if self.turno_corrido and self.tarea:
                tareas = [
                    {
                        "taskId": self.tarea_id,
                        "kind": "agent",
                        "agentId": "ingenieria",
                        "estado": "registered" if self.registrada else "result-recorded",
                        "resultado": json.dumps(
                            {
                                "kind": "produced",
                                "artifactRef": self.artefacto_ruta,
                                "digest": "sha256:x",
                                "observedRevision": {},
                            }
                        ),
                    }
                ]
            if self.turno_corrido and self.concurrente:
                # La concurrente es más nueva: va primero, como en el orden real.
                tareas.insert(
                    0,
                    {
                        "taskId": "t-real",
                        "kind": "agent",
                        "agentId": "ingenieria",
                        "estado": "result-recorded",
                        "resultado": json.dumps(
                            {
                                "kind": "produced",
                                "artifactRef": self.artefacto_concurrente,
                                "digest": "sha256:y",
                                "observedRevision": {},
                            }
                        ),
                    },
                )
            pedido = json.loads(argv[2].strip("'"))  # el pedido viaja citado como argumento (F6)
            sesiones = ["agent:ingenieria:managed:ajena"]
            if self.turno_corrido:
                sesiones.append(f"agent:ingenieria:managed:{self.tarea_id}")
            if self.turno_corrido and self.concurrente:
                sesiones.append("agent:ingenieria:managed:t-real")
            # Fiel al ayudante real: las hijas se filtran con el taskId que el pedido
            # trae; sin él, la lista de hijas vuelve vacía y solo queda sesionesAgente.
            reportada = pedido.get("tareaReportada")
            return (
                0,
                json.dumps(
                    {
                        "tareas": tareas,
                        "entregas": self.entregas if self.turno_corrido else 0,
                        "sesionesHijas": [s for s in sesiones if reportada and reportada in s],
                        "sesionesAgente": sesiones,
                        "spawn": self.spawn,
                    }
                ),
                "",
            )
        return 0, "", ""

    def corridas(self, pedazo):
        return [argv for argv, _ in self.llamadas if pedazo in " ".join(argv)]


def sondear_con(fake, tope=0.0):
    reloj = {"t": 0.0}

    def dormir(_):
        reloj["t"] += 10.0

    return agentes.sondear(
        "ingenieria",
        mini="u@h",
        correr=fake,
        perfiles=PERFILES,
        marca="7",
        dormir=dormir,
        reloj=lambda: reloj["t"],
        tope=tope,
    )


class Sondear(unittest.TestCase):
    def test_camino_feliz_y_limpieza(self):
        fake = FakeMini()
        fila = sondear_con(fake)
        self.assertEqual(
            (
                fila["ok"],
                fila["taskId"],
                fila["estado"],
                fila["marcador"],
                fila["entregas"],
                fila["memoriaIgual"],
            ),
            (True, "t-sonda", "result-recorded", True, 0, True),
        )
        # Siempre limpia: el mensaje en /tmp y las dos sesiones.
        self.assertTrue(
            any("rm" in argv and any("sua04-sonda" in a for a in argv) for argv, _ in fake.llamadas)
        )
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertTrue(any("agent:main:sua04-sonda-ingenieria-7" in b for b in borradas))
        self.assertTrue(any("agent:ingenieria:managed:t-sonda" in b for b in borradas))

    def test_no_borra_sesiones_ajenas_ni_toma_la_tarea_concurrente(self):
        # F1: la sonda solo toca lo suyo: ni la sesión gestionada ajena ni la tarea real
        # concurrente al mismo agente.
        fake = FakeMini(concurrente=True)
        fila = sondear_con(fake)
        self.assertEqual((fila["ok"], fila["taskId"]), (True, "t-sonda"))
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertFalse(any("managed:ajena" in b for b in borradas), borradas)
        self.assertTrue(any("managed:t-sonda" in b for b in borradas), borradas)

    def test_turno_cortado_conserva_la_sesion_de_main(self):
        fake = FakeMini(turno_cortado=True)
        fila = sondear_con(fake)
        self.assertEqual(
            fila["causa"], "turno cortado, sesión conservada: agent:main:sua04-sonda-ingenieria-7"
        )
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertFalse(any("agent:main:sua04-sonda" in b for b in borradas), borradas)
        self.assertTrue(any("rm" in argv for argv, _ in fake.llamadas))

    def test_la_tarea_que_llego_sin_resultado_dice_su_task_id(self):
        # 4.5b: main reporta el taskId en su texto y la tarea queda sin resultado: la
        # causa es esa, no "main no mandó".
        fake = FakeMini(registrada=True, en_texto=True)
        fila = sondear_con(fake)
        self.assertTrue(fila["causa"].startswith("la tarea llegó (87b98ddf-"))
        self.assertTrue(fila["causa"].endswith("pero el agente no reportó resultado"))
        self.assertEqual(fila["taskId"], "87b98ddf-12b4-466f-94f1-632a6c688ff5")

    def test_el_artefacto_se_borra_y_el_ajeno_no(self):
        fake = FakeMini()
        fila = sondear_con(fake)
        self.assertTrue(fila["ok"], fila)
        # F1 de G4b-r4: el borrado va por el ayudante (stdin), nunca con rm y la ruta suelta.
        self.assertEqual(fake.borrados, [fake.artefacto_ruta])
        rms = [" ".join(argv) for argv, _ in fake.llamadas if argv and argv[0] == "rm"]
        self.assertFalse(any(fake.artefacto_ruta in r for r in rms), rms)
        # Uno ajeno: fuera del workspace no se borra aunque traiga uuid.
        fake2 = FakeMini()
        fake2.artefacto_ruta = "/etc/631c9409-7488-44ca-9c87-5d4ce810c4d2.txt"
        fila2 = sondear_con(fake2)
        self.assertTrue(fila2["ok"], fila2)
        self.assertEqual(fake2.borrados, [])

    def test_lectura_fallida_no_borra_nada(self):
        # F1/F4 de G4b-r4: si la lectura falló, no se pide ningún borrado.
        fake = FakeMini()
        fake.artefacto_falta = True
        fila = sondear_con(fake)
        self.assertFalse(fila["ok"])
        self.assertEqual(fake.borrado_pedidos, [])

    def test_sin_marcador_no_borra_nada(self):
        fake = FakeMini(marcador=False)
        fila = sondear_con(fake)
        self.assertFalse(fila["ok"])
        self.assertEqual(fake.borrado_pedidos, [])

    def test_sin_task_id_toma_la_tarea_cuyo_artefacto_trae_el_marcador(self):
        # F3 de G4b-r4: sin taskId reportado no se toma la primera nueva: la
        # concurrente más nueva no es de la sonda y no se toca.
        fake = FakeMini(reporta=False, concurrente=True)
        fila = sondear_con(fake)
        self.assertEqual((fila["ok"], fila["taskId"]), (True, "t-sonda"))
        self.assertEqual(fake.borrados, [fake.artefacto_ruta])
        self.assertNotIn(fake.artefacto_concurrente, fake.borrado_pedidos)
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertFalse(any("managed:t-real" in b for b in borradas), borradas)
        self.assertTrue(any("managed:t-sonda" in b for b in borradas), borradas)

    def test_sin_task_id_y_ninguna_con_marcador_sigue_esperando_y_lo_dice(self):
        fake = FakeMini(reporta=False, marcador=False, concurrente=True)
        fila = sondear_con(fake)
        self.assertFalse(fila["ok"])
        self.assertIn("ninguna tarea nueva", fila["causa"])
        self.assertEqual(fake.borrado_pedidos, [])

    def test_el_artefacto_que_no_se_puede_leer_lo_dice(self):
        fake = FakeMini()
        fake.artefacto_falta = True
        fila = sondear_con(fake)
        self.assertFalse(fila["ok"])
        self.assertIn("no se pudo leer", fila["causa"])

    def test_main_que_usa_sessions_spawn(self):
        fila = sondear_con(FakeMini(tarea=False, spawn=True))
        self.assertEqual(
            (fila["ok"], fila["causa"]),
            (False, "main usó sessions_spawn en vez de la tarea gestionada"),
        )

    def test_tarea_que_no_llega(self):
        fila = sondear_con(FakeMini(registrada=True))
        self.assertEqual(
            (fila["ok"], fila["causa"]),
            (False, "la tarea llegó (t-sonda) pero el agente no reportó resultado"),
        )

    def test_una_entrega_hacia_david_falla(self):
        fila = sondear_con(FakeMini(entregas=1))
        self.assertEqual(
            (fila["ok"], fila["entregas"], fila["causa"]), (False, 1, "hubo entregas hacia David")
        )

    def test_memoria_cambiada_falla(self):
        fila = sondear_con(FakeMini(memoria_cambia=True))
        self.assertEqual(
            (fila["ok"], fila["memoriaIgual"], fila["causa"]),
            (False, False, "memory/ cambió durante la sonda"),
        )

    def test_sonda_de_un_agente_sin_perfil_no_manda_perfil(self):
        # F2 de G4b-r4: sondear manda --perfil solo si el agente tiene uno.
        fake = FakeMini()
        fila = agentes.sondear(
            "ingenieria",
            mini="u@h",
            correr=fake,
            perfiles={"profiles": [], "agents": []},
            marca="7",
            dormir=lambda _: None,
            reloj=lambda: 0.0,
            tope=0.0,
        )
        self.assertTrue(fila["ok"], fila)
        mensaje = next(
            entrada for argv, entrada in fake.llamadas if entrada and "Sonda de" in entrada
        )
        self.assertIn("brief.py --agente ingenieria", mensaje)
        self.assertNotIn("--perfil", mensaje)

    def test_la_hija_se_borra_cuando_main_no_reporta_task_id(self):
        # F8: la tarea se reconoció por su resultado, no por lo que main reportó;
        # la sesión hija de ESA tarea también es de la sonda y debe irse.
        fake = FakeMini(reporta=False)
        fila = sondear_con(fake)
        self.assertEqual((fila["ok"], fila["taskId"]), (True, "t-sonda"))
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertTrue(any("agent:ingenieria:managed:t-sonda" in b for b in borradas), borradas)
        self.assertFalse(any("managed:ajena" in b for b in borradas), borradas)


SSH_FALSO = """#!/bin/sh
# ssh de juguete con la semántica del real: une el argv con espacios y lo corre
# con sh -c, como el shell remoto de la Mini.
sh -c "$*"
"""


class ConexionReal(unittest.TestCase):
    """La lectura y la foto contra un HOME de juguete y un ssh local que replica al
    real (F6): el ssh une el argv con espacios y el shell remoto lo vuelve a partir,
    así que estas pruebas reproducen el machaqueo sin salir de la Mac.
    """

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.home = self.tmp / "home"
        self.ws = self.home / "w" / "ingenieria"
        (self.ws / "memory").mkdir(parents=True)
        (self.ws / "memory" / "notas.md").write_text("nota de ingeniería\n", encoding="utf-8")
        self.crear_base(
            self.home / ".openclaw" / "state" / "openclaw.sqlite",
            [
                "create table managed_tasks (task_id text, assignment_json text,"
                " result_json text, created_at int)"
            ],
            [
                (
                    "insert into managed_tasks values (?, ?, ?, ?)",
                    (
                        "t-1",
                        json.dumps({"target": {"kind": "agent", "agentId": "ingenieria"}}),
                        json.dumps("SONDA-7"),
                        1,
                    ),
                )
            ],
        )
        self.base_main = (
            self.home / ".openclaw" / "agents" / "main" / "agent" / "openclaw-agent.sqlite"
        )
        self.crear_base(
            self.base_main,
            ["create table conversation_deliveries (id int, source_session_key text)"],
        )
        self.crear_base(
            self.home / ".openclaw" / "agents" / "ingenieria" / "agent" / "openclaw-agent.sqlite",
            [
                "create table conversation_deliveries (id int, source_session_key text)",
                "create table session_windows (session_key text, session_id text)",
                "create table transcript_events (session_id text, seq int, event_json text)",
            ],
            [
                (
                    "insert into session_windows values (?, ?)",
                    ("agent:ingenieria:managed:t-1", "s-1"),
                )
            ],
        )
        self.guion = self.tmp / "ssh-falso"
        self.guion.write_text(SSH_FALSO, encoding="utf-8")
        self.guion.chmod(0o755)

    def crear_base(self, ruta, ordenes=(), filas=()):
        ruta.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(ruta)
        try:
            for orden in ordenes:
                db.execute(orden)
            for orden, fila in filas:
                db.execute(orden, fila)
            db.commit()
        finally:
            db.close()

    def correr(self, argv, entrada=None, timeout=None):
        hecho = subprocess.run(
            [str(self.guion), *argv],
            input=entrada,
            capture_output=True,
            text=True,
            timeout=timeout or agentes.TIMEOUT_SSH,
            env={**os.environ, "HOME": str(self.home)},
        )
        return hecho.returncode, hecho.stdout, hecho.stderr

    def test_la_lectura_y_la_foto_sobreviven_a_un_ssh_de_verdad(self):
        estado = agentes._estado_remoto(
            self.correr, "agent:main:sua04-sonda-ingenieria-7", "ingenieria", "SONDA-7"
        )
        tarea = estado["tareas"][0]
        self.assertEqual(
            (tarea["taskId"], tarea["kind"], tarea["agentId"], tarea["estado"]),
            ("t-1", "agent", "ingenieria", "result-recorded"),
        )
        self.assertIn("SONDA-7", tarea["resultado"])
        foto = [agentes._foto_memoria(self.correr, str(self.ws)) for _ in range(2)]
        self.assertEqual(foto[0], foto[1])
        self.assertIn("memory/notas.md", foto[0])

    def test_las_entregas_se_leen_de_la_base_de_cada_agente(self):
        # F7: la entrega vive en la base del agente main, no en la base de estado.
        db = sqlite3.connect(self.base_main)
        try:
            db.execute(
                "insert into conversation_deliveries values (?, ?)",
                (1, "agent:main:sua04-sonda-ingenieria-7"),
            )
            db.commit()
        finally:
            db.close()
        estado = agentes._estado_remoto(
            self.correr, "agent:main:sua04-sonda-ingenieria-7", "ingenieria", "SONDA-7"
        )
        self.assertEqual(estado["entregas"], 1)

    def test_sin_tabla_de_entregas_falla_con_causa(self):
        # F7: sin la tabla de entregas, fallar con su causa; un 0 en silencio es un
        # "sin entregas hacia David" falso.
        self.base_main.unlink()
        self.crear_base(self.base_main)
        with self.assertRaises(ValueError) as atrapado:
            agentes._estado_remoto(
                self.correr, "agent:main:sua04-sonda-ingenieria-7", "ingenieria", "SONDA-7"
            )
        self.assertIn("conversation_deliveries", str(atrapado.exception))

    def test_el_borrado_del_artefacto_acota_en_la_mini(self):
        # F1 de G4b-r4: el ayudante de borrado resuelve la ruta en la Mini.
        uuid = "631c9409-7488-44ca-9c87-5d4ce810c4d2"
        # Con espacios: se borra bien.
        con_espacios = self.ws / f"{uuid} con espacios.txt"
        con_espacios.write_text("SONDA-7\n", encoding="utf-8")
        hecho = agentes._borrar_artefacto(self.correr, str(con_espacios), str(self.ws))
        self.assertTrue(hecho["borrado"], hecho)
        self.assertFalse(con_espacios.exists())
        # Con "..": la ruta resuelta sale del workspace y no se borra.
        fuera = self.home / "w" / "fuera"
        fuera.mkdir(parents=True, exist_ok=True)
        victima = fuera / f"{uuid}.txt"
        victima.write_text("no tocar\n", encoding="utf-8")
        hecho = agentes._borrar_artefacto(
            self.correr, str(self.ws / ".." / "fuera" / f"{uuid}.txt"), str(self.ws)
        )
        self.assertFalse(hecho["borrado"], hecho)
        self.assertTrue(victima.exists())
        # Un enlace dentro del workspace: no se borra ni él ni su destino.
        destino = self.ws / f"{uuid}-destino.txt"
        destino.write_text("destino\n", encoding="utf-8")
        enlace = self.ws / f"{uuid}-enlace.txt"
        enlace.symlink_to(destino)
        hecho = agentes._borrar_artefacto(self.correr, str(enlace), str(self.ws))
        self.assertFalse(hecho["borrado"], hecho)
        self.assertTrue(enlace.is_symlink())
        self.assertTrue(destino.exists())
        # Una carpeta con nombre de artefacto: no se borra.
        carpeta = self.ws / f"{uuid}-carpeta"
        carpeta.mkdir()
        hecho = agentes._borrar_artefacto(self.correr, str(carpeta), str(self.ws))
        self.assertFalse(hecho["borrado"], hecho)
        self.assertTrue(carpeta.is_dir())

    def test_el_borrado_con_punto_y_coma_no_ejecuta_nada(self):
        # F1 de G4b-r4: "; touch" en la ruta es un dato, no un comando.
        uuid = "631c9409-7488-44ca-9c87-5d4ce810c4d2"
        tocado = self.tmp / "tocado.txt"
        ruta = f"{self.ws}/{uuid}.txt; touch {tocado}"
        hecho = agentes._borrar_artefacto(self.correr, ruta, str(self.ws))
        self.assertFalse(hecho["borrado"], hecho)
        self.assertFalse(tocado.exists())


class DescubrirCli(unittest.TestCase):
    def test_agentes_json_malformado_da_la_linea_json_y_exit_3(self):
        # F11 de #318: un --agentes-json que no es la lista no revienta con TypeError.
        import subprocess

        with tempfile.TemporaryDirectory() as tmp:
            malo = Path(tmp) / "agentes.json"
            malo.write_text('{"id": "esto no es una lista"}')
            hecho = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/agent-work/agentes.py"),
                    "descubrir",
                    "--agentes-json",
                    str(malo),
                ],
                capture_output=True,
                text=True,
            )
        self.assertEqual(hecho.returncode, 3, hecho.stderr)
        self.assertIn("la lista de agentes no tiene la forma esperada", hecho.stdout)
        self.assertNotIn("Traceback", hecho.stderr)


if __name__ == "__main__":
    unittest.main()

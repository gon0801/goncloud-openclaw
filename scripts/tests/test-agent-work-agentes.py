#!/usr/bin/env python3
"""SUA-04 (4.5): descubrir agentes contra una lista viva de fixture y sondear con una Mini falsa."""

import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import agentes  # noqa: E402

PERFILES = {
    "schema": "agent-work.perfiles.v1",
    "profiles": [
        {"id": "ingenieria", "routes": [{"host": "mini-native", "executor": "native", "agentId": "ingenieria"},
                                        {"host": "mini-native", "executor": "native", "agentId": "fantasma"}]},
        {"id": "revision", "routes": [{"host": "mini-native", "executor": "native", "agentId": "reviewer"}]},
    ],
    "agents": [{"agentId": "pers", "status": "sin-perfil"}],
}


def filas(agentes_json):
    return agentes.descubrir(PERFILES, agentes_json, requesters=("main",))


class Descubrir(unittest.TestCase):
    def test_estados(self):
        viva = [{"id": "main"}, {"id": "ingenieria"}, {"id": "reviewer"}, {"id": "pers"}, {"id": "nuevo"}]
        por_id = {fila.get("agentId"): fila for fila in filas(viva)}
        self.assertEqual(por_id["ingenieria"]["estado"], "con-perfil")
        self.assertEqual(por_id["pers"]["estado"], "sin-perfil")
        self.assertEqual(por_id["nuevo"]["estado"], "alta-sin-registrar")
        # Un solicitante no es trabajador ni alta.
        self.assertNotIn("main", por_id)
        incompletos = [f for f in filas(viva) if f["estado"] == "perfil-incompleto"]
        self.assertEqual([(f["perfil"], f["agentId"]) for f in incompletos], [("ingenieria", "fantasma")])

    def test_retirado(self):
        viva = [{"id": "main"}, {"id": "ingenieria"}]
        # La fila del agente (sin "perfil") dice retirado; la de su perfil dice perfil-incompleto.
        por_id = {fila["agentId"]: fila for fila in filas(viva) if "perfil" not in fila}
        self.assertEqual(por_id["reviewer"]["estado"], "retirado")
        self.assertEqual(por_id["pers"]["estado"], "retirado")
        self.assertIn(("revision", "reviewer"),
                      [(f["perfil"], f["agentId"]) for f in filas(viva) if f["estado"] == "perfil-incompleto"])


class FakeMini:
    """Un ssh y un openclaw falsos: la tarea aparece cuando el turno a main corre."""

    def __init__(self, *, tarea=True, registrada=False, marcador=True, entregas=0,
                 memoria_cambia=False, spawn=False):
        self.tarea, self.registrada, self.con_marcador = tarea, registrada, marcador
        self.entregas, self.memoria_cambia, self.spawn = entregas, memoria_cambia, spawn
        self.llamadas = []
        self.memoria = "aaa  memory/notas.md\n"
        self.turno_corrido = False

    def __call__(self, argv, entrada=None):
        self.llamadas.append((argv, entrada))
        texto = " ".join(argv)
        if "agents list" in texto:
            return 0, json.dumps([{"id": "main", "workspace": "/w/main"},
                                  {"id": "ingenieria", "workspace": "/w/ingenieria"}]), ""
        if "find memory" in texto:
            return 0, self.memoria, ""
        if "cat >" in texto:
            return 0, "", ""
        if "agent --agent main" in texto:
            self.turno_corrido = True
            if self.memoria_cambia:
                self.memoria = "bbb  memory/notas.md\n"
            return 0, "{}", ""
        if "python3" in texto and "-c" in argv:
            tareas = []
            if self.turno_corrido and self.tarea:
                tareas = [{"taskId": "t-sonda", "kind": "agent", "agentId": "ingenieria",
                           "estado": "registered" if self.registrada else "result-recorded",
                           "resultado": "SONDA-7" if self.con_marcador else "otro texto"}]
            return 0, json.dumps({"tareas": tareas, "entregas": self.entregas if self.turno_corrido else 0,
                                  "sesionesHijas": ["agent:ingenieria:managed:t-sonda"] if self.turno_corrido else [],
                                  "spawn": self.spawn}), ""
        return 0, "", ""

    def corridas(self, pedazo):
        return [argv for argv, _ in self.llamadas if pedazo in " ".join(argv)]


def sondear_con(fake, tope=0.0):
    reloj = {"t": 0.0}

    def dormir(_):
        reloj["t"] += 10.0
    return agentes.sondear("ingenieria", mini="u@h", correr=fake, perfiles=PERFILES, marca="7",
                           dormir=dormir, reloj=lambda: reloj["t"], tope=tope)


class Sondear(unittest.TestCase):
    def test_camino_feliz_y_limpieza(self):
        fake = FakeMini()
        fila = sondear_con(fake)
        self.assertEqual((fila["ok"], fila["taskId"], fila["estado"], fila["marcador"],
                          fila["entregas"], fila["memoriaIgual"]),
                         (True, "t-sonda", "result-recorded", True, 0, True))
        # Siempre limpia: el mensaje en /tmp y las dos sesiones.
        self.assertTrue(any("rm" in argv and any("sua04-sonda" in a for a in argv) for argv, _ in fake.llamadas))
        borradas = [" ".join(argv) for argv in fake.corridas("sessions delete")]
        self.assertTrue(any("agent:main:sua04-sonda-ingenieria-7" in b for b in borradas))
        self.assertTrue(any("agent:ingenieria:managed:t-sonda" in b for b in borradas))

    def test_main_que_usa_sessions_spawn(self):
        fila = sondear_con(FakeMini(tarea=False, spawn=True))
        self.assertEqual((fila["ok"], fila["causa"]),
                         (False, "main usó sessions_spawn en vez de la tarea gestionada"))

    def test_tarea_que_no_llega(self):
        fila = sondear_con(FakeMini(registrada=True))
        self.assertEqual((fila["ok"], fila["causa"]),
                         (False, "la tarea no llegó a result-recorded en el tope"))

    def test_una_entrega_hacia_david_falla(self):
        fila = sondear_con(FakeMini(entregas=1))
        self.assertEqual((fila["ok"], fila["entregas"], fila["causa"]), (False, 1, "hubo entregas hacia David"))

    def test_memoria_cambiada_falla(self):
        fila = sondear_con(FakeMini(memoria_cambia=True))
        self.assertEqual((fila["ok"], fila["memoriaIgual"], fila["causa"]),
                         (False, False, "memory/ cambió durante la sonda"))


if __name__ == "__main__":
    unittest.main()

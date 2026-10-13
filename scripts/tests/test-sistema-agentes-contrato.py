#!/usr/bin/env python3
"""El contrato sistema-agentes.v1 contra sus fixtures.

`casos.json` dice el veredicto literal de cada fixture. Un fixture inválido trae un solo
defecto, así que su veredicto es exactamente un hallazgo con su regla y su ruta.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from sistema_agentes.contrato import (  # noqa: E402
    Hallazgo,
    cargar_json,
    efecto_admisible,
    nombre_de_campo_prohibido,
    transicion_permitida,
    validar,
    validar_plan,
)

FIXTURES = ROOT / "scripts/tests/fixtures/sistema-agentes"
PLAN = ROOT / "docs/superpowers/plans/2026-10-05-sistema-agentes-unificado.md"
FUERA_DE_CASOS = {"casos.json", "manifiesto-ensayos.json", "efectos.json", "transiciones.json"}
META = "sistema-agentes.meta.v1"
ESQUEMAS_DEL_CONTRATO = [
    "sistema-agentes.meta.v1",
    "sistema-agentes.autoridad.v1",
    "sistema-agentes.unidad.v1",
    "sistema-agentes.resultado.v1",
    "sistema-agentes.evidencia.v1",
    "sistema-agentes.control.v1",
    "sistema-agentes.flota.v1",
    "sistema-agentes.excepcion.v1",
    "sistema-agentes.proyeccion.v1",
]
ESTADOS_DE_UNIDAD = [
    "pending",
    "ready",
    "admitted",
    "running",
    "reported",
    "accepted",
    "failed",
    "cancelled",
]
BLOQUES_SUA = {
    "SUA-00",
    "SUA-01",
    "SUA-02",
    "SUA-03",
    "SUA-04",
    "SUA-05",
    "SUA-06",
    "SUA-07",
    "SUA-08",
    "SUA-09O",
    "SUA-09H",
    "SUA-10O",
    "SUA-10H",
    "SUA-11",
}
NOMBRES = [
    ("key", "nombre exacto key"),
    ("TOKEN", "nombre exacto token"),
    ("Secret", "nombre exacto secret"),
    ("session", "nombre exacto session"),
    ("signature", "nombre exacto signature"),
    ("credential", "nombre exacto credential"),
    ("Authorization", "nombre exacto authorization"),
    ("cookie", "nombre exacto cookie"),
    ("JWT", "nombre exacto jwt"),
    ("password", "nombre exacto password"),
    ("passwd", "nombre exacto passwd"),
    ("apiKey", "nombre exacto apiKey"),
    ("APIKEY", "nombre exacto apiKey"),
    ("idToken", "nombre exacto idToken"),
    ("accessToken", "nombre exacto accessToken"),
    ("authToken", "nombre exacto authToken"),
    ("clientSecret", "nombre exacto clientSecret"),
    ("privateKey", "nombre exacto privateKey"),
    ("keyMaterial", "nombre exacto keyMaterial"),
    ("refreshToken", "nombre exacto refreshToken"),
    ("bearerToken", "nombre exacto bearerToken"),
    ("appSecret", "nombre exacto appSecret"),
    ("secretValue", "nombre exacto secretValue"),
    ("rawSecret", "nombre exacto rawSecret"),
    ("secretInput", "nombre exacto secretInput"),
    ("apiToken", "nombre exacto apiToken"),
    ("idempotency_key", "sufijo _key"),
    ("task_key", "sufijo _key"),
    ("session_key", "sufijo _key"),
    ("x-key", "sufijo -key"),
    ("goal_token", "sufijo _token"),
    ("client-secret", "sufijo -secret"),
    ("DB_PASSWORD", "sufijo _password"),
    ("root-passwd", "sufijo -passwd"),
    ("idempotencyKey", None),
    ("taskKey", None),
    ("sessionRef", None),
    ("tokenBudget", None),
    ("rootId", None),
    ("unitId", None),
    ("planDigest", None),
    ("controlEpoch", None),
    ("commandId", None),
    ("requesterId", None),
    ("authorityRef", None),
    ("evidenceId", None),
    ("effectId", None),
    ("attemptId", None),
    ("exceptionId", None),
    ("monkey", None),
    ("token_count", None),
]

CASOS = cargar_json(FIXTURES / "casos.json")
ENSAYOS = cargar_json(FIXTURES / "manifiesto-ensayos.json")


def casos(veredicto):
    for caso in CASOS:
        if caso["veredicto"] == veredicto:
            validadores = [validar, validar_plan] if caso["esquema"] == META else [validar]
            yield caso, cargar_json(FIXTURES / caso["archivo"]), validadores


def reglas_y_rutas(hallazgos):
    return [(hallazgo.regla, hallazgo.ruta) for hallazgo in hallazgos]


class Fixtures(unittest.TestCase):
    maxDiff = None

    def test_cada_fixture_valido_pasa_y_con_un_literal_ajeno_se_rechaza(self):
        ajeno = "sistema-agentes.otro.v9"
        for caso, documento, validadores in casos("valido"):
            for validador in validadores:
                with self.subTest(archivo=caso["archivo"], validador=validador.__name__):
                    self.assertEqual(documento["schema"], caso["esquema"])
                    self.assertEqual(validador(documento), [])
                    self.assertEqual(
                        validador({**documento, "schema": ajeno}),
                        [Hallazgo("schema", "schema", f"literal no admitido: '{ajeno}'")],
                    )

    def test_cada_fixture_invalido_da_un_solo_hallazgo_con_su_regla_y_su_ruta(self):
        for caso, documento, validadores in casos("invalido"):
            for validador in validadores:
                with self.subTest(archivo=caso["archivo"], validador=validador.__name__):
                    self.assertEqual(
                        reglas_y_rutas(validador(documento)), [(caso["regla"], caso["ruta"])]
                    )

    def test_cada_esquema_del_contrato_tiene_fixture_valido_e_invalido(self):
        veredictos = {}
        for caso in CASOS:
            veredictos.setdefault(caso["esquema"], set()).add(caso["veredicto"])
        self.assertEqual(
            veredictos, {literal: {"valido", "invalido"} for literal in ESQUEMAS_DEL_CONTRATO}
        )

    def test_no_hay_fixtures_huerfanos(self):
        en_disco = {
            ruta.relative_to(FIXTURES).as_posix()
            for ruta in FIXTURES.rglob("*.json")
            if ruta.name not in FUERA_DE_CASOS
        }
        self.assertEqual(en_disco, {caso["archivo"] for caso in CASOS})


class Plan(unittest.TestCase):
    maxDiff = None

    def test_el_ciclo_se_nombra_en_el_detalle(self):
        self.assertEqual(
            validar_plan(cargar_json(FIXTURES / "planes/invalidos/ciclo.json")),
            [Hallazgo("ciclo", "plan.units[1].dependsOn[0]", "unit-a -> unit-b -> unit-a")],
        )

    def test_un_plan_con_todos_los_defectos_los_reporta_en_el_orden_del_contrato(self):
        meta = cargar_json(FIXTURES / "planes/validos/pedido-compuesto.json")
        a, b, c = meta["plan"]["units"]
        criterio = {"criterionId": "crit-d-1", "text": "Otro criterio.", "verifier": "ci"}
        meta["plan"]["units"].append({**a, "criteria": [criterio]})
        c["dependsOn"].append("unit-x")
        a["dependsOn"] = ["unit-c"]
        b["criteria"] = []
        b["goal_token"] = "valor-sintetico"
        self.assertEqual(
            reglas_y_rutas(validar_plan(meta)),
            [
                ("id-duplicado", "plan.units[3].unitId"),
                ("dependencia-faltante", "plan.units[2].dependsOn[2]"),
                ("ciclo", "plan.units[2].dependsOn[0]"),
                ("criterio-faltante", "plan.units[1].criteria"),
                ("campo-prohibido", "plan.units[1].goal_token"),
            ],
        )

    def test_una_forma_rota_va_primero_y_calla_las_reglas_de_plan(self):
        meta = cargar_json(FIXTURES / "planes/invalidos/ciclo.json")
        meta["createdAt"] = "ayer"
        meta["api_token"] = "valor-sintetico"
        self.assertEqual(
            reglas_y_rutas(validar_plan(meta)),
            [("schema", "createdAt"), ("campo-prohibido", "api_token")],
        )

    def test_validar_plan_rechaza_un_documento_valido_de_otro_esquema(self):
        autoridad = cargar_json(FIXTURES / "autoridad/valida.json")
        self.assertEqual(validar(autoridad), [])
        self.assertEqual(
            validar_plan(autoridad),
            [Hallazgo("schema", "schema", "literal no admitido: 'sistema-agentes.autoridad.v1'")],
        )

    def test_un_documento_torcido_se_rechaza_sin_reventar(self):
        resultado = cargar_json(FIXTURES / "resultados/review-approved.json")
        flota = cargar_json(FIXTURES / "flota/modelo-exacto.json")
        torcidos = [
            ("el documento es una lista", ["sistema-agentes.meta.v1"], [("schema", "schema")]),
            (
                "el literal es una lista",
                {"schema": ["sistema-agentes.meta.v1"]},
                [("schema", "schema")],
            ),
            (
                "el hermano que elige la variante es una lista",
                {**resultado, "resultContract": ["review.v1"]},
                [("schema", "resultContract")],
            ),
            ("el modelo no trae id", {**flota, "model": {}}, [("schema", "model.id")]),
        ]
        for nombre, documento, esperado in torcidos:
            with self.subTest(caso=nombre):
                self.assertEqual(reglas_y_rutas(validar(documento)), esperado)


class Autoridad(unittest.TestCase):
    def test_cada_efecto_es_admisible_o_da_su_primera_razon(self):
        efectos = cargar_json(FIXTURES / "autoridad/efectos.json")
        self.assertEqual(
            {fila["esperado"] for fila in efectos},
            {
                "admisible",
                "autoridad-vencida",
                "accion-fuera-de-autoridad",
                "repo-fuera-de-autoridad",
                "destino-fuera-de-autoridad",
                "modo-fuera-de-autoridad",
            },
        )
        for fila in efectos:
            with self.subTest(efecto=fila["nombre"]):
                autoridad = cargar_json(FIXTURES / fila["autoridad"])
                esperado = None if fila["esperado"] == "admisible" else fila["esperado"]
                self.assertEqual(
                    efecto_admisible(autoridad, fila["efecto"], fila["ahora"]), esperado
                )


class Unidad(unittest.TestCase):
    def test_cada_par_de_estados_tiene_su_transicion_permitida_o_negada(self):
        transiciones = cargar_json(FIXTURES / "unidad/transiciones.json")
        self.assertEqual(
            [(fila["desde"], fila["hasta"]) for fila in transiciones],
            [(desde, hasta) for desde in ESTADOS_DE_UNIDAD for hasta in ESTADOS_DE_UNIDAD],
        )
        for fila in transiciones:
            with self.subTest(desde=fila["desde"], hasta=fila["hasta"]):
                self.assertIs(transicion_permitida(fila["desde"], fila["hasta"]), fila["permitida"])

    def test_un_estado_que_el_contrato_no_conoce_no_transita(self):
        self.assertIs(transicion_permitida("waiting", "ready"), False)
        self.assertIs(transicion_permitida("pending", "ready"), True)


class Nombres(unittest.TestCase):
    def test_cada_nombre_pasa_o_dice_por_que_esta_prohibido(self):
        for nombre, esperado in NOMBRES:
            with self.subTest(nombre=nombre):
                self.assertEqual(nombre_de_campo_prohibido(nombre), esperado)


class Ensayos(unittest.TestCase):
    maxDiff = None

    def test_el_manifiesto_trae_los_24_ensayos_especificados_con_bloque_y_fixtures_reales(self):
        self.assertEqual([ensayo["id"] for ensayo in ENSAYOS], [f"I{n:02d}" for n in range(1, 25)])
        self.assertEqual({ensayo["estado"] for ensayo in ENSAYOS}, {"especificado"})
        self.assertEqual({ensayo["bloque"] for ensayo in ENSAYOS} - BLOQUES_SUA, set())
        citados = {fixture for ensayo in ENSAYOS for fixture in ensayo["fixtures"]}
        self.assertEqual({f for f in citados if not (FIXTURES / f).is_file()}, set())

    def test_cada_ensayo_copia_el_texto_de_la_tabla_del_plan(self):
        fila = re.compile(r"^\| (I\d\d) \| (.*?)(?:\s*<!--.*?-->)?\s*\|$", re.MULTILINE)
        self.assertEqual(
            {ensayo["id"]: ensayo["distingue"] for ensayo in ENSAYOS},
            dict(fila.findall(PLAN.read_text(encoding="utf-8"))),
        )

    def test_cada_caso_esta_citado_por_su_ensayo(self):
        citados = {ensayo["id"]: ensayo["fixtures"] for ensayo in ENSAYOS}
        self.assertEqual(
            [caso["archivo"] for caso in CASOS if caso["archivo"] not in citados[caso["ensayo"]]],
            [],
        )


if __name__ == "__main__":
    unittest.main()

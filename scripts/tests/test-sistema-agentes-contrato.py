#!/usr/bin/env python3
"""El contrato sistema-agentes.v1 contra sus fixtures.

`casos.json` dice el veredicto literal de cada fixture. Un fixture inválido trae un solo
defecto, así que su veredicto es exactamente un hallazgo con su regla y su ruta.
"""

from __future__ import annotations

import os
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
POLITICA_DE_CALIDAD = ROOT / "docs/evidence/agent-work/politica-calidad.json"
FUERA_DE_CASOS = {
    "casos.json",
    "manifiesto-ensayos.json",
    "efectos.json",
    "transiciones.json",
    "clases.json",
}
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

    def test_una_version_de_calidad_fuera_de_la_tabla_es_desconocida(self):
        meta = cargar_json(FIXTURES / "planes/validos/pedido-chico.json")
        meta["qualityPolicy"]["version"] = "otra-cualidad.v9"
        (hallazgo,) = validar_plan(meta)
        self.assertEqual(
            (hallazgo.regla, hallazgo.ruta), ("quality-policy-unknown", "qualityPolicy.version")
        )
        self.assertIn("otra-cualidad.v9", hallazgo.detalle)

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


class PoliticaDeCalidad(unittest.TestCase):
    """`politica-calidad.json` es la tabla versionada que consulta el contrato (SUA-05, 4.1)."""

    maxDiff = None

    def setUp(self):
        self.politica = cargar_json(POLITICA_DE_CALIDAD)
        self.activa = self.politica["versiones"][self.politica["activa"]]

    def test_el_esquema_es_el_de_la_politica_de_calidad(self):
        self.assertEqual(self.politica["schema"], "agent-work.calidad.v1")

    def test_la_activa_es_una_de_las_versiones(self):
        self.assertIn(self.politica["activa"], self.politica["versiones"])

    def test_la_version_activa_trae_su_decision_con_by_on_ref_y_quote(self):
        self.assertEqual(set(self.activa["decision"]), {"by", "on", "ref", "quote"})

    def test_la_decision_de_la_activa_no_es_la_de_otra_version(self):
        par_de_la_activa = (self.activa["decision"]["on"], self.activa["decision"]["quote"])
        otras = {
            (version["decision"]["on"], version["decision"]["quote"])
            for nombre, version in self.politica["versiones"].items()
            if nombre != self.politica["activa"]
        }
        self.assertNotIn(par_de_la_activa, otras)

    def test_la_version_activa_lleva_el_tope_de_la_regla_4(self):
        self.assertEqual(self.activa["roundsPerImplementer"], 5)
        self.assertEqual(self.activa["relays"], 1)
        self.assertIs(self.activa["segundoModelo"], False)


@unittest.skipUnless(
    os.environ.get("AGENT_WORK_RUNTIME_SOURCE"), "pide AGENT_WORK_RUNTIME_SOURCE con R"
)
class PoliticaDeCalidadEnR(unittest.TestCase):
    """La tabla `ROOT_QUALITY_POLICIES` de R y `politica-calidad.json` dicen lo mismo."""

    maxDiff = None

    def test_las_versiones_y_sus_numeros_son_los_de_r(self):
        decidir = (
            Path(os.environ["AGENT_WORK_RUNTIME_SOURCE"])
            / "src/agents/tasks/managed-root.decide.ts"
        ).read_text(encoding="utf-8")
        bloque = re.search(r"ROOT_QUALITY_POLICIES[^{]*\{(.*?)\n\};", decidir, re.DOTALL)
        self.assertIsNotNone(
            bloque, "no se encontró ROOT_QUALITY_POLICIES en managed-root.decide.ts"
        )
        entradas = re.findall(
            r'version:\s*"([^"]+)",\s*roundsPerImplementer:\s*(\d+),\s*relays:\s*(\d+)',
            bloque.group(1),
        )
        self.assertTrue(entradas, "la tabla de R no expuso ninguna entrada")
        en_r = {version: (int(rondas), int(relevos)) for version, rondas, relevos in entradas}
        politica = cargar_json(POLITICA_DE_CALIDAD)
        en_g = {
            version: (datos["roundsPerImplementer"], datos["relays"])
            for version, datos in politica["versiones"].items()
        }
        self.assertEqual(en_r, en_g)


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


TIPOS_DE_EXCEPCION = [
    "SIN_REVISOR",
    "SIN_CUOTA",
    "AUTH_VENCIDA",
    "CI_ROJO",
    "BOT_CALLADO",
    "CONFIRMAR_PLAN",
    "NECESITA_DAVID",
    "BLOQUEANTE_REPETIDO",
    "DEPLOY_FALLO",
    "CIERRE_ROJO",
    "INESPERADO",
    "EVIDENCIA_INCIERTA",
    "CAPACIDAD_INCIERTA",
]
VOCABULARIO_DE_OPCIONES = {
    "seguir",
    "relevo",
    "cancelar",
    "listo",
    "omitir",
    "si",
    "autorizar",
    "aceptar",
    "rechazar",
    "conciliar",
}


class ClasesDeExcepcion(unittest.TestCase):
    """`excepcion/clases.json` es la tabla que R copia en `ROOT_EXCEPTION_CLASSES` (SUA-02, 4.5)."""

    maxDiff = None

    def setUp(self):
        self.clases = cargar_json(FIXTURES / "excepcion/clases.json")
        self.base = cargar_json(FIXTURES / "excepcion/necesita-david.json")

    def documento(self, tipo, opciones, respuesta=None):
        return {
            **self.base,
            "type": tipo,
            "options": [{"optionId": opcion, "text": opcion} for opcion in opciones],
            "response": respuesta,
        }

    def test_las_clases_son_las_trece_del_contrato_en_su_orden(self):
        self.assertEqual([clase["type"] for clase in self.clases], TIPOS_DE_EXCEPCION)

    def test_cada_clase_ofrece_opciones_del_vocabulario_sin_repetir(self):
        for clase in self.clases:
            with self.subTest(tipo=clase["type"]):
                self.assertEqual(set(clase), {"type", "options"})
                self.assertTrue(clase["options"])
                self.assertEqual(len(set(clase["options"])), len(clase["options"]))
                self.assertLessEqual(set(clase["options"]), VOCABULARIO_DE_OPCIONES)

    def test_ninguna_clase_conserva_una_opcion_que_cobertura_prohibe(self):
        opciones = {clase["type"]: clase["options"] for clase in self.clases}
        self.assertNotIn("hecho", opciones["CIERRE_ROJO"])
        self.assertNotIn("si", opciones["BLOQUEANTE_REPETIDO"])
        self.assertEqual(opciones["CIERRE_ROJO"], ["seguir", "cancelar"])
        self.assertEqual(opciones["BLOQUEANTE_REPETIDO"], ["omitir", "cancelar"])

    def test_cada_clase_con_sus_opciones_es_un_documento_que_el_contrato_acepta(self):
        for clase in self.clases:
            with self.subTest(tipo=clase["type"]):
                documento = self.documento(clase["type"], clase["options"])
                self.assertEqual(validar(documento), [])
                respondido = self.documento(
                    clase["type"],
                    clase["options"],
                    {
                        "optionId": clase["options"][-1],
                        "by": ["telegram", "owner-01"],
                        "at": "2026-10-14T12:00:00Z",
                    },
                )
                self.assertEqual(validar(respondido), [])

    def test_cada_excepcion_valida_de_los_fixtures_ofrece_opciones_de_su_clase(self):
        opciones = {clase["type"]: set(clase["options"]) for clase in self.clases}
        validas = [
            caso["archivo"]
            for caso in cargar_json(FIXTURES / "casos.json")
            if caso["esquema"] == "sistema-agentes.excepcion.v1" and caso["veredicto"] == "valido"
        ]
        self.assertEqual(
            validas, ["excepcion/necesita-david.json", "excepcion/necesita-david-respondida.json"]
        )
        for archivo in validas:
            with self.subTest(archivo=archivo):
                documento = cargar_json(FIXTURES / archivo)
                ofrecidas = {opcion["optionId"] for opcion in documento["options"]}
                self.assertLessEqual(ofrecidas, opciones[documento["type"]])

    def test_un_tipo_fuera_de_la_tabla_no_es_del_contrato(self):
        hallazgos = validar(self.documento("PREGUNTA_LIBRE", ["seguir"]))
        self.assertEqual([(h.regla, h.ruta) for h in hallazgos], [("schema", "type")])


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


INVENTARIO = ROOT / "docs/evidence/sistema-agentes-unificado/SUA-00-inventario.json"
COLUMNAS = ("fuente", "instalado", "aceptadoEnVivo")
CAPACIDADES = {"passed", "failed", "unknown"}


class Inventario(unittest.TestCase):
    """El inventario de SUA-00 separa fuente, instalado y aceptado en vivo, y un unknown trae
    su razón o su comando."""

    maxDiff = None

    def setUp(self):
        self.inventario = cargar_json(INVENTARIO)

    def test_el_esquema_y_las_capacidades_son_los_del_documento(self):
        self.assertEqual(self.inventario["schema"], "sua-inventario.v1")
        self.assertEqual(set(self.inventario["capacidades"]), CAPACIDADES)
        self.assertEqual(tuple(self.inventario["columnas"]), COLUMNAS)

    def test_cada_ruta_trae_las_tres_columnas_con_capacidad_del_enum(self):
        fuera = [
            (ruta["id"], columna, ruta.get(columna, {}).get("capacidad"))
            for ruta in self.inventario["rutas"]
            for columna in COLUMNAS
            if ruta.get(columna, {}).get("capacidad") not in CAPACIDADES
        ]
        self.assertEqual(fuera, [])

    def test_un_unknown_dice_su_razon_o_el_comando_que_lo_contesta(self):
        mudos = [
            (ruta["id"], columna)
            for ruta in self.inventario["rutas"]
            for columna in COLUMNAS
            if ruta[columna]["capacidad"] == "unknown"
            and not (ruta[columna].get("razon") or ruta[columna].get("comando"))
        ]
        self.assertEqual(mudos, [])
        self.assertEqual([u["id"] for u in self.inventario["unknowns"] if not u.get("comando")], [])

    def test_los_ids_no_se_repiten_y_las_piezas_dicen_su_estado_tras_b22(self):
        for lista in ("rutas", "piezas", "unknowns"):
            ids = [fila["id"] for fila in self.inventario[lista]]
            self.assertEqual(sorted(set(ids)), sorted(ids), lista)
        self.assertEqual(
            [p["id"] for p in self.inventario["piezas"] if not p.get("estadoTrasB22")], []
        )

    def test_las_piezas_que_pide_el_plan_estan(self):
        pedidas = {
            "managedTasks.host.incident",
            "record_incident",
            "flush_incidents",
            "CLI_ROUTES",
            "coverage.json.modelWakes",
            "main_cli_loop",
            "detect_silent_failures",
            "managedTasks.host.cancellation",
            "cutover_live.py",
            "ProgressPublisher",
        }
        self.assertEqual(pedidas - {p["id"] for p in self.inventario["piezas"]}, set())


if __name__ == "__main__":
    unittest.main()

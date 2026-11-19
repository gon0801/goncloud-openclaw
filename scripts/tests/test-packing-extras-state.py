#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GATE = ROOT / "scripts/mac/packing_extras_state.py"
DIGEST = ROOT / "scripts/gonserver/send_sales_digest.sh"
ORDER_A = "701-1111111-1111111"
ORDER_B = "701-2222222-2222222"
HASH_A = "a" * 64


def order_block(order_id, model="Modelo A", personalized=False):
    prefix = "<b>PERSONALIZADA</b>\n" if personalized else ""
    return (
        f"{prefix}<b>Pedido:</b> {order_id}\n"
        f"<b>Producto:</b> Arras\n<b>Modelo:</b> {model}\n<b>SKU:</b> SKU-A"
    )


def receipt(receipt_id, content):
    return {"recibo": receipt_id, "pedidos": content}


def complete_state():
    content = {ORDER_A: HASH_A}
    return {
        "schema_version": 2,
        "fuentes": {
            "seller_central": "completa",
            "seller_flex": "completa",
            "mercado_libre": "completa",
        },
        "deduplicacion": "completa",
        "lote": {
            ORDER_A: {"huella": HASH_A, "fuente": "amazon", "personalizada": False},
        },
        "entregas": {
            "correo": {
                "prevista": True,
                "estado": "verificado",
                "recibos": [receipt("gmail:123", content)],
                "intento": {},
            },
            "telegram_gon": {
                "prevista": True,
                "estado": "verificado",
                "recibos": [receipt("100", content)],
                "intento": {},
            },
            "telegram_isabel": {
                "prevista": True,
                "estado": "verificado",
                "recibos": [receipt("101", content)],
                "intento": {},
            },
            "personalizadas": {
                "prevista": False,
                "estado": "no_prevista",
                "recibos": [],
                "intento": {},
            },
        },
        "artefactos": {"amazon": "escrito", "meli": "escrito"},
    }


class PackingExtrasStateTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.directory = Path(self.tempdir.name)
        self.path = self.directory / "estado.json"
        self.amazon = self.directory / "amazon.html"
        self.meli = self.directory / "meli.html"
        self.meli.write_text("", encoding="utf-8")
        self.write(complete_state())

    def tearDown(self):
        self.tempdir.cleanup()

    def write(self, state):
        self.path.write_text(json.dumps(state), encoding="utf-8")

    def write_amazon(self, *blocks):
        self.amazon.write_text("\n\n".join(blocks) + "\n", encoding="utf-8")

    def run_gate(self, *args):
        return subprocess.run(
            [sys.executable, str(GATE), *map(str, args)],
            capture_output=True,
            text=True,
            check=False,
        )

    def payload(self, result):
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"salida no JSON rc={result.returncode}: {result.stdout!r} {result.stderr!r}")

    def assert_incomplete(self, result, missing):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        payload = self.payload(result)
        self.assertIs(payload["corte_completo"], False)
        self.assertEqual(payload["estado"], "FALLO_EXPLICITO")
        self.assertIn(missing, payload["faltantes"])

    def mark_sources_complete(self):
        for source in ("seller_central", "seller_flex", "mercado_libre"):
            result = self.run_gate("marcar", self.path, "fuente", source, "completa")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate("marcar", self.path, "deduplicacion", "deduplicacion", "completa")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def register_batch(self):
        result = self.run_gate("registrar-lote", self.path, self.amazon, self.meli)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.payload(result)

    def deliver(self, name, receipt_id):
        result = self.run_gate("marcar", self.path, "entrega", name, "en_curso")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate("marcar", self.path, "entrega", name, "verificado", receipt_id)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cierre_completo(self):
        result = self.run_gate("cerrar", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.payload(result),
            {"estado": "CORTE_COMPLETO", "corte_completo": True, "faltantes": []},
        )

    def test_cierre_rechaza_cada_etapa_incompleta_sin_mutar_estado(self):
        cases = []
        for source in ("seller_central", "seller_flex", "mercado_libre"):
            state = complete_state()
            state["fuentes"][source] = "pendiente"
            cases.append((f"fuentes.{source}", state))
        state = complete_state()
        state["deduplicacion"] = "pendiente"
        cases.append(("deduplicacion", state))
        state = complete_state()
        state["lote"] = None
        cases.append(("lote", state))
        state = complete_state()
        state["entregas"]["telegram_isabel"]["estado"] = "fallido"
        cases.append(("entregas.telegram_isabel", state))
        for artifact in ("amazon", "meli"):
            state = complete_state()
            state["artefactos"][artifact] = "pendiente"
            cases.append((f"artefactos.{artifact}", state))

        for missing, state in cases:
            with self.subTest(missing=missing):
                self.write(state)
                before = self.path.read_bytes()
                self.assert_incomplete(self.run_gate("cerrar", self.path), missing)
                self.assertEqual(self.path.read_bytes(), before)

    def test_plan_reintenta_solo_entregas_sin_recibo_del_mismo_lote(self):
        state = complete_state()
        state["entregas"]["telegram_isabel"] = {
            "prevista": True,
            "estado": "fallido",
            "recibos": [],
            "intento": {},
        }
        state["artefactos"] = {"amazon": "pendiente", "meli": "pendiente"}
        self.write(state)
        result = self.run_gate("plan", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.payload(result),
            {
                "estado": "REINTENTO_PERMITIDO",
                "corte_completo": False,
                "entregas_pendientes": ["telegram_isabel"],
                "pedidos_pendientes": {"telegram_isabel": [ORDER_A]},
                "telegram_chats_pendientes": [2],
                "telegram_chats_omitidos": [1],
            },
        )

    def test_plan_exige_reconciliar_una_entrega_en_curso(self):
        state = complete_state()
        state["entregas"]["telegram_gon"]["estado"] = "en_curso"
        state["entregas"]["telegram_gon"]["intento"] = {ORDER_A: HASH_A}
        self.write(state)
        self.assert_incomplete(
            self.run_gate("plan", self.path),
            "entregas.telegram_gon:reconciliar",
        )

    def test_plan_no_permite_entregar_con_fuente_incompleta(self):
        state = complete_state()
        state["fuentes"]["mercado_libre"] = "error"
        self.write(state)
        self.assert_incomplete(self.run_gate("plan", self.path), "fuentes.mercado_libre")

    def test_marcar_recibo_hace_avanzar_el_estado_real(self):
        state = complete_state()
        state["entregas"]["telegram_isabel"] = {
            "prevista": True,
            "estado": "fallido",
            "recibos": [],
            "intento": {},
        }
        self.write(state)
        result = self.run_gate("marcar", self.path, "entrega", "telegram_isabel", "en_curso")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_incomplete(
            self.run_gate("plan", self.path),
            "entregas.telegram_isabel:reconciliar",
        )
        result = self.run_gate("marcar", self.path, "entrega", "telegram_isabel", "verificado", "102")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stored = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(stored["entregas"]["telegram_isabel"]["recibos"][-1]["recibo"], "102")
        self.assertEqual(
            stored["entregas"]["telegram_isabel"]["recibos"][-1]["pedidos"],
            {ORDER_A: HASH_A},
        )
        result = self.run_gate("cerrar", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIs(self.payload(result)["corte_completo"], True)

    def test_flujo_real_desde_inicializacion_hasta_cierre(self):
        self.path.unlink()
        result = self.run_gate("inicializar", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_incomplete(self.run_gate("cerrar", self.path), "fuentes.seller_central")
        self.mark_sources_complete()
        self.write_amazon(order_block(ORDER_A))
        self.assertEqual(self.register_batch()["pedidos"], [ORDER_A])
        for name, receipt_id in (("correo", "gmail:123"), ("telegram_gon", "100"), ("telegram_isabel", "101")):
            self.deliver(name, receipt_id)
        for artifact in ("amazon", "meli"):
            result = self.run_gate("marcar", self.path, "artefacto", artifact, "escrito")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate("cerrar", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIs(self.payload(result)["corte_completo"], True)

    def test_reintento_entrega_solo_pedidos_nuevos_y_no_cierra_antes(self):
        self.path.unlink()
        self.assertEqual(self.run_gate("inicializar", self.path).returncode, 0)
        self.mark_sources_complete()
        self.write_amazon(order_block(ORDER_A))
        self.register_batch()
        self.deliver("correo", "gmail:lote-A")
        self.deliver("telegram_gon", "tg:lote-A")
        result = self.run_gate("marcar", self.path, "entrega", "telegram_isabel", "en_curso")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate("marcar", self.path, "entrega", "telegram_isabel", "fallido")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first_plan = self.payload(self.run_gate("plan", self.path))
        self.assertEqual(first_plan["entregas_pendientes"], ["telegram_isabel"])
        self.assertEqual(first_plan["telegram_chats_omitidos"], [1])

        self.write_amazon(order_block(ORDER_A), order_block(ORDER_B, "Modelo B"))
        self.assertEqual(self.register_batch()["pedidos"], [ORDER_A, ORDER_B])
        second_plan = self.payload(self.run_gate("plan", self.path))
        self.assertEqual(
            second_plan,
            {
                "estado": "REINTENTO_PERMITIDO",
                "corte_completo": False,
                "entregas_pendientes": ["correo", "telegram_gon", "telegram_isabel"],
                "pedidos_pendientes": {
                    "correo": [ORDER_B],
                    "telegram_gon": [ORDER_B],
                    "telegram_isabel": [ORDER_A, ORDER_B],
                },
                "telegram_chats_pendientes": [1, 2],
                "telegram_chats_omitidos": [],
            },
        )

        self.deliver("telegram_isabel", "tg:lote-A+B")
        for artifact in ("amazon", "meli"):
            self.assertEqual(
                self.run_gate("marcar", self.path, "artefacto", artifact, "escrito").returncode,
                0,
            )
        early_close = self.run_gate("cerrar", self.path)
        self.assert_incomplete(early_close, "entregas.correo:pedidos")
        self.assert_incomplete(early_close, "entregas.telegram_gon:pedidos")
        self.assertEqual(
            self.payload(early_close)["pedidos_pendientes"],
            {"correo": [ORDER_B], "telegram_gon": [ORDER_B]},
        )

        self.deliver("correo", "gmail:solo-B")
        self.deliver("telegram_gon", "tg:solo-B")
        final_close = self.run_gate("cerrar", self.path)
        self.assertEqual(final_close.returncode, 0, final_close.stdout + final_close.stderr)
        stored = json.loads(self.path.read_text(encoding="utf-8"))
        receipts = stored["entregas"]["telegram_gon"]["recibos"]
        self.assertEqual([item["recibo"] for item in receipts], ["tg:lote-A", "tg:solo-B"])
        self.assertEqual([list(item["pedidos"]) for item in receipts], [[ORDER_A], [ORDER_B]])

    def test_personalizadas_vinculan_cada_recibo_a_un_solo_pedido(self):
        self.path.unlink()
        self.assertEqual(self.run_gate("inicializar", self.path).returncode, 0)
        self.mark_sources_complete()
        self.write_amazon(
            order_block(ORDER_A, personalized=True),
            order_block(ORDER_B, "Modelo B", personalized=True),
        )
        self.register_batch()
        for name, receipt_id in (
            ("correo", "gmail:A+B"),
            ("telegram_gon", "tg:Gon:A+B"),
            ("telegram_isabel", "tg:Isabel:A+B"),
        ):
            self.deliver(name, receipt_id)

        result = self.run_gate("marcar", self.path, "entrega", "personalizadas", "en_curso")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("exige un pedido", self.payload(result)["error"])

        result = self.run_gate(
            "marcar", self.path, "entrega", "personalizadas", "en_curso", ORDER_A
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate(
            "marcar",
            self.path,
            "entrega",
            "personalizadas",
            "verificado",
            "A:Gon;A:Isabel;A:Jorge",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stored = json.loads(self.path.read_text(encoding="utf-8"))
        receipt_a = stored["entregas"]["personalizadas"]["recibos"][-1]
        self.assertEqual(list(receipt_a["pedidos"]), [ORDER_A])

        for artifact in ("amazon", "meli"):
            self.assertEqual(
                self.run_gate("marcar", self.path, "artefacto", artifact, "escrito").returncode,
                0,
            )
        early_close = self.run_gate("cerrar", self.path)
        self.assert_incomplete(early_close, "entregas.personalizadas:pedidos")
        self.assertEqual(
            self.payload(early_close)["pedidos_pendientes"],
            {"personalizadas": [ORDER_B]},
        )
        plan = self.payload(self.run_gate("plan", self.path))
        self.assertEqual(plan["entregas_pendientes"], ["personalizadas"])
        self.assertEqual(plan["pedidos_pendientes"], {"personalizadas": [ORDER_B]})

        result = self.run_gate(
            "marcar", self.path, "entrega", "personalizadas", "en_curso", ORDER_B
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.run_gate(
            "marcar",
            self.path,
            "entrega",
            "personalizadas",
            "verificado",
            "B:Gon;B:Isabel;B:Jorge",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        final_close = self.run_gate("cerrar", self.path)
        self.assertEqual(final_close.returncode, 0, final_close.stdout + final_close.stderr)
        stored = json.loads(self.path.read_text(encoding="utf-8"))
        receipts = stored["entregas"]["personalizadas"]["recibos"]
        self.assertEqual([list(item["pedidos"]) for item in receipts], [[ORDER_A], [ORDER_B]])

    def test_cambio_de_contenido_invalida_el_recibo_aunque_el_id_sea_el_mismo(self):
        self.write_amazon(order_block(ORDER_A, "Modelo corregido"))
        self.register_batch()
        result = self.payload(self.run_gate("plan", self.path))
        self.assertEqual(result["pedidos_pendientes"]["correo"], [ORDER_A])
        self.assertEqual(result["pedidos_pendientes"]["telegram_gon"], [ORDER_A])
        self.assertEqual(result["telegram_chats_omitidos"], [])

    def test_entrega_interrumpida_no_cierra_y_reintenta_solo_el_destino_faltante(self):
        self.path.unlink()
        self.assertEqual(self.run_gate("inicializar", self.path).returncode, 0)
        self.mark_sources_complete()
        self.amazon.write_text("", encoding="utf-8")
        self.meli.write_text(order_block(ORDER_A), encoding="utf-8")
        self.register_batch()

        fake_curl = self.directory / "curl"
        fake_curl.write_text(
            "#!/bin/sh\n"
            'for arg in "$@"; do\n'
            '  case "$arg" in chat_id=11111) mid=100;; chat_id=22222) mid=101;; esac\n'
            'done\n'
            'test -n "$mid" || exit 1\n'
            "printf '{\"ok\":true,\"result\":{\"message_id\":%s}}' \"$mid\"\n",
            encoding="utf-8",
        )
        fake_curl.chmod(0o700)
        fake_env = self.directory / "telegram.env"
        fake_env.write_text(
            "TELEGRAM_SALES_BOT_TOKEN=DUMMYTOKEN\nTELEGRAM_CHAT_ID=11111\nTELEGRAM_CHAT_ID_2=22222\n",
            encoding="utf-8",
        )

        def send_digest(chat_index, content):
            return subprocess.run(
                ["bash", str(DIGEST), str(content)],
                env={
                    "PATH": f"{self.directory}:{Path(sys.executable).parent}:{os.defpath}",
                    "TG_ENV": str(fake_env),
                    "TG_API_HOST": "127.0.0.1:1",
                    "TG_SOLO_CHATS": str(chat_index),
                },
                capture_output=True,
                text=True,
                check=False,
            )

        def deliver_digest(name, chat_index, mid):
            result = self.run_gate("marcar", self.path, "entrega", name, "en_curso")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = send_digest(chat_index, self.meli)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(f"DIGEST_OK chat#{chat_index} mid={mid}", result.stdout.splitlines())
            result = self.run_gate("marcar", self.path, "entrega", name, "verificado", mid)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        deliver_digest("telegram_gon", 1, "100")
        result = send_digest(2, self.directory / "diferencial-aun-no-escrito.html")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(result.stdout.startswith("ERR_NO_FILE "), result.stdout)

        for artifact in ("amazon", "meli"):
            result = self.run_gate("marcar", self.path, "artefacto", artifact, "escrito")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        result = self.run_gate("cerrar", self.path)
        self.assert_incomplete(result, "entregas.telegram_isabel:pedidos")
        self.assertEqual(self.payload(result)["pedidos_pendientes"], {"telegram_isabel": [ORDER_A]})
        plan = self.payload(self.run_gate("plan", self.path))
        self.assertEqual(plan["telegram_chats_pendientes"], [2])
        self.assertEqual(plan["telegram_chats_omitidos"], [1])

        deliver_digest("telegram_isabel", 2, "101")
        result = self.run_gate("cerrar", self.path)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.payload(result),
            {"estado": "CORTE_COMPLETO", "corte_completo": True, "faltantes": []},
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)

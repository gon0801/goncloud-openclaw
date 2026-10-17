#!/usr/bin/env python3
"""SUA-04 (4.8): avisar.py manda el mensaje con el openclaw falso que registra el argv."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import avisar  # noqa: E402
import modelos  # noqa: E402

POLICY = ROOT / "docs/evidence/agent-work/proveedores-permitidos.json"


class Avisar(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.log = self.tmp / "argv.log"
        self.bin = self.tmp / "openclaw"
        self.bin.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> " + str(self.log) + "\n"
            'if [ -f "' + str(self.tmp) + '/fallar" ]; then exit 7; fi\n'
            'if [ -f "' + str(self.tmp) + '/salida.json" ]; then\n'
            '  cat "' + str(self.tmp) + '/salida.json"\n'
            "else\n"
            "  printf '{\"ok\": true}\\n'\n"
            "fi\n"
        )
        self.bin.chmod(0o755)
        self.policy = modelos.ProviderPolicy.load(POLICY)

    def con_salida(self, texto):
        (self.tmp / "salida.json").write_text(texto, encoding="utf-8")

    def test_sin_la_variable_no_corre_openclaw(self):
        # B1: avisar solo manda con AGENT_WORK_AVISOS=1 (la pone el plist de sucesión).
        # Sin ella, ni una llamada, aunque el binario apunte a uno de verdad.
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("AGENT_WORK_AVISOS", None)
            respuesta = avisar.avisar(
                "sucesion: glm-5.4 reemplazó a glm-5.3", policy=self.policy, openclaw_bin=self.bin
            )
        self.assertEqual(
            respuesta,
            {"enviado": False, "causa": "avisos apagados (AGENT_WORK_AVISOS no es 1)"},
        )
        self.assertFalse(self.log.exists())

    def test_manda_al_chat_del_dueno(self):
        respuesta = self.avisar_con_avisos("sucesion: glm-5.4 reemplazó a glm-5.3")
        self.assertTrue(respuesta["enviado"])
        argv = self.log.read_text().splitlines()
        self.assertEqual(argv[:4], ["message", "send", "--channel", "telegram"])
        self.assertEqual(argv[argv.index("--target") + 1], "6470689715")
        self.assertIn("sucesion: glm-5.4 reemplazó a glm-5.3", argv)

    def avisar_con_avisos(self, texto):
        anterior = os.environ.get("AGENT_WORK_AVISOS")
        os.environ["AGENT_WORK_AVISOS"] = "1"
        try:
            return avisar.avisar(texto, policy=self.policy, openclaw_bin=self.bin)
        finally:
            if anterior is None:
                del os.environ["AGENT_WORK_AVISOS"]
            else:
                os.environ["AGENT_WORK_AVISOS"] = anterior

    def test_un_envio_fallido_contesta_que_no_salio(self):
        (self.tmp / "fallar").write_text("x")
        respuesta = self.avisar_con_avisos("hola")
        self.assertFalse(respuesta["enviado"])
        self.assertIn("causa", respuesta)


class MessageId(unittest.TestCase):
    """SUA-06 (4.2, paso 4): el envío confirmado devuelve el messageId del gateway.

    El messageId es la confirmación que el checkpoint del emisor exige para avanzar:
    solo cuenta un entero positivo (una cadena de dígitos se convierte); todo lo
    demás deja la clave fuera y el llamador reintenta en la pasada siguiente.
    """

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.log = self.tmp / "argv.log"
        self.bin = self.tmp / "openclaw"
        self.bin.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >> " + str(self.log) + "\n"
            'if [ -f "' + str(self.tmp) + '/salida.json" ]; then\n'
            '  cat "' + str(self.tmp) + '/salida.json"\n'
            "else\n"
            "  printf '{\"ok\": true}\\n'\n"
            "fi\n"
        )
        self.bin.chmod(0o755)
        self.policy = modelos.ProviderPolicy.load(POLICY)

    def avisar_con_avisos(self, texto):
        anterior = os.environ.get("AGENT_WORK_AVISOS")
        os.environ["AGENT_WORK_AVISOS"] = "1"
        try:
            return avisar.avisar(texto, policy=self.policy, openclaw_bin=self.bin)
        finally:
            if anterior is None:
                del os.environ["AGENT_WORK_AVISOS"]
            else:
                os.environ["AGENT_WORK_AVISOS"] = anterior

    def con_salida(self, texto):
        (self.tmp / "salida.json").write_text(texto, encoding="utf-8")

    def test_message_id_entero_positivo(self):
        self.con_salida('{"ok": true, "messageId": 7796}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertTrue(respuesta["enviado"])
        self.assertEqual(respuesta["messageId"], 7796)
        self.assertIs(type(respuesta["messageId"]), int)

    def test_message_id_cadena_de_digitos_se_convierte(self):
        self.con_salida('{"ok": true, "messageId": "7796"}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertEqual(respuesta["messageId"], 7796)
        self.assertIs(type(respuesta["messageId"]), int)

    def test_message_id_detras_de_lineas_de_log(self):
        self.con_salida('INFO enviando por telegram\n{"ok": true, "messageId": 5}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertEqual(respuesta["messageId"], 5)

    def test_sin_message_id_la_clave_no_va(self):
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertTrue(respuesta["enviado"])
        self.assertNotIn("messageId", respuesta)

    def test_message_id_cero_no_cuenta(self):
        self.con_salida('{"ok": true, "messageId": 0}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertTrue(respuesta["enviado"])
        self.assertNotIn("messageId", respuesta)

    def test_message_id_negativo_no_cuenta(self):
        self.con_salida('{"ok": true, "messageId": -5}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertNotIn("messageId", respuesta)

    def test_message_id_float_no_cuenta(self):
        self.con_salida('{"ok": true, "messageId": 1.5}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertNotIn("messageId", respuesta)

    def test_message_id_texto_no_cuenta(self):
        self.con_salida('{"ok": true, "messageId": "texto"}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertNotIn("messageId", respuesta)

    def test_message_id_bool_no_cuenta(self):
        self.con_salida('{"ok": true, "messageId": true}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertNotIn("messageId", respuesta)

    def test_ok_false_con_message_id_positivo_la_clave_va_igual(self):
        # avisar no interpreta el ok del gateway: mientras openclaw salió 0, el envío
        # salió y el messageId que trae la salida es la confirmación del checkpoint.
        self.con_salida('{"ok": false, "messageId": 7796}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertTrue(respuesta["enviado"])
        self.assertEqual(respuesta["messageId"], 7796)

    def test_enviado_sigue_siendo_la_primera_clave(self):
        self.con_salida('{"ok": true, "messageId": 7796}\n')
        respuesta = self.avisar_con_avisos("raíces con pendientes")
        self.assertEqual(list(respuesta)[0], "enviado")


if __name__ == "__main__":
    unittest.main()

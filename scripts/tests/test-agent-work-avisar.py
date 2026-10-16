#!/usr/bin/env python3
"""SUA-04 (4.8): avisar.py manda el mensaje con el openclaw falso que registra el argv."""

import sys
import tempfile
import unittest
from pathlib import Path

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
            "printf '{\"ok\": true}\\n'\n"
        )
        self.bin.chmod(0o755)
        self.policy = modelos.ProviderPolicy.load(POLICY)

    def test_manda_al_chat_del_dueno(self):
        respuesta = avisar.avisar(
            "sucesion: glm-5.4 reemplazó a glm-5.3", policy=self.policy, openclaw_bin=self.bin
        )
        self.assertTrue(respuesta["enviado"])
        argv = self.log.read_text().splitlines()
        self.assertEqual(argv[:4], ["message", "send", "--channel", "telegram"])
        self.assertEqual(argv[argv.index("--target") + 1], "6470689715")
        self.assertIn("sucesion: glm-5.4 reemplazó a glm-5.3", argv)

    def test_un_envio_fallido_contesta_que_no_salio(self):
        (self.tmp / "fallar").write_text("x")
        respuesta = avisar.avisar("hola", policy=self.policy, openclaw_bin=self.bin)
        self.assertFalse(respuesta["enviado"])
        self.assertIn("causa", respuesta)


if __name__ == "__main__":
    unittest.main()

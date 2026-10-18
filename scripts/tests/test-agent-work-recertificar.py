#!/usr/bin/env python3
"""Sondas de recertificar.py contra un doble del CLI, sin opencode ni claude reales."""
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import recertificar  # noqa: E402

DOBLE_OPENCODE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
MODO = %r
argv = sys.argv[1:]
pedido = argv[-1] if argv else ""
modelo = argv[argv.index("-m") + 1] if "-m" in argv else ""
pwd = os.environ.get("PWD", "")
cwd = Path.cwd()

def rutas():
    return [Path(trozo.strip(".,")) for trozo in pedido.split() if trozo.startswith("/")]

if "no-existe" in modelo:
    if MODO == "bien":
        print(json.dumps({"type": "error", "error": {"data": {"message": "Unexpected server error"}}}))
        raise SystemExit(1)
    print(json.dumps({"type": "text", "timestamp": 1}))
    raise SystemExit(0)
if modelo == "zai/glm-5.3":
    if MODO == "bien":
        sys.stderr.write("level=ERROR message=provider-disabled\n")
        raise SystemExit(1)
    sys.stderr.write("message=stream providerID=zai modelID=glm-5.3 small=false agent=build\n")
    print(json.dumps({"type": "text", "timestamp": 1}))
    raise SystemExit(0)
if pedido.startswith("Crea el archivo"):
    fuera = rutas()[0]
    if MODO == "mal":
        fuera.parent.mkdir(parents=True, exist_ok=True)
        fuera.write_text("hola\n", encoding="utf-8")
    else:
        sys.stderr.write("message=evaluated permission=external_directory pattern=* action.action=deny\n")
    print(json.dumps({"type": "text", "timestamp": 1}))
    raise SystemExit(0)
if "fin.txt" in pedido:
    fuera = next(ruta for ruta in rutas() if ruta.name != "fin.txt")
    if MODO == "mal":
        if fuera.exists():
            fuera.unlink()
        raise SystemExit(0)
    sys.stderr.write("message=evaluated permission=external_directory pattern=* action.action=deny\n")
    (cwd / "fin.txt").write_text("segui\n", encoding="utf-8")
    print(json.dumps({"type": "text", "timestamp": 1}))
    raise SystemExit(0)
directorio = pwd if MODO == "bien" else str(cwd.resolve())
sys.stderr.write("message=created id=ses_sonda directory=%%s\n" %% directorio)
if MODO == "bien":
    sys.stderr.write("message=stream providerID=zai-coding-plan modelID=glm-5.3-flash small=true agent=build\n")
    print(json.dumps({"type": "text", "timestamp": 1, "part": {"text": "hola"}}))
else:
    sys.stderr.write("message=stream providerID=openai modelID=gpt small=false agent=build\n")
    print("Update Available")
    print(json.dumps({"type": "text", "timestamp": 1}))
raise SystemExit(0)
'''

DOBLE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
MODO = %r
argv = sys.argv[1:]
pedido = argv[1] if argv and argv[0] == "-p" else ""
cwd = Path.cwd()
pwd = os.environ.get("PWD", "")

def rutas():
    return [Path(trozo.strip(".,")) for trozo in pedido.split() if trozo.startswith("/")]

def emitir(cwd_declarado, tools, mcp, denegados):
    print(json.dumps({"type": "system", "subtype": "init", "cwd": cwd_declarado, "tools": tools,
                      "mcp_servers": mcp, "model": "claude-sonnet-5"}))
    print(json.dumps({"type": "result", "subtype": "success", "permission_denials": denegados, "is_error": False}))

if pedido.startswith("Escribe"):
    fuera = rutas()[0]
    if MODO == "mal":
        fuera.parent.mkdir(parents=True, exist_ok=True)
        fuera.write_text("hola\n", encoding="utf-8")
        emitir(pwd, ["Read", "Bash", "Write"], [], [])
    else:
        emitir(str(cwd.resolve()), ["Read", "Bash", "Write"], [],
               [{"tool_name": "Write", "tool_use_id": "t1", "tool_input": {"file_path": str(fuera)}}])
    raise SystemExit(0)
if pedido.startswith("Con Bash"):
    caminos = rutas()
    dentro = next(camino for camino in caminos if camino.name == "dentro.txt")
    fuera = next(camino for camino in caminos if camino.name != "dentro.txt")
    if MODO == "mal" and "dangerouslyDisableSandbox: true" in pedido:
        fuera.parent.mkdir(parents=True, exist_ok=True)
        fuera.write_text("hola\n", encoding="utf-8")
    else:
        dentro.write_text("hola\n", encoding="utf-8")
    emitir(str(cwd.resolve()), ["Bash"], [], [])
    raise SystemExit(0)
marca = None
ajustes = cwd / ".claude" / "settings.json"
if ajustes.is_file():
    comando = json.loads(ajustes.read_text(encoding="utf-8"))["hooks"]["SessionStart"][0]["hooks"][0]["command"]
    marca = Path(comando.split()[-1])
if MODO == "mal" or "--restricted" not in argv or "--setting-sources" in argv:
    if marca is not None:
        marca.parent.mkdir(parents=True, exist_ok=True)
        marca.write_text("corrio\n", encoding="utf-8")
    emitir(str(cwd.resolve()), ["Task", "Bash", "Write", "Read"],
           [{"name": "claude.ai Claude Docs", "status": "connected"}], [])
else:
    tools = argv[argv.index("--tools") + 1].split(",")
    emitir(str(cwd.resolve()), tools, [], [])
raise SystemExit(0)
'''


class Sondas(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.raiz = Path(self.tmp.name)

    def doble(self, texto, modo):
        ruta = self.raiz / f"doble-{modo}-{abs(hash(texto)) % 10000}.py"
        ruta.write_text(texto % modo, encoding="utf-8")
        ruta.chmod(ruta.stat().st_mode | stat.S_IEXEC)
        return ruta

    def test_m1_rechaza_update_available_aunque_salga_solo_por_stderr(self):
        doble = self.raiz / "doble-stderr.py"
        doble.write_text(
            "#!/usr/bin/env python3\nimport json, sys\n"
            "sys.stderr.write('Update Available 1.19.4\\n')\n"
            "print(json.dumps({'type': 'text', 'text': 'hola'}))\n",
            encoding="utf-8")
        doble.chmod(doble.stat().st_mode | stat.S_IEXEC)
        veredicto = recertificar.correr_sonda(
            "m1", doble, checkout=ROOT, raiz=self.raiz / "m1-stderr")
        self.assertEqual(veredicto.estado, "no pasa", veredicto.detalle)

    def test_cada_sonda_de_opencode_pasa_con_el_doble_sano_y_falla_con_el_roto(self):
        for sonda in recertificar.SONDAS["opencode"]:
            for modo, esperado in (("bien", "pasa"), ("mal", "no pasa")):
                with self.subTest(sonda=sonda, modo=modo):
                    veredicto = recertificar.correr_sonda(
                        sonda, self.doble(DOBLE_OPENCODE, modo), checkout=ROOT, raiz=self.raiz / f"{sonda}-{modo}")
                    self.assertEqual(veredicto.estado, esperado, veredicto.detalle)

    def test_sin_recert_fuera_no_inventa_una_carpeta(self):
        anterior = os.environ.pop("RECERT_FUERA", None)
        try:
            with self.assertRaises(RuntimeError) as ctx:
                recertificar._fuera(self.raiz / "base")
        finally:
            if anterior is not None:
                os.environ["RECERT_FUERA"] = anterior
        self.assertIn("RECERT_FUERA", str(ctx.exception))

    def test_m7_pasa_con_solo_texto_y_no_si_termina_en_el_deny_o_borra_el_archivo(self):
        casos = {
            "texto": (
                "#!/usr/bin/env python3\nimport json, sys\n"
                "sys.stderr.write('message=evaluated permission=external_directory pattern=* action.action=deny\\n')\n"
                "print(json.dumps({'type': 'text', 'timestamp': 2, 'part': {'type': 'text', 'text': 'bloqueado'}}))\n",
                "pasa",
            ),
            "termina": (
                "#!/usr/bin/env python3\nimport json, sys\n"
                "sys.stderr.write('message=evaluated permission=external_directory pattern=* action.action=deny\\n')\n"
                "print(json.dumps({'type': 'text', 'timestamp': 1, 'part': {'type': 'text', 'text': 'voy'}}))\n"
                "print(json.dumps({'type': 'tool_use', 'timestamp': 2, 'part': {'type': 'tool', 'tool': 'read', "
                "'state': {'status': 'error', 'error': 'The user has specified a rule which prevents you "
                "from using this specific tool call.'}}}))\n",
                "no pasa",
            ),
            "borra": (
                "#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\n"
                "pedido = sys.argv[-1]\n"
                "fuera = next(Path(trozo.strip('.,')) for trozo in pedido.split() if trozo.startswith('/'))\n"
                "if fuera.exists():\n    fuera.unlink()\n"
                "sys.stderr.write('message=evaluated permission=external_directory pattern=* action.action=deny\\n')\n"
                "print('{\"type\": \"text\"}')\n",
                "no pasa",
            ),
        }
        for nombre, (texto, esperado) in casos.items():
            with self.subTest(nombre=nombre):
                doble = self.raiz / f"m7-{nombre}.py"
                doble.write_text(texto, encoding="utf-8")
                doble.chmod(doble.stat().st_mode | stat.S_IEXEC)
                veredicto = recertificar.correr_sonda(
                    "m7", doble, checkout=ROOT, raiz=self.raiz / f"m7-{nombre}")
                self.assertEqual(veredicto.estado, esperado, veredicto.detalle)

    def test_m23_exige_salir_del_sandbox_y_el_doble_malo_escribe_fuera(self):
        for modo, esperado in (("bien", "pasa"), ("mal", "no pasa")):
            with self.subTest(modo=modo):
                veredicto = recertificar.correr_sonda(
                    "m23", self.doble(DOBLE_CLAUDE, modo), checkout=ROOT,
                    raiz=self.raiz / f"m23-frase-{modo}")
                self.assertEqual(veredicto.estado, esperado, veredicto.detalle)

    def test_cada_sonda_de_claude_pasa_con_el_doble_sano_y_falla_con_el_roto(self):
        for sonda in recertificar.SONDAS["claude"]:
            for modo, esperado in (("bien", "pasa"), ("mal", "no pasa")):
                with self.subTest(sonda=sonda, modo=modo):
                    veredicto = recertificar.correr_sonda(
                        sonda, self.doble(DOBLE_CLAUDE, modo), checkout=ROOT, raiz=self.raiz / f"{sonda}-{modo}")
                    self.assertEqual(veredicto.estado, esperado, veredicto.detalle)


if __name__ == "__main__":
    unittest.main()

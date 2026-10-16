#!/usr/bin/env python3
"""SUA-06 (4.2): el emisor de las raíces — pasar() proyecta, avisa y lleva checkpoint.

El gateway es un doble en memoria que sirve los fixtures de proyeccion-derivar según
el método y registra cada llamada; el reloj es un datetime fijo por pasada; avisar_fn
es un falso que graba los textos y contesta lo que la prueba fija. Nada toca la red.
"""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import native_gateway  # noqa: E402
import proyeccion  # noqa: E402
from sistema_agentes import contrato  # noqa: E402

FIXTURES = ROOT / "scripts/tests/fixtures/sistema-agentes/proyeccion-derivar"
AHORA = datetime(2026, 10, 16, 12, 0, 0, tzinfo=timezone.utc)
STALE = 300000
INTERVALO = 300000
CONSOLIDADO_MS = 1800000
GATEWAY = "gateway-1"
OK = {"enviado": True, "messageId": 7796}
RAIZ_LISTADA = [{"rootId": "root-estados", "state": "active", "openedAt": "2026-10-16T09:05:00Z"}]


def fixture(nombre):
    return json.loads((FIXTURES / f"{nombre}.json").read_text(encoding="utf-8"))


class GatewayDoble:
    """Sirve los snapshots fijados según el método; "basura" no es un snapshot."""

    def __init__(self, snapshots, lista=None):
        self.snapshots = snapshots
        self.lista = lista
        self.llamadas = []

    def __call__(self, metodo, params):
        self.llamadas.append({"method": metodo, "params": params})
        if metodo == "managedTasks.root.list":
            if isinstance(self.lista, Exception):
                raise self.lista
            if self.lista is not None:
                return self.lista
            return {
                "roots": [
                    {"rootId": rid, "state": "active", "openedAt": "2026-10-16T09:05:00Z"}
                    for rid in sorted(self.snapshots)
                ]
            }
        if metodo == "managedTasks.root.read":
            valor = self.snapshots.get(params["rootId"], "basura")
            if isinstance(valor, Exception):
                raise valor
            return json.loads(json.dumps(valor))
        raise AssertionError(f"método inesperado: {metodo}")


class AvisarDoble:
    """Graba cada texto y contesta el resultado que toque por número de envío."""

    def __init__(self, resultados=None):
        self.textos = []
        self.resultados = resultados or [dict(OK)]

    def __call__(self, texto):
        self.textos.append(texto)
        indice = min(len(self.textos), len(self.resultados)) - 1
        return self.resultados[indice]


class Pasada(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.dir = self.tmp / "raices"

    def correr(self, snapshots, ahora=AHORA, avisar_fn=None, lista=None, gateway=None):
        self.gateway = gateway or GatewayDoble(snapshots, lista=lista)
        self.resultado = proyeccion.pasar(
            self.dir,
            stale_after_ms=STALE,
            ahora=ahora,
            gateway=self.gateway,
            intervalo_ms=INTERVALO,
            consolidado_ms=CONSOLIDADO_MS,
            host_gateway=GATEWAY,
            avisar_fn=avisar_fn,
        )
        return self.resultado

    def proyeccion(self, root_id):
        ruta = self.dir / "proyecciones" / f"{root_id}.json"
        return json.loads(ruta.read_text(encoding="utf-8"))

    def checkpoint(self):
        return json.loads((self.dir / "checkpoint.json").read_text(encoding="utf-8"))


class DosRaicesUnConsolidado(Pasada):
    def test_dos_raices_un_consolidado(self):
        avisos = AvisarDoble()
        snapshots = {
            "root-estados": fixture("raiz-estados"),
            "root-sin-criterios": fixture("raiz-sin-criterios"),
        }
        resultado = self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 1)
        texto = avisos.textos[0]
        self.assertTrue(texto.startswith("📊 *Raíces con pendientes* (2)"), texto)
        self.assertIn("root-estados", texto)
        self.assertIn("root-sin-criterios", texto)
        self.assertIn("declarado 66% / observado 66% / aceptado 33%", texto)
        self.assertIn("• unit-a (reported) · cli:banco-cli", texto)
        self.assertIn("• unit-b (running) · agent:agent-b ⚠️ transport-unavailable", texto)
        self.assertNotIn("unit-c", texto)
        self.assertEqual(resultado["raices"], 2)
        self.assertEqual(resultado["escritas"], 2)
        self.assertEqual(resultado["errores"], [])
        self.assertEqual(resultado["avisos"]["excepciones"], None)
        self.assertEqual(
            resultado["avisos"]["consolidado"], {"enviado": True, "messageId": 7796, "causa": None}
        )
        self.assertEqual(contrato.validar(self.proyeccion("root-estados")), [])
        self.assertEqual(contrato.validar(self.proyeccion("root-sin-criterios")), [])
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint["schema"], "sistema-agentes.emisor-raices.v1")
        self.assertEqual(checkpoint["ultimoConsolidado"], "2026-10-16T12:00:00Z")
        self.assertEqual(checkpoint["notados"], {})


class CerrarUnaLaOtraSigue(Pasada):
    def test_cerrar_una_la_otra_sigue(self):
        avisos = AvisarDoble()
        snapshots = {
            "root-estados": fixture("raiz-estados"),
            "root-sin-criterios": fixture("raiz-sin-criterios"),
        }
        gateway = GatewayDoble(snapshots)
        self.correr(snapshots, avisar_fn=avisos, gateway=gateway)
        self.assertEqual(self.checkpoint()["ultimoConsolidado"], "2026-10-16T12:00:00Z")

        luego = AHORA + timedelta(minutes=31)
        gateway.lista = {
            "roots": [
                {"rootId": "root-estados", "state": "active", "openedAt": "2026-10-16T09:05:00Z"}
            ]
        }
        resultado = self.correr(snapshots, ahora=luego, avisar_fn=avisos, gateway=gateway)
        self.assertEqual(resultado["raices"], 1)
        self.assertEqual(resultado["escritas"], 1)
        consolidado = avisos.textos[-1]
        self.assertIn("Raíces con pendientes* (1)", consolidado)
        self.assertIn("root-estados", consolidado)
        self.assertNotIn("root-sin-criterios", consolidado)
        self.assertFalse((self.dir / "proyecciones" / "root-sin-criterios.json").exists())
        self.assertEqual(self.proyeccion("root-estados")["generatedAt"], "2026-10-16T12:31:00Z")
        self.assertEqual(self.checkpoint()["ultimoConsolidado"], "2026-10-16T12:31:00Z")


class EnvioSinConfirmarNoAvanza(Pasada):
    def test_el_checkpoint_no_avanza_y_la_pasada_siguiente_reintenta(self):
        avisos = AvisarDoble(
            resultados=[
                {"enviado": False, "causa": "openclaw salió 7"},
                {"enviado": True},
                dict(OK),
            ]
        )
        snapshots = {"root-sin-criterios": fixture("raiz-sin-criterios")}
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 1)
        self.assertTrue(self.resultado["errores"])
        self.assertIn("no se confirmó", " ".join(self.resultado["errores"]))
        self.assertIn("openclaw salió 7", " ".join(self.resultado["errores"]))
        self.assertFalse((self.dir / "checkpoint.json").exists())

        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 2)
        self.assertTrue(self.resultado["errores"])
        self.assertFalse((self.dir / "checkpoint.json").exists())

        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 3)
        self.assertEqual(self.resultado["errores"], [])
        self.assertEqual(self.checkpoint()["ultimoConsolidado"], "2026-10-16T12:00:00Z")

    def test_el_checkpoint_existente_queda_byte_por_byte_igual(self):
        avisos = AvisarDoble(
            resultados=[
                dict(OK),
                dict(OK),
                {"enviado": False, "causa": "apagados"},
                {"enviado": False, "causa": "apagados"},
            ]
        )
        snapshots = {"root-excepciones": fixture("excepciones")}
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 2)
        antes = (self.dir / "checkpoint.json").read_bytes()

        luego = AHORA + timedelta(hours=1)
        self.correr(snapshots, ahora=luego, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 4)
        self.assertTrue(self.resultado["errores"])
        self.assertEqual((self.dir / "checkpoint.json").read_bytes(), antes)
        self.assertEqual(
            self.resultado["avisos"]["excepciones"]["avisadas"], ["exc-01", "exc-00-raiz"]
        )

        self.correr(snapshots, ahora=luego, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 6)


class ExcepcionNuevaYReaviso(Pasada):
    def test_nueva_avisada_reaviso_al_umbral_y_response_nunca_sale(self):
        avisos = AvisarDoble()
        snapshots = {"root-excepciones": fixture("excepciones")}
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 2)
        excepciones = avisos.textos[0]
        self.assertTrue(excepciones.startswith("⚠️ *Excepciones sin respuesta* (3)"), excepciones)
        self.assertIn(
            "*root-excepciones*/unit-a · NECESITA_DAVID (exc-01) · desde 11:20Z", excepciones
        )
        self.assertIn("responder: seguir=Seguir con el plan. | cancelar=Cancelar.", excepciones)
        self.assertIn(
            "*root-excepciones*/(raíz) · CONFIRMAR_PLAN (exc-00-raiz) · desde 11:00Z", excepciones
        )
        self.assertIn("responder: seguir=Seguir con el plan.", excepciones)
        self.assertNotIn("exc-03", excepciones)
        self.assertNotIn("CI_ROJO", excepciones)
        self.assertLess(excepciones.index("*/unit-a"), excepciones.index("*/(raíz)"))
        self.assertEqual(
            self.resultado["avisos"]["excepciones"],
            {
                "enviado": True,
                "messageId": 7796,
                "causa": None,
                "avisadas": ["exc-01", "exc-02", "exc-00-raiz"],
            },
        )
        self.assertEqual(
            self.checkpoint()["notados"],
            {
                "exc-00-raiz": "2026-10-16T12:00:00Z",
                "exc-01": "2026-10-16T12:00:00Z",
                "exc-02": "2026-10-16T12:00:00Z",
            },
        )

        self.correr(snapshots, ahora=AHORA + timedelta(minutes=15), avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 2)
        self.assertEqual(self.resultado["avisos"]["excepciones"], None)
        self.assertEqual(self.checkpoint()["notados"]["exc-01"], "2026-10-16T12:00:00Z")

        self.correr(snapshots, ahora=AHORA + timedelta(hours=1), avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 4)
        reaviso = avisos.textos[2]
        self.assertIn("(2)", reaviso)
        self.assertIn("exc-01", reaviso)
        self.assertIn("exc-00-raiz", reaviso)
        self.assertNotIn("exc-02", reaviso)
        self.assertNotIn("exc-03", " ".join(avisos.textos))
        checkpoint = self.checkpoint()
        self.assertEqual(checkpoint["notados"]["exc-01"], "2026-10-16T13:00:00Z")
        self.assertEqual(checkpoint["notados"]["exc-00-raiz"], "2026-10-16T13:00:00Z")
        self.assertEqual(checkpoint["notados"]["exc-02"], "2026-10-16T12:00:00Z")
        self.assertNotIn("exc-03", checkpoint["notados"])


class DosPasadasALaVez(Pasada):
    def test_con_el_candado_ocupado_la_pasada_se_salta(self):
        avisos = AvisarDoble()
        snapshots = {"root-sin-criterios": fixture("raiz-sin-criterios")}
        (self.dir).mkdir(parents=True, exist_ok=True)
        candado = open(self.dir / ".pasada.lock", "a")
        self.addCleanup(candado.close)
        fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            resultado = self.correr(snapshots, avisar_fn=avisos)
            self.assertEqual(resultado, {"saltada": True})
            self.assertEqual(self.gateway.llamadas, [])
            self.assertFalse((self.dir / "checkpoint.json").exists())
            self.assertEqual(avisos.textos, [])
        finally:
            fcntl.flock(candado, fcntl.LOCK_UN)
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(avisos.textos), 1)


class RaizRotaNoTumbaLasDemas(Pasada):
    def test_la_raiz_rota_queda_en_errores_y_las_demas_siguen(self):
        (self.dir / "proyecciones").mkdir(parents=True)
        vieja_rota = self.dir / "proyecciones" / "root-roto.json"
        vieja_rota.write_text('{"vieja": true}\n', encoding="utf-8")
        avisos = AvisarDoble()
        mensaje_largo = "boom " * 80
        snapshots = {
            "root-roto": RuntimeError(mensaje_largo),
            "root-estados": fixture("raiz-estados"),
        }
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(self.resultado["errores"]), 1)
        error = self.resultado["errores"][0]
        self.assertTrue(error.startswith("raíz root-roto:"), error)
        self.assertLessEqual(len(error), 200)
        self.assertEqual(self.resultado["escritas"], 1)
        self.assertEqual(contrato.validar(self.proyeccion("root-estados")), [])
        self.assertEqual(
            (self.dir / "proyecciones" / "root-roto.json").read_text(encoding="utf-8"),
            '{"vieja": true}\n',
        )
        self.assertEqual(len(avisos.textos), 1)
        self.assertNotIn("root-roto", avisos.textos[0])

    def test_la_raiz_que_devuelve_basura_tampoco_tumba_las_demas(self):
        snapshots = {
            "root-basura": "no entre al diccionario",
            "root-estados": fixture("raiz-estados"),
        }
        avisos = AvisarDoble()
        self.correr(snapshots, avisar_fn=avisos)
        self.assertEqual(len(self.resultado["errores"]), 1)
        self.assertTrue(self.resultado["errores"][0].startswith("raíz root-basura:"))
        self.assertEqual(self.resultado["escritas"], 1)


class ListCaidoNoEscribeNiBorra(Pasada):
    def test_el_list_caido_deja_todo_como_estaba(self):
        (self.dir / "proyecciones").mkdir(parents=True)
        proyeccion_vieja = self.dir / "proyecciones" / "root-estados.json"
        proyeccion_vieja.write_text('{"vieja": true}\n', encoding="utf-8")
        gateway = GatewayDoble({})
        gateway.lista = RuntimeError("gateway no disponible")
        resultado = self.correr({}, gateway=gateway, avisar_fn=AvisarDoble())
        self.assertEqual(len(resultado["errores"]), 1)
        self.assertIn("managedTasks.root.list", resultado["errores"][0])
        self.assertEqual(proyeccion_vieja.read_text(encoding="utf-8"), '{"vieja": true}\n')
        self.assertFalse((self.dir / "checkpoint.json").exists())


class EscrituraAtomica(Pasada):
    def test_un_replace_fallido_deja_el_viejo_intacto_y_sin_residuos(self):
        snapshots = {"root-estados": fixture("raiz-estados")}
        self.correr(snapshots, avisar_fn=AvisarDoble())
        vieja = (self.dir / "proyecciones" / "root-estados.json").read_text(encoding="utf-8")

        with mock.patch("os.replace", side_effect=OSError("disco lleno")):
            resultado = self.correr(snapshots, avisar_fn=AvisarDoble())
        self.assertTrue(any("raíz root-estados" in error for error in resultado["errores"]))
        intacta = (self.dir / "proyecciones" / "root-estados.json").read_text(encoding="utf-8")
        self.assertEqual(intacta, vieja)
        residuos = [
            p.name for p in (self.dir / "proyecciones").iterdir() if p.name.startswith(".pending-")
        ]
        self.assertEqual(residuos, [])

        self.correr(snapshots, avisar_fn=AvisarDoble())
        self.assertEqual(contrato.validar(self.proyeccion("root-estados")), [])


class CheckpointIlegible(Pasada):
    def test_checkpoint_con_basura_da_error_sin_avisos_y_sin_pisarlo(self):
        self.dir.mkdir(parents=True)
        (self.dir / "checkpoint.json").write_bytes(b"basura { no json")
        avisos = AvisarDoble()
        resultado = self.correr({"root-estados": fixture("raiz-estados")}, avisar_fn=avisos)
        self.assertEqual(len(resultado["errores"]), 1)
        self.assertIn("checkpoint", resultado["errores"][0])
        self.assertEqual(avisos.textos, [])
        self.assertEqual(resultado["avisos"], {"consolidado": None, "excepciones": None})
        self.assertEqual(contrato.validar(self.proyeccion("root-estados")), [])
        self.assertEqual((self.dir / "checkpoint.json").read_bytes(), b"basura { no json")

    def test_checkpoint_con_otro_esquema_tambien_da_error(self):
        self.dir.mkdir(parents=True)
        (self.dir / "checkpoint.json").write_text(
            json.dumps({"schema": "otra-cosa", "ultimoConsolidado": None, "notados": {}}),
            encoding="utf-8",
        )
        resultado = self.correr({"root-estados": fixture("raiz-estados")}, avisar_fn=AvisarDoble())
        self.assertEqual(len(resultado["errores"]), 1)
        self.assertIn("checkpoint", resultado["errores"][0])
        self.assertIn("schema", (self.dir / "checkpoint.json").read_text(encoding="utf-8"))


class MudoEnLaMac(Pasada):
    def test_avisar_fn_none_es_el_emisor_mudo(self):
        resultado = self.correr({"root-excepciones": fixture("excepciones")}, avisar_fn=None)
        self.assertEqual(
            resultado,
            {
                "raices": 1,
                "escritas": 1,
                "avisos": {"consolidado": None, "excepciones": None},
                "errores": [],
            },
        )
        self.assertEqual(contrato.validar(self.proyeccion("root-excepciones")), [])
        self.assertFalse((self.dir / "checkpoint.json").exists())


class Salida(Pasada):
    def test_sin_errores_son_exactamente_las_cuatro_claves(self):
        resultado = self.correr({"root-estados": fixture("raiz-estados")}, avisar_fn=AvisarDoble())
        self.assertEqual(set(resultado), {"raices", "escritas", "avisos", "errores"})
        self.assertEqual(resultado["raices"], 1)
        self.assertEqual(resultado["escritas"], 1)

    def test_directorio_symlink_es_error_con_nombre(self):
        real = self.tmp / "real"
        real.mkdir()
        enlace = self.tmp / "enlace"
        enlace.symlink_to(real)
        self.dir = enlace
        resultado = self.correr({"root-estados": fixture("raiz-estados")}, avisar_fn=AvisarDoble())
        self.assertEqual(len(resultado["errores"]), 1)
        self.assertIn("enlace", resultado["errores"][0])
        self.assertIn("symlink", resultado["errores"][0])
        self.assertEqual(list((real).iterdir()), [])


class Cli(Pasada):
    SCRIPT = ROOT / "scripts/agent-work/proyeccion.py"

    def setUp(self):
        super().setUp()
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp_bin = Path(temp.name)
        self.log = self.tmp_bin / "gateway.log"
        self.bin = self.tmp_bin / "openclaw"
        self.bin.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "args = sys.argv[1:]\n"
            "assert args[:2] == ['gateway', 'call'] and args[-1] == '--json'\n"
            "metodo = args[2]\n"
            "params = json.loads(args[args.index('--params') + 1])\n"
            "with open(os.environ['FAKE_LOG'], 'a') as f:\n"
            "    f.write(json.dumps({'method': metodo, 'params': params}) + '\\n')\n"
            "if metodo == 'managedTasks.root.read':\n"
            "    print(pathlib.Path(os.environ['FAKE_SNAPSHOT']).read_text(), end='')\n"
            "else:\n"
            "    print(json.dumps(json.loads(os.environ['FAKE_LISTA'])))\n",
            encoding="utf-8",
        )
        self.bin.chmod(0o755)

    def snapshot_aceptado(self):
        snapshot = fixture("raiz-estados")
        for doc in snapshot["units"]:
            doc["state"] = "accepted"
        ruta = self.tmp_bin / "raiz-aceptada.json"
        ruta.write_text(json.dumps(snapshot), encoding="utf-8")
        return ruta

    def correr_cli(self, *argumentos, snapshot=None):
        entorno = dict(
            os.environ,
            LANG="en_US.UTF-8",
            FAKE_LOG=str(self.log),
            FAKE_SNAPSHOT=str(snapshot or self.snapshot_aceptado()),
            FAKE_LISTA=json.dumps({"roots": RAIZ_LISTADA}),
            OPENCLAW_BIN=str(self.bin),
        )
        entorno.pop("AGENT_WORK_AVISOS", None)
        return subprocess.run(
            [sys.executable, str(self.SCRIPT), *argumentos],
            capture_output=True,
            text=True,
            timeout=60,
            env=entorno,
            cwd=str(ROOT),
        )

    def comandos(self, *extra):
        return [
            "pasar",
            "--dir",
            str(self.dir),
            "--stale-after-ms",
            str(STALE),
            "--intervalo-ms",
            str(INTERVALO),
            *extra,
        ]

    def test_pasar_sin_pendientes_sale_cero_con_las_cuatro_claves(self):
        hecho = self.correr_cli(*self.comandos())
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        self.assertEqual(
            json.loads(hecho.stdout),
            {
                "raices": 1,
                "escritas": 1,
                "avisos": {"consolidado": None, "excepciones": None},
                "errores": [],
            },
        )
        self.assertEqual(contrato.validar(self.proyeccion("root-estados")), [])
        self.assertFalse((self.dir / "checkpoint.json").exists())
        llamadas = [json.loads(linea) for linea in self.log.read_text().splitlines()]
        self.assertEqual(llamadas[0], {"method": "managedTasks.root.list", "params": {}})
        self.assertEqual(
            llamadas[1], {"method": "managedTasks.root.read", "params": {"rootId": "root-estados"}}
        )

    def test_pasar_con_avisos_apagados_es_error_con_nombre(self):
        hecho = self.correr_cli(*self.comandos(), snapshot=FIXTURES / "raiz-estados.json")
        self.assertEqual(hecho.returncode, 1)
        salida = json.loads(hecho.stdout)
        self.assertEqual(salida["escritas"], 1)
        self.assertEqual(len(salida["errores"]), 1)
        self.assertIn("consolidado", salida["errores"][0])
        self.assertIn("avisos apagados", salida["errores"][0])
        self.assertFalse((self.dir / "checkpoint.json").exists())

    def test_pasar_con_el_candado_ocupado_imprime_saltada(self):
        self.dir.mkdir(parents=True, exist_ok=True)
        candado = open(self.dir / ".pasada.lock", "a")
        self.addCleanup(candado.close)
        fcntl.flock(candado, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            hecho = self.correr_cli(*self.comandos())
        finally:
            fcntl.flock(candado, fcntl.LOCK_UN)
        self.assertEqual(hecho.returncode, 0, hecho.stderr)
        self.assertEqual(json.loads(hecho.stdout), {"saltada": True})
        self.assertFalse(self.log.exists())


class RelojFalso:
    def __init__(self, valor=0.0):
        self.valor = valor

    def __call__(self):
        return self.valor


class PasarFalso:
    VACIO = {"raices": 0, "escritas": 0, "errores": []}

    def __init__(self, resultado=None, error=None):
        self.llamadas = []
        self.resultado = resultado if resultado is not None else dict(self.VACIO)
        self.error = error

    def __call__(self, raices_dir, **kwargs):
        self.llamadas.append({"raices_dir": raices_dir, **kwargs})
        if self.error is not None:
            raise self.error
        return self.resultado


class ClienteGateway:
    host_id = "host-uno"
    openclaw_bin = "/bin/openclaw-falso"

    def list_pending(self, after_task_id=None, limit=100):
        return []

    def ack(self, receipt):
        return receipt

    def close_host(self, *_):
        raise AssertionError("sin cierres pendientes")

    def report_host_result(self, *_):
        raise AssertionError("sin reportes pendientes")

    def report_host_incident(self, *_):
        raise AssertionError("sin incidentes pendientes")


class HostQuieto:
    def flush(self, *_):
        return []

    def flush_closures(self, *_):
        return 0, []

    def flush_incidents(self, *_):
        return 0, []

    def operation_key_for(self, *_):
        return None


class RaicesPublisherDelHost(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)

    def test_cuando_no_toca_no_llama_y_devuelve_vacio(self):
        reloj = RelojFalso(100.0)
        pasar = PasarFalso(resultado={"raices": 1, "escritas": 2, "errores": []})
        publisher = native_gateway.RaicesPublisher(str(self.tmp), clock=reloj, pasar_fn=pasar)
        self.assertEqual(publisher.publish(ClienteGateway()), (2, []))
        reloj.valor = 399.9
        self.assertEqual(publisher.publish(ClienteGateway()), (0, []))
        self.assertEqual(len(pasar.llamadas), 1)

    def test_cuando_toca_llama_una_vez_muda_y_reprograma(self):
        reloj = RelojFalso(100.0)
        pasar = PasarFalso()
        publisher = native_gateway.RaicesPublisher(
            str(self.tmp), clock=reloj, pasar_fn=pasar, host_gateway="mini"
        )
        publisher.publish(ClienteGateway())
        self.assertEqual(len(pasar.llamadas), 1)
        llamada = pasar.llamadas[0]
        self.assertEqual(llamada["raices_dir"], str(self.tmp))
        self.assertEqual(llamada["stale_after_ms"], 3600000)
        self.assertEqual(llamada["intervalo_ms"], 300000)
        self.assertEqual(llamada["host_gateway"], "mini")
        self.assertNotIn("avisar_fn", llamada)
        self.assertNotIn("consolidado_ms", llamada)
        self.assertTrue(callable(llamada["gateway"]))
        self.assertIsNotNone(llamada["ahora"].tzinfo)

        reloj.valor = 399.9
        publisher.publish(ClienteGateway())
        reloj.valor = 400.0
        publisher.publish(ClienteGateway())
        self.assertEqual(len(pasar.llamadas), 2)

    def test_un_fallo_de_pasar_sale_como_error_y_no_lanza(self):
        publisher = native_gateway.RaicesPublisher(
            str(self.tmp),
            clock=RelojFalso(100.0),
            pasar_fn=PasarFalso(error=RuntimeError("gateway en llamas")),
        )
        self.assertEqual(publisher.publish(ClienteGateway()), (0, ["raices: gateway en llamas"]))
        publisher = native_gateway.RaicesPublisher(
            str(self.tmp), clock=RelojFalso(100.0), pasar_fn=PasarFalso(error=OSError("disco ido"))
        )
        self.assertEqual(publisher.publish(ClienteGateway()), (0, ["raices: disco ido"]))

    def test_los_errores_del_resultado_salen_prefijados(self):
        publisher = native_gateway.RaicesPublisher(
            str(self.tmp),
            clock=RelojFalso(100.0),
            pasar_fn=PasarFalso(
                resultado={"raices": 1, "escritas": 2, "errores": ["raíz root-x: boom"]}
            ),
        )
        self.assertEqual(publisher.publish(ClienteGateway()), (2, ["raices: raíz root-x: boom"]))


class PumpOnceConRaices(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.args = {
            "evidence_root": self.tmp / "evidence",
            "progress_state_dir": self.tmp / "progress",
            "progress_client": ROOT / "scripts" / "mac" / "progress-events.py",
        }

    def test_resultado_limpio_incluye_raices(self):
        raices = PasarFalso(resultado={"raices": 1, "escritas": 3, "errores": []})
        resultado = native_gateway.pump_once(
            ClienteGateway(),
            host=HostQuieto(),
            raices_publisher=raices_como_publisher(raices),
            **self.args,
        )
        self.assertEqual(
            resultado,
            {
                "reported": 0,
                "closed": 0,
                "incidents": 0,
                "transferred": 0,
                "published": 0,
                "raices": 3,
            },
        )

    def test_el_error_de_raices_se_suma_al_runtimeerror(self):
        publisher = native_gateway.RaicesPublisher(
            str(self.tmp),
            clock=RelojFalso(100.0),
            pasar_fn=PasarFalso(error=RuntimeError("gateway en llamas")),
        )

        class HostRoto(HostQuieto):
            def flush(self, *_):
                raise RuntimeError("host report unavailable")

        with self.assertRaisesRegex(
            RuntimeError, r"host report unavailable.*raices: gateway en llamas"
        ):
            native_gateway.pump_once(
                ClienteGateway(), host=HostRoto(), raices_publisher=publisher, **self.args
            )


def raices_como_publisher(pasar):
    return native_gateway.RaicesPublisher("donde-sea", clock=RelojFalso(100.0), pasar_fn=pasar)


class WatchConRaices(unittest.TestCase):
    def test_watch_construye_el_publisher_y_lo_atraviesa(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        tmp = Path(temp.name)
        with (
            mock.patch.object(native_gateway, "watch_pump") as bombeo,
            mock.patch.object(native_gateway, "RaicesPublisher") as clase,
        ):
            codigo = native_gateway.main(
                [
                    "--openclaw-bin",
                    "/bin/openclaw-falso",
                    "--host-id",
                    "host-uno",
                    "--expect-url",
                    "https://gateway",
                    "--host-state-dir",
                    str(tmp),
                    "--evidence-root",
                    str(tmp),
                    "--progress-state-dir",
                    str(tmp),
                    "--progress-client",
                    "progress-events.py",
                    "--watch",
                    "--raices-dir",
                    "/data/raices",
                ]
            )
        self.assertEqual(codigo, 0)
        clase.assert_called_once_with("/data/raices")
        self.assertIs(bombeo.call_args.kwargs["raices_publisher"], clase.return_value)


if __name__ == "__main__":
    unittest.main()

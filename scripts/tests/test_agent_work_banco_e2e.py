#!/usr/bin/env python3
"""banco: the ruta_viva harness with a real opencode and a real model, per profile of the CLI route.

The host runs with --canary: the generation gate is armed and the CLI profiles have no competence yet,
so without it the banco would refuse itself. Each case runs one task end to end: the package reaches
runs/<op>/contexto, conducta.py reads what the model actually did, and the real repo of a reviewer is
photographed before and after. The control case runs the same task with no profile (--sin-contexto):
its conducta must be red for the expected reason, not by accident.

Nothing here touches this machine's host, the Mini or ~/bin. It skips unless AGENT_WORK_BANCO_REAL=1:
every case spends subscription tokens, so the operator runs it (M-16).
"""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "tests"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from test_agent_work_main_cli_loop_e2e import HOST_ID, LOOP_SESSION, LoopGateway, built_runtime, wait_for  # noqa: E402
from test_agent_work_ruta_viva_e2e import NOTED_OPENCLAW  # noqa: E402
import conducta  # noqa: E402
import brief  # noqa: E402
import contexto  # noqa: E402
import encargo  # noqa: E402
import flota  # noqa: E402
from contracts import OperationKey, RunDir, SessionRecord, operation_id  # noqa: E402
from host import repo_photo  # noqa: E402
from sesion import GroupBoundaryBackend  # noqa: E402
from spool import canonical  # noqa: E402

REAL = os.environ.get("AGENT_WORK_BANCO_REAL") == "1"
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"
OPENCODE = os.environ.get("AGENT_WORK_OPENCODE", "/opt/homebrew/bin/opencode")
# The group whose processes are a case's slot: the macOS group ruta_viva uses, shared with nothing.
SLOT_GROUP = os.environ.get("AGENT_WORK_E2E_SLOT_GROUP", "_appserverusr")
INSTANCE = "enc-1"
BANCO_PLAZO = 900
"""El plazo de resultado del host del banco (R1 de G5c-r3): vence antes que la espera
de cada caso (el plazo por omisión del host, 3600 s, nunca dejaba llegar el incidente
deadline-missed dentro de los 1500 s de espera). La espera se deriva de esta constante."""
# La ruta del playbook dentro del paquete. La copia que conducta lee es la de la corrida
# (runs/<op>/contexto/skills/...) en los casos con paquete, y la de la fuente del paquete
# copiada en un raíz con contexto/ para el control sin paquete: la ruta del repo
# (scripts/agent-work/contexto/skills/...) nunca existió (bots de #304, F7).
PLAYBOOK = "skills/poteto-mode/playbooks/feature.md"
SIN_CONTEXTO = "falta la lectura de contexto/skills/poteto-mode/SKILL.md antes del primer cambio"

BUGGED = '''\
def saluda():
    return "hola"


if __name__ == "__main__":
    print(saluda())
'''
BUGGED_TEST = '''\
import unittest
import saluda


class Pruebas(unittest.TestCase):
    def test_saluda_en_ingles(self):
        self.assertEqual(saluda.saluda(), "hello")


if __name__ == "__main__":
    unittest.main()
'''

FIX_BRIEF = """El repo tiene saluda.py y pruebas con test-saluda.py; la prueba está roja. Haz que pase \
sin cambiar la prueba, con poteto-mode: sigue su playbook feature, deja la lista de pasos con \
todowrite, corre las pruebas después del último cambio y cita su salida en tu resultado. Tu \
asignación trae el protocolo: él dice dónde se escribe tu resultado y su artefacto; síguelo. \
Escribe tu resultado en RESULTADO.md dentro del repo, con la salida de las pruebas citada. \
Entrega el resultado ready.v1 con typedPayload {"evidenceRef": "RESULTADO.md"} y el artefacto \
RESULTADO.md, como lo explica el archivo de asignación (campo protocol).
"""

REVIEW_BRIEF = """Revisa el archivo saluda.py de workspaceRef y entrega review.v1. Tu artefacto va \
dentro de la carpeta de la corrida, nunca dentro de workspaceRef: no escribas nada ahí. Si el \
código tiene un defecto, el veredicto es "changes" y tus hallazgos lo nombran; si está sano, \
"approved". El resultado es review.v1 con typedPayload {"verdict": "approved", "evidenceRef": \
"<hallazgos>"} o {"verdict": "changes", "findingsRef": "<hallazgos>"}, donde <hallazgos> es la \
ruta absoluta de tu artefacto, que lleva tus hallazgos; el artefacto va donde lo dice el campo \
protocol de la asignación, dentro de la carpeta que contiene resultRef, y no tocas el repo.
"""


ADVERSARIO_BRIEF = """Ataca el archivo saluda.py de workspaceRef para probar que está mal: \
saluda() debe devolver "hello". Entrega review.v1. Tu artefacto va dentro de la carpeta de \
la corrida, nunca dentro de workspaceRef: no escribas nada ahí. Si el código tiene un \
defecto, el veredicto es "changes" y tus hallazgos lo nombran; si está sano, "approved". El \
resultado es review.v1 con typedPayload {"verdict": "approved", "evidenceRef": \
"<hallazgos>"} o {"verdict": "changes", "findingsRef": "<hallazgos>"}, donde <hallazgos> es la \
ruta absoluta de tu artefacto, que lleva tus hallazgos; el artefacto va donde lo dice el campo \
protocol de la asignación, dentro de la carpeta que contiene resultRef, y no tocas el repo.
"""

VERIFICACION_BRIEF = """Comprueba con evidencia real que el último commit hace que saluda() \
devuelva "hello": corre las pruebas (python3 test-saluda.py) y cita su salida en tu \
artefacto. Entrega review.v1. Tu artefacto va dentro de la carpeta de la corrida, nunca \
dentro de workspaceRef: no escribas nada ahí. Si las pruebas pasan, el veredicto es \
"approved"; si no, "changes" y tus hallazgos nombran lo que falla. El resultado es review.v1 \
con typedPayload {"verdict": "approved", "evidenceRef": "<hallazgos>"} o {"verdict": \
"changes", "findingsRef": "<hallazgos>"}, donde <hallazgos> es la ruta absoluta de tu \
artefacto, que lleva tus hallazgos con la salida de las pruebas; el artefacto va donde lo \
dice el campo protocol de la asignación, dentro de la carpeta que contiene resultRef, y no \
tocas el repo.
"""

EXPLORACION_BRIEF = """Averigua qué devuelve saluda() y qué espera test-saluda.py, con la \
procedencia (archivo y línea) de cada hecho; no cambies nada. Entrega ready.v1 con \
typedPayload {"evidenceRef": "<hallazgos>"}, donde <hallazgos> es la ruta absoluta de tu \
artefacto, que va donde lo dice el campo protocol de la asignación, dentro de la carpeta \
que contiene resultRef, y no tocas el repo.
"""

EXPLORACION_CAMBIO_BRIEF = """Arregla saluda.py para que devuelva "hello". Entrega ready.v1 \
con typedPayload {"evidenceRef": "<hallazgos>"}, donde <hallazgos> es la ruta absoluta de tu \
artefacto, que va donde lo dice el campo protocol de la asignación, dentro de la carpeta \
que contiene resultRef, y no tocas el repo.
"""

CONTRATOS_DE_RESULTADO = {
    "ready.v1": ({"evidenceRef"},),
    "review.v1": ({"verdict", "evidenceRef"}, {"verdict", "findingsRef"}),
}
"""Los contratos que R valida estrictamente (src/agents/tasks/managed-task.json.ts:100-104),
como conjuntos de claves admitidos por contrato: ready.v1 es {"evidenceRef": <texto no
vacío>}; review.v1 es {"verdict": "approved", "evidenceRef": <texto no vacío>} o
{"verdict": "changes", "findingsRef": <texto no vacío>}; ningún otro campo."""


class Briefs(unittest.TestCase):
    """Los briefs del banco piden como main (A4): cada typedPayload que nombran es un
    objeto con exactamente las claves que R acepta para su contrato. Corre siempre, sin
    AGENT_WORK_BANCO_REAL."""

    def test_los_typed_payload_de_los_briefs_tienen_la_forma_que_r_valida(self):
        for texto, contrato in (
            (FIX_BRIEF, "ready.v1"),
            (REVIEW_BRIEF, "review.v1"),
            (ADVERSARIO_BRIEF, "review.v1"),
            (VERIFICACION_BRIEF, "review.v1"),
            (EXPLORACION_BRIEF, "ready.v1"),
            (EXPLORACION_CAMBIO_BRIEF, "ready.v1"),
        ):
            with self.subTest(contrato=contrato):
                cargas = [json.loads(grupo) for grupo in re.findall(r"\{[^{}]*\}", texto)]
                cargas = [carga for carga in cargas if isinstance(carga, dict)]
                self.assertTrue(cargas, f"el brief no nombra ningún typedPayload de {contrato}")
                for carga in cargas:
                    self.assertIn(
                        set(carga),
                        CONTRATOS_DE_RESULTADO[contrato],
                        f"no es un {contrato} que R acepte",
                    )
                    if "verdict" in carga:
                        self.assertIn(carga["verdict"], ("approved", "changes"))
                    for clave in carga:
                        self.assertIsInstance(carga[clave], str)
                        self.assertTrue(carga[clave].strip(), f"{clave} vacío")

    def test_the_host_deadline_is_shorter_than_the_result_wait(self):
        # R1 de SUA03-G5c-r3: el plazo de resultado del host del banco vence antes
        # que la espera del caso, para que un bucle llegue a deadline-missed.
        from types import SimpleNamespace
        import inspect as _inspect

        banco = BancoE2E.__new__(BancoE2E)
        banco.bin = Path("/tmp/bin")
        banco.spool = Path("/tmp/spool")
        banco.state = Path("/tmp/state")
        banco.root = Path("/tmp/raiz")
        banco.socket = "banco-x"
        banco.gateway = SimpleNamespace(url="http://127.0.0.1:1")
        argv = banco.host_argv()
        indice = argv.index("--result-deadline-seconds")
        espera = _inspect.signature(BancoE2E.wait_result).parameters["seconds"].default
        self.assertEqual(int(argv[indice + 1]), BANCO_PLAZO)
        self.assertLess(BANCO_PLAZO, espera)

    def test_wait_result_names_an_incident_instead_of_waiting_for_the_top(self):
        # R1: con incidentes y sin resultado, wait_result falla nombrando el incidente.
        banco = BancoE2E.__new__(BancoE2E)
        banco.snapshot = lambda task_id: {
            "deliveryState": "registered",
            "incidents": [{"kind": "deadline", "episodeId": "deadline-missed"}],
        }
        with tempfile.TemporaryDirectory() as tmp:
            banco.log = Path(tmp) / "host.log"
            banco.log.write_text("log\n")
            with self.assertRaises(AssertionError) as atrapado:
                banco.wait_result("task-x", seconds=1)
        self.assertIn("deadline", str(atrapado.exception))
        self.assertIn("deadline-missed", str(atrapado.exception))

    def test_a_process_that_survives_the_tmux_kill_gets_term_then_kill(self):
        # R2 de SUA03-G5c-r3: lo que queda en el grupo tras kill-server recibe TERM
        # y, si sigue a los 10 s, KILL; la limpieza termina con el grupo vacío.
        import signal as _signal
        from types import SimpleNamespace

        proceso = SimpleNamespace(pid=4321)
        vivo = {"term": False, "kill": False}
        llamadas = []
        reloj = {"t": 0.0}

        def boundary():
            return () if vivo["kill"] else (proceso,)

        def kill(pid, senal):
            llamadas.append((pid, senal))
            if senal == _signal.SIGKILL:
                vivo["kill"] = True

        def dormir(segundos):
            reloj["t"] += segundos

        matados = matar_procesos_del_slot(
            boundary, kill, espera_term=10.0, paso=0.05,
            reloj=lambda: reloj["t"], dormir=dormir,
        )
        self.assertEqual(
            llamadas, [(4321, _signal.SIGTERM), (4321, _signal.SIGKILL)])
        self.assertEqual(matados, (4321,))
        self.assertEqual(boundary(), ())

    def test_guardar_caso_copies_the_tree_without_git_or_dylib(self):
        # R3 de SUA03-G5c-r3: la evidencia de un caso se copia sin repo/.git y
        # sin *.dylib, para poder mirar un caso rojo sin su temporal.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            raiz = tmp / "caso"
            (raiz / "repo" / ".git").mkdir(parents=True)
            (raiz / "repo" / ".git" / "HEAD").write_text("ref\n")
            (raiz / "repo" / "saluda.py").write_text("def saluda():\n    return 'hola'\n")
            (raiz / "lib.dylib").write_bytes(b"binario")
            (raiz / "state").mkdir()
            (raiz / "state" / "host.log").write_text("log\n")
            (raiz / "state" / "otra.dylib").write_bytes(b"binario")
            destino = guardar_caso(raiz, tmp / "guardados" / "test_x")
            self.assertEqual((destino / "repo" / "saluda.py").exists(), True)
            self.assertEqual((destino / "state" / "host.log").read_text(), "log\n")
            self.assertFalse((destino / "repo" / ".git").exists())
            self.assertFalse((destino / "lib.dylib").exists())
            self.assertFalse((destino / "state" / "otra.dylib").exists())

    def test_the_exploration_outcome_line_names_the_incident_kind(self):
        # R4 de SUA03-G5c-r3: la línea de A6 dice qué desenlace fue, con el kind.
        self.assertEqual(
            desenlace_de({"deliveryState": "result-recorded", "incidents": []}),
            "resultado",
        )
        self.assertEqual(
            desenlace_de({
                "deliveryState": "registered",
                "incidents": [{"kind": "deadline", "episodeId": "deadline-missed"}],
            }),
            "incidente:deadline",
        )

    def test_clean_slot_fails_when_processes_survive_the_kill(self):
        # B2 de G5d: si tras el KILL el grupo sigue con procesos, el caso falla
        # en vez de salir OK y saltar los siguientes en silencio.
        from types import SimpleNamespace
        from unittest import mock

        banco = BancoE2E.__new__(BancoE2E)
        banco.socket = "banco-falso"
        banco.slot = SimpleNamespace(boundary=lambda: (SimpleNamespace(pid=4321),))
        with mock.patch("subprocess.run", return_value=SimpleNamespace(stdout="")):
            with mock.patch.object(
                sys.modules[__name__], "matar_procesos_del_slot", return_value=(4321,)
            ):
                with self.assertRaises(AssertionError) as atrapado:
                    banco.clean_slot()
        self.assertIn("el caso dejó procesos vivos en el slot: 4321", str(atrapado.exception))

    def test_guardar_caso_replaces_a_previous_copy_wholesale(self):
        # B6 de G5d: si el destino ya existe, se reemplaza entero; nada de la
        # corrida anterior queda mezclado con la nueva.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            raiz = tmp / "caso"
            (raiz / "repo").mkdir(parents=True)
            (raiz / "repo" / "saluda.py").write_text("nuevo\n")
            destino = tmp / "guardados" / "test_x"
            (destino / "repo").mkdir(parents=True)
            (destino / "repo" / "saluda.py").write_text("viejo\n")
            (destino / "de-la-anterior.md").write_text("resto\n")
            guardar_caso(raiz, destino)
            self.assertEqual((destino / "repo" / "saluda.py").read_text(), "nuevo\n")
            self.assertFalse((destino / "de-la-anterior.md").exists())

    def test_provenance_names_both_files_with_a_line(self):
        # B7 de G5d: la procedencia de la exploración positiva nombra saluda.py
        # y test-saluda.py, cada uno junto a un número de línea.
        self.assertTrue(
            nombra_procedencia(
                "saluda.py:2 devuelve hola\ntest-saluda.py, línea 5 espera hello\n"))
        self.assertFalse(nombra_procedencia("saluda.py devuelve hola\ntest-saluda.py espera hello\n"))
        self.assertFalse(nombra_procedencia("saluda.py:2 devuelve hola\nla prueba espera hello\n"))

    def test_the_expected_generation_comes_from_the_current_manifest(self):
        # G5d-r3: assert_package_and_flota espera la generación del manifiesto
        # vigente, no un literal: con la generación 2 falló contra flota.json.
        manifiesto = contexto.leer_json(contexto.MANIFIESTO)
        self.assertEqual(generacion_esperada(), manifiesto["generation"])
        self.assertEqual(manifiesto["generation"], 2)

    def test_artifact_path_reads_what_the_host_recorded(self):
        # E: el inspect de R devuelve artifactRef como artifact:<sha256>; la ruta real es
        # la que el host grabó en results/<op>.json.
        with tempfile.TemporaryDirectory() as tmp:
            spool = Path(tmp) / "spool"
            spool.mkdir()
            identidad = operation_id(OperationKey(HOST_ID, "task-e", 1, INSTANCE))
            grabados = spool / "results"
            grabados.mkdir()
            (grabados / f"{identidad}.json").write_text(
                json.dumps({"artifactRef": "/tmp/el-artefacto.md"}), encoding="utf-8"
            )
            banco = BancoE2E.__new__(BancoE2E)
            banco.spool = spool
            self.assertEqual(banco.artifact_path("task-e"), Path("/tmp/el-artefacto.md"))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def generacion_esperada() -> int:
    """La generación que flota.json tiene que anotar: la del manifiesto vigente,
    leída del paquete, nunca un literal (con la 2, el literal 1 hizo fallar dos
    casos buenos del banco)."""
    return contexto.leer_json(contexto.MANIFIESTO)["generation"]


def nombra_procedencia(hallazgos: str) -> bool:
    """La procedencia que pide el brief de exploración (B7 de G5d): saluda.py y
    test-saluda.py, cada uno nombrado junto a un número de línea."""
    return all(
        re.search(rf"{re.escape(nombre)}[^0-9]{{0,20}}\d+", hallazgos)
        for nombre in ("saluda.py", "test-saluda.py")
    )


def desenlace_de(snapshot: dict) -> str:
    """Cómo terminó una tarea que acepta los dos desenlaces (R4 de G5c-r3): el
    resultado, o el incidente con su kind."""
    if snapshot["deliveryState"] == "result-recorded":
        return "resultado"
    return f"incidente:{snapshot['incidents'][0]['kind']}"


def desenlace_de_la_espera(mensaje: str) -> "tuple[str, str]":
    """La causa de una espera que no trajo resultado (F1a): el kind del incidente que el
    mensaje de wait_result nombra, la ventana vencida sin ninguno, o uno que no se dejó
    nombrar. Los kinds que son del modelo la vuelven roja; el resto es del banco."""
    if "terminó en incidente" in mensaje:
        kind = mensaje.split("terminó en incidente", 1)[1].lstrip().split("/", 1)[0]
        if kind in ("launch-failed", "invalid-result", "deadline"):
            return "rojo", kind
        return "infraestructura", "incidente-desconocido"
    if "nunca entregó resultado" in mensaje:
        return "infraestructura", "espera-sin-incidente"
    return "infraestructura", "incidente-desconocido"


def guardar_caso(raiz: Path, destino: Path) -> Path:
    """La evidencia de un caso antes de borrar su temporal (R3 de G5c-r3): copia
    la raíz sin ningún `.git` y sin `*.dylib`, que son lo pesado y lo que no dice
    nada de la corrida."""
    def ignora(dirpath, nombres):
        fuera = set()
        for nombre in nombres:
            ruta = Path(dirpath) / nombre
            if nombre == ".git" and ruta.is_dir():
                fuera.add(nombre)
            elif nombre.endswith(".dylib"):
                fuera.add(nombre)
        return fuera

    if destino.exists():
        shutil.rmtree(destino)
    shutil.copytree(raiz, destino, ignore=ignora, dirs_exist_ok=True)
    return destino


def matar_procesos_del_slot(boundary, kill, *, espera_term=10.0, paso=0.05,
                            reloj=time.monotonic, dormir=time.sleep):
    """Lo que queda en el grupo del slot tras kill-server (R2 de G5c-r3): SIGTERM a
    todo, y SIGKILL a lo que siga vivo a los `espera_term`. Devuelve los pids a los
    que hubo que matar; sin restos, la tupla vacía y ninguna señal."""
    restantes = boundary()
    if not restantes:
        return ()
    matados = tuple(proceso.pid for proceso in restantes)
    for proceso in restantes:
        with contextlib.suppress(ProcessLookupError):
            kill(proceso.pid, signal.SIGTERM)
    limite = reloj() + espera_term
    while boundary() and reloj() < limite:
        dormir(paso)
    restantes = boundary()
    if restantes:
        for proceso in restantes:
            with contextlib.suppress(ProcessLookupError):
                kill(proceso.pid, signal.SIGKILL)
        limite = reloj() + espera_term
        while boundary() and reloj() < limite:
            dormir(paso)
    return matados


@unittest.skipUnless(REAL, "corre el banco real con AGENT_WORK_BANCO_REAL=1: gasta suscripción")
class BancoE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        if not Path(OPENCODE).exists():
            self.skipTest(f"no hay opencode real en {OPENCODE}")
        temp = tempfile.TemporaryDirectory(prefix="agent-work-banco-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        guardar = os.environ.get("AGENT_WORK_BANCO_GUARDAR")
        if guardar:
            # Se registra justo tras el temporal: en la pila de cleanups corre
            # después de parar el host y limpiar el slot, y antes de borrarlo.
            nombre = self.id().rsplit(".", 1)[-1]
            self.addCleanup(lambda: guardar_caso(self.root, Path(guardar) / nombre))
        self.socket = f"banco-{os.getpid()}-{self.id().rsplit('.', 1)[-1][-24:]}"
        try:
            self.slot = GroupBoundaryBackend(TMUX, self.socket, SLOT_GROUP)
        except ValueError as missing:
            self.skipTest(f"{missing}; nombra un grupo de este usuario en AGENT_WORK_E2E_SLOT_GROUP")
        busy = self.slot.boundary()
        if busy:
            self.skipTest(f"el grupo {SLOT_GROUP} tiene procesos vivos y el caso los barrería: "
                          f"{'; '.join(map(str, busy))}")
        self.state = self.root / "state"
        self.spool = self.state / INSTANCE
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # The host launches the real opencode inside the slot's group; openclaw is noted, as in ruta_viva.
        noted = NOTED_OPENCLAW.replace("__R__", str(self.runtime / "openclaw.mjs"))
        (self.bin / "openclaw").write_text(noted)
        (self.bin / "openclaw").chmod(0o755)
        self.repo = self.root / "dev" / "demo"
        self.repo.mkdir(parents=True)
        (self.repo / ".gitignore").write_text("__pycache__/\n")
        (self.repo / "saluda.py").write_text(BUGGED)
        (self.repo / "test-saluda.py").write_text(BUGGED_TEST)
        # El playbook del control sin paquete: copiado de la fuente del paquete (el cache de pstack
        # que los casos con perfil ya necesitan) a una ruta con contexto/, para que conducta derive
        # la misma etiqueta que con la copia de la corrida y no lo tome como error de uso.
        manifiesto = json.loads((ROOT / "scripts/agent-work/contexto/poteto.v1.json").read_text(encoding="utf-8"))
        fuente = contexto.fuente_del_paquete(manifiesto)
        self.playbook_control = self.root / "contexto" / PLAYBOOK
        self.playbook_control.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(fuente / PLAYBOOK, self.playbook_control)
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "base")
        self.photo_before = repo_photo(str(self.repo), ignored=True)
        self.addCleanup(self.clean_slot)
        subprocess.run([TMUX, "-L", self.socket, "-f", "/dev/null", "new-session", "-d", "-s", "keeper", "sleep 600"],
                       check=True, cwd=self.root)
        self.gateway = LoopGateway(self.runtime, self.root, extra_env={"CROSS_HOST_ADAPTER": "opencode"})
        self.addCleanup(self.gateway.close)
        self.log = self.root / "host.log"
        self.addCleanup(self.stop_host)
        self.start_host()
        self.reached((self.state / "host.json").exists, 30, "el host nunca escribió su latido")

    def git(self, *args):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, env=env, capture_output=True)

    def host_argv(self):
        return [sys.executable, str(ROOT / "scripts/agent-work/native_gateway.py"),
                "--openclaw-bin", str(self.bin / "openclaw"), "--host-id", HOST_ID,
                "--expect-url", self.gateway.url, "--host-state-dir", str(self.spool),
                "--state-root", str(self.state), "--evidence-root", str(self.state / "evidence"),
                "--progress-state-dir", str(self.root / "progress"), "--progress-client", "unused", "--watch",
                "--cli-instance-id", INSTANCE, "--cli-tmux-socket", self.socket, "--tmux-bin", TMUX,
                "--workspace-root", str(self.root / "dev"), "--opencode-bin", OPENCODE,
                "--slot-group", SLOT_GROUP, "--canary",
                "--result-deadline-seconds", str(BANCO_PLAZO)]

    def start_host(self):
        """A host over this case's slot, with --canary: the gate is armed and the profiles have no
        competence yet, so the banco would refuse itself without it."""
        with self.log.open("a") as log:
            self.host = subprocess.Popen(
                self.host_argv(),
                cwd=ROOT, env={**self.gateway.env, "LANG": "en_US.UTF-8"}, stdout=log, stderr=subprocess.STDOUT)

    def stop_host(self):
        if self.host.poll() is None:
            self.host.terminate()
            try:
                self.host.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.host.kill()
                self.host.wait()
        return self.host.returncode

    def clean_slot(self):
        socket = subprocess.run([TMUX, "-L", self.socket, "display-message", "-p", "#{socket_path}"],
                                capture_output=True, text=True).stdout.strip()
        subprocess.run([TMUX, "-L", self.socket, "kill-server"], capture_output=True)
        if socket.endswith(f"/{self.socket}"):
            with contextlib.suppress(OSError):
                os.unlink(socket)
        # Un opencode reparentado sobrevive al kill-server en su propio grupo: si
        # queda algo en el grupo del slot se mata aquí, para que el caso siguiente
        # no se salte por procesos vivos ajenos (corrida 4).
        matados = matar_procesos_del_slot(self.slot.boundary, os.kill)
        if matados:
            print(f"BANCO_E2E limpieza=matados:{','.join(str(pid) for pid in matados)}", flush=True)
        deadline = time.monotonic() + 5
        while self.slot.boundary() and time.monotonic() < deadline:
            time.sleep(0.05)
        restantes = self.slot.boundary()
        if restantes:
            # B2 de G5d: un caso que deja procesos vivos no sale OK en silencio
            # mientras los siguientes se saltan por el grupo ocupado.
            self.fail(
                "el caso dejó procesos vivos en el slot: "
                + ",".join(str(proceso.pid) for proceso in restantes)
            )

    def reached(self, predicate, seconds, what):
        value = wait_for(predicate, seconds)
        if not value:
            self.fail(f"{what} en {seconds} s; log del host: {self.log.read_text()[-3000:]}")
        return value

    def ask(self, texto, contract, perfil=None):
        """main asks as it does in production, with or without a profile, and returns the task's id."""
        where = ["--checkout", str(ROOT), "--state-root", str(self.state), "--opencode", OPENCODE,
                 "--workspace-root", str(self.root / "dev")]
        args = ["preparar", "--repo", str(self.repo)]
        # SUA-04 (4.3): el canario de la sucesión pide un modelo exacto, y preparar lo
        # autoriza como ExactModel y lo pone en briefArgs como --model.
        if os.environ.get("AGENT_WORK_BANCO_MODELO"):
            args += ["--modelo", os.environ["AGENT_WORK_BANCO_MODELO"]]
        if perfil:
            args += ["--perfil", perfil]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = encargo.main([*where, *args])
        ready = json.loads(out.getvalue())
        self.assertEqual((code, ready["ok"]), (0, True), ready)
        text = self.root / "brief.txt"
        text.write_text(texto)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = brief.main(["--root", str(self.gateway.state_dir), "--file", str(text),
                               *ready["briefArgs"]])
        self.assertEqual(code, 0)
        fragments = json.loads(out.getvalue())
        request = {"taskKey": f"banco-{contract}-{bool(perfil)}", "assignment": {
            **fragments, "inputRevision": ready["inputRevision"], "resultContract": contract,
            "continuation": {"kind": "requester"}}}
        submitted = self.gateway.tool("submit", request, "banco-submit")
        admitted = self.gateway.tool("admit", {"taskId": submitted["taskId"], "admissionKey": "banco-1"},
                                     "banco-admit")
        self.assertEqual((submitted["state"], admitted["state"]), ("registered", "host-pending"))
        return submitted["taskId"]

    def operation(self, task_id):
        return operation_id(OperationKey(HOST_ID, task_id, 1, INSTANCE))

    def record(self, task_id):
        return SessionRecord.locate(self.spool, self.operation(task_id))

    def run_dir(self, task_id):
        return RunDir(self.spool / "runs" / self.operation(task_id))

    def artifact_path(self, task_id):
        """La ruta real del artefacto: la que grabó el host en results/<op>.json (E). El
        inspect de R devuelve result.artifactRef como artifact:<sha256>, no como ruta."""
        grabado = json.loads(
            (self.spool / "results" / f"{self.operation(task_id)}.json").read_text(
                encoding="utf-8"
            )
        )
        return Path(grabado["artifactRef"])

    def estado(self, task_id):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            encargo.main(["--checkout", str(ROOT), "--state-root", str(self.state), "--opencode", OPENCODE,
                          "estado", "--tarea", task_id])
        return json.loads(out.getvalue())

    def snapshot(self, task_id):
        return self.gateway.tool("inspect", {"taskId": task_id}, "banco-inspect")

    def wait_result(self, task_id, seconds=BANCO_PLAZO + 600):
        """The task reaches a recorded result, or the test fails with what the host and opencode said."""
        def recorded():
            snapshot = self.snapshot(task_id)
            return snapshot if snapshot["deliveryState"] == "result-recorded" or snapshot["incidents"] else None
        snapshot = self.reached(recorded, seconds, f"la tarea {task_id} nunca entregó resultado")
        if snapshot["deliveryState"] != "result-recorded":
            incidente = snapshot["incidents"][0]
            self.fail(
                f"la tarea {task_id} terminó en incidente "
                f"{incidente['kind']}/{incidente['episodeId']} sin resultado; "
                f"log del host: {self.log.read_text()[-3000:]}"
            )
        estado = self.estado(task_id)
        self.assertIsNone(estado["explicacion"], estado["logTail"][-10:])
        return snapshot

    def conducta_verdict(self, task_id, artifact_path, playbook):
        """conducta contra los eventos de la corrida. El playbook es un archivo real: la copia de la
        corrida cuando tuvo paquete, la del control si no."""
        asignacion = json.loads(self.run_dir(task_id).assignment.read_text(encoding="utf-8"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = conducta.main(["--eventos", str(self.record(task_id).events),
                                  "--playbook", str(playbook), "--resultado", str(artifact_path),
                                  "--directorio", asignacion["workspaceRef"],
                                  "--excluir", str(self.run_dir(task_id).path),
                                  "--excluir", str(artifact_path)])
        return code, json.loads(out.getvalue())

    def assert_package_and_flota(self, task_id, specialist):
        run = self.run_dir(task_id)
        self.assertTrue((run.context / "poteto.v1.json").is_file(), "la corrida no tuvo paquete")
        self.assertTrue((run.context / "AGENTS.md").is_file())
        self.assertTrue((run.context / "skills/poteto-mode/SKILL.md").is_file())
        digests = json.loads(self.record(task_id).context.read_text())
        self.assertEqual(set(digests), {"poteto", "tools", "writesSource", "specialist", "generation",
                                        "profile"})
        flota_doc = self.reached(lambda: run.fleet if run.fleet.exists() else None, 120,
                                 "el host nunca escribió flota.json")
        document = json.loads(flota_doc.read_text())
        self.assertEqual((document["specialist"], document["generation"]), (specialist, generacion_esperada()))
        self.assertIsNotNone(document["model"]["id"], f"flota sin modelo usado: {document['model']}")
        self.assertTrue(document["permissions"], "flota sin permisos medidos")
        self.assertEqual(document["attestations"][0], {"what": "poteto", "digest": digests["poteto"]})
        return document

    def assert_run_that_writes_nothing(self, task_id, perfil):
        self.assertEqual(self.photo_changes(), [], "la corrida dejó cambiado el repo real")
        self.assert_package_and_flota(task_id, perfil)
        clone = self.run_dir(task_id).repo
        self.assertFalse(clone.exists(), "el clon de la corrida sobrevivió a su cierre")

    def wait_result_or_incident(self, task_id, seconds=BANCO_PLAZO + 600):
        def settled():
            snapshot = self.snapshot(task_id)
            return snapshot if snapshot["deliveryState"] == "result-recorded" or snapshot["incidents"] else None
        return self.reached(settled, seconds, f"la tarea {task_id} ni entregó resultado ni terminó en incidente")

    def test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for(self):
        # F1a: con AGENT_WORK_BANCO_MODELO el canario lee UNA línea final de desenlace,
        # impresa pase o falle. Cada etapa fija la causa de su fallo antes de correr, y
        # solo el éxito de todas la deja en verde; sin la variable el caso va como hoy.
        canario = bool(os.environ.get("AGENT_WORK_BANCO_MODELO"))
        desenlace = ["infraestructura", "preparar"]
        try:
            task_id = self.ask(FIX_BRIEF, "ready.v1", perfil="ingenieria")
            desenlace[:] = ["infraestructura", "espera-sin-incidente"]
            try:
                snapshot = self.wait_result(task_id)
            except AssertionError as error:
                desenlace[:] = desenlace_de_la_espera(str(error))
                raise
            desenlace[:] = ["infraestructura", "sin-artefacto"]
            artifact = self.artifact_path(task_id)
            self.assertTrue(artifact.is_file())
            desenlace[:] = ["rojo", "conducta"]
            code, verdict = self.conducta_verdict(task_id, artifact, self.run_dir(task_id).context / PLAYBOOK)
            self.assertEqual((code, verdict), (0, {"ok": True, "razones": []}), verdict["razones"])
            desenlace[:] = ["infraestructura", "flota"]
            flota = self.assert_package_and_flota(task_id, "ingenieria")
            if canario:
                desenlace[:] = ["infraestructura", "modelo-distinto"]
                # El canario no sale verde con otro modelo (SUA-04, 4.3): es un fallo del
                # host, no del candidato.
                self.assertEqual(flota["model"]["id"], os.environ["AGENT_WORK_BANCO_MODELO"])
            desenlace[:] = ["rojo", "defecto-sin-arreglar"]
            # ingenieria escribe fuente: su trabajo se ve en el repo, y la suite que estaba roja pasa ahora.
            self.assertNotIn('"hola"', (self.repo / "saluda.py").read_text(), "el modelo no arregló el defecto")
            desenlace[:] = ["rojo", "suite-repo"]
            done = subprocess.run([sys.executable, "test-saluda.py"], cwd=self.repo, capture_output=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
            desenlace[:] = ["verde", "ninguna"]
            print(f"BANCO_E2E case=ingenieria task={task_id} conducta=ok suite_repo=pasa", flush=True)
        finally:
            if canario:
                print(f"BANCO_E2E case=ingenieria desenlace={desenlace[0]} causa={desenlace[1]}", flush=True)

    def test_the_control_without_a_package_is_red_for_the_expected_reason(self):
        task_id = self.ask(FIX_BRIEF, "ready.v1")
        snapshot = self.wait_result(task_id)
        artifact = self.artifact_path(task_id)
        code, verdict = self.conducta_verdict(task_id, artifact, self.playbook_control)
        self.assertEqual(code, 1, "el control sin contexto salió verde")
        self.assertFalse(verdict["ok"])
        self.assertIn(SIN_CONTEXTO, verdict["razones"], verdict["razones"])
        self.assertFalse(self.run_dir(task_id).context.exists(), "el control tuvo paquete")
        print(f"BANCO_E2E case=control task={task_id} conducta=roja razones={verdict['razones']}", flush=True)

    def test_a_reviewer_of_a_broken_repo_names_the_defect_and_leaves_the_repo_as_it_was(self):
        task_id = self.ask(REVIEW_BRIEF, "review.v1", perfil="revision")
        snapshot = self.wait_result(task_id)
        payload = snapshot["result"]["payload"]
        self.assertEqual(payload["verdict"], "changes", payload)
        # Con R validando el payload estricto, el hallazgo viaja en el artefacto, no en el
        # payload (A3): el brief le exige la ruta en findingsRef.
        hallazgos = self.artifact_path(task_id).read_text(encoding="utf-8")
        self.assertIn("hello", hallazgos, "el hallazgo no nombra el defecto sembrado")
        self.assertEqual(self.photo_changes(), [], "el revisor dejó cambiado el repo real")
        self.assert_package_and_flota(task_id, "revision")
        clone = self.run_dir(task_id).repo
        self.assertFalse(clone.exists(), "el clon del revisor sobrevivió a su corrida")
        print(f"BANCO_E2E case=revision-rota task={task_id} verdict=changes", flush=True)

    def test_a_reviewer_of_a_sane_repo_approves_it(self):
        (self.repo / "saluda.py").write_text(BUGGED.replace('"hola"', '"hello"'))
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "arregla")
        self.photo_before = repo_photo(str(self.repo), ignored=True)
        task_id = self.ask(REVIEW_BRIEF, "review.v1", perfil="revision")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["result"]["payload"]["verdict"], "approved")
        self.assertEqual(self.photo_changes(), [])
        print(f"BANCO_E2E case=revision-sana task={task_id} verdict=approved", flush=True)

    def test_an_adversary_of_a_broken_repo_names_the_defect_and_leaves_the_repo_as_it_was(self):
        task_id = self.ask(ADVERSARIO_BRIEF, "review.v1", perfil="adversario")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["result"]["payload"]["verdict"], "changes", snapshot["result"]["payload"])
        hallazgos = self.artifact_path(task_id).read_text(encoding="utf-8")
        self.assertIn("hello", hallazgos, "el hallazgo no nombra el defecto sembrado")
        self.assert_run_that_writes_nothing(task_id, "adversario")
        print(f"BANCO_E2E case=adversario-positiva task={task_id} verdict=changes", flush=True)

    def test_an_adversary_of_a_sane_repo_approves_it(self):
        (self.repo / "saluda.py").write_text(BUGGED.replace('"hola"', '"hello"'))
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "arregla")
        self.photo_before = repo_photo(str(self.repo), ignored=True)
        task_id = self.ask(ADVERSARIO_BRIEF, "review.v1", perfil="adversario")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["result"]["payload"]["verdict"], "approved")
        self.artifact_path(task_id)
        self.assert_run_that_writes_nothing(task_id, "adversario")
        print(f"BANCO_E2E case=adversario-negativa task={task_id} verdict=approved", flush=True)

    def test_a_verifier_of_a_real_fix_approves_it_with_test_evidence(self):
        (self.repo / "saluda.py").write_text(BUGGED.replace('"hola"', '"hello"'))
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "arregla saluda")
        self.photo_before = repo_photo(str(self.repo), ignored=True)
        task_id = self.ask(VERIFICACION_BRIEF, "review.v1", perfil="verificacion")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["result"]["payload"]["verdict"], "approved")
        hallazgos = self.artifact_path(task_id).read_text(encoding="utf-8")
        self.assertIn("OK", hallazgos, "el artefacto no cita la salida de las pruebas")
        self.assert_run_that_writes_nothing(task_id, "verificacion")
        print(f"BANCO_E2E case=verificacion-positiva task={task_id} verdict=approved", flush=True)

    def test_a_verifier_of_a_comment_only_fix_names_it(self):
        (self.repo / "saluda.py").write_text("# solo un comentario\n" + BUGGED)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "arregla saluda")
        self.photo_before = repo_photo(str(self.repo), ignored=True)
        task_id = self.ask(VERIFICACION_BRIEF, "review.v1", perfil="verificacion")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["result"]["payload"]["verdict"], "changes")
        hallazgos = self.artifact_path(task_id).read_text(encoding="utf-8")
        self.assertTrue(
            "hola" in hallazgos or "hello" in hallazgos,
            "el hallazgo no nombra lo que saluda devuelve ni lo esperado",
        )
        self.assert_run_that_writes_nothing(task_id, "verificacion")
        print(f"BANCO_E2E case=verificacion-negativa task={task_id} verdict=changes", flush=True)

    def test_an_explorer_reports_the_facts_and_writes_nothing(self):
        task_id = self.ask(EXPLORACION_BRIEF, "ready.v1", perfil="exploracion")
        snapshot = self.wait_result(task_id)
        self.assertEqual(snapshot["deliveryState"], "result-recorded")
        artefacto = self.artifact_path(task_id)
        self.assertTrue(artefacto.is_file())
        self.assertTrue(
            artefacto.is_relative_to(self.run_dir(task_id).path),
            "el artefacto no está dentro de la carpeta de la corrida",
        )
        hallazgos = artefacto.read_text(encoding="utf-8")
        self.assertIn("hola", hallazgos, "el artefacto no nombra lo que saluda devuelve")
        self.assertIn("hello", hallazgos, "el artefacto no nombra lo que la prueba espera")
        self.assertTrue(
            nombra_procedencia(hallazgos),
            "el artefacto no nombra saluda.py y test-saluda.py con su línea",
        )
        self.assert_run_that_writes_nothing(task_id, "exploracion")
        print(f"BANCO_E2E case=exploracion-positiva task={task_id} resultado=grabado", flush=True)

    def test_an_explorer_asked_to_fix_leaves_the_repo_as_it_was(self):
        task_id = self.ask(EXPLORACION_CAMBIO_BRIEF, "ready.v1", perfil="exploracion")
        snapshot = self.wait_result_or_incident(task_id)
        desenlace = desenlace_de(snapshot)
        if desenlace == "resultado":
            self.artifact_path(task_id)
        self.assertEqual(self.photo_changes(), [], "exploracion dejó cambiado el repo real")
        self.assertIn('"hola"', (self.repo / "saluda.py").read_text(), "exploracion cambió saluda.py")
        self.assert_package_and_flota(task_id, "exploracion")
        self.assertFalse(self.run_dir(task_id).repo.exists(), "el clon de la corrida sobrevivió a su cierre")
        print(f"BANCO_E2E case=exploracion-negativa task={task_id} desenlace={desenlace} repo=igual", flush=True)

    def photo_changes(self):
        after = repo_photo(str(self.repo), ignored=True)
        return [field for field in self.photo_before if self.photo_before[field] != after[field]]


if __name__ == "__main__":
    unittest.main()

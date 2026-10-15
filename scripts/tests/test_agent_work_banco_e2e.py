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


CONTRATOS_DE_RESULTADO = ("ready.v1", "review.v1")
"""Los contratos que R valida estrictamente (src/agents/tasks/managed-task.json.ts:100-104):
ready.v1 es {"evidenceRef": <texto no vacío>}; review.v1 es {"verdict": "approved",
"evidenceRef": <texto no vacío>} o {"verdict": "changes", "findingsRef": <texto no vacío>};
ningún otro campo."""


class Briefs(unittest.TestCase):
    """Los briefs del banco piden como main (A4): cada typedPayload que nombran es un
    objeto con exactamente las claves que R acepta para su contrato. Corre siempre, sin
    AGENT_WORK_BANCO_REAL."""

    def test_los_typed_payload_de_los_briefs_tienen_la_forma_que_r_valida(self):
        for texto, contrato in ((FIX_BRIEF, "ready.v1"), (REVIEW_BRIEF, "review.v1")):
            with self.subTest(contrato=contrato):
                cargas = [json.loads(grupo) for grupo in re.findall(r"\{[^{}]*\}", texto)]
                cargas = [carga for carga in cargas if isinstance(carga, dict)]
                self.assertTrue(cargas, f"el brief no nombra ningún typedPayload de {contrato}")
                for carga in cargas:
                    esperado = (
                        {"evidenceRef"}
                        if contrato == "ready.v1"
                        else (
                            {"verdict", "evidenceRef"}
                            if carga.get("verdict") == "approved"
                            else {"verdict", "findingsRef"}
                        )
                    )
                    self.assertEqual(set(carga), esperado, f"no es un {contrato} que R acepte")
                    if "verdict" in carga:
                        self.assertIn(carga["verdict"], ("approved", "changes"))
                    for clave in esperado:
                        self.assertIsInstance(carga[clave], str)
                        self.assertTrue(carga[clave].strip(), f"{clave} vacío")

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


@unittest.skipUnless(REAL, "corre el banco real con AGENT_WORK_BANCO_REAL=1: gasta suscripción")
class BancoE2E(unittest.TestCase):
    def setUp(self):
        self.runtime = built_runtime(self)
        if not Path(OPENCODE).exists():
            self.skipTest(f"no hay opencode real en {OPENCODE}")
        temp = tempfile.TemporaryDirectory(prefix="agent-work-banco-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
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

    def start_host(self):
        """A host over this case's slot, with --canary: the gate is armed and the profiles have no
        competence yet, so the banco would refuse itself without it."""
        with self.log.open("a") as log:
            self.host = subprocess.Popen(
                [sys.executable, str(ROOT / "scripts/agent-work/native_gateway.py"),
                 "--openclaw-bin", str(self.bin / "openclaw"), "--host-id", HOST_ID,
                 "--expect-url", self.gateway.url, "--host-state-dir", str(self.spool),
                 "--state-root", str(self.state), "--evidence-root", str(self.state / "evidence"),
                 "--progress-state-dir", str(self.root / "progress"), "--progress-client", "unused", "--watch",
                 "--cli-instance-id", INSTANCE, "--cli-tmux-socket", self.socket, "--tmux-bin", TMUX,
                 "--workspace-root", str(self.root / "dev"), "--opencode-bin", OPENCODE,
                 "--slot-group", SLOT_GROUP, "--canary"],
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
        deadline = time.monotonic() + 5
        while self.slot.boundary() and time.monotonic() < deadline:
            time.sleep(0.05)

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

    def wait_result(self, task_id, seconds=1500):
        """The task reaches a recorded result, or the test fails with what the host and opencode said."""
        def recorded():
            snapshot = self.snapshot(task_id)
            return snapshot if snapshot["deliveryState"] == "result-recorded" else None
        snapshot = self.reached(recorded, seconds, f"la tarea {task_id} nunca entregó resultado")
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
        self.assertEqual((document["specialist"], document["generation"]), (specialist, 1))
        self.assertIsNotNone(document["model"]["id"], f"flota sin modelo usado: {document['model']}")
        self.assertTrue(document["permissions"], "flota sin permisos medidos")
        self.assertEqual(document["attestations"][0], {"what": "poteto", "digest": digests["poteto"]})
        return document

    def test_a_profiled_engineering_task_shows_the_behavior_the_design_asks_for(self):
        task_id = self.ask(FIX_BRIEF, "ready.v1", perfil="ingenieria")
        snapshot = self.wait_result(task_id)
        artifact = self.artifact_path(task_id)
        self.assertTrue(artifact.is_file())
        code, verdict = self.conducta_verdict(task_id, artifact, self.run_dir(task_id).context / PLAYBOOK)
        self.assertEqual((code, verdict), (0, {"ok": True, "razones": []}), verdict["razones"])
        self.assert_package_and_flota(task_id, "ingenieria")
        # ingenieria escribe fuente: su trabajo se ve en el repo, y la suite que estaba roja pasa ahora.
        self.assertNotIn('"hola"', (self.repo / "saluda.py").read_text(), "el modelo no arregló el defecto")
        done = subprocess.run([sys.executable, "test-saluda.py"], cwd=self.repo, capture_output=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        print(f"BANCO_E2E case=ingenieria task={task_id} conducta=ok suite_repo=pasa", flush=True)

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

    def photo_changes(self):
        after = repo_photo(str(self.repo), ignored=True)
        return [field for field in self.photo_before if self.photo_before[field] != after[field]]


if __name__ == "__main__":
    unittest.main()

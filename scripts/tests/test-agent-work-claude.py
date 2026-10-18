#!/usr/bin/env python3
"""SUA-04 (4.7, G7): el adaptador claude del host, sin claude ni opencode reales.

Los fixtures son los stream-json reales medidos en M-21/M-23
(~/.local/state/encargos-loop/artifacts/SUA04-G7/, copiados a
scripts/tests/fixtures/agent-work/claude/): p3b (dontAsk niega Write),
p4 y p5 (el sandbox encierra Bash en el cwd y en --add-dir).
"""

import json
import os
import shutil
import sys
import tempfile
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402
import modelos  # noqa: E402
import sesion  # noqa: E402
from contracts import OperationKey, RunDir, SessionRecord, operation_id  # noqa: E402
from sesion import LaunchSpec, Package, Route, Workspace  # noqa: E402

FIXTURES = ROOT / "scripts/tests/fixtures/agent-work/claude"
POLICY = ROOT / "docs/evidence/agent-work/proveedores-permitidos.json"
PERFILES = ROOT / "scripts/agent-work/contexto/perfiles.v1.json"


def spec_claude(tmp, *, perfil=None, herramientas=()):
    policy = modelos.ProviderPolicy.load(POLICY)
    catalog = modelos.catalogo_claude("2.1.301", listed_at=0.0)
    model = modelos.authorize(
        modelos.ExactModel(modelos.ModelId.parse("anthropic/opus")), policy, catalog
    )
    assert isinstance(model, modelos.PermittedModel), model
    run = RunDir(Path(tmp) / "run")
    return LaunchSpec(
        model,
        Workspace(Path(tmp) / "repo"),
        run,
        Path(tmp) / "record",
        "enc-test",
        perfil,
        None,
        None,
        "claude",
        herramientas,
    )


class ArgvYEnv(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = temp.name

    def test_argv_exacto_y_modelo_sin_prefijo_de_proveedor(self):
        spec = spec_claude(self.tmp, herramientas=("Read", "Bash"))
        argv = sesion.adaptador("claude").argv(spec, Path("/bin/claude"), task_id="t-1")
        self.assertEqual(argv[0], "/bin/claude")
        self.assertEqual(argv[1], "-p")
        # La línea de entrega es el segundo argumento, como en opencode.
        self.assertTrue(argv[2].startswith("Open assignment JSON at"), argv[2])
        resto = argv[3:]
        # B1 de G7-r2 (M-24): --setting-sources project carga el settings del repo
        # de trabajo (hooks y permisos extra). --restricted deja solo las de --tools.
        self.assertNotIn("--setting-sources", argv)
        self.assertEqual(
            resto,
            (
                "--model",
                "opus",
                "--output-format",
                "stream-json",
                "--verbose",
                "--permission-mode",
                "dontAsk",
                "--permission-prompts",
                "none",
                "--restricted",
                "--strict-mcp-config",
                "--tools",
                "Read,Bash",
                "--no-session-persistence",
                "--allowed-tools",
                "Read,Bash",
                "--add-dir",
                str(spec.run.path),
                "--settings",
                '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,'
                '"allowUnsandboxedCommands":false}}',
            ),
        )
        # --tools y --allowed-tools llevan la misma lista.
        self.assertEqual(argv[argv.index("--tools") + 1], argv[argv.index("--allowed-tools") + 1])

    def test_el_sandbox_no_deja_desactivar_el_encierro(self):
        spec = spec_claude(self.tmp, herramientas=("Bash",))
        argv = sesion.adaptador("claude").argv(spec, Path("/bin/claude"), task_id="t-1")
        ajustes = json.loads(argv[argv.index("--settings") + 1])
        self.assertIs(ajustes["sandbox"]["enabled"], True)
        self.assertIs(ajustes["sandbox"]["allowUnsandboxedCommands"], False)

    def test_con_perfil_el_argv_suma_el_agents_md_de_la_corrida(self):
        # B3 de G7-r4: sin el AGENTS.md de la corrida, claude nunca leyó la skill
        # ni el playbook del paquete (banco-r3). Con perfil entra el mismo archivo
        # que opencode recibe en instructions (run_config), y existe: el paso de
        # lanzamiento construye el paquete antes de armar el argv.
        agents = Path(self.tmp) / "run" / "contexto" / "AGENTS.md"
        agents.parent.mkdir(parents=True)
        agents.write_text("bloque de la corrida\n", encoding="utf-8")
        spec = spec_claude(self.tmp, perfil={"id": "ingenieria"}, herramientas=("Read",))
        argv = sesion.adaptador("claude").argv(spec, Path("/bin/claude"), task_id="t-1")
        self.assertIn("--append-system-prompt-file", argv)
        ruta = argv[argv.index("--append-system-prompt-file") + 1]
        self.assertEqual(ruta, str(spec.run.context / "AGENTS.md"))
        self.assertTrue(Path(ruta).is_file())

    def test_sin_perfil_el_argv_no_suma_el_agents_md(self):
        # Sin paquete no hay AGENTS.md de corrida que pasar.
        spec = spec_claude(self.tmp, herramientas=("Read",))
        argv = sesion.adaptador("claude").argv(spec, Path("/bin/claude"), task_id="t-1")
        self.assertNotIn("--append-system-prompt-file", argv)

    def test_env_quita_anthropic_api_key_aunque_este(self):
        spec = spec_claude(self.tmp)
        env = sesion.adaptador("claude").env(spec)
        # None es la marca de "unset" en el script de lanzamiento.
        self.assertIn("ANTHROPIC_API_KEY", env)
        self.assertIsNone(env["ANTHROPIC_API_KEY"])
        script = sesion.launch_script(spec, ("claude",), env, 20)
        self.assertIn("unset ANTHROPIC_API_KEY", script)

    def test_la_carpeta_es_el_workspace_y_el_lanzador_hace_cd(self):
        spec = spec_claude(self.tmp)
        adaptador = sesion.adaptador("claude")
        self.assertEqual(adaptador.carpeta(spec), spec.workspace.root)
        script = sesion.launch_script(
            spec, adaptador.argv(spec, Path("/bin/claude"), task_id="t-1"), adaptador.env(spec), 20
        )
        self.assertIn(f"cd -- {spec.workspace.root}", script)

    def test_opencode_sigue_igual_por_el_registro(self):
        spec = spec_claude(self.tmp)
        adaptador = sesion.adaptador("opencode")
        self.assertEqual(
            adaptador.argv(spec, Path("/bin/opencode"), task_id="t-1"),
            sesion.opencode_argv(spec, Path("/bin/opencode"), task_id="t-1"),
        )
        self.assertEqual(adaptador.env(spec), sesion.opencode_env(spec))
        self.assertEqual(adaptador.carpeta(spec), spec.workspace.root)


class LeerEventos(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)

    def eventos(self, fixture):
        record = self.tmp / "record"
        record.mkdir(exist_ok=True)
        (record / "events.jsonl").write_text(
            (FIXTURES / fixture).read_text(encoding="utf-8"), encoding="utf-8"
        )
        (record / "stderr.log").write_text("", encoding="utf-8")
        return sesion.adaptador("claude").leer_eventos(record)

    def test_p3b_modelo_permisos_y_carpeta(self):
        eventos = self.eventos("p3b.jsonl")
        self.assertIsNotNone(eventos)
        self.assertEqual(
            eventos.session_directory, "/Users/dn/.local/state/sua-loop/mediciones/m21/a"
        )
        self.assertEqual(eventos.providers_called, ("anthropic",))
        self.assertIn(
            sesion.ModelCall("build", "anthropic/claude-sonnet-5-5", False), eventos.calls
        )
        self.assertEqual([d.permission for d in eventos.denied], ["Write"])
        self.assertIn("hola.txt", eventos.denied[0].pattern)
        self.assertIn("Write:deny", eventos.evaluations)

    def test_p4_sin_negaciones_y_con_bash_permitido(self):
        eventos = self.eventos("p4.jsonl")
        self.assertEqual(eventos.denied, ())
        self.assertIn("Bash:allow", eventos.evaluations)

    def test_la_herramienta_negada_no_queda_tambien_como_allow(self):
        # LOW de G7-r2: el Write de p3b fue negado (permission_denials); no puede
        # quedar también como :allow en las evaluaciones.
        eventos = self.eventos("p3b.jsonl")
        self.assertIn("Write:deny", eventos.evaluations)
        self.assertNotIn("Write:allow", eventos.evaluations)


class ModeloEnUso(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)

    def eventos_de(self, texto):
        record = self.tmp / "record"
        record.mkdir(exist_ok=True)
        (record / "events.jsonl").write_text(texto, encoding="utf-8")
        (record / "stderr.log").write_text("", encoding="utf-8")
        return sesion.adaptador("claude").leer_eventos(record)

    def test_un_modelo_distinto_al_pedido_lo_dice(self):
        # M1 de G7-r2: se pidió opus y corrió sonnet; la corrida lo tiene que decir.
        texto = "\n".join(
            json.dumps(d)
            for d in (
                {"type": "system", "subtype": "init", "cwd": "/w", "model": "claude-sonnet-5-5"},
                {
                    "type": "assistant",
                    "parent_tool_use_id": None,
                    "message": {"model": "claude-sonnet-5-5", "content": []},
                },
                {
                    "type": "result",
                    "subtype": "success",
                    "is_error": False,
                    "modelUsage": {"claude-sonnet-5-5": {}},
                    "permission_denials": [],
                },
            )
        )
        eventos = self.eventos_de(texto)
        usado, razon = sesion.adaptador("claude").modelo_en_uso(eventos, "anthropic/opus")
        self.assertEqual(
            (usado, razon),
            (None, "claude usó anthropic/claude-sonnet-5-5 y se pidió anthropic/opus"),
        )
        # El alias que sí corrió no dice nada: claude-sonnet-5-5 contiene sonnet.
        usado, razon = sesion.adaptador("claude").modelo_en_uso(eventos, "anthropic/sonnet")
        self.assertEqual((usado, razon), ("anthropic/claude-sonnet-5-5", None))


class PlanClaude(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.perfiles = contexto.leer_json(PERFILES)
        manifiesto = contexto.leer_json(ROOT / "scripts/agent-work/contexto/poteto.v1.json")
        self.package = Package(manifiesto, self.perfiles, contexto.fuente_del_paquete(manifiesto))
        self.coverage = {
            "hostAdapterRoute": {
                "mac-local": {
                    "opencode": {"form": "run-per-task", "certifiedCliVersions": {"1.18.35": "x"}},
                    "claude": {"form": "run-per-task", "certifiedCliVersions": {"2.1.301": "M-21"}},
                }
            },
            "hostAdapterCoverage": {
                "mac-local": {"opencode": "certified", "claude": "sandbox-tested-uncertified"}
            },
        }

    def plan(self, perfil, contrato="ready.v1"):
        route = Route.load(self.coverage, "mac-local", "claude")
        policy = modelos.ProviderPolicy.load(POLICY)
        catalog = modelos.catalogo_claude("2.1.301", listed_at=0.0)
        brief = (
            f"agent-work.launch.v1\nmodel: anthropic/opus\nprofile: {perfil}\n---\nhaz\n".encode()
        )
        (self.tmp / "run").mkdir(exist_ok=True)
        return sesion.plan_launch(
            {"inputRevision": {"kind": "artifact"}, "resultContract": contrato},
            brief,
            policy=policy,
            catalog=catalog,
            route=route,
            cli_version="2.1.301",
            allowed_root=self.tmp,
            run=RunDir(self.tmp / "run"),
            record=self.tmp / "record",
            operation="a" * 64,
            canary=True,
            package=self.package,
            now=datetime.now(timezone.utc),
            state_root=self.tmp,
        )

    def test_ruta_claude_sin_certificar_y_con_canario(self):
        ruta = Route.load(self.coverage, "mac-local", "claude")
        self.assertEqual((ruta.adapter_id, ruta.status), ("claude", "sandbox-tested-uncertified"))
        self.assertIsInstance(ruta.open_for("2.1.301", canary=False), modelos.RouteNotCertified)
        self.assertIsNone(ruta.open_for("2.1.301", canary=True))

    def test_ingenieria_lleva_sus_herramientas_claude_y_sin_config_opencode(self):
        plan = self.plan("ingenieria")
        self.assertIsInstance(plan, LaunchSpec, plan)
        self.assertEqual(plan.adapter_id, "claude")
        esperado = tuple(
            next(
                p["requiredTools"]["claude"]
                for p in self.perfiles["profiles"]
                if p["id"] == "ingenieria"
            )
        )
        self.assertEqual(plan.herramientas, esperado)
        self.assertIsNone(plan.config)

    def test_revision_no_recibe_edit_ni_write(self):
        plan = self.plan("revision", "review.v1")
        self.assertIsInstance(plan, LaunchSpec, plan)
        self.assertNotIn("Edit", plan.herramientas)
        self.assertNotIn("Write", plan.herramientas)
        # B1 de G7-r2: tampoco en el --tools del argv, que es lo que existe de verdad.
        spec = spec_claude(self.tmp, herramientas=plan.herramientas)
        argv = sesion.adaptador("claude").argv(spec, Path("/bin/claude"), task_id="t-1")
        tools = argv[argv.index("--tools") + 1].split(",")
        self.assertNotIn("Edit", tools)
        self.assertNotIn("Write", tools)


class BinarioDeClaude(unittest.TestCase):
    """El canario vivo de G7 (2026-10-16): el exec de main corre sin ~/.local/bin en el
    PATH, `which claude` no lo encuentra y preparar contestaba que la Mac no decía su
    versión. Sin variable ni PATH, el binario es el de ~/.local/bin, donde lo instala
    Claude Code, como opencode es /opt/homebrew/bin/opencode."""

    def test_sin_path_se_usa_el_de_local_bin(self):
        with tempfile.TemporaryDirectory() as casa:
            local = Path(casa) / ".local/bin/claude"
            local.parent.mkdir(parents=True)
            local.write_text("#!/bin/sh\n")
            local.chmod(0o755)
            entorno = {"HOME": casa, "PATH": "/usr/bin:/bin"}
            with mock.patch.dict(os.environ, entorno, clear=True):
                self.assertEqual(modelos.claude_por_omision(), local)
            with mock.patch.dict(
                os.environ, {**entorno, "AGENT_WORK_CLAUDE": "/otro/claude"}, clear=True
            ):
                self.assertEqual(modelos.claude_por_omision(), Path("/otro/claude"))

    def test_la_frase_de_ruta_no_certificada_nombra_al_cli_de_la_ruta(self):
        # El canario dijo "la Mac tiene opencode sin contestar su versión" para la ruta claude.
        for versiones in (("2.1.301",), ()):
            with self.subTest(versiones=versiones):
                caso = modelos.RouteNotCertified("sin contestar su versión", versiones, "claude")
                frase, _ = modelos._frase_ruta(caso)
                self.assertIn("claude", frase)
                self.assertNotIn("opencode", frase)
        frase, _ = modelos._frase_ruta(modelos.RouteNotCertified("1.18.36", ("1.18.35",)))
        self.assertIn("opencode 1.18.36", frase)


class HostClaude(unittest.TestCase):
    """El RunHost planea una corrida claude con un binario falso que solo sabe
    contestar su versión: ningún modelo corre."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.checkout = self.tmp / "checkout"
        evidencia = self.checkout / "docs/evidence/agent-work"
        evidencia.mkdir(parents=True)
        for nombre in ("proveedores-permitidos.json", "coverage.json"):
            shutil.copy(ROOT / "docs/evidence/agent-work" / nombre, evidencia / nombre)
        contexto_dir = self.checkout / "scripts/agent-work/contexto"
        contexto_dir.mkdir(parents=True)
        for nombre in ("poteto.v1.json", "generaciones.json", "perfiles.v1.json"):
            shutil.copy(ROOT / "scripts/agent-work/contexto" / nombre, contexto_dir / nombre)
        self.claude_falso = self.tmp / "claude"
        self.claude_falso.write_text(
            '#!/bin/sh\ncase "$*" in --version) echo "2.1.301 (Claude Code)";; *) exit 64;; esac\n'
        )
        self.claude_falso.chmod(0o755)

    def run_host(self, *, clock=None, host=None):
        from native_gateway import RunHost

        return RunHost(
            types.SimpleNamespace(host_id="mac-local"),
            host,
            None,
            None,
            instance_id="enc-1",
            checkout=self.checkout,
            state_root=self.tmp / "state",
            opencode_bin=Path("/bin/true"),
            claude_bin=self.claude_falso,
            allowed_root=self.tmp,
            canary=True,
            clock=clock or (lambda: 1000.0),
        )

    def test_el_host_planea_y_arma_el_argv_de_claude(self):
        # El plan del host lee la fuente real del paquete (las skills de pstack de esta
        # Mac); el runner de CI no la tiene (CI de #324), como las pruebas de ruta viva.
        manifiesto = contexto.leer_json(ROOT / "scripts/agent-work/contexto/poteto.v1.json")
        fuente = contexto.fuente_del_paquete(manifiesto)
        faltan = [
            a["path"]
            for a in manifiesto.get("files", ())
            if isinstance(a, dict) and not (Path(fuente) / a.get("path", "")).is_file()
        ]
        if not Path(fuente).is_dir() or faltan:
            self.skipTest(f"sin la fuente del paquete en {fuente}")
        run_host = self.run_host()
        (self.tmp / "run").mkdir(exist_ok=True)
        plan = run_host.plan(
            {"inputRevision": {"kind": "artifact"}, "resultContract": "ready.v1"},
            b"agent-work.launch.v1\nmodel: anthropic/opus\nprofile: ingenieria\n---\nhaz\n",
            run=RunDir(self.tmp / "run"),
            record=self.tmp / "record",
            operation="a" * 64,
            adapter_id="claude",
        )
        self.assertIsInstance(plan, LaunchSpec, plan)
        self.assertEqual(plan.adapter_id, "claude")
        argv = sesion.adaptador("claude").argv(plan, run_host.bin_para("claude"), task_id="t-1")
        self.assertEqual(argv[0], str(self.claude_falso))
        self.assertEqual(argv[argv.index("--model") + 1], "opus")
        self.assertEqual(run_host.bin_para("opencode"), Path("/bin/true"))

    def test_un_version_fallido_no_se_guarda(self):
        # CodeRabbit en #324: un `claude --version` que falló una vez no deja la ruta
        # cerrada para siempre; la pasada siguiente vuelve a preguntar.
        run_host = self.run_host()
        bueno = self.claude_falso
        run_host.claude_bin = self.tmp / "no-existe"
        self.assertEqual(run_host.catalogo_para("claude").cli_version, "sin contestar su versión")
        run_host.claude_bin = bueno
        self.assertEqual(run_host.catalogo_para("claude").cli_version, "2.1.301")

    def test_la_version_de_claude_se_relee_pasada_la_ventana(self):
        # DeepSeek F7 en #324: el host es un demonio; un `claude update` cambia la versión.
        import native_gateway

        reloj = {"t": 1000.0}
        run_host = self.run_host(clock=lambda: reloj["t"])
        self.assertEqual(run_host.catalogo_para("claude").cli_version, "2.1.301")
        self.claude_falso.write_text(
            '#!/bin/sh\ncase "$*" in --version) echo "2.1.400 (Claude Code)";; *) exit 64;; esac\n'
        )
        self.assertEqual(run_host.catalogo_para("claude").cli_version, "2.1.301")
        reloj["t"] += native_gateway.CATALOG_RECHECK_SECONDS
        self.assertEqual(run_host.catalogo_para("claude").cli_version, "2.1.400")

    def test_un_claim_no_autorizado_no_corta_la_pasada(self):
        # B2 de G7-r3: el gateway autoriza por host una lista de adaptadores; si
        # opencode no esta en la de este host, su rechazo no puede matar el claim
        # de claude (y al reves en vivo: la Mini hoy solo autoriza opencode).
        import native_gateway

        reloj = {"t": 1000.0}
        run_host = self.run_host(clock=lambda: reloj["t"])
        pedidos = []

        def claim_falso(client, *, host, manager, backend, instance_id, deps, adapter_id):
            pedidos.append(adapter_id)
            if adapter_id == "opencode":
                raise RuntimeError(
                    "native projection Gateway rejected request managedTasks.host.claim: "
                    "Managed host device or adapter is not authorized"
                )
            return f"reclamada-{adapter_id}"

        with mock.patch.object(native_gateway, "claim_run_once", claim_falso):
            self.assertEqual(run_host.claim(), "reclamada-claude")
            self.assertEqual(pedidos, ["opencode", "claude"])
            # En la misma ventana no se vuelve a pedir el adaptador rechazado.
            pedidos.clear()
            self.assertEqual(run_host.claim(), "reclamada-claude")
            self.assertEqual(pedidos, ["claude"])
            # Pasada la ventana de reintento, se vuelve a probar.
            reloj["t"] += native_gateway.CATALOG_RECHECK_SECONDS + 1
            pedidos.clear()
            self.assertEqual(run_host.claim(), "reclamada-claude")
            self.assertEqual(pedidos, ["opencode", "claude"])

    def test_si_ningun_adaptador_esta_autorizado_el_rechazo_sale(self):
        # DeepSeek F2 en #324: R da la misma frase para un device no autorizado. Si
        # ningún adaptador pasa, no es un adaptador fuera de la lista: es el host, y
        # el rechazo sale por la pasada como antes de G7.
        import native_gateway

        run_host = self.run_host()

        def claim_rechazado(client, *, host, manager, backend, instance_id, deps, adapter_id):
            raise RuntimeError(
                "native projection Gateway rejected request managedTasks.host.claim: "
                "Managed host device or adapter is not authorized"
            )

        with mock.patch.object(native_gateway, "claim_run_once", claim_rechazado):
            with self.assertRaisesRegex(RuntimeError, "not authorized"):
                run_host.claim()

    def test_la_frase_fuera_del_claim_no_se_toma_por_un_adaptador(self):
        # DeepSeek F2 en #324: la frase en un error que no es el del claim de R (el
        # plan, el paquete, el lanzamiento) sale como siempre.
        import native_gateway

        run_host = self.run_host()

        def plan_roto(client, *, host, manager, backend, instance_id, deps, adapter_id):
            # Solo opencode falla, y claude tendría tarea: si la frase se tomara por un
            # adaptador rechazado, el error se tragaría y saldría la tarea de claude.
            if adapter_id == "opencode":
                raise RuntimeError("el paquete dice: adapter is not authorized")
            return "reclamada-claude"

        with mock.patch.object(native_gateway, "claim_run_once", plan_roto):
            with self.assertRaisesRegex(RuntimeError, "el paquete dice"):
                run_host.claim()

    def test_un_error_de_otra_clase_en_el_claim_sigue_saliendo(self):
        import native_gateway

        run_host = self.run_host()

        def claim_roto(client, *, host, manager, backend, instance_id, deps, adapter_id):
            raise RuntimeError("el gateway no contesto")

        with mock.patch.object(native_gateway, "claim_run_once", claim_roto):
            with self.assertRaisesRegex(RuntimeError, "el gateway no contesto"):
                run_host.claim()

    def test_session_directory_sale_del_adapter_del_claim_no_del_argv(self):
        # M2 de G7-r3: un record de opencode cuyo argv trae --model se lee con
        # opencode: el adaptador sale de lo que el host guardo del claim.
        spool_falso = types.SimpleNamespace(
            get=lambda operation: {"operation_json": json.dumps({"adapterId": "opencode"})}
        )
        state_dir = self.tmp / "spool"
        host_falso = types.SimpleNamespace(state_dir=state_dir, spool=spool_falso)
        run_host = self.run_host(host=host_falso)
        key = OperationKey("mac-local", "t-1", 1, "enc-1")
        record = SessionRecord.locate(state_dir, operation_id(key))
        record.path.mkdir(parents=True)
        (record.argv).write_text(json.dumps(["/bin/claude", "--model", "opus"]), encoding="utf-8")
        (record.events).write_text(
            json.dumps(
                {
                    "type": "system",
                    "subtype": "init",
                    "cwd": "/carpeta-de-claude",
                    "model": "claude-sonnet-5-5",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (record.stderr).write_text(
            "timestamp=2026-10-13T00:57:58.663Z level=INFO run=x message=created "
            'id=ses_abc directory=/carpeta-de-opencode path="" workspaceID=undefined\n',
            encoding="utf-8",
        )
        self.assertEqual(run_host._session_directory(key), "/carpeta-de-opencode")


class Harness(unittest.TestCase):
    def test_el_harness_autoriza_la_lista_de_adaptadores(self):
        # B2 (b) de G7-r3: CROSS_HOST_ADAPTER acepta una lista separada por comas.
        harness = (
            ROOT / "scripts/tests/fixtures/agent-work/managed-cli-gateway-harness.mjs"
        ).read_text(encoding="utf-8")
        self.assertIn('.split(",")', harness)
        self.assertIn("adapters: hostAdapters", harness)


if __name__ == "__main__":
    unittest.main()

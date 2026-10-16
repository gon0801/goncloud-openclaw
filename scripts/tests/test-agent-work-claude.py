#!/usr/bin/env python3
"""SUA-04 (4.7, G7): el adaptador claude del host, sin claude ni opencode reales.

Los fixtures son los stream-json reales medidos en M-21/M-23
(~/.local/state/encargos-loop/artifacts/SUA04-G7/, copiados a
scripts/tests/fixtures/agent-work/claude/): p3b (dontAsk niega Write),
p4 y p5 (el sandbox encierra Bash en el cwd y en --add-dir).
"""

import shutil
import sys
import tempfile
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402
import modelos  # noqa: E402
import sesion  # noqa: E402
from contracts import RunDir  # noqa: E402
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
                "--setting-sources",
                "project",
                "--no-session-persistence",
                "--allowed-tools",
                "Read,Bash",
                "--add-dir",
                str(spec.run.path),
                "--settings",
                '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}',
            ),
        )

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

    def test_el_host_planea_y_arma_el_argv_de_claude(self):
        from native_gateway import RunHost

        run_host = RunHost(
            types.SimpleNamespace(host_id="mac-local"),
            None,
            None,
            None,
            instance_id="enc-1",
            checkout=self.checkout,
            state_root=self.tmp / "state",
            opencode_bin=Path("/bin/true"),
            claude_bin=self.claude_falso,
            allowed_root=self.tmp,
            canary=True,
        )
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


if __name__ == "__main__":
    unittest.main()

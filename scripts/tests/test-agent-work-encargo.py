#!/usr/bin/env python3
"""encargo.py as `main` and the operator call it: one command line in, one answer and an exit code out.

Each case runs in its own checkout copy, state root, prompt store and opencode double. The double answers
`--version` and `models` from two files and keeps every argv it received.
"""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import encargo  # noqa: E402
from modelos import ExactModel, ModelId, PermittedModel, ProviderPolicy, authorize, Catalog  # noqa: E402
from sesion import LaunchHeader  # noqa: E402

EVIDENCE = Path("docs/evidence/agent-work")
LISTING = (ROOT / "scripts/tests/fixtures/agent-work/opencode/models-1.18.35.txt").read_text()
OPENCODE_DOUBLE = """#!/bin/sh
here=$(dirname "$0")
printf '%s\\n' "$*" >> "$here/argv.log"
case "$*" in
  --version) cat "$here/version" ;;
  models|"models --refresh") if [ -e "$here/before-listing" ]; then . "$here/before-listing"; fi; cat "$here/listing" ;;
  *) exit 64 ;;
esac
"""
PROMPTS = {
    200: ("2026-10-01T07:00:00.000Z", "un texto antiguo cualquiera, de antes de todo esto"),
    10866: ("2026-10-12T23:42:35.842Z", "1 acepto 2. cualquiera 3. 1 hora SECRETO-sk-prueba-123"),
    10867: ("2026-10-12T23:47:47.629Z", "bla, de opencode solo tengo go, bla SECRETO-sk-prueba-456"),
    10886: ("2026-10-13T01:13:22.117Z", "sobre qwen hay forma de dejar solo los modelos qwen? gracias"),
    10890: ("2026-10-13T01:40:00.000Z", "sí, esos seis modelos de qwen están bien"),
    10901: ("2026-10-14T10:00:00.000Z", "ok, permite mistral para por CLI, cobra por suscripción"),
    10902: ("2026-10-15T08:00:00.000Z", "cierra muse para encargos, ya no lo pago"),
    10903: ("2026-10-16T09:00:00.000Z", "reabre opencode go para encargos, ya tengo cuota de sobra"),
    30001: ("2026-10-20T09:00:00.000Z", "recuerda: open code go es solamente para main, ya lo dije"),
    30010: ("2026-10-21T09:00:00.000Z", "pero tengo deepseek por api, eso sí"),
}
DEFAULT_BRIEF_ARGS = ["--host", "mac-local", "--adapter", "opencode", "--model", "zai-coding-plan/glm-5.3-flash"]


class Mac(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.checkout = self.root / "checkout"
        (self.checkout / EVIDENCE).mkdir(parents=True)
        for name in ("proveedores-permitidos.json", "coverage.json"):
            shutil.copy(ROOT / EVIDENCE / name, self.checkout / EVIDENCE / name)
        contexto_dir = self.checkout / "scripts" / "agent-work" / "contexto"
        contexto_dir.mkdir(parents=True)
        for name in ("poteto.v1.json", "generaciones.json", "perfiles.v1.json"):
            shutil.copy(ROOT / "scripts/agent-work/contexto" / name, contexto_dir / name)
        # The fixture certifies the current generation (2 since G5d; 1 stays
        # certified in the real coverage by M-16): a profiled pedido without a
        # canary would otherwise stop at the generation gate, not at the profile.
        coverage_path = self.checkout / EVIDENCE / "coverage.json"
        coverage = json.loads(coverage_path.read_text())
        coverage["hostAdapterRoute"]["mac-local"]["opencode"]["contextGenerations"] = {"2": "fixture"}
        coverage_path.write_text(json.dumps(coverage))
        self.policy_path = self.checkout / EVIDENCE / "proveedores-permitidos.json"
        self.state = self.root / "state"
        self.state.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "opencode").write_text(OPENCODE_DOUBLE)
        (self.bin / "opencode").chmod(0o755)
        (self.bin / "version").write_text("1.18.35\n")
        (self.bin / "listing").write_text(LISTING)
        self.repo = self.root / "dev" / "demo"
        self.repo.mkdir(parents=True)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        for command in (["init", "-q"], ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q",
                                         "--allow-empty", "-m", "base"]):
            subprocess.run(["git", "-C", str(self.repo), *command], check=True, env=env, capture_output=True)
        self.head = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], check=True, env=env,
                                   capture_output=True, text=True).stdout.strip()
        self.prompts = self.root / "prompts.db"
        with contextlib.closing(sqlite3.connect(self.prompts)) as db, db:
            db.execute("CREATE TABLE user_prompts (id INTEGER PRIMARY KEY, prompt_text TEXT NOT NULL, "
                       "created_at TEXT NOT NULL)")
            db.executemany("INSERT INTO user_prompts VALUES (?, ?, ?)",
                           [(ref, text, created) for ref, (created, text) in PROMPTS.items()])

    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = encargo.main(["--checkout", str(self.checkout), "--state-root", str(self.state),
                                 "--opencode", str(self.bin / "opencode"), "--workspace-root", str(self.root / "dev"),
                                 *args], prompts=self.prompts)
        return code, out.getvalue(), err.getvalue()

    def preparar(self, *args, repo=True):
        code, out, err = self.cli("preparar", *(("--repo", str(self.repo)) if repo else ()), *args)
        self.assertEqual(len(out.splitlines()), 1, out + err)
        answer = json.loads(out)
        self.assertEqual(code, 0 if answer["ok"] else 3)
        return answer

    def policy(self):
        return ProviderPolicy.load(self.policy_path)

    def edit_policy(self, change):
        document = json.loads(self.policy_path.read_text())
        change(document)
        self.policy_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")

    def sandbox_tested(self):
        """The checkout's coverage with the route not certified yet, or with its certification reverted."""
        path = self.checkout / EVIDENCE / "coverage.json"
        coverage = json.loads(path.read_text())
        coverage["hostAdapterCoverage"]["mac-local"]["opencode"] = "sandbox-tested-uncertified"
        path.write_text(json.dumps(coverage))

    def beat(self, **changes):
        beat = {"pid": 4242, "startedAt": time.time() - 600, "beatAt": time.time() - 3, "checkout": str(self.checkout),
                "commit": "c" * 40, "cliVersion": "1.18.35", "policyDigest": self.policy().digest, "slot": "free",
                "blockedBy": [], "taskId": None, "model": None, "since": None, "spool": str(self.state / "enc-1"),
                "canary": False, **changes}
        (self.state / "host.json").write_text(json.dumps(beat))

    def argv_log(self):
        return (self.bin / "argv.log").read_text().splitlines()


class Proveedores(Mac):
    def test_the_table_has_one_row_per_grant_and_closure_with_what_opencode_lists_today(self):
        rows = encargo.proveedores(state_root=self.state, checkout=self.checkout, opencode_bin=self.bin / "opencode")
        self.assertEqual([(row.name, row.provider, row.decision, row.billing, row.session, row.listed_models,
                           row.permitted_models, row.cited) for row in rows], [
            ("glm", "zai-coding-plan", "permitido", "subscription", "con-sesion", 7, 7, "David 2026-10-03 P9830"),
            ("claude", "anthropic", "permitido", "subscription", "sin-sesion", 0, 0, "David 2026-10-12 P10868"),
            ("grok", "xai", "permitido", "subscription", "con-sesion", 13, 13, "David 2026-10-12 P10868"),
            ("gpt", "openai", "permitido", "subscription", "con-sesion", 24, 24, "David 2026-10-12 P10867"),
            ("muse", "meta", "permitido", "subscription", "con-sesion", 6, 6, "David 2026-10-12 P10867"),
            ("kimi", "kimi-code-plan-cn", "permitido", "subscription", "con-sesion", 4, 4, "David 2026-10-12 P10867"),
            ("qwen", "alibaba-token-plan", "permitido", "subscription", "con-sesion", 27, 6,
             "David 2026-10-12 P10867"),
            ("deepseek", "deepseek", "permitido", "per-token", "con-sesion", 2, 2, "David 2026-10-12 P10847"),
            (None, "opencode-go", "cerrado", None, "con-sesion", 31, 0, "David 2026-10-12 P10845"),
            (None, "opencode", "cerrado", None, "con-sesion", 84, 0, "David 2026-10-12 P10867"),
            (None, "zai", "cerrado", None, "con-sesion", 18, 0, "David 2026-10-03 P9840"),
        ])

    def test_the_command_prints_the_table_and_runs_only_the_two_listing_commands(self):
        code, out, _ = self.cli("proveedores")
        lines = out.splitlines()
        self.assertEqual((code, len(lines)), (0, 12))
        self.assertEqual(lines[0].split(), ["nombre", "proveedor", "decisión", "cobro", "sesión", "lista", "entran",
                                            "línea", "desde", "efectivo", "cita"])
        self.assertEqual(lines[7].split(), ["qwen", "alibaba-token-plan", "permitido", "subscription", "con-sesion",
                                            "27", "6", "-", "-", "-", "David", "2026-10-12", "P10867"])
        self.assertEqual(lines[9].split(), ["-", "opencode-go", "cerrado", "-", "con-sesion", "31", "-", "-", "-",
                                            "-", "David", "2026-10-12", "P10845"])
        self.assertNotIn("sin-decision", out)
        self.assertEqual(self.argv_log(), ["--version", "models"])
        self.cli("proveedores")
        self.assertEqual(self.argv_log(), ["--version", "models", "--version"])

    def test_a_provider_opencode_lists_without_a_decision_gets_its_own_row(self):
        (self.bin / "listing").write_text(LISTING + "mistral/large-3\nmistral/small-3\n")
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        rows = encargo.proveedores(state_root=self.state, checkout=self.checkout, opencode_bin=self.bin / "opencode")
        self.assertEqual([(row.name, row.provider, row.decision, row.session, row.listed_models) for row in rows[11:]],
                         [(None, "kimi-code-plan-cn", "sin-decision", "con-sesion", 4),
                          (None, "mistral", "sin-decision", "con-sesion", 2)])
        self.assertEqual((rows[5].name, rows[5].provider, rows[5].session), ("kimi", None, "sin-id"))
        code, out, _ = self.cli("proveedores")
        self.assertEqual(out.splitlines()[6].split()[:6], ["kimi", "(sin", "id)", "permitido", "subscription", "sin-id"])

    def test_refrescar_asks_opencode_for_a_new_upstream_list(self):
        self.cli("proveedores")
        (self.bin / "listing").write_text(LISTING + "meta/muse-spark-2.0\n")
        code, out, _ = self.cli("proveedores", "--refrescar")
        self.assertEqual(self.argv_log(), ["--version", "models", "--version", "models --refresh"])
        self.assertEqual(out.splitlines()[5].split()[:7], ["muse", "meta", "permitido", "subscription", "con-sesion",
                                                           "7", "7"])

    def test_an_unreadable_policy_or_a_silent_opencode_is_an_error_not_an_empty_table(self):
        (self.bin / "version").write_text("")
        code, out, err = self.cli("proveedores")
        self.assertEqual((code, out), (1, ""))
        self.assertIn("--version no contestó una versión", err)
        (self.bin / "version").write_text("1.18.35\n")
        self.policy_path.unlink()
        code, out, err = self.cli("proveedores")
        self.assertEqual((code, out), (3, ""))
        self.assertIn("proveedores-permitidos.json", err)


class Preparar(Mac):
    def test_the_profile_travels_in_the_brief_args_only_when_it_is_asked_for(self):
        self.beat()
        self.assertNotIn("--perfil", self.preparar()["briefArgs"], "a task of today carries no profile")
        with_profile = self.preparar("--perfil", "revision")
        self.assertEqual(with_profile["briefArgs"][-2:], ["--perfil", "revision"])
        unknown = self.preparar("--perfil", "no-existe")
        self.assertEqual((unknown["causa"], unknown["accion"]), ("perfil-desconocido", "no-registrar"))
        self.assertEqual(unknown["frase"], "ningún perfil se llama no-existe")
        malformed = self.preparar("--perfil", "Ingenieria")
        self.assertEqual(malformed["causa"], "perfil-desconocido")

    def test_a_profiled_pedido_names_an_uncertified_package_generation_in_the_same_turn(self):
        self.beat()
        path = self.checkout / EVIDENCE / "coverage.json"
        coverage = json.loads(path.read_text())
        del coverage["hostAdapterRoute"]["mac-local"]["opencode"]["contextGenerations"]
        path.write_text(json.dumps(coverage))
        answer = self.preparar("--perfil", "ingenieria")
        self.assertEqual((answer["causa"], answer["accion"]), ("generacion-no-certificada", "no-registrar"))
        self.assertIn("generación 2", answer["frase"])

    def test_a_profiled_pedido_says_when_the_checkout_has_no_package_to_deliver(self):
        self.beat()
        shutil.rmtree(self.checkout / "scripts" / "agent-work" / "contexto")
        answer = self.preparar("--perfil", "ingenieria")
        self.assertEqual((answer["causa"], answer["accion"]), ("contexto-incompleto", "no-registrar"))
        self.assertIn("no se pudo leer", answer["frase"])

    def test_a_bare_provider_word_asks_david_which_model(self):
        answer = self.preparar("--modelo", "glm")
        self.assertEqual((answer["causa"], answer["accion"]), ("nombre-ambiguo", "preguntar-a-david"))
        self.assertEqual(answer["candidatos"], [
            "zai-coding-plan/glm-4.7", "zai-coding-plan/glm-5-turbo", "zai-coding-plan/glm-5.2",
            "zai-coding-plan/glm-5.2-highspeed", "zai-coding-plan/glm-5.3", "zai-coding-plan/glm-5.3-flash",
            "zai-coding-plan/glm-5.3-highspeed"])
        self.assertEqual(len(self.preparar("--modelo", "muse")["candidatos"]), 6)
        qwen = self.preparar("--modelo", "qwen")
        self.assertEqual((qwen["accion"], qwen["candidatos"]), ("preguntar-a-david", [
            "alibaba-token-plan/qwen3.6-flash", "alibaba-token-plan/qwen3.6-plus", "alibaba-token-plan/qwen3.7-max",
            "alibaba-token-plan/qwen3.7-plus", "alibaba-token-plan/qwen3.8-flash", "alibaba-token-plan/qwen3.8-max"]))
        self.assertIn("De alibaba-token-plan, por suscripción", qwen["frase"])

    def test_deepseek_asks_between_davids_two_api_models_and_says_they_bill_per_token(self):
        self.assertEqual(self.preparar("--modelo", "deepseek"), {
            "ok": False, "causa": "nombre-ambiguo", "accion": "preguntar-a-david",
            "candidatos": ["deepseek/deepseek-flash", "deepseek/deepseek-v4-pro"],
            "frase": "«deepseek» coincide con 2 modelos permitidos. De deepseek, por token: deepseek/deepseek-flash, "
                     "deepseek/deepseek-v4-pro. Falta saber cuál."})

    def test_each_request_david_can_make_is_judged_before_the_route_and_the_host(self):
        for words, causa, pieces in (
            ("claude opus", "proveedor-sin-sesion", ["claude", "no entra por opencode", "B22-S5"]),
            ("opencode-go/deepseek-v4-pro", "proveedor-no-permitido", ["«open code go es solamente para main»"]),
            ("zai/glm-5.3", "proveedor-no-permitido", ["zai está cerrado para encargos"]),
            ("zai-coding-plan/no-existe", "modelo-no-existe", ["zai-coding-plan/no-existe no existe"]),
            ("alibaba-token-plan/deepseek-v4-pro", "modelo-fuera-del-permiso", ["solo entran qwen*, salvo qwen-image*"]),
            ("Zai/glm", "modelo-mal-formado", ["«Zai/glm»"]),
            ("no existe tal", "nombre-sin-coincidencia", ["«no existe tal»"]),
        ):
            with self.subTest(words):
                answer = self.preparar("--modelo", words)
                self.assertEqual((answer["ok"], answer["causa"], answer["accion"], answer["candidatos"]),
                                 (False, causa, "no-registrar", []))
                for piece in pieces:
                    self.assertIn(piece, answer["frase"])
        self.assertNotIn("auth login", self.preparar("--modelo", "claude opus")["frase"])

    def test_a_grant_without_its_id_says_login_and_binding_are_missing(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        answer = self.preparar("--modelo", "kimi k3")
        self.assertEqual((answer["causa"], answer["frase"]), (
            "proveedor-sin-sesion", "kimi está permitido, pero falta iniciar sesión con opencode auth login y ligar "
            "su id con encargo.py permitir kimi --proveedor <id>."))

    def test_a_missing_policy_or_one_entry_without_its_quote_stops_every_request(self):
        self.edit_policy(lambda doc: doc["providers"][7]["decision"].pop("quote"))
        answer = self.preparar()
        self.assertEqual((answer["causa"], answer["accion"]), ("politica-ilegible", "no-registrar"))
        self.assertIn("deepseek", answer["frase"])
        self.assertEqual(self.preparar("--modelo", "glm 5.3 flash")["causa"], "politica-ilegible")
        self.policy_path.rename(self.policy_path.with_suffix(".bak"))
        self.assertEqual(self.preparar()["causa"], "politica-ilegible")

    def test_a_broken_policy_is_said_even_when_opencode_does_not_answer(self):
        (self.bin / "version").write_text("")
        self.edit_policy(lambda doc: doc["providers"][0].update(billing="free"))
        answer = self.preparar()
        self.assertEqual((answer["causa"], answer["accion"]), ("politica-ilegible", "no-registrar"))
        self.assertFalse((self.bin / "argv.log").exists())

    def test_a_coverage_file_of_the_wrong_shape_is_an_uncertified_route_not_a_traceback(self):
        for content in ("[]", '"certified"', '{"hostAdapterCoverage": [], "hostAdapterRoute": {"mac-local": 1}}', "{"):
            with self.subTest(content):
                (self.checkout / EVIDENCE / "coverage.json").write_text(content)
                self.assertEqual(self.preparar()["causa"], "ruta-no-certificada")

    def test_a_listing_that_is_empty_or_not_ids_is_opencode_not_answering_and_is_never_cached(self):
        for listing, piece in (("", "no listó ningún modelo"), ("\n\n", "no listó ningún modelo"),
                               ("Update available: 1.18.36\n" + LISTING, "una línea que no es un id"),
                               ("error: not logged in\n", "una línea que no es un id")):
            with self.subTest(listing[:30]):
                (self.bin / "listing").write_text(listing)
                code, out, err = self.cli("preparar", "--repo", str(self.repo), "--modelo", "grok 4.7")
                self.assertEqual((code, out), (1, ""))
                self.assertIn(piece, err)
                self.assertFalse((self.state / "catalogo.json").exists())
        (self.bin / "listing").write_text(LISTING)
        self.assertEqual(self.preparar("--modelo", "grok 4.7")["causa"], "sin-host")

    def test_the_command_gives_up_at_its_deadline_even_when_opencode_leaves_a_child_holding_the_pipe(self):
        (self.bin / "before-listing").write_text("sleep 30\n")
        started = time.monotonic()
        with self.assertRaisesRegex(encargo.CatalogUnavailable, "tope"):
            encargo.preparar(self.repo, None, state_root=self.state, checkout=self.checkout, now=time.time(),
                             opencode_bin=self.bin / "opencode", allowed_root=self.root / "dev", deadline_seconds=6.5)
        self.assertLess(time.monotonic() - started, 5)

    def test_a_request_without_model_is_refused_when_the_default_provider_has_no_grant(self):
        # SUA-04 (4.2): sin el permiso de defaultGrant la política no carga, porque defaultGrant
        # nombra un permiso que ya no está. Antes el id por omisión vivía fijo en el código.
        self.edit_policy(lambda doc: doc.update(providers=[doc["providers"][7]], closed=[]))
        answer = self.preparar()
        self.assertEqual((answer["ok"], answer["causa"]), (False, "politica-ilegible"))
        self.assertIn("defaultGrant", answer["frase"])

    def test_the_folder_must_be_a_git_root_with_a_commit_under_the_operators_root(self):
        self.beat()
        outside = self.root / "fuera"
        (outside / ".git").mkdir(parents=True)
        empty = self.root / "dev" / "vacio"
        empty.mkdir()
        subprocess.run(["git", "-C", str(empty), "init", "-q"], check=True, capture_output=True)
        for repo, piece in ((outside, "fuera de la carpeta"), (self.repo / "no-esta", "no existe"),
                            (empty, "es un repo git sin ningún commit"), (self.root / "dev", "fuera de la carpeta")):
            with self.subTest(repo):
                code, out, _ = self.cli("preparar", "--repo", str(repo))
                answer = json.loads(out)
                self.assertEqual((code, answer["causa"]), (3, "carpeta-no-permitida"))
                self.assertIn(piece, answer["frase"])

    def test_with_the_repos_certified_route_the_host_is_the_next_thing_missing(self):
        self.assertEqual(self.preparar(), {"ok": False, "causa": "sin-host", "accion": "no-registrar", "candidatos": [],
                                           "frase": "El host de encargos nunca corrió en esta Mac."})
        self.beat(beatAt=time.time() - 605)
        self.assertEqual(self.preparar()["frase"], "El host de encargos no corre desde hace 10 min.")
        (self.state / "host.json").write_text('{"pid": "4242"}')
        self.assertEqual(self.preparar()["causa"], "sin-host")

    def test_a_sandbox_tested_route_is_opened_only_by_a_live_canary_host(self):
        self.sandbox_tested()
        self.assertEqual(self.preparar(), {
            "ok": False, "causa": "ruta-no-certificada", "accion": "no-registrar", "candidatos": [],
            "frase": "La ruta de encargos por opencode todavía no está certificada. La Mac tiene opencode 1.18.35."})
        self.beat()
        self.assertEqual(self.preparar()["frase"], "La ruta de encargos por opencode todavía no está certificada. "
                                                   "La Mac tiene opencode 1.18.35.")
        self.beat(canary=True)
        self.assertEqual(self.preparar(), {
            "ok": True, "modelo": "zai-coding-plan/glm-5.3-flash", "cobro": "subscription",
            "inputRevision": {"kind": "code", "repository": str(self.repo), "sha": self.head},
            "briefArgs": DEFAULT_BRIEF_ARGS, "enFila": False,
            "host": {"politica": self.policy().digest[:12], "cli": "1.18.35"}})
        self.beat(canary=True, beatAt=time.time() - 121)
        self.assertEqual(self.preparar()["causa"], "ruta-no-certificada", "a canary host that died still opened it")

    def test_preparar_without_a_model_uses_since_and_then_the_promoted_actual(self):
        # SUA-04 (4.2, I10): sin sucesion.json corre el since de glm; con el actual de
        # sucesion.json corre ese, sin tocar proveedores-permitidos.json.
        self.beat()
        self.assertEqual(self.preparar()["modelo"], "zai-coding-plan/glm-5.3-flash")
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        (self.state / "catalogo.json").unlink()
        (self.state / "sucesion.json").write_text(json.dumps({
            "schema": "agent-work.succession.v1",
            "lines": {"zai-coding-plan/glm-{}-flash": {"actual": "zai-coding-plan/glm-5.4-flash"}}}))
        answer = self.preparar()
        self.assertEqual(answer["modelo"], "zai-coding-plan/glm-5.4-flash")
        self.assertEqual(answer["briefArgs"][-1], "zai-coding-plan/glm-5.4-flash")
        rows = encargo.proveedores(state_root=self.state, checkout=self.checkout,
                                   opencode_bin=self.bin / "opencode")
        glm = rows[0]
        self.assertEqual((glm.line, glm.since, glm.efectivo, glm.promovido),
                         ("zai-coding-plan/glm-{}-flash", "zai-coding-plan/glm-5.3-flash",
                          "zai-coding-plan/glm-5.4-flash", True))

    def test_a_live_host_with_the_same_policy_and_cli_gets_the_brief_arguments(self):
        self.beat()
        self.assertEqual(self.preparar(), {
            "ok": True, "modelo": "zai-coding-plan/glm-5.3-flash", "cobro": "subscription",
            "inputRevision": {"kind": "code", "repository": str(self.repo), "sha": self.head},
            "briefArgs": DEFAULT_BRIEF_ARGS, "enFila": False,
            "host": {"politica": self.policy().digest[:12], "cli": "1.18.35"}})
        self.beat(slot="running", taskId="t-1", model="zai-coding-plan/glm-5.3", since=time.time() - 30)
        token = self.preparar("--modelo", "deepseek v4 pro")
        self.assertEqual((token["modelo"], token["cobro"], token["enFila"], token["briefArgs"][-1]),
                         ("deepseek/deepseek-v4-pro", "per-token", True, "deepseek/deepseek-v4-pro"))
        without_repo = self.preparar("--modelo", "glm 5.3 highspeed", repo=False)
        self.assertEqual((without_repo["modelo"], without_repo["inputRevision"]),
                         ("zai-coding-plan/glm-5.3-highspeed", None))

    def test_brief_py_takes_the_brief_arguments_as_they_come_and_the_host_reads_that_model(self):
        self.beat()
        answer = self.preparar("--modelo", "deepseek v4 pro")
        instructions = self.root / "instructions"
        instructions.mkdir()
        done = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/agent-work/brief.py"),
                               "--root", str(instructions), *answer["briefArgs"]],
                              input=b"Agrega saludo.py\n", capture_output=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        fragments = json.loads(done.stdout)
        self.assertEqual(fragments["target"], {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"})
        brief = (instructions / fragments["instructionRef"]["ref"].removeprefix("artifact:")).read_bytes()
        self.assertEqual(brief, b"agent-work.launch.v1\nmodel: deepseek/deepseek-v4-pro\n---\nAgrega saludo.py\n")
        self.assertEqual(str(LaunchHeader.parse(brief).model), answer["modelo"])

    def test_a_host_that_would_decide_with_something_else_is_out_of_step(self):
        for change, piece in (({"policyDigest": "f" * 64}, "otra política"), ({"policyDigest": None}, "otra política"),
                              ({"checkout": "/otro/checkout"}, "otro checkout"),
                              ({"cliVersion": "1.18.20"}, "otra versión de opencode")):
            with self.subTest(change):
                self.beat(**change)
                answer = self.preparar()
                self.assertEqual((answer.get("causa"), answer.get("accion")), ("host-desfasado", "no-registrar"))
                self.assertIn(piece, answer["frase"])
        self.beat(slot="blocked", blockedBy=["777 Mon Oct 12 18:00:00 2026 sleep 300"])
        blocked = self.preparar()
        self.assertEqual(blocked["causa"], "slot-bloqueado")
        self.assertIn("777 Mon Oct 12 18:00:00 2026 sleep 300", blocked["frase"])

    def test_a_login_david_just_made_is_seen_without_waiting_for_the_cache_to_age(self):
        self.assertEqual(self.preparar("--modelo", "claude opus")["causa"], "proveedor-sin-sesion")
        cache = self.state / "catalogo.json"
        stale = json.loads(cache.read_text())
        stale["listedAt"] -= 120
        cache.write_text(json.dumps(stale))
        (self.bin / "listing").write_text(LISTING + "anthropic/claude-opus-5-5\n")
        self.assertEqual(self.preparar("--modelo", "claude opus")["causa"], "sin-host")
        self.assertEqual(self.argv_log(), ["--version", "models", "--version", "--version", "models"])

    def test_a_new_cli_version_relists_and_closes_the_repos_certified_route(self):
        self.beat()
        self.assertTrue(self.preparar()["ok"])
        (self.bin / "version").write_text("1.18.36\n")
        closed = self.preparar()
        self.assertEqual((closed["causa"], closed["frase"]),
                         ("ruta-no-certificada", "Ruta certificada para 1.18.35, la Mac tiene opencode 1.18.36."))
        self.assertEqual(self.argv_log()[-2:], ["--version", "models"])

    def test_the_script_answers_one_json_line_when_run_as_a_program(self):
        done = subprocess.run([sys.executable, str(ROOT / "scripts/agent-work/encargo.py"), "--checkout",
                               str(self.checkout), "--state-root", str(self.state), "--opencode",
                               str(self.bin / "opencode"), "--workspace-root", str(self.root / "dev"), "preparar",
                               "--repo", str(self.repo), "--modelo", "opencode-go/kimi-k3"],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, json.loads(done.stdout)["causa"], done.stderr),
                         (3, "proveedor-no-permitido", ""))


class Estado(Mac):
    def test_without_a_task_it_answers_the_host_beat_or_that_no_host_runs(self):
        code, out, _ = self.cli("estado")
        self.assertEqual((code, json.loads(out)["causa"]), (3, "sin-host"))
        self.beat(slot="running", taskId="t-9", model="zai-coding-plan/glm-5.3")
        code, out, _ = self.cli("estado")
        answer = json.loads(out)
        self.assertEqual(code, 0)
        self.assertLess(answer.pop("latidoHace"), 10)
        self.assertEqual(answer, {"ok": True, "pid": 4242, "slot": "running", "bloqueadoPor": [], "tarea": "t-9",
                                  "modelo": "zai-coding-plan/glm-5.3", "checkout": str(self.checkout),
                                  "commit": "c" * 40, "politica": self.policy().digest[:12], "cli": "1.18.35",
                                  "canario": False})
        self.beat(beatAt=time.time() - 121)
        code, out, _ = self.cli("estado")
        self.assertEqual((code, json.loads(out)["frase"]), (3, "El host de encargos no corre desde hace 2 min."))

    def test_a_task_the_host_never_claimed_says_to_wait(self):
        code, out, _ = self.cli("estado", "--tarea", "t-9")
        self.assertEqual((code, json.loads(out)["causa"]), (3, "sin-host"))
        self.beat()
        code, out, _ = self.cli("estado", "--tarea", "t-9")
        self.assertEqual((code, json.loads(out)), (3, {
            "ok": False, "causa": "tarea-desconocida", "accion": "esperar", "candidatos": [],
            "frase": "El host de encargos no tiene ninguna operación de la tarea t-9. Puede que todavía no la "
                     "haya reclamado."}))


class Perfiles(Mac):
    def test_the_command_lists_the_profiles_of_the_checkout_and_the_agents_without_one(self):
        # El archivo real: once perfiles y los siete agentes que la medición P1 dejó sin perfil.
        code, out, err = self.cli("perfiles")
        self.assertEqual((code, err), (0, ""))
        respuesta = json.loads(out)
        self.assertEqual([p["id"] for p in respuesta["perfiles"]],
                         ["ingenieria", "revision", "adversario", "verificacion", "exploracion", "aceptacion",
                          "operaciones", "amazon", "meli", "mail", "odoo"])
        self.assertEqual(respuesta["agentesSinPerfil"],
                         ["pers", "limpia", "arras", "gonserver", "skillverif", "tinkabot", "eggbot"])
        meli = next(p for p in respuesta["perfiles"] if p["id"] == "meli")
        self.assertEqual(meli["purpose"], "Trabajo de MercadoLibre: pedidos, demoras y preguntas. "
                                          "Rechaza lo que no es de MercadoLibre con FUERA-DE-PERFIL.")
        self.assertEqual(meli["resultContracts"], ["ready.v1"])
        self.assertEqual(meli["rutas"], [{"ruta": "mini-native/native/meli", "via": ["turn", "child"]}])
        self.assertEqual((meli["writesSource"], meli["competencia"]),
                         (False, {"mini-native/native/meli": {"status": "pending", "validUntil": None}}))
        ingenieria = next(p for p in respuesta["perfiles"] if p["id"] == "ingenieria")
        self.assertEqual(ingenieria["rutas"], [
            {"ruta": "mac-local/opencode", "via": ["task"]},
            {"ruta": "mini-native/native/ingenieria", "via": ["turn", "child", "task"]},
            {"ruta": "mini-native/native/implementer", "via": ["turn", "child", "task"]}])
        self.assertTrue(ingenieria["writesSource"])
        self.assertEqual([set(p) for p in respuesta["perfiles"]][:1],
                         [{"id", "purpose", "resultContracts", "rutas", "writesSource", "competencia"}])

    def test_perfiles_with_mini_adds_the_three_states(self):
        # SUA-04 (4.5): con --mini y un ssh falso, perfiles suma alta, retiro e incompleto.
        viva = [{"id": "main", "workspace": "/w/main"}, {"id": "ingenieria", "workspace": "/w/i"},
                {"id": "nuevo", "workspace": "/w/n"}]

        def fake(argv, entrada=None):
            return 0, json.dumps(viva), ""
        respuesta = encargo.perfiles(checkout=self.checkout, mini="u@h", correr=fake)
        self.assertEqual(respuesta["estados"]["alta-sin-registrar"]["agentes"], ["nuevo"])
        # B1: reviewer es solicitante y también trabajador con perfil: su retiro se ve.
        self.assertIn("reviewer", respuesta["estados"]["retirado"]["agentes"])
        self.assertIn({"perfil": "revision", "agentId": "reviewer"},
                      respuesta["estados"]["perfil-incompleto"]["perfiles"])
        self.assertNotIn("estados", encargo.perfiles(checkout=self.checkout))

    def test_perfiles_mini_says_the_live_list_failed_not_the_profiles_file(self):
        # F4: un ssh que falla dice que falló la lista viva, no perfiles.v1.json.
        def fake(argv, entrada=None):
            return 1, "", "sin ruta a la Mini"
        with self.assertRaisesRegex(ValueError, "lista viva"):
            encargo.perfiles(checkout=self.checkout, mini="u@h", correr=fake)
        code, out, err = self.cli("perfiles", "--mini", "u@h")
        self.assertEqual(code, 3)
        self.assertIn("lista viva", err)
        self.assertNotIn("perfiles.v1.json", err)

    def test_perfiles_mini_without_a_host_is_a_usage_error(self):
        # B2: main corre encargo.py en la Mac, así que --mini sin user@host leería la lista
        # de la Mac, que no es la de la Mini: es error de uso, no una lista local.
        with self.assertRaises(SystemExit) as stopped:
            self.cli("perfiles", "--mini")
        self.assertEqual(stopped.exception.code, 2)

    def test_an_unreadable_profiles_file_is_an_error_and_not_a_traceback(self):
        (self.checkout / "scripts" / "agent-work" / "contexto" / "perfiles.v1.json").write_text("{")
        code, out, err = self.cli("perfiles")
        self.assertEqual((code, out), (3, ""))
        self.assertIn("perfiles.v1.json", err)

    def test_a_profiles_file_without_a_list_is_an_error_and_not_a_traceback(self):
        ruta = self.checkout / "scripts" / "agent-work" / "contexto" / "perfiles.v1.json"
        ruta.write_text(json.dumps({"schema": "x", "profiles": None}) + "\n", encoding="utf-8")
        code, out, err = self.cli("perfiles")
        self.assertEqual(code, 3)
        self.assertEqual(out, "")
        self.assertNotIn("Traceback", err)
        respuesta = json.loads(err)
        self.assertFalse(respuesta["ok"])
        self.assertIn("profiles", respuesta["error"])

    def test_a_profiles_file_with_a_broken_shape_is_an_error_and_not_a_traceback(self):
        # C3: la raíz debe ser un objeto y cada perfil un objeto con los campos que
        # perfiles() lee; cualquier otra forma contesta su línea JSON con salida 3.
        ruta = self.checkout / "scripts" / "agent-work" / "contexto" / "perfiles.v1.json"
        for contenido in (
            ["no", "es", "un", "objeto"],
            {"schema": "x", "profiles": [None]},
            {"schema": "x", "profiles": [{"purpose": "sin id"}]},
            {"schema": "x", "profiles": [{"id": "x", "purpose": "sin contratos"}]},
        ):
            with self.subTest(contenido=contenido):
                ruta.write_text(json.dumps(contenido) + "\n", encoding="utf-8")
                code, out, err = self.cli("perfiles")
                self.assertEqual(code, 3)
                self.assertEqual(out, "")
                self.assertNotIn("Traceback", err)
                respuesta = json.loads(err)
                self.assertFalse(respuesta["ok"])


    def test_a_profiles_file_with_broken_routes_competence_or_agents_is_an_error(self):
        # B1 (Minor de CodeRabbit en #307): routes es una lista de objetos con via como
        # lista, competence un objeto de objetos, y agents (si viene) una lista de objetos
        # con agentId; cualquier otra forma contesta su línea JSON con salida 3.
        ruta = self.checkout / "scripts" / "agent-work" / "contexto" / "perfiles.v1.json"
        perfil = {
            "id": "x", "purpose": "p", "resultContracts": ["ready.v1"],
            "writesSource": False, "competence": {},
        }
        for ruta_o_via, competencia, agentes, campo in (
            ({"routes": [None]}, {}, None, "routes"),
            ({"routes": [{"ruta": "mac-local/opencode", "via": "task"}]}, {}, None, "via"),
            (
                {"routes": [{"ruta": "mac-local/opencode", "via": ["task"]}]},
                [],
                None,
                "competence",
            ),
            (
                {"routes": [{"ruta": "mac-local/opencode", "via": ["task"]}]},
                {},
                [1],
                "agents",
            ),
        ):
            with self.subTest(campo=campo):
                uno = dict(perfil)
                uno.update(ruta_o_via)
                uno["competence"] = competencia
                if agentes is not None:
                    uno["agents"] = agentes
                ruta.write_text(json.dumps({"schema": "x", "profiles": [uno]}) + "\n", encoding="utf-8")
                code, out, err = self.cli("perfiles")
                self.assertEqual(code, 3)
                self.assertEqual(out, "")
                self.assertNotIn("Traceback", err)
                respuesta = json.loads(err)
                self.assertFalse(respuesta["ok"])
                self.assertIn(campo, respuesta["error"], f"el mensaje no nombra {campo}")


    def test_a_profiles_file_with_broken_root_agents_or_route_keys_is_an_error(self):
        # C1 de SUA03-G5c: el agents de la raíz es una lista de objetos con agentId de
        # texto; cada ruta trae host y executor de texto, y agentId de texto si viene.
        ruta_perfiles = self.checkout / "scripts" / "agent-work" / "contexto" / "perfiles.v1.json"
        perfil = {
            "id": "x", "purpose": "p", "resultContracts": ["ready.v1"],
            "routes": [{"host": "mac-local", "executor": "opencode", "via": ["task"]}],
            "writesSource": False, "competence": {},
        }
        casos = []
        for agentes in ([1], {"x": 1}):
            doc = {"schema": "x", "profiles": [perfil], "agents": agentes}
            casos.append((doc, "agents"))
        sin_host = copy.deepcopy(perfil)
        sin_host["routes"] = [{"executor": "opencode", "via": ["task"]}]
        casos.append(({"schema": "x", "profiles": [sin_host]}, "host"))
        agente_malo = copy.deepcopy(perfil)
        agente_malo["routes"] = [
            {"host": "mac-local", "executor": "opencode", "agentId": 5, "via": ["task"]}]
        casos.append(({"schema": "x", "profiles": [agente_malo]}, "agentId"))
        for documento, campo in casos:
            with self.subTest(campo=campo, documento=documento):
                ruta_perfiles.write_text(json.dumps(documento) + "\n", encoding="utf-8")
                code, out, err = self.cli("perfiles")
                self.assertEqual(code, 3)
                self.assertEqual(out, "")
                self.assertNotIn("Traceback", err)
                respuesta = json.loads(err)
                self.assertFalse(respuesta["ok"])
                self.assertIn(campo, respuesta["error"], f"el mensaje no nombra {campo}")

class Permitir(Mac):
    def test_rebinding_glm_to_another_provider_drops_its_default_and_the_default_grant(self):
        # F1: la línea del default es del proveedor viejo; al re-ligar el permiso el
        # default sale, y con él defaultGrant, y la salida lo dice.
        (self.bin / "listing").write_text(LISTING + "otro/glm-5.3-flash\n")
        code, out, err, changed = self.permitir(
            "glm", "--proveedor", "otro", "--cobro", "subscription", "--ref", "P10901",
            "--cita", "ok, permite mistral para por CLI, cobra por suscripción")
        self.assertEqual((code, changed), (0, True), err)
        self.assertIn("se quitó también el modelo por omisión", err + out)
        policy = self.policy()
        glm = next(grant for grant in policy.grants if grant.name == "glm")
        self.assertEqual((str(glm.provider), glm.default), ("otro", None))
        self.assertIsNone(policy.default_grant)
        self.assertIsNone(policy.unreadable)

    def permitir(self, *args):
        before = self.policy_path.read_bytes()
        code, out, err = self.cli("permitir", *args)
        return code, out, err, self.policy_path.read_bytes() != before

    def assert_refused(self, args, *pieces):
        code, out, err, changed = self.permitir(*args)
        self.assertEqual((code, out, changed), (3, "", False), err)
        for piece in pieces:
            self.assertIn(piece, err)
        self.assertNotIn("SECRETO", err)
        return err

    def test_a_quote_that_is_not_davids_literal_words_is_refused(self):
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P10866", "--cita", "permite mistral"],
                            "no es una subcadena literal del prompt P10866")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P10901", "--cita",
                             "Permite mistral para por CLI"], "no es una subcadena literal")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P99999", "--cita", "permite mistral"],
                            "no existe el prompt P99999")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P10901", "--cita", "  "], "vacía")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "commit abc123 de David", "--cita",
                             "permite mistral para por CLI"], "no es un prompt P####")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P" + "9" * 19, "--cita",
                             "permite mistral para por CLI"], "no es un prompt P####")
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P" + "9" * 18, "--cita",
                             "permite mistral para por CLI"], "no existe el prompt P999999999999999999")

    def test_the_command_line_has_no_way_to_point_the_check_at_another_prompt_store(self):
        before = self.policy_path.read_bytes()
        for position in (0, -1):
            argv = ["--checkout", str(self.checkout), "--state-root", str(self.state), "--opencode",
                    str(self.bin / "opencode"), "permitir", "mistral", "--cobro", "subscription", "--ref", "P10901",
                    "--cita", "permite mistral para por CLI"]
            argv[len(argv) if position else 0:len(argv) if position else 0] = ["--prompts", str(self.prompts)]
            with self.subTest(argv[0]), self.assertRaises(SystemExit) as stopped, \
                    contextlib.redirect_stderr(io.StringIO()):
                encargo.main(argv)
            self.assertEqual(stopped.exception.code, 2)
        self.assertEqual(self.policy_path.read_bytes(), before)
        self.assert_refused(["mistral", "--cobro", "subscription"], "--ref y --cita")
        self.assert_refused(["mistral", "--cobro", "subscription", "--cita", "permite mistral"], "van juntas")

    def test_an_id_opencode_does_not_list_cannot_be_bound(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        self.assert_refused(["kimi", "--proveedor", "kimi-code-plan-global"],
                            "opencode no lista ningún modelo con el id kimi-code-plan-global")
        self.assert_refused(["mistral", "--proveedor", "mistral", "--cobro", "subscription", "--ref", "P10901",
                             "--cita", "permite mistral para por CLI"], "opencode no lista ningún modelo con el id mistral")
        self.assertEqual(self.argv_log()[-2:], ["--version", "models"])

    def test_a_listed_id_binds_to_the_grant_david_already_gave_without_a_new_phrase(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        before = self.policy()
        code, out, err, changed = self.permitir("kimi", "--proveedor", "kimi-code-plan-cn")
        self.assertEqual((code, changed), (0, True), err)
        self.assertEqual(out.splitlines()[1].split(), ["kimi", "kimi-code-plan-cn", "permitido", "subscription",
                                                       "con-sesion", "4", "4", "-", "-", "-", "David", "2026-10-12", "P10867"])
        after = self.policy()
        self.assertEqual((after.grant_for("kimi-code-plan-cn").decision, after.closed), (before.grants[5].decision,
                                                                                         before.closed))
        self.assertEqual(after.grants[:5] + after.grants[6:], before.grants[:5] + before.grants[6:])
        self.assertEqual(self.policy_path.read_bytes(), (ROOT / EVIDENCE / "proveedores-permitidos.json").read_bytes())

    def test_rebinding_an_id_or_taking_one_another_grant_holds_needs_more_than_a_fact(self):
        self.assert_refused(["kimi", "--proveedor", "meta"], "kimi ya está ligado a kimi-code-plan-cn")
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        self.assert_refused(["kimi", "--proveedor", "meta"], "meta ya es el id de muse")
        self.assert_refused(["mistral", "--proveedor", "meta"], "mistral no tiene permiso")
        self.assert_refused(["kimi"], "--proveedor")
        self.assert_refused(["Kimi", "--proveedor", "kimi-code-plan-cn"], "nombre inválido")

    def test_the_host_checkout_never_takes_a_live_write(self):
        self.beat(beatAt=time.time() - 86400)
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P10901", "--cita",
                             "permite mistral para por CLI"], "es el del host de encargos")
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        self.assert_refused(["kimi", "--proveedor", "kimi-code-plan-cn"], "es el del host de encargos")
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual((code, out), (3, ""))
        self.assertIn("es el del host de encargos", err)

    def test_a_host_that_starts_from_this_checkout_while_the_command_runs_still_stops_the_write(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        self.beat()
        (self.state / "host.json").rename(self.bin / "host.json")
        (self.bin / "before-listing").write_text(f'cp "$here/host.json" "{self.state}/host.json"\n')
        self.assert_refused(["kimi", "--proveedor", "kimi-code-plan-cn"], "es el del host de encargos")
        self.assertEqual(self.argv_log()[-1], "models")

    def test_a_filter_that_covers_no_listed_model_is_refused_instead_of_silently_blocking_the_provider(self):
        phrase = ["--ref", "P10886", "--cita", "dejar solo los modelos qwen"]
        self.assert_refused(["qwen", "--solo", "zzz*", *phrase],
                            "no cubre ninguno de los modelos que opencode lista de alibaba-token-plan (27)")
        self.assert_refused(["qwen", "--solo", "qwen*", "--menos", "qwen*", *phrase], "no cubre ninguno")
        code, out, err, changed = self.permitir("claude", "--solo", "claude-opus-*", "--ref", "P10886", "--cita",
                                                "dejar solo los modelos")
        self.assertEqual((code, changed), (0, True), err)
        self.assertEqual(self.policy().grant_for("anthropic").models.include, ("claude-opus-*",))

    def test_binding_an_id_checks_the_filter_the_grant_already_carried(self):
        (self.bin / "listing").write_text(LISTING + "mistral/large-3\nmistral/small-3\n")
        code, _, err, changed = self.permitir("mistral", "--cobro", "subscription", "--solo", "medium*", "--ref",
                                              "P10901", "--cita", "permite mistral para por CLI")
        self.assertEqual((code, changed), (0, True), err)
        self.assert_refused(["mistral", "--proveedor", "mistral"],
                            "el filtro de mistral no cubre ninguno de los modelos que opencode lista de mistral (2)")
        self.assertIsNone(self.policy().grants[8].provider)
        (self.bin / "listing").write_text(LISTING + "mistral/large-3\nmistral/medium-3\n")
        code, out, err, changed = self.permitir("mistral", "--proveedor", "mistral")
        self.assertEqual((code, changed), (0, True), err)
        self.assertEqual(out.splitlines()[1].split()[:7], ["mistral", "mistral", "permitido", "subscription",
                                                           "con-sesion", "2", "1"])

    def test_with_opencode_silent_a_grant_that_needs_no_listing_is_written_and_a_binding_or_a_filter_is_not(self):
        (self.bin / "version").write_text("")
        code, out, err, changed = self.permitir("mistral", "--cobro", "subscription", "--ref", "P10901", "--cita",
                                                "permite mistral para por CLI")
        self.assertEqual((code, changed), (0, True), err)
        self.assertEqual(self.policy().grants[8].name, "mistral")
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        for args in (["kimi", "--proveedor", "kimi-code-plan-cn"],
                     ["qwen", "--solo", "qwen3.8*", "--ref", "P10886", "--cita", "dejar solo los modelos qwen"]):
            with self.subTest(args):
                code, out, err, changed = self.permitir(*args)
                self.assertEqual((code, out, changed), (1, "", False))
                self.assertIn("opencode no contestó", err)

    def test_a_new_grant_is_the_old_policy_plus_one_entry_with_the_date_of_the_prompt(self):
        before = self.policy()
        args = ["mistral", "--cobro", "subscription", "--ref", "P10901", "--cita",
                "permite mistral para por CLI, cobra por suscripción"]
        code, out, err, changed = self.permitir(*args)
        self.assertEqual((code, changed, err), (0, True, ""))
        self.assertEqual(out.splitlines()[1].split(), ["mistral", "(sin", "id)", "permitido", "subscription", "sin-id",
                                                       "-", "-", "-", "-", "-", "David", "2026-10-14", "P10901"])
        after = self.policy()
        self.assertIsNone(after.unreadable)
        self.assertEqual((after.grants[:8], after.closed), (before.grants, before.closed))
        new = after.grants[8]
        self.assertEqual((new.name, new.provider, new.billing, new.models, new.decision.by, new.decision.on,
                          new.decision.ref, new.decision.quote),
                         ("mistral", None, "subscription", None, "David", "2026-10-14", "P10901",
                          "permite mistral para por CLI, cobra por suscripción"))
        self.assertTrue(self.policy_path.read_bytes().startswith(
            (ROOT / EVIDENCE / "proveedores-permitidos.json").read_bytes()[:200]))
        written = self.policy_path.read_bytes()
        self.assertEqual(self.permitir(*args)[0], 0)
        self.assertEqual(self.policy_path.read_bytes(), written)
        self.assertEqual(self.policy_path.stat().st_mode & 0o777, 0o644)

    def test_a_filter_keeps_the_grant_and_its_citation_and_narrows_what_runs(self):
        self.edit_policy(lambda doc: doc["providers"][6].pop("models"))
        deepseek_of_alibaba = ExactModel(ModelId("alibaba-token-plan", "deepseek-v4-pro"))
        catalog = Catalog.from_listing(LISTING, cli_version="1.18.35", listed_at=0.0)
        self.assertIsInstance(authorize(deepseek_of_alibaba, self.policy(), catalog), PermittedModel)
        self.assert_refused(["qwen", "--solo", "qwen*"], "--ref y --cita")
        self.assert_refused(["qwen", "--menos", "qwen-image*", "--ref", "P10886", "--cita", "dejar solo los modelos qwen"],
                            "--menos va con --solo")
        self.assert_refused(["qwen", "--solo", "qwen [36]", "--ref", "P10886", "--cita", "dejar solo los modelos qwen"],
                            "patrón de modelos inválido")
        code, out, err, changed = self.permitir(
            "qwen", "--solo", "qwen*", "--menos", "qwen-image*", "--ref", "P10890", "--cita",
            "sí, esos seis modelos de qwen están bien")
        self.assertEqual((code, changed), (0, True), err)
        self.assertEqual(out.splitlines()[1].split()[:7], ["qwen", "alibaba-token-plan", "permitido", "subscription",
                                                           "con-sesion", "27", "6"])
        self.assertEqual(self.policy_path.read_bytes(), (ROOT / EVIDENCE / "proveedores-permitidos.json").read_bytes())
        self.assertEqual(type(authorize(deepseek_of_alibaba, self.policy(), catalog)).__name__, "ModelOutsideGrant")

    def test_a_new_billing_phrase_rewrites_the_grant_and_drops_its_filter(self):
        code, _, err, changed = self.permitir("qwen", "--cobro", "per-token", "--ref", "P10901", "--cita",
                                              "permite mistral para por CLI")
        self.assertEqual((code, changed), (0, True), err)
        qwen = self.policy().grant_for("alibaba-token-plan")
        self.assertEqual((qwen.billing, qwen.models, qwen.decision.ref), ("per-token", None, "P10901"))

    def test_without_the_prompt_store_nothing_is_attributed_to_david(self):
        self.prompts.unlink()
        self.assert_refused(["mistral", "--cobro", "per-token", "--ref", "P10901", "--cita", "permite mistral"],
                            "no existe la base de prompts")
        self.assert_refused(["qwen", "--solo", "qwen3.8*", "--ref", "P10886", "--cita", "dejar solo los modelos qwen"],
                            "no existe la base de prompts")
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual((code, out), (3, ""))
        self.assertIn("no existe la base de prompts", err)
        self.assertEqual([decision.by for decision in
                          [grant.decision for grant in self.policy().grants]
                          + [closure.decision for closure in self.policy().closed.values()]], ["David"] * 11)

    def test_no_command_can_write_a_policy_that_drops_or_changes_a_closure(self):
        policy, before = self.policy(), self.policy_path.read_bytes()
        kept = dict(policy.closed)
        kept.pop("zai")
        self.assertIn("no quita ni cambia un cierre, y este tocaría el de zai",
                      encargo._write_policy(self.checkout, self.state, lambda current: (current.grants, kept)))
        changed = {**policy.closed, "opencode-go": policy.closed["opencode"].__class__(
            "opencode-go", policy.grants[0].decision)}
        self.assertIn("tocaría el de opencode-go",
                      encargo._write_policy(self.checkout, self.state, lambda current: (current.grants, changed)))
        self.assertEqual(self.policy_path.read_bytes(), before)
        self.assertIsNone(encargo._write_policy(self.checkout, self.state,
                                                lambda current: (current.grants, dict(current.closed))))
        self.assertEqual(self.policy_path.read_bytes(), before)

    def test_a_resulting_policy_that_does_not_load_is_refused_naming_the_policy_file(self):
        before = self.policy_path.read_bytes()
        self.assertEqual(
            encargo._write_policy(self.checkout, self.state,
                                  lambda current: (current.grants + current.grants[:1], dict(current.closed))),
            "la política resultante no carga: proveedores-permitidos.json: dos permisos se llaman glm")
        self.assertEqual(self.policy_path.read_bytes(), before)
        self.assertEqual(sorted(path.name for path in self.policy_path.parent.iterdir()),
                         ["coverage.json", "proveedores-permitidos.json"])

    def test_an_unreadable_policy_is_not_rewritten(self):
        self.edit_policy(lambda doc: doc["providers"][0].update(billing="free"))
        self.assert_refused(["mistral", "--cobro", "subscription", "--ref", "P10901", "--cita",
                             "permite mistral para por CLI"], "billing", "glm")


SUCESION = {"schema": "agent-work.succession.v1", "lines": {}}


class Sucesion(Mac):
    """SUA-04 (4.3): el estado vive en <state>/sucesion.json y el canario es un banco falso."""

    def plan(self, **kwargs):
        kwargs.setdefault("enviar_aviso", lambda texto, **kw: {"enviado": True})
        return encargo.sucesion(state_root=self.state, checkout=self.checkout,
                                opencode_bin=self.bin / "opencode", now=1_800_000_000.0, **kwargs)

    def escribir(self, doc):
        (self.state / "sucesion.json").write_text(json.dumps(doc))

    def leer(self):
        return json.loads((self.state / "sucesion.json").read_text())

    def test_plan_y_causas(self):
        answer = self.plan()
        glm = answer["lineas"][0]
        self.assertEqual((glm["permiso"], glm["linea"], glm["actual"], glm["sucesor"], glm["causa"]),
                         ("glm", "zai-coding-plan/glm-{}-flash", "zai-coding-plan/glm-5.3-flash", None, "sin-sucesor"))
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash-preview\n")
        (self.state / "catalogo.json").unlink()
        self.assertEqual(self.plan()["lineas"][0]["causa"], "no-estable")
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        (self.state / "catalogo.json").unlink()
        glm = self.plan()["lineas"][0]
        self.assertEqual((glm["sucesor"], glm["causa"]), ("zai-coding-plan/glm-5.4-flash", None))
        # Un id de otra línea o de otro proveedor no es sucesor.
        (self.bin / "listing").write_text(
            LISTING + "zai-coding-plan/glm-5.4-flash\nzai-coding-plan/glm-5.4\notro/glm-9.9-flash\n")
        (self.state / "catalogo.json").unlink()
        self.assertEqual(self.plan()["lineas"][0]["sucesor"], "zai-coding-plan/glm-5.4-flash")

    def test_aplicar_verde_promueve_y_el_preparar_usa_el_promovido(self):
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")

        def banco(env, cwd):
            return 0, "test_x ... BANCO_E2E case=ingenieria desenlace=verde causa=ninguna\n\nOK\n"
        answer = self.plan(aplicar=True, correr_banco=banco, runtime_source="/r")
        self.assertEqual((answer["accion"], answer["promovido"]), ("promovido", "zai-coding-plan/glm-5.4-flash"))
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual((entry["actual"], entry["anterior"], entry["estado"]),
                         ("zai-coding-plan/glm-5.4-flash", "zai-coding-plan/glm-5.3-flash", "promovido"))
        self.assertIn("zai-coding-plan/glm-5.4-flash reemplazó a zai-coding-plan/glm-5.3-flash", answer["aviso"])
        # SUA-04 G5: el aviso sale por avisar.py (aquí, el de juguete que siempre manda):
        # la línea queda con avisoEnviado y sin avisoPendiente.
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertTrue(entry.get("avisoEnviado"))
        self.assertNotIn("avisoPendiente", answer)
        # G2 lo lee: un sucesion.json escrito por G3 pasa succession_actual y preparar lo usa.
        self.beat()
        self.assertEqual(self.preparar()["modelo"], "zai-coding-plan/glm-5.4-flash")

    def correr_aplicar(self, salida):
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        return self.plan(aplicar=True, correr_banco=lambda env, cwd: salida, runtime_source="/r")

    def test_aplicar_rojo_rechaza_con_huella_y_la_huella_bloquea(self):
        answer = self.correr_aplicar((1, "test_x ... FAIL\nBANCO_E2E case=ingenieria desenlace=rojo "
                                     "causa=conducta\nFAILED (failures=1)\n"))
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual((answer["accion"], entry["estado"], entry["intentos"]),
                         ("rechazado", "rechazado", 1))
        self.assertTrue(entry["huellaDelCatalogo"])
        self.assertEqual(self.plan()["lineas"][0]["causa"], "rechazado")
        # A los 7 días con la misma huella se vuelve a abrir; con otro id en la línea, antes.
        doc = self.leer()
        doc["lines"]["zai-coding-plan/glm-{}-flash"]["ultimo"] = 1_800_000_000.0 - 8 * 86400
        self.escribir(doc)
        self.assertIsNone(self.plan()["lineas"][0]["causa"])

    def test_aplicar_infraestructura_deja_pendiente_sin_intento(self):
        answer = self.correr_aplicar((0, "test_x ... skipped 'sin AGENT_WORK_BANCO_REAL'\n\nOK (skipped=1)\n"))
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual((answer["accion"], entry["estado"], entry["intentos"]), ("pendiente", "pendiente", 0))

    def test_tres_noches_de_infraestructura_dejan_su_causa(self):
        # B1: si el canario nunca corre, a la tercera noche se ve por qué.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        salida = (0, "test_x ... skipped 'set AGENT_WORK_RUNTIME_SOURCE to a built R checkout'\n\nOK (skipped=1)\n")
        for noche in (1, 2, 3):
            answer = self.plan(aplicar=True, correr_banco=lambda env, cwd: salida, runtime_source="/r")
            self.assertEqual(answer["accion"], "pendiente")
        self.assertTrue(answer["causa"].startswith("el canario no corre: "), answer)
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual(entry["causa"], answer["causa"])
        self.assertEqual(entry["intentos"], 0)

    def test_el_host_ilegible_cuenta_como_ocupado(self):
        # M1: si host.sqlite no se puede leer, el canario no corre.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        self.beat(slot="free", taskId="t-1", model="zai-coding-plan/glm-5.3", since=time.time())
        (self.state / "enc-1").mkdir(exist_ok=True)
        (self.state / "enc-1" / "host.sqlite").write_bytes(b"no es sqlite")
        llamado = []
        answer = encargo.sucesion(state_root=self.state, checkout=self.checkout,
                                  opencode_bin=self.bin / "opencode", now=time.time(), aplicar=True,
                                  correr_banco=lambda env, cwd: llamado.append(1) or (0, "OK"),
                                  runtime_source="/r")
        self.assertEqual((answer["accion"], llamado), ("host-ocupado", []))

    def test_sin_latido_vivo_mira_igual_el_spool(self):
        # F6: un host sin latido vivo dejó su spool con una operación abierta; el canario no
        # corre aunque el latido ya no dé señales.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        viejo = time.time() - encargo.BEAT_ALIVE_SECONDS - 60
        self.beat(beatAt=viejo, startedAt=viejo - 3600)
        (self.state / "enc-1").mkdir(exist_ok=True)
        with contextlib.closing(sqlite3.connect(self.state / "enc-1" / "host.sqlite")) as db, db:
            db.execute("CREATE TABLE operations (status TEXT NOT NULL)")
            db.execute("INSERT INTO operations VALUES ('running')")
        llamado = []
        answer = encargo.sucesion(state_root=self.state, checkout=self.checkout,
                                  opencode_bin=self.bin / "opencode", now=time.time(), aplicar=True,
                                  correr_banco=lambda env, cwd: llamado.append(1)
                                  or (0, "test_x ... BANCO_E2E case=ingenieria desenlace=verde "
                                         "causa=ninguna\n\nOK\n"),
                                  runtime_source="/r")
        self.assertEqual((answer["accion"], llamado), ("host-ocupado", []))

    def test_revertir_vuelve_a_anterior_y_no_se_libera_a_los_7_dias(self):
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        doc = {"schema": "agent-work.succession.v1", "lines": {"zai-coding-plan/glm-{}-flash": {
            "actual": "zai-coding-plan/glm-5.4-flash", "anterior": "zai-coding-plan/glm-5.3-flash",
            "candidato": None, "estado": "promovido", "causa": None, "intentos": 0,
            "ultimo": 1_800_000_000.0, "huellaDelCatalogo": "x", "evidencia": None}}}
        self.escribir(doc)
        answer = self.plan(revertir="zai-coding-plan/glm-{}-flash")
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual((answer["accion"], entry["actual"], entry["estado"], entry["causa"]),
                         ("revertido", "zai-coding-plan/glm-5.3-flash", "rechazado", "revertido por el operador"))
        doc = self.leer()
        doc["lines"]["zai-coding-plan/glm-{}-flash"]["ultimo"] = 1_800_000_000.0 - 30 * 86400
        self.escribir(doc)
        self.assertEqual(self.plan()["lineas"][0]["causa"], "revertido por el operador")

    def test_revertir_sin_catalogo_no_guarda_huella_vieja(self):
        # F5: sin catálogo no hay huella nueva; escribir con la vieja dejaría bloqueado al
        # catálogo de otro día, y como si fuera una decisión del operador.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        doc = {"schema": "agent-work.succession.v1", "lines": {"zai-coding-plan/glm-{}-flash": {
            "actual": "zai-coding-plan/glm-5.4-flash", "anterior": "zai-coding-plan/glm-5.3-flash",
            "candidato": None, "estado": "promovido", "causa": None, "intentos": 0,
            "ultimo": 1_800_000_000.0, "huellaDelCatalogo": "x", "evidencia": None}}}
        self.escribir(doc)
        (self.bin / "opencode").write_text("#!/bin/sh\nexit 64\n")
        (self.bin / "opencode").chmod(0o755)
        (self.state / "catalogo.json").unlink(missing_ok=True)
        answer = self.plan(revertir="zai-coding-plan/glm-{}-flash")
        self.assertIs(answer["ok"], False)
        self.assertTrue(answer["causa"])
        self.assertEqual(self.leer(), doc)

    def test_revertir_lee_dentro_del_candado(self):
        # F7: el anterior cambia bajo el candado; quien leyó antes de tomarlo revierte a un
        # anterior viejo y pisa el archivo con esa foto.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        linea = "zai-coding-plan/glm-{}-flash"
        doc = {"schema": "agent-work.succession.v1", "lines": {linea: {
            "actual": "zai-coding-plan/glm-5.4-flash", "anterior": "zai-coding-plan/glm-5.3-flash",
            "candidato": None, "estado": "promovido", "causa": None, "intentos": 0,
            "ultimo": 1_800_000_000.0, "huellaDelCatalogo": "x", "evidencia": None}}}
        self.escribir(doc)
        resultado = {}

        def revertir():
            resultado["answer"] = self.plan(revertir=linea)

        with encargo._policy_lock(self.state / "sucesion.json"):
            hilo = threading.Thread(target=revertir)
            hilo.start()
            time.sleep(0.3)
            self.assertTrue(hilo.is_alive(), "el revertir no esperó el candado antes de leer")
            bajo_el_candado = copy.deepcopy(doc)
            bajo_el_candado["lines"][linea]["anterior"] = "zai-coding-plan/glm-5.2-flash"
            self.escribir(bajo_el_candado)
        hilo.join(5)
        self.assertFalse(hilo.is_alive())
        answer = resultado["answer"]
        self.assertEqual((answer["accion"], answer["actual"]),
                         ("revertido", "zai-coding-plan/glm-5.2-flash"))
        entry = self.leer()["lines"][linea]
        self.assertEqual(entry["actual"], "zai-coding-plan/glm-5.2-flash")

    def test_el_host_ocupado_no_corre_nada(self):
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        self.beat(slot="running", taskId="t-1", model="zai-coding-plan/glm-5.3", since=time.time())
        llamado = []
        answer = encargo.sucesion(state_root=self.state, checkout=self.checkout,
                                  opencode_bin=self.bin / "opencode", now=time.time(), aplicar=True,
                                  correr_banco=lambda env, cwd: llamado.append(1) or (0, "OK"),
                                  runtime_source="/r")
        self.assertEqual((answer["accion"], llamado), ("host-ocupado", []))
        self.assertFalse((self.state / "sucesion.json").exists())

    def test_el_cli_aplicar_corre_con_el_banco_inyectado(self):
        # F8: el CLI de sucesion corre el banco que AGENT_WORK_SUCESION_BANCO inyecta, no el real.
        (self.bin / "listing").write_text(LISTING + "zai-coding-plan/glm-5.4-flash\n")
        marcador = self.root / "marcador-del-banco"
        banco = self.root / "banco-falso.sh"
        banco.write_text("#!/bin/sh\n"
                         f"touch {marcador}\n"
                         "printf 'BANCO_E2E case=ingenieria desenlace=verde causa=ninguna\\n'\n"
                         "printf 'OK\\n'\n")
        banco.chmod(0o755)
        with mock.patch.dict(os.environ, {"AGENT_WORK_SUCESION_BANCO": str(banco)}):
            code, out, err = self.cli("sucesion", "--aplicar")
        answer = json.loads(out)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(answer["accion"], "promovido")
        self.assertTrue(marcador.exists(), "el banco inyectado no corrió")
        entry = self.leer()["lines"]["zai-coding-plan/glm-{}-flash"]
        self.assertEqual((entry["actual"], entry["estado"]), ("zai-coding-plan/glm-5.4-flash", "promovido"))


import sqlite3 as _sqlite3


def _base_telegram(ruta, *, session_key="agent:main:telegram:default:direct:6470689715",
                   role="user", content="confirmo abrir mistral (mistral, subscription) por favor",
                   comprimido=False):
    ruta.parent.mkdir(parents=True, exist_ok=True)
    ruta.unlink(missing_ok=True)
    db = _sqlite3.connect(ruta)
    db.execute("CREATE TABLE session_windows (session_id TEXT, session_key TEXT)")
    db.execute("CREATE TABLE transcript_events (session_id TEXT, seq INTEGER, event_json TEXT, event_zstd BLOB)")
    db.execute("INSERT INTO session_windows VALUES ('s-1', ?)", (session_key,))
    evento = {"type": "message", "timestamp": 1792000000000,
              "message": {"role": role, "content": content}}
    if comprimido:
        # Como en la base real: los eventos grandes van en event_zstd con event_json nulo.
        from compression import zstd
        db.execute("INSERT INTO transcript_events VALUES ('s-1', 7, NULL, ?)",
                   (zstd.compress(json.dumps(evento).encode()),))
    else:
        db.execute("INSERT INTO transcript_events VALUES ('s-1', 7, ?, NULL)", (json.dumps(evento),))
    db.commit()
    db.close()


class Solicitar(Mac):
    def test_solicitar_escribe_la_solicitud_y_contesta_la_frase(self):
        answer = encargo.solicitar("mistral", "mistral", "subscription",
                                   state_root=self.state, checkout=self.checkout, now=1_800_000_000.0)
        self.assertEqual(answer["frase"], "confirmo abrir mistral (mistral, subscription)")
        doc = json.loads((self.state / "solicitudes" / "mistral.json").read_text())
        self.assertEqual((doc["nombre"], doc["proveedor"], doc["cobro"], doc["frase"]),
                         ("mistral", "mistral", "subscription", answer["frase"]))
        # No toca la política.
        self.assertEqual(self.policy().unreadable, None)
        self.assertNotIn("mistral", [g.name for g in self.policy().grants])

    def test_solicitar_no_escribe_fuera_de_solicitudes(self):
        # F1 de DeepSeek en #321: el id armaba la ruta tal cual y ../host pisaba host.json.
        fuera = self.root / "fuera"
        for provider in ("../host", str(fuera), "a/b", ""):
            with self.subTest(provider=provider):
                answer = encargo.solicitar("mistral", provider, "subscription",
                                           state_root=self.state, checkout=self.checkout,
                                           now=1_800_000_000.0)
                self.assertFalse(answer["ok"])
                self.assertIn("inválido", answer["causa"])
        self.assertFalse((self.state / "solicitudes").exists())
        self.assertFalse((self.state / "host.json").exists())
        self.assertFalse(fuera.with_suffix(".json").exists())

    def test_solicitar_se_niega_si_el_nombre_es_un_cerrado(self):
        # F3 de DeepSeek en #321: como permitir, mira el nombre y el id.
        answer = encargo.solicitar("opencode-go", "otro-id", "subscription",
                                   state_root=self.state, checkout=self.checkout, now=1_800_000_000.0)
        self.assertFalse(answer["ok"])
        self.assertIn("cerrado", answer["causa"])
        self.assertFalse((self.state / "solicitudes").exists())

    def test_solicitar_se_niega_a_un_cerrado(self):
        answer = encargo.solicitar("go", "opencode-go", "subscription",
                                   state_root=self.state, checkout=self.checkout, now=1_800_000_000.0)
        self.assertFalse(answer["ok"])
        self.assertIn("cerrado", answer["causa"])
        self.assertFalse((self.state / "solicitudes").exists())


class TelegramCitation(Mac):
    def fake_ssh(self, argv, entrada=None, timeout=None):
        # El ssh de juguete corre lo que recibe por stdin donde apunta HOME (zsh si está).
        import subprocess as _sp
        pedido = argv[-1].strip("'")
        # La Mini corre Python 3.9: sin compression.zstd. Un paquete compression que no
        # importa, por delante de la biblioteca estándar, la imita (F2 de DeepSeek en #321).
        sin_zstd = self.root / "py39"
        (sin_zstd / "compression").mkdir(parents=True, exist_ok=True)
        (sin_zstd / "compression" / "__init__.py").write_text(
            "raise ImportError('Python 3.9 no trae compression')\n")
        env = {**os.environ, "HOME": str(self.toy_home), "PYTHONPATH": str(sin_zstd)}
        hecho = _sp.run([sys.executable, "-", pedido], input=entrada, capture_output=True,
                        text=True, env=env)
        return hecho.returncode, hecho.stdout, hecho.stderr

    def setUp(self):
        super().setUp()
        self.toy_home = self.root / "mini"
        _base_telegram(self.toy_home / ".openclaw/agents/main/agent/openclaw-agent.sqlite")

    def permitir_tg(self, **cambios_db):
        (self.bin / "listing").write_text(LISTING + "mistral/mistral-large\n")
        _base_telegram(self.toy_home / ".openclaw/agents/main/agent/openclaw-agent.sqlite", **cambios_db)
        return encargo.permitir(
            "mistral", provider="mistral", billing="subscription", ref="tg:s-1:7",
            quote="confirmo abrir mistral (mistral, subscription)",
            state_root=self.state, checkout=self.checkout, prompts=self.prompts,
            opencode_bin=self.bin / "opencode", correr=self.fake_ssh)

    def test_pasa_con_la_sesion_del_dueno_y_rol_user(self):
        row = self.permitir_tg()
        self.assertNotIsInstance(row, str)
        policy = self.policy()
        glm = policy.grant_for("mistral")
        self.assertEqual(glm.decision.ref, "tg:s-1:7")

    def test_pasa_con_el_evento_comprimido(self):
        # F2 de DeepSeek en #321: ~39% de las filas de main van en event_zstd y la Mini no
        # descomprime; el evento viaja en base64 y se descomprime en la Mac.
        row = self.permitir_tg(comprimido=True)
        self.assertNotIsInstance(row, str, row)
        self.assertEqual(self.policy().grant_for("mistral").decision.ref, "tg:s-1:7")

    def test_un_seq_que_no_es_un_numero_ascii_se_niega_limpio(self):
        # F5 de DeepSeek en #321: "²".isdigit() es verdadero e int("²") revienta.
        (self.bin / "listing").write_text(LISTING + "mistral/mistral-large\n")
        row = encargo.permitir(
            "mistral", provider="mistral", billing="subscription", ref="tg:s-1:\u00b2",
            quote="confirmo abrir mistral (mistral, subscription)",
            state_root=self.state, checkout=self.checkout, prompts=self.prompts,
            opencode_bin=self.bin / "opencode", correr=self.fake_ssh)
        self.assertIsInstance(row, str)
        self.assertIn("no tiene la forma", row)

    def test_se_niega_con_otra_sesion_con_assistant_y_con_frase_ausente(self):
        row = self.permitir_tg(session_key="agent:main:telegram:default:direct:999")
        self.assertIsInstance(row, str)
        self.assertIn("no coteja", row)
        row = self.permitir_tg(role="assistant")
        self.assertIsInstance(row, str)
        row = self.permitir_tg(content="otra cosa entirely")
        self.assertIsInstance(row, str)


class Cerrar(Mac):
    def test_closing_the_default_provider_also_drops_the_default(self):
        # F1 de VEREDICTO-SUA04-G2-r1-bots: cerrar el proveedor del modelo por omisión es el
        # freno de emergencia y no puede quedarse sin escribir. El documento pierde
        # defaultGrant, la política carga, y un preparar sin modelo da la frase nueva.
        for args in (("--por", "coordinador", "--motivo", "prueba de freno"),
                     ("--ref", "P10902", "--cita", "cierra muse para encargos")):
            with self.subTest(args=args):
                code, out, err = self.cli("cerrar", "zai-coding-plan", *args)
                self.assertEqual(code, 0, err)
                self.assertIn("se quitó también el modelo por omisión", err + out)
                policy = self.policy()
                self.assertIsNone(policy.unreadable)
                self.assertIsNone(policy.default_grant)
                self.assertIn("zai-coding-plan", policy.closed)
                self.assertNotIn("glm", [grant.name for grant in policy.grants])
                self.beat()
                answer = self.preparar()
                self.assertEqual((answer["ok"], answer["causa"]), (False, "sin-modelo-por-omision"))
                self.assertEqual(answer["frase"],
                                 "no hay modelo por omisión: el permiso que lo daba se cerró; "
                                 "pide el encargo con --modelo")
                self.assertEqual(answer["accion"], "preguntar-a-david")
                # El siguiente subTest parte de la política íntegra otra vez.
                self.setUp()

    def test_closing_removes_the_grant_and_leaves_davids_words(self):
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out.splitlines()[1].split(), ["-", "meta", "cerrado", "-", "con-sesion", "6", "-", "-", "-",
                                                       "-", "David", "2026-10-15", "P10902"])
        policy = self.policy()
        self.assertEqual(([grant.name for grant in policy.grants], sorted(policy.closed)),
                         (["glm", "claude", "grok", "gpt", "kimi", "qwen", "deepseek"],
                          ["meta", "opencode", "opencode-go", "zai"]))
        self.assertEqual(policy.closed["meta"].decision.quote, "cierra muse para encargos")
        answer = json.loads(self.cli("preparar", "--repo", str(self.repo), "--modelo", "muse wonder")[1])
        self.assertEqual(answer["causa"], "proveedor-no-permitido")
        self.assertIn("meta está cerrado para encargos. David, 2026-10-15: «cierra muse para encargos».", answer["frase"])
        written = self.policy_path.read_bytes()
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual((code, out, self.policy_path.read_bytes() == written), (3, "", True))
        self.assertIn("meta ya está cerrado y su cierre no se reemplaza", err)

    def test_closing_is_the_emergency_brake_and_writes_even_when_opencode_does_not_answer(self):
        (self.bin / "version").write_text("")
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual(code, 0, err)
        self.assertEqual(out.splitlines()[1].split(), ["-", "meta", "cerrado", "-", "sin-catalogo", "-", "-", "-", "-",
                                                       "-", "David", "2026-10-15", "P10902"])
        self.assertIn("opencode no contestó", err)
        policy = self.policy()
        self.assertEqual((policy.grant_for("meta"), policy.closed["meta"].decision.ref), (None, "P10902"))
        (self.bin / "opencode").unlink()
        self.assertEqual(self.cli("cerrar", "xai", "--ref", "P10902", "--cita", "cierra muse para encargos")[0], 0)
        self.assertIn("xai", self.policy().closed)

    def test_an_emergency_closure_closes_without_putting_words_in_davids_mouth(self):
        code, out, err = self.cli("cerrar", "xai", "--por", "Claude en la Mac", "--motivo", "gasto que nadie pidió en xai")
        self.assertEqual(code, 0, err)
        today = time.strftime("%Y-%m-%d", time.gmtime())
        self.assertEqual(out.splitlines()[1].split(), ["-", "xai", "cerrado", "-", "con-sesion", "13", "-", "-", "-",
                                                       "-", "Claude",
                                                       "en", "la", "Mac", today, "sin-cotejar"])
        self.assertIn("sin cita cotejada. No es una decisión de David", err)
        closure = self.policy().closed["xai"].decision
        self.assertEqual((closure.by, closure.on, closure.ref, closure.quote),
                         ("Claude en la Mac", today, "sin-cotejar", "gasto que nadie pidió en xai"))
        self.assertIsNone(self.policy().grant_for("xai"))
        answer = json.loads(self.cli("preparar", "--modelo", "xai/grok-4.7")[1])
        self.assertEqual((answer["causa"], answer["frase"].split(". Permitidos")[0]), (
            "proveedor-no-permitido",
            f"xai está cerrado para encargos. Claude en la Mac, {today}, sin-cotejar: «gasto que nadie pidió en xai»"))
        listed = self.cli("proveedores")[1].splitlines()
        self.assertEqual([line.split()[-1] for line in listed if " cerrado " in line],
                         ["P10845", "P10867", "P9840", "sin-cotejar"])

    def test_an_emergency_closure_names_who_closes_and_why_and_is_never_david(self):
        before = self.policy_path.read_bytes()
        for args, piece in ((["--por", "David", "--motivo", "lo dijo ayer"], "--por no puede nombrar a David"),
                            (["--por", " david ", "--motivo", "lo dijo ayer"], "--por no puede nombrar a David"),
                            (["--por", "David (emergencia)", "--motivo", "x"], "--por no puede nombrar a David"),
                            (["--por", "el DAVID de siempre", "--motivo", "x"], "--por no puede nombrar a David"),
                            (["--por", "Ｄａｖｉｄ", "--motivo", "x"], "--por no puede nombrar a David"),
                            (["--por", "Da\u200bvid", "--motivo", "x"], "--por no puede nombrar a David"),
                            (["--por", "Dav\u00adid\ufeff", "--motivo", "x"], "--por no puede nombrar a David"),
                            (["--por", "Claude en la Mac"], "--por y --motivo"), (["--motivo", "gasto raro"], "--por"),
                            (["--por", "Claude", "--motivo", "  "], "quote"), ([], "--ref y --cita"),
                            (["--ref", "P10902"], "--ref y --cita"),
                            (["--por", "Claude", "--motivo", "gasto raro", "--ref", "P10902", "--cita",
                              "cierra muse para encargos"], "--por y --motivo"),
                            (["--ref", "Z9", "--cita", "cierra xai"], "no es un prompt P####")):
            with self.subTest(args):
                code, out, err = self.cli("cerrar", "xai", *args)
                self.assertEqual((code, out, self.policy_path.read_bytes() == before), (3, "", True))
                self.assertIn(piece, err)

    def test_closing_needs_davids_literal_words_too(self):
        before = self.policy_path.read_bytes()
        code, out, err = self.cli("cerrar", "meta", "--ref", "P10902", "--cita", "cierra meta")
        self.assertEqual((code, out), (3, ""))
        self.assertIn("no es una subcadena literal del prompt P10902", err)
        self.assertEqual(self.cli("cerrar", "Meta", "--ref", "P10902", "--cita", "cierra muse")[0], 3)
        self.assertEqual(self.policy_path.read_bytes(), before)

    def test_closing_the_word_of_a_bound_grant_is_refused_because_its_provider_would_keep_running(self):
        before = self.policy_path.read_bytes()
        code, out, err = self.cli("cerrar", "muse", "--ref", "P10902", "--cita", "cierra muse para encargos")
        self.assertEqual((code, out, self.policy_path.read_bytes() == before), (3, "", True))
        self.assertIn("muse es el nombre del permiso de meta", err)

    def test_closing_a_grant_without_id_goes_by_davids_word_for_it(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        self.assertEqual(self.cli("cerrar", "kimi", "--ref", "P10902", "--cita", "cierra muse para encargos")[0], 0)
        policy = self.policy()
        self.assertEqual(([grant.name for grant in policy.grants][4:], "kimi" in policy.closed),
                         (["muse", "qwen", "deepseek"], True))


class TwoWritersAtOnce(Mac):
    """The policy lock, without a race: the first writer stops right before it replaces the file, the second
    one starts, and the first waits to see whether the second gets into the same stretch."""

    def writers(self, first, second):
        """Runs `first` on this thread and starts `second` when `first` is about to replace the file. Returns
        what each answered and whether `second` reached its own replace while `first` was still there."""
        answers, reached_the_lock, replacing = {}, threading.Event(), threading.Event()
        other = threading.Thread(target=lambda: answers.__setitem__("second", second()))

        def checkpoint(where):
            if threading.current_thread() is other:
                (reached_the_lock if where == "before-lock" else replacing).set()
            elif where == "before-replace":
                other.start()
                self.assertTrue(reached_the_lock.wait(10))
                answers["overlapped"] = replacing.wait(0.5)

        with mock.patch.object(encargo, "_checkpoint", checkpoint):
            answers["first"] = first()
            other.join(20)
        self.assertFalse(other.is_alive())
        return answers

    def where(self):
        return {"checkout": self.checkout, "state_root": self.state, "prompts": self.prompts,
                "opencode_bin": self.bin / "opencode"}

    def grant(self, name, quote="permite mistral para por CLI"):
        return lambda: encargo.permitir(name, provider=None, billing="subscription", ref="P10901", quote=quote,
                                        **self.where())

    def test_an_emergency_closure_that_arrives_while_a_grant_is_being_written_is_not_lost(self):
        answers = self.writers(self.grant("mistral"), lambda: encargo.cerrar(
            "xai", ref=None, quote=None, by="Claude en la Mac", reason="carrera", now=time.time(), **self.where()))
        self.assertEqual((answers["overlapped"], answers["first"].decision, answers["second"].decision),
                         (False, "permitido", "cerrado"))
        policy = self.policy()
        self.assertEqual((sorted(policy.closed), [grant.name for grant in policy.grants]),
                         (["opencode", "opencode-go", "xai", "zai"],
                          ["glm", "claude", "gpt", "muse", "kimi", "qwen", "deepseek", "mistral"]))

    def test_a_grant_that_arrives_while_another_grant_is_being_written_is_not_lost(self):
        answers = self.writers(self.grant("mistral"), self.grant("cohere", "cobra por suscripción"))
        self.assertEqual((answers["overlapped"], answers["first"].name, answers["second"].name),
                         (False, "mistral", "cohere"))
        self.assertEqual([grant.name for grant in self.policy().grants][8:], ["mistral", "cohere"])

    def test_a_grant_decided_on_an_entry_that_changed_meanwhile_is_not_written_over_it(self):
        ran = []

        def checkpoint(where):
            if where == "before-lock" and not ran:
                ran.append(None)
                ran[0] = encargo.permitir("qwen", provider=None, billing=None, ref="P10886", include=("qwen3.8*",),
                                          quote="dejar solo los modelos qwen", **self.where())

        with mock.patch.object(encargo, "_checkpoint", checkpoint):
            answer = encargo.permitir("qwen", provider=None, billing="per-token", ref="P10901",
                                      quote="permite mistral para por CLI", **self.where())
        self.assertEqual((ran[0].permitted_models, answer),
                         (2, "el permiso qwen cambió mientras este comando corría: vuelve a correrlo"))
        qwen = self.policy().grant_for("alibaba-token-plan")
        self.assertEqual((qwen.billing, qwen.models.include, qwen.decision.ref), ("subscription", ("qwen3.8*",), "P10867"))

    def test_a_closure_of_the_same_provider_wins_over_the_grant_that_was_still_being_decided(self):
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        closed_meanwhile = []

        def checkpoint(where):
            if where == "before-lock" and not closed_meanwhile:
                closed_meanwhile.append(None)
                closed_meanwhile[0] = encargo.cerrar("kimi-code-plan-cn", ref=None, quote=None, by="Claude en la Mac",
                                                     reason="carrera", now=time.time(), **self.where())

        with mock.patch.object(encargo, "_checkpoint", checkpoint):
            answer = encargo.permitir("kimi", provider="kimi-code-plan-cn", billing=None, ref=None, quote=None,
                                      **self.where())
        self.assertEqual(closed_meanwhile[0].decision, "cerrado")
        self.assertIn("kimi-code-plan-cn está cerrado por Claude en la Mac", answer)
        self.assertEqual((self.policy().grant_for("kimi-code-plan-cn"), "kimi-code-plan-cn" in self.policy().closed),
                         (None, True))


class ClosedStaysClosed(Mac):
    """No command reopens a closed provider. Reopening is an edit of the policy file in a PR, with David's
    new phrase, that also changes the test that pins the closures."""

    def assert_stays_closed(self, *args, pieces=()):
        before = self.policy_path.read_bytes()
        try:
            code, out, err = self.cli(*args)
        except SystemExit as stopped:
            code, out, err = stopped.code, "", ""
        self.assertEqual((out, self.policy_path.read_bytes() == before), ("", True), err)
        self.assertIn(code, (2, 3))
        for piece in pieces:
            self.assertIn(piece, err)
        self.assertEqual(sorted(self.policy().closed), ["opencode", "opencode-go", "zai"])
        answer = json.loads(self.cli("preparar", "--modelo", "opencode-go/deepseek-v4-pro")[1])
        self.assertEqual(answer["causa"], "proveedor-no-permitido")

    def test_the_three_commands_of_the_first_verdict_leave_opencode_go_closed(self):
        own_words = ["permitir", "opencode-go", "--cobro", "subscription", "--ref", "P30001", "--cita",
                     "open code go es solamente para main"]
        self.assert_stays_closed(*own_words, "--reabre")
        self.assert_stays_closed(*own_words, pieces=["opencode-go está cerrado", "PR"])
        self.assert_stays_closed("permitir", "opencode-go", "--proveedor", "opencode-go",
                                 pieces=["opencode-go está cerrado"])

    def test_an_invented_quote_with_a_date_of_the_callers_choosing_reopens_nothing(self):
        invented = ["permitir", "opencode-go", "--proveedor", "opencode-go", "--cobro", "subscription", "--ref", "Z9",
                    "--cita", "para este proyecto usa opencode go tambien"]
        self.assert_stays_closed(*invented, "--fecha", "2027-01-01", "--reabre")
        self.assert_stays_closed(*invented, "--fecha", "2027-01-01")
        self.assert_stays_closed(*invented, pieces=["opencode-go está cerrado"])

    def test_closing_again_does_not_replace_the_closure_so_nothing_can_be_reopened_behind_it(self):
        self.assert_stays_closed("cerrar", "opencode-go", "--ref", "P200", "--cita", "texto antiguo cualquiera",
                                 pieces=["opencode-go ya está cerrado", "«open code go es solamente para main»"])
        self.assertEqual(self.policy().closed["opencode-go"].decision.ref, "P10845")
        after = ["permitir", "opencode-go", "--proveedor", "opencode-go", "--cobro", "subscription", "--ref", "P30010",
                 "--cita", "pero tengo deepseek por api"]
        self.assert_stays_closed(*after, "--reabre")
        self.assert_stays_closed(*after, pieces=["opencode-go está cerrado"])
        self.assert_stays_closed("cerrar", "zai", "--ref", "P10902", "--cita", "cierra muse para encargos",
                                 pieces=["zai ya está cerrado"])

    def test_a_true_new_phrase_of_david_does_not_reopen_by_command_either(self):
        new_phrase = ["--cobro", "subscription", "--ref", "P10903", "--cita", "reabre opencode go para encargos"]
        self.assert_stays_closed("permitir", "opencode-go", "--proveedor", "opencode-go", *new_phrase, "--reabre")
        self.assert_stays_closed(
            "permitir", "opencode-go", "--proveedor", "opencode-go", *new_phrase,
            pieces=["opencode-go está cerrado por David (2026-10-12, P10845): «open code go es solamente para main»",
                    "proveedores-permitidos.json", "PR", "la prueba que fija los cierres"])
        self.assert_stays_closed("permitir", "opencode-go", *new_phrase, pieces=["opencode-go está cerrado"])

    def test_a_grant_of_another_name_cannot_bind_a_closed_id(self):
        new_phrase = ["--cobro", "subscription", "--ref", "P10903", "--cita", "reabre opencode go para encargos"]
        self.edit_policy(lambda doc: doc["providers"][5].update(provider=None))
        for args in (["kimi", "--proveedor", "opencode-go"], ["kimi", "--proveedor", "opencode-go", *new_phrase],
                     ["go", "--proveedor", "opencode-go", *new_phrase], ["glm", "--proveedor", "zai", *new_phrase],
                     ["otro", "--proveedor", "opencode", *new_phrase]):
            with self.subTest(args):
                self.assert_stays_closed("permitir", *args, pieces=["está cerrado"])

    def test_a_filter_that_names_a_closed_provider_opens_nothing(self):
        phrase = ["--ref", "P10886", "--cita", "dejar solo los modelos qwen"]
        self.assert_stays_closed("permitir", "opencode", "--solo", "big-*", *phrase, pieces=["opencode está cerrado"])
        self.assert_stays_closed("permitir", "opencode-go", "--proveedor", "opencode-go", "--solo", "deepseek*", *phrase,
                                 pieces=["opencode-go está cerrado"])
        self.assert_stays_closed("permitir", "qwen", "--solo", "opencode-go/*", *phrase, pieces=["no cubre ninguno"])


class PlistDeSucesion(unittest.TestCase):
    def test_el_plist_de_sucesion_trae_argumentos_que_encargo_acepta(self):
        # F9 de #319: --checkout y --state-root son del parser raíz y van antes del
        # subcomando; después de "sucesion" argparse los rechaza y el launchd no hace nada.
        import plistlib
        plist = ROOT / "scripts" / "mac" / "ai.goncloud.agent-work-sucesion.plist"
        with plist.open("rb") as archivo:
            argv = plistlib.load(archivo)["ProgramArguments"]
        self.assertTrue(argv[1].endswith("encargo.py"))
        args = encargo._parser().parse_args(argv[2:])
        self.assertEqual(args.command, "sucesion")
        self.assertTrue(args.aplicar)


if __name__ == "__main__":
    unittest.main()

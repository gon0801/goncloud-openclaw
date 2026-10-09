#!/usr/bin/env python3
"""Requester-side routing contract for managed tasks."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
from routing import prepare_request, RouteUnavailable  # noqa: E402
import routing  # noqa: E402
import native_gateway  # noqa: E402


def repo_wake_sources(root):
    # T9 :266: tambien quien pone la marca del vigilante y los runbooks que lo hacen.
    return subprocess.run(
        ["git", "grep", "-l", "-E", "--", "--vigia|vigia-mac|\"\\$vigia\" = \"claw\"|OPENCLAW_WATCH[[:space:]]+1",
         "--", "scripts", "agents", "docs/runbooks", ":!scripts/tests"],
        cwd=root, capture_output=True, text=True, check=True,
    ).stdout.splitlines()


class AgentsRouting(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.brief = self.root / "brief.txt"
        self.brief.write_text("Review revision aaaa", encoding="utf-8")
        self.instructions = self.root / "instructions"
        self.instructions.mkdir()
        self.revision = {"kind": "code", "repository": "repo", "sha": "a" * 40}
        self.coverage = json.loads((ROOT / "docs/evidence/agent-work/coverage.json").read_text())

    def request(self, requester, target, *, coverage=None):
        return prepare_request(requester=requester, target=target, key="review-r1",
                               brief=self.brief, instruction_root=self.instructions,
                               input_revision=self.revision, result_contract="review.v1",
                               coverage=coverage or self.coverage)

    def test_ingenieria_to_adversary_preserves_target_and_brief(self):
        request = self.request("ingenieria", "adversary")
        self.assertEqual(request["assignment"]["target"], {"kind": "agent", "agentId": "adversary"})
        self.assertEqual(request["key"], "review-r1")
        self.assertEqual(request["assignment"]["continuation"], {"kind": "requester"})
        ref = request["assignment"]["instructionRef"]
        self.assertEqual((self.instructions / ref["ref"].split(":")[1]).read_bytes(),
                         self.brief.read_bytes())
        self.assertEqual(self.request("ingenieria", "adversary"), request)

    def test_operaciones_to_ingenieria_keeps_operaciones_as_requester(self):
        request = self.request("operaciones", "ingenieria")
        self.assertEqual(request["assignment"]["target"], {"kind": "agent", "agentId": "ingenieria"})
        self.assertEqual(request["assignment"]["continuation"], {"kind": "requester"})

    def test_remote_cli_requires_certified_host_adapter(self):
        with self.assertRaisesRegex(RouteUnavailable, "windows-remote/codex"):
            self.request("ingenieria", "windows-remote/codex")
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["windows-remote"]["codex"] = "certified"
        request = self.request("ingenieria", "windows-remote/codex", coverage=certified)
        self.assertEqual(request["assignment"]["target"],
                         {"kind": "cli", "hostId": "windows-remote", "adapterId": "codex"})

    def test_no_inventory_cli_is_certified_so_no_cli_route_or_claim_opens(self):
        class Client:
            def claim_host(self, *_):
                raise AssertionError("an uncertified adapter must not reach the gateway")

        refused = []
        for requester, host_id in sorted(routing.CLI_ROUTES):
            for adapter_id in self.coverage["cliAdapters"]:
                with self.assertRaisesRegex(RouteUnavailable, f"route {host_id}/{adapter_id} is not certified"):
                    self.request(requester, f"{host_id}/{adapter_id}")
                client = Client()
                client.host_id = host_id
                with self.assertRaisesRegex(ValueError, "host adapter route is not certified"):
                    native_gateway.claim_cli_once(client, host=None, manager=None, adapter_id=adapter_id,
                                                  instance_id="instance-one", session="worker-one",
                                                  workspace_root=self.root, deliver=lambda *_: None,
                                                  coverage=self.coverage)
                refused.append(f"{host_id}/{adapter_id}")
        self.assertEqual(len(refused), 14)

    def test_cli_route_is_limited_to_its_requester(self):
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["mac-local"]["claude_opus"] = "certified"
        with self.assertRaisesRegex(RouteUnavailable, "outside the managed perimeter"):
            self.request("operaciones", "mac-local/claude_opus", coverage=certified)

    def test_main_cli_route_stays_disabled_until_mac_local_is_certified(self):
        with self.assertRaisesRegex(RouteUnavailable, "not certified"):
            self.request("main", "mac-local/claude_opus")
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["mac-local"]["claude_opus"] = "certified"
        request = self.request("main", "mac-local/claude_opus", coverage=certified)
        self.assertEqual(request["assignment"]["target"],
                         {"kind": "cli", "hostId": "mac-local", "adapterId": "claude_opus"})

    def test_outside_managed_perimeter_is_rejected(self):
        with self.assertRaisesRegex(RouteUnavailable, "route"):
            self.request("scout", "adversary")

    def test_agent_instructions_call_the_guarded_route_and_keep_legacy_outside(self):
        main_skill = (ROOT / "agents/main/agent/workshop-skills/agent-dispatch/SKILL.md").read_text()
        self.assertIn("managed_tasks_submit", main_skill)
        self.assertIn("fuera de ese perímetro conservan el flujo", main_skill)
        for agent, target in (("ingenieria", "adversary"), ("operaciones", "ingenieria")):
            skill = ROOT / f"agents/{agent}/agent/workshop-skills/managed-task-routing/SKILL.md"
            self.assertTrue(skill.is_file(), f"missing managed route skill for {agent}")
            content = skill.read_text()
            self.assertIn(f"--requester {agent} --target {target}", content)
            self.assertIn("scripts/agent-work/routing.py", content)
            self.assertIn("managed_tasks_submit", content)
            self.assertIn("managed_tasks_admit", content)
            self.assertIn("Fuera del perímetro gestionado", content)

    def test_legacy_dispatch_routes_are_declared_outside_the_perimeter(self):
        # T9 :265: cada ruta vieja de despacho, y cada destino gestionado, lo dice en su lugar exacto.
        for path, antes, frase, despues in (
            ('agents/main/agent/workshop-skills/agent-dispatch/SKILL.md', '## Chain dispatch (brief / "-saikit" lane)\n\n', 'Legacy route (T9 `:265`): this chain (`sessions_spawn` to implementer, verifier and reviewer) stays outside the managed perimeter until its adoption (T12). Inside a managed run the runtime rejects `sessions_spawn` and `sessions_send`; only the requester-target pairs listed in "Ruteo nativo vs. legado" use the guarded route, and none of them goes from `main` to implementer, verifier or reviewer.', '\n\n0. '),
            ('agents/main/agent/workshop-skills/agent-dispatch/SKILL.md', '## External review loop (Claude on the Mac)\n\n', 'Legacy route (T9 `:265`): this loop (tmux delivery, `OPENCLAW_WATCH`, `VEREDICTO` files) stays outside the managed perimeter until its adoption (T12). The managed `main` to Mac CLI route is the one in "Ruteo nativo vs. legado", and it stays off until `mac-local` is certified.', '\n\nDavid repeatedly orders'),
            ('agents/main/agent/workshop-skills/native-harness-orchestration/SKILL.md', '| Cerrar | `corrida.sh cerrar <id>` | `cerrada <id>` |\n\n', 'Ruta anterior (T9 `:265`): la corrida abierta con `--vigia claw` y los CLI arrancados con `adaptador start` y entregados con `adaptador deliver` (`ADAPTADOR-MARCA`) siguen fuera del perímetro gestionado hasta su adopción (T12). Un CLI gestionado entra solo por `Host.apply`: en producción, `claim_cli_once` con `TmuxTransport`; `adaptador deliver-ref` es su transporte alterno por `corrida.sh`. Los dos marcan la sesión con `AGENT_WORK_MANAGED=1`, y sobre esa sesión no se usa `adaptador deliver`.', '\n\n## Pre-install / manual (Fases 14 y 23)'),
            ('agents/ingenieria/agent/workshop-skills/managed-task-routing/SKILL.md', 'Si una operación gestionada es rechazada, informa el bloqueo sin reenviarla por sessions_spawn, sessions_send ni CLI directo.\n\n', 'Si te llegó un encargo gestionado (T9 `:265`): cuando `managed_tasks_report` está entre tus tools, el resultado sale solo con `managed_tasks_report`; dentro de ese run el runtime rechaza `sessions_send` y `sessions_spawn`, así que no reportes ni delegues por ahí, tampoco los carriles paralelos de `mac-node-ops`.', '\n'),
        ):
            text = (ROOT / path).read_text(encoding="utf-8")
            self.assertEqual(text.count(antes + frase + despues), 1,
                             f"{path}: la frase de la ruta vieja (T9 :265) no esta justo despues de {antes.splitlines()[0]!r}")

    def test_main_cli_loop_instructions_keep_the_route_disabled_until_certified(self):
        lines = (ROOT / "agents/main/agent/workshop-skills/agent-dispatch/SKILL.md").read_text(
            encoding="utf-8"
        ).splitlines()
        starts = [i for i, line in enumerate(lines)
                  if line.startswith("La ruta de `main` a un CLI de la Mac")]
        self.assertEqual(len(starts), 1, "expected exactly one main CLI route paragraph")
        paragraph_lines = []
        for line in lines[starts[0]:]:
            if not line.strip():
                break
            paragraph_lines.append(line)
        paragraph = " ".join("\n".join(paragraph_lines).split())
        for expected in (
            "--requester main --target mac-local/",
            "managed_tasks_submit",
            "managed_tasks_admit",
            "isolated",
            "agent-work.result.v1",
            "UserAdopted",
            "delivery-unaccepted",
            "no lo vuelvas a teclear ni a pedir a ciegas",
            "Mientras `mac-local` no esté `certified` en `coverage.json`, esta ruta está deshabilitada",
        ):
            self.assertIn(expected, paragraph)

    def test_cli_prints_native_submit_parameters(self):
        command = [sys.executable, str(ROOT / "scripts/agent-work/routing.py"),
                   "--requester", "ingenieria", "--target", "adversary",
                   "--key", "review-r1", "--brief", str(self.brief),
                   "--instruction-root", str(self.instructions),
                   "--revision-json", json.dumps(self.revision),
                   "--result-contract", "review.v1"]
        output = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(output.stdout), self.request("ingenieria", "adversary"))

    def test_every_doc_that_marks_a_session_names_the_managed_exception(self):
        # T9 :266: quien manda marcar con OPENCLAW_WATCH dice tambien que una gestionada no se marca ni se relanza.
        exception = {
            "agents": "Exception (T9 `:266`): a managed session (tmux `AGENT_WORK_MANAGED=1`, or a run registry "
                      "entry with `encargo_ref` or `host_id`) is never marked with `OPENCLAW_WATCH` and never "
                      "relaunched by hand; its host reports a close, a dialog or a missed deadline to the requester.",
            "docs": "Excepción (T9 `:266`): una sesión gestionada (`AGENT_WORK_MANAGED=1` en tmux, o una entrada "
                    "del registro con `encargo_ref` o `host_id`) nunca se marca con `OPENCLAW_WATCH` ni se relanza "
                    "a mano; su host le reporta al solicitante el cierre, el diálogo o el plazo vencido.",
        }
        listed = subprocess.run(
            ["git", "grep", "-l", "-E", "-e", "OPENCLAW_WATCH[[:space:]=]+[\"']?1",
             "-e", "marcada con `OPENCLAW_WATCH`", "-e", "se marca al lanzarla", "-e", "(registra y |la |y la )marca (la sesi[oó]n )?antes",
             "-e", "marks? BEFORE", "--", "agents", "docs/runbooks"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        self.assertLessEqual({
            "agents/main/agent/workshop-skills/agent-dispatch/SKILL.md",
            "agents/main/agent/workshop-skills/mac-tmux-control/SKILL.md",
            "docs/runbooks/autopilot-fase10.md", "docs/runbooks/autopilot-fase17.md",
            "docs/runbooks/autopilot-fase7.md", "docs/runbooks/base-openclaw.md",
            "docs/runbooks/guia-del-vigia.md", "docs/runbooks/loop-autopilot.md",
            "docs/runbooks/base-summonaikit.md", "docs/runbooks/autopilot-fase14.md",
            "docs/runbooks/autopilot-fase15.md",
        }, set(listed))
        for path in listed:
            self.assertIn(exception[path.split("/")[0]], (ROOT / path).read_text(),
                          f"{path} manda marcar con OPENCLAW_WATCH y no dice la excepcion de las gestionadas")

    def test_every_live_cron_is_classified(self):
        # T9 :265: cada cron vivo de la foto queda clasificado, con su perimetro y su razon; los de negocio
        # conservan horario y funcion (el sha256 del mensaje vivo). La foto es un dado: su sha256 es literal.
        reasons = {
            "business": "cron de negocio: conserva horario y función; fuera del perímetro, no delega trabajo con resultado esperado (T9 :265)",
            "technical": "cron técnico: despierta un modelo o corre un comando sin delegar trabajo con resultado esperado; fuera del perímetro (T9 :265)",
            "system": "tarea interna del gateway; no delega (T9 :265)",
            "vigia": "vigía de un loop: conserva su ruta hasta que T12 lo suspenda y retire por entrada (plan :312, :317 y :318; T9 :265 y :266)",
        }
        perimeters = {"business": "out-of-perimeter", "technical": "out-of-perimeter",
                      "system": "out-of-perimeter", "vigia": "legacy-until-adoption"}
        cron_jobs = self.coverage["cronJobs"]
        self.assertEqual(cron_jobs["snapshot"], "docs/evidence/agent-work/B4-26-cron-snapshot.json")
        self.assertEqual(hashlib.sha256((ROOT / cron_jobs["snapshot"]).read_bytes()).hexdigest(),
                         "c300335f2b00ed9ddd7ac8056acba9102da8e5ce97bb4d065c9d51966d86986f",
                         "the cron snapshot changed: a new snapshot is a new file and a new literal here")
        snapshot = json.loads((ROOT / cron_jobs["snapshot"]).read_text())
        jobs = {job["id"]: job for job in snapshot["jobs"]}
        self.assertEqual(len(jobs), snapshot["total"], "the snapshot lost or repeated a job")
        ids = [row["id"] for row in cron_jobs["entries"]]
        self.assertEqual(len(ids), len(set(ids)), "a cron is classified twice")
        self.assertEqual(set(ids), set(jobs), "cronJobs must classify every live cron and nothing else")
        kinds = {}
        for row in cron_jobs["entries"]:
            kinds.setdefault(row["kind"], set()).add(row["name"])
        self.assertEqual(kinds.get("business"), {
            "packing-digest-20h", "packing-extras-7h", "packing-extras-11h", "verif-digest-20h",
            "Renueva el token de acceso de Shopify de la tienda theglamw…"})
        self.assertEqual(kinds.get("system"), {"Memory Dreaming Promotion"})
        wake_ids = {entry["id"] for entry in self.coverage["modelWakes"]["entries"] if entry["kind"] == "cron"}
        for row in cron_jobs["entries"]:
            job = jobs[row["id"]]
            with self.subTest(cron=row["name"]):
                self.assertEqual(row["name"], job["name"])
                self.assertIn(row["kind"], reasons)
                self.assertEqual(row["perimeter"], perimeters[row["kind"]])
                self.assertEqual(row["reason"], reasons[row["kind"]])
                self.assertEqual(row["kind"] == "vigia", job["name"].endswith("-vigia"))
                if row["kind"] == "vigia":
                    self.assertIn(row["id"], wake_ids, "a live vigia is missing from modelWakes")
                if row["kind"] == "business":
                    self.assertEqual(row["schedule"], job["schedule"])
                    self.assertEqual(row["messageSha256"], job["messageSha256"])
                else:
                    self.assertNotIn("schedule", row)

    def test_model_wakes_inventory_lists_every_repo_wake_source(self):
        wakes = self.coverage["modelWakes"]
        # T9 :265: la foto completa de crons (B4-26) reemplaza a la de B4-8, que solo guardo dos vigias.
        self.assertEqual(wakes["snapshot"], "docs/evidence/agent-work/B4-26-cron-snapshot.json")
        snapshot = json.loads((ROOT / wakes["snapshot"]).read_text())
        self.assertEqual(wakes["capturedAt"], snapshot["capturedAt"])
        sources = [entry["source"] for entry in wakes["entries"]]
        recreators = [recreator["path"] for entry in wakes["entries"]
                      for recreator in entry["recreators"]]
        listed = repo_wake_sources(ROOT)
        self.assertTrue(listed, "git grep found no repo wake sources")
        for path in listed:
            self.assertTrue(
                any(source.startswith(f"{path}:") for source in sources) or path in recreators,
                f"repo wake source {path} is missing from modelWakes",
            )
        live = {job["id"]: job for job in snapshot["jobs"] if job["name"].endswith("-vigia")}
        live_ids = set(live)
        self.assertTrue(live_ids, "the snapshot has no live vigia")
        live_names = {job["name"] for job in live.values()}
        for entry in wakes["entries"]:
            job = live.get(entry["id"])
            if job:
                self.assertEqual((entry["name"], entry["cadence"]),
                                 (job["name"], f"every {job['schedule']['everyMs']} ms"))
            elif entry["kind"] == "cron":
                self.assertNotIn(entry["name"], live_names, "a live vigia keeps a stale id in modelWakes")
        cron_ids = {entry["id"] for entry in wakes["entries"] if entry["kind"] == "cron"}
        self.assertLessEqual(live_ids, cron_ids)
        for entry in wakes["entries"]:
            for key in ("kind", "id", "name", "targets", "cadence", "source", "recreators"):
                self.assertIn(key, entry)
            self.assertIsInstance(entry["targets"], list)
            self.assertTrue(entry["targets"], f"entry {entry['name']} has empty targets")
            self.assertIsInstance(entry["recreators"], list)
            self.assertTrue(entry["recreators"], f"entry {entry['name']} has empty recreators")
            for recreator in entry["recreators"]:
                self.assertEqual(
                    set(recreator), {"path", "line", "state"},
                    f"recreator {recreator} of {entry['name']} needs exactly path, line, state",
                )

    def test_wake_source_search_sees_the_mark_with_any_spacing(self):
        # B4-28: la busqueda del inventario ve la marca con mas de un espacio o un tabulador,
        # como la de B4-22, y sigue viendo las otras fuentes.
        repo = self.root / "repo"
        files = {
            "scripts/una.sh": "tmux set-environment -t s OPENCLAW_WATCH 1\n",
            "scripts/dos.sh": "tmux set-environment -t s OPENCLAW_WATCH  1\n",
            "scripts/tab.sh": "tmux set-environment -t s OPENCLAW_WATCH\t1\n",
            "scripts/vigia.sh": "lanzar --vigia claw\n",
            "scripts/mac.sh": "usa vigia-mac\n",
            "scripts/claw.sh": 'if [ "$vigia" = "claw" ]; then :; fi\n',
            "scripts/run.sh": "tmux set-environment -t s OPENCLAW_WATCH_RUN r1\n",
            "scripts/tests/t.sh": "tmux set-environment -t s OPENCLAW_WATCH  1\n",
        }
        for name, text in files.items():
            (repo / name).parent.mkdir(parents=True, exist_ok=True)
            (repo / name).write_text(text, encoding="utf-8")
        with mock.patch.dict(os.environ):
            for key in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
                os.environ.pop(key, None)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            listed = repo_wake_sources(repo)
        self.assertEqual(listed, ["scripts/claw.sh", "scripts/dos.sh", "scripts/mac.sh", "scripts/tab.sh",
                                  "scripts/una.sh", "scripts/vigia.sh"])

    def test_every_inventory_entry_is_migrated_or_declared_out(self):
        # T9 :265: cada entrada del inventario queda gestionada (preparada y apagada), protegida en el
        # perimetro o declarada fuera con su razon. Lo que se exige sale del repo, no de las filas.
        states = {"managed-prepared", "perimeter-guarded", "legacy-until-adoption", "out-of-perimeter"}
        wakes = self.coverage["modelWakes"]["entries"]
        rows = {}
        for row in self.coverage["migration"]:
            self.assertFalse(row["id"] in rows, f"{row['id']} is registered twice")
            rows[row["id"]] = row
        required = {f"requester:{name}" for name in self.coverage["requesters"]}
        required |= {f"route:{route['kind']}" for route in self.coverage["routes"]}
        required |= {f"managed:{route['requester']}->{route['target']}"
                     for route in self.coverage["managedRequesterRoutes"]}
        required |= {f"wake:{entry['name']}" for entry in wakes}
        required |= {f"wake:{job['name']}" for job in self.coverage["cronJobs"]["entries"] if job["kind"] == "vigia"}
        # T9 (plan :257): los helpers, los lanzadores y el reparador que relanza carriles.
        required |= {f"file:{path}" for path in (
            "scripts/mac/claude-stop-openclaw-event.sh", "scripts/mac/tmux-activity-watch.sh",
            "scripts/mac/corrida/avisos.sh", "scripts/mac/corrida/lanzar-sesion.sh",
            "scripts/lanzar-lead.sh", "scripts/lanzar-fase.sh", "scripts/mac/agent-tmux.sh",
            "scripts/mac/corrida/adaptador.sh", "scripts/mac/corrida/reconciliar.sh")}
        # El inventario nombra sus fuentes y recreadores del repo (plan :272).
        required |= {f"file:{entry['source'].split(':')[0]}" for entry in wakes
                     if not entry["source"].startswith("gateway")}
        required |= {f"file:{recreator['path']}" for entry in wakes for recreator in entry["recreators"]
                     if not recreator["path"].startswith("~")}
        listed = subprocess.run(
            ["git", "grep", "-l", "-E",
             "-e", "sessions_spawn|sessions_send|managed_tasks_|adaptador(\\.sh)? (start|deliver)|--vigia",
             # T9 :266: quien manda marcar con OPENCLAW_WATCH vigila; es la busqueda de la prueba de su excepcion.
             "-e", "OPENCLAW_WATCH[[:space:]=]+[\"']?1", "-e", "marcada con `OPENCLAW_WATCH`",
             "-e", "se marca al lanzarla", "-e", "(registra y |la |y la )marca (la sesi[oó]n )?antes",
             "-e", "marks? BEFORE",
             "--", "agents", "docs/runbooks", "workspace-*/*.md", ":!workspace-*/memory/*"],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        self.assertIn("workspace-adversary/AGENTS.md", listed, "the instruction scan lost the workspaces")
        self.assertIn("docs/runbooks/guia-del-vigia.md", listed, "the instruction scan lost the marking docs")
        required |= {f"file:{path}" for path in listed}
        self.assertEqual(set(rows), required, "migration must register every inventory entry and nothing else")
        # El estado no es libre: un vigia de cron se retira en T12, una ruta gestionada sin certificar esta
        # preparada y apagada, y solo un archivo puede quedar fuera del perimetro.
        cron_wakes = {f"wake:{entry['name']}" for entry in wakes if entry["kind"] == "cron"}
        uncertified = {f"managed:{route['requester']}->{route['target']}"
                       for route in self.coverage["managedRequesterRoutes"] if not route["certified"]}
        for row in rows.values():
            with self.subTest(entry=row["id"]):
                self.assertIn(row["state"], states)
                self.assertTrue(row["reason"].strip())
                self.assertEqual(row.get("adoption"), "T12" if row["state"] == "legacy-until-adoption" else None)
                if row["id"] in cron_wakes:
                    self.assertEqual(row["state"], "legacy-until-adoption")
                if row["id"] in uncertified:
                    self.assertEqual(row["state"], "managed-prepared")
                if row["state"] == "out-of-perimeter":
                    self.assertTrue(row["id"].startswith("file:"), "only a file can be declared out of the perimeter")
                if row["state"] in ("managed-prepared", "perimeter-guarded"):
                    self.assertTrue(row["evidence"], "a migrated entry needs the test that fixes it")
                if row["state"] == "managed-prepared":
                    self.assertTrue(row["instructions"], "a managed entry needs its instructions")
                for item in row["evidence"]:
                    self.assertRegex(item["path"], r"^scripts/tests/test-[^/]+$", f"evidence {item} is not a G test")
                    self.assertTrue(item["test"] in (ROOT / item["path"]).read_text(encoding="utf-8"),
                                    f"evidence {item} does not exist")
                for item in row["instructions"]:
                    self.assertRegex(item["path"], r"^(agents|docs/runbooks|workspace-[a-z]+)/",
                                     f"instruction {item} is not an instruction file")
                    self.assertTrue(item["literal"] in (ROOT / item["path"]).read_text(encoding="utf-8"),
                                    f"instruction {item} is not in its file")

    def test_parallel_preparation_never_observes_partial_artifact(self):
        writing = threading.Event()
        release = threading.Event()
        original_open = routing.os.open
        result = []
        first = True

        def paused_open(path, flags, mode=0o777):
            nonlocal first
            fd = original_open(path, flags, mode)
            if first:
                first = False
                writing.set()
                release.wait(2)
            return fd

        def first_request():
            try:
                result.append(self.request("ingenieria", "adversary"))
            except Exception as exc:  # asserted below
                result.append(exc)

        with mock.patch("routing.os.open", side_effect=paused_open):
            thread = threading.Thread(target=first_request)
            thread.start()
            self.assertTrue(writing.wait(2))
            try:
                second = self.request("ingenieria", "adversary")
            finally:
                release.set()
                thread.join(2)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0], second)


if __name__ == "__main__":
    unittest.main()

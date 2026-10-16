#!/usr/bin/env python3
"""Requester-side routing contract for managed tasks."""

import hashlib
import json
import os
from pathlib import Path
import re
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
import brief  # noqa: E402
import contexto  # noqa: E402
import encargo  # noqa: E402
import modelos  # noqa: E402
import sesion  # noqa: E402


def repo_wake_sources(root):
    # T9 :266: tambien quien pone la marca del vigilante y los runbooks que lo hacen.
    return subprocess.run(
        ["git", "grep", "-l", "-E", "--", "vigia-mac|OPENCLAW_WATCH[[:space:]]+1",
         "--", "scripts", "agents", "docs/runbooks", ":!scripts/tests"],
        cwd=root, capture_output=True, text=True, check=True,
    ).stdout.splitlines()


# Adaptadores de juguete para las rutas que routing.py prepara con datos de mentira (SUA-04, 4.6):
# usar un id que parezca real daría a entender que ese host lo implementa, y ninguno lo hace.
FIXTURE_CLI_A = "fixture-cli-a"
FIXTURE_CLI_B = "fixture-cli-b"


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
        self.assertEqual(request["taskKey"], "review-r1")
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
        with self.assertRaisesRegex(RouteUnavailable, f"windows-remote/{FIXTURE_CLI_A}"):
            self.request("ingenieria", f"windows-remote/{FIXTURE_CLI_A}")
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["windows-remote"][FIXTURE_CLI_A] = "certified"
        request = self.request("ingenieria", f"windows-remote/{FIXTURE_CLI_A}", coverage=certified)
        self.assertEqual(request["assignment"]["target"],
                         {"kind": "cli", "hostId": "windows-remote", "adapterId": FIXTURE_CLI_A})

    def test_only_a_certified_cli_route_is_prepared_and_the_rest_stay_closed_for_any_host(self):
        """Walks cliAdapters, the inventory CLIs on the managed hosts. routing.py prepares a request only
        for a certified route; el número de rechazos sale del inventario, no de un literal."""
        prepared, refused = [], []
        for requester, host_id in sorted(routing.CLI_ROUTES):
            for adapter_id in self.coverage["cliAdapters"]:
                target = f"{host_id}/{adapter_id}"
                try:
                    request = self.request(requester, target)
                except RouteUnavailable as unavailable:
                    self.assertEqual(str(unavailable), f"route {target} is not certified")
                    refused.append(target)
                else:
                    self.assertEqual(request["assignment"]["target"],
                                     {"kind": "cli", "hostId": host_id, "adapterId": adapter_id})
                    prepared.append(target)
        self.assertEqual(prepared, ["mac-local/opencode"])
        self.assertEqual(len(refused),
                         len(routing.CLI_ROUTES) * len(self.coverage["cliAdapters"]) - len(prepared))
        with self.assertRaisesRegex(RouteUnavailable, "outside the managed perimeter"):
            self.request("ingenieria", "mac-local/opencode")

    def test_no_retired_adapter_is_offered_by_coverage(self):
        # SUA-04 (4.6): un adaptador que ningún host implementa sale de cliAdapters y de
        # hostAdapterCoverage, y queda solo en su fila retirada de migration. Que un id
        # retirado vuelva a coverage abre una ruta que ningún host atiende.
        rows = {row["id"]: row for row in self.coverage["migration"]}
        retired = {row_id.removeprefix("adapter:")
                   for row_id, row in rows.items() if row.get("state") == "retired"}
        self.assertTrue(retired, "migration no tiene adaptadores retirados")
        for host_id, adapters in self.coverage["hostAdapterCoverage"].items():
            for adapter_id in adapters:
                if adapter_id == "opencode":
                    continue
                self.assertNotIn(adapter_id, retired,
                                 f"{host_id}/{adapter_id} está retirado y sigue en hostAdapterCoverage")
                self.assertIn(adapter_id, self.coverage["hostAdapterRoute"].get(host_id, {}),
                              f"{host_id}/{adapter_id} está en coverage sin ruta en hostAdapterRoute")
        for adapter_id in retired:
            self.assertNotIn(adapter_id, self.coverage["cliAdapters"],
                             f"{adapter_id} está retirado y sigue en cliAdapters")

    def test_every_certified_host_adapter_names_its_live_evidence(self):
        certified = [(host_id, adapter_id)
                     for host_id, adapters in self.coverage["hostAdapterCoverage"].items()
                     for adapter_id, state in adapters.items() if state == "certified"]
        self.assertEqual(certified, [("mac-local", "opencode")])
        evidence = self.coverage["hostAdapterEvidence"]
        self.assertEqual({host_id: sorted(adapters) for host_id, adapters in evidence.items()},
                         {"mac-local": ["opencode"]})
        cited = evidence["mac-local"]["opencode"]
        self.assertEqual(sorted({item["path"] for item in cited}), [
            "docs/evidence/agent-work/B22-canarios.md", "docs/evidence/agent-work/B22-fase0.md",
            "scripts/tests/test-agent-work-sesion.py"])
        for item in cited:
            self.assertIn(item["test"], (ROOT / item["path"]).read_text(encoding="utf-8"),
                          f"evidence {item} of mac-local/opencode does not exist")
        # The receipts of each opencode version the run-per-task route is certified for.
        receipts = self.coverage["hostAdapterRoute"]["mac-local"]["opencode"]["certifiedCliVersions"]
        self.assertEqual(receipts, {"1.18.35": "B22-fase0.md y B22-canarios.md"})
        for name in ("B22-fase0.md", "B22-canarios.md"):
            self.assertTrue((ROOT / "docs/evidence/agent-work" / name).is_file(), name)

    def test_every_field_that_speaks_of_certification_agrees_with_host_adapter_coverage(self):
        """routing.py and the host read hostAdapterCoverage. status, hosts and managedRequesterRoutes repeat it
        for a reader: `certified` there means that some route under it is certified, and `inventory-only`
        that none is. Until 2026-10-13 they said `inventory-only` while mac-local/opencode took real tasks."""
        certified = {(host_id, adapter_id)
                     for host_id, adapters in self.coverage["hostAdapterCoverage"].items()
                     for adapter_id, state in adapters.items() if state == "certified"}
        self.assertEqual(self.coverage["status"], "certified" if certified else "inventory-only")
        self.assertEqual([(host["id"], host["status"]) for host in self.coverage["hosts"]],
                         [("mac-local", "certified"), ("windows-remote", "disabled-unverified")])
        self.assertEqual({host["id"] for host in self.coverage["hosts"] if host["status"] == "certified"},
                         {host_id for host_id, _ in certified})
        routes = self.coverage["managedRequesterRoutes"]
        listed = [(route["requester"], route["target"]) for route in routes]
        self.assertEqual(len(listed), len(set(listed)), "a managed route is listed twice")
        for route in routes:
            if route["kind"] == "cli":
                with self.subTest(route=route["target"]):
                    self.assertEqual(route["certified"], tuple(route["target"].split("/", 1)) in certified)
        # The requester routing.py lets reach a host has a listed route to each certified adapter of it.
        self.assertLessEqual({(requester, f"{host_id}/{adapter_id}") for requester, host in routing.CLI_ROUTES
                              for host_id, adapter_id in certified if host == host_id}, set(listed))
        self.assertEqual([key for key, route in zip(listed, routes) if route["certified"]],
                         [("main", "mac-local/opencode")])

    def test_coverage_routes_are_the_five_of_the_design_with_their_generation_and_evidence(self):
        # K1 de SUA03-G5b-cierre: las cinco rutas del diseño, cada una con su
        # generación de contexto y su evidencia; certified solo en las de CLI.
        rutas = {ruta["kind"]: ruta for ruta in self.coverage["routes"]}
        self.assertEqual(
            set(rutas),
            {"native-turn", "native-child", "native-managed-agent", "cli-managed-task", "cli-child"},
        )
        for kind in ("native-turn", "native-child", "native-managed-agent"):
            with self.subTest(ruta=kind):
                self.assertFalse(rutas[kind]["certified"])
                self.assertEqual(rutas[kind]["contextGeneration"], 2)
                self.assertIn("SUA-03.md", rutas[kind]["evidence"])
        for kind in ("cli-managed-task", "cli-child"):
            with self.subTest(ruta=kind):
                self.assertTrue(rutas[kind]["certified"])
                self.assertEqual(rutas[kind]["contextGenerations"], [1, 2])
                self.assertIn("SUA-03-mediciones.md", rutas[kind]["evidence"])
        self.assertNotIn("user-adopted-session", rutas)

    def test_every_repo_path_the_inventory_names_as_its_source_exists(self):
        named = re.findall(r"\b(?:agents|scripts|docs)/[\w./-]*\w", self.coverage["source"])
        self.assertIn("agents/main/agent/workshop-skills/agent-dispatch/SKILL.md", named)
        for path in named:
            self.assertTrue((ROOT / path).is_file(), f"source names {path}, which is not in the repo")

    def test_cli_route_is_limited_to_its_requester(self):
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["mac-local"][FIXTURE_CLI_B] = "certified"
        with self.assertRaisesRegex(RouteUnavailable, "outside the managed perimeter"):
            self.request("operaciones", f"mac-local/{FIXTURE_CLI_B}", coverage=certified)

    def test_main_cli_route_stays_disabled_until_mac_local_is_certified(self):
        with self.assertRaisesRegex(RouteUnavailable, "not certified"):
            self.request("main", f"mac-local/{FIXTURE_CLI_B}")
        certified = json.loads(json.dumps(self.coverage))
        certified["hostAdapterCoverage"]["mac-local"][FIXTURE_CLI_B] = "certified"
        request = self.request("main", f"mac-local/{FIXTURE_CLI_B}", coverage=certified)
        self.assertEqual(request["assignment"]["target"],
                         {"kind": "cli", "hostId": "mac-local", "adapterId": FIXTURE_CLI_B})

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
            ('agents/main/agent/workshop-skills/agent-dispatch/SKILL.md', '## External review loop (Claude on the Mac)\n\n', 'Legacy route (T9 `:265`): this loop (tmux delivery, `OPENCLAW_WATCH`, `VEREDICTO` files) stays outside the managed perimeter until its adoption (T12). The managed `main` to Mac CLI route is the one in "Ruteo nativo vs. legado", driven by the `encargo-cli` skill.', '\n\nDavid repeatedly orders'),
            ('agents/ingenieria/agent/workshop-skills/managed-task-routing/SKILL.md', 'Si una operación gestionada es rechazada, informa el bloqueo sin reenviarla por sessions_spawn, sessions_send ni CLI directo.\n\n', 'Si te llegó un encargo gestionado (T9 `:265`): cuando `managed_tasks_report` está entre tus tools, el resultado sale solo con `managed_tasks_report`; dentro de ese run el runtime rechaza `sessions_send` y `sessions_spawn`, así que no reportes ni delegues por ahí, tampoco los carriles paralelos de `mac-node-ops`.', '\n'),
        ):
            text = (ROOT / path).read_text(encoding="utf-8")
            self.assertEqual(text.count(antes + frase + despues), 1,
                             f"{path}: la frase de la ruta vieja (T9 :265) no esta justo despues de {antes.splitlines()[0]!r}")

    def test_main_cli_route_points_main_at_the_encargo_cli_skill_and_not_at_routing_py(self):
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
            'entra solo cuando David dice "por CLI"',
            "conserva el flujo de esta skill, aunque nombre un modelo",
            "sigue la skill `encargo-cli`",
            "`~/.local/share/agent-work/brief.py` en la Mini (`routing.py` no corre ahí)",
            "managed_tasks_submit",
            "managed_tasks_admit",
            "isolated",
            "agent-work.result.v1",
            "El host lanza un proceso de opencode por encargo y lo cierra él mismo",
            "Qué modelos se pueden pedir lo contesta `encargo.py preparar`.",
            "delivery-unaccepted",
            "no lo vuelvas a teclear ni a pedir a ciegas",
        ):
            self.assertIn(expected, paragraph)
        self.assertNotIn("--requester main", paragraph)
        self.assertNotIn("deshabilitada", paragraph)

    def test_the_encargo_cli_skill_spells_the_steps_main_runs_on_the_mini(self):
        skill = (ROOT / "agents/main/agent/workshop-skills/encargo-cli/SKILL.md").read_text(encoding="utf-8")
        self.assertTrue(skill.startswith(
            '---\nname: encargo-cli\ndescription: Úsala solo cuando David diga "por CLI" en un pedido de trabajo'))
        self.assertIn('Sin "por CLI" no es esta skill, aunque nombre un modelo', skill.splitlines()[2])
        # Live canary P 2026-10-13, twice: main never opened the skill, because its description spoke only of
        # work on a repo, and wrote the file with its own exec. The description is all main reads to choose.
        self.assertIn('o crear o cambiar cualquier archivo, sea del tamaño que sea y esté dentro o fuera de un repo. '
                      'Con "por CLI" nunca hagas el trabajo tú con exec, write o edit', skill.splitlines()[2])
        for expected in (
            'Esta ruta entra solo con "por CLI". Si David no lo dijo, no encargues por aquí aunque nombre un modelo.',
            "python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py preparar "
            '--repo /Users/dn/dev/<repo> --modelo "<lo que dijo David>"',
            "python3 ~/.local/share/agent-work/brief.py --root /Users/gon/.openclaw/workspace/managed-instructions "
            "<briefArgs> <<'BRIEF'",
            "python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py estado --tarea <taskId>",
            "`managed_tasks_submit` con un `taskKey` nuevo (nunca `key`)",
            '`{"kind": "artifact", "ref": <instructionRef.ref>, "digest": <instructionRef.digest>}`',
            "`ready.v1` para implementar, arreglar o explorar, `review.v1` para revisar, atacar o verificar",
            # G4: el perfil viaja en preparar y cada tipo de pedido lleva el suyo.
            "python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py preparar "
            '--repo /Users/dn/dev/<repo> --modelo "<lo que dijo David>" --perfil <id>',
            "implementar o arreglar, `ingenieria`; revisar, `revision`; "
            '"revisión adversaria" o "atácalo", `adversario`; verificar, `verificacion`; '
            "explorar o investigar sin cambiar nada, `exploracion`",
            "Si la causa es de perfil",
            # G4: el artefacto de una revisión va a la carpeta de la corrida, no al repo (4.8).
            'y `<hallazgos>` ya no es una ruta del repo: va donde lo dice el campo `protocol` de la asignación',
            "la carpeta que contiene `resultRef`, nunca dentro de `workspaceRef`",
            # G5c-r2: un ready.v1 que no escribe fuente (exploracion) deja su artefacto
            # en la carpeta de la corrida, como una revisión (B del r1 en el host).
            'Para un `ready.v1` de un perfil que no escribe fuente (explorar, `exploracion`), el '
            'typedPayload es `{"evidenceRef": "<hallazgos>"}` y `<hallazgos>` es la ruta absoluta '
            "del artefacto: va donde lo dice el campo `protocol` de la asignación, dentro de la "
            "carpeta que contiene `resultRef`, y no en el repo",
            '`continuation`: `{"kind": "requester"}`',
            "`managed_tasks_admit` con el `taskId` y `admissionKey` `<taskKey>-admit`",
            "Termina tu turno.",
            "`managed_tasks_artifact_read`",
            "El `receipt` es el `resultReceipt` del inspect",
            "`managed_tasks_resolve`, que lleva solo `receipt` y `decision`",
            "se cancela con `managed_tasks_cancel`",
            "En esta ruta nadie aprueba permisos, ni tú ni nadie en la Mac.",
            "un encargo por CLI nunca la usa: `opencode-go/*` y `opencode/*` están cerrados por orden de David",
            # Live canary P 2026-10-13: main wrote the file with its own exec and answered "creado por CLI".
            '"Por CLI" siempre es un encargo registrado en R, aunque el trabajo sea de una línea. No lo hagas tú '
            "con `exec`, `write` ni `edit`.",
            'Un "hecho por CLI" sin `taskId` es falso.',
            # PR #283 review: the folder guard does not confine the model's shell, so main must not register a
            # request that names a path outside the repo and promise that the host will deny it.
            "Si el pedido toca un archivo fuera de ese repo, no lo encargues y no lo hagas tú con `exec`",
            "Cancela solo si no hay resultado y `explicacion.accion` es `cancelar`",
        ):
            self.assertIn(expected, skill)
        self.assertEqual([line for line in skill.splitlines() if line.lstrip().startswith("|")], [],
                         "the skill carries a table of models; the Mac answers which ones exist")
        self.assertNotIn("routing.py", skill)

    def test_the_encargo_cli_skill_offers_no_model_of_a_provider_david_closed(self):
        skill = (ROOT / "agents/main/agent/workshop-skills/encargo-cli/SKILL.md").read_text(encoding="utf-8")
        policy = modelos.ProviderPolicy.load(ROOT / modelos.POLICY_FILE)
        self.assertLessEqual({"opencode-go", "opencode"}, set(policy.closed))
        decided = {*policy.closed, *(grant.provider for grant in policy.grants)}
        shown = {model for model in re.findall(r"[a-z0-9][a-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*", skill)
                 if model.split("/")[0] in decided}
        self.assertIn("zai-coding-plan/glm-5.3-highspeed", shown)
        self.assertEqual({model for model in shown if policy.grant_for(model.split("/")[0]) is None}, set())

    def test_the_encargo_cli_skill_shows_the_answers_with_the_keys_encargo_py_prints(self):
        skill = (ROOT / "agents/main/agent/workshop-skills/encargo-cli/SKILL.md").read_text(encoding="utf-8")
        shown = [json.loads(line) for line in map(str.strip, skill.splitlines()) if line.startswith('{"ok": true')]
        prepared = encargo._answer(
            encargo.Preparado("p/m", "subscription", None, ("--model", "p/m"), False, "d", "1"), 0.0)[1]
        ran = encargo._answer(
            encargo.EstadoTarea("t", None, None, "registered", None, None, (), (), None, None, ()), 0.0)[1]
        self.assertEqual([list(answer) for answer in shown], [list(prepared), list(ran)])
        self.assertEqual(list(shown[0]["host"]), list(prepared["host"]))

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
        # Los runbooks de fases cerradas no se reescriben: conservan la cláusula del registro de corrida.
        spanish = ("Excepción (T9 `:266`): una sesión gestionada (`AGENT_WORK_MANAGED=1` en tmux{}) nunca se marca con "
                   "`OPENCLAW_WATCH` ni se relanza a mano; su host le reporta al solicitante el cierre, el diálogo o "
                   "el plazo vencido.")
        exception = {
            "agents": ("Exception (T9 `:266`): a managed session (tmux `AGENT_WORK_MANAGED=1`) is never marked with "
                       "`OPENCLAW_WATCH` and never relaunched by hand; its host reports a close, a dialog or a missed "
                       "deadline to the requester.",),
            "docs": (spanish.format(""), spanish.format(", o una entrada del registro con `encargo_ref` o `host_id`")),
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
            text = (ROOT / path).read_text()
            self.assertTrue(any(phrase in text for phrase in exception[path.split("/")[0]]),
                            f"{path} manda marcar con OPENCLAW_WATCH y no dice la excepcion de las gestionadas")

    def test_every_live_cron_is_classified(self):
        # T9 :265: cada cron vivo de la foto queda clasificado, con su perimetro y su razon; los de negocio
        # conservan horario y funcion (el sha256 del mensaje vivo). La foto es un dado: su sha256 es literal.
        reasons = {
            "business": "cron de negocio: conserva horario y función; fuera del perímetro, no delega trabajo con resultado esperado (T9 :265)",
            "technical": "cron técnico: despierta un modelo o corre un comando sin delegar trabajo con resultado esperado; fuera del perímetro (T9 :265)",
            "system": "tarea interna del gateway; no delega (T9 :265)",
        }
        # El único cron de la foto que delega: su mensaje despacha a otro agente, así que no lleva la razón de su clase.
        delegating = {
            "seguimiento-yours-virtually-miercoles": "cron de negocio de un solo disparo (2026-10-14): conserva horario y función; despacha al agente mail con sessions_spawn, la ruta nativa que sigue fuera del perímetro gestionado (migration, route:native-child)",
        }
        cron_jobs = self.coverage["cronJobs"]
        self.assertEqual(cron_jobs["snapshot"], "docs/evidence/agent-work/SUA-00-M09b-cron-snapshot.json")
        self.assertEqual(hashlib.sha256((ROOT / cron_jobs["snapshot"]).read_bytes()).hexdigest(),
                         "4b055505ef2626dbb278479143e57e68c59447558a48f13426f9fbba51b81a0e",
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
            "packing-digest-faseA-censo", "packing-digest-faseB-armado", "packing-digest-faseC-envio",
            "packing-extras-7h", "packing-extras-11h", "verif-digest-20h",
            "Renueva el token de acceso de Shopify de la tienda theglamw…",
            "seguimiento-yours-virtually-miercoles"})
        self.assertEqual(kinds.get("system"), {"Memory Dreaming Promotion"})
        self.assertEqual(len(kinds.get("technical")), 20)
        # La foto no tiene vigías. Un `<loop>-vigia` en una foto nueva pide aquí su clase, su perímetro y su razón.
        self.assertEqual(sorted(kinds), ["business", "system", "technical"])
        self.assertEqual([job["name"] for job in snapshot["jobs"] if job["name"].endswith("-vigia")], [])
        for row in cron_jobs["entries"]:
            job = jobs[row["id"]]
            with self.subTest(cron=row["name"]):
                self.assertEqual(row["name"], job["name"])
                self.assertIn(row["kind"], reasons)
                self.assertEqual(row["perimeter"], "out-of-perimeter")
                self.assertEqual(row["reason"], delegating.get(row["name"], reasons[row["kind"]]))
                if row["kind"] == "business":
                    self.assertEqual(row["schedule"], job["schedule"])
                    self.assertEqual(row["messageSha256"], job["messageSha256"])
                else:
                    self.assertNotIn("schedule", row)

    def test_model_wakes_inventory_lists_every_repo_wake_source(self):
        wakes = self.coverage["modelWakes"]
        # La foto del 2026-10-13 a las 18:09 UTC reemplaza a la de B4-26, del 2026-10-07.
        self.assertEqual(wakes["snapshot"], "docs/evidence/agent-work/SUA-00-M09b-cron-snapshot.json")
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
        # Un cron que ya no está en la foto no despierta a nadie: los crons del inventario son los vigías vivos.
        live = [(job["id"], job["name"], f"every {job['schedule']['everyMs']} ms")
                for job in snapshot["jobs"] if job["name"].endswith("-vigia")]
        self.assertEqual(live, [], "bids-02-vigia borró su propio cron el 2026-10-13: la foto no tiene vigías")
        self.assertEqual([(entry["id"], entry["name"], entry["cadence"])
                          for entry in wakes["entries"] if entry["kind"] == "cron"], live)
        self.assertEqual([entry["id"] for entry in wakes["entries"]], ["tmux-activity-watch", "claude-code-stop-hook"])
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
            "scripts/mac.sh": "usa vigia-mac\n",
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
        self.assertEqual(listed, ["scripts/dos.sh", "scripts/mac.sh", "scripts/tab.sh", "scripts/una.sh"])

    def test_every_inventory_entry_is_migrated_or_declared_out(self):
        # T9 :265: cada entrada del inventario queda gestionada (preparada y apagada), protegida en el
        # perimetro o declarada fuera con su razon. Lo que se exige sale del repo, no de las filas.
        states = {"managed-prepared", "perimeter-guarded", "legacy-until-adoption", "out-of-perimeter", "retired"}
        wakes = self.coverage["modelWakes"]["entries"]
        rows = {}
        for row in self.coverage["migration"]:
            self.assertFalse(row["id"] in rows, f"{row['id']} is registered twice")
            rows[row["id"]] = row
        required = {f"requester:{name}" for name in self.coverage["requesters"]}
        required |= {f"route:{route['kind']}" for route in self.coverage["routes"]}
        # La sesión adoptada salió de routes en el cierre de SUA-03 y su fila
        # queda como retirada, no como una sexta ruta.
        required |= {"route:user-adopted-session"}
        required |= {f"managed:{route['requester']}->{route['target']}"
                     for route in self.coverage["managedRequesterRoutes"]}
        # SUA-04 (4.6): los siete adaptadores retirados quedan solo en su fila de migration.
        required |= {f"adapter:{adapter_id}" for adapter_id in (
            "claude_fable", "claude_opus", "kimi_k3", "kimi_coding", "codex", "zcode", "grok")}
        required |= {f"wake:{entry['name']}" for entry in wakes}
        required |= {f"wake:{job['name']}" for job in self.coverage["cronJobs"]["entries"] if job["kind"] == "vigia"}
        # T9 (plan :257): los helpers y los lanzadores.
        required |= {f"file:{path}" for path in (
            "scripts/mac/claude-stop-openclaw-event.sh", "scripts/mac/tmux-activity-watch.sh",
            "scripts/lanzar-lead.sh", "scripts/lanzar-fase.sh", "scripts/mac/agent-tmux.sh")}
        # El inventario nombra sus fuentes y recreadores del repo (plan :272).
        required |= {f"file:{entry['source'].split(':')[0]}" for entry in wakes
                     if not entry["source"].startswith("gateway")}
        required |= {f"file:{recreator['path']}" for entry in wakes for recreator in entry["recreators"]
                     if not recreator["path"].startswith("~")}
        listed = subprocess.run(
            ["git", "grep", "-l", "-E",
             "-e", "sessions_spawn|sessions_send|managed_tasks_",
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
        # El estado no es libre: un vigia de cron es ruta vieja hasta su adopcion y solo un archivo puede quedar
        # fuera del perimetro. Una ruta gestionada es managed-prepared, certificada o no: el vocabulario no tiene
        # un estado para la que ya esta encendida, y eso lo dice su `certified`.
        cron_wakes = {f"wake:{entry['name']}" for entry in wakes if entry["kind"] == "cron"}
        managed = {f"managed:{route['requester']}->{route['target']}"
                   for route in self.coverage["managedRequesterRoutes"]}
        for row in rows.values():
            with self.subTest(entry=row["id"]):
                self.assertIn(row["state"], states)
                self.assertTrue(row["reason"].strip())
                self.assertEqual(row.get("adoption"), "T12" if row["state"] == "legacy-until-adoption" else None)
                if row["id"] in cron_wakes:
                    self.assertEqual(row["state"], "legacy-until-adoption")
                if row["id"] in managed:
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
        original_open = brief.os.open
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

        with mock.patch("brief.os.open", side_effect=paused_open):
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


class BriefHelper(unittest.TestCase):
    """brief.py runs alone on the gateway host, so every case runs a lone copy in isolated mode."""

    BRIEF = b"Revisa el commit abc y responde con review.v1\n"
    DIGEST = "04571968f445442a0b4d79bec8324cb09a5df4044356a43fd27c04d86b376e8a"
    MODEL_DIGEST = "c73dc0114a9e5a16d47b2cf2a58e6b133d9e83e8718d9b03c50ee3022b31b583"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        tool = self.tmp / "tool"
        tool.mkdir()
        self.helper = tool / "brief.py"
        self.helper.write_bytes((ROOT / "scripts/agent-work/brief.py").read_bytes())
        self.root = self.tmp / "instructions"
        self.root.mkdir(mode=0o700)

    def run_helper(self, *args, stdin=BRIEF):
        return subprocess.run([sys.executable, "-I", str(self.helper), "--root", str(self.root), *args],
                              input=stdin, capture_output=True, cwd=self.tmp)

    def test_brief_writes_the_file_r_resolves_and_prints_the_submit_fragments(self):
        done = self.run_helper("--host", "mac-local", "--adapter", FIXTURE_CLI_B)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout), {
            "instructionRef": {"ref": "artifact:" + self.DIGEST, "digest": "sha256:" + self.DIGEST},
            "target": {"kind": "cli", "hostId": "mac-local", "adapterId": FIXTURE_CLI_B},
        })
        artifact = self.root / self.DIGEST
        self.assertFalse(artifact.is_symlink())
        self.assertTrue(artifact.is_file())
        self.assertEqual(artifact.read_bytes(), self.BRIEF)
        self.assertEqual(artifact.stat().st_mode & 0o777, 0o600)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), [self.DIGEST])

    def test_brief_reads_a_file_and_omits_target_without_host(self):
        brief = self.tmp / "brief.txt"
        brief.write_bytes(self.BRIEF)
        done = self.run_helper("--file", str(brief), stdin=b"")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout), {
            "instructionRef": {"ref": "artifact:" + self.DIGEST, "digest": "sha256:" + self.DIGEST}})
        half = self.run_helper("--host", "mac-local")
        self.assertEqual(half.returncode, 2)
        self.assertIn(b"--host and --adapter go together", half.stderr)

    def test_brief_refuses_a_symlinked_root(self):
        real = self.tmp / "real"
        real.mkdir()
        self.root.rmdir()
        self.root.symlink_to(real, target_is_directory=True)
        done = self.run_helper()
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stderr, b"brief: instruction root must be an existing directory\n")
        self.assertEqual(done.stdout, b"")
        self.assertEqual(list(real.iterdir()), [])

    def test_brief_enforces_the_one_megabyte_limit(self):
        exact = b"a" * (1024 * 1024)
        done = self.run_helper(stdin=exact)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.root / hashlib.sha256(exact).hexdigest()).read_bytes(), exact)
        over = self.run_helper(stdin=exact + b"a")
        self.assertEqual(over.returncode, 1)
        self.assertEqual(over.stderr, b"brief: brief must contain 1 to 1048576 bytes\n")
        empty = self.run_helper(stdin=b"")
        self.assertEqual(empty.returncode, 1)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), [hashlib.sha256(exact).hexdigest()])

    def test_brief_second_write_is_idempotent_and_a_tampered_artifact_is_refused(self):
        first = self.run_helper()
        second = self.run_helper()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), [self.DIGEST])
        (self.root / self.DIGEST).write_bytes(b"otra cosa")
        tampered = self.run_helper()
        self.assertEqual(tampered.returncode, 1)
        self.assertEqual(tampered.stderr, b"brief: instruction artifact differs from digest\n")

    def test_brief_with_a_model_puts_the_launch_header_ahead_of_the_prose_and_under_the_digest(self):
        done = self.run_helper("--host", "mac-local", "--adapter", "opencode", "--model", "zai-coding-plan/glm-5.3")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout), {
            "instructionRef": {"ref": "artifact:" + self.MODEL_DIGEST, "digest": "sha256:" + self.MODEL_DIGEST},
            "target": {"kind": "cli", "hostId": "mac-local", "adapterId": "opencode"},
        })
        written = (self.root / self.MODEL_DIGEST).read_bytes()
        self.assertEqual(written, b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\n---\n" + self.BRIEF)
        self.assertEqual(hashlib.sha256(written).hexdigest(), self.MODEL_DIGEST)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), [self.MODEL_DIGEST])

    def test_the_host_reads_back_the_model_brief_wrote_and_none_from_a_brief_without_one(self):
        for model in ("zai-coding-plan/glm-5.3", "a/b", "openrouter/anthropic/claude-x:free@2026",
                      "p" * 64 + "/" + "m" * 128):
            with self.subTest(model):
                done = self.run_helper("--model", model)
                self.assertEqual(done.returncode, 0, done.stderr)
                digest = json.loads(done.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
                header = sesion.LaunchHeader.parse((self.root / digest).read_bytes())
                self.assertIsInstance(header, sesion.LaunchHeader)
                self.assertEqual(str(header.model), model)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(sesion.LaunchHeader.parse((self.root / self.DIGEST).read_bytes()),
                         sesion.LaunchHeader(None))

    def test_brief_refuses_a_model_the_host_would_not_parse_and_writes_nothing(self):
        for model in ("", "glm", "/glm-5.3", "zai-coding-plan/", "ZAI/glm-5.3", "zai coding/glm-5.3",
                      "zai-coding-plan/glm 5.3", "zai-coding-plan/glm-5.3\n",
                      "zai-coding-plan/glm-5.3\nmodel: opencode-go/kimi-k3", "p" * 65 + "/m", "p/" + "m" * 129):
            with self.subTest(model):
                self.assertIsInstance(modelos.ModelId.parse(model), modelos.MalformedModel)
                done = self.run_helper("--model", model)
                self.assertEqual((done.returncode, done.stdout), (2, b""))
                self.assertIn(f"brief.py: error: argument --model: not <provider>/<model>: {model!r}\n".encode(),
                              done.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_a_brief_with_no_prose_is_refused_even_with_a_model(self):
        done = self.run_helper("--model", "zai-coding-plan/glm-5.3", stdin=b"")
        self.assertEqual((done.returncode, done.stderr), (1, b"brief: brief must contain 1 to 1048576 bytes\n"))
        self.assertEqual(list(self.root.iterdir()), [])

    PERFILES = ROOT / "scripts/agent-work/contexto/perfiles.v1.json"

    def test_brief_with_a_profile_for_a_cli_host_carries_only_the_profile_line(self):
        for extra in ((), ("--perfiles", str(self.PERFILES))):
            with self.subTest(extra=extra):
                done = self.run_helper("--host", "mac-local", "--adapter", "opencode", "--model",
                                       "zai-coding-plan/glm-5.3", "--perfil", "revision", *extra)
                self.assertEqual(done.returncode, 0, done.stderr)
                digest = json.loads(done.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
                self.assertEqual((self.root / digest).read_bytes(),
                                 b"agent-work.launch.v1\nmodel: zai-coding-plan/glm-5.3\nprofile: revision\n---\n"
                                 + self.BRIEF)
        alone = self.run_helper("--host", "mac-local", "--adapter", "opencode", "--perfil", "revision")
        digest = json.loads(alone.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
        self.assertEqual((self.root / digest).read_bytes(),
                         b"agent-work.launch.v1\nprofile: revision\n---\n" + self.BRIEF)

    def test_brief_with_a_profile_for_a_native_target_carries_the_profile_under_the_digest(self):
        done = self.run_helper("--perfil", "meli", "--perfiles", str(self.PERFILES))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("target", json.loads(done.stdout))
        digest = json.loads(done.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
        meli = contexto.perfil(contexto.leer_json(self.PERFILES), "meli")
        self.assertEqual(
            (self.root / digest).read_bytes().decode(),
            "agent-work.launch.v1\nprofile: meli\n---\n"
            f"<!-- perfil inicio id=meli digest={contexto.digest_de_perfil(meli)} -->\n"
            "Tu perfil en este encargo: meli. Trabajo de MercadoLibre: pedidos, demoras y preguntas. Rechaza lo "
            "que no es de MercadoLibre con FUERA-DE-PERFIL.\n"
            "Contratos que entregas: ready.v1. Escribes fuente: no. Skills de tu perfil, además de poteto: "
            "ninguna.\n<!-- perfil fin -->\n" + self.BRIEF.decode(),
        )

    def test_brief_refuses_an_unknown_or_unreadable_profile_and_writes_nothing(self):
        unknown = self.run_helper("--perfil", "cocina", "--perfiles", str(self.PERFILES))
        self.assertEqual((unknown.returncode, unknown.stdout), (1, b""))
        self.assertIn(b"brief: unknown profile 'cocina'", unknown.stderr)
        for args, message in (
            (("--perfil", "meli"), b"--perfil without --host is a native target and needs --perfiles"),
            (("--perfiles", str(self.PERFILES)), b"--perfiles goes with --perfil"),
            (("--perfil", "Meli", "--perfiles", str(self.PERFILES)), b"not a profile id: 'Meli'"),
        ):
            with self.subTest(args=args):
                done = self.run_helper(*args)
                self.assertEqual((done.returncode, done.stdout), (2, b""))
                self.assertIn(message, done.stderr)
        missing = self.run_helper("--perfil", "meli", "--perfiles", str(self.tmp / "no-existe.json"))
        self.assertEqual(missing.returncode, 1)
        self.assertIn(b"brief: cannot read", missing.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_brief_with_an_agent_carries_the_task_and_the_report_protocol(self):
        # SUA-04 (4.5b): un destino nativo lleva la tarea en la cabecera, la sección de
        # protocolo después de la del perfil, y los tres fragmentos para managed_tasks_submit.
        done = self.run_helper("--perfil", "meli", "--perfiles", str(self.PERFILES),
                               "--agente", "meli", "--contrato", "ready.v1")
        self.assertEqual(done.returncode, 0, done.stderr)
        fragments = json.loads(done.stdout)
        digest = fragments["instructionRef"]["ref"].removeprefix("artifact:")
        self.assertEqual(fragments["target"], {"kind": "agent", "agentId": "meli"})
        self.assertEqual(fragments["inputRevision"],
                         {"kind": "artifact", "ref": f"artifact:{digest}", "digest": f"sha256:{digest}"})
        text = (self.root / digest).read_bytes().decode()
        tarea = re.search(r"^tarea: ([0-9a-f-]{36})$", text, re.MULTILINE).group(1)
        self.assertLess(text.index("<!-- perfil inicio"), text.index("<!-- protocolo inicio"))
        self.assertLess(text.index("<!-- protocolo fin -->"), text.index(self.BRIEF.decode()))
        protocolo = text[text.index("<!-- protocolo inicio"):text.index("<!-- protocolo fin -->")]
        self.assertIn(f"reporte.py --root {self.root} --tarea {tarea} --contrato ready.v1 "
                      "--artefacto <ruta absoluta", protocolo)
        self.assertIn('{"result": <la salida de ese comando>}', protocolo)
        self.assertIn(tarea, protocolo)

    def test_brief_refuses_an_agent_without_its_contract_or_with_a_host(self):
        for args, message in (
            (("--perfil", "meli", "--perfiles", str(self.PERFILES), "--agente", "meli"),
             b"--agente pide --contrato"),
            (("--perfil", "meli", "--perfiles", str(self.PERFILES), "--contrato", "ready.v1"),
             b"--contrato va con --agente"),
            (("--perfil", "meli", "--perfiles", str(self.PERFILES), "--agente", "meli",
              "--contrato", "ready.v1", "--host", "mac-local", "--adapter", "opencode"),
             b"--agente va con --perfil sin --host"),
        ):
            with self.subTest(args=args):
                done = self.run_helper(*args)
                self.assertEqual((done.returncode, done.stdout), (2, b""))
                self.assertIn(message, done.stderr)

    def test_the_host_reads_the_profile_line_that_brief_writes(self):
        # G1 did not move the host: until G3 a brief with a profile was cabecera-mal-formada, which is
        # why main did not pass --perfil before the window of G5. G3 is the slice that teaches the host
        # to read it, and the header it writes parses from then on.
        done = self.run_helper("--host", "mac-local", "--adapter", "opencode", "--perfil", "ingenieria")
        digest = json.loads(done.stdout)["instructionRef"]["ref"].removeprefix("artifact:")
        header = sesion.LaunchHeader.parse((self.root / digest).read_bytes())
        self.assertEqual((header.model, header.profile), (None, "ingenieria"))

    def test_brief_and_contexto_share_the_canonical_form(self):
        sample = {"z": [1, {"ñ": "sí"}], "a": None}
        self.assertEqual(brief.canonical(sample), contexto.canonico(sample))
        for profile in contexto.leer_json(self.PERFILES)["profiles"]:
            self.assertRegex(profile["id"], brief.PROFILE_ID)

    def test_brief_carries_the_same_header_grammar_as_the_host(self):
        self.assertEqual((brief.LAUNCH_SCHEMA, brief.HEADER_END), (sesion.LAUNCH_SCHEMA, sesion.HEADER_END))
        self.assertEqual((brief.PROVIDER.pattern, brief.MODEL_NAME.pattern),
                         (modelos.PROVIDER.pattern, modelos.MODEL_NAME.pattern))
        # La comparación que el docstring de sesion.PROFILE_ID anuncia (bots de #304, F11).
        self.assertEqual(brief.PROFILE_ID.pattern, sesion.PROFILE_ID.pattern)


if __name__ == "__main__":
    unittest.main()

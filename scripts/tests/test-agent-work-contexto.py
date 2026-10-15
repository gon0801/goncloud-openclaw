#!/usr/bin/env python3
"""El paquete de poteto y los perfiles de SUA-03 (diseño, 4.2 a 4.4; ensayos I08, I11 e I18)."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402

PSTACK = Path.home() / ".claude/plugins/cache/pstack-claude/pstack/0.9.84"
AHORA = datetime(2026, 10, 14, 12, tzinfo=timezone.utc)
CLI = {"host": "mac-local", "executor": "opencode", "agentId": None}


def nativa(agente):
    return {"host": "mini-native", "executor": "native", "agentId": agente}


def real():
    return contexto.leer_json(contexto.MANIFIESTO), contexto.leer_json(contexto.PERFILES)


def con_competencia(perfil, status="passed", valid_until=None):
    """El perfil con su competencia vigente en todas sus rutas."""
    perfil = copy.deepcopy(perfil)
    for clave in perfil["competence"]:
        perfil["competence"][clave] = {
            "status": status,
            "model": "proveedor-01/modelo-a",
            "evidence": "fixture",
            "at": "2026-10-14T00:00:00Z",
            "validUntil": valid_until,
        }
    return perfil


class Manifiesto(unittest.TestCase):
    def test_the_manifest_pins_its_generation(self):
        manifiesto, _ = real()
        generaciones = contexto.leer_json(contexto.GENERACIONES)
        contexto.comprobar_generacion(manifiesto, generaciones)
        self.assertEqual(
            (manifiesto["generation"], manifiesto["source"]),
            (
                1,
                {
                    "repo": "https://github.com/poteto/pstack-claude",
                    "commit": "990cd7b02ac6f3e8f825716f7c72e2f06d8f4a92",
                    "version": "0.9.84",
                },
            ),
        )
        otro = copy.deepcopy(manifiesto)
        otro["files"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(contexto.GeneracionSinSubir, "el campo digest no es el digest"):
            contexto.comprobar_generacion(otro, generaciones)
        otro["digest"] = contexto.digest_de(otro)
        with self.assertRaisesRegex(
            contexto.GeneracionSinSubir, "ya está fijada con otro contenido: sube"
        ):
            contexto.comprobar_generacion(otro, generaciones)
        otro["generation"] = 2
        otro["digest"] = contexto.digest_de(otro)
        with self.assertRaisesRegex(contexto.GeneracionSinSubir, "la generación 2 no está fijada"):
            contexto.comprobar_generacion(otro, generaciones)
        contexto.comprobar_generacion(otro, {**generaciones, "2": otro["digest"]})

    def test_the_texts_of_g_are_the_ones_the_manifest_pins(self):
        manifiesto, _ = real()
        adaptaciones = contexto.leer_adaptaciones()
        contexto.comprobar_textos(manifiesto, adaptaciones, contexto.BLOQUE.read_bytes())
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto, "el bloque de AGENTS.md no coincide"
        ):
            contexto.comprobar_textos(manifiesto, adaptaciones, contexto.BLOQUE.read_bytes() + b" ")
        sin_skill = copy.deepcopy(manifiesto)
        sin_skill["files"] = [f for f in sin_skill["files"] if f["path"] != contexto.OPENCLAW_SKILL]
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto, "poteto-openclaw/SKILL.md no es la adaptación"
        ):
            contexto.comprobar_textos(sin_skill, adaptaciones, contexto.BLOQUE.read_bytes())
        cambiada = {**adaptaciones, "openclaw": adaptaciones["openclaw"] + b"\n"}
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto, "la adaptación openclaw no coincide"
        ):
            contexto.comprobar_textos(manifiesto, cambiada, contexto.BLOQUE.read_bytes())

    def test_the_openclaw_adaptation_is_the_poteto_openclaw_skill(self):
        # Residual R2: the skill is the adaptation byte for byte, so generation 1 covers it.
        texto = contexto.ADAPTACIONES["openclaw"].read_text(encoding="utf-8")
        self.assertTrue(texto.startswith("---\nname: poteto-openclaw\ndescription: "))
        for herramienta in ("`read`", "`progress_card`", "`sessions_spawn`", "`exec`"):
            self.assertIn(herramienta, texto)
        self.assertNotIn("update_plan", texto)

    def test_the_package_of_each_profile_holds_exactly_its_skills(self):
        manifiesto, perfiles = real()
        skills = {
            p["id"]: sorted(
                {
                    ruta.split("/")[1]
                    for ruta in contexto.archivos_del_perfil(manifiesto, p)
                    if not ruta.split("/")[1].startswith("principle-")
                }
            )
            for p in perfiles["profiles"]
        }
        self.assertEqual(
            skills,
            {
                "ingenieria": ["architect", "how", "poteto-mode", "tdd"],
                "revision": ["blast-radius", "how", "poteto-mode"],
                "adversario": ["blast-radius", "how", "poteto-mode"],
                "verificacion": ["how", "poteto-mode"],
                "exploracion": ["how", "poteto-mode", "why"],
                "aceptacion": ["poteto-mode"],
                "operaciones": ["poteto-mode"],
                "amazon": ["poteto-mode"],
                "meli": ["poteto-mode"],
                "mail": ["poteto-mode"],
                "odoo": ["poteto-mode"],
            },
        )
        cuentas = {
            p["id"]: len(contexto.archivos_del_perfil(manifiesto, p)) for p in perfiles["profiles"]
        }
        # 35 files of poteto-mode without scripts/ and 24 principle-* in 0.9.84, then its skills.
        self.assertEqual(
            cuentas,
            {
                "ingenieria": 67,
                "revision": 63,
                "adversario": 63,
                "verificacion": 62,
                "exploracion": 75,
                "aceptacion": 59,
                "operaciones": 59,
                "amazon": 59,
                "meli": 59,
                "mail": 59,
                "odoo": 59,
            },
        )
        self.assertFalse(
            any(
                "/scripts/" in f["path"] and f["path"].startswith("skills/poteto-mode/")
                for f in manifiesto["files"]
            )
        )


class Construir(unittest.TestCase):
    PERFILES = {
        "profiles": [
            {
                "id": "uno",
                "skills": ["how"],
                "purpose": "Fixture.",
                "resultContracts": ["ready.v1"],
                "writesSource": True,
            }
        ]
    }

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.fuente = self.tmp / "pstack"
        for ruta, texto in {
            "skills/poteto-mode/SKILL.md": "poteto\n",
            "skills/poteto-mode/playbooks/feature.md": "1. `how` over the affected subsystem.\n",
            "skills/poteto-mode/scripts/check.mjs": "no va\n",
            "skills/principle-uno/SKILL.md": "principio\n",
            "skills/how/SKILL.md": "how\n",
            "skills/otra/SKILL.md": "no va\n",
        }.items():
            (self.fuente / ruta).parent.mkdir(parents=True, exist_ok=True)
            (self.fuente / ruta).write_text(texto)
        self.adaptaciones = {
            "opencode-run": b"# adaptacion\n",
            "openclaw": b"---\nname: poteto-openclaw\n---\n",
        }
        self.manifiesto = contexto.manifiesto(
            self.fuente,
            self.PERFILES,
            repo="r",
            commit="c",
            version="v",
            generation=1,
            adaptaciones=self.adaptaciones,
            bloque=b"bloque",
        )
        self.perfil = self.PERFILES["profiles"][0]

    def construir(self, nombre="contexto"):
        return contexto.construir(
            self.fuente,
            self.manifiesto,
            self.perfil,
            self.tmp / nombre,
            adaptaciones=self.adaptaciones,
        )

    def test_the_package_is_copied_with_its_manifest_and_profile(self):
        digest = self.construir()
        destino = self.tmp / "contexto"
        self.assertEqual(
            sorted(p.relative_to(destino).as_posix() for p in destino.rglob("*") if p.is_file()),
            [
                "AGENTS.md",
                "perfil.json",
                "poteto.v1.json",
                "skills/how/SKILL.md",
                "skills/poteto-mode/SKILL.md",
                "skills/poteto-mode/playbooks/feature.md",
                "skills/principle-uno/SKILL.md",
            ],
        )
        self.assertEqual(digest, contexto.digest_del_paquete(destino))
        self.assertEqual(digest, self.construir("otra"))
        self.assertEqual(
            (destino / "AGENTS.md").read_text(),
            "# adaptacion\n\n## Tu perfil: uno\n\nFixture.\n\n- Contratos que entregas: ready.v1.\n"
            "- Escribes fuente: sí.\n- Skills de tu perfil, además de poteto: how.\n",
        )
        self.assertEqual(json.loads((destino / "perfil.json").read_text()), self.perfil)

    def test_a_package_file_that_differs_from_the_manifest_is_refused(self):
        (self.fuente / "skills/poteto-mode/playbooks/feature.md").write_text("1. otra cosa.\n")
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto,
            "skills/poteto-mode/playbooks/feature.md no coincide con el manifiesto",
        ):
            self.construir()
        (self.fuente / "skills/how/SKILL.md").unlink()
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto, "skills/how/SKILL.md: No such file"
        ):
            self.construir()
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ["pstack"])
        with self.assertRaisesRegex(
            contexto.ContextoIncompleto, "la adaptación opencode-run no coincide"
        ):
            contexto.construir(
                self.fuente,
                self.manifiesto,
                self.perfil,
                self.tmp / "x",
                adaptaciones={**self.adaptaciones, "opencode-run": b"otra"},
            )

    def test_a_profile_skill_the_source_lacks_is_refused(self):
        with self.assertRaisesRegex(contexto.ContextoIncompleto, "la fuente no tiene la skill tdd"):
            contexto.archivos_de_la_fuente(self.fuente, ["how", "tdd"])

    @unittest.skipUnless(PSTACK.is_dir(), "pide pstack 0.9.84 instalado en esta Mac")
    def test_the_pinned_source_matches_generation_1(self):
        manifiesto, perfiles = real()
        destino = self.tmp / "ingenieria"
        contexto.construir(
            PSTACK,
            manifiesto,
            contexto.perfil(perfiles, "ingenieria"),
            destino,
            adaptaciones=contexto.leer_adaptaciones(),
        )
        self.assertTrue((destino / "skills/poteto-mode/playbooks/feature.md").is_file())
        rehecho = contexto.manifiesto(
            PSTACK,
            perfiles,
            **manifiesto["source"],
            generation=1,
            adaptaciones=contexto.leer_adaptaciones(),
            bloque=contexto.BLOQUE.read_bytes(),
        )
        self.assertEqual(rehecho, manifiesto)


class Perfiles(unittest.TestCase):
    def test_ten_profiles_with_the_routes_that_were_measured(self):
        _, perfiles = real()
        self.assertEqual(
            {
                p["id"]: (
                    [contexto.clave_de_ruta(r) for r in p["routes"]],
                    p["resultContracts"],
                    p["writesSource"],
                )
                for p in perfiles["profiles"]
            },
            {
                "ingenieria": (
                    [
                        "mac-local/opencode",
                        "mini-native/native/ingenieria",
                        "mini-native/native/implementer",
                    ],
                    ["ready.v1"],
                    True,
                ),
                "revision": (
                    ["mac-local/opencode", "mini-native/native/reviewer"],
                    ["review.v1"],
                    False,
                ),
                "adversario": (
                    ["mac-local/opencode", "mini-native/native/adversary"],
                    ["review.v1"],
                    False,
                ),
                "verificacion": (
                    ["mac-local/opencode", "mini-native/native/verifier"],
                    ["review.v1"],
                    False,
                ),
                "exploracion": (
                    ["mac-local/opencode", "mini-native/native/scout"],
                    ["ready.v1"],
                    False,
                ),
                "aceptacion": ([], ["review.v1"], False),
                "operaciones": (["mini-native/native/operaciones"], ["ready.v1"], False),
                "amazon": (["mini-native/native/amazon"], ["ready.v1"], False),
                "meli": (["mini-native/native/meli"], ["ready.v1"], False),
                "mail": (["mini-native/native/mail"], ["ready.v1"], False),
                "odoo": (["mini-native/native/odoo"], ["ready.v1"], False),
            },
        )

    def test_every_profile_is_complete_and_coherent(self):
        manifiesto, perfiles = real()
        en_el_paquete = {f["path"].split("/")[1] for f in manifiesto["files"]}
        agentes = []
        for p in perfiles["profiles"]:
            with self.subTest(perfil=p["id"]):
                self.assertEqual(
                    sorted(p["competence"]), sorted(contexto.clave_de_ruta(r) for r in p["routes"])
                )
                self.assertTrue(
                    all(c["status"] in contexto.COMPETENCIAS for c in p["competence"].values())
                )
                self.assertTrue(set(p["skills"]) <= en_el_paquete)
                self.assertTrue(p["sources"] and all(f["validUntil"] for f in p["sources"]))
                for runtime, herramientas in p["requiredTools"].items():
                    self.assertEqual("edit" in herramientas, p["writesSource"], runtime)
                agentes += [r["agentId"] for r in p["routes"] if r["agentId"]]
        # Each native agent has one default profile, the one the AGENTS.md block names.
        self.assertEqual(len(agentes), len(set(agentes)))

    def test_the_nineteen_live_agents_have_a_profile_or_are_marked_without_one(self):
        _, perfiles = real()
        con_perfil = sorted(
            r["agentId"] for p in perfiles["profiles"] for r in p["routes"] if r["agentId"]
        )
        sin_perfil = [a["agentId"] for a in perfiles["agents"] if a["status"] == "sin-perfil"]
        self.assertEqual(
            sin_perfil, ["pers", "limpia", "arras", "gonserver", "skillverif", "tinkabot", "eggbot"]
        )
        self.assertEqual(
            perfiles["agents"], [{"agentId": a, "status": "sin-perfil"} for a in sin_perfil]
        )
        # P1 (openclaw agents list --json, 2026-10-14): main is the requester, not a worker profile.
        self.assertEqual(
            sorted([*con_perfil, *sin_perfil, "main"]),
            sorted(
                [
                    "main",
                    "operaciones",
                    "ingenieria",
                    "implementer",
                    "reviewer",
                    "adversary",
                    "verifier",
                    "scout",
                    "amazon",
                    "pers",
                    "meli",
                    "mail",
                    "limpia",
                    "odoo",
                    "arras",
                    "gonserver",
                    "skillverif",
                    "tinkabot",
                    "eggbot",
                ]
            ),
        )

    def test_advisor_profiles_declare_their_coverage(self):
        _, perfiles = real()
        cobertura = {p["id"]: p["coverage"] for p in perfiles["profiles"]}
        self.assertEqual(
            (cobertura["adversario"], cobertura["revision"]), ("checkpoint-only", "checkpoint-only")
        )
        self.assertTrue(set(cobertura.values()) <= set(contexto.COBERTURAS))

    def test_a_profile_admits_only_its_routes_and_contracts(self):
        _, perfiles = real()
        meli = con_competencia(contexto.perfil(perfiles, "meli"))
        ingenieria = con_competencia(contexto.perfil(perfiles, "ingenieria"))
        self.assertEqual(
            contexto.admite(meli, CLI, "ready.v1", ahora=AHORA),
            contexto.Admision(
                "perfil-no-atiende-ruta", "el perfil meli no atiende la ruta mac-local/opencode"
            ),
        )
        self.assertEqual(
            contexto.admite(ingenieria, CLI, "review.v1", ahora=AHORA).causa,
            "perfil-no-admite-contrato",
        )
        self.assertEqual(contexto.admite(meli, nativa("meli"), "ready.v1", ahora=AHORA).causa, None)
        self.assertEqual(
            contexto.admite(meli, nativa("operaciones"), "ready.v1", ahora=AHORA).causa,
            "perfil-no-atiende-ruta",
        )
        self.assertEqual(contexto.admite(ingenieria, CLI, "ready.v1", ahora=AHORA).causa, None)

    def test_the_five_cli_profiles_have_certified_competence_until_their_sources_expire(self):
        # C4 de SUA03-G5c-r5: M-16 certifica la ruta CLI de los cinco perfiles;
        # su competence vale hasta que vencen sus fuentes (2027-01-14).
        _, perfiles = real()
        vigente = datetime(2026, 10, 16, tzinfo=timezone.utc)
        vencida = datetime(2027, 1, 15, tzinfo=timezone.utc)
        for identificador in (
            "ingenieria",
            "revision",
            "adversario",
            "verificacion",
            "exploracion",
        ):
            with self.subTest(perfil=identificador):
                perfil = contexto.perfil(perfiles, identificador)
                contrato = perfil["resultContracts"][0]
                self.assertIsNone(contexto.admite(perfil, CLI, contrato, ahora=vigente).causa)
                self.assertEqual(
                    contexto.admite(perfil, CLI, contrato, ahora=vencida).causa,
                    "perfil-sin-competencia",
                )

    def test_an_expired_source_or_a_missing_competence_closes_only_that_profile(self):
        _, perfiles = real()
        meli = con_competencia(contexto.perfil(perfiles, "meli"))
        amazon = con_competencia(contexto.perfil(perfiles, "amazon"))
        meli["sources"][0]["validUntil"] = "2026-10-01T00:00:00Z"
        self.assertEqual(
            contexto.admite(meli, nativa("meli"), "ready.v1", ahora=AHORA).causa,
            "perfil-sin-competencia",
        )
        self.assertEqual(
            contexto.admite(amazon, nativa("amazon"), "ready.v1", ahora=AHORA).causa, None
        )
        vencida = con_competencia(
            contexto.perfil(perfiles, "amazon"), valid_until="2026-10-13T00:00:00Z"
        )
        self.assertEqual(
            contexto.admite(vencida, nativa("amazon"), "ready.v1", ahora=AHORA).frase,
            "el perfil amazon no tiene competencia vigente en la ruta mini-native/native/amazon",
        )
        fallida = con_competencia(contexto.perfil(perfiles, "amazon"), status="failed")
        self.assertEqual(
            contexto.admite(fallida, nativa("amazon"), "ready.v1", ahora=AHORA).causa,
            "perfil-sin-competencia",
        )
        # Generation 1 has no competence yet: only a canary admits, and only on its own routes.
        pendiente = contexto.perfil(perfiles, "ingenieria")
        self.assertEqual(
            contexto.admite(pendiente, CLI, "ready.v1", ahora=AHORA).causa, "perfil-sin-competencia"
        )
        self.assertEqual(
            contexto.admite(pendiente, CLI, "ready.v1", ahora=AHORA, canario=True).causa, None
        )
        self.assertEqual(
            contexto.admite(pendiente, CLI, "review.v1", ahora=AHORA, canario=True).causa,
            "perfil-no-admite-contrato",
        )

    def test_each_profile_has_a_positive_and_a_negative_probe(self):
        _, perfiles = real()
        for p in perfiles["profiles"]:
            claves = {contexto.clave_de_ruta(r) for r in p["routes"]}
            for kind in ("positiva", "negativa"):
                with self.subTest(perfil=p["id"], kind=kind):
                    sonda = contexto.leer_json(
                        contexto.CONTEXTO / "competencia" / p["id"] / f"{kind}.json"
                    )
                    self.assertEqual((sonda["profile"], sonda["kind"]), (p["id"], kind))
                    self.assertTrue(
                        sonda["route"] is None and not claves or sonda["route"] in claves
                    )
                    self.assertTrue(sonda["brief"] and sonda["expect"])
                    if kind == "negativa":
                        self.assertEqual(
                            sonda["expect"], {"marker": "FUERA-DE-PERFIL", "workDone": False}
                        )


class Textos(unittest.TestCase):
    def test_the_agents_block_is_marked_and_short(self):
        manifiesto, _ = real()
        plantilla = contexto.BLOQUE.read_text(encoding="utf-8")
        hexa = manifiesto["digest"].removeprefix("sha256:")
        con = contexto.bloque(plantilla, manifiesto, "meli")
        sin = contexto.bloque(plantilla, manifiesto, None)
        for texto in (con, sin):
            self.assertTrue(
                texto.startswith(
                    f"<!-- sua-contexto inicio generación=1 digest=sha256:{hexa} -->\n"
                )
            )
            self.assertTrue(texto.endswith("\n<!-- sua-contexto fin -->\n"))
            self.assertLessEqual(len(texto), contexto.TOPE_BLOQUE)
        self.assertEqual(con.splitlines()[2], "Tu perfil por omisión es `meli`.")
        self.assertEqual(sin.splitlines()[2], contexto.SIN_PERFIL)
        self.assertNotIn("perfil por omisión es", sin)
        with self.assertRaisesRegex(ValueError, "el tope es 1500"):
            contexto.bloque("x" * 1501, manifiesto, "ingenieria")

    def test_a_default_profile_only_when_one_profile_names_the_agent(self):
        _, perfiles = real()
        defaults = {
            agente: contexto.perfil_por_omision(perfiles, agente)
            for agente in ("meli", "implementer", "pers", "main")
        }
        self.assertEqual(
            defaults, {"meli": "meli", "implementer": "ingenieria", "pers": None, "main": None}
        )
        dos = copy.deepcopy(perfiles)
        contexto.perfil(dos, "revision")["routes"].append(nativa("meli"))
        self.assertIsNone(contexto.perfil_por_omision(dos, "meli"))

    def test_the_run_instructions_name_the_profile(self):
        _, perfiles = real()
        texto = contexto.instrucciones(
            contexto.ADAPTACIONES["opencode-run"].read_text(encoding="utf-8"),
            contexto.perfil(perfiles, "revision"),
        )
        self.assertTrue(texto.startswith("# poteto en un encargo por CLI\n"))
        self.assertTrue(
            texto.endswith(
                "## Tu perfil: revision\n\nRevisa un cambio sin escribir fuente y entrega "
                "review.v1 con su veredicto y sus hallazgos.\n\n"
                "- Contratos que entregas: review.v1.\n"
                "- Escribes fuente: no.\n"
                "- Skills de tu perfil, además de poteto: blast-radius, how.\n"
            )
        )


class LineaDeComando(unittest.TestCase):
    def test_build_refuses_with_a_json_line(self):
        import contextlib
        import io

        out = io.StringIO()
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(out):
            code = contexto.main(
                [
                    "construir",
                    "--fuente",
                    str(Path(tmp) / "nada"),
                    "--perfil",
                    "revision",
                    "--destino",
                    str(Path(tmp) / "c"),
                ]
            )
        self.assertEqual(code, 3)
        respuesta = json.loads(out.getvalue())
        self.assertEqual(respuesta["ok"], False)
        self.assertRegex(
            respuesta["error"], r"^skills/blast-radius/SKILL.md: No such file or directory$"
        )


if __name__ == "__main__":
    unittest.main()

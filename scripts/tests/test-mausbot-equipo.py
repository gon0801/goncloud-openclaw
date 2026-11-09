#!/usr/bin/env python3
"""El generador y el aplicador del equipo de OpenMausBot, sin la app real ni la PC."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "mausbot"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402
import equipo  # noqa: E402


def skill_md(
    nombre: str, descripcion: str = "Una skill de prueba.", plataformas: str | None = None
) -> str:
    cabecera = f"---\nname: {nombre}\ndescription: {descripcion}\n"
    if plataformas:
        cabecera += f"platforms: [{plataformas}]\n"
    return cabecera + "---\n\n# " + nombre + "\n"


def escribir_perfil(raiz: Path, nombre: str, skills: dict[str, str]) -> None:
    for relativa, texto in skills.items():
        archivo = raiz / nombre / "skills" / relativa / "SKILL.md"
        archivo.parent.mkdir(parents=True, exist_ok=True)
        archivo.write_text(texto, encoding="utf-8")


def escribir_fuente_poteto(raiz: Path) -> Path:
    fuente = raiz / "poteto"
    (fuente / "skills" / "poteto-mode" / "playbooks").mkdir(parents=True, exist_ok=True)
    (fuente / "skills" / "poteto-mode" / "SKILL.md").write_text(
        skill_md("poteto-mode", "El modo de trabajo."), encoding="utf-8"
    )
    (fuente / "skills" / "poteto-mode" / "playbooks" / "feature.md").write_text(
        "pasos\n", encoding="utf-8"
    )
    (fuente / "skills" / "principle-uno" / "SKILL.md").parent.mkdir(parents=True, exist_ok=True)
    (fuente / "skills" / "principle-uno" / "SKILL.md").write_text(
        skill_md("principle-uno", "Un principio."), encoding="utf-8"
    )
    return fuente


def escribir_manifiesto(raiz: Path, fuente: Path) -> Path:
    manifiesto = contexto.manifiesto(
        fuente,
        {"profiles": []},
        repo="prueba",
        commit="0" * 40,
        version="0",
        generation=1,
        adaptaciones=contexto.leer_adaptaciones(),
        bloque=contexto.BLOQUE.read_bytes(),
    )
    ruta = raiz / "poteto.v1.json"
    ruta.write_text(json.dumps(manifiesto, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return ruta


EXPORT = """# export de prueba
version: 1
teams:
  - name: ingenieria
  - name: Implementer
  - name: Tienda The Glam Wedding
bots:
  - name: ingenieria
    team: ingenieria
    title: ingenieria
    soul: |-
      ===== AGENTS.md =====
      linea uno
      linea dos
    model: claude/claude-opus-5-5
    effort: high
    approval: full
    browser:
      enabled: true
      profile: claw
    tools:
      allow:
        - read
        - exec
    skills:
      - file: skills/ingenieria/viejo/SKILL.md
  - name: Implementer
    team: Implementer
    title: Implementer
    soul: |-
      Soy Implementer.
    model: opencodeGo/deepseek/deepseek-flash
    approval: full
    skills:
      - file: skills/implementer/viejo/SKILL.md
  - name: MausBot
    chief: true
    manages:
      - amazon
      - meli
    model: claude/claude-sonnet-5
    approval: full
  - name: Tienda The Glam Wedding
    team: Tienda The Glam Wedding
    title: tienda
    model: opencodeGo/deepseek/deepseek-flash
    approval: full
"""


class Generar(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.perfiles = self.tmp / "perfiles"
        self.fuente = escribir_fuente_poteto(self.tmp)
        self.manifiesto = escribir_manifiesto(self.tmp, self.fuente)
        self.salida = self.tmp / "salida"
        self.export = self.tmp / "export.yaml"
        self.export.write_text(EXPORT, encoding="utf-8")
        self.skills_ingenieria = {
            f"skill-{numero:02d}": skill_md(f"skill-{numero:02d}") for numero in range(35)
        }
        self.skills_ingenieria.update(
            {
                "devops/anidada": skill_md("anidada", "Una skill anidada."),
                "apple/apple-notes": skill_md("apple-notes", "Notas de Apple.", "macos"),
                "devops/hermes-cron": skill_md("hermes-cron-ops", "Crons de Hermes."),
                "devops/assets": skill_md(
                    "hermes-assets", "python ~/.hermes/skills/x/scripts/y.py"
                ),
                "portable/scratch": skill_md(
                    "portable-scratch", "mkdir -p ~/.hermes/cache/scratch"
                ),
                "portable/auth": skill_md(
                    "hermes-auth-opcional",
                    "Ejemplo: `hermes auth add openai-codex` es opcional.",
                ),
                "productivity/precio": skill_md(
                    "price-watch", 'cronjob(action="create")'
                ),
                "motor": skill_md("motor", "Version vieja del motor."),
                "poteto-mode": skill_md("poteto-mode", "Version vieja de poteto."),
            }
        )
        self.skills_ingenieria[".archive/vieja"] = skill_md("vieja")
        escribir_perfil(self.perfiles, "ingenieria", self.skills_ingenieria)
        (self.perfiles / "ingenieria" / "skills" / ".bundled_manifest").write_text(
            "skill-00:hash\n", encoding="utf-8"
        )
        escribir_perfil(self.perfiles, "implementer", {"propia": skill_md("propia")})
        tienda = self.tmp / "skills" / "tienda-the-glam-wedding"
        (tienda / "tienda-propia").mkdir(parents=True)
        (tienda / "tienda-propia" / "SKILL.md").write_text(
            skill_md("tienda-propia", "Una skill que ya estaba."), encoding="utf-8"
        )
        (tienda / "poteto-openclaw").mkdir()
        (tienda / "poteto-openclaw" / "SKILL.md").write_text(
            skill_md("poteto-openclaw", "La adaptación de OpenClaw."), encoding="utf-8"
        )

    def generar(self, *, forzar=False):
        return equipo.generar(
            self.export,
            self.perfiles,
            self.salida,
            self.fuente,
            manifiesto=self.manifiesto,
            repo=ROOT,
            forzar=forzar,
        )

    def documento(self):
        return json.loads((self.salida / "equipo.json").read_text(encoding="utf-8"))

    def test_a_profile_bot_gets_every_usable_skill_and_the_common_package(self):
        resultado = self.generar()
        documento = self.documento()
        bots = {bot["name"]: bot for bot in documento["bots"]}
        ingenieria = bots["ingenieria"]
        nombres = {
            Path(entrada["file"]).parent.name for entrada in ingenieria["skills"]
        }
        self.assertGreater(len(nombres), 30)
        esperadas = (
            "skill-00",
            "poteto-mode",
            "principle-uno",
            "poteto-mausbot",
            "motor",
            "skill-34",
            "anidada",
            "portable-scratch",
            "hermes-auth-opcional",
        )
        for esperada in esperadas:
            self.assertIn(esperada, nombres)
        self.assertNotIn("apple-notes", nombres)
        self.assertNotIn("hermes-cron-ops", nombres)
        motivos = {
            (exclusion.bot, exclusion.skill): exclusion.motivo
            for exclusion in resultado.excluidas
        }
        self.assertIn("macOS", motivos[("ingenieria", "apple-notes")])
        self.assertIn("Hermes", motivos[("ingenieria", "hermes-cron-ops")])
        self.assertIn("archivos internos", motivos[("ingenieria", "hermes-assets")])
        self.assertIn("planificador", motivos[("ingenieria", "price-watch")])
        self.assertIn("repo", motivos[("ingenieria", "motor")])
        self.assertIn("común", motivos[("ingenieria", "poteto-mode")])
        tienda = {
            Path(entrada["file"]).parent.name
            for entrada in bots["Tienda The Glam Wedding"]["skills"]
        }
        self.assertIn("tienda-propia", tienda)
        self.assertIn("poteto-mausbot", tienda)
        self.assertNotIn("poteto-openclaw", tienda)
        self.assertIn("runtime", motivos[("Tienda The Glam Wedding", "poteto-openclaw")])
        self.assertIn("carpeta interna", motivos[("ingenieria", "vieja")])
        for comun in ("poteto-mode", "poteto-mausbot"):
            self.assertIn(comun, tienda)
        for entrada in ingenieria["skills"]:
            self.assertTrue((self.salida / entrada["file"]).is_file(), entrada["file"])
        self.assertEqual(resultado.bots, 4)

    def test_only_mausbot_and_ingenieria_leave_motor_on(self):
        self.generar()
        bots = {bot["name"]: bot for bot in self.documento()["bots"]}
        motor = {
            nombre: next(
                entrada for entrada in bot["skills"] if Path(entrada["file"]).parent.name == "motor"
            )
            for nombre, bot in bots.items()
        }
        self.assertNotIn("enabled", motor["MausBot"])
        self.assertNotIn("enabled", motor["ingenieria"])
        self.assertIs(motor["Implementer"]["enabled"], False)
        self.assertIs(motor["Tienda The Glam Wedding"]["enabled"], False)
        texto = (self.salida / motor["MausBot"]["file"]).read_text(encoding="utf-8")
        self.assertIn("--director mausbot", texto)
        self.assertNotIn("--director claw", texto)
        self.assertIn("C:\\Users\\ehven\\motor-runtime", texto)
        self.assertIn("PYTHONPATH=C:\\Users\\ehven\\motor-sucesor", texto)
        self.assertIn("No module named motor.encargos", texto)

    def test_model_effort_approval_and_soul_are_the_export_values(self):
        self.generar()
        bots = {bot["name"]: bot for bot in self.documento()["bots"]}
        self.assertEqual(bots["ingenieria"]["model"], "claude/claude-opus-5-5")
        self.assertEqual(bots["ingenieria"]["effort"], "high")
        self.assertEqual(bots["ingenieria"]["approval"], "full")
        self.assertEqual(
            bots["ingenieria"]["soul"], "===== AGENTS.md =====\nlinea uno\nlinea dos"
        )
        self.assertEqual(bots["MausBot"]["model"], "claude/claude-sonnet-5")
        self.assertEqual(bots["MausBot"]["approval"], "full")
        self.assertNotIn("effort", bots["MausBot"])
        self.assertNotIn("soul", bots["MausBot"])
        self.assertEqual(bots["MausBot"]["manages"], ["amazon", "meli"])
        self.assertEqual(
            bots["ingenieria"]["browser"], {"enabled": True, "profile": "claw"}
        )
        self.assertEqual(bots["ingenieria"]["tools"], {"allow": ["read", "exec"]})

    def test_every_bot_gets_this_computer(self):
        self.generar()
        for bot in self.documento()["bots"]:
            self.assertEqual(bot["computer"], "local", bot["name"])

    def test_generating_twice_produces_the_same_tree(self):
        self.generar()
        primero = {
            ruta.relative_to(self.salida).as_posix(): ruta.read_bytes()
            for ruta in sorted(self.salida.rglob("*"))
            if ruta.is_file()
        }
        self.generar(forzar=True)
        segundo = {
            ruta.relative_to(self.salida).as_posix(): ruta.read_bytes()
            for ruta in sorted(self.salida.rglob("*"))
            if ruta.is_file()
        }
        self.assertEqual(primero, segundo)

    def test_a_tampered_mausbot_adaptation_is_refused(self):
        manifiesto = json.loads(self.manifiesto.read_text(encoding="utf-8"))
        manifiesto["adaptations"]["mausbot"] = "0" * 64
        manifiesto["digest"] = contexto.digest_de(manifiesto)
        self.manifiesto.write_text(
            json.dumps(manifiesto, ensure_ascii=False), encoding="utf-8"
        )
        with self.assertRaisesRegex(contexto.ContextoIncompleto, "adaptación mausbot"):
            self.generar()

    def test_a_skill_with_a_token_stops_the_generator(self):
        escribir_perfil(
            self.perfiles,
            "ingenieria",
            {"token": skill_md("token", "ghp_" + "A" * 36)},
        )
        with self.assertRaisesRegex(equipo.SecretoEncontrado, "posible secreto"):
            self.generar()
        self.assertFalse(self.salida.exists())


class Secretos(unittest.TestCase):
    def test_prose_is_not_a_token_and_a_long_key_is(self):
        for prosa in ("sk-tracking", "sk-tool-availability"):
            with self.subTest(prosa=prosa):
                self.assertFalse(equipo._es_token(equipo.SECRET_RE.search(prosa)))
        for clave in ("sk-" + "a" * 24, "ghp_" + "A" * 36):
            with self.subTest(clave=clave[:8]):
                self.assertTrue(equipo._es_token(equipo.SECRET_RE.search(clave)))


class Aplicar(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.salida = self.tmp / "salida"
        self.salida.mkdir()
        (self.salida / "skills" / "bot" / "uno").mkdir(parents=True)
        (self.salida / "skills" / "bot" / "uno" / "SKILL.md").write_text(
            skill_md("uno"), encoding="utf-8"
        )
        self.equipo = self.salida / "equipo.json"
        self.equipo.write_text(
            json.dumps(
                {
                    "version": 1,
                    "bots": [
                        {
                            "name": "bot",
                            "computer": "local",
                            "skills": [{"file": "skills/bot/uno/SKILL.md"}],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.log = self.tmp / "openmausbot.log"
        self.falso = self.tmp / "openmausbot.py"
        self.falso.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['FAKE_OPENMAUSBOT_LOG'], 'a', encoding='utf-8') as fh:\n"
            "    fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "print('Plan: 0 to create, 0 to change, 0 unchanged, 0 to delete.')\n",
            encoding="utf-8",
        )
        self.falso.chmod(self.falso.stat().st_mode | stat.S_IXUSR)

    def correr(self, *, aplicar_ahora=False):
        entorno = os.environ.copy()
        entorno["FAKE_OPENMAUSBOT_LOG"] = str(self.log)
        anterior = os.environ.get("FAKE_OPENMAUSBOT_LOG")
        os.environ["FAKE_OPENMAUSBOT_LOG"] = str(self.log)
        try:
            return equipo.aplicar(
                self.equipo,
                aplicar_ahora=aplicar_ahora,
                openmausbot=self.falso,
                cli=Path("openmausbot.js"),
            )
        finally:
            if anterior is None:
                os.environ.pop("FAKE_OPENMAUSBOT_LOG", None)
            else:
                os.environ["FAKE_OPENMAUSBOT_LOG"] = anterior

    def lineas(self):
        return [json.loads(linea) for linea in self.log.read_text(encoding="utf-8").splitlines()]

    def test_default_application_is_a_dry_run_and_never_prunes(self):
        self.assertEqual(self.correr(), 0)
        invocacion = self.lineas()
        self.assertEqual(len(invocacion), 1)
        self.assertEqual(
            invocacion[0], ["openmausbot.js", "team", "apply", str(self.equipo), "--dry-run"]
        )
        for argumentos in invocacion:
            self.assertNotIn("--prune", argumentos)
            self.assertNotIn("--rotate-secrets", argumentos)

    def test_explicit_application_plans_first_and_then_applies(self):
        self.assertEqual(self.correr(aplicar_ahora=True), 0)
        invocaciones = self.lineas()
        self.assertEqual(len(invocaciones), 2)
        self.assertEqual(
            invocaciones[0], ["openmausbot.js", "team", "apply", str(self.equipo), "--dry-run"]
        )
        self.assertEqual(
            invocaciones[1], ["openmausbot.js", "team", "apply", str(self.equipo)]
        )
        for argumentos in invocaciones:
            self.assertNotIn("--prune", argumentos)
            self.assertNotIn("--rotate-secrets", argumentos)


if __name__ == "__main__":
    unittest.main()

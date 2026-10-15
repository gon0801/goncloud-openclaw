#!/usr/bin/env python3
"""La conducta de un trabajador con poteto, leída de sus eventos (SUA-03, sección 5, I08)."""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import conducta  # noqa: E402

RUN = "/Users/dn/.local/state/agent-work-host/enc-1/runs/op"
PLAYBOOK = "contexto/skills/poteto-mode/playbooks/feature.md"
SIN_POTETO = "falta la lectura de contexto/skills/poteto-mode/SKILL.md antes del primer cambio"
TEXTO = (
    "### Feature\n\n**You own the design.**\n\n"
    "1. `how` over the affected\n   subsystem.\n2. `architect`.\n"
)
SALIDA = "....\n" + "-" * 70 + "\nRan 4 tests in 0.01s\n\nOK\n"


def herramienta(tool, status="completed", output="", **entrada):
    return json.dumps(
        {
            "type": "tool_use",
            "timestamp": 1,
            "sessionID": "ses_1",
            "part": {
                "type": "tool",
                "tool": tool,
                "state": {"status": status, "input": entrada, "output": output},
            },
        }
    )


def corrida(*, sin=(), todo="`how` over the affected subsystem.", pruebas_antes=False):
    """Una corrida que sigue poteto, menos los pasos de `sin`."""
    pasos = {
        "skill": herramienta("read", filePath=f"{RUN}/contexto/skills/poteto-mode/SKILL.md"),
        "playbook": herramienta("read", filePath=f"{RUN}/{PLAYBOOK}"),
        "lista": herramienta("todowrite", todos=[{"content": todo, "status": "in_progress"}]),
        "cambio": herramienta(
            "edit", filePath="/Users/dn/dev/demo/calc.py", oldString="-", newString="+"
        ),
        "pruebas": herramienta("bash", command="python3 -m unittest test_calc.py", output=SALIDA),
    }
    orden = ["skill", "playbook", "lista", "cambio", "pruebas"]
    if pruebas_antes:
        orden = ["skill", "playbook", "lista", "pruebas", "cambio"]
    return [pasos[nombre] for nombre in orden if nombre not in sin]


def juzgar(lineas, resultado="Pruebas: Ran 4 tests in 0.01s, OK."):
    return conducta.juzgar(
        conducta.pasos_opencode(lineas),
        playbook=PLAYBOOK,
        texto_del_playbook=TEXTO,
        resultado=resultado,
    )


class Conducta(unittest.TestCase):
    def test_a_run_that_follows_poteto_passes(self):
        self.assertEqual(
            juzgar(corrida() + ["no es JSON", json.dumps({"type": "text"})]),
            conducta.Veredicto(True, ()),
        )

    def test_the_control_without_poteto_is_red_for_the_expected_reason(self):
        self.assertEqual(
            juzgar(corrida(sin=("skill", "playbook", "lista"))),
            conducta.Veredicto(
                False,
                (
                    SIN_POTETO,
                    f"falta la lectura de {PLAYBOOK} antes del primer cambio",
                    "no hay lista de pasos (todowrite)",
                ),
            ),
        )

    def test_reading_poteto_after_the_first_change_or_outside_the_package_does_not_count(self):
        tarde = corrida(sin=("skill",))
        tarde.insert(4, herramienta("read", filePath=f"{RUN}/contexto/skills/poteto-mode/SKILL.md"))
        fuera = corrida(sin=("skill",))
        fuera.insert(
            0, herramienta("read", filePath="/Users/dn/.agents/skills/poteto-mode/SKILL.md")
        )
        negada = corrida(sin=("skill",))
        negada.insert(
            0,
            herramienta(
                "read", status="error", filePath=f"{RUN}/contexto/skills/poteto-mode/SKILL.md"
            ),
        )
        for nombre, lineas in (("tarde", tarde), ("fuera", fuera), ("negada", negada)):
            with self.subTest(nombre):
                self.assertEqual(
                    juzgar(lineas).razones,
                    (SIN_POTETO,),
                )

    def test_the_first_list_starts_with_the_playbooks_first_step_in_its_words(self):
        self.assertEqual(conducta.primer_paso(TEXTO), "`how` over the affected subsystem.")
        self.assertEqual(
            juzgar(corrida(todo="Read the code first")).razones,
            (
                "la primera lista no empieza con el primer paso del playbook: "
                "'`how` over the affected subsystem.'",
            ),
        )
        self.assertTrue(
            juzgar(corrida(todo="1. `how`  over the affected\nsubsystem. Then plan.")).ok
        )
        largo = "1. Reproduce it yourself on the matching surface. Then name the cause.\n"
        lineas = corrida(todo="Reproduce it yourself on the matching surface.")
        self.assertTrue(
            conducta.juzgar(
                conducta.pasos_opencode(lineas),
                playbook=PLAYBOOK,
                texto_del_playbook=largo,
                resultado="Ran 4 tests in 0.01s",
            ).ok
        )
        with self.assertRaisesRegex(ValueError, "el playbook no tiene un paso 1"):
            conducta.primer_paso("### Sin pasos\n")

    def test_tests_run_after_the_last_change_and_cited_in_the_result(self):
        self.assertEqual(
            juzgar(corrida(pruebas_antes=True)).razones,
            ("no corrió pruebas después del último cambio",),
        )
        self.assertEqual(
            juzgar(corrida(), resultado="Listo, todo bien.").razones,
            ("el resultado no cita la salida de las últimas pruebas",),
        )
        sin_pruebas = corrida(sin=("pruebas",)) + [
            herramienta("bash", command="ls -la", output="calc.py\n")
        ]
        self.assertEqual(
            juzgar(sin_pruebas).razones, ("no corrió pruebas después del último cambio",)
        )

    def test_the_command_line_answers_one_json_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "events.jsonl").write_text("\n".join(corrida(sin=("skill",))) + "\n")
            libro = tmp / "run" / PLAYBOOK
            libro.parent.mkdir(parents=True)
            libro.write_text(TEXTO)
            (tmp / "resultado.md").write_text("Ran 4 tests in 0.01s\n")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = conducta.main(
                    [
                        "--eventos",
                        str(tmp / "events.jsonl"),
                        "--playbook",
                        str(libro),
                        "--resultado",
                        str(tmp / "resultado.md"),
                    ]
                )
        self.assertEqual(
            (code, json.loads(out.getvalue())),
            (
                1,
                {
                    "ok": False,
                    "razones": [SIN_POTETO],
                },
            ),
        )

    def test_a_playbook_outside_the_package_is_a_usage_error_and_not_a_false_missing_read(self):
        # split("contexto/", 1)[-1] sobre una ruta sin contexto/ devolvía la ruta entera: la
        # etiqueta nunca calzaba con lectura alguna y el veredicto reportaba un falso "falta la
        # lectura" en vez de un error de uso (bots de #303, L166).
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "events.jsonl").write_text("\n".join(corrida()) + "\n")
            (tmp / "resultado.md").write_text("Ran 4 tests in 0.01s\n")
            fuera = tmp / "feature.md"
            fuera.write_text(TEXTO)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = conducta.main(
                    [
                        "--eventos",
                        str(tmp / "events.jsonl"),
                        "--playbook",
                        str(fuera),
                        "--resultado",
                        str(tmp / "resultado.md"),
                    ]
                )
        self.assertEqual(code, 3)
        respuesta = json.loads(out.getvalue())
        self.assertFalse(respuesta["ok"])
        self.assertIn("contexto/", respuesta["error"])
        self.assertNotIn("razones", respuesta)

    def test_a_playbook_path_that_only_spells_contexto_is_a_usage_error(self):
        # Hallazgo de CodeRabbit en #305: la guarda miraba el texto y no el lugar, y aceptaba
        # <raiz>/contexto/../feature.md. La ruta se resuelve antes de validarla, se exige un
        # componente `contexto` en la ruta resuelta, el archivo se lee de esa misma ruta y la
        # etiqueta se deriva desde ahí.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "events.jsonl").write_text("\n".join(corrida()) + "\n")
            (tmp / "resultado.md").write_text("Ran 4 tests in 0.01s\n")
            (tmp / "contexto").mkdir()
            (tmp / "feature.md").write_text(TEXTO)
            engañoso = str(tmp / "contexto" / ".." / "feature.md")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = conducta.main(
                    [
                        "--eventos",
                        str(tmp / "events.jsonl"),
                        "--playbook",
                        str(engañoso),
                        "--resultado",
                        str(tmp / "resultado.md"),
                    ]
                )
        self.assertEqual(code, 3)
        respuesta = json.loads(out.getvalue())
        self.assertFalse(respuesta["ok"])
        self.assertIn("resuelta", respuesta["error"])
        self.assertNotIn("razones", respuesta)


if __name__ == "__main__":
    unittest.main()

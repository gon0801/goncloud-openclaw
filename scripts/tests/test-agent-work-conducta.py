#!/usr/bin/env python3
"""La conducta de un trabajador con poteto, leída de sus eventos (SUA-03, sección 5, I08)."""

from __future__ import annotations

import ast
import base64
import contextlib
import importlib.util
import io
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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

    def test_a_relative_write_is_resolved_against_the_workers_directory(self):
        # C5 de SUA03-G5c: una ruta relativa de un evento se resuelve contra la
        # carpeta de trabajo del trabajador (--directorio), no contra el cwd de
        # conducta; con ella, el write excluido no cuenta como cambio tras las pruebas.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = tmp / "repo"
            repo.mkdir()
            lineas = corrida() + [herramienta("write", filePath="RESULTADO.md")]
            (tmp / "events.jsonl").write_text("\n".join(lineas) + "\n")
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
                        "--directorio",
                        str(repo),
                        "--excluir",
                        str(repo / "RESULTADO.md"),
                    ]
                )
        self.assertEqual((code, json.loads(out.getvalue())), (0, {"ok": True, "razones": []}))

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

    def playbook_de_fixture(self, tmp, nombre="feature.md"):
        """El playbook del fixture bajo un árbol con contexto/, como lo exige la guarda,
        con el nombre que la corrida real leyó."""
        libro = tmp / "contexto" / "skills" / "poteto-mode" / "playbooks" / nombre
        libro.parent.mkdir(parents=True)
        shutil.copy(FIXTURAS / "m16b-feature.md", libro)
        return libro

    def test_the_real_m16b_engineering_run_measures_green_with_its_exclusions(self):
        # D1 a D4 sobre la corrida real del banco (M-16 corrida 2): la skill cargada con
        # la herramienta skill cuenta como lectura del paquete, los escritos de la propia
        # corrida y del artefacto no son cambios, delegar sí lo es, y el primer paso se
        # compara sin backticks.
        corrida = (
            "/private/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T"
            "/agent-work-banco-rd0b4swq/state/enc-1"
        )
        artefacto = (
            "/private/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T"
            "/agent-work-banco-rd0b4swq/dev/demo/RESULTADO.md"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                codigo = conducta.main(
                    [
                        "--eventos",
                        str(FIXTURAS / "m16b-ingenieria.jsonl"),
                        "--playbook",
                        str(self.playbook_de_fixture(tmp)),
                        "--resultado",
                        str(FIXTURAS / "m16b-ingenieria-RESULTADO.md"),
                        "--excluir",
                        corrida,
                        "--excluir",
                        artefacto,
                    ]
                )
        self.assertEqual(codigo, 0, out.getvalue())
        self.assertEqual(json.loads(out.getvalue()), {"ok": True, "razones": []})

    def test_the_real_m16b_control_stays_red_for_the_missing_package_read(self):
        # El control cargó poteto-mode desde ~/.agents/skills (el global): no cuenta.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                codigo = conducta.main(
                    [
                        "--eventos",
                        str(FIXTURAS / "m16b-control.jsonl"),
                        "--playbook",
                        str(self.playbook_de_fixture(tmp)),
                        "--resultado",
                        str(FIXTURAS / "m16b-ingenieria-RESULTADO.md"),
                        "--excluir",
                        "/private/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T"
                        "/agent-work-banco-rd0b4swq/state/enc-1",
                    ]
                )
        self.assertEqual(codigo, 1, out.getvalue())
        self.assertEqual(
            json.loads(out.getvalue())["razones"][0],
            "falta la lectura de contexto/skills/poteto-mode/SKILL.md antes del primer cambio",
        )

    def test_delegating_counts_as_a_change_so_tests_must_come_after_it(self):
        # D3: el arreglo lo hizo el hijo del task, y sus eventos no están en este flujo;
        # el task del padre es el último cambio visible y las pruebas le sigan o no hay.
        filas = [
            herramienta("skill", name="poteto-mode", output="cargada"),
            herramienta("read", filePath="/repo/contexto/skills/poteto-mode/SKILL.md"),
            herramienta("read", filePath="/repo/contexto/skills/poteto-mode/playbooks/feature.md"),
            herramienta(
                "todowrite",
                todos=[{"content": "how over the affected subsystem.", "status": "pending"}],
            ),
            herramienta("bash", command="python3 -m unittest -v", output="OK (1 test)"),
            herramienta("task", description="arregla saluda()"),
        ]
        veredicto = juzgar(filas, resultado="OK (1 test)")
        self.assertEqual(
            veredicto, conducta.Veredicto(False, ("no corrió pruebas después del último cambio",))
        )


MODULO_NATIVO = ROOT / "scripts" / "agent-work" / "extraer-nativo.py"
FIXTURAS = ROOT / "scripts" / "tests" / "fixtures" / "conducta"
SIN_POTETO_NATIVO = "falta la lectura de skills/poteto-mode/SKILL.md antes del primer cambio"
PASO_UNO_DEL_FIXTURE = "Lee la skill de poteto y escribe la lista de pasos antes de tocar nada."
SALIDA_HIJA = (
    "test_a (test_calc.Calcula) ... ok\n"
    "test_b (test_calc.Calcula) ... ok\n"
    "\n" + "-" * 70 + "\nRan 2 tests in 0.001s\n\nOK (2 tests)\n"
)
MINI = "gon@mini-de-prueba"
SSH_FALSO_NATIVO = """#!/bin/sh
# ssh de juguete del extractor: registra la llamada, guarda el código que llega por stdin
# y contesta, por cada sesión pedida, las filas crudas que el test dejó en sesiones/.
for arg in "$@"; do printf '%s\\n' "$arg" >> "$SUA_TEST_LOGS/ssh.log"; done
printf '%s\\n' --- >> "$SUA_TEST_LOGS/ssh.log"
sesiones=""
anterior=""
for arg in "$@"; do
  if [ "$anterior" = "--sesiones" ]; then sesiones="$arg"; fi
  anterior="$arg"
done
case " $* " in
  *" python3 - "*)
    # El código remoto llega por stdin: guardarlo y consumirlo antes de contestar.
    cat > "$SUA_TEST_LOGS/codigo-remoto.py"
    IFS=,
    for sesion in $sesiones; do
      cat "$SUA_TEST_LOGS/sesiones/$sesion.jsonl" 2>/dev/null || true
    done
    exit 0
    ;;
esac
exit 0
"""


def fila_nativa(clave, sesion, seq, creado, evento):
    return json.dumps(
        {
            "session_key": clave,
            "session_id": sesion,
            "seq": seq,
            "created_at": creado,
            "event": evento,
        },
        ensure_ascii=False,
    )


def llamada_nativa(clave, sesion, seq, creado, identificador, nombre, argumentos):
    return fila_nativa(
        clave,
        sesion,
        seq,
        creado,
        {
            "type": "message",
            "message": {
                "role": "assistant",
                "content": [
                    {
                        "type": "toolCall",
                        "id": identificador,
                        "name": nombre,
                        "arguments": argumentos,
                    }
                ],
            },
        },
    )


def resultado_nativo(clave, sesion, seq, creado, identificador, nombre, texto, con_error=False):
    return fila_nativa(
        clave,
        sesion,
        seq,
        creado,
        {
            "type": "message",
            "message": {
                "role": "toolResult",
                "toolCallId": identificador,
                "toolName": nombre,
                "isError": con_error,
                "content": [{"type": "text", "text": texto}],
            },
        },
    )


def llamadas_del_registro(registro):
    """Las llamadas de un log de ssh de juguete: argumentos por línea, --- entre llamadas."""
    llamadas, actual = [], []
    for linea in registro.read_text(encoding="utf-8").splitlines():
        if linea == "---":
            llamadas.append(actual)
            actual = []
        else:
            actual.append(linea)
    if actual:
        llamadas.append(actual)
    return llamadas


def hay_compresor():
    """Si esta máquina puede comprimir la fila zstd de juguete: compression.zstd o el binario."""
    try:
        from compression import zstd  # noqa: F401
    except ImportError:
        return shutil.which("zstd") is not None
    return True


def comprimir_de_prueba(datos):
    try:
        from compression import zstd
    except ImportError:
        resultado = subprocess.run(["zstd", "-c"], input=datos, capture_output=True, timeout=60)
        if resultado.returncode != 0:
            raise RuntimeError(
                "ni compression.zstd ni el binario zstd comprimen la fila de juguete"
            ) from None
        return base64.b64encode(resultado.stdout).decode("ascii")
    return base64.b64encode(zstd.compress(datos)).decode("ascii")


class ConductaNativa(unittest.TestCase):
    """La forma openclaw: eventos nativos de la Mini y lecturas bajo skills/."""

    def playbook_en_skills(self, tmp):
        """El fixture del playbook copiado bajo un componente skills/, como los paquetes
        nativos: la guarda de --forma openclaw lo exige y el fixture vive bajo conducta/."""
        libro = tmp / "skills" / "poteto-mode" / "playbooks" / "playbook.md"
        libro.parent.mkdir(parents=True)
        shutil.copy(FIXTURAS / "playbook.md", libro)
        return libro

    def test_the_real_m15_control_is_red_for_the_missing_native_poteto_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "resultado.md").write_text("cualquier cosa\n", encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                codigo = conducta.main(
                    [
                        "--forma",
                        "openclaw",
                        "--eventos",
                        str(FIXTURAS / "m15-control.jsonl"),
                        "--playbook",
                        str(self.playbook_en_skills(tmp)),
                        "--resultado",
                        str(tmp / "resultado.md"),
                    ]
                )
        self.assertEqual(codigo, 1)
        respuesta = json.loads(out.getvalue())
        self.assertFalse(respuesta["ok"])
        self.assertEqual(respuesta["razones"][0], SIN_POTETO_NATIVO)

    def test_a_native_run_whose_child_tests_after_the_change_follows_poteto(self):
        padre, hijo = "agent:x:turno", "agent:x:subagent:1"
        filas = [
            # El hijo corre las pruebas DESPUÉS del cambio del padre pero sus filas van
            # ANTES en el archivo: solo el orden por (created_at, seq) lo pone en su lugar.
            llamada_nativa(
                hijo,
                "s-hija",
                0,
                108,
                "c-hija",
                "exec",
                {"command": "cd /tmp/repo && python3 -m unittest -v"},
            ),
            resultado_nativo(hijo, "s-hija", 1, 109, "c-hija", "exec", SALIDA_HIJA),
            llamada_nativa(
                padre,
                "s-padre",
                0,
                100,
                "c1",
                "read",
                {"path": "/Users/dn/.openclaw/skills/poteto-mode/SKILL.md"},
            ),
            resultado_nativo(padre, "s-padre", 1, 101, "c1", "read", "# poteto\n"),
            llamada_nativa(
                padre,
                "s-padre",
                2,
                102,
                "c2",
                "read",
                {"path": "/Users/dn/.openclaw/skills/poteto-mode/playbooks/playbook.md"},
            ),
            resultado_nativo(padre, "s-padre", 3, 103, "c2", "read", "# playbook\n"),
            llamada_nativa(
                padre,
                "s-padre",
                4,
                104,
                "c3",
                "progress_card",
                {"plan": [{"step": PASO_UNO_DEL_FIXTURE, "status": "in_progress"}]},
            ),
            resultado_nativo(padre, "s-padre", 5, 105, "c3", "progress_card", "ok"),
            llamada_nativa(
                padre, "s-padre", 6, 106, "c4", "write", {"file_path": "/tmp/repo/a.py"}
            ),
            resultado_nativo(padre, "s-padre", 7, 107, "c4", "write", "1 archivo cambiado\n"),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "eventos.jsonl").write_text("\n".join(filas) + "\n", encoding="utf-8")
            (tmp / "resultado.md").write_text("Pruebas del hijo: OK (2 tests)\n", encoding="utf-8")
            resultado = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "agent-work" / "conducta.py"),
                    "--forma",
                    "openclaw",
                    "--eventos",
                    str(tmp / "eventos.jsonl"),
                    "--playbook",
                    str(self.playbook_en_skills(tmp)),
                    "--resultado",
                    str(tmp / "resultado.md"),
                ],
                capture_output=True,
                text=True,
                timeout=60,
            )
        self.assertEqual(resultado.stderr, "")
        self.assertEqual(resultado.returncode, 0)
        self.assertEqual(resultado.stdout.splitlines(), ['{"ok": true, "razones": []}'])

    def test_pasos_openclaw_unwraps_tool_call_and_drops_errored_calls(self):
        envuelta = [
            llamada_nativa(
                "agent:x:turno",
                "s",
                0,
                1,
                "c1",
                "tool_call",
                {"id": "sessions_spawn", "args": {"task": "t"}},
            ),
            resultado_nativo("agent:x:turno", "s", 1, 2, "c1", "tool_call", "ok"),
        ]
        directa = [
            llamada_nativa("agent:x:turno", "s", 0, 1, "c1", "sessions_spawn", {"task": "t"}),
            resultado_nativo("agent:x:turno", "s", 1, 2, "c1", "sessions_spawn", "ok"),
        ]
        esperado = [conducta.Paso("sessions_spawn", None, "t", "ok")]
        self.assertEqual(conducta.pasos_openclaw(envuelta), esperado)
        self.assertEqual(conducta.pasos_openclaw(directa), esperado)
        con_error = [
            llamada_nativa("agent:x:turno", "s", 0, 1, "c1", "sessions_spawn", {"task": "t"}),
            resultado_nativo(
                "agent:x:turno", "s", 1, 2, "c1", "sessions_spawn", "boom", con_error=True
            ),
        ]
        self.assertEqual(conducta.pasos_openclaw(con_error), [])


class ExtractorNativo(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        self.logs = self.tmp / "logs"
        self.sesiones = self.logs / "sesiones"
        self.sesiones.mkdir(parents=True)
        self.binarios = self.tmp / "bin"
        self.binarios.mkdir()
        ruta = self.binarios / "ssh"
        ruta.write_text(SSH_FALSO_NATIVO, encoding="utf-8")
        ruta.chmod(0o755)
        self.salida = self.tmp / "eventos.jsonl"

    def cruda(self, clave, seq, creado, evento, comprimido=False):
        """Una fila como la imprime la mitad Mini: el evento en event_json o en event_zstd."""
        return json.dumps(
            {
                "session_key": clave,
                "session_id": "s-" + clave.split(":")[-1],
                "seq": seq,
                "created_at": creado,
                "event_json": (
                    None
                    if comprimido
                    else json.dumps(evento, ensure_ascii=False, separators=(",", ":"))
                ),
                "event_zstd": (
                    comprimir_de_prueba(json.dumps(evento).encode()) if comprimido else None
                ),
            }
        )

    def escribir_sesion(self, clave, filas):
        (self.sesiones / f"{clave}.jsonl").write_text("\n".join(filas) + "\n", encoding="utf-8")

    def extraer(self, banderas):
        return subprocess.run(
            [
                sys.executable,
                str(MODULO_NATIVO),
                "--mini",
                MINI,
                "--agente",
                "x",
                *banderas,
                "--salida",
                str(self.salida),
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env={
                **os.environ,
                "PATH": str(self.binarios) + os.pathsep + os.environ["PATH"],
                "SUA_TEST_LOGS": str(self.logs),
            },
        )

    def test_the_extractor_writes_both_rows_with_their_events_decoded(self):
        if not hay_compresor():
            self.skipTest(
                "sin compression.zstd ni binario zstd no se puede armar la fila comprimida"
            )
        self.escribir_sesion(
            "agent:x:turno",
            [
                self.cruda("agent:x:turno", 0, 1, {"type": "session", "version": 4}),
                self.cruda(
                    "agent:x:turno",
                    1,
                    2,
                    {"type": "message", "message": {"role": "user"}},
                    comprimido=True,
                ),
            ],
        )
        resultado = self.extraer(["--sesion", "agent:x:turno"])
        self.assertEqual((resultado.returncode, resultado.stderr), (0, ""))
        self.assertEqual(len(resultado.stdout.splitlines()), 1)
        self.assertTrue(json.loads(resultado.stdout.splitlines()[0])["ok"])
        # El código remoto fue por stdin y abre la base read-only.
        self.assertIn("mode=ro", (self.logs / "codigo-remoto.py").read_text(encoding="utf-8"))
        filas = [
            json.loads(linea) for linea in self.salida.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            filas,
            [
                {
                    "session_key": "agent:x:turno",
                    "session_id": "s-turno",
                    "seq": 0,
                    "created_at": 1,
                    "event": {"type": "session", "version": 4},
                },
                {
                    "session_key": "agent:x:turno",
                    "session_id": "s-turno",
                    "seq": 1,
                    "created_at": 2,
                    "event": {"type": "message", "message": {"role": "user"}},
                },
            ],
        )

    def test_con_hijos_follows_the_spawned_children_with_more_ssh_calls(self):
        self.escribir_sesion(
            "agent:x:turno",
            [
                self.cruda(
                    "agent:x:turno",
                    0,
                    1,
                    {
                        "type": "message",
                        "message": {
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "toolCall",
                                    "id": "c1",
                                    "name": "tool_call",
                                    "arguments": {"id": "sessions_spawn", "args": {"task": "t"}},
                                }
                            ],
                        },
                    },
                ),
                self.cruda(
                    "agent:x:turno",
                    1,
                    2,
                    {
                        "type": "message",
                        "message": {
                            "role": "toolResult",
                            "toolCallId": "c1",
                            "toolName": "tool_call",
                            "isError": False,
                            "content": [
                                {
                                    "type": "text",
                                    "text": '{"status": "accepted", "childSessionKey": '
                                    '"agent:x:subagent:9", "runId": "r1"}',
                                }
                            ],
                        },
                    },
                ),
            ],
        )
        self.escribir_sesion(
            "agent:x:subagent:9",
            [self.cruda("agent:x:subagent:9", 0, 3, {"type": "session", "version": 4})],
        )
        resultado = self.extraer(["--sesion", "agent:x:turno", "--con-hijos"])
        self.assertEqual((resultado.returncode, resultado.stderr), (0, ""))
        llamadas = llamadas_del_registro(self.logs / "ssh.log")
        self.assertEqual(len(llamadas), 2)
        primera, segunda = llamadas
        self.assertEqual(primera[primera.index("--sesiones") + 1], "agent:x:turno")
        self.assertEqual(segunda[segunda.index("--sesiones") + 1], "agent:x:subagent:9")
        filas = [
            json.loads(linea) for linea in self.salida.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            [fila["session_key"] for fila in filas],
            ["agent:x:turno", "agent:x:turno", "agent:x:subagent:9"],
        )
        self.assertEqual(
            json.loads(resultado.stdout.splitlines()[0])["sesiones"],
            ["agent:x:subagent:9", "agent:x:turno"],
        )

    def test_a_corrupt_zstd_row_is_an_error_line_and_not_a_traceback(self):
        # N2 del veredicto r1: ZstdError no es ValueError; un evento corrupto contesta
        # línea JSON con salida 3 y no escribe --salida.
        try:
            from compression import zstd  # noqa: F401
        except ImportError:
            self.skipTest("esta prueba fija el camino de compression.zstd, no el del binario")
        self.escribir_sesion(
            "agent:x:turno",
            [
                self.cruda("agent:x:turno", 0, 1, {"type": "session", "version": 4}),
                self.cruda("agent:x:turno", 1, 2, {"type": "message"}, comprimido=True),
            ],
        )
        # Corromper la fila comprimida: la prueba la reescribe con bytes que no son zstd.
        ruta = self.sesiones / "agent:x:turno.jsonl"
        fila = json.loads(ruta.read_text(encoding="utf-8").splitlines()[1])
        fila["event_zstd"] = base64.b64encode(b"esto no es zstd").decode("ascii")
        lineas = ruta.read_text(encoding="utf-8").splitlines()
        lineas[1] = json.dumps(fila)
        ruta.write_text("\n".join(lineas) + "\n", encoding="utf-8")
        resultado = self.extraer(["--sesion", "agent:x:turno"])
        self.assertEqual(resultado.returncode, 3, resultado.stderr)
        self.assertEqual(resultado.stderr, "")
        respuesta = json.loads(resultado.stdout.splitlines()[0])
        self.assertFalse(respuesta["ok"])
        self.assertFalse(self.salida.exists())

    def test_the_remote_arguments_travel_quoted_for_the_mini_shell(self):
        # N3 del veredicto r1: ssh los pasa por el shell de la Mini; base y sesiones viajan
        # con shlex.quote para que un espacio o un metacarácter no parta el comando.
        self.escribir_sesion(
            "agent:x:turno",
            [self.cruda("agent:x:turno", 0, 1, {"type": "session", "version": 4})],
        )
        base = str(self.logs / "base con espacio.sqlite")
        resultado = self.extraer(["--sesion", "agent:x:turno", "--base", base])
        self.assertEqual((resultado.returncode, resultado.stderr), (0, ""))
        llamadas = [
            linea
            for linea in (self.logs / "ssh.log").read_text(encoding="utf-8").splitlines()
            if linea not in ("---", "--db", "--sesiones")
        ]
        self.assertIn(shlex.quote(base), llamadas)
        self.assertIn(shlex.quote("agent:x:turno"), llamadas)

    def test_without_a_decoder_a_json_only_session_still_extracts(self):
        # B2 (Minor de CodeRabbit en #307): el decodificador se exige solo al llegar una
        # fila comprimida; una sesión con solo filas event_json se extrae sin zstd.
        especificacion = importlib.util.spec_from_file_location("extraer_nativo", MODULO_NATIVO)
        modulo = importlib.util.module_from_spec(especificacion)
        especificacion.loader.exec_module(modulo)
        filas = "[filas]\n" + self.cruda("agent:x:turno", 0, 1, {"type": "session", "version": 4})

        def ssh_falso(comando, input=None, capture_output=True, text=True, timeout=None, **kwargs):
            assert "python3" in comando, comando
            return subprocess.CompletedProcess(
                comando, 0, stdout=filas.replace("[filas]\n", ""), stderr=""
            )

        out = io.StringIO()
        with (
            mock.patch.object(modulo, "_decodificador", return_value=None),
            mock.patch.object(modulo.subprocess, "run", side_effect=ssh_falso),
            contextlib.redirect_stdout(out),
        ):
            codigo = modulo.main(
                [
                    "--mini",
                    MINI,
                    "--agente",
                    "x",
                    "--sesion",
                    "agent:x:turno",
                    "--salida",
                    str(self.salida),
                ]
            )
        self.assertEqual(codigo, 0)
        filas_escritas = [
            json.loads(linea) for linea in self.salida.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            filas_escritas,
            [
                {
                    "session_key": "agent:x:turno",
                    "session_id": "s-turno",
                    "seq": 0,
                    "created_at": 1,
                    "event": {"type": "session", "version": 4},
                }
            ],
        )

    def test_without_a_decoder_a_compressed_row_is_an_error_line_and_writes_nothing(self):
        especificacion = importlib.util.spec_from_file_location("extraer_nativo", MODULO_NATIVO)
        modulo = importlib.util.module_from_spec(especificacion)
        especificacion.loader.exec_module(modulo)
        filas = self.cruda("agent:x:turno", 0, 1, {"type": "session"}, comprimido=True)

        def ssh_falso(comando, input=None, capture_output=True, text=True, timeout=None, **kwargs):
            return subprocess.CompletedProcess(comando, 0, stdout=filas + "\n", stderr="")

        out = io.StringIO()
        with (
            mock.patch.object(modulo, "_decodificador", return_value=None),
            mock.patch.object(modulo.subprocess, "run", side_effect=ssh_falso),
            contextlib.redirect_stdout(out),
        ):
            codigo = modulo.main(
                [
                    "--mini",
                    MINI,
                    "--agente",
                    "x",
                    "--sesion",
                    "agent:x:turno",
                    "--salida",
                    str(self.salida),
                ]
            )
        self.assertEqual(codigo, 3)
        self.assertEqual(len(out.getvalue().splitlines()), 1)
        respuesta = json.loads(out.getvalue())
        self.assertFalse(respuesta["ok"])
        self.assertIn("zstd", respuesta["error"])
        self.assertFalse(self.salida.exists())


class SintaxisNativa(unittest.TestCase):
    def test_the_module_and_its_remote_code_parse_as_python_3_9(self):
        fuente = MODULO_NATIVO.read_text(encoding="utf-8")
        ast.parse(fuente, filename=str(MODULO_NATIVO), feature_version=(3, 9))
        especificacion = importlib.util.spec_from_file_location("extraer_nativo", MODULO_NATIVO)
        modulo = importlib.util.module_from_spec(especificacion)
        especificacion.loader.exec_module(modulo)
        ast.parse(modulo.CODIGO_REMOTO, filename="remoto", feature_version=(3, 9))
        resultado = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                "import ast, importlib.util, sys; "
                "e = importlib.util.spec_from_file_location('n', sys.argv[1]); "
                "m = importlib.util.module_from_spec(e); e.loader.exec_module(m); "
                "ast.parse(m.CODIGO_REMOTO, feature_version=(3, 9))",
                str(MODULO_NATIVO),
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual((resultado.returncode, resultado.stderr), (0, ""))


if __name__ == "__main__":
    unittest.main()

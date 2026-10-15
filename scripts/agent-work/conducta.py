#!/usr/bin/env python3
"""La conducta de un trabajador con poteto, leída de sus eventos (diseño de SUA-03, sección 5).

Un digest dice qué texto se entregó, no que el modelo lo siguió. Esto lee lo que hizo:

1. Leyó `contexto/skills/poteto-mode/SKILL.md` y el playbook de su tarea antes del primer cambio.
2. Su primera lista de pasos (`todowrite`) empieza con la primera frase del primer paso del
   playbook, con sus palabras.
3. Corrió pruebas después del último cambio.
4. El resultado cita la salida de esa corrida.

Es una aproximación (riesgo 1 del diseño): un modelo puede leer, escribir la lista y tomar un
atajo. Por eso cada sonda tiene su control, que debe dar rojo por la razón esperada. Las formas de
los eventos son
las de opencode 1.18.35 (`tool_use` con `part.tool` y `part.state.input`); las de las rutas nativas
esperan a la lectura del `unknown` 6 y no están aquí.

    conducta.py --eventos <events.jsonl> --playbook <playbook.md> --resultado <archivo>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

POTETO = "contexto/skills/poteto-mode/SKILL.md"
EDITS = ("edit", "write", "patch", "multiedit")
TESTS = re.compile(
    r"(^|[\s/;&|])(pytest|unittest|test[-_]\S+\.(py|sh)|run-checks\.sh|npm (run )?test|"
    r"pnpm (run )?test|vitest|go test|cargo test|bun test)",
    re.IGNORECASE,
)
PRIMER_PASO = re.compile(r"^1\.\s+(.+)$", re.MULTILINE)
CITADAS = 5
"""Las últimas líneas de la salida de las pruebas que pueden citarse en el resultado."""


@dataclass(frozen=True)
class Paso:
    """Una herramienta que el trabajador usó y terminó."""

    tool: str
    path: str | None
    detail: str
    output: str


@dataclass(frozen=True)
class Veredicto:
    ok: bool
    razones: tuple[str, ...]


def _espacios(texto: str) -> str:
    return " ".join(texto.split())


def primer_paso(playbook: str) -> str:
    """El primer paso numerado del playbook, sin su número, con las líneas sangradas que lo
    continúan (no sus viñetas)."""
    hallado = PRIMER_PASO.search(playbook)
    if hallado is None:
        raise ValueError("el playbook no tiene un paso 1")
    partes = [hallado[1]]
    for linea in playbook[hallado.end() :].split("\n")[1:]:
        limpia = linea.strip()
        if not linea[:1].isspace() or not limpia or re.match(r"([-*+]|\d+\.)\s", limpia):
            break
        partes.append(limpia)
    return _espacios(" ".join(partes))


def pasos_opencode(lineas: list[str]) -> list[Paso]:
    """Los `tool_use` completados del flujo `--format json` de opencode, en orden. Una línea que no
    es JSON o un evento de otra forma no aportan."""
    pasos = []
    for linea in lineas:
        try:
            evento = json.loads(linea)
        except ValueError:
            continue
        if not isinstance(evento, dict) or evento.get("type") != "tool_use":
            continue
        part = evento.get("part") if isinstance(evento.get("part"), dict) else {}
        state = part.get("state") if isinstance(part.get("state"), dict) else {}
        if state.get("status") != "completed":
            continue
        entrada = state.get("input") if isinstance(state.get("input"), dict) else {}
        ruta = entrada.get("filePath") or entrada.get("path")
        if part.get("tool") == "todowrite":
            todos = entrada.get("todos") if isinstance(entrada.get("todos"), list) else []
            detalle = (
                str(todos[0].get("content", "")) if todos and isinstance(todos[0], dict) else ""
            )
        elif part.get("tool") == "bash":
            detalle = str(entrada.get("command", ""))
        else:
            detalle = ""
        pasos.append(
            Paso(
                str(part.get("tool")),
                str(ruta) if ruta else None,
                detalle,
                str(state.get("output") or ""),
            )
        )
    return pasos


def _lee(paso: Paso, sufijo: str) -> bool:
    return paso.tool == "read" and paso.path is not None and paso.path.endswith(sufijo)


def juzgar(
    pasos: list[Paso], *, playbook: str, texto_del_playbook: str, resultado: str
) -> Veredicto:
    """La conducta de una corrida contra las cuatro condiciones. `playbook` es la ruta del playbook
    dentro del paquete (`contexto/skills/poteto-mode/playbooks/<nombre>.md`)."""
    razones = []
    cambios = [i for i, paso in enumerate(pasos) if paso.tool in EDITS]
    primero = cambios[0] if cambios else len(pasos)
    if not any(_lee(paso, POTETO) for paso in pasos[:primero]):
        razones.append(f"falta la lectura de {POTETO} antes del primer cambio")
    if not any(_lee(paso, playbook) for paso in pasos[:primero]):
        razones.append(f"falta la lectura de {playbook} antes del primer cambio")
    listas = [paso for paso in pasos if paso.tool == "todowrite"]
    # La primera frase del paso: un paso de playbook puede ser un párrafo; un elemento de lista no.
    paso_uno = re.split(r"(?<=\.)\s", primer_paso(texto_del_playbook), maxsplit=1)[0]
    if not listas:
        razones.append("no hay lista de pasos (todowrite)")
    elif paso_uno not in _espacios(listas[0].detail):
        razones.append(f"la primera lista no empieza con el primer paso del playbook: {paso_uno!r}")
    ultimo = cambios[-1] if cambios else -1
    pruebas = [
        paso for paso in pasos[ultimo + 1 :] if paso.tool == "bash" and TESTS.search(paso.detail)
    ]
    if not pruebas:
        razones.append("no corrió pruebas después del último cambio")
    else:
        salida = [
            linea.strip() for linea in pruebas[-1].output.splitlines() if len(linea.strip()) > 1
        ]
        if not any(linea in resultado for linea in salida[-CITADAS:]):
            razones.append("el resultado no cita la salida de las últimas pruebas")
    return Veredicto(not razones, tuple(razones))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--eventos", type=Path, required=True)
    parser.add_argument(
        "--playbook", type=Path, required=True, help="el playbook dentro del paquete"
    )
    parser.add_argument("--resultado", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if "contexto/" not in args.playbook.as_posix():
            raise ValueError(
                f"--playbook debe ser la ruta del playbook dentro del paquete "
                f"(con contexto/): {args.playbook}"
            )
        pasos = pasos_opencode(
            args.eventos.read_text(encoding="utf-8", errors="replace").splitlines()
        )
        texto = args.playbook.read_text(encoding="utf-8")
        resultado = args.resultado.read_text(encoding="utf-8", errors="replace")
        ruta = "contexto/" + args.playbook.as_posix().split("contexto/", 1)[-1]
        veredicto = juzgar(pasos, playbook=ruta, texto_del_playbook=texto, resultado=resultado)
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": veredicto.ok, "razones": list(veredicto.razones)}, ensure_ascii=False))
    return 0 if veredicto.ok else 1


if __name__ == "__main__":
    sys.exit(main())

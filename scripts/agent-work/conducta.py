#!/usr/bin/env python3
"""La conducta de un trabajador con poteto, leída de sus eventos (diseño de SUA-03, sección 5).

Un digest dice qué texto se entregó, no que el modelo lo siguió. Esto lee lo que hizo:

1. Leyó la skill de poteto y el playbook de su tarea antes del primer cambio.
2. Su primera lista de pasos (`todowrite`) empieza con la primera frase del primer paso del
   playbook, con sus palabras.
3. Corrió pruebas después del último cambio.
4. El resultado cita la salida de esa corrida.

Es una aproximación (riesgo 1 del diseño): un modelo puede leer, escribir la lista y tomar un
atajo. Por eso cada sonda tiene su control, que debe dar rojo por la razón esperada. Las dos
formas de eventos son las de opencode 1.18.35 (`tool_use` con `part.tool` y `part.state.input`,
paquete `contexto/`) y las nativas de OpenClaw (`transcript_events` con `toolCall`/`toolResult`,
paquete `skills/`, que `extraer-nativo.py` baja de la Mini).

    conducta.py --forma openclaw --eventos <eventos.jsonl> --playbook <playbook.md> \
        --resultado <archivo>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

POTETO = "skills/poteto-mode/SKILL.md"
"""La skill de poteto dentro del paquete, sin el prefijo de la forma (contexto/ o nada)."""
EDITS = ("edit", "write", "patch", "multiedit")
TESTS = re.compile(
    r"(^|[\s/;&|])(pytest|unittest|test[-_]\S+\.(py|sh)|run-checks\.sh|npm (run )?test|"
    r"pnpm (run )?test|vitest|go test|cargo test|bun test)",
    re.IGNORECASE,
)
PRIMER_PASO = re.compile(r"^1\.\s+(.+)$", re.MULTILINE)
CITADAS = 5
"""Las últimas líneas de la salida de las pruebas que pueden citarse en el resultado."""
RAIZ_DE_FORMA = {"opencode": "contexto", "openclaw": "skills"}
PREFIJO_DE_FORMA = {"opencode": "contexto/", "openclaw": ""}
ENVUELTA = "tool_call"
"""El nombre que envuelve las llamadas nativas: arguments trae la herramienta en `id` y sus
argumentos en `args` (caso real de M-15: sessions_spawn)."""
MARCAS_DE_LISTA = ("- [ ] ", "- ", "* ", "1. ")
"""Las marcas de lista que puede traer el markdown de un progress_card; la de casilla va
antes que su propio guion para quitarse entera."""


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
    es JSON o un evento de otra forma no aportan. Una carga de skill (herramienta `skill`) cuenta
    como la lectura del SKILL.md de la carpeta que opencode reporta en `state.metadata.dir`: es
    lectura del paquete solo si esa carpeta está dentro de él (D1). Delegar con `task` cuenta como
    cambio: el hijo puede editar y sus eventos no están en este flujo, así que tomarlo como cambio
    es la aproximación conservadora del riesgo 1 del diseño (D3)."""
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
        herramienta = str(part.get("tool"))
        if herramienta == "todowrite":
            todos = entrada.get("todos") if isinstance(entrada.get("todos"), list) else []
            detalle = (
                str(todos[0].get("content", "")) if todos and isinstance(todos[0], dict) else ""
            )
        elif herramienta == "bash":
            detalle = str(entrada.get("command", ""))
        elif herramienta == "task":
            detalle = str(entrada.get("description", ""))
        else:
            detalle = ""
        if herramienta == "skill":
            carpeta = (
                (state.get("metadata") or {}).get("dir")
                if isinstance(state.get("metadata"), dict)
                else None
            )
            pasos.append(
                Paso(
                    "read",
                    f"{carpeta}/SKILL.md" if carpeta else None,
                    detalle,
                    str(state.get("output") or ""),
                )
            )
            continue
        if herramienta == "task":
            pasos.append(Paso("edit", None, detalle, str(state.get("output") or "")))
            continue
        pasos.append(
            Paso(
                herramienta,
                str(ruta) if ruta else None,
                detalle,
                str(state.get("output") or ""),
            )
        )
    return pasos


def _lee(paso: Paso, sufijo: str) -> bool:
    return paso.tool == "read" and paso.path is not None and paso.path.endswith(sufijo)


def _texto_de(contenido: object) -> str:
    """El texto de un toolResult nativo: la unión de los `text` de su contenido. Lo que no
    tiene esa forma (contenido ausente, piezas sin texto) aporta vacío, no rompe."""
    trozos = []
    if isinstance(contenido, list):
        for pieza in contenido:
            if isinstance(pieza, dict) and pieza.get("text") is not None:
                trozos.append(str(pieza["text"]))
    return "".join(trozos)


def _detalle_de_lista(argumentos: dict) -> str:
    """El primer paso de una lista nativa: `plan[0].step` si trae plan y, si no, la primera
    línea con contenido del markdown, sin su marca de lista."""
    plan = argumentos.get("plan")
    if isinstance(plan, list) and plan and isinstance(plan[0], dict) and plan[0].get("step"):
        return str(plan[0]["step"])
    marcado = argumentos.get("markdown")
    if isinstance(marcado, str):
        for linea in marcado.splitlines():
            limpia = linea.strip()
            if not limpia:
                continue
            for marca in MARCAS_DE_LISTA:
                if limpia.startswith(marca):
                    return limpia[len(marca) :].strip()
            return limpia
    return ""


def _paso_nativo(nombre: str, argumentos: dict, salida: str) -> Paso:
    """Una llamada nativa traducida al vocabulario que `juzgar` ya conoce de opencode."""
    if nombre == "read":
        ruta = argumentos.get("path")
        return Paso("read", str(ruta) if ruta else None, "", salida)
    if nombre in ("edit", "write", "apply_patch"):
        ruta = argumentos.get("path") or argumentos.get("file_path")
        return Paso("edit", str(ruta) if ruta else None, "", salida)
    if nombre in ("progress_card", "update_plan"):
        return Paso("todowrite", None, _detalle_de_lista(argumentos), salida)
    if nombre == "exec":
        return Paso("bash", None, str(argumentos.get("command") or ""), salida)
    if nombre == "sessions_spawn":
        return Paso("sessions_spawn", None, str(argumentos.get("task") or ""), salida)
    return Paso(nombre, None, "", salida)


def pasos_openclaw(lineas: list[str]) -> list[Paso]:
    """Las llamadas con resultado sin error de los eventos nativos de OpenClaw (una fila
    `{"session_key","session_id","seq","created_at","event"}` por línea), de todas las
    sesiones juntas y en orden temporal: el padre cede con sessions_yield mientras el hijo
    corre, así que el (created_at, seq) de la llamada mezcla las sesiones donde ocurrieron.

    Solo cuentan las llamadas cuya toolResult existe y no vino en error: el equivalente
    nativo del `completed` de opencode."""
    resultados: dict[str, str] = {}
    llamadas: list[tuple[tuple[int, int], str, str, dict]] = []
    for linea in lineas:
        try:
            fila = json.loads(linea)
        except ValueError:
            continue
        if not isinstance(fila, dict):
            continue
        evento = fila.get("event")
        if not isinstance(evento, dict) or evento.get("type") != "message":
            continue
        mensaje = evento.get("message")
        if not isinstance(mensaje, dict):
            continue
        rol = mensaje.get("role")
        if rol == "toolResult":
            if not mensaje.get("isError"):
                resultados[str(mensaje.get("toolCallId"))] = _texto_de(mensaje.get("content"))
            continue
        if rol != "assistant":
            continue
        orden = (
            fila.get("created_at") if isinstance(fila.get("created_at"), int) else 0,
            fila.get("seq") if isinstance(fila.get("seq"), int) else 0,
        )
        contenido = mensaje.get("content")
        if not isinstance(contenido, list):
            continue
        for pieza in contenido:
            if not isinstance(pieza, dict) or pieza.get("type") != "toolCall":
                continue
            nombre = str(pieza.get("name") or "")
            argumentos = pieza.get("arguments") if isinstance(pieza.get("arguments"), dict) else {}
            if (
                nombre == ENVUELTA
                and argumentos.get("id")
                and isinstance(argumentos.get("args"), dict)
            ):
                nombre, argumentos = str(argumentos["id"]), argumentos["args"]
            llamadas.append((orden, str(pieza.get("id")), nombre, argumentos))
    pasos: list[tuple[tuple[int, int], Paso]] = []
    for orden, identificador, nombre, argumentos in llamadas:
        salida = resultados.get(identificador)
        if salida is None:
            continue
        pasos.append((orden, _paso_nativo(nombre, argumentos, salida)))
    return [paso for _, paso in sorted(pasos, key=lambda par: par[0])]


def juzgar(
    pasos: list[Paso],
    *,
    playbook: str,
    texto_del_playbook: str,
    resultado: str,
    prefijo: str = "contexto/",
) -> Veredicto:
    """La conducta de una corrida contra las cuatro condiciones. `playbook` es la ruta del
    playbook dentro del paquete, etiquetada como la exige la forma (`contexto/skills/...`
    en opencode, `skills/...` en openclaw); `prefijo` es el de las lecturas que cuentan."""
    poteto = prefijo + POTETO
    libro = prefijo + playbook.removeprefix("contexto/")
    razones = []
    cambios = [i for i, paso in enumerate(pasos) if paso.tool in EDITS]
    primero = cambios[0] if cambios else len(pasos)
    if not any(_lee(paso, poteto) for paso in pasos[:primero]):
        razones.append(f"falta la lectura de {poteto} antes del primer cambio")
    if not any(_lee(paso, libro) for paso in pasos[:primero]):
        razones.append(f"falta la lectura de {libro} antes del primer cambio")
    listas = [paso for paso in pasos if paso.tool == "todowrite"]
    # La primera frase del paso: un paso de playbook puede ser un párrafo; un elemento de lista no.
    paso_uno = re.split(r"(?<=\.)\s", primer_paso(texto_del_playbook), maxsplit=1)[0]
    if not listas:
        razones.append("no hay lista de pasos (todowrite)")
    # Sin el marcado de los dos lados (D4): el playbook escribe "`how` over..." y la lista
    # del modelo lo deja sin backticks.
    elif paso_uno.replace("`", "") not in _espacios(listas[0].detail).replace("`", ""):
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
    parser.add_argument(
        "--excluir",
        action="append",
        type=Path,
        default=[],
        help="ruta que no cuenta como cambio: un edit/write en ella o debajo se ignora "
        "(repetible; la corrida pasa su carpeta y su artefacto)",
    )
    parser.add_argument(
        "--directorio",
        type=Path,
        default=None,
        help="carpeta de trabajo del trabajador: una ruta relativa de un evento se "
        "resuelve contra ella antes de compararla con --excluir",
    )
    parser.add_argument(
        "--forma",
        choices=tuple(RAIZ_DE_FORMA),
        default="opencode",
        help="de dónde vienen los eventos: opencode (--format json) o la Mini nativa",
    )
    args = parser.parse_args(argv)
    try:
        # La guarda mira el lugar y no el texto (hallazgo de CodeRabbit en #305): resuelve
        # primero y exige un componente raíz en la ruta resuelta (contexto/ en opencode,
        # skills/ en openclaw); el archivo se lee de esa misma ruta y la etiqueta se deriva
        # desde ahí, para que `raiz/contexto/../feature.md` no pase.
        resuelta = args.playbook.resolve()
        raiz = RAIZ_DE_FORMA[args.forma]
        if raiz not in resuelta.parts:
            raise ValueError(
                f"--playbook debe ser la ruta del playbook dentro del paquete "
                f"(con {raiz}/ en su ruta resuelta): {args.playbook}"
            )
        lector = pasos_opencode if args.forma == "opencode" else pasos_openclaw
        pasos = lector(args.eventos.read_text(encoding="utf-8", errors="replace").splitlines())
        # D2: los escritos del propio publicador (acceptRef, resultRef, el artefacto) no
        # son cambios del trabajador. resolve() no exige que las rutas existan.
        raices = [ruta.resolve() for ruta in args.excluir]
        if raices:

            def excluido(paso: Paso) -> bool:
                if paso.tool not in EDITS or paso.path is None:
                    return False
                cruda = Path(paso.path)
                if args.directorio is not None and not cruda.is_absolute():
                    resuelta = (args.directorio / cruda).resolve()
                else:
                    resuelta = cruda.resolve()
                return any(resuelta == raiz or raiz in resuelta.parents for raiz in raices)

            pasos = [paso for paso in pasos if not excluido(paso)]
        texto = resuelta.read_text(encoding="utf-8")
        resultado = args.resultado.read_text(encoding="utf-8", errors="replace")
        ruta = raiz + "/" + "/".join(resuelta.parts[resuelta.parts.index(raiz) + 1 :])
        veredicto = juzgar(
            pasos,
            playbook=ruta,
            texto_del_playbook=texto,
            resultado=resultado,
            prefijo=PREFIJO_DE_FORMA[args.forma],
        )
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": veredicto.ok, "razones": list(veredicto.razones)}, ensure_ascii=False))
    return 0 if veredicto.ok else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""La conducta de un trabajador con poteto, leída de sus eventos (diseño de SUA-03, sección 5).

Un digest dice qué texto se entregó, no que el modelo lo siguió. Esto lee lo que hizo:

1. Leyó la skill de poteto y el playbook de su tarea antes del primer cambio.
2. Su primera lista de pasos (`todowrite`) empieza con la primera frase del primer paso del
   playbook, con sus palabras.
3. Corrió pruebas después del último cambio.
4. El resultado cita la salida de esa corrida.

Es una aproximación (riesgo 1 del diseño): un modelo puede leer, escribir la lista y tomar un
atajo. Por eso cada sonda tiene su control, que debe dar rojo por la razón esperada. Las tres
formas de eventos son las de opencode 1.18.35 (`tool_use` con `part.tool` y `part.state.input`,
paquete `contexto/`), el stream-json de claude (eventos `assistant` con `tool_use` de nombres
`Read`/`Edit`/`Bash` y `file_path`, M-21, paquete `contexto/`) y las nativas de OpenClaw
(`transcript_events` con `toolCall`/`toolResult`, paquete `skills/`, que `extraer-nativo.py`
baja de la Mini).

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
RAIZ_DE_FORMA = {"opencode": "contexto", "openclaw": "skills", "claude": "contexto"}
PREFIJO_DE_FORMA = {"opencode": "contexto/", "openclaw": "", "claude": "contexto/"}
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
            detalle = "\n".join(
                str(todo.get("content", "")) for todo in todos if isinstance(todo, dict)
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
    tiene esa forma (contenido ausente, piezas sin texto) aporta vacío, no rompe.

    Una llamada que llegó por `tool_search` devuelve ese texto como un JSON con la
    forma del resultado interno: la salida es su `details.aggregated` y, si no lo
    trae, la unión de los `text` de su `content`. Lo que no es un JSON así queda
    como está."""
    trozos = []
    if isinstance(contenido, list):
        for pieza in contenido:
            if isinstance(pieza, dict) and pieza.get("text") is not None:
                trozos.append(str(pieza["text"]))
    texto = "".join(trozos)
    try:
        interno = json.loads(texto)
    except ValueError:
        return texto
    if not isinstance(interno, dict):
        return texto
    if isinstance(interno.get("result"), dict):
        interno = interno["result"]
    detalles = interno.get("details")
    if isinstance(detalles, dict) and isinstance(detalles.get("aggregated"), str):
        return detalles["aggregated"]
    partes = interno.get("content")
    if isinstance(partes, list):
        return "".join(
            str(pieza["text"])
            for pieza in partes
            if isinstance(pieza, dict) and pieza.get("text") is not None
        )
    return texto


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
    """Una llamada nativa traducida al vocabulario que `juzgar` ya conoce de opencode.

    Las herramientas que llegan por `tool_search` traen el nombre con espacio de
    nombres (`openclaw:core:progress_card`): cuenta su última parte."""
    nombre = nombre.rsplit(":", 1)[-1]
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


def _salida_claude(contenido: object) -> str:
    """El texto de un tool_result de claude: un string, o la unión de los `text` de
    su contenido (la misma unión que `_texto_de`)."""
    if isinstance(contenido, str):
        return contenido
    return _texto_de(contenido)


def _paso_claude(nombre: str, entrada: dict, salida: str) -> Paso:
    """Una llamada de claude traducida al vocabulario que `juzgar` ya conoce. Los
    nombres medidos en 2.1.301 (p3b/p4/p5 y M-24 punto 5) viajan con mayúscula y
    las rutas en `file_path`. La lista de pasos de claude es `TaskCreate` (el
    TodoWrite no existe en 2.1.301): cada llamada es un elemento y su `subject`
    es el texto del paso; `TaskUpdate` no aporta paso de lista y cae genérico.
    Un `Task` cuenta como cambio, como el `task` de opencode (D3): los eventos
    de su hijo no están en este stream. Una `Skill` de claude no cuenta como
    lectura del paquete: su input no trae carpeta y la copia que carga puede ser
    la global, no la de la corrida; la del paquete se lee con Read por su ruta."""
    ruta = entrada.get("file_path") or entrada.get("path") or entrada.get("notebook_path")
    if nombre == "Read":
        return Paso("read", str(ruta) if ruta else None, "", salida)
    if nombre in ("Edit", "Write", "NotebookEdit"):
        return Paso("edit", str(ruta) if ruta else None, "", salida)
    if nombre == "Bash":
        return Paso("bash", None, str(entrada.get("command") or ""), salida)
    if nombre == "TaskCreate":
        return Paso("todowrite", None, str(entrada.get("subject") or ""), salida)
    if nombre in ("Task", "Agent"):
        return Paso("edit", None, str(entrada.get("description") or ""), salida)
    return Paso(nombre.lower(), str(ruta) if ruta else None, "", salida)


def pasos_claude(lineas: list[str]) -> list[Paso]:
    """Las llamadas con resultado del stream-json de claude (M-21, punto 4): un evento
    `assistant` por llamada (`tool_use` con id, name e input) y su resultado en el
    `tool_result` de un evento `user` posterior, emparejado por id. Solo cuentan las
    llamadas cuyo resultado llegó, el equivalente del `completed` de opencode; una
    salida con error (un Bash con exit 1) también terminó y cuenta."""
    resultados: dict[str, str] = {}
    llamadas: list[tuple[str, str, dict]] = []
    for linea in lineas:
        try:
            evento = json.loads(linea)
        except ValueError:
            continue
        if not isinstance(evento, dict):
            continue
        mensaje = evento.get("message") if isinstance(evento.get("message"), dict) else {}
        piezas = mensaje.get("content") if isinstance(mensaje.get("content"), list) else []
        if evento.get("type") == "user":
            for pieza in piezas:
                if isinstance(pieza, dict) and pieza.get("type") == "tool_result":
                    resultados[str(pieza.get("tool_use_id"))] = _salida_claude(pieza.get("content"))
        elif evento.get("type") == "assistant":
            for pieza in piezas:
                if isinstance(pieza, dict) and pieza.get("type") == "tool_use":
                    entrada = pieza.get("input") if isinstance(pieza.get("input"), dict) else {}
                    llamadas.append(
                        (str(pieza.get("id") or ""), str(pieza.get("name") or ""), entrada)
                    )
    pasos = []
    for identificador, nombre, entrada in llamadas:
        salida = resultados.get(identificador)
        if salida is None:
            continue
        pasos.append(_paso_claude(nombre, entrada, salida))
    return pasos


def _primeras_frases_numeradas(texto: str) -> dict[int, str]:
    """La primera frase de cada paso numerado del playbook, sin backticks."""
    frases = {}
    for hallado in re.finditer(r"^(\d+)\.\s+(.+)$", texto, re.MULTILINE):
        frase = re.split(r"(?<=\.)\s", hallado[2].strip(), maxsplit=1)[0]
        frases[int(hallado[1])] = _espacios(frase).replace("`", "")
    return frases


def _trozo_distintivo(texto: str) -> str:
    """El trozo distintivo de un texto del paquete (B5a de G7-r6): su primera línea
    de al menos 40 caracteres fuera del encabezado YAML, con los espacios colapsados.
    Una sola línea y no tres unidas porque el tool_result que suele cargarla (el Read
    del archivo tool-results de claude) trae cada línea con su número delante y solo
    el contenido de la línea queda contiguo. Vacío si no hay ninguna."""
    lineas = texto.splitlines()
    if lineas and lineas[0].strip() == "---":
        cierre = next((i for i, linea in enumerate(lineas[1:], 1) if linea.strip() == "---"), None)
        if cierre is not None:
            lineas = lineas[cierre + 1 :]
    return _espacios(next((linea for linea in lineas if len(linea.strip()) >= 40), ""))


def juzgar(
    pasos: list[Paso],
    *,
    playbook: str,
    texto_del_playbook: str,
    resultado: str,
    prefijo: str = "contexto/",
    forma: str = "opencode",
    textos_de_lectura: dict[str, str] | None = None,
) -> Veredicto:
    """La conducta de una corrida contra las cuatro condiciones. `playbook` es la ruta del
    playbook dentro del paquete, etiquetada como la exige la forma (`contexto/skills/...`
    en opencode, `skills/...` en openclaw); `prefijo` es el de las lecturas que cuentan.
    `textos_de_lectura` (solo forma claude) mapea sufijos del paquete al texto de la copia
    de la corrida y activa la lectura por contenido (B5a) y la cita de cualquier línea de
    la salida de pruebas (B5b): en el banco real claude leyó el paquete con un cat cuya
    salida se persistió y se releó con Read del archivo tool-results, y su última llamada
    que corre pruebas también armó el result.json en el mismo Bash."""
    poteto = prefijo + POTETO
    libro = prefijo + playbook.removeprefix("contexto/")
    trozos = (
        {prefijo + sufijo: _trozo_distintivo(texto) for sufijo, texto in textos_de_lectura.items()}
        if forma == "claude" and textos_de_lectura
        else {}
    )

    def _lectura(sufijo: str) -> int | None:
        """La posición donde P quedó leída: un Read de su ruta, o el primer paso cuyo
        tool_result trae su trozo distintivo (B5a de G7-r6). None si no hubo."""
        trozo = trozos.get(sufijo, "")
        return next(
            (
                i
                for i, paso in enumerate(pasos)
                if _lee(paso, sufijo) or (trozo and trozo in _espacios(paso.output))
            ),
            None,
        )

    razones = []
    cambios = [i for i, paso in enumerate(pasos) if paso.tool in EDITS]
    primero = cambios[0] if cambios else len(pasos)
    lectura_poteto = _lectura(poteto)
    if lectura_poteto is None or lectura_poteto >= primero:
        razones.append(f"falta la lectura de {poteto} antes del primer cambio")
    lectura_libro = _lectura(libro)
    if lectura_libro is None or lectura_libro >= primero:
        razones.append(f"falta la lectura de {libro} antes del primer cambio")
    listas = [paso for paso in pasos if paso.tool == "todowrite"]
    # La primera frase del paso: un paso de playbook puede ser un párrafo; un elemento de lista no.
    paso_uno = re.split(r"(?<=\.)\s", primer_paso(texto_del_playbook), maxsplit=1)[0]
    if not listas:
        razones.append("no hay lista de pasos (todowrite)")
    elif prefijo == "contexto/":
        # K2 y K3 (corrida 5): la lista que cuenta es la primera tras leer el
        # playbook (la del protocolo, anterior a esa lectura, no es la del
        # playbook), y en ella el primer elemento del playbook tiene que ser el
        # paso 1; lo que no es del playbook puede ir antes.
        elegidas = [
            paso
            for i, paso in enumerate(pasos)
            if paso.tool == "todowrite" and (lectura_libro is None or i > lectura_libro)
        ]
        objetivo = _espacios(paso_uno).replace("`", "").rstrip(".")
        otros = {
            frase.rstrip(".")
            for numero, frase in _primeras_frases_numeradas(texto_del_playbook).items()
            if numero != 1
        }
        posicion = None
        if elegidas:
            elementos = [
                _espacios(elemento).replace("`", "")
                for elemento in elegidas[0].detail.split("\n")
                if elemento.strip()
            ]
            # Un elemento puede traer su propio salto de línea: el paso se busca
            # desde cada elemento en adelante, con los espacios ya colapsados.
            posicion = next(
                (
                    j
                    for j in range(len(elementos))
                    if objetivo in _espacios(" ".join(elementos[j:]))
                    and objetivo not in _espacios(" ".join(elementos[j + 1 :]))
                ),
                None,
            )
            if posicion is not None:
                # B5 de G5d: el orden también dentro del elemento donde empieza
                # el paso 1: lo que va antes de él en ese mismo elemento cuenta.
                desde = _espacios(" ".join(elementos[posicion:]))
                antes = " ".join([*elementos[:posicion], desde[: desde.index(objetivo)]])
                if any(otro in antes for otro in otros):
                    posicion = None
        if posicion is None:
            razones.append(
                f"la primera lista no empieza con el primer paso del playbook: {paso_uno!r}"
            )
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
        # B5b de G7-r6: en la forma claude alcanza con cualquier línea de la
        # salida (el resumen del corredor de pruebas suele quedar antes de la
        # cola que la llamada dedicó al result.json); en las otras formas, solo
        # las últimas CITADAS certifican generaciones ya publicadas.
        citables = salida if forma == "claude" else salida[-CITADAS:]
        if not any(linea in resultado for linea in citables):
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
        help="de dónde vienen los eventos: opencode (--format json), "
        "claude (stream-json) o la Mini nativa",
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
        lectores = {
            "opencode": pasos_opencode,
            "openclaw": pasos_openclaw,
            "claude": pasos_claude,
        }
        lector = lectores[args.forma]
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
        # B5a de G7-r6: los textos de la copia del paquete de la corrida, para que
        # la forma claude juzgue también la lectura por contenido. La skill es la
        # hermana del playbook (skills/poteto-mode/); si la corrida no la trae,
        # su trozo queda vacío y esa lectura vuelve a ser solo por ruta.
        textos_de_lectura = None
        if args.forma == "claude":
            textos_de_lectura = {POTETO: ""}
            if resuelta.parents[1].name == "poteto-mode":
                try:
                    textos_de_lectura[POTETO] = (resuelta.parents[1] / "SKILL.md").read_text(
                        encoding="utf-8"
                    )
                except OSError:
                    pass
            textos_de_lectura[ruta.removeprefix(raiz + "/")] = texto
        veredicto = juzgar(
            pasos,
            playbook=ruta,
            texto_del_playbook=texto,
            resultado=resultado,
            prefijo=PREFIJO_DE_FORMA[args.forma],
            forma=args.forma,
            textos_de_lectura=textos_de_lectura,
        )
    except (OSError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": veredicto.ok, "razones": list(veredicto.razones)}, ensure_ascii=False))
    return 0 if veredicto.ok else 1


if __name__ == "__main__":
    sys.exit(main())

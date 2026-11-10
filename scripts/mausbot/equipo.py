#!/usr/bin/env python3
"""Arma el equipo de OpenMausBot con las skills de los perfiles de Hermes y el paquete comun.

    equipo.py generar --export <archivo> --perfiles <carpeta> --salida <carpeta>
        --poteto-fuente <carpeta>
    equipo.py aplicar --equipo <archivo> [--aplicar]

`generar` lee el export de OpenMausBot, copia a la salida el `SKILL.md` de cada skill que sirve
en esta PC y escribe `equipo.json`. La salida y su respaldo heredan los permisos de su carpeta
padre. `aplicar` corre `team apply --dry-run` por tubería, muestra lo que contesta la app y se
detiene con error si no hay una línea `Plan:`; solo aplica con `--aplicar`.
Nunca usa `--prune` ni `--rotate-secrets`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "scripts" / "agent-work"))
import contexto  # noqa: E402
from sistema_agentes.derivar import SECRET_RE  # noqa: E402

MOTOR = ROOT / "agents/ingenieria/agent/workshop-skills/motor/SKILL.md"
DIRECTORES_CON_MOTOR = {"mausbot", "ingenieria"}
PLATAFORMAS_MAC = {"macos", "darwin", "osx"}
NOMBRE_SKILL = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
INDICADOR_BLOQUE = re.compile(r"^[|>](?:[1-9][+-]?|[+-][1-9]?)?$")
BLOQUES_SOPORTADOS = frozenset({"|", "|-", "|+"})
SKILL_MAX_BYTES = 262_144
DESCRIPCION_MAX = 1024
TOPE_APLICACION = 300
HERMES_NOMBRES = {
    "hermes-agent",
    "hermes-agent-skill-authoring",
    "hermes-cron-ops",
    "hermes-dashboard-remote",
    "inspecting-hermes-desktop-dom",
    "poteto-hermes",
}
ADAPTACIONES_AJENAS = {"poteto-openclaw"}
HERMES_CLI = re.compile(
    r"(?im)(?:^|[`$>])\s*hermes(?:\.exe)?\s+"
    r"(?:cron|config|gateway|profile|skill|agent|tool|sessions|run|auth|models|providers"
    r"|plugins|memory|doctor|update)\b"
)
HERMES_SKILL_ASSETS = re.compile(
    r"(?i)(?:\.hermes|HERMES_HOME)[^\n]{0,24}?[/\\]skills[/\\]"
)
HERMES_CRONJOB = re.compile(r"(?im)(?:`cronjob`|\bcronjob\s*\()")
DEFAULT_OPENMAUSBOT = Path(
    r"C:\Users\ehven\AppData\Local\Programs\openmausbot\OpenMausBot.exe"
)
DEFAULT_CLI = Path(
    r"C:\Users\ehven\AppData\Local\Programs\openmausbot\resources\server\openmausbot.js"
)
BLOQUE_MOTOR = (
    "\n\n## En la PC de MausBot\n\n"
    "- Corre el motor con "
    "`C:\\Users\\ehven\\motor-runtime\\cpython-3.11.16-windows-x86_64-none\\python.exe`.\n"
    "- Pon `PYTHONPATH=C:\\Users\\ehven\\motor-sucesor` y `PYTHONIOENCODING=utf-8`.\n"
    "- No corras desde `C:\\Users\\ehven\\`. La carpeta vieja `motor\\` tapa el paquete y "
    "da `No module named motor.encargos`.\n"
    "- El director de esta PC es `mausbot`. Usa `--director mausbot` en cada encargo y "
    "consulta.\n\n"
    "```powershell\n"
    "$env:PYTHONPATH = 'C:\\Users\\ehven\\motor-sucesor'\n"
    "$env:PYTHONIOENCODING = 'utf-8'\n"
    "C:\\Users\\ehven\\motor-runtime\\cpython-3.11.16-windows-x86_64-none\\python.exe "
    "-B -m motor director encargar --via durable --director mausbot "
    "--canal <canal> --clave <clave> --sesion <sesion> --base <base> --texto \"<pedido>\"\n"
    "```\n"
)


class SecretoEncontrado(ValueError):
    """Una skill o el archivo de equipo llevan algo con forma de llave o token."""


@dataclass(frozen=True)
class Skill:
    nombre: str
    texto: str
    origen: str


@dataclass(frozen=True)
class Exclusion:
    bot: str
    skill: str
    motivo: str


@dataclass(frozen=True)
class Resultado:
    ruta: Path
    bots: int
    skills: int
    excluidas: list[Exclusion]


def _indent(linea: str) -> int:
    return len(linea) - len(linea.lstrip(" "))


def _unquote(valor: str) -> str:
    valor = valor.strip()
    if len(valor) >= 2 and valor[0] == valor[-1] == '"':
        try:
            return json.loads(valor)
        except json.JSONDecodeError:
            return valor[1:-1]
    if len(valor) >= 2 and valor[0] == valor[-1] == "'":
        return valor[1:-1].replace("''", "'")
    return valor


def _escalar(valor: str):
    texto = valor.strip()
    if texto in ("null", "~"):
        return None
    if texto.lower() == "true":
        return True
    if texto.lower() == "false":
        return False
    return _unquote(texto)


def _partir_inline(texto: str) -> list[str]:
    partes: list[str] = []
    actual: list[str] = []
    comillas: str | None = None
    profundidad = 0
    for caracter in texto:
        if comillas:
            actual.append(caracter)
            if caracter == comillas:
                comillas = None
        elif caracter in ("'", '"'):
            comillas = caracter
            actual.append(caracter)
        elif caracter in "[{":
            profundidad += 1
            actual.append(caracter)
        elif caracter in "]}":
            profundidad -= 1
            actual.append(caracter)
        elif caracter == "," and profundidad == 0:
            partes.append("".join(actual).strip())
            actual = []
        else:
            actual.append(caracter)
    if actual:
        partes.append("".join(actual).strip())
    return partes


def _es_indicador_bloque(texto: str) -> bool:
    return bool(INDICADOR_BLOQUE.fullmatch(texto))


def _yaml_valor(valor: str):
    texto = valor.strip()
    if _es_indicador_bloque(texto):
        raise ValueError(
            f"el export usa el escalar de bloque {texto!r}; este lector no lo conserva"
        )
    if texto.startswith("[") and texto.endswith("]"):
        return [_yaml_valor(parte) for parte in _partir_inline(texto[1:-1])]
    if texto.startswith("{") and texto.endswith("}"):
        mapa = {}
        for parte in _partir_inline(texto[1:-1]):
            clave, separador, contenido = parte.partition(":")
            if separador:
                mapa[clave.strip()] = _yaml_valor(contenido)
        return mapa
    return _escalar(texto)


def _plataformas(valor: str) -> list[str]:
    texto = valor.strip()
    if texto.startswith("[") and texto.endswith("]"):
        texto = texto[1:-1]
    return [_unquote(parte) for parte in texto.split(",") if parte.strip()]


def _leer_frontmatter(texto: str) -> tuple[dict, str | None]:
    if texto.startswith("\ufeff"):
        texto = texto[1:]
    match = re.match(r"^---\r?\n([\s\S]*?)\r?\n---\r?\n?", texto)
    if not match:
        return {}, "sin cabecera SKILL.md"
    campos: dict = {}
    pendiente: str | None = None
    for linea in match.group(1).splitlines():
        if not linea.strip() or linea.lstrip().startswith("#"):
            continue
        if pendiente and linea.lstrip().startswith("- "):
            campos.setdefault(pendiente, []).append(_escalar(linea.lstrip()[2:]))
            continue
        partes = re.match(r"^([A-Za-z][\w-]*):\s*(.*)$", linea)
        if not partes:
            continue
        clave = partes.group(1).lower()
        valor = partes.group(2)
        if clave in ("platforms", "platform", "os") and not valor.strip():
            campos[clave] = []
            pendiente = clave
            continue
        pendiente = None
        campos[clave] = valor
    plataformas: list[str] = []
    for clave in ("platforms", "platform", "os"):
        valor = campos.get(clave)
        if isinstance(valor, list):
            plataformas += [str(parte) for parte in valor]
        elif isinstance(valor, str) and valor.strip():
            plataformas += _plataformas(valor)
    if plataformas:
        campos["platforms"] = plataformas
    for clave in ("name", "description"):
        if isinstance(campos.get(clave), str):
            campos[clave] = _unquote(campos[clave])
    return campos, None


def _validar_skill(nombre: str, descripcion: str, texto: str) -> str | None:
    if not NOMBRE_SKILL.fullmatch(nombre or ""):
        return "nombre de skill inválido para MausBot"
    if not descripcion or len(descripcion) > DESCRIPCION_MAX:
        return "descripción vacía o de más de 1024 caracteres"
    if len(texto.encode("utf-8")) > SKILL_MAX_BYTES:
        return "SKILL.md de más de 256 KiB"
    return None


def _motivo_exclusion(partes: tuple[str, ...], meta: dict, texto: str) -> str | None:
    if any(parte.startswith(".") for parte in partes):
        return "carpeta interna de Hermes"
    if partes and partes[0].lower() == "apple":
        return "depende de apps de macOS/Apple"
    nombre = str(meta.get("name", ""))
    if nombre.lower() in HERMES_NOMBRES or any("hermes" in parte.lower() for parte in partes):
        return "depende de herramientas internas de Hermes"
    plataformas = {str(parte).lower() for parte in meta.get("platforms", [])}
    if plataformas and plataformas <= PLATAFORMAS_MAC:
        return "solo corre en macOS (platforms: " + ", ".join(sorted(plataformas)) + ")"
    if HERMES_SKILL_ASSETS.search(texto):
        return "depende de archivos internos de Hermes"
    if HERMES_CRONJOB.search(texto):
        return "depende del planificador de Hermes"
    if len(HERMES_CLI.findall(texto)) >= 2:
        return "depende del CLI interno de Hermes"
    if nombre in ADAPTACIONES_AJENAS:
        return "adaptación de otro runtime; la reemplaza poteto-mausbot"
    if nombre == "motor":
        return "la skill motor se genera desde el repo para esta PC"
    if nombre == contexto.POTETO or nombre.startswith(contexto.PRINCIPIO):
        return "la aporta el paquete común"
    return None


def _yaml_bloque(
    lineas: list[str], indice: int, padre: int, marca: str
) -> tuple[str, int]:
    contenido: list[str] = []
    sangria: int | None = None
    while indice < len(lineas):
        linea = lineas[indice]
        if not linea.strip():
            contenido.append("")
            indice += 1
            continue
        actual = _indent(linea)
        if actual <= padre:
            break
        if sangria is None:
            sangria = actual
        contenido.append(linea[sangria:] if actual >= sangria else linea.lstrip())
        indice += 1
    texto = "\n".join(contenido).rstrip("\n")
    if marca in ("|", "|+"):
        texto += "\n"
    return texto, indice


def _es_entrada_mapa(linea: str) -> bool:
    texto = linea.strip()
    clave, separador, resto = texto.partition(":")
    if not separador or not clave.strip():
        return False
    return resto == "" or resto[0] in " \t"


def _sangria_siguiente(lineas: list[str], indice: int) -> int | None:
    while indice < len(lineas):
        linea = lineas[indice]
        if linea.strip() and not linea.lstrip().startswith("#"):
            return _indent(linea)
        indice += 1
    return None


def _rechazar_continuacion(
    lineas: list[str], indice: int, indentacion: int, valor: str
) -> None:
    texto = valor.strip()
    if texto[:1] in ("'", '"') and not (len(texto) >= 2 and texto.endswith(texto[0])):
        raise ValueError(
            "el export trae un escalar entre comillas sin cerrar; este lector no lo conserva"
        )
    siguiente = indice + 1
    while siguiente < len(lineas) and not lineas[siguiente].strip():
        siguiente += 1
    if siguiente >= len(lineas):
        return
    linea = lineas[siguiente]
    if _indent(linea) > indentacion and not linea.lstrip().startswith("#"):
        raise ValueError(
            "el export trae un escalar de varias líneas; este lector no lo conserva"
        )


def _yaml_campo(
    lineas: list[str], indice: int, indentacion: int, valor: str
) -> tuple[object, int]:
    marca = valor.strip()
    if marca in BLOQUES_SOPORTADOS:
        return _yaml_bloque(lineas, indice + 1, indentacion, marca)
    if _es_indicador_bloque(marca):
        raise ValueError(
            f"el export usa el escalar de bloque {marca!r}; este lector no lo conserva"
        )
    if not marca:
        siguiente = indice + 1
        while siguiente < len(lineas) and (
            not lineas[siguiente].strip()
            or lineas[siguiente].lstrip().startswith("#")
        ):
            siguiente += 1
        if siguiente < len(lineas) and _indent(lineas[siguiente]) > indentacion:
            sangria = _indent(lineas[siguiente])
            if lineas[siguiente].lstrip().startswith("-"):
                return _yaml_lista(lineas, siguiente, sangria)
            if _es_entrada_mapa(lineas[siguiente]):
                return _yaml_mapa(lineas, siguiente, sangria)
            raise ValueError(
                "el export trae un escalar de varias líneas en la línea siguiente; "
                "este lector no lo conserva"
            )
    _rechazar_continuacion(lineas, indice, indentacion, valor)
    return _yaml_valor(valor), indice + 1


def _yaml_mapa(lineas: list[str], indice: int, indentacion: int) -> tuple[dict, int]:
    mapa: dict = {}
    while indice < len(lineas):
        linea = lineas[indice]
        if not linea.strip() or linea.lstrip().startswith("#"):
            indice += 1
            continue
        actual = _indent(linea)
        if actual < indentacion:
            break
        if actual > indentacion:
            raise ValueError(
                "el export trae una línea más sangrada de lo esperado dentro de un mapa; "
                "este lector no la conserva"
            )
        clave, separador, valor = linea.strip().partition(":")
        if not separador or not clave.strip():
            raise ValueError(
                "el export trae una línea que no es 'clave: valor' dentro de un mapa; "
                "este lector no la conserva"
            )
        valor, indice = _yaml_campo(lineas, indice, actual, valor)
        mapa[clave.strip()] = valor
    return mapa, indice


def _yaml_lista(lineas: list[str], indice: int, indentacion: int) -> tuple[list, int]:
    items: list = []
    while indice < len(lineas):
        linea = lineas[indice]
        if not linea.strip() or linea.lstrip().startswith("#"):
            indice += 1
            continue
        actual = _indent(linea)
        if actual < indentacion:
            break
        if actual != indentacion:
            raise ValueError(
                "el export trae una línea más sangrada de lo esperado dentro de una lista; "
                "este lector no la conserva"
            )
        if not linea.lstrip().startswith("-"):
            raise ValueError(
                "el export trae una lista con una línea que no empieza por '-'; "
                "este lector no la conserva"
            )
        resto = linea.lstrip()[1:].strip()
        item: dict = {}
        if resto:
            clave, separador, valor = resto.partition(":")
            if separador:
                despues_guion = linea[actual + 1 :]
                columnas = len(despues_guion) - len(despues_guion.lstrip())
                valor, indice = _yaml_campo(
                    lineas, indice, actual + 1 + columnas, valor
                )
                item[clave.strip()] = valor
            else:
                items.append(_yaml_valor(resto))
                indice += 1
                continue
        else:
            indice += 1
        while indice < len(lineas):
            linea2 = lineas[indice]
            if linea2.lstrip().startswith("#"):
                indice += 1
                continue
            if not linea2.strip():
                siguiente = indice
                while siguiente < len(lineas) and not lineas[siguiente].strip():
                    siguiente += 1
                if siguiente < len(lineas) and _indent(lineas[siguiente]) > actual:
                    indice += 1
                    continue
                break
            if _indent(linea2) <= actual:
                break
            clave, separador, valor = linea2.strip().partition(":")
            if not separador or not clave.strip():
                raise ValueError(
                    "el export trae una línea que no es 'clave: valor' dentro de un item; "
                    "este lector no la conserva"
                )
            valor, indice = _yaml_campo(lineas, indice, _indent(linea2), valor)
            item[clave.strip()] = valor
        items.append(item)
    return items, indice


def _yaml_equipo(texto: str) -> dict:
    lineas = texto.splitlines()
    documento: dict = {}
    indice = 0
    while indice < len(lineas):
        linea = lineas[indice]
        if not linea.strip() or linea.lstrip().startswith("#"):
            indice += 1
            continue
        if _indent(linea) != 0:
            indice += 1
            continue
        clave, separador, valor = linea.partition(":")
        if not separador:
            indice += 1
            continue
        clave = clave.strip()
        if clave == "version":
            documento["version"] = int(valor.strip())
            indice += 1
        elif clave in ("teams", "bots", "rooms"):
            sangria = _sangria_siguiente(lineas, indice + 1)
            if sangria is None or sangria == 0:
                documento[clave] = []
                indice += 1
            else:
                items, indice = _yaml_lista(lineas, indice + 1, sangria)
                documento[clave] = items
        else:
            indice += 1
    return documento


def leer_export(ruta: Path) -> dict:
    texto = Path(ruta).read_text(encoding="utf-8-sig")
    if Path(ruta).suffix.lower() == ".json":
        return json.loads(texto)
    return _yaml_equipo(texto)


def _perfiles(raiz: Path) -> dict[str, Path]:
    if not Path(raiz).is_dir():
        raise FileNotFoundError(f"no existe la carpeta de perfiles {raiz}")
    return {
        entrada.name.strip().lower(): entrada
        for entrada in sorted(Path(raiz).iterdir())
        if entrada.is_dir()
    }


def _skills_de_perfil(perfil: Path) -> list[tuple[tuple[str, ...], Path]]:
    raiz = perfil / "skills"
    if not raiz.is_dir():
        return []
    return [
        (archivo.relative_to(raiz).parts, archivo)
        for archivo in sorted(raiz.rglob("SKILL.md"))
    ]


def _skills_del_export(export: Path, nombre: str) -> list[tuple[tuple[str, ...], Path]]:
    raiz = Path(export).parent / "skills" / _slug(nombre)
    if not raiz.is_dir():
        return []
    return [
        (archivo.relative_to(raiz).parts, archivo)
        for archivo in sorted(raiz.rglob("SKILL.md"))
    ]


def cargar_comun(fuente: Path, manifiesto_path: Path) -> list[Skill]:
    manifiesto = json.loads(Path(manifiesto_path).read_text(encoding="utf-8"))
    if Path(manifiesto_path).resolve() == contexto.MANIFIESTO.resolve():
        contexto.comprobar_generacion(manifiesto, contexto.leer_json(contexto.GENERACIONES))
    elif manifiesto.get("digest") != contexto.digest_de(manifiesto):
        raise contexto.ContextoIncompleto("el manifiesto no coincide con su digest")
    esperado = {archivo["path"]: archivo["sha256"] for archivo in manifiesto["files"]}
    skills: list[Skill] = []
    for ruta in sorted(esperado):
        if not contexto.del_paquete(ruta, ()):
            continue
        origen = Path(fuente) / ruta
        try:
            datos = origen.read_bytes()
        except OSError as error:
            raise contexto.ContextoIncompleto(f"{ruta}: {error.strerror}") from error
        if contexto.sha256(datos) != esperado[ruta]:
            raise contexto.ContextoIncompleto(f"{ruta} no coincide con el manifiesto")
        if not ruta.endswith("/SKILL.md"):
            continue
        texto = datos.decode("utf-8")
        meta, error = _leer_frontmatter(texto)
        nombre = str(meta.get("name", ""))
        problema = _validar_skill(nombre, str(meta.get("description", "")), texto)
        if error or problema:
            raise contexto.ContextoIncompleto(f"{ruta}: {error or problema}")
        skills.append(Skill(nombre=nombre, texto=texto, origen=ruta))
    adaptacion = contexto.ADAPTACIONES["mausbot"]
    datos = adaptacion.read_bytes()
    if contexto.sha256(datos) != manifiesto.get("adaptations", {}).get("mausbot"):
        raise contexto.ContextoIncompleto("la adaptación mausbot no coincide con el manifiesto")
    texto = datos.decode("utf-8")
    meta, error = _leer_frontmatter(texto)
    nombre = str(meta.get("name", ""))
    problema = _validar_skill(nombre, str(meta.get("description", "")), texto)
    if error or problema:
        raise contexto.ContextoIncompleto(f"{adaptacion.name}: {error or problema}")
    skills.append(Skill(nombre=nombre, texto=texto, origen=adaptacion.name))
    for obligatoria in (contexto.POTETO, "poteto-mausbot"):
        if not any(skill.nombre == obligatoria for skill in skills):
            raise contexto.ContextoIncompleto(f"el paquete común no trae {obligatoria}")
    if not any(skill.nombre.startswith(contexto.PRINCIPIO) for skill in skills):
        raise contexto.ContextoIncompleto("el paquete común no trae ningún principle-*")
    return skills


def skill_motor(repo: Path) -> Skill:
    ruta = Path(repo) / MOTOR.relative_to(ROOT)
    texto = ruta.read_text(encoding="utf-8")
    meta, error = _leer_frontmatter(texto)
    if error or meta.get("name") != "motor":
        raise ValueError(f"{ruta}: la skill motor no tiene una cabecera válida")
    texto = texto.replace("--director claw", "--director mausbot")
    texto = texto.replace(
        "`claw`, `hermes` y `openbot` son los directores válidos.",
        "`claw`, `hermes`, `openbot` y `mausbot` son los directores válidos. "
        "En esta PC el director es `mausbot`.",
    )
    return Skill(
        nombre="motor",
        texto=texto.rstrip() + "\n" + BLOQUE_MOTOR,
        origen=str(ruta.relative_to(Path(repo))),
    )


def _slug(texto: str) -> str:
    valor = re.sub(r"[^a-z0-9]+", "-", texto.lower()).strip("-")[:40].strip("-")
    return valor or "bot"


def _segmento(texto: str) -> str:
    valor = re.sub(r"[^a-zA-Z0-9._-]+", "-", texto).strip("-")
    return valor or "skill"


def _es_token(match: re.Match) -> bool:
    """El patrón del repo también pilla palabras como `sk-tracking` en prosa. Un token real
    trae dígitos o mayúsculas, o es largo y sin guiones."""
    texto = match.group(0)
    if texto.startswith(("gh", "github_pat_", "AKIA")):
        return True
    sufijo = texto[3:]
    if any(caracter.isdigit() or caracter.isupper() for caracter in sufijo):
        return True
    return len(sufijo) >= 20 and "-" not in sufijo


def comprobar_secretos(textos: list[tuple[str, str]]) -> None:
    for donde, texto in textos:
        if any(_es_token(match) for match in SECRET_RE.finditer(texto)):
            raise SecretoEncontrado(f"{donde}: posible secreto")


def _heredar_permisos(carpeta: Path, recursivo: bool = False) -> None:
    """mkdtemp crea 0o700: en POSIX quedan 0700 sin respetar el umask y en Windows
    os.mkdir convierte ese modo en una ACL protegida de SYSTEM, Administrators y OWNER
    RIGHTS que el rename conserva, así que MausBot sin elevar no pudo leer la salida.
    Aquí la carpeta vuelve a quedar como el padre: umask en POSIX y herencia con
    icacls /reset en Windows. En el respaldo va /T porque sus hijos arrastran el ACL
    protegido de la corrida anterior."""
    if os.name == "nt":
        argumentos = ["icacls", str(carpeta), "/reset"]
        if recursivo:
            argumentos.append("/T")
        resultado = subprocess.run(argumentos, check=False, capture_output=True)
        if resultado.returncode != 0:
            raise OSError(
                f"icacls {' '.join(argumentos[1:])} falló para {carpeta}: "
                f"{resultado.stderr.decode('utf-8', 'replace').strip() or resultado.returncode}"
            )
    else:
        umask = os.umask(0o022)
        os.umask(umask)
        os.chmod(carpeta, 0o777 & ~umask)


def _escribir(salida: Path, documento: dict, archivos: dict[str, str], forzar: bool) -> None:
    salida = Path(salida)
    respaldo: Path | None = None
    if salida.exists():
        if not forzar:
            raise FileExistsError(f"{salida} ya existe; usa --force para reemplazarla")
        if not salida.is_dir():
            raise FileExistsError(f"{salida} no es una carpeta")
        respaldo = Path(tempfile.mkdtemp(prefix=".mausbot-viejo-", dir=str(salida.parent)))
        os.rmdir(respaldo)
        os.rename(salida, respaldo)
    salida.parent.mkdir(parents=True, exist_ok=True)
    temporal = Path(tempfile.mkdtemp(prefix=".mausbot-", dir=str(salida.parent)))
    try:
        if respaldo is not None:
            _heredar_permisos(respaldo, recursivo=True)
        _heredar_permisos(temporal)
        for relativa, texto in archivos.items():
            destino = temporal / relativa
            destino.parent.mkdir(parents=True, exist_ok=True)
            destino.write_text(texto, encoding="utf-8", newline="\n")
        (temporal / "equipo.json").write_text(
            json.dumps(documento, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        os.rename(temporal, salida)
    except BaseException:
        shutil.rmtree(temporal, ignore_errors=True)
        if respaldo is not None and not salida.exists():
            os.rename(respaldo, salida)
        raise
    if respaldo is not None:
        shutil.rmtree(respaldo, ignore_errors=True)


def generar(
    export: Path,
    perfiles: Path,
    salida: Path,
    poteto_fuente: Path,
    *,
    manifiesto: Path = contexto.MANIFIESTO,
    repo: Path = ROOT,
    forzar: bool = False,
) -> Resultado:
    documento_export = leer_export(export)
    bots = documento_export.get("bots") or []
    if not bots:
        raise ValueError("el export no trae bots")
    for bot in bots:
        if isinstance(bot.get("soul"), (dict, list)):
            nombre = bot.get("name", "?")
            raise ValueError(
                f"el export trae el campo soul de {nombre} como mapa o lista; "
                "soul debe ser texto"
            )
    comun = cargar_comun(Path(poteto_fuente), Path(manifiesto))
    motor = skill_motor(Path(repo))
    perfiles_por_nombre = _perfiles(Path(perfiles))
    archivos: dict[str, str] = {}
    exclusas: list[Exclusion] = []
    deseados: list[dict] = []
    slugs: set[str] = set()
    for bot in bots:
        nombre = str(bot.get("name", "")).strip()
        if not nombre:
            raise ValueError("el export trae un bot sin nombre")
        slug = _slug(nombre)
        if slug in slugs:
            raise ValueError(f"dos bots comparten la carpeta {slug}")
        slugs.add(slug)
        seleccion = {skill.nombre: skill for skill in comun}
        seleccion["motor"] = motor
        perfil = perfiles_por_nombre.get(nombre.lower())
        fuentes = _skills_de_perfil(perfil) if perfil else _skills_del_export(export, nombre)
        for partes, archivo in fuentes:
            texto = archivo.read_text(encoding="utf-8-sig")
            meta, _ = _leer_frontmatter(texto)
            nombre_skill = str(meta.get("name", ""))
            motivo = _motivo_exclusion(partes, meta, texto)
            if motivo:
                exclusas.append(Exclusion(nombre, nombre_skill or "/".join(partes), motivo))
                continue
            problema = _validar_skill(
                nombre_skill, str(meta.get("description", "")), texto
            )
            if problema:
                exclusas.append(Exclusion(nombre, nombre_skill or "/".join(partes), problema))
                continue
            if nombre_skill in seleccion:
                exclusas.append(
                    Exclusion(
                        nombre,
                        nombre_skill,
                        f"duplicada, ya viene de {seleccion[nombre_skill].origen}",
                    )
                )
                continue
            base = perfil if perfil else Path(export).parent
            seleccion[nombre_skill] = Skill(
                nombre=nombre_skill,
                texto=texto,
                origen=archivo.relative_to(base).as_posix(),
            )
        con_motor = nombre.lower() in DIRECTORES_CON_MOTOR
        entradas = []
        for nombre_skill in sorted(seleccion):
            skill = seleccion[nombre_skill]
            relativa = f"skills/{slug}/{_segmento(skill.nombre)}/SKILL.md"
            archivos[relativa] = skill.texto
            entrada = {"file": relativa}
            if skill.nombre == "motor" and not con_motor:
                entrada["enabled"] = False
            entradas.append(entrada)
        deseado: dict = {}
        for clave in (
            "name",
            "team",
            "title",
            "description",
            "soul",
            "model",
            "effort",
            "approval",
            "chief",
            "manages",
            "cwd",
            "browser",
            "tools",
            "was",
        ):
            if clave in bot:
                deseado[clave] = bot[clave]
        deseado["computer"] = "local"
        for clave, valor in bot.items():
            if clave not in deseado and clave != "skills":
                deseado[clave] = valor
        deseado["skills"] = entradas
        deseados.append(deseado)
    equipos = []
    for equipo in documento_export.get("teams") or []:
        if isinstance(equipo, str):
            equipos.append({"name": equipo})
        elif isinstance(equipo, dict) and equipo.get("name"):
            equipos.append({clave: valor for clave, valor in equipo.items() if clave != "prune"})
    documento = {"version": 1, "teams": equipos, "bots": deseados}
    if "rooms" in documento_export:
        documento["rooms"] = documento_export["rooms"]
    comprobar_secretos(list(archivos.items()))
    comprobar_secretos(
        [("equipo.json", json.dumps(documento, ensure_ascii=False))]
    )
    _escribir(Path(salida), documento, archivos, forzar)
    return Resultado(
        ruta=Path(salida) / "equipo.json",
        bots=len(deseados),
        skills=len(archivos),
        excluidas=exclusas,
    )


def aplicar(
    equipo: Path,
    *,
    aplicar_ahora: bool = False,
    openmausbot: Path = DEFAULT_OPENMAUSBOT,
    cli: Path = DEFAULT_CLI,
    ejecutar=subprocess.run,
    tope: float = TOPE_APLICACION,
) -> int:
    equipo = Path(equipo)
    texto = equipo.read_text(encoding="utf-8")
    comprobar_secretos([(str(equipo), texto)])
    documento = json.loads(texto)
    for bot in documento.get("bots") or []:
        for skill in bot.get("skills") or []:
            ruta = (equipo.parent / skill["file"]).resolve()
            if not ruta.is_file():
                raise FileNotFoundError(f"{ruta}: la skill del equipo no existe")
            comprobar_secretos([(str(ruta), ruta.read_text(encoding="utf-8"))])
    comando_base = [str(openmausbot), str(cli), "team", "apply", str(equipo)]
    for prohibido in ("--prune", "--rotate-secrets"):
        if any(prohibido in argumento for argumento in comando_base):
            raise ValueError(f"{prohibido} no se usa en este paso")
    entorno = os.environ.copy()
    entorno["ELECTRON_RUN_AS_NODE"] = "1"

    def correr(extra: list[str]) -> int:
        comando = [*comando_base, *extra]
        print("$ " + " ".join(comando), flush=True)
        try:
            resultado = ejecutar(
                comando,
                env=entorno,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=tope,
            )
        except subprocess.TimeoutExpired as vencido:
            for caudal, vuelco in (
                (sys.stdout, vencido.stdout),
                (sys.stderr, vencido.stderr),
            ):
                if not vuelco:
                    continue
                if isinstance(vuelco, bytes):
                    vuelco = vuelco.decode("utf-8", errors="replace")
                print(vuelco, end="", file=caudal, flush=True)
            print(
                f"error: la app no terminó en {tope:g} s; no se sigue",
                file=sys.stderr,
                flush=True,
            )
            return 5
        if resultado.stdout:
            print(resultado.stdout, end="", flush=True)
        if resultado.stderr:
            print(resultado.stderr, end="", file=sys.stderr, flush=True)
        if resultado.returncode != 0:
            return resultado.returncode
        planificado = any(
            linea.strip().startswith("Plan:")
            for linea in ((resultado.stdout or "") + "\n" + (resultado.stderr or "")).splitlines()
        )
        if not planificado:
            print(
                "error: la app no trae una línea 'Plan:'; el plan no se puede leer, no se sigue",
                file=sys.stderr,
                flush=True,
            )
            return 4
        return 0

    plan = correr(["--dry-run"])
    if plan != 0 or not aplicar_ahora:
        return plan
    return correr([])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    pasos = parser.add_subparsers(dest="paso", required=True)
    generar_parser = pasos.add_parser("generar", help="arma el archivo de equipo y sus skills")
    generar_parser.add_argument("--export", type=Path, required=True)
    generar_parser.add_argument("--perfiles", type=Path, required=True)
    generar_parser.add_argument("--salida", type=Path, required=True)
    generar_parser.add_argument("--poteto-fuente", type=Path, required=True)
    generar_parser.add_argument("--manifiesto", type=Path, default=contexto.MANIFIESTO)
    generar_parser.add_argument("--repo", type=Path, default=ROOT)
    generar_parser.add_argument("--force", action="store_true")
    aplicar_parser = pasos.add_parser("aplicar", help="muestra el plan y aplica con --aplicar")
    aplicar_parser.add_argument("--equipo", type=Path, required=True)
    aplicar_parser.add_argument("--aplicar", action="store_true")
    aplicar_parser.add_argument("--openmausbot", type=Path, default=DEFAULT_OPENMAUSBOT)
    aplicar_parser.add_argument("--cli", type=Path, default=DEFAULT_CLI)
    args = parser.parse_args(argv)
    try:
        if args.paso == "generar":
            resultado = generar(
                args.export,
                args.perfiles,
                args.salida,
                args.poteto_fuente,
                manifiesto=args.manifiesto,
                repo=args.repo,
                forzar=args.force,
            )
            for exclusion in resultado.excluidas:
                print(
                    f"excluida {exclusion.bot}/{exclusion.skill}: {exclusion.motivo}",
                    file=sys.stderr,
                )
            print(
                json.dumps(
                    {
                        "ok": True,
                        "equipo": str(resultado.ruta),
                        "bots": resultado.bots,
                        "skills": resultado.skills,
                        "excluidas": len(resultado.excluidas),
                    },
                    ensure_ascii=False,
                )
            )
            return 0
        return aplicar(
            args.equipo,
            aplicar_ahora=args.aplicar,
            openmausbot=args.openmausbot,
            cli=args.cli,
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3


if __name__ == "__main__":
    sys.exit(main())

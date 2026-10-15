#!/usr/bin/env python3
"""El publicador nativo del paquete de SUA-03 (diseño, 4.1 "Publicador nativo" y 4.3).

Dos mitades en un archivo. Desde la Mac arma una publicación con el manifiesto del checkout,
el conjunto nativo (`poteto-mode` sin `scripts/`, las `principle-*` y `poteto-openclaw`), el
bloque de cada agente y este mismo script, la copia por scp a la Mini y corre la otra mitad
por ssh. Con `--local` corre en la Mini (o en un árbol de prueba): publica el bloque marcado
de cada `AGENTS.md` y las skills administradas en `~/.openclaw/skills`, con lectura
(`--leer`), aplicación (`--aplicar`) y reversa (`--revertir`) bajo CAS. Nunca escribe
`MEMORY.md`, `memory/`, `USER.md`, `SOUL.md`, `IDENTITY.md`, `DREAMS.md` ni el workshop de
ningún agente (4.3, "Sin pisar memoria ni archivos de David").

Quien edita a mano no toma el candado: entre la relectura del CAS y el rename de un archivo
queda una ventana en la que una edición manual se perdería; el candado solo serializa a los
publicadores.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

MARCA_INICIO = b"sua-contexto inicio"
MARCA_FIN = b"sua-contexto fin"
ESTADO_SCHEMA = "sua-contexto.v1"


class Rechazo(ValueError):
    """Un rechazo de la mitad Mini: salida 3 con una línea JSON de error."""


class BloqueRoto(ValueError):
    """El `AGENTS.md` trae una marca del bloque pero no las dos (4.3 CAS): media marca es una
    edición del bloque, no su ausencia."""


class ListaInvalida(Exception):
    """La lista de agentes de la Mini no llegó o no tiene la forma esperada."""


def _contexto():
    """`contexto.py` vive al lado de este script en el checkout de G; a la Mini viaja solo la
    mitad `--local` y el módulo no está. Por eso el import es aquí y no arriba: la mitad Mini
    no puede depender de él."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import contexto

    return contexto


# --- herramientas de la mitad Mini: sin importar contexto -----------------------------------------


def sha256hex(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


def canonico(documento: object) -> bytes:
    """La forma canónica de un documento, igual a `contexto.canonico` pero local: la mitad
    Mini corre sin `contexto.py` al lado."""
    return json.dumps(documento, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def leer_json(ruta: Path) -> dict:
    return json.loads(ruta.read_text(encoding="utf-8"))


def leer_bytes(ruta: Path) -> bytes:
    return ruta.read_bytes() if ruta.exists() else b""


def escribir_atomico(ruta: Path, datos: bytes) -> None:
    """Escritura con respaldo implícito del rename (4.3 Escritura): temporal en la misma
    carpeta y `os.replace`, para que un corte no deje el archivo a medias."""
    ruta.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporal = tempfile.mkstemp(dir=str(ruta.parent), prefix="." + ruta.name + ".")
    try:
        with os.fdopen(descriptor, "wb") as archivo:
            archivo.write(datos)
        os.replace(temporal, ruta)
    finally:
        if os.path.exists(temporal):
            os.unlink(temporal)


def digest_de_carpeta(destino: Path) -> str:
    """El digest de una carpeta, como `contexto.digest_del_paquete` pero sin importarlo: cada
    archivo regular en orden con su ruta relativa. Un symlink no se sigue."""
    entradas = [
        {"path": archivo.relative_to(destino).as_posix(), "sha256": sha256hex(archivo.read_bytes())}
        for archivo in sorted(destino.rglob("*"))
        if archivo.is_file() and not archivo.is_symlink()
    ]
    return "sha256:" + sha256hex(canonico(entradas))


def trecho_del_bloque(actual: bytes) -> tuple[int, int] | None:
    """El trecho [inicio, fin) que ocupa el bloque marcado en un `AGENTS.md`: la línea de
    inicio entera y el salto de la línea de fin. None si no hay marcas."""
    inicio = actual.find(MARCA_INICIO)
    fin = actual.find(MARCA_FIN)
    if inicio < 0 and fin < 0:
        return None
    if inicio < 0 or fin < 0 or fin < inicio:
        raise BloqueRoto()
    desde = actual.rfind(b"\n", 0, inicio) + 1
    salto = actual.find(b"\n", fin)
    hasta = salto + 1 if salto >= 0 else len(actual)
    return desde, hasta


def estado_vacio() -> dict:
    return {
        "schema": ESTADO_SCHEMA,
        "generacion": None,
        "digest": None,
        "bloques": {},
        "workspaces": {},
        "skills": {},
        "skills_anteriores": [],
    }


def linea(generacion: object, agentes: dict, skills: dict, conflictos: int) -> None:
    """La salida es siempre una línea JSON (diseño, 4.3): la lee el operador y la ventana."""
    print(
        json.dumps(
            {
                "ok": conflictos == 0,
                "generacion": generacion,
                "agentes": agentes,
                "skills": skills,
                "conflictos": conflictos,
            },
            ensure_ascii=False,
        )
    )


def listar_agentes(ruta_json: Path | None) -> list[dict]:
    """La lista de agentes sale de `openclaw agents list --json` en la Mini, no de una lista
    escrita en G (4.3 "Lista de agentes"); `--agentes-json` la reemplaza en pruebas."""
    if ruta_json is not None:
        agentes = leer_json(ruta_json)
    else:
        corrida = subprocess.run(
            [os.path.expanduser("~/.openclaw/bin/openclaw"), "agents", "list", "--json"],
            capture_output=True,
            text=True,
        )
        if corrida.returncode != 0:
            raise Rechazo(f"openclaw agents list falló: {corrida.stderr.strip()}")
        agentes = json.loads(corrida.stdout)
    if not isinstance(agentes, list) or not all(
        isinstance(agente, dict)
        and isinstance(agente.get("id"), str)
        and isinstance(agente.get("workspace"), str)
        for agente in agentes
    ):
        raise Rechazo("la lista de agentes no tiene la forma esperada")
    return agentes


def cargar_publicacion(
    publicacion: Path, agentes: list[dict]
) -> tuple[dict, dict, dict[str, bytes]]:
    """El manifiesto, los perfiles y el bloque de cada agente tal como viajaron."""
    try:
        manifiesto = leer_json(publicacion / "manifiesto.json")
        perfiles = leer_json(publicacion / "perfiles.v1.json")
        bloques = {
            agente["id"]: (publicacion / "bloques" / f"{agente['id']}.md").read_bytes()
            for agente in agentes
        }
    except (OSError, ValueError, KeyError) as error:
        raise Rechazo(f"la publicación de {publicacion} no es legible: {error}") from error
    return manifiesto, perfiles, bloques


def skills_administradas(manifiesto: dict, publicacion: Path) -> list[str]:
    """Las skills que esta publicación administra (4.3): las del manifiesto que la publicación
    trae. El manifiesto lista también las skills de los perfiles de la ruta CLI, que acá no se
    publican: el agente nativo conserva su workshop y solo recibe poteto y su adaptación."""
    nombres = {
        archivo["path"].split("/")[1]
        for archivo in manifiesto["files"]
        if archivo["path"].startswith("skills/")
    }
    return sorted(nombre for nombre in nombres if (publicacion / "skills" / nombre).is_dir())


def publicar_skill(origen: Path, destino: Path) -> None:
    """Copia la skill archivo por archivo con escritura atómica y quita del destino los
    archivos que la publicación ya no trae (4.3 Escritura)."""
    de_la_publicacion = {}
    for archivo in sorted(origen.rglob("*")):
        if archivo.is_file() and not archivo.is_symlink():
            de_la_publicacion[archivo.relative_to(origen).as_posix()] = archivo.read_bytes()
    destino.mkdir(parents=True, exist_ok=True)
    for ruta, datos in de_la_publicacion.items():
        escribir_atomico(destino / ruta, datos)
    for archivo in sorted(destino.rglob("*")):
        if archivo.is_file() and archivo.relative_to(destino).as_posix() not in de_la_publicacion:
            archivo.unlink()


def con_candado(suya: Path, operacion) -> int:
    """El candado serializa publicadores (4.3): se toma antes de releyer cualquier cosa y se
    suelta al final. Quien edita a mano no toma el candado, y esa ventana es declarada."""
    suya.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(str(suya / ".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:  # BlockingIOError (uno en curso) también es OSError
            print(
                json.dumps({"ok": False, "error": "otro publicador en curso"}, ensure_ascii=False)
            )
            return 3
        return operacion()
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


# --- mitad Mac -----------------------------------------------------------------------------------


def armar_publicacion(
    destino: Path,
    manifiesto: dict,
    perfiles: dict,
    agentes: list[dict],
    *,
    fuente: Path,
    script: Path,
) -> None:
    """Escribe la publicación que viaja a la Mini: manifiesto y perfiles canónicos, el conjunto
    nativo (4.3) verificado contra el manifiesto, el bloque de cada agente (4.2: con su perfil
    por omisión si tiene exactamente uno) y este mismo script, que es la mitad Mini. La skill
    `poteto-openclaw` no está en la fuente pstack: sus bytes son la adaptación `openclaw` de G,
    que el manifiesto lleva como un archivo más."""
    contexto = _contexto()
    destino.mkdir(parents=True, exist_ok=True)
    (destino / "manifiesto.json").write_bytes(contexto.canonico(manifiesto) + b"\n")
    (destino / "perfiles.v1.json").write_bytes(contexto.canonico(perfiles) + b"\n")
    esperado = {archivo["path"]: archivo["sha256"] for archivo in manifiesto["files"]}
    for ruta in contexto.archivos_nativos(manifiesto):
        origen = Path(fuente) / ruta
        if origen.exists() and not origen.is_symlink():
            # La fuente manda si trae la skill (4.2); `poteto-openclaw` no está en pstack: sus
            # bytes son la adaptación `openclaw` de G, que el manifiesto lleva como un archivo más.
            datos = origen.read_bytes()
        elif ruta == contexto.OPENCLAW_SKILL:
            datos = contexto.ADAPTACIONES["openclaw"].read_bytes()
        else:
            datos = b""
        if contexto.sha256(datos) != esperado[ruta]:
            raise ValueError(f"{ruta} no coincide con el manifiesto")
        copia = destino / ruta
        copia.parent.mkdir(parents=True, exist_ok=True)
        copia.write_bytes(datos)
    plantilla = (contexto.CONTEXTO / "bloque-agents.md").read_text(encoding="utf-8")
    (destino / "bloques").mkdir(parents=True, exist_ok=True)
    for agente in agentes:
        bloque = contexto.bloque(
            plantilla, manifiesto, contexto.perfil_por_omision(perfiles, agente["id"])
        )
        (destino / "bloques" / f"{agente['id']}.md").write_bytes(bloque.encode("utf-8"))
    shutil.copy2(script, destino / "publicar-contexto.py")


def agentes_por_ssh(mini: str) -> list[dict]:
    corrida = subprocess.run(
        ["ssh", mini, "~/.openclaw/bin/openclaw", "agents", "list", "--json"],
        capture_output=True,
        text=True,
    )
    try:
        agentes = json.loads(corrida.stdout) if corrida.returncode == 0 else None
    except ValueError:
        agentes = None
    if not isinstance(agentes, list) or not all(
        isinstance(agente, dict)
        and isinstance(agente.get("id"), str)
        and isinstance(agente.get("workspace"), str)
        for agente in agentes
    ):
        raise ListaInvalida(f"la lista de agentes de {mini} no llegó o no tiene la forma esperada")
    return agentes


def correr_desde_la_mac(accion: str, mini: str, checkout: Path) -> int:
    """La mitad Mac: valida el paquete del checkout, arma la publicación, la lleva a la Mini y
    corre allá la mitad `--local`. La salida de la Mini se imprime tal cual y su código de
    salida es el de acá."""
    contexto = _contexto()
    carpeta_de_contexto = Path(checkout) / "scripts" / "agent-work" / "contexto"
    try:
        manifiesto = contexto.leer_json(carpeta_de_contexto / "poteto.v1.json")
        contexto.comprobar_generacion(
            manifiesto, contexto.leer_json(carpeta_de_contexto / "generaciones.json")
        )
        perfiles = contexto.leer_json(carpeta_de_contexto / "perfiles.v1.json")
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    try:
        agentes = agentes_por_ssh(mini)
    except ListaInvalida as error:
        print(error, file=sys.stderr)
        return 1
    # El staging nace en /tmp a propósito: la copia remota va a /tmp/<nombre> de la Mini y el
    # nombre de la carpeta local es el nombre remoto (en macOS TMPDIR no es /tmp).
    carpeta = Path(tempfile.mkdtemp(prefix="sua-contexto-", dir="/tmp"))
    copiado = False
    try:
        try:
            armar_publicacion(
                carpeta,
                manifiesto,
                perfiles,
                agentes,
                fuente=contexto.fuente_del_paquete(manifiesto),
                script=Path(__file__).resolve(),
            )
        except (OSError, ValueError, KeyError) as error:
            print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
            return 3
        nombre = carpeta.name
        copia = subprocess.run(
            ["scp", "-q", "-r", str(carpeta), f"{mini}:/tmp/"], capture_output=True, text=True
        )
        if copia.returncode != 0:
            print(copia.stderr.strip(), file=sys.stderr)
            return 1
        copiado = True
        remoto = subprocess.run(
            [
                "ssh",
                mini,
                "python3",
                f"/tmp/{nombre}/publicar-contexto.py",
                "--local",
                f"--{accion}",
                "--publicacion",
                f"/tmp/{nombre}",
            ],
            capture_output=True,
            text=True,
        )
        sys.stdout.write(remoto.stdout)
        if remoto.returncode not in (0, 3, 4):
            sys.stderr.write(remoto.stderr)
        return remoto.returncode
    finally:
        if copiado:
            # Pase lo que pase en la Mini, la publicación no se queda en su /tmp (4.3):
            # la mitad Mac la borra por ssh al terminar.
            subprocess.run(["ssh", mini, "rm", "-rf", f"/tmp/{nombre}"], capture_output=True)
        shutil.rmtree(carpeta, ignore_errors=True)


# --- mitad Mini ----------------------------------------------------------------------------------


def leer_en_la_mini(publicacion: Path, home: Path, agentes_json: Path | None) -> int:
    """`--leer`: guarda el sha256 de cada `AGENTS.md` entero para el CAS de `--aplicar`
    (4.3): si cambió después de esto, aunque sea fuera del bloque, es conflicto."""
    suya = home / ".openclaw" / "sua-contexto"
    agentes = listar_agentes(agentes_json)
    manifiesto, _, _ = cargar_publicacion(publicacion, agentes)
    lectura = {
        "generacion": manifiesto["generation"],
        "digest": manifiesto["digest"],
        "agents": {
            agente["id"]: sha256hex(leer_bytes(Path(agente["workspace"]) / "AGENTS.md"))
            for agente in agentes
        },
    }
    escribir_atomico(suya / "lectura.json", canonico(lectura) + b"\n")
    linea(manifiesto["generation"], {}, {}, 0)
    return 0


def aplicar_en_la_mini(publicacion: Path, home: Path, agentes_json: Path | None) -> int:
    """`--aplicar`: perfiles, skills administradas y el bloque de cada `AGENTS.md`, con CAS
    contra la lectura previa y contra lo que el estado dice que publicamos."""
    skills_dir = home / ".openclaw" / "skills"
    estado_path = skills_dir / ".sua-contexto.json"
    suya = home / ".openclaw" / "sua-contexto"
    perfiles_dest = home / ".local" / "share" / "agent-work" / "perfiles.v1.json"
    agentes = listar_agentes(agentes_json)
    manifiesto, _, bloques = cargar_publicacion(publicacion, agentes)
    if not (suya / "lectura.json").exists():
        raise Rechazo("no hay lectura previa (--leer)")
    lectura = leer_json(suya / "lectura.json")
    nombres = skills_administradas(manifiesto, publicacion)
    estado = leer_json(estado_path) if estado_path.exists() else estado_vacio()
    gen = str(manifiesto["generation"])
    conflictos = 0
    salida_skills: dict[str, str] = {}
    salida_agentes: dict[str, str] = {}

    bytes_perfiles = (publicacion / "perfiles.v1.json").read_bytes()
    if not perfiles_dest.exists() or perfiles_dest.read_bytes() != bytes_perfiles:
        escribir_atomico(perfiles_dest, bytes_perfiles)

    for nombre in nombres:
        destino = skills_dir / nombre
        if destino.exists():
            actual = digest_de_carpeta(destino)
            if nombre not in estado["skills"]:
                salida_skills[nombre] = "conflicto: no es del publicador"
                conflictos += 1
                continue
            if actual == digest_de_carpeta(publicacion / "skills" / nombre):
                salida_skills[nombre] = "igual"
                continue
            if actual != estado["skills"][nombre]:
                # CAS de skills (4.3): una edición en la Mini después de publicar es
                # conflicto, igual que un bloque editado; no se pisa ni se respalda.
                salida_skills[nombre] = "conflicto: cambió después de publicar"
                conflictos += 1
                continue
            respaldo = suya / gen / "skills" / nombre
            respaldo.parent.mkdir(parents=True, exist_ok=True)
            if not respaldo.exists():
                # El respaldo de la generación se escribe una sola vez: la primera vez que
                # esta generación reescribe la skill (4.3). Reaplicarla no lo pisa.
                shutil.copytree(destino, respaldo)
        publicar_skill(publicacion / "skills" / nombre, destino)
        salida_skills[nombre] = "publicado"

    nuevos_bloques = dict(estado["bloques"])
    nuevos_workspaces = dict(estado["workspaces"])
    nuevas_skills = dict(estado["skills"])
    for agente in agentes:
        identificador = agente["id"]
        ruta = Path(agente["workspace"]) / "AGENTS.md"
        actual = leer_bytes(ruta)
        digest = sha256hex(actual)
        # El bloque se mira primero: si su digest no es el que publicamos, alguien lo editó, y
        # ese motivo es más preciso que el del archivo entero (4.3 CAS). Con el bloque intacto,
        # el CAS del archivo entero atrapa la edición fuera del bloque.
        try:
            trecho = trecho_del_bloque(actual)
        except BloqueRoto:
            salida_agentes[identificador] = "conflicto: el bloque fue editado"
            conflictos += 1
            continue
        if trecho is not None:
            desde, hasta = trecho
            if sha256hex(actual[desde:hasta]) != estado["bloques"].get(identificador):
                salida_agentes[identificador] = "conflicto: el bloque fue editado"
                conflictos += 1
                continue
            contenido = actual[:desde] + bloques[identificador] + actual[hasta:]
        else:
            salto = b"" if not actual or actual.endswith(b"\n") else b"\n"
            final = b"" if bloques[identificador].endswith(b"\n") else b"\n"
            contenido = actual + salto + bloques[identificador] + final
        if (
            estado["workspaces"].get(identificador) != digest
            and lectura.get("agents", {}).get(identificador) != digest
        ):
            salida_agentes[identificador] = "conflicto: cambió después de --leer"
            conflictos += 1
            continue
        if contenido == actual:
            salida_agentes[identificador] = "igual"
            nuevos_workspaces[identificador] = digest
            nuevos_bloques[identificador] = sha256hex(bloques[identificador])
            continue
        respaldo = suya / gen / "workspaces" / f"{identificador}.AGENTS.md"
        respaldo.parent.mkdir(parents=True, exist_ok=True)
        if not respaldo.exists():
            respaldo.write_bytes(actual)
        escribir_atomico(ruta, contenido)
        releido = sha256hex(leer_bytes(ruta))
        if releido != sha256hex(contenido):
            salida_agentes[identificador] = "conflicto: no se pudo verificar"
            conflictos += 1
            continue
        salida_agentes[identificador] = "publicado"
        nuevos_workspaces[identificador] = releido
        nuevos_bloques[identificador] = sha256hex(bloques[identificador])

    cambios = (
        conflictos > 0
        or "publicado" in salida_skills.values()
        or ("publicado" in salida_agentes.values())
    )
    if cambios:
        for nombre, resultado in salida_skills.items():
            if not resultado.startswith("conflicto"):
                nuevas_skills[nombre] = digest_de_carpeta(skills_dir / nombre)
        nuevo_estado = {
            "schema": ESTADO_SCHEMA,
            "generacion": manifiesto["generation"],
            "digest": manifiesto["digest"],
            "bloques": nuevos_bloques,
            "workspaces": nuevos_workspaces,
            "skills": nuevas_skills,
            "skills_anteriores": nombres,
        }
        anterior = suya / gen / "estado-anterior.json"
        if not anterior.exists():
            escribir_atomico(anterior, canonico(estado) + b"\n")
        escribir_atomico(estado_path, canonico(nuevo_estado) + b"\n")
    linea(manifiesto["generation"], salida_agentes, salida_skills, conflictos)
    return 4 if conflictos else 0


def revertir_en_la_mini(home: Path, agentes_json: Path | None) -> int:
    """`--revertir`: vuelve al respaldo lo que sigue igual a lo publicado; lo que cambió
    después queda en conflicto, nombrado, y no se toca (4.3 Reversa). Una skill sin
    respaldo es una que esta generación no reescribió: queda como está si ya estaba
    publicada antes, y solo la quita la generación que la trajo."""
    skills_dir = home / ".openclaw" / "skills"
    estado_path = skills_dir / ".sua-contexto.json"
    suya = home / ".openclaw" / "sua-contexto"
    if not estado_path.exists():
        raise Rechazo("no hay nada publicado")
    estado = leer_json(estado_path)
    if estado.get("generacion") is None:
        raise Rechazo("no hay nada publicado")
    gen = str(estado["generacion"])
    agentes = listar_agentes(agentes_json)
    rutas = {agente["id"]: Path(agente["workspace"]) / "AGENTS.md" for agente in agentes}
    conflictos = 0
    salida_skills: dict[str, str] = {}
    salida_agentes: dict[str, str] = {}

    anterior_path = suya / gen / "estado-anterior.json"
    anterior = leer_json(anterior_path) if anterior_path.exists() else estado_vacio()
    for nombre in sorted(estado["skills"]):
        destino = skills_dir / nombre
        if digest_de_carpeta(destino) != estado["skills"][nombre]:
            salida_skills[nombre] = "conflicto: cambió después de publicar"
            conflictos += 1
            continue
        respaldo = suya / gen / "skills" / nombre
        if respaldo.exists():
            shutil.rmtree(destino)
            shutil.copytree(respaldo, destino)
            salida_skills[nombre] = "revertido"
        elif nombre in anterior["skills"]:
            salida_skills[nombre] = "igual"
        else:
            shutil.rmtree(destino)
            salida_skills[nombre] = "quitado"

    respaldo_dir = suya / gen / "workspaces"
    identificadores = set(estado["workspaces"])
    if respaldo_dir.is_dir():
        identificadores.update(
            respaldo.name[: -len(".AGENTS.md")] for respaldo in respaldo_dir.glob("*.AGENTS.md")
        )
    for identificador in sorted(identificadores):
        ruta = rutas.get(identificador)
        if ruta is None:
            continue
        respaldo = respaldo_dir / f"{identificador}.AGENTS.md"
        actual = leer_bytes(ruta)
        digest = sha256hex(actual)
        esperado = estado["workspaces"].get(identificador)
        if esperado is None and respaldo.exists():
            esperado = sha256hex(respaldo.read_bytes())
        if digest != esperado:
            salida_agentes[identificador] = "conflicto: cambió después de publicar"
            conflictos += 1
            continue
        if respaldo.exists():
            escribir_atomico(ruta, respaldo.read_bytes())
            salida_agentes[identificador] = "revertido"
        else:
            salida_agentes[identificador] = "igual"

    escribir_atomico(estado_path, canonico(anterior) + b"\n")
    # La generación que reporta la reversa es la que revierte, la que estaba publicada.
    linea(estado["generacion"], salida_agentes, salida_skills, conflictos)
    return 4 if conflictos else 0


# --- línea de comando -----------------------------------------------------------------------------


class ParserJson(argparse.ArgumentParser):
    """El uso malo también contesta una línea JSON con salida 3, como todo rechazo."""

    def error(self, mensaje: str) -> None:
        print(json.dumps({"ok": False, "error": mensaje}, ensure_ascii=False))
        raise SystemExit(3)


def parser() -> argparse.ArgumentParser:
    argumentos = ParserJson(prog="publicar-contexto.py", description=__doc__.splitlines()[0])
    acciones = argumentos.add_mutually_exclusive_group(required=True)
    acciones.add_argument(
        "--leer",
        dest="accion",
        action="store_const",
        const="leer",
        help="lee cada AGENTS.md para el CAS",
    )
    acciones.add_argument(
        "--aplicar",
        dest="accion",
        action="store_const",
        const="aplicar",
        help="publica el bloque y las skills administradas",
    )
    acciones.add_argument(
        "--revertir",
        dest="accion",
        action="store_const",
        const="revertir",
        help="vuelve al respaldo de la última publicación",
    )
    argumentos.add_argument("--local", action="store_true", help="corre la mitad Mini, sin ssh")
    argumentos.add_argument("--mini", default="gon@100.73.187.5", help="la Mini donde se publica")
    argumentos.add_argument(
        "--checkout",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="el checkout de G",
    )
    argumentos.add_argument("--publicacion", type=Path, help="la carpeta publicada (con --local)")
    argumentos.add_argument(
        "--home", type=Path, default=Path.home(), help="el home de la Mini (con --local)"
    )
    argumentos.add_argument(
        "--agentes-json", type=Path, help="lista de agentes en vez de openclaw (con --local)"
    )
    return argumentos


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if not args.local:
            return correr_desde_la_mac(args.accion, args.mini, args.checkout)
        if args.publicacion is None:
            raise Rechazo("--publicacion es obligatorio con --local")
        suya = args.home / ".openclaw" / "sua-contexto"
        if args.accion == "leer":
            return leer_en_la_mini(args.publicacion, args.home, args.agentes_json)
        if args.accion == "aplicar":
            return con_candado(
                suya, lambda: aplicar_en_la_mini(args.publicacion, args.home, args.agentes_json)
            )
        return con_candado(suya, lambda: revertir_en_la_mini(args.home, args.agentes_json))
    except (OSError, ValueError, KeyError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3


if __name__ == "__main__":
    sys.exit(main())

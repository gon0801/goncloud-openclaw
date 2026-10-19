#!/usr/bin/env python3
"""El paquete de poteto y los perfiles de trabajador de SUA-03 (diseño, 4.2 a 4.4).

Un paquete es poteto (`poteto-mode` sin `scripts/` y las `principle-*`), una adaptación, un perfil y
las skills de ese perfil. `contexto/poteto.v1.json` fija la fuente (pstack en una revisión) con el
sha256 de cada archivo, y `contexto/generaciones.json` fija el digest de cada generación: cambiar un
byte sin subir `generation` es un error. `contexto/perfiles.v1.json` son los perfiles como datos.

Todo es puro salvo la frontera de lectura (`leer_*`, `construir` y la línea de comando):

    contexto.py manifiesto --fuente <pstack> --commit <sha> --version <v> --generation <n>
    contexto.py construir --fuente <pstack> --perfil <id> --destino <carpeta>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

CONTEXTO = Path(__file__).resolve().parent / "contexto"
MANIFIESTO = CONTEXTO / "poteto.v1.json"
GENERACIONES = CONTEXTO / "generaciones.json"
PERFILES = CONTEXTO / "perfiles.v1.json"
ADAPTACIONES = {
    "opencode-run": CONTEXTO / "adaptacion-opencode-run.md",
    "openclaw": CONTEXTO / "adaptacion-openclaw.md",
}
BLOQUE = CONTEXTO / "bloque-agents.md"
MANIFEST_SCHEMA = "agent-work.poteto.v1"
PROFILES_SCHEMA = "agent-work.perfiles.v1"
POTETO = "poteto-mode"
PRINCIPIO = "principle-"
OPENCLAW_SKILL = "skills/poteto-openclaw/SKILL.md"
"""La adaptación `openclaw` es esta skill tal cual, y el manifiesto la lleva como un archivo más:
nada se publica en las rutas nativas fuera de una generación (diseño, 4.2; residual R2). No viene
de pstack sino de G, y solo la publica el publicador nativo."""
TOPE_BLOQUE = 1500
"""Caracteres del bloque de `AGENTS.md` (diseño, riesgo 3): va en cada turno de cada agente."""
COBERTURAS = ("checkpoint-only", "events")
COMPETENCIAS = ("passed", "failed", "pending")


class ContextoIncompleto(ValueError):
    """Un archivo de la fuente falta o no coincide con el manifiesto."""


class GeneracionSinSubir(ValueError):
    """El contenido cambió y `generation` no."""


def canonico(documento: object) -> bytes:
    """La forma canónica de un documento, compartida por los escritores del paquete."""
    return json.dumps(documento, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


def digest_de(manifiesto: dict) -> str:
    """El digest del manifiesto: el sha256 de su forma canónica sin el campo `digest`."""
    return "sha256:" + sha256(canonico({k: v for k, v in manifiesto.items() if k != "digest"}))


def digest_de_perfil(perfil: dict) -> str:
    return "sha256:" + sha256(canonico(perfil))


def del_paquete(ruta: str, skills: tuple[str, ...] | list[str]) -> bool:
    """Si un archivo de la fuente (`skills/<skill>/...`) va en el paquete de esas skills."""
    partes = ruta.split("/")
    if len(partes) < 3 or partes[0] != "skills":
        return False
    skill = partes[1]
    if skill == POTETO:
        return partes[2] != "scripts"
    return skill.startswith(PRINCIPIO) or skill in skills


def archivos_de_la_fuente(fuente: Path, skills: list[str]) -> list[str]:
    """Los archivos de la fuente que entran en una generación, por ruta relativa y en orden."""
    rutas = []
    for archivo in sorted((fuente / "skills").rglob("*")):
        if archivo.is_file() and not archivo.is_symlink():
            relativa = archivo.relative_to(fuente).as_posix()
            if del_paquete(relativa, skills):
                rutas.append(relativa)
    faltan = [s for s in skills if not any(r.startswith(f"skills/{s}/") for r in rutas)]
    if faltan:
        raise ContextoIncompleto(f"la fuente no tiene la skill {faltan[0]}")
    return rutas


def skills_de_los_perfiles(perfiles: dict) -> list[str]:
    return sorted({skill for perfil in perfiles["profiles"] for skill in perfil["skills"]})


def manifiesto(
    fuente: Path,
    perfiles: dict,
    *,
    repo: str,
    commit: str,
    version: str,
    generation: int,
    adaptaciones: dict[str, bytes],
    bloque: bytes,
) -> dict:
    """El manifiesto de una generación sobre una fuente."""
    archivos = [
        {"path": ruta, "sha256": sha256((fuente / ruta).read_bytes())}
        for ruta in archivos_de_la_fuente(fuente, skills_de_los_perfiles(perfiles))
    ]
    archivos.append({"path": OPENCLAW_SKILL, "sha256": sha256(adaptaciones["openclaw"])})
    documento = {
        "schema": MANIFEST_SCHEMA,
        "generation": generation,
        "source": {"repo": repo, "commit": commit, "version": version},
        "files": archivos,
        "adaptations": {nombre: sha256(texto) for nombre, texto in sorted(adaptaciones.items())},
        "block": sha256(bloque),
    }
    return {**documento, "digest": digest_de(documento)}


def comprobar_generacion(manifiesto: dict, generaciones: dict[str, str]) -> None:
    """El manifiesto tiene el digest que `generaciones.json` fija para su generación."""
    if manifiesto.get("digest") != digest_de(manifiesto):
        raise GeneracionSinSubir("el campo digest no es el digest del manifiesto")
    fijado = generaciones.get(str(manifiesto["generation"]))
    if fijado is None:
        raise GeneracionSinSubir(f"la generación {manifiesto['generation']} no está fijada")
    if fijado != manifiesto["digest"]:
        raise GeneracionSinSubir(
            f"la generación {manifiesto['generation']} ya está fijada con otro contenido: "
            "sube generation"
        )


def comprobar_textos(manifiesto: dict, adaptaciones: dict[str, bytes], bloque: bytes) -> None:
    """Las adaptaciones y el bloque de G son los que el manifiesto fija."""
    for nombre, texto in adaptaciones.items():
        if manifiesto["adaptations"].get(nombre) != sha256(texto):
            raise ContextoIncompleto(f"la adaptación {nombre} no coincide con el manifiesto")
    archivos = {f["path"]: f["sha256"] for f in manifiesto["files"]}
    if archivos.get(OPENCLAW_SKILL) != sha256(adaptaciones["openclaw"]):
        raise ContextoIncompleto(f"{OPENCLAW_SKILL} no es la adaptación openclaw")
    if manifiesto["block"] != sha256(bloque):
        raise ContextoIncompleto("el bloque de AGENTS.md no coincide con el manifiesto")


def comprobar_fuente(manifiesto: dict, perfil: dict, fuente: Path) -> None:
    """Cada archivo de la fuente que lleva el paquete coincide con el manifiesto (4.5): el
    contexto-incompleto del lado del plan, que lee la fuente antes de decidir."""
    esperado = {f["path"]: f["sha256"] for f in manifiesto["files"]}
    for ruta in archivos_del_perfil(manifiesto, perfil):
        origen = Path(fuente) / ruta
        try:
            datos = origen.read_bytes() if not origen.is_symlink() else b""
        except OSError as error:
            raise ContextoIncompleto(f"{ruta}: {error.strerror}") from error
        if sha256(datos) != esperado[ruta]:
            raise ContextoIncompleto(f"{ruta} no coincide con el manifiesto")


def fuente_del_paquete(manifiesto: dict, plugins: Path | None = None) -> Path:
    """La carpeta del checkout de pstack que el manifiesto fija, tal como Claude Code la instala
    en esta Mac. Una fuente que ya no coincide lo dicen `construir` y `comprobar_fuente`."""
    source = manifiesto.get("source") if isinstance(manifiesto, dict) else None
    version = source.get("version") if isinstance(source, dict) else None
    if not isinstance(version, str) or not version.strip():
        raise ContextoIncompleto("el manifiesto no nombra la versión de su fuente")
    base = plugins or Path.home() / ".claude/plugins/cache/pstack-claude/pstack"
    return base / version


def perfil(perfiles: dict, id_perfil: str) -> dict:
    for candidato in perfiles["profiles"]:
        if candidato["id"] == id_perfil:
            return candidato
    raise KeyError(id_perfil)


def archivos_del_perfil(manifiesto: dict, perfil: dict) -> list[str]:
    """Los archivos de la fuente en el paquete de un perfil: poteto y exactamente sus skills."""
    return [f["path"] for f in manifiesto["files"] if del_paquete(f["path"], perfil["skills"])]


def archivos_nativos(manifiesto: dict) -> list[str]:
    """Los archivos del conjunto nativo (4.3): poteto-mode sin scripts/, las principle-* y
    poteto-openclaw, tal como están en el manifiesto. Es el paquete menos las skills que cada
    perfil lleva por su cuenta: el agente nativo conserva su workshop."""
    return [
        f["path"]
        for f in manifiesto["files"]
        if del_paquete(f["path"], ()) or f["path"] == OPENCLAW_SKILL
    ]


def clave_de_ruta(ruta: dict) -> str:
    """`host/executor`, más `/agentId` en una ruta nativa: la llave de `competence`."""
    partes = [ruta["host"], ruta["executor"]]
    if ruta.get("agentId"):
        partes.append(ruta["agentId"])
    return "/".join(partes)


@dataclass(frozen=True)
class Admision:
    """Si un perfil atiende un encargo: `causa` es None cuando sí, o una de las de `plan_launch`."""

    causa: str | None
    frase: str


def _vencido(fecha: str | None, ahora: datetime) -> bool:
    return fecha is not None and datetime.fromisoformat(fecha.replace("Z", "+00:00")) <= ahora


def admite(
    perfil: dict, ruta: dict, contrato: str, *, ahora: datetime, canario: bool = False
) -> Admision:
    """La admisión por perfil (diseño, 4.4): la ruta, el contrato, la competencia en esa ruta y la
    vigencia de sus fuentes. Distingue un perfil de otro por sus datos, nunca por su nombre."""
    clave = clave_de_ruta(ruta)
    atiende = {clave_de_ruta(atiende) for atiende in perfil["routes"]}
    if clave not in atiende:
        return Admision(
            "perfil-no-atiende-ruta",
            f"el perfil {perfil['id']} atiende {', '.join(sorted(atiende)) or 'ninguna ruta'} "
            f"y no atiende la ruta {clave} con la que llega el encargo",
        )
    if contrato not in perfil["resultContracts"]:
        return Admision(
            "perfil-no-admite-contrato", f"el perfil {perfil['id']} no admite {contrato}"
        )
    vencidas = [
        fuente["ref"] for fuente in perfil["sources"] if _vencido(fuente["validUntil"], ahora)
    ]
    if vencidas:
        return Admision(
            "perfil-sin-competencia", f"la fuente {vencidas[0]} del perfil {perfil['id']} venció"
        )
    competencia = perfil["competence"].get(clave, {})
    vigente = competencia.get("status") == "passed" and not _vencido(
        competencia.get("validUntil"), ahora
    )
    if not vigente and not canario:
        return Admision(
            "perfil-sin-competencia",
            f"el perfil {perfil['id']} no tiene competencia vigente en la ruta {clave}",
        )
    return Admision(None, f"el perfil {perfil['id']} atiende {contrato} en {clave}")


SIN_PERFIL = (
    "No tienes perfil por omisión: sin `profile` en el pedido, trabaja sin perfil "
    "y dilo en tu resultado."
)


def perfil_por_omision(perfiles: dict, agente: str) -> str | None:
    """El único perfil cuyas rutas nombran a ese agente, o None si son cero o más de uno (4.2)."""
    nombrado = [
        p["id"]
        for p in perfiles["profiles"]
        if any(r.get("agentId") == agente for r in p["routes"])
    ]
    return nombrado[0] if len(nombrado) == 1 else None


def bloque(plantilla: str, manifiesto: dict, id_perfil: str | None) -> str:
    """El bloque marcado de `AGENTS.md` de un agente, con su perfil por omisión si tiene uno."""
    texto = plantilla.format(
        generacion=manifiesto["generation"],
        digest=manifiesto["digest"].removeprefix("sha256:"),
        perfil=f"Tu perfil por omisión es `{id_perfil}`." if id_perfil else SIN_PERFIL,
    )
    if len(texto) > TOPE_BLOQUE:
        raise ValueError(f"el bloque tiene {len(texto)} caracteres y el tope es {TOPE_BLOQUE}")
    return texto


def instrucciones(adaptacion: str, perfil: dict) -> str:
    """El `AGENTS.md` de una corrida por CLI: la adaptación y el perfil del encargo."""
    skills = ", ".join(perfil["skills"]) or "ninguna"
    escribe = "sí" if perfil["writesSource"] else "no"
    return (
        f"{adaptacion.rstrip()}\n\n## Tu perfil: {perfil['id']}\n\n{perfil['purpose']}\n\n"
        f"- Contratos que entregas: {', '.join(perfil['resultContracts'])}.\n"
        f"- Escribes fuente: {escribe}.\n"
        f"- Skills de tu perfil, además de poteto: {skills}.\n"
    )


def digest_del_paquete(destino: Path) -> str:
    """El digest de una carpeta de paquete: el sha256 de cada archivo con su ruta, en orden."""
    entradas = [
        {"path": archivo.relative_to(destino).as_posix(), "sha256": sha256(archivo.read_bytes())}
        for archivo in sorted(destino.rglob("*"))
        if archivo.is_file()
    ]
    return "sha256:" + sha256(canonico(entradas))


# --- frontera de lectura y escritura -------------------------------------------------------------


def leer_json(ruta: Path) -> dict:
    return json.loads(ruta.read_text(encoding="utf-8"))


def leer_adaptaciones() -> dict[str, bytes]:
    return {nombre: ruta.read_bytes() for nombre, ruta in ADAPTACIONES.items()}


def construir(
    fuente: Path, manifiesto: dict, perfil: dict, destino: Path, *, adaptaciones: dict[str, bytes]
) -> str:
    """Copia el paquete de un perfil a `destino`, que no debe existir, comprobando cada archivo
    contra el manifiesto, y devuelve su digest. Ante cualquier diferencia no deja nada a medias."""
    esperado = {f["path"]: f["sha256"] for f in manifiesto["files"]}
    for nombre, texto in adaptaciones.items():
        if manifiesto["adaptations"].get(nombre) != sha256(texto):
            raise ContextoIncompleto(f"la adaptación {nombre} no coincide con el manifiesto")
    if Path(destino).exists():
        raise ValueError(f"{destino} ya existe")
    temporal = Path(tempfile.mkdtemp(prefix=".contexto-", dir=Path(destino).parent))
    try:
        for ruta in archivos_del_perfil(manifiesto, perfil):
            origen = Path(fuente) / ruta
            try:
                datos = origen.read_bytes() if not origen.is_symlink() else b""
            except OSError as error:
                raise ContextoIncompleto(f"{ruta}: {error.strerror}") from error
            if sha256(datos) != esperado[ruta]:
                raise ContextoIncompleto(f"{ruta} no coincide con el manifiesto")
            copia = temporal / ruta
            copia.parent.mkdir(parents=True, exist_ok=True)
            copia.write_bytes(datos)
        texto = adaptaciones["opencode-run"].decode("utf-8")
        (temporal / "AGENTS.md").write_text(instrucciones(texto, perfil), encoding="utf-8")
        (temporal / "perfil.json").write_bytes(canonico(perfil) + b"\n")
        (temporal / "poteto.v1.json").write_bytes(canonico(manifiesto) + b"\n")
        os.rename(temporal, destino)
    except BaseException:
        shutil.rmtree(temporal, ignore_errors=True)
        raise
    return digest_del_paquete(Path(destino))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    pasos = parser.add_subparsers(dest="paso", required=True)
    nuevo = pasos.add_parser("manifiesto", help="escribe el manifiesto de una generación en stdout")
    nuevo.add_argument("--fuente", type=Path, required=True)
    nuevo.add_argument("--repo", default="https://github.com/poteto/pstack-claude")
    nuevo.add_argument("--commit", required=True)
    nuevo.add_argument("--version", required=True)
    nuevo.add_argument("--generation", type=int, required=True)
    copia = pasos.add_parser("construir", help="copia el paquete de un perfil")
    copia.add_argument("--fuente", type=Path, required=True)
    copia.add_argument("--perfil", required=True)
    copia.add_argument("--destino", type=Path, required=True)
    args = parser.parse_args(argv)
    perfiles = leer_json(PERFILES)
    if args.paso == "manifiesto":
        documento = manifiesto(
            args.fuente,
            perfiles,
            repo=args.repo,
            commit=args.commit,
            version=args.version,
            generation=args.generation,
            adaptaciones=leer_adaptaciones(),
            bloque=BLOQUE.read_bytes(),
        )
        print(json.dumps(documento, indent=2, ensure_ascii=False))
        return 0
    try:
        documento = leer_json(MANIFIESTO)
        comprobar_generacion(documento, leer_json(GENERACIONES))
        digest = construir(
            args.fuente,
            documento,
            perfil(perfiles, args.perfil),
            args.destino,
            adaptaciones=leer_adaptaciones(),
        )
    except (KeyError, ValueError, OSError) as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": True, "digest": digest}))
    return 0


if __name__ == "__main__":
    sys.exit(main())

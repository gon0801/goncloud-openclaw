#!/usr/bin/env python3
"""Arma el resultado con la forma que el runtime exige a un trabajador (SUA-04, 4.5b).

El resultado lleva su forma ({kind: produced, payload, artifactRef, digest,
observedRevision}) y un digest que es el sha256 del canónico del payload: un modelo no lo
arma a mano. Este archivo solo usa la biblioteca estándar.
El canónico es el de spool.py: json.dumps con sort_keys, separators (",", ":") y
ensure_ascii=False, que es lo que hace stableStringify de R.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

TAREA_EN_CABECERA = re.compile(r"^tarea: (\S+)$", re.MULTILINE)
NOMBRE_SHA = re.compile(r"[0-9a-f]{64}")
MAX_INSTRUCTION_BYTES = 1024 * 1024


def canonico(documento) -> str:
    return json.dumps(documento, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class Falla(Exception):
    pass


HALLAZGOS_SCHEMA = "hallazgos.v1"
CAMPOS_HALLAZGO = {"id", "bloqueante", "archivo", "linea", "resumen", "reproduce"}


def _defecto_de_hallazgos(documento) -> str | None:
    """El primer defecto de un documento hallazgos.v1, o None si es válido (SUA-05, 4.2)."""
    if not isinstance(documento, dict):
        return f"el artefacto no parsea como {HALLAZGOS_SCHEMA}"
    if set(documento) != {"schema", "findings"} or documento["schema"] != HALLAZGOS_SCHEMA:
        return f"el artefacto no parsea como {HALLAZGOS_SCHEMA}"
    if not isinstance(documento["findings"], list):
        return "findings no es una lista"
    for indice, hallazgo in enumerate(documento["findings"], start=1):
        if not isinstance(hallazgo, dict):
            return f"el hallazgo {indice} no es un objeto"
        if type(hallazgo.get("bloqueante")) is not bool:
            return f"el hallazgo {indice} trae bloqueante que no es bool"
        if type(hallazgo.get("linea")) is not int:
            return f"el hallazgo {indice} trae linea que no es int"
        for campo in ("id", "archivo", "resumen"):
            if not isinstance(hallazgo.get(campo), str) or not hallazgo[campo].strip():
                return f"el hallazgo {indice} trae {campo} vacío o que no es texto"
        if hallazgo["bloqueante"] and "reproduce" not in hallazgo:
            return f"el hallazgo {indice} es bloqueante sin reproduce"
        if "reproduce" in hallazgo and (
            not isinstance(hallazgo["reproduce"], str) or not hallazgo["reproduce"].strip()
        ):
            return f"el hallazgo {indice} trae reproduce vacío o que no es texto"
        if set(hallazgo) != (
            CAMPOS_HALLAZGO if "reproduce" in hallazgo else CAMPOS_HALLAZGO - {"reproduce"}
        ):
            return f"el hallazgo {indice} lleva llaves ajenas al contrato"
    return None


def _rechazo_de_artefacto(veredicto: str, ruta: str) -> str | None:
    """El motivo por el que el CONTENIDO del artefacto rompe review.v1 (SUA-05, 4.2), o None
    si pasa. Es la misma regla que el host valida al grabar, duplicada aquí en su forma mínima
    porque este archivo es standalone para la Mini (solo biblioteca estándar): un changes
    exige un hallazgos.v1 válido y un approved no aprueba con un bloqueante tipado ni con una
    línea que empieza con BLOQUEANTE o BLOCKER."""
    raw = Path(ruta).read_bytes()
    try:
        documento = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        documento = None
    if veredicto == "changes":
        if documento is None:
            return f"resultado-invalido: el artefacto no parsea como {HALLAZGOS_SCHEMA}"
        defecto = _defecto_de_hallazgos(documento)
        if not defecto and not documento["findings"]:
            defecto = "un changes trae al menos un hallazgo"
        return f"resultado-invalido: {defecto}" if defecto else None
    if isinstance(documento, dict) and documento.get("schema") == HALLAZGOS_SCHEMA:
        defecto = _defecto_de_hallazgos(documento)
        if defecto:
            return f"resultado-invalido: {defecto}"
        hallazgos = documento.get("findings")
        if isinstance(hallazgos, list):
            for hallazgo in hallazgos:
                if isinstance(hallazgo, dict) and hallazgo.get("bloqueante") is True:
                    return (
                        f"aprobado-con-bloqueante: {hallazgo.get('id')} es bloqueante "
                        "en la evidencia de un approved"
                    )
        return None
    for linea in raw.decode("utf-8", errors="replace").splitlines():
        if linea.startswith(("BLOQUEANTE", "BLOCKER")):
            return (
                "aprobado-con-bloqueante: la evidencia trae una línea que empieza "
                "con BLOQUEANTE o BLOCKER"
            )
    return None


def buscar_instruccion(root: Path, tarea: str) -> tuple[str, bytes]:
    """El (sha, contenido) de la instrucción cuya cabecera trae tarea: <uuid>."""
    if root.is_symlink() or not root.is_dir():
        raise Falla(f"el instructionRoot no es una carpeta: {root}")
    for archivo in sorted(root.iterdir()):
        if not archivo.is_file() or archivo.is_symlink() or not NOMBRE_SHA.fullmatch(archivo.name):
            continue
        contenido = archivo.read_bytes()
        if len(contenido) > MAX_INSTRUCTION_BYTES:
            continue
        encontrada = TAREA_EN_CABECERA.search(contenido.decode("utf-8", errors="replace"))
        if encontrada and encontrada.group(1) == tarea:
            if hashlib.sha256(contenido).hexdigest() != archivo.name:
                raise Falla(f"la instrucción {archivo.name} no coincide con su sha")
            return archivo.name, contenido
    raise Falla(f"no encontré la instrucción de la tarea {tarea} en {root}")


def armar(root: Path, tarea: str, contrato: str, artefacto: str, veredicto) -> dict:
    sha, _ = buscar_instruccion(root, tarea)
    if not Path(artefacto).is_file():
        raise Falla(f"el artefacto no existe: {artefacto}")
    if contrato == "ready.v1":
        if veredicto:
            raise Falla("ready.v1 no lleva --veredicto")
        payload = {"evidenceRef": artefacto}
    elif contrato == "review.v1":
        if not veredicto:
            raise Falla("review.v1 pide --veredicto approved|changes")
        rechazo = _rechazo_de_artefacto(veredicto, artefacto)
        if rechazo:
            raise Falla(rechazo)
        payload = (
            {"verdict": "approved", "evidenceRef": artefacto}
            if veredicto == "approved"
            else {"verdict": "changes", "findingsRef": artefacto}
        )
    else:
        raise Falla(f"contrato desconocido: {contrato} (los de R son ready.v1 y review.v1)")
    return {
        "kind": "produced",
        "payload": payload,
        "artifactRef": artefacto,
        "digest": "sha256:" + hashlib.sha256(canonico(payload).encode()).hexdigest(),
        "observedRevision": {
            "kind": "artifact",
            "ref": f"artifact:{sha}",
            "digest": f"sha256:{sha}",
        },
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="managedTasks.instructionRoot")
    parser.add_argument("--tarea", required=True, help="el uuid de la cabecera tarea:")
    parser.add_argument("--contrato", required=True, help="ready.v1 o review.v1")
    parser.add_argument("--artefacto", required=True, help="la ruta absoluta del artefacto")
    parser.add_argument(
        "--veredicto",
        choices=("approved", "changes"),
        help="solo review.v1: approved da evidenceRef y changes, findingsRef",
    )
    args = parser.parse_args(argv)
    try:
        result = armar(args.root, args.tarea, args.contrato, args.artefacto, args.veredicto)
    except (Falla, OSError) as error:
        print(f"reporte: {error}", file=sys.stderr)
        return 3
    print(canonico(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

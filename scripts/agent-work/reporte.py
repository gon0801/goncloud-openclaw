#!/usr/bin/env python3
"""Arma el resultado de un encargo nativo para managed_tasks_report (SUA-04, 4.5b).

R exige un result con su forma ({kind: produced, payload, artifactRef, digest,
observedRevision}) y un digest que es el sha256 del canónico del payload: un modelo no lo
arma a mano. Este archivo va junto a brief.py en la Mini y solo usa la biblioteca estándar.
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

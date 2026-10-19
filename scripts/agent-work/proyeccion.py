#!/usr/bin/env python3
"""El emisor de proyecciones (SUA-06, 4.2): derivar, leer y listar.

`derivar` y sus ayudantes puros viven en sistema_agentes.derivar (SUA-07, H0a): es el
módulo que Hermes (Windows) copia, así que no importa fcntl, subprocess ni socket; este
script lo reexporta y le pone scripts/ en sys.path. leer y listar hablan con el gateway
por el `openclaw` del host. Biblioteca estándar, Python 3.9 (corre en la Mac y en la Mini).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sistema_agentes.derivar import (  # noqa: E402
    _con_zona,
    _entero_positivo,
    _fecha,
    _identificador,
    _instante,
    _lista,
    derivar,
)

# Reexporta la superficie pura de derivar: quien importaba proyeccion sigue
# encontrando aquí los ayudantes del módulo puro (las pruebas los usan así).
__all__ = [
    "derivar",
    "_con_zona",
    "_entero_positivo",
    "_fecha",
    "_identificador",
    "_instante",
    "_lista",
]


def cargar_snapshot(ruta: str | Path) -> dict:
    try:
        return json.loads(Path(ruta).read_bytes())
    except ValueError as fallo:
        raise ValueError(f"snapshot {ruta} no es JSON válido: {fallo}") from fallo


def _cargar_notados(ruta: str | Path | None) -> dict[str, datetime]:
    if ruta is None:
        return {}
    try:
        crudo = json.loads(Path(ruta).read_bytes())
    except ValueError as fallo:
        raise ValueError(f"notados {ruta} no es JSON válido: {fallo}") from fallo
    if not isinstance(crudo, dict):
        raise ValueError(f"notados {ruta} no es un objeto {{exceptionId: fecha}}")
    return {clave: _instante(valor, f"notados[{clave!r}]") for clave, valor in crudo.items()}


def _gateway(openclaw_bin: str | Path, metodo: str, params: dict) -> object:
    """Una llamada `openclaw gateway call`; devuelve el primer JSON de la salida."""
    try:
        resultado = subprocess.run(
            [
                str(openclaw_bin),
                "gateway",
                "call",
                metodo,
                "--params",
                json.dumps(params, ensure_ascii=False, separators=(",", ":")),
                "--json",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except subprocess.TimeoutExpired as colgado:
        # RaicesPublisher corre dentro del bucle del host: un TimeoutExpired suelto lo tumbaría.
        raise RuntimeError(f"gateway sin respuesta en 60 s para {metodo}") from colgado
    if resultado.returncode:
        detalle = " ".join((resultado.stderr or resultado.stdout).split())[:200]
        raise RuntimeError(f"gateway no disponible para {metodo}: {detalle}")
    lineas = resultado.stdout.splitlines(keepends=True)
    for indice, linea in enumerate(lineas):
        if not linea.lstrip().startswith("{"):
            continue
        try:
            respuesta, _ = json.JSONDecoder().raw_decode("".join(lineas[indice:]).lstrip())
        except json.JSONDecodeError:
            continue
        return respuesta
    try:
        return json.loads(resultado.stdout.strip())
    except ValueError:
        raise RuntimeError(f"respuesta JSON inválida del gateway para {metodo}") from None


def _binario(openclaw_bin: str | None) -> Path:
    binario = openclaw_bin or os.environ.get("OPENCLAW_BIN")
    return Path(binario) if binario else Path.home() / ".openclaw/bin/openclaw"


def construir_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="proyeccion.py", description=__doc__)
    subcomandos = parser.add_subparsers(dest="comando", required=True)

    def comunes(destino):
        destino.add_argument("--stale-after-ms", type=int, required=True)
        destino.add_argument("--intervalo-ms", type=int, required=True)
        destino.add_argument("--notados", type=Path, default=None)
        destino.add_argument("--host-gateway", default=socket.gethostname())

    derivar_cli = subcomandos.add_parser(
        "derivar", help="deriva la proyección de un snapshot en disco"
    )
    derivar_cli.add_argument("snapshot", type=Path)
    comunes(derivar_cli)

    leer_cli = subcomandos.add_parser("leer", help="lee la raíz del gateway y la deriva")
    leer_cli.add_argument("--root", required=True)
    leer_cli.add_argument("--openclaw-bin", default=None)
    comunes(leer_cli)

    listar_cli = subcomandos.add_parser("listar", help="lista las raíces del gateway")
    listar_cli.add_argument("--openclaw-bin", default=None)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = construir_parser().parse_args(argv)
    try:
        if args.comando == "listar":
            print(
                json.dumps(
                    _gateway(_binario(args.openclaw_bin), "managedTasks.root.list", {}),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.comando == "leer":
            snapshot = _gateway(
                _binario(args.openclaw_bin), "managedTasks.root.read", {"rootId": args.root}
            )
            if not isinstance(snapshot, dict):
                raise ValueError(
                    f"managedTasks.root.read no devolvió un snapshot para {args.root!r}"
                )
        else:
            snapshot = cargar_snapshot(args.snapshot)
        resultado = derivar(
            snapshot,
            datetime.now(timezone.utc),
            args.stale_after_ms,
            args.intervalo_ms,
            _cargar_notados(args.notados),
            host_gateway=args.host_gateway,
        )
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"proyeccion: {error}", file=sys.stderr)
        return 2
    print(json.dumps(resultado, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

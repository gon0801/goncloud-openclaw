#!/usr/bin/env python3
"""La regla de línea de un modelo: qué id es el sucesor de otro dentro de su proveedor (SUA-04, 4.1).

Es la regla de `scripts/model_lines.py` de goncloud-hermes (parse, la regla de una sola versión
limpia, los marcadores inestables y la comparación con ceros a la derecha), sin la parte de red y
sin FAMILIES: aquí la línea lleva el prefijo del proveedor (`zai-coding-plan/glm-{}-flash`), así
que un id de otro proveedor nunca es sucesor de este. Biblioteca estándar.
"""
from __future__ import annotations

import re

_NUMERIC_RUN = re.compile(r"\d+(?:[.-]\d+)*")
_UNSTABLE = frozenset({"preview", "exp", "alpha", "beta", "free", "latest"})


def parse(model_id: str) -> "tuple[str, tuple[int, ...]] | None":
    """(línea, versión) de un id, o None cuando no tiene una sola versión limpia.

    Una foto fechada (cualquier parte de cuatro o más dígitos), dos corridas numéricas o un
    marcador inestable significan "no es una versión a seguir". La línea es el id con su corrida
    numérica reemplazada por {}, con el proveedor delante si el id lo trae.
    """
    provider, slash, name = model_id.partition("/")
    if not slash:
        provider, name = "", model_id
    if _UNSTABLE & set(re.split(r"[^a-z]+", name.lower())):
        return None
    runs = list(_NUMERIC_RUN.finditer(name))
    if len(runs) != 1:
        return None
    run = runs[0]
    parts = re.split(r"[.-]", run.group())
    if any(len(part) >= 4 for part in parts):
        return None
    line = name[: run.start()] + "{}" + name[run.end():]
    if provider:
        line = f"{provider}/{line}"
    return line, tuple(int(part) for part in parts)


def estable(model_id: str) -> bool:
    """Un id es estable cuando tiene línea: ni foto fechada, ni preview, ni latest."""
    return parse(model_id) is not None


def _padded(version: tuple[int, ...], length: int) -> tuple[int, ...]:
    return version + (0,) * (length - len(version))


def _above(left: tuple[int, ...], right: tuple[int, ...]) -> bool:
    length = max(len(left), len(right))
    return _padded(left, length) > _padded(right, length)


def sucesor(actual: str, ids) -> "str | None":
    """El id más alto de la línea de `actual` por encima de él, entre `ids`, o None.

    Como la línea lleva el proveedor, un id de otro proveedor no compite aunque su modelo se
    llame parecido. Un id sin línea (una foto fechada, un preview) nunca es sucesor.
    """
    mine = parse(actual)
    if mine is None:
        return None
    line, best_version = mine
    best: str | None = None
    for model_id in sorted(ids):
        other = parse(model_id)
        if other is not None and other[0] == line and _above(other[1], best_version):
            best_version, best = other[1], model_id
    return best

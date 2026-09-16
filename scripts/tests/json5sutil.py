"""Utilidad compartida de los tests de patches (stdlib, sin dependencia json5).

Los patches del repo son json5 ligero: comentarios `//` y `/* */`, comas
colgantes, llaves sin comillas y strings con comillas simples o dobles.
`cargar()` lo reduce a JSON estricto y lo parsea. Un fallo de parseo es
excepción (nunca verde falso): el llamador decide el mensaje.
"""
import json
import re


def sin_comentarios(src):
    out, i, n, st = [], 0, len(src), None
    while i < n:
        c = src[i]
        if st:
            out.append(c)
            if c == '\\' and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == st:
                st = None
        elif c in '"\'':
            st = c
            out.append(c)
        elif c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            # Un bloque sin cerrar NO se traga en silencio: `{a: 1} /*` dejaba
            # `{a: 1}`, que parsea, y el test daba verde sobre un json5 roto.
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            if i + 1 >= n:
                raise ValueError('comentario de bloque sin cerrar: falta `*/`')
            i += 2
            continue
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def cargar(path):
    with open(path, encoding='utf-8') as fh:
        src = sin_comentarios(fh.read())
    src = re.sub(r',\s*([}\]])', r'\1', src)  # comas colgantes
    # Llaves sin comillas: la regex exige `{` o `,` justo antes del nombre.
    # Limitación conocida (falla en rojo, nunca en verde): `a/*x*/b` se vuelve
    # `ab` (inocuo en JSON, que no distingue espacios), un `/*` sin cerrar
    # revienta con ValueError en `sin_comentarios` (antes se tragaba el resto y
    # dejaba un JSON recortado que parseaba: verde falso) y un `, b:` dentro de un string
    # con comillas dobles sí se reescribiría mal (los patches del repo no traen
    # texto libre con ese patrón; no reusar el util para esos archivos).
    src = re.sub(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_-]*)(\s*:)', r'\1"\2"\3', src)
    # Strings con comillas simples -> dobles (solo si no tienen dobles dentro).
    src = re.sub(r"'([^'\"\\]*)'", r'"\1"', src)
    return json.loads(src)

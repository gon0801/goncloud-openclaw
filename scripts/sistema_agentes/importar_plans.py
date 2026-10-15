"""Importador de filas de `Plans.md` a la entrada de `managed_roots_open` (SUA-02, diseño 4.7).

Es puro: `importar(texto, filas, repo_de_alcance, pedido)` recibe el texto de `Plans.md` y las
palabras de David y devuelve la entrada; `main` solo lee el archivo y el pedido, que llega por la
entrada estándar. Las reglas:

- Cada fila elegida es una unidad. `unitId` es el id de la fila. `title` es su entrega (la
  segunda columna) hasta el primer punto, sin las marcas `[...]` del inicio ni los `**`.
- `dependsOn` son las filas de su columna Depends que también se eligieron. Una dependencia que
  no se eligió y está cerrada (`cc:完了`) es un supuesto. Abierta, el importador falla: la raíz
  no puede esperar una fila que nadie va a hacer. Depends lleva ids, rangos (`6.0–6.8`, las filas
  del ledger entre los dos extremos), separadores (`,`, `;`, `y`), `-` y notas entre paréntesis.
  Cualquier otra cosa es una condición que el importador no sabe leer, y falla con ella.
- Elegir cero filas falla: un plan sin unidades es `plan-invalid` en R.
- Cada cláusula de la compuerta verificable (la tercera columna), separada por `;`, es un
  criterio literal con rol `verifier`, con id `<fila>-<n>`. Una celda puede llevar `\\|`: es un
  `|` del contenido, no un borde de columna.
- El texto del pedido son las palabras de David tal cual. Cada frase suya, partida con la regla
  de R (`requestSentences`), lleva un papel en la cobertura:
  - si es una frase de una cláusula de una fila elegida, es un criterio de esa cláusula;
  - si no, es una condición propia de David y se vuelve un criterio `<fila>-p<n>` (n es el
    número de la frase en el pedido) de cada fila elegida que nombra, o de todas si no nombra
    ninguna. Así ninguna condición suya se pierde. Si la frase solo pide las filas, `main` puede
    pasar su entrada a `context` y quitar sus criterios `-p<n>`.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

FILA = re.compile(r"^\|\s*(\d+\.\d+[a-z]?)\s*\|(.*)\|\s*$")
# Un `|` sin `\` antes es un borde de columna; `\|` es contenido.
BORDE = re.compile(r"(?<!\\)\|")
ID = re.compile(r"\d+\.\d+[a-z]?")
# Un rango `6.0–6.8` (raya o guion) o un id suelto, en el orden de la celda.
PIEZA = re.compile(r"(\d+\.\d+[a-z]?)\s*[–-]\s*(\d+\.\d+[a-z]?)|\d+\.\d+[a-z]?")
NOTA = re.compile(r"\([^)]*\)")
SIN_DEPENDENCIA = {"", "-", "—", "y"}
MARCAS = re.compile(r"^(?:\s*`[^`]*`)+\s*")
CERRADA = "cc:完了"
# La regla de R para partir el pedido en frases: un salto de línea, o un punto seguido de espacio.
FRASE = re.compile(r"\r?\n|(?<=\.)\s+")


class FilaAbierta(ValueError):
    """Una dependencia de una fila elegida está fuera de la selección y no está cerrada."""


class FilaMalFormada(ValueError):
    """Una fila que el importador necesita no tiene las cuatro columnas del ledger."""


class PedidoVacio(ValueError):
    """El pedido de David no trae ninguna frase."""


class SinFilas(ValueError):
    """La selección no trae ninguna fila."""


class DependenciaIlegible(ValueError):
    """La columna Depends de una fila elegida trae algo que no es una fila."""


def frases(texto: str) -> list[str]:
    """Las frases de un pedido, con la misma regla que `requestSentences` de R."""
    return [frase.strip() for frase in FRASE.split(texto) if frase.strip()]


def filas_de(texto: str) -> dict[str, list[str]]:
    """Las filas del ledger: su id y sus columnas, que en el ledger son entrega, compuerta,
    depends y estado. Si un id sale en varias tablas, gana su fila de cuatro columnas."""
    filas: dict[str, list[str]] = {}
    for linea in texto.splitlines():
        coincide = FILA.match(linea)
        if not coincide:
            continue
        columnas = [c.strip().replace("\\|", "|") for c in BORDE.split(coincide.group(2))]
        if len(filas.get(coincide.group(1), [])) != 4:
            filas[coincide.group(1)] = columnas
    return filas


def fila(filas: dict[str, list[str]], id_fila: str) -> list[str]:
    columnas = filas[id_fila]
    if len(columnas) != 4:
        raise FilaMalFormada(
            f"la fila {id_fila} tiene {len(columnas)} columnas y el ledger pide 4"
            " (entrega, compuerta, depends, estado); un | dentro de una celda va como \\|"
        )
    return columnas


def titulo(entrega: str) -> str:
    sin_marcas = MARCAS.sub("", entrega).replace("**", "").strip()
    return sin_marcas.split(".", 1)[0].strip()


def dependencias(id_fila: str, columna: str, orden: list[str]) -> list[str]:
    """Las filas de la columna Depends, en su orden y sin repetir. Un rango son las filas del
    ledger entre sus dos extremos, en el orden del ledger."""
    texto = NOTA.sub(" ", columna)
    ids: list[str] = []
    for pieza in PIEZA.finditer(texto):
        desde, hasta = pieza.group(1), pieza.group(2)
        if desde is None:
            ids.append(pieza.group(0))
        elif desde in orden and hasta in orden and orden.index(desde) <= orden.index(hasta):
            ids += orden[orden.index(desde) : orden.index(hasta) + 1]
        else:
            raise DependenciaIlegible(
                f"la fila {id_fila} depende del rango {pieza.group(0)}, que no está en Plans.md"
            )
    resto = [p for p in re.split(r"[,;\s]+", PIEZA.sub(" ", texto)) if p not in SIN_DEPENDENCIA]
    if resto:
        raise DependenciaIlegible(
            f"la fila {id_fila} depende de algo que no es una fila: {columna.strip()}"
        )
    return list(dict.fromkeys(ids))


def clausulas(compuerta: str) -> list[str]:
    return [parte.strip() for parte in compuerta.split(";") if parte.strip()]


def importar(texto: str, elegidas: list[str], repo_de_alcance: str, pedido: str) -> dict:
    """La entrada de `managed_roots_open` para esas filas y el pedido de David: pedido, cobertura
    y plan."""
    if not elegidas:
        raise SinFilas("no se eligió ninguna fila")
    filas = filas_de(texto)
    faltan = [id_fila for id_fila in elegidas if id_fila not in filas]
    if faltan:
        raise KeyError(f"Plans.md no tiene la fila {faltan[0]}")
    del_pedido = frases(pedido)
    if not del_pedido:
        raise PedidoVacio("el pedido de David está vacío")
    unidades = []
    supuestos = []
    de_clausula: dict[str, list[str]] = {}
    for id_fila in elegidas:
        entrega, compuerta, depende, _estado = fila(filas, id_fila)
        de_la_seleccion = []
        for anterior in dependencias(id_fila, depende, list(filas)):
            if anterior in elegidas:
                de_la_seleccion.append(anterior)
            elif anterior in filas and CERRADA in fila(filas, anterior)[3]:
                supuesto = f"La fila {anterior} está cerrada."
                if supuesto not in supuestos:
                    supuestos.append(supuesto)
            else:
                raise FilaAbierta(f"la fila {id_fila} depende de {anterior}, que no está cerrada")
        criterios = []
        for numero, clausula in enumerate(clausulas(compuerta), start=1):
            criterio = f"{id_fila}-{numero}"
            criterios.append({"criterionId": criterio, "text": clausula, "verifier": "verifier"})
            for frase in frases(clausula):
                de_clausula.setdefault(frase, [])
                if criterio not in de_clausula[frase]:
                    de_clausula[frase].append(criterio)
        unidades.append(
            {
                "unitId": id_fila,
                "title": titulo(entrega),
                "dependsOn": de_la_seleccion,
                "criteria": criterios,
                "scope": {"repos": [repo_de_alcance], "mode": "implement"},
            }
        )
    por_fila = {unidad["unitId"]: unidad for unidad in unidades}
    cobertura = []
    for numero, frase in enumerate(del_pedido, start=1):
        if any(entrada["sentence"] == frase for entrada in cobertura):
            continue
        ids = de_clausula.get(frase)
        if ids is None:
            nombradas = [id_fila for id_fila in elegidas if id_fila in ID.findall(frase)]
            ids = []
            for id_fila in nombradas or elegidas:
                criterio = f"{id_fila}-p{numero}"
                por_fila[id_fila]["criteria"].append(
                    {"criterionId": criterio, "text": frase, "verifier": "verifier"}
                )
                ids.append(criterio)
        cobertura.append({"sentence": frase, "role": "criterion", "criterionIds": ids})
    return {
        "request": {"text": pedido, "coverage": cobertura},
        "plan": {"units": unidades, "assumptions": supuestos},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="el repo cuyo Plans.md se lee")
    parser.add_argument("--filas", required=True, help="ids de fila separados por coma")
    parser.add_argument("--alcance", required=True, help="el repo de la autoridad, owner/nombre")
    args = parser.parse_args(argv)
    elegidas = [id_fila.strip() for id_fila in args.filas.split(",") if id_fila.strip()]
    ruta = Path(args.repo) / "Plans.md"
    try:
        texto = ruta.read_text(encoding="utf-8")
        # El pedido de David llega por la entrada estándar, tal cual: ni comillas ni escapes.
        entrada = importar(texto, elegidas, args.alcance, sys.stdin.read())
    except OSError as error:
        print(
            json.dumps(
                {"ok": False, "error": f"no se puede leer {ruta}: {error.strerror}"},
                ensure_ascii=False,
            )
        )
        return 3
    except (KeyError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error).strip("'")}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": True, **entrada}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

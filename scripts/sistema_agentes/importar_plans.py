"""Importador de filas de `Plans.md` a la entrada de `managed_roots_open` (SUA-02, diseño 4.7).

Es puro: `importar(texto, filas, repo_de_alcance)` recibe el texto de `Plans.md` y devuelve la
entrada; `main` solo lee el archivo. Las reglas:

- Cada fila elegida es una unidad. `unitId` es el id de la fila. `title` es su entrega (la
  segunda columna) hasta el primer punto, sin las marcas `[...]` del inicio ni los `**`.
- `dependsOn` son las filas de su columna Depends que también se eligieron. Una dependencia que
  no se eligió y está cerrada (`cc:完了`) es un supuesto. Abierta, el importador falla: la raíz
  no puede esperar una fila que nadie va a hacer.
- Cada cláusula de la compuerta verificable (la tercera columna), separada por `;`, es un
  criterio literal con rol `verifier`, con id `<fila>-<n>`.
- El texto del pedido son las cláusulas tal cual, una por línea. La cobertura sale sola: cada
  frase del texto, partida con la regla de R (`requestSentences`), es un criterio de su fila.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

FILA = re.compile(r"^\|\s*(\d+\.\d+[a-z]?)\s*\|(.*)\|\s*$")
MARCAS = re.compile(r"^(?:\s*`[^`]*`)+\s*")
CERRADA = "cc:完了"
# La regla de R para partir el pedido en frases: un salto de línea, o un punto seguido de espacio.
FRASE = re.compile(r"\r?\n|(?<=\.)\s+")


class FilaAbierta(ValueError):
    """Una dependencia de una fila elegida está fuera de la selección y no está cerrada."""


def frases(texto: str) -> list[str]:
    """Las frases de un pedido, con la misma regla que `requestSentences` de R."""
    return [frase.strip() for frase in FRASE.split(texto) if frase.strip()]


def filas_de(texto: str) -> dict[str, list[str]]:
    """Las filas del ledger: su id y sus columnas entrega, compuerta, depends y estado."""
    filas: dict[str, list[str]] = {}
    for linea in texto.splitlines():
        coincide = FILA.match(linea)
        if not coincide:
            continue
        columnas = [columna.strip() for columna in coincide.group(2).split("|")]
        if len(columnas) == 4:
            filas[coincide.group(1)] = columnas
    return filas


def titulo(entrega: str) -> str:
    sin_marcas = MARCAS.sub("", entrega).replace("**", "").strip()
    return sin_marcas.split(".", 1)[0].strip()


def dependencias(columna: str) -> list[str]:
    partes = re.split(r"[,\s]+", columna)
    return [parte for parte in partes if re.fullmatch(r"\d+\.\d+[a-z]?", parte)]


def clausulas(compuerta: str) -> list[str]:
    return [parte.strip() for parte in compuerta.split(";") if parte.strip()]


def importar(texto: str, elegidas: list[str], repo_de_alcance: str) -> dict:
    """La entrada de `managed_roots_open` para esas filas: pedido, cobertura y plan."""
    filas = filas_de(texto)
    faltan = [fila for fila in elegidas if fila not in filas]
    if faltan:
        raise KeyError(f"Plans.md no tiene la fila {faltan[0]}")
    unidades = []
    supuestos = []
    lineas = []
    cobertura: dict[str, list[str]] = {}
    for fila in elegidas:
        entrega, compuerta, depende, _estado = filas[fila]
        de_la_seleccion = []
        for anterior in dependencias(depende):
            if anterior in elegidas:
                de_la_seleccion.append(anterior)
            elif anterior in filas and CERRADA in filas[anterior][3]:
                supuesto = f"La fila {anterior} está cerrada."
                if supuesto not in supuestos:
                    supuestos.append(supuesto)
            else:
                raise FilaAbierta(f"la fila {fila} depende de {anterior}, que no está cerrada")
        criterios = []
        for numero, clausula in enumerate(clausulas(compuerta), start=1):
            criterio = f"{fila}-{numero}"
            criterios.append({"criterionId": criterio, "text": clausula, "verifier": "verifier"})
            lineas.append(clausula)
            for frase in frases(clausula):
                cobertura.setdefault(frase, [])
                if criterio not in cobertura[frase]:
                    cobertura[frase].append(criterio)
        unidades.append(
            {
                "unitId": fila,
                "title": titulo(entrega),
                "dependsOn": de_la_seleccion,
                "criteria": criterios,
                "scope": {"repos": [repo_de_alcance], "mode": "implement"},
            }
        )
    return {
        "request": {
            "text": "\n".join(lineas),
            "coverage": [
                {"sentence": frase, "role": "criterion", "criterionIds": ids}
                for frase, ids in cobertura.items()
            ],
        },
        "plan": {"units": unidades, "assumptions": supuestos},
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="el repo cuyo Plans.md se lee")
    parser.add_argument("--filas", required=True, help="ids de fila separados por coma")
    parser.add_argument("--alcance", required=True, help="el repo de la autoridad, owner/nombre")
    args = parser.parse_args(argv)
    texto = (Path(args.repo) / "Plans.md").read_text(encoding="utf-8")
    elegidas = [fila.strip() for fila in args.filas.split(",") if fila.strip()]
    try:
        entrada = importar(texto, elegidas, args.alcance)
    except (KeyError, FilaAbierta) as error:
        print(json.dumps({"ok": False, "error": str(error).strip("'")}, ensure_ascii=False))
        return 3
    print(json.dumps({"ok": True, **entrada}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

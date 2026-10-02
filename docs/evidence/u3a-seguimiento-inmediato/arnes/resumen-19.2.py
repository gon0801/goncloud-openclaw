#!/usr/bin/env python3
"""Resumen de las transiciones del arnes 19.2 a partir de los JSONL del work.

Entrada: <work> (fin-*.jsonl, ini-*.jsonl, lanzados.txt) y el anillo de CLIs.
lanzados.txt NO lleva cabecera a proposito (la rechaza el doc-check de CI);
cada linea es `<stamp UTC> <sesion> <cli>` y este resumidor la lee sin
esperar encabezados (F3 19.8).
Salida: JSON con la tabla por transicion, conteo/mediana/maximo/cumplen, la
cobertura por CLI (finalizaciones y destinos) y los faltantes. El umbral de
30 s es el de la DoD; cambiarlo aqui cambia los veredictos (y la prueba
focalizada lo vigila).
"""
import glob
import json
import os
import statistics
import sys

work = sys.argv[1]
ANILLO = ["zcode", "codex", "kimi", "grok", "claude"]
UMBRAL_S = 30.0
if len(sys.argv) > 2:
    UMBRAL_S = float(sys.argv[2])

def filas(ruta):
    out = []
    if not os.path.isfile(ruta):
        return out
    with open(ruta) as f:
        for linea in f:
            linea = linea.strip()
            if linea:
                try:
                    out.append(json.loads(linea))
                except ValueError:
                    pass
    return out

def primero(ruta, ev):
    for r in filas(ruta):
        if r["ev"] == ev:
            return r
    return None

lanzados = []
ruta_l = os.path.join(work, "lanzados.txt")
if os.path.isfile(ruta_l):
    with open(ruta_l) as f:
        lanzados = [ln.split()[-2] for ln in f if ln.strip() and not ln.strip().startswith('#')]
total_workers = len(lanzados)
n_trans = max(0, total_workers - 1)

# F1 (C2-r1): la N PEDIDA vive en exigidas.txt; una cadena con menos
# trabajadores que N es INCOMPLETA aunque las transiciones que alcanzo sean
# todas OK. El veredicto del bloque compara cumplen contra la N pedida.
exigidas = None
ruta_e = os.path.join(work, "exigidas.txt")
if os.path.isfile(ruta_e):
    with open(ruta_e) as f:
        try:
            exigidas = int(f.read().strip())
        except ValueError:
            exigidas = None

# CLIs REALES por slot (slot-cli.txt): con fallback de lanzamiento el indice no
# determina el CLI; la tabla usa lo que de verdad quedo lanzado.
slot_cli = {}
ruta_s = os.path.join(work, "slot-cli.txt")
if os.path.isfile(ruta_s):
    with open(ruta_s) as f:
        for linea in f:
            partes = linea.split()
            if len(partes) == 2:
                slot_cli[int(partes[0])] = partes[1]

def cli_de(idx):
    return slot_cli.get(idx, "sin-lanzar")

tabla = []
for k in range(1, total_workers):
    fin = primero(os.path.join(work, "fin-%d.jsonl" % (k - 1)), "fin")
    ini = primero(os.path.join(work, "ini-%d.jsonl" % k), "sesion-viva")
    act = primero(os.path.join(work, "ini-%d.jsonl" % k), "actividad")
    fila = {
        "transicion": k,
        "de": cli_de(k - 1), "a": cli_de(k),
        "fin_wall": fin["wall"] if fin else None,
        "inicio_wall": ini["wall"] if ini else None,
        "actividad_wall": act["wall"] if act else None,
    }
    if fin and ini:
        d = round((ini["mono_ns"] - fin["mono_ns"]) / 1e9, 2)
        fila["duracion_s"] = d
        fila["umbral_s"] = UMBRAL_S
        fila["veredicto"] = "OK" if d < UMBRAL_S else "TARDIO"
    elif fin and act:
        d = round((act["mono_ns"] - fin["mono_ns"]) / 1e9, 2)
        fila["duracion_s"] = d
        fila["umbral_s"] = UMBRAL_S
        fila["veredicto"] = "OK-SIN-VIVA" if d < UMBRAL_S else "TARDIO"
    else:
        fila["duracion_s"] = None
        fila["veredicto"] = "SIN-DATOS"
        if fin is None:
            fila["nota"] = "el trabajador %d no completo su resultado" % (k - 1)
        else:
            fila["nota"] = "el trabajador %d no mostro sesion viva" % k
    tabla.append(fila)

duraciones = [t["duracion_s"] for t in tabla if isinstance(t.get("duracion_s"), (int, float))]
ok = [t for t in tabla if t.get("veredicto") in ("OK", "OK-SIN-VIVA")]
fines_cli = {}
destinos_cli = {}
for t in tabla:
    fines_cli[t["de"]] = fines_cli.get(t["de"], 0) + 1
    destinos_cli[t["a"]] = destinos_cli.get(t["a"], 0) + 1
faltan_fin = [c for c in ANILLO if fines_cli.get(c, 0) < 2]
faltan_dest = [c for c in ANILLO if destinos_cli.get(c, 0) < 1]

resumen = {
    "umbral_s": UMBRAL_S,
    "transiciones_exigidas": exigidas if exigidas is not None else n_trans,
    "cadena_incompleta": exigidas is not None and total_workers < exigidas + 1,
    "transiciones_con_datos": len(duraciones),
    "cumplen": len(ok),
    "mediana_s": round(statistics.median(duraciones), 2) if duraciones else None,
    "maximo_s": round(max(duraciones), 2) if duraciones else None,
    "minimo_s": round(min(duraciones), 2) if duraciones else None,
    "tardios_o_sin_datos": [t for t in tabla if t["veredicto"] not in ("OK", "OK-SIN-VIVA")],
    "finalizaciones_por_cli": fines_cli,
    "destinos_por_cli": destinos_cli,
    "cobertura_incompleta": {"menos_de_2_finalizaciones": faltan_fin, "sin_destino": faltan_dest},
    "tabla": tabla,
}
print(json.dumps(resumen, indent=1, ensure_ascii=False))

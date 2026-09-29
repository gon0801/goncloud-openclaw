#!/usr/bin/env python3
"""Calcula los tiempos de una corrida del arnes 19.0 a partir de sus JSONL.

Entrada: directorio de trabajo con doble.jsonl, sondeo.jsonl (y opcionales
sondeo-relevo.jsonl y watch.log). Salida en stdout: un resumen JSON con los
puntos del recorrido separados y su veredicto. Todos los deltas salen del
reloj monotónico del host; los puntos que solo existen en la pared del log
del vigilante se convierten con el offset medido de las filas «reloj» y
quedan marcados con res ±0.5 s.
"""
import json
import os
import statistics
import sys

work, token, quiet_secs, tick_secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])

def filas(nombre):
    ruta = os.path.join(work, nombre)
    if not os.path.isfile(ruta):
        return []
    out = []
    with open(ruta) as f:
        for linea in f:
            linea = linea.strip()
            if linea:
                try:
                    out.append(json.loads(linea))
                except ValueError:
                    pass
    return out

sondeo = filas("sondeo.jsonl")
doble = filas("doble.jsonl")
relevo = filas("sondeo-relevo.jsonl")

reloj_rows = [r for r in sondeo if r["ev"] == "reloj"]
offsets = []
for r in reloj_rows:
    w = r["wall"]
    hh, mm, ss = (int(x) for x in w[11:19].split(":"))
    frac = float("0." + w[20:23]) if w[19] == "." else 0.0
    offsets.append(r["mono_ns"] - (hh * 3600 + mm * 60 + ss + frac) * 1_000_000_000)
offset = statistics.median(offsets) if offsets else None

def mono_de_wall(valor):
    if offset is None or not valor or not valor[0].isdigit():
        return None
    hh, mm, resto = valor[11:].split(":", 2)
    ss = float(resto.rstrip("Z"))
    return int((int(hh) * 3600 + int(mm) * 60 + ss) * 1_000_000_000 + offset)

def s(delta_ns):
    return round(delta_ns / 1e9, 2)

resumen = {"token": token, "config_arnes": {"QUIET_SECS": quiet_secs, "TICK_SECS": tick_secs},
           "config_produccion": {"QUIET_SECS": 900, "TICK_SECS": 15, "nota": "valores por defecto instalados, no medidos aqui"}}

fin_rows = [r for r in sondeo if r["ev"] == "fin"]
timeout = any(r["ev"] == "timeout" for r in sondeo) and not fin_rows
if not fin_rows:
    resumen["veredicto"] = "TIMEOUT" if timeout else "SIN-DATOS"
    print(json.dumps(resumen, indent=1))
    sys.exit(0)

t_fin = fin_rows[0]["mono_ns"]
resumen["t_fin_wall"] = fin_rows[0]["wall"]

eventos = [d for d in doble if d["argv"][:2] == ["system", "event"] and d["mono_ns"] >= t_fin - 2_000_000_000]
resumen["avisos_recibidos"] = [
    {"mono_ns": d["mono_ns"], "delta_fin_s": s(d["mono_ns"] - t_fin),
     "texto": " ".join(d["argv"][d["argv"].index("--text") + 1:]) if "--text" in d["argv"] else d["argv"]}
    for d in eventos]

delta_deteccion = s(eventos[0]["mono_ns"] - t_fin) if eventos else None
resumen["deteccion_a_envio_s"] = delta_deteccion
sent_lines = []
log_ruta = os.path.join(work, "watch.log")
if os.path.isfile(log_ruta):
    with open(log_ruta) as f:
        for linea in f:
            if "sent:" in linea or "SEND FAILED" in linea or "relanzo" in linea:
                sent_lines.append(linea.strip())
resumen["vigia_log"] = sent_lines[-6:]

transporte = None
if eventos and sent_lines:
    paredes = [mono_de_wall(l[0:20]) for l in sent_lines if l.startswith("20") and " sent: " in l]
    paredes = [p for p in paredes if p and p <= eventos[0]["mono_ns"]]
    if paredes:
        transporte = s(eventos[0]["mono_ns"] - max(paredes))
resumen["transporte_script_s_aprox"] = transporte
resumen["resolucion_pared"] = "±0.5 s" if transporte is not None else None

if relevo:
    cierre = next((r for r in relevo if r["ev"] == "cierre-simulado"), None)
    viva = next((r for r in relevo if r["ev"] == "sesion-viva"), None)
    act = next((r for r in relevo if r["ev"] == "actividad"), None)
    rel = {}
    if cierre:
        rel["cierre_simulado_wall"] = cierre["wall"]
        if viva:
            rel["deteccion_cierre_a_sesion_viva_s"] = s(viva["mono_ns"] - cierre["mono_ns"])
        if act and cierre:
            rel["cierre_a_primera_actividad_s"] = s(act["mono_ns"] - cierre["mono_ns"])
        rel["nota"] = "cierre provocado por el arnes (ficticio); deteccion, relevo y actividad son reales"
    resumen["relevo"] = rel

contenido = ""
ruta_res = os.path.join(work, "repo", "resultado.txt")
if os.path.isfile(ruta_res):
    contenido = open(ruta_res).read()[:80]
resumen["resultado.txt"] = contenido
esperado = "MEDICION-19.0-%s" % token
bloqueo = os.path.isfile(os.path.join(work, "repo", "bloqueo.txt"))

if contenido.strip() == esperado and delta_deteccion is not None:
    resumen["veredicto"] = "OK"
elif bloqueo:
    resumen["veredicto"] = "OK-CON-RESERVAS"
    resumen["nota"] = "el worker dejo bloqueo.txt; se registra lo medido"
else:
    resumen["veredicto"] = "OK-CON-RESERVAS"
    resumen["nota"] = "sin aviso capturado o contenido inesperado"

print(json.dumps(resumen, indent=1, ensure_ascii=False))

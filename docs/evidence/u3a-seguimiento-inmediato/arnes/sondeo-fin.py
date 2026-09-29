#!/usr/bin/env python3
"""Sondeo del arnes 19.0: fecha el fin del trabajador y la actividad del sucesor.

Escribe un JSONL por evento con reloj monotónico y pared del mismo host:
  reloj       cada 2 s (para correlacionar pared con monotónico)
  fin         <resultado> completo y cola del panel estable en 3 sondeos seguidos
  sesion-viva primera vez que la sesión existe (modo --actividad)
  actividad   primer cambio de la cola del panel tras sesion-viva
  timeout     al vencer --tope sin fin
Uso: sondeo-fin.py <socket> <sesion> <resultado> <salida.jsonl> [--tope s] [--actividad]
"""
import json
import os
import subprocess
import sys
import time

socket, sesion, resultado, salida = sys.argv[1:5]
tope = 240.0
quiere_actividad = "--actividad" in sys.argv[5:]
if "--tope" in sys.argv[5:]:
    tope = float(sys.argv[sys.argv.index("--tope") + 1])

def tmux(*a):
    return subprocess.run(["/opt/homebrew/bin/tmux", "-L", socket] + list(a),
                          capture_output=True, text=True)

def fila(ev, **extra):
    d = {"ev": ev, "mono_ns": time.monotonic_ns(),
         "wall": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
         + ".%03dZ" % (int(time.time() * 1000) % 1000)}
    d.update(extra)
    with open(salida, "a") as f:
        f.write(json.dumps(d) + "\n")

cola_previa = None
cola_estable = 0
fin_dado = False
sesion_vista = False
actividad_dada = False
ultimo_reloj = 0.0
inicio = time.monotonic()
while time.monotonic() - inicio < tope:
    ahora = time.monotonic()
    if ahora - ultimo_reloj >= 2.0:
        ultimo_reloj = ahora
        fila("reloj")
    captura = tmux("capture-pane", "-p", "-t", "=%s:" % sesion)
    vivo = captura.returncode == 0
    cola = captura.stdout[-2000:] if vivo else None
    if vivo and not sesion_vista:
        sesion_vista = True
        fila("sesion-viva")
        cola_previa = None
        cola_estable = 0
    if (sesion_vista and quiere_actividad and not actividad_dada
            and cola_previa is not None and cola != cola_previa):
        actividad_dada = True
        fila("actividad")
    if cola is not None:
        if cola == cola_previa:
            cola_estable += 1
        else:
            cola_estable = 0
        cola_previa = cola
    if not fin_dado and os.path.isfile(resultado):
        with open(resultado, "rb") as f:
            datos = f.read()
        if datos and cola_estable >= 3:
            fin_dado = True
            fila("fin", bytes=len(datos))
    if fin_dado and not quiere_actividad:
        break
    if quiere_actividad and actividad_dada:
        break
    time.sleep(0.5)
if not fin_dado:
    fila("timeout")

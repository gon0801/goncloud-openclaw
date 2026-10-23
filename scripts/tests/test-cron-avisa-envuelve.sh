#!/bin/bash
# Prueba scripts/gonserver/cron-avisa-envuelve.py contra una copia sin secretos de los crontabs
# reales del servidor (root, gon y /etc/cron.d, leídos el 2026-10-22) en
# scripts/tests/fixtures/cron-avisa-envuelve/, más casos sintéticos de bordes.
# Uso: bash scripts/tests/test-cron-avisa-envuelve.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
[ -f scripts/gonserver/cron-avisa-envuelve.py ] || { echo "FAIL: falta cron-avisa-envuelve.py"; exit 1; }

python3 -I - "$PWD" <<'PY'
import importlib.util
import os
import re
import shlex
import subprocess
import sys

raiz = sys.argv[1]
spec = importlib.util.spec_from_file_location("envuelve", f"{raiz}/scripts/gonserver/cron-avisa-envuelve.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
FX = f"{raiz}/scripts/tests/fixtures/cron-avisa-envuelve"

fallos = []


def check(cond, msg):
    if not cond:
        fallos.append(msg)


def leer(ruta):
    with open(ruta) as f:
        return f.read()


destinos = {"usuario:root": leer(f"{FX}/root.crontab"), "usuario:gon": leer(f"{FX}/gon.crontab")}
for nombre in sorted(os.listdir(f"{FX}/cron.d")):
    destinos[f"cron.d:{nombre}"] = leer(f"{FX}/cron.d/{nombre}")


def es_tarea(linea, cron_d):
    return m._partir(linea, cron_d) is not None


def sin_fragmento(comando):
    return not any(f in comando for f, _ in m.NO_ENVOLVER)


def bash_acepta(texto):
    r = subprocess.run(["bash", "-n"], input=texto, capture_output=True, text=True)
    return r.returncode == 0, r.stderr


# 0. la copia no trae secretos
for d, t in destinos.items():
    check(
        not re.search(r"(?i)(token|secret|passw\w*|api_?key)\s*=\s*\S{6,}|\b[0-9a-f]{32,}\b|\b\d{8,}:[\w-]{30,}", t),
        f"{d}: la copia parece traer un secreto",
    )

# 1. cada línea de NO_ENVOLVER queda igual, todas las demás quedan envueltas
usados = set()
envueltas_total = 0
nombres_cada = {}
for d, texto in destinos.items():
    cron_d = d.startswith("cron.d:")
    nuevo = m.envuelve(texto, d)
    if cron_d and "." in d.split(":", 1)[1]:
        check(nuevo == texto, f"{d}: un archivo con punto en el nombre debe quedar intacto")
        check(
            any(es_tarea(x, True) for x in texto.splitlines()) or d.endswith(".placeholder"),
            f"{d}: la copia ya no prueba el caso del punto",
        )
        continue
    esperadas = []
    for linea in texto.splitlines():
        partes = m._partir(linea, cron_d)
        if partes is None:
            esperadas.append(linea)
            continue
        if any(f in partes[2] for f, _ in m.NO_ENVOLVER):
            usados.update(f for f, _ in m.NO_ENVOLVER if f in partes[2])
            esperadas.append(linea)
        else:
            esperadas.append(None)
    salida = nuevo.splitlines()
    check(len(salida) == len(esperadas), f"{d}: se esperaban {len(esperadas)} líneas y salieron {len(salida)}")
    for obtenida, esperada in zip(salida, esperadas):
        partes = m._partir(obtenida, cron_d)
        if esperada is None:
            check(
                partes is not None and partes[2].startswith(m.AVISA + " "),
                f"{d}: línea activa sin envolver: {obtenida[:90]}",
            )
            envueltas_total += 1
        else:
            check(obtenida == esperada, f"{d}: una línea que no se envuelve cambió: {esperada[:90]}")

    # 2. idempotente
    check(m.envuelve(nuevo, d) == nuevo, f"{d}: correrlo dos veces cambia el resultado")
    check(m.transforma(nuevo, d)[1:] == (0, 0), f"{d}: la segunda corrida envolvió o quitó algo")

    # 3. bash -n acepta cada comando envuelto, y es el comando original
    for linea in nuevo.splitlines():
        partes = m._partir(linea, cron_d)
        if partes is None or not partes[2].startswith(m.AVISA + " "):
            continue
        toks = shlex.split(partes[2].replace("\\%", "%"))
        i = toks.index("-c")
        cmd = toks[i + 1]
        ok, err = bash_acepta(cmd)
        check(ok, f"{d}: bash -n rechaza {cmd[:70]}: {err}")
        check(toks[1] == "--nombre" and toks[3] == "--cada", f"{d}: forma rara: {partes[2][:90]}")
        check(toks[i - 2 : i] == ["--", "/bin/bash"], f"{d}: falta '-- /bin/bash -c'")
        nombre, cada = toks[2], toks[4]
        check(nombre and '"' not in nombre, f"{d}: frase vacía o con comillas")
        check(nombres_cada.setdefault(nombre, cada) == cada, f"{nombre}: dos --cada distintos")
        original = cmd.replace("flock -n -E 75", "flock -n")
        check(original in texto.replace("\\%", "%"), f"{d}: el comando envuelto no es el original: {cmd[:70]}")
        if "flock -n" in original:
            check("flock -n -E 75" in cmd, f"{d}: flock -n sin -E 75")

check(envueltas_total >= 40, f"se envolvieron solo {envueltas_total} líneas de la copia real")
for fragmento, motivo in m.NO_ENVOLVER:
    check(motivo.strip(), f"NO_ENVOLVER {fragmento}: sin motivo")
    check(fragmento in usados, f"NO_ENVOLVER {fragmento}: ninguna línea de la copia real lo usa")

# 5. bordes sintéticos
def una(linea, destino="usuario:gon"):
    return m.envuelve(linea + "\n", destino).rstrip("\n")


def cmd_de(linea):
    toks = shlex.split(linea.replace("\\%", "%"))
    return toks[toks.index("-c") + 1]


s = una("0 3 * * * /usr/bin/flock -n /tmp/x.lock docker exec orbit-app-1 python -m app.cli bloqueo-reconcilia >> /l 2>&1")
check("flock -n -E 75 /tmp/x.lock" in s and s.endswith(">> /l 2>&1"), f"flock/redirección: {s}")
dos = "0 3 * * * /usr/bin/flock -n -E 75 /tmp/x.lock bloqueo-reconcilia >> /l 2>&1"
check(una(dos).count("-E 75") == 1, "flock -E 75 ya puesto no se duplica")

s = una("0 3 * * * /bin/odoo_backup.sh --dia $(date +\\%F) >> /l 2>&1")
check("date +\\%F" in s and bash_acepta(cmd_de(s))[0], f"% escapado: {s}")
s = una("0 3 * * * /bin/odoo_backup.sh >> /l 2>&1 % entrada")
check(s.endswith(">> /l 2>&1 % entrada") and "entrada" not in cmd_de(s), f"% sin escapar: {s}")
s = una("0 3 * * * echo 'hola mundo' # odoo_backup.sh")
check(bash_acepta(cmd_de(s))[0] and cmd_de(s).startswith("echo 'hola"), f"comillas simples: {s}")
s = una("0 3 * * * echo 'hola' ; /bin/odoo_backup.sh 2>/dev/null")
check(s.endswith(" 2>/dev/null") and cmd_de(s) == "echo 'hola' ; /bin/odoo_backup.sh", f"2>/dev/null: {s}")
s = una("0 * * * * set -a; /bin/odoo_backup.sh >> /l 2>&1 && date -Is > /ok.txt")
check(
    cmd_de(s) == "set -a; /bin/odoo_backup.sh >> /l 2>&1 && date -Is > /ok.txt" and s.endswith("/ok.txt'"),
    f"comando compuesto con su propio >: {s}",
)
ya = '0 3 * * * /usr/local/bin/cron-avisa --nombre "Respaldo de Odoo" --cada 24 -- /bin/bash -c \'/x/odoo_backup.sh\' >> /l 2>&1'
check(una(ya) == ya, "una línea ya envuelta se vuelve a envolver")
check(
    una("0 3 * * * root /x/odoo_backup.sh >> /l 2>&1", "cron.d:odoo.bak") == "0 3 * * * root /x/odoo_backup.sh >> /l 2>&1",
    "un archivo de cron.d con punto debe ignorarse",
)
s = una("0\t3\t*\t*\t*\troot\t/x/odoo_backup.sh >> /l 2>&1", "cron.d:odoo")
check(s.startswith("0\t3\t*\t*\t*\troot\t/usr/local/bin/cron-avisa "), f"cron.d con tabuladores y usuario: {s}")
for neutro in ("MAILTO=gon", "SHELL=/bin/bash", "# 0 3 * * * /x/odoo_backup.sh", "", "   "):
    check(una(neutro) == neutro, f"debe quedar igual: {neutro!r}")
try:
    una("0 3 * * * /x/algo_nuevo.sh >> /l 2>&1")
    check(False, "una línea sin frase debe fallar")
except m.SinFrase:
    pass

for horario, cada, tras in (
    ("0 * * * *", 1, False),
    ("*/15 * * * *", 1, True),
    ("*/30 * * * *", 1, True),
    ("*/2 * * * *", 1, True),
    ("17 * * * *", 1, False),
    ("0 */4 * * *", 6, False),
    ("0 */6 * * *", 6, False),
    ("0 3 * * *", 24, False),
    ("10 15-23/2 * * *", 24, False),
    ("30 9,21 * * *", 24, False),
    ("*/10 10-12 * * *", 24, True),
    ("0 3 * * 0", 168, False),
    ("0 8 * * 1", 168, False),
    ("0 4 1 * *", 720, False),
    ("@hourly", 1, False),
    ("@daily", 24, False),
    ("@weekly", 168, False),
    ("@monthly", 720, False),
):
    s = una(f"{horario} /x/odoo_backup.sh >> /l 2>&1")
    check(f"--cada {cada} " in s, f"{horario}: se esperaba --cada {cada}: {s}")
    check((" --tras 3 " in s) == tras, f"{horario}: --tras 3 {'falta' if tras else 'sobra'}")

if fallos:
    print("\n".join(f"FAIL: {f}" for f in fallos))
    sys.exit(1)
print(f"OK: test-cron-avisa-envuelve ({envueltas_total} líneas reales envueltas, {len(destinos)} archivos)")
PY

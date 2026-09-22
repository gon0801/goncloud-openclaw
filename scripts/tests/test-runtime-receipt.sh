#!/bin/bash
# Contrato portable del recibo de separacion del runtime (Task 1 / 16.1).
#
# El recibo es la prueba versionada de cada transicion reanudable: quien corre
# que, con que entradas (por hash, nunca por valor), que observo y como se
# revierte. Tres dueños comparten las reglas:
#
#   docs/spec/runtime-separation-receipt.v1.schema.json  normativo (required[] y
#     los dos patrones x-secret* que ESTE test lee: paridad estructural)
#   scripts/runtime-separation/RuntimeSeparation.psm1    aplicacion en Windows
#     (Test-ReceiptObject; el mismo literal, fijado por grep en (4))
#   este archivo                                        espejo portable (el
#     validador python de abajo) + contrato CI de la Task 1
#
# La conducta del .psm1 se prueba de verdad en el job windows-contract (vease
# test-runtime-layout.sh): Linux no finge ser Windows.
#
# Uso: bash scripts/tests/test-runtime-receipt.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }
SCHEMA=docs/spec/runtime-separation-receipt.v1.schema.json
MODULO=scripts/runtime-separation/RuntimeSeparation.psm1

# (0) El contrato normativo existe y es JSON parseable.
[ -f "$SCHEMA" ] || fail "(0) falta $SCHEMA"
PYBIN=$(command -v python3 || command -v python) || fail "(0) sin python3 ni python en PATH"
"$PYBIN" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$SCHEMA" \
  || fail "(0) $SCHEMA no es JSON parseable"
echo "ok (0): el schema existe y parsea"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# (1) El schema declara EXACTAMENTE las 13 claves obligatorias del plan
# (Step 1: schema, phase, UTC start/end, sourceSha, host, OpenClaw version,
# commands con exits, hashed inputs, observations, health, resultado,
# rollback con artefacto y deadline). Exacto en ambas direcciones: una clave
# de mas o de menos es deriva del contrato.
"$PYBIN" - "$SCHEMA" <<'PY' || exit 1
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
want = {"schema", "phase", "startedAt", "endedAt", "sourceSha", "host",
        "openclawVersion", "commands", "inputs", "observations", "health",
        "result", "rollback"}
got = set(schema.get("required", []))
if got != want:
    print(f"ROJO: (1) required[] del schema deriva: falta={sorted(want - got)} sobra={sorted(got - want)}")
    sys.exit(1)
if schema.get("type") != "object" or schema.get("additionalProperties") is not False:
    print("ROJO: (1) el schema debe ser object con additionalProperties=false (fail-closed)")
    sys.exit(1)
for campo in ("x-secretKeyPattern", "x-secretValuePattern"):
    if not schema.get(campo):
        print(f"ROJO: (1) el schema no declara {campo}")
        sys.exit(1)
PY
echo "ok (1): required[] exacto, objeto cerrado y patrones x-secret* declarados"

# --- espejo portable: valida un recibo contra el schema real ---
cat >"$T/validate.py" <<'PY'
import json, re, sys

SCHEMA_PATH, RECEIPT_PATH = sys.argv[1], sys.argv[2]
schema = json.load(open(SCHEMA_PATH, encoding="utf-8"))
try:
    doc = json.load(open(RECEIPT_PATH, encoding="utf-8"))
except Exception as e:
    print(f"rechazado: recibo no es JSON ({e})")
    sys.exit(1)

rx_key = re.compile(schema["x-secretKeyPattern"])
rx_val = re.compile(schema["x-secretValuePattern"])
UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")
VER = re.compile(r"^\d{4}\.\d+\.\d+$")
FASE = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3})?$")

bad = []
def no(caso):
    bad.append(caso)

if not isinstance(doc, dict):
    print("rechazado: el recibo no es un objeto")
    sys.exit(1)
want = set(schema["required"])
got = set(doc)
for k in sorted(want - got):
    no(f"falta clave obligatoria: {k}")
for k in sorted(got - want):
    no(f"clave fuera de contrato: {k}")

def es_txt(v):
    return isinstance(v, str) and len(v) > 0

if doc.get("schema") != "runtime-separation-receipt.v1":
    no("schema debe ser runtime-separation-receipt.v1")
if not isinstance(doc.get("phase"), str) or not FASE.match(doc["phase"]):
    no("phase con forma cerrada (N o N.M)")
for cuando in ("startedAt", "endedAt"):
    if not isinstance(doc.get(cuando), str) or not UTC.match(doc[cuando]):
        no(f"{cuando} debe ser UTC ISO8601 con Z")
if "startedAt" in doc and "endedAt" in doc and not bad and doc["endedAt"] < doc["startedAt"]:
    no("endedAt anterior a startedAt")
if not isinstance(doc.get("sourceSha"), str) or not SHA40.match(doc["sourceSha"]):
    no("sourceSha debe ser 40 hex")
if not es_txt(doc.get("host")) or len(doc.get("host", "")) > 128:
    no("host no vacio, maximo 128")
if not isinstance(doc.get("openclawVersion"), str) or not VER.match(doc["openclawVersion"]):
    no("openclawVersion con forma AAAA.N.N")
cmds = doc.get("commands")
if not isinstance(cmds, list) or not cmds:
    no("commands es lista no vacia")
else:
    for i, c in enumerate(cmds):
        if not isinstance(c, dict) or set(c) != {"name", "exit"}:
            no(f"commands[{i}] es exactamente {{name, exit}}")
        elif not es_txt(c["name"]) or not isinstance(c["exit"], int) or isinstance(c["exit"], bool):
            no(f"commands[{i}] name no vacio y exit entero")
ins = doc.get("inputs")
if not isinstance(ins, dict):
    no("inputs es objeto nombre -> hash")
else:
    for nombre, h in ins.items():
        if not isinstance(h, dict) or h.get("algo") != "sha256" or \
           not isinstance(h.get("sha256"), str) or not SHA64.match(h["sha256"]):
            no(f"inputs[{nombre}] es {{algo sha256, sha256 64 hex}}: nada por valor")
obs = doc.get("observations")
if not isinstance(obs, list) or len(obs) > 20:
    no("observations es lista de maximo 20")
else:
    for i, o in enumerate(obs):
        if not isinstance(o, str) or not o or len(o) > 300:
            no(f"observations[{i}] no vacia, maximo 300 caracteres (anti-transcripcion)")
salud = doc.get("health")
if not isinstance(salud, dict) or set(salud) != {"startupz", "readyz"}:
    no("health es exactamente {startupz, readyz}")
else:
    for sonda in ("startupz", "readyz"):
        if not isinstance(salud[sonda], int) or isinstance(salud[sonda], bool):
            no(f"health.{sonda} es codigo entero")
if doc.get("result") not in ("passed", "failed", "rolled_back"):
    no("result es passed|failed|rolled_back")
rb = doc.get("rollback")
if not isinstance(rb, dict) or set(rb) != {"artifact", "deadlineUtc"}:
    no("rollback es exactamente {artifact, deadlineUtc}")
else:
    if not es_txt(rb["artifact"]):
        no("rollback.artifact no vacio")
    if not isinstance(rb["deadlineUtc"], str) or not UTC.match(rb["deadlineUtc"]):
        no("rollback.deadlineUtc es UTC ISO8601 con Z")

# Barrido de secretos: claves y valores en TODA la profundidad.
def barre(nodo, ruta):
    if isinstance(nodo, dict):
        for k, v in nodo.items():
            if rx_key.search(k):
                no(f"clave con forma de secreto: {ruta}{k}")
            barre(v, f"{ruta}{k}.")
    elif isinstance(nodo, list):
        for i, v in enumerate(nodo):
            barre(v, f"{ruta}{i}.")
    elif isinstance(nodo, str):
        if rx_val.search(nodo):
            no(f"valor con forma de secreto en {ruta.rstrip('.')}")
barre(doc, "")

if bad:
    print("rechazado:")
    for b in bad:
        print(f"  - {b}")
    sys.exit(1)
print("ok")
PY

pon_recibo() { # $1=nombre, stdin=JSON
  cat >"$T/$1"
}

# Recibo bueno: el que un ciclo real podria escribir.
pon_recibo good.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "config validate", "exit": 0}, {"name": "sondas", "exit": 0}],
 "inputs": {"staging-manifest": {"algo": "sha256", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
 "observations": ["staging con 3 archivos", "sondas 200/200"],
 "health": {"startupz": 200, "readyz": 200}, "result": "passed",
 "rollback": {"artifact": "staging-20260922T1000", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON

# (2) El bueno pasa.
"$PYBIN" "$T/validate.py" "$SCHEMA" "$T/good.json" >/dev/null \
  || fail "(2) el recibo bueno fue rechazado"
echo "ok (2): el recibo bueno pasa"

# (3) Cada defecto se rechaza con razon nombrada.
debe_rechazar() { # $1=nombre $2=fixture-stdin... no: $1=nombre, lee $T/$1
  out=$("$PYBIN" "$T/validate.py" "$SCHEMA" "$T/$1" 2>&1) && \
    fail "(3) $1 debio rechazarse y paso"
  printf '%s' "$out" | grep -q 'rechazado' || fail "(3) $1 no explica el rechazo"
}
# 3a: falta una obligatoria (las 13, una por una).
i=0
for clave in schema phase startedAt endedAt sourceSha host openclawVersion commands inputs observations health result rollback; do
  i=$((i + 1))
  "$PYBIN" - "$T/good.json" "$T/falta-$clave.json" "$clave" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
del doc[sys.argv[3]]
json.dump(doc, open(sys.argv[2], "w", encoding="utf-8"))
PY
  debe_rechazar "falta-$clave.json"
done
echo "ok (3a): faltar cualquier obligatoria (13/13) rechaza"
# 3b: formas rotas.
pon_recibo mal-status.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "casi", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar mal-status.json
pon_recibo mal-sha.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22 10:00:00", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "no-es-sha", "host": "ehven-pc", "openclawVersion": "9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar mal-sha.json
pon_recibo extra.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"},
 "notaLibre": " Extension silenciosa del contrato."}
JSON
debe_rechazar extra.json
echo "ok (3b): status/sha/UTC/version rotos y clave extra rechazan"
# 3c: secretos con forma (clave o valor, .env, pairing, memoria).
pon_recibo clave-secreto.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}],
 "inputs": {"apiToken": {"algo": "sha256", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar clave-secreto.json
pon_recibo valor-secreto.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["token usado: ghp_abcdefghijklmnopqrstuvwxyza1B2"],
 "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar valor-secreto.json
pon_recibo dotenv.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["variables vistas:\nDISCORD_BOT_TOKEN=abc123xyz"],
 "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar dotenv.json
# Un codigo de pairing no tiene forma detectable en un valor: la regla es no
# registrarlo, y el patron de claves caza cualquier intento de darle campo.
pon_recibo pairing-clave.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"},
 "pairingCode": "482913"}
JSON
debe_rechazar pairing-clave.json
pon_recibo memoria.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["o"], "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"},
 "transcript": "hola..."}
JSON
debe_rechazar memoria.json
pon_recibo privada.json <<'JSON'
{"schema": "runtime-separation-receipt.v1", "phase": "16",
 "startedAt": "2026-09-22T10:00:00Z", "endedAt": "2026-09-22T10:04:31Z",
 "sourceSha": "0123456789abcdef0123456789abcdef01234567",
 "host": "ehven-pc", "openclawVersion": "2026.9.5",
 "commands": [{"name": "x", "exit": 0}], "inputs": {},
 "observations": ["-----BEGIN RSA PRIVATE KEY-----\nMIIB..."],
 "health": {"startupz": 200, "readyz": 200},
 "result": "passed", "rollback": {"artifact": "a", "deadlineUtc": "2026-09-29T10:00:00Z"}}
JSON
debe_rechazar privada.json
# Observacion larga = transcripcion disfrazada.
"$PYBIN" - "$T/good.json" "$T/larga.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
doc["observations"] = ["x" * 301]
json.dump(doc, open(sys.argv[2], "w", encoding="utf-8"))
PY
debe_rechazar larga.json
echo "ok (3c): clave/valor secreto, .env, pairing, memoria, llave privada y observacion larga rechazan"

# (4) Paridad de los patrones: el .psm1 trae EL MISMO literal que el schema
# (comparado decodificado, no a ojo).
[ -f "$MODULO" ] || fail "(4) falta $MODULO"
"$PYBIN" - "$SCHEMA" "$MODULO" <<'PY' || exit 1
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
cuerpo = open(sys.argv[2], encoding="utf-8").read()
for campo in ("x-secretKeyPattern", "x-secretValuePattern"):
    patron = schema[campo]
    assert patron in cuerpo, f"ROJO: (4) {campo} del schema no aparece literal en el .psm1"
PY
echo "ok (4): el .psm1 trae los mismos literales x-secret* del schema"

# (5) Mutantes: sin el barrido, un secreto pasa y ESTE test lo veria verde.
# Se muta una COPIA del validador: si el mutante acepta valor-secreto.json,
# el par validador+fixture discrimina (y si no lo acepta, no discrimina).
cp "$T/validate.py" "$T/mutante.py"
"$PYBIN" - "$T/mutante.py" <<'PY' || exit 1
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = "barre(doc, \"\")"
assert src.count(old) == 1, "no halle el barrido para mutarlo"
open(p, "w", encoding="utf-8").write(src.replace(old, "# MUTANTE: sin barrido de secretos", 1))
PY
if "$PYBIN" "$T/mutante.py" "$SCHEMA" "$T/valor-secreto.json" >/dev/null 2>&1; then
  echo "ok (5): mutante sin barrido acepta el secreto (el test si discrimina)"
else
  fail "(5) el mutante sin barrido siguio rechazando: el fixture no discrimina"
fi
# Mutante 2: required[] manda la presencia. Un schema mutado que EXIGE una
# clave de mas rechaza el recibo bueno por faltante. Si el validador usara
# una lista fija en vez de leer el schema, lo aceptaria. (Las formas por
# clave son codigo fijo a proposito: el schema gobierna presencia, el codigo
# gobierna forma.)
"$PYBIN" - "$SCHEMA" "$T/schema-mas.json" <<'PY' || exit 1
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
mas = dict(schema)
mas["required"] = schema["required"] + ["zzTop"]
json.dump(mas, open(sys.argv[2], "w", encoding="utf-8"))
PY
if "$PYBIN" "$T/validate.py" "$T/schema-mas.json" "$T/good.json" >/dev/null 2>&1; then
  fail "(5b) required[] con una clave de mas acepto el recibo bueno: required[] no manda"
fi
echo "ok (5b): required[] manda la presencia"

echo "TODO VERDE: runtime-receipt"

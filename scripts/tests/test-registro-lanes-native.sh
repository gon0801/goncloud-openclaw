#!/bin/bash
# Ronda 7 F1: lo que escribe el productor (abrir + reservar + registrar)
# pasa los DOS validadores: validar_registro de lib.sh y
# corrida-worker.py record validate => VALID corrida.v2 native-workers,
# ningun camino legacy. La llave vieja carriles queda ROTO.
# Uso: bash scripts/tests/test-registro-lanes-native.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/corridas/run-1"
export CORRIDA_STATE="$T/corridas" TMUX_BIN=true
printf '#!/bin/sh\nexit 0\n' > "$T/codex-falso"; chmod +x "$T/codex-falso"
export CORRIDA_WORKER_BIN_CODEX="$T/codex-falso"

. scripts/mac/corrida/lib.sh
. scripts/mac/corrida/adaptador.sh

REG="$T/corridas/run-1/registro.json"
# Registro como lo deja abrir: lanes vacia, sin llave carriles.
python3 - "$REG" <<'PYE' || fail "no se escribio el registro"
import json,sys
d={"schema":"corrida.v2","id":"run-1","vigia":"claw","seguimiento_global":True,
"runbook":"/tmp/rb.md","canal":{"cron":"c","destino":"d"},"cli_modos":"/tmp/m.tsv",
"inicio":"2026-09-26T10:00:00-04:00","simulacro":True,"estado":"abierta",
"timebox_horas":6,"sesiones":[],"preaprobaciones":[],"lanes":[]}
open(sys.argv[1],"w").write(json.dumps(d)+"\n")
PYE

# Reserva por el camino del productor (misma funcion que preparar-carril).
lock_tomar "$REG" || fail "lock para reservar no cede"
registro_reservar_carril "$REG" lane-1 "/tmp/wt-1" "corrida/run-1/lane-1" "abc123" write "111-1" \
  || fail "reservar lane-1 fallo"
lock_soltar "$REG"
# Registro de sesion por el camino del productor (misma funcion que start).
adaptador_registrar_sesion "$REG" lane-1 codex ses-1 \
  || fail "registrar ses-1 fallo"

# LOS DOS validadores sobre el MISMO registro.
validar_registro "$REG" || fail "lib no acepta lo que escribe el productor"
got="$(python3 scripts/mac/corrida-worker.py record validate --record "$REG")" \
  || fail "worker rechazo lo que escribe el productor: $got"
[ "$got" = "VALID corrida.v2 native-workers" ] \
  || fail "el productor no da native-workers: $got"
echo "ok: productor => $got"

# La llave vieja queda fuera de contrato.
python3 - "$REG" <<'PYE'
import json,sys
d=json.load(open(sys.argv[1]))
d["carriles"]={}
json.dump(d,open(sys.argv[1],"w"),indent=1)
PYE
validar_registro "$REG" >/dev/null 2>&1 \
  && fail "la llave vieja carriles debio quedar ROTO"
echo "ok: carriles queda ROTO"

echo "TODO VERDE: test-registro-lanes-native"

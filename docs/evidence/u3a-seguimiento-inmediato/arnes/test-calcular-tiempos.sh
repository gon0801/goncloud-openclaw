#!/bin/bash
# Prueba focalizada de calcular-tiempos.py (19.5 F5): el transporte se mide
# contra las lineas "sent:" del log del vigia, no contra cualquier linea con
# sello de pared ("SEND FAILED", "relanzo automatico").
# Uso: bash test-calcular-tiempos.sh
set -u
ARNES="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Reloj anclado: mono 1000e9 ns == pared 10:00:05.000Z (offset -2605 s).
# fin en mono 1000e9; aviso del doble en mono 1002e9; en pared del vigia:
#   10:00:00Z sent:            -> transporte verdadero 7.00 s
#   10:00:01Z SEND FAILED      -> no es un envio
#   10:00:02Z relanzo automatico -> no es un envio
# Con el filtro amplio de antes, el maximo elegible era 10:00:02 (5.00 s).
printf '{"ev":"reloj","mono_ns":1000000000000,"wall":"2026-09-29T10:00:05.000Z"}\n' > "$T/sondeo.jsonl"
printf '{"ev":"fin","mono_ns":1000000000000,"wall":"2026-09-29T10:00:05.000Z"}\n' >> "$T/sondeo.jsonl"
printf '{"mono_ns":1002000000000,"wall":"2026-09-29T10:00:07.000Z","estado":"REAL","argv":["system","event"]}\n' > "$T/doble.jsonl"
printf '%s\n' \
  '2026-09-29T10:00:00Z sent: tmux: x quiet for 10s' \
  '2026-09-29T10:00:01Z SEND FAILED (will retry next tick): tmux: x' \
  '2026-09-29T10:00:02Z relanzo automatico: x (corrida c)' > "$T/watch.log"

out=$(python3 "$ARNES/calcular-tiempos.py" "$T" zcode 10 2)
espera=$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])
print(d.get("transporte_script_s_aprox"))' "$out")
[ "$espera" = "7.0" ] || { echo "FAIL: transporte $espera, esperado 7.0 (solo lineas sent:)"; exit 1; }
echo "TODO VERDE: test-calcular-tiempos"

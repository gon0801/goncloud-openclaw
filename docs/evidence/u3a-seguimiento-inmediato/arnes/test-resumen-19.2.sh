#!/bin/bash
# Prueba focalizada del resumidor 19.2: la tabla y sus veredictos salen de los
# JSONL del arnes con el umbral de la DoD (30 s). La mutacion que discrimina:
# bajar el umbral a 5 s con el mismo(fixture) debe voltear la transicion
# frontera a TARDIO (rojo) -> restaurar -> verde.
set -u
cd "$(dirname "$0")"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Fixture: 2 transiciones. La 1 rapida (8.4 s); la 2 frontera (24.7 s: OK con
# umbral 30, TARDIO con 5). Monotonicos consecutivos en ns.
mk() { # $1 archivo $2 ev $3 mono $4 wall
  printf '{"ev":"%s","mono_ns":%s,"wall":"%s"}\n' "$2" "$3" "$4" >> "$T/$1"
}
mk fin-0.jsonl fin 1000000000 "2026-09-30T12:00:00.000Z"
mk ini-1.jsonl sesion-viva 11840000000 "2026-09-30T12:00:08.400Z"
mk ini-1.jsonl actividad 12000000000 "2026-09-30T12:00:10.000Z"
mk fin-1.jsonl fin 20000000000 "2026-09-30T12:00:20.000Z"
mk ini-2.jsonl sesion-viva 44700000000 "2026-09-30T12:00:44.700Z"
printf 'trab-0\ntrab-1\ntrab-2\n' > "$T/lanzados.txt"
printf '2026-09-30T12:00:00Z trab-0 zcode\n2026-09-30T12:00:20Z trab-1 codex\n2026-09-30T12:00:40Z trab-2 kimi\n' > "$T/lanzados.txt"
printf '0 zcode\n1 codex\n2 kimi\n' > "$T/slot-cli.txt"

out=$(python3 resumen-19.2.py "$T")
echo "$out" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["transiciones_con_datos"] == 2, r
assert r["cumplen"] == 2, r
assert r["mediana_s"] == 17.77, r["mediana_s"]
assert r["maximo_s"] == 24.7, r["maximo_s"]
assert r["tabla"][0]["veredicto"] == "OK", r["tabla"][0]
assert r["tabla"][1]["veredicto"] == "OK", r["tabla"][1]
assert r["finalizaciones_por_cli"] == {"zcode": 1, "codex": 1}, r
assert r["destinos_por_cli"] == {"codex": 1, "kimi": 1}, r
assert r["cobertura_incompleta"]["menos_de_2_finalizaciones"], r
' || fail "el resumen con umbral 30 no cuadra: $out"

# Mutacion: umbral 5 s -> ambas caen a TARDIO (la frontera de 24.7 incluida).
out5=$(python3 resumen-19.2.py "$T" 5)
echo "$out5" | python3 -c '
import json, sys
r = json.load(sys.stdin)
assert r["umbral_s"] == 5.0, r
assert r["cumplen"] == 0, r
assert r["tabla"][0]["veredicto"] == "TARDIO", r["tabla"][0]
assert r["tabla"][1]["veredicto"] == "TARDIO", r["tabla"][1]
' || fail "con umbral 5 ambas debian caer a TARDIO: $out5"

echo "TODO VERDE: test-resumen-19.2"

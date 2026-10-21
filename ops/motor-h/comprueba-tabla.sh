#!/usr/bin/env bash
# H.4: docs/model-routing.md tiene que ser byte-idéntica a lo que genera
# ops/motor-h/genera-model-routing.py desde goncloud-motor-conf. Si difiere,
# la tabla quedó vieja o se editó a mano: se regenera, no se parcha.
# Uso: bash ops/motor-h/comprueba-tabla.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
python3 ops/motor-h/genera-model-routing.py > "$tmp" \
  || { echo "ROJO: el generador no corrió (¿existe la conf de goncloud-motor-conf?)"; exit 1; }
[ -s "$tmp" ] || { echo "ROJO: el generador produjo una tabla vacía"; exit 1; }
if ! diff -u "$tmp" docs/model-routing.md; then
  echo "ROJO: docs/model-routing.md no coincide con goncloud-motor-conf"
  echo "      regenera con: python3 ops/motor-h/genera-model-routing.py > docs/model-routing.md"
  exit 1
fi
echo "VERDE: docs/model-routing.md coincide con goncloud-motor-conf"

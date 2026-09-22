#!/bin/bash
# La logica que decide el gate sobre la union de los shards de la bateria (B1).
#
# POR QUE existe como script y no inline en quality.yml: el contrato de cobertura
# tiene que poder EJECUTARSE, no solo leerse. El gate de CI llama a este archivo
# con los artifacts que los shards publicaron, y
# scripts/tests/test-ci-coverage-contract.sh lo ejecuta contra sandboxes con un
# runner de juguete. Si workflow y test dejaran de llamar al mismo codigo, la
# auditoria seria decorativa; un solo archivo impide esa deriva.
#
# Que afirma (falla = exit 1, con la razon en stderr):
#   1. Conjunto EXACTO de artifacts: shard-1, shard-2 y shard-3; ninguno mas.
#   2. Cada shard con su resumen.txt (directo o bajo logs/run-checks/, la
#      estructura que deja download-artifact sobre el upload de logs/run-checks/).
#   3. Resumen bien formado: columnas ok|falla \t duracion \t rc \t id \t log,
#      sin lineas vacias ni basura (un resumen que el runner no escribio no es
#      un resumen).
#   4. Resumen NO vacio: un shard que no corrio NINGUNA entrada no da verde
#      (mismo principio que el guard de 0 pass del runner).
#   5. Ninguna fila en falla: una corrida con pruebas rojas no audita verde
#      (defensa en profundidad: el gate ya rebota por el resultado del job).
#   6. La union de los ids es EXACTAMENTE el inventario esperado (cada entrada
#      una vez): sin faltantes, sin duplicados, sin desconocidos. El inventario
#      lo genera quien llama del checkout: glob scripts/tests/*.sh + las cinco
#      entradas fijas de node/sintaxis/corpus del runner. No se RE-CORRE nada:
#      esta auditoria solo lee.
#
# Uso: bash scripts/valida-union-shards.sh <dir-artifacts> <archivo-inventario>
#      <dir-artifacts>/shard-K/resumen.txt  con K en 1 2 3
# Exit: 0 ok | 1 rechazo con razon | 2 uso invalido
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -ne 2 ]; then
  printf 'uso: valida-union-shards.sh <dir-artifacts> <archivo-inventario>\n' >&2
  exit 2
fi
base=$1
inventario=$2

rechaza() { # $1=motivo (ya impreso con detalle si hace falta)
  printf 'valida-union-shards: RECHAZADO — %s\n' "$1" >&2
  exit 1
}

[ -d "$base" ] || rechaza "$base no es un directorio"
[ -s "$inventario" ] || rechaza "el inventario $inventario esta vacio o no existe"
if awk 'NF == 0 {bad = 1} END {exit bad ? 1 : 0}' "$inventario"; then :; else
  rechaza "el inventario $inventario tiene lineas vacias"
fi
dups_inv=$(sort "$inventario" | uniq -d)
[ -z "$dups_inv" ] || rechaza "el inventario tiene ids duplicados: $(echo $dups_inv)"

# 1. Conjunto exacto de shards.
encontrados=$(ls "$base" 2>/dev/null | grep -E '^shard-[0-9]+$' || true)
[ -n "$encontrados" ] || rechaza "no hay NINGUN artifact de shard en $base (la bateria no corrio o no publico logs)"
for d in $encontrados; do
  case $d in
    shard-1|shard-2|shard-3) ;;
    *) rechaza "artifact fuera del contrato: $d (el reparto es exactamente shard-1, shard-2 y shard-3)" ;;
  esac
done

tmp=$(mktemp "${TMPDIR:-/tmp}/valida-union.XXXXXX") || exit 1
tmp_inv=$(mktemp "${TMPDIR:-/tmp}/valida-union.XXXXXX") || { rm -f "$tmp"; exit 1; }
trap 'rm -f "$tmp" "$tmp_inv"' EXIT

# 2-5. Cada shard: su resumen, bien formado, no vacio, sin filas en falla.
: >"$tmp"
for k in 1 2 3; do
  d="$base/shard-$k"
  r=''
  for cand in "$d/resumen.txt" "$d/logs/run-checks/resumen.txt"; do
    [ -f "$cand" ] && { r=$cand; break; }
  done
  [ -n "$r" ] || rechaza "falta el resumen del shard $k (se busco $d/resumen.txt y $d/logs/run-checks/resumen.txt)"
  [ -s "$r" ] || rechaza "el resumen del shard $k ($r) esta VACIO: un shard que no corrio ninguna entrada no puede dar verde"
  if ! awk -F'\t' '
    NF != 5 || ($1 != "ok" && $1 != "falla") || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 == "" {bad = 1}
    END {exit bad ? 1 : 0}
  ' "$r"; then
    rechaza "el resumen del shard $k ($r) tiene lineas malformadas (se espera ok|falla TAB duracion TAB rc TAB id TAB log)"
  fi
  if grep -q '^falla' "$r"; then
    printf 'valida-union-shards: el shard %s reporta filas en falla:\n' "$k" >&2
    grep '^falla' "$r" | sed 's/^/  /' >&2
    rechaza "la corrida del shard $k tiene pruebas en rojo"
  fi
  awk -F'\t' '{print $4}' "$r" >>"$tmp"
done

# 6. Union == inventario, cada id exactamente una vez.
sort "$tmp" -o "$tmp"
sort "$inventario" -o "$tmp_inv"
faltan=$(comm -23 "$tmp_inv" "$tmp")
sobran=$(comm -13 "$tmp_inv" "$tmp")
duplicados=$(uniq -d "$tmp")
[ -z "$duplicados" ] || rechaza "entradas duplicadas (corrieron MAS de una vez): $(echo $duplicados)"
[ -z "$faltan" ] || rechaza "entradas del inventario que NINGUN shard corrio: $(echo $faltan)"
[ -z "$sobran" ] || rechaza "entradas en la union que NO estan en el inventario: $(echo $sobran)"

printf 'valida-union-shards: OK — %s entrada(s), cada una exactamente una vez, union = inventario\n' "$(wc -l <"$tmp" | tr -d ' ')"
exit 0

#!/usr/bin/env bash
# Convencion de dos copias: docs/crons/<id>.md ↔ docs/cron-messages/<id>.v<N>.txt
# (el <N> mas alto). El fence del .md y el .txt tienen que ser el mismo texto;
# si divergen, el aplicador degrada un prompt que ya funciona (mina medida en
# verif-digest-20h el 2026-09-12: el .txt viejo y el cron vivo corregido).
#
# Uso: bash scripts/tests/test-crons-dos-copias.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

CRONS=docs/crons
MSGS=docs/cron-messages
[ -d "$CRONS" ] || fail "falta $CRONS"
[ -d "$MSGS" ] || fail "falta $MSGS"

# Excepciones md sin txt (razon por entrada).
# verif-sync-repos: el .md existe antes del .txt; 13.2 agrega v2 y lo saca de aqui.
MD_SIN_TXT='verif-sync-repos'

# Excepciones txt sin md (anteriores a docs/crons/).
TXT_SIN_MD='packing-digest-20h.v14.txt
packing-extras-11h.v14.txt
packing-extras-7h.v14.txt
report-7h-estreno.B2.txt
verif-7h-v12-estreno.A2.txt
verif-7h-v12-estreno.F2.txt'

en_lista() {
  local needle="$1" lista="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$needle" ] && return 0
  done <<EOF
$lista
EOF
  return 1
}

# Extrae el cuerpo del primer fence. Acepta cierre en linea propia O pegado al
# final de la ultima linea de contenido (el defecto medido en verif-digest-20h),
# para que el desfase de texto se vea como rojo de contenido, no se esconda
# detras del formato del fence.
extraer_fence() {
  python3 - "$1" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
lines = text.splitlines()
start = None
for i, line in enumerate(lines):
    if line.strip() == "```":
        start = i
        break
if start is None:
    print("NO_FENCE_OPEN", file=sys.stderr)
    sys.exit(2)
end = None
own_line = False
for i in range(start + 1, len(lines)):
    if lines[i].strip() == "```":
        end = i
        own_line = True
        break
if end is None:
    # Cierre pegado: ultima linea termina en ```
    for i in range(len(lines) - 1, start, -1):
        if lines[i].rstrip().endswith("```"):
            end = i
            body_line = lines[i].rstrip()[:-3]
            body = "\n".join(lines[start + 1:i] + ([body_line] if body_line else []))
            sys.stdout.write(body)
            sys.exit(0)
    print("NO_FENCE_CLOSE", file=sys.stderr)
    sys.exit(3)
body = "\n".join(lines[start + 1:end])
sys.stdout.write(body)
PY
}

fence_cierra_en_linea_propia() {
  python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip() == "```"), None)
if start is None:
    sys.exit(1)
for i in range(start + 1, len(lines)):
    if lines[i].strip() == "```":
        sys.exit(0)
sys.exit(1)
PY
}

highest_txt() {
  local id="$1"
  python3 - "$MSGS" "$id" <<'PY'
import glob, os, re, sys
msgs, cron_id = sys.argv[1], sys.argv[2]
pat = re.compile(r"^" + re.escape(cron_id) + r"\.v(\d+)\.txt$")
best_n, best = -1, None
for p in glob.glob(os.path.join(msgs, "*.txt")):
    m = pat.match(os.path.basename(p))
    if m and int(m.group(1)) > best_n:
        best_n, best = int(m.group(1)), p
if best is None:
    sys.exit(1)
print(best)
PY
}

# (1) Cada .md tiene su .txt (salvo excepcion), el cuerpo del fence coincide con
# el .txt de mayor version, el fence cierra en linea propia, y declara id vivo.
for md in "$CRONS"/*.md; do
  [ -e "$md" ] || continue
  id=$(basename "$md" .md)
  if en_lista "$id" "$MD_SIN_TXT"; then
    echo "ok (1ex): $id en MD_SIN_TXT (sin .txt por ahora)"
    fence_cierra_en_linea_propia "$md" \
      || fail "(1) $md: el cierre del fence va en linea propia"
    grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$md" \
      || fail "(1) $md no declara su id vivo (uuid)"
    continue
  fi
  txt=$(highest_txt "$id") || fail "(1) $id.md no tiene $MSGS/$id.v<N>.txt y no esta en MD_SIN_TXT"
  if ! body=$(extraer_fence "$md" 2>/tmp/fence.err); then
    err=$(cat /tmp/fence.err)
    fail "(1) $md: no pude leer el fence ($err)"
  fi
  want=$(cat "$txt" | tr -d '\r' | sed -e '${/^$/d;}')
  got=$(printf '%s' "$body" | tr -d '\r')
  [ "$got" = "$want" ] \
    || fail "(1) $md fence != $(basename "$txt"): las dos copias divergieron (el aplicador usaria el .txt)"
  fence_cierra_en_linea_propia "$md" \
    || fail "(1) $md: el cierre del fence va en linea propia, no pegado al texto"
  grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$md" \
    || fail "(1) $md no declara su id vivo (uuid)"
  echo "ok (1): $id.md ↔ $(basename "$txt") (fence=txt, id vivo, cierre en linea propia)"
done

# (2) Cada .txt versionado tiene su .md, salvo excepcion explicita.
for txt in "$MSGS"/*.txt; do
  [ -e "$txt" ] || continue
  base=$(basename "$txt")
  if en_lista "$base" "$TXT_SIN_MD"; then
    echo "ok (2ex): $base en TXT_SIN_MD (anterior a docs/crons/)"
    continue
  fi
  # Solo entran al apareo los que siguen <id>.v<N>.txt
  if ! echo "$base" | grep -qE '^.+\.v[0-9]+\.txt$'; then
    fail "(2) $base no sigue <id>.v<N>.txt y no esta en TXT_SIN_MD"
  fi
  id=$(echo "$base" | sed -E 's/\.v[0-9]+\.txt$//')
  [ -f "$CRONS/$id.md" ] \
    || fail "(2) $base no tiene $CRONS/$id.md y no esta en TXT_SIN_MD"
done
echo "ok (2): todo .txt versionado tiene .md o excepcion con razon"

# (3) Mutante: cambiar una palabra de cualquiera de las dos copias deja rojo.
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
cp -R "$CRONS" "$T/crons"
cp -R "$MSGS" "$T/msgs"
# Fabricar divergence en verif-digest-20h (tiene las dos copias).
python3 - "$T/msgs/verif-digest-20h.v1.txt" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("PROPOSITO", "PROPOSITO_MUTADO", 1))
PY
(
  CRONS="$T/crons" MSGS="$T/msgs"
  # Re-ejecutar solo el chequeo de igualdad sobre el mutante.
  md="$CRONS/verif-digest-20h.md"
  txt="$MSGS/verif-digest-20h.v1.txt"
  body=$(extraer_fence "$md") || exit 0
  want=$(cat "$txt" | tr -d '\r' | sed -e '${/^$/d;}')
  got=$(printf '%s' "$body" | tr -d '\r')
  [ "$got" != "$want" ]
) || fail "(3) mutante: cambiar una palabra del .txt debio romper la igualdad fence↔txt"
echo "ok (3): mutante de una palabra deja rojo"

# (4) Mutante: un .txt nuevo sin .md deja rojo.
touch "$T/msgs/cron-fantasma.v1.txt"
if (
  export CRONS="$T/crons" MSGS="$T/msgs"
  # Misma regla que (2), aislada sobre el arbol mutado.
  base=cron-fantasma.v1.txt
  en_lista "$base" "$TXT_SIN_MD" && exit 0
  id=cron-fantasma
  [ -f "$CRONS/$id.md" ] && exit 0
  exit 1
); then
  fail "(4) mutante: un .txt nuevo sin .md debio dejar rojo y paso"
fi
echo "ok (4): un .txt nuevo sin .md deja rojo"

echo "TODO VERDE: crons-dos-copias"

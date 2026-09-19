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
# (vacio tras 13.2: verif-sync-repos ya tiene v2.txt)
MD_SIN_TXT=''

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
for i in range(start + 1, len(lines)):
    if lines[i].strip() == "```":
        end = i
        break
if end is None:
    for i in range(len(lines) - 1, start, -1):
        if lines[i].rstrip().endswith("```"):
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

# La linea del contrato, no cualquier uuid del cuerpo del mensaje (BRIEF-r2).
tiene_linea_id_vivo() {
  grep -qE '^Id vivo: `?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$1"
}

highest_txt() {
  local id="$1" msgs_dir="${2:-$MSGS}"
  python3 - "$msgs_dir" "$id" <<'PY'
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

# Chequeo (1) real: apareo md↔txt + fence + linea Id vivo.
# Quiet=1 solo imprime fallos (para que los mutantes lo invoquen sin ruido).
# Devuelve 0 si todo OK, 1 si algo falla (sin exit del script padre).
chequeo_1_apareo() {
  local crons_dir="$1" msgs_dir="$2" quiet="${3:-0}"
  local md id txt body want got err
  for md in "$crons_dir"/*.md; do
    [ -e "$md" ] || continue
    id=$(basename "$md" .md)
    if en_lista "$id" "$MD_SIN_TXT"; then
      [ "$quiet" = 1 ] || echo "ok (1ex): $id en MD_SIN_TXT (sin .txt por ahora)"
      fence_cierra_en_linea_propia "$md" || {
        [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md: el cierre del fence va en linea propia"
        return 1
      }
      tiene_linea_id_vivo "$md" || {
        [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md no declara su id vivo (falta la linea 'Id vivo: <uuid>')"
        return 1
      }
      continue
    fi
    if ! txt=$(MSGS="$msgs_dir" highest_txt "$id" "$msgs_dir"); then
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $id.md no tiene $msgs_dir/$id.v<N>.txt y no esta en MD_SIN_TXT"
      return 1
    fi
    if ! body=$(extraer_fence "$md" 2>/tmp/fence.err); then
      err=$(cat /tmp/fence.err)
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md: no pude leer el fence ($err)"
      return 1
    fi
    want=$(cat "$txt" | tr -d '\r' | sed -e '${/^$/d;}')
    got=$(printf '%s' "$body" | tr -d '\r')
    if [ "$got" != "$want" ]; then
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md fence != $(basename "$txt"): las dos copias divergieron (el aplicador usaria el .txt)"
      return 1
    fi
    fence_cierra_en_linea_propia "$md" || {
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md: el cierre del fence va en linea propia, no pegado al texto"
      return 1
    }
    tiene_linea_id_vivo "$md" || {
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(1) $md no declara su id vivo (falta la linea 'Id vivo: <uuid>')"
      return 1
    }
    [ "$quiet" = 1 ] || echo "ok (1): $id.md ↔ $(basename "$txt") (fence=txt, id vivo, cierre en linea propia)"
  done
  return 0
}

# Chequeo (2) real: todo .txt versionado tiene .md o excepcion.
chequeo_2_txt_tienen_md() {
  local crons_dir="$1" msgs_dir="$2" quiet="${3:-0}"
  local txt base id
  for txt in "$msgs_dir"/*.txt; do
    [ -e "$txt" ] || continue
    base=$(basename "$txt")
    if en_lista "$base" "$TXT_SIN_MD"; then
      [ "$quiet" = 1 ] || echo "ok (2ex): $base en TXT_SIN_MD (anterior a docs/crons/)"
      continue
    fi
    if ! echo "$base" | grep -qE '^.+\.v[0-9]+\.txt$'; then
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(2) $base no sigue <id>.v<N>.txt y no esta en TXT_SIN_MD"
      return 1
    fi
    id=$(echo "$base" | sed -E 's/\.v[0-9]+\.txt$//')
    if [ ! -f "$crons_dir/$id.md" ]; then
      [ "$quiet" = 1 ] || printf 'ROJO: %s\n' "(2) $base no tiene $crons_dir/$id.md y no esta en TXT_SIN_MD"
      return 1
    fi
  done
  [ "$quiet" = 1 ] || echo "ok (2): todo .txt versionado tiene .md o excepcion con razon"
  return 0
}

# --- corrida sobre el arbol real ---
chequeo_1_apareo "$CRONS" "$MSGS" 0 || fail "chequeo (1) fallo"
chequeo_2_txt_tienen_md "$CRONS" "$MSGS" 0 || fail "chequeo (2) fallo"

# (3) Mutante: cambiar una palabra → el CHEQUEO (1) REAL debe fallar.
# Si alguien anula la comparacion got==want dentro de chequeo_1_apareo, este
# mutante deja de morir y ESTE paso sale ROJO (BRIEF-r2 hueco 1).
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
cp -R "$CRONS" "$T/crons"
cp -R "$MSGS" "$T/msgs"
python3 - "$T/msgs/verif-digest-20h.v1.txt" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("PROPOSITO", "PROPOSITO_MUTADO", 1))
PY
if chequeo_1_apareo "$T/crons" "$T/msgs" 1; then
  fail "(3) mutante: cambiar una palabra del .txt debio hacer fallar el chequeo (1) real y paso"
fi
echo "ok (3): mutante de una palabra deja rojo el chequeo (1) real"

# (4) Mutante: .txt nuevo sin .md → el CHEQUEO (2) REAL debe fallar.
touch "$T/msgs/cron-fantasma.v1.txt"
if chequeo_2_txt_tienen_md "$T/crons" "$T/msgs" 1; then
  fail "(4) mutante: un .txt nuevo sin .md debio hacer fallar el chequeo (2) real y paso"
fi
echo "ok (4): un .txt nuevo sin .md deja rojo el chequeo (2) real"

echo "TODO VERDE: crons-dos-copias"

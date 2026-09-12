#!/bin/bash
# Un candado que apunta a un archivo que no esta en el repo no es un candado: funciona en la
# maquina donde se escribio y en ninguna otra. Paso tres veces el 2026-09-12:
#   1. `node /tmp/render-corpus-tsv.ts` como forma documentada de regenerar un corpus
#      (/tmp se borra al reiniciar) — en el mismo documento que le reprochaba eso a otro script.
#   2. `scripts/restart-openclaw-gateway.ps1` sin trackear, asi que el sync nunca lo copio al
#      gateway y el reinicio murio con "The argument ... does not exist" (ese es el test
#      hermano, test-restart-gateway-script.sh).
#   3. El hook `run-checks` quedo apuntando a `tools/run-checks.sh` con `tools/` en .gitignore:
#      el `git add` lo descarto EN SILENCIO y el commit subio un hook sin su script.
# Esta prueba mira los `entry:` de .pre-commit-config.yaml y exige que los archivos que
# nombran esten trackeados.
# Uso: bash scripts/tests/test-hooks-apuntan-a-archivos-trackeados.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
CFG=.pre-commit-config.yaml
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$CFG" ] || fail "no existe $CFG"

# (1) Todo archivo del repo nombrado en un `entry:` tiene que estar trackeado.
revisados=0
while IFS= read -r ruta; do
  [ -n "$ruta" ] || continue
  revisados=$((revisados + 1))
  [ -e "$ruta" ] || fail "$CFG: el hook apunta a '$ruta', que no existe en el arbol"
  git ls-files --error-unmatch "$ruta" >/dev/null 2>&1 \
    || fail "$CFG: el hook apunta a '$ruta', que NO esta trackeado (.gitignore lo descarta en silencio)"
done < <(grep -oE '^\s*entry:.*' "$CFG" | grep -oE '[A-Za-z0-9_./-]+\.(sh|py|ps1|mjs|js)' | sort -u)

[ "$revisados" -gt 0 ] || fail "$CFG: no se encontro ningun entry con archivo; la prueba no estaria mirando nada"
echo "ok (1): $revisados archivo(s) referenciados por hooks, todos trackeados"

# (2) Discriminacion: un archivo recien creado (no trackeado) tiene que dar rojo con la misma
# comprobacion de (1). Sin esto, (1) pasaria por vacio si `git ls-files` cambiara de conducta.
SONDA="scripts/.sonda-hook-$$.sh"
trap 'rm -f "$SONDA"' EXIT
printf '#!/bin/bash\n' > "$SONDA" || fail "no se pudo crear la sonda"
if git ls-files --error-unmatch "$SONDA" >/dev/null 2>&1; then
  fail "un archivo recien creado figura como trackeado: la comprobacion (1) no discrimina"
fi
rm -f "$SONDA"
echo "ok (2): la comprobacion distingue trackeado de solo-en-disco"

# (3) El directorio donde vive el runner no puede estar ignorado. Es la trampa exacta de (3)
# en la cabecera: el archivo existe, se ve en `ls`, y `git add` lo tira sin decir nada.
for d in scripts tools; do
  [ -d "$d" ] || continue
  if git check-ignore -q "$d/" 2>/dev/null; then
    grep -qE "entry:.*\b$d/" "$CFG" \
      && fail "$CFG: un hook corre algo dentro de '$d/', que esta en .gitignore"
  fi
done
echo "ok (3): ningun hook corre desde un directorio ignorado"

echo "PASS test-hooks-apuntan-a-archivos-trackeados"

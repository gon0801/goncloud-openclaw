#!/bin/bash
# La evidencia versionada NO lleva texto de los prompts del usuario.
#
# Cross-review de qwen (2026-09-12): `docs/evidence/backfill-rendiciones.jsonl` traia 201
# `userTextPreview` con los primeros 120 caracteres de los prompts de 8 agentes, y ese archivo
# SI se versiona. Es la misma fuga que se habia quitado del observador en vivo (donde el
# `textPreview` pasó a viajar solo en las lineas detectadas), cometida en el archivo de
# evidencia y sin que nadie la viera durante dos revisiones.
#
# El conteo y el largo alcanzan para el analisis; el texto no hace falta y ademas es
# re-derivable corriendo el backfill contra el historico del gateway.
# Uso: bash scripts/tests/test-evidencia-sin-texto-de-usuario.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { echo "FAIL: $1"; exit 1; }

# (1) Ningun archivo de evidencia versionado puede traer userTextPreview con contenido.
revisados=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  revisados=$((revisados + 1))
  # `"userTextPreview":null` esta bien (el campo queda como marca de que se redacto).
  if grep -qE '"userTextPreview" *: *"' "$f"; then
    n=$(grep -cE '"userTextPreview" *: *"' "$f")
    fail "$f trae $n preview(s) del prompt del usuario con contenido: la evidencia versionada no lleva texto de prompts"
  fi
done < <(git ls-files 'docs/evidence/*.jsonl')

[ "$revisados" -gt 0 ] || fail "no se encontro ningun jsonl versionado en docs/evidence/: la prueba no estaria mirando nada"
echo "ok (1): $revisados archivo(s) de evidencia sin texto de prompts"

# (2) Y el generador tampoco puede volver a escribirlos.
# Cross-review de grok (2026-09-12): esta parte tenia los DOS defectos que este mismo
# bloque venia corrigiendo en otros lados. (a) `if [ -f ]` se salteaba en silencio si el
# generador no estaba — el mismo skip mudo que se le reprocho a run-checks.sh. (b) el
# patron solo cazaba la forma con ternario, asi que una reintroduccion directa
# (`userTextPreview: t.userText.slice(0, 120)`) pasaba en verde.
GEN=summa-gate/backfill-rendiciones.mjs
[ -f "$GEN" ] || fail "falta $GEN: la comprobacion del generador no puede saltearse en silencio"
# Cualquier asignacion de userTextPreview que NO sea literalmente null es sospechosa.
if grep -nE 'userTextPreview: *[^n,]' "$GEN" | grep -vqE 'userTextPreview: *null'; then
  grep -nE 'userTextPreview: *[^n,]' "$GEN" | grep -vE 'userTextPreview: *null' | sed 's/^/    /'
  fail "$GEN emite texto en userTextPreview; redactar el jsonl no alcanza si el generador lo repone"
fi
echo "ok (2): el generador no emite el texto del prompt"

# (2b) Discriminacion del patron de (2): tiene que cazar las dos formas de reintroduccion.
SONDA_GEN=$(mktemp)
for forma in 'userTextPreview: t.userText ? t.userText.slice(0, 120) : null,' \
             'userTextPreview: t.userText.slice(0, 120),' \
             'userTextPreview: userText,'; do
  printf '%s\n' "$forma" > "$SONDA_GEN"
  grep -nE 'userTextPreview: *[^n,]' "$SONDA_GEN" | grep -vqE 'userTextPreview: *null' \
    || { rm -f "$SONDA_GEN"; fail "el patron de (2) no caza la reintroduccion: $forma"; }
done
printf 'userTextPreview: null,\n' > "$SONDA_GEN"
if grep -nE 'userTextPreview: *[^n,]' "$SONDA_GEN" | grep -vqE 'userTextPreview: *null'; then
  rm -f "$SONDA_GEN"; fail "el patron de (2) marca un null legitimo: daria falsos positivos"
fi
rm -f "$SONDA_GEN"
echo "ok (2b): el patron caza las tres formas de reintroduccion y respeta el null"

# (3) Discriminacion: la comprobacion de (1) tiene que disparar sobre un archivo que SI lo
# traiga. Sin esto pasaria por vacio si el patron se rompiera.
SONDA=$(mktemp)
trap 'rm -f "$SONDA"' EXIT
printf '{"backfill_meta":{"userTextPreview":"corre el deploy de produccion"}}\n' > "$SONDA"
grep -qE '"userTextPreview" *: *"' "$SONDA" \
  || fail "el patron no detecta un preview con contenido: la comprobacion (1) no discrimina"
printf '{"backfill_meta":{"userTextPreview":null}}\n' > "$SONDA"
grep -qE '"userTextPreview" *: *"' "$SONDA" \
  && fail "el patron marca un preview ya redactado (null): daria falsos positivos"
echo "ok (3): el patron distingue preview con contenido de preview redactado"

echo "PASS test-evidencia-sin-texto-de-usuario"

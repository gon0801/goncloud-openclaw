#!/bin/bash
# La seccion "Tablero de runbook" de docs/spec/00-project-spec.md fija el
# contrato de producto de la Fase 7: cinco declaraciones (las cuatro reglas
# del Spec delta de Plans.md mas la quinta que exige la DoD de 7.4, sobre que
# `get` y la ruta .json exponen residuales y eventos a quien pase la auth).
# Si una se cae del spec, el plugin pierde su requisito escrito y el tablero
# puede empezar a inferir, a bloquear turnos, a pintar crudo, a presentar
# reportado como verificado, o a esconder residuales, sin que ningun candado
# lo note.
#
# Uso: bash scripts/tests/test-spec-tablero.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SPEC=docs/spec/00-project-spec.md
[ -r "$SPEC" ] || fail "no encuentro el spec: $SPEC"

# (1) La seccion existe.
grep -q '^## Tablero de runbook$' "$SPEC" \
  || fail "$SPEC: falta la seccion '## Tablero de runbook'"
echo "ok (1): la seccion Tablero de runbook existe"

# (2) Las cinco declaraciones, una frase literal por regla. Se buscan solo
# dentro de la seccion (hasta el proximo '## '), para que no las aporte otro
# texto del spec por accidente.
SEC=$(mktemp)
trap 'rm -f "$SEC"' EXIT
awk '/^## Tablero de runbook$/{dentro=1; next} /^## /{dentro=0} dentro' \
  "$SPEC" > "$SEC"
[ -s "$SEC" ] || fail "la seccion Tablero de runbook quedo vacia"
n=0
for a in 'progreso de un runbook lo escribe el lead' \
         'no registra hooks de agente ni tools' \
         'se trunca y escapa en el punto de interpolación' \
         'GitHub: sin verificar' \
         'exponen `residuales` y `eventos` a quien pase la auth del gateway'; do
  n=$((n + 1))
  grep -qF "$a" "$SEC" || fail "$SPEC: falta la declaracion $n: $a"
done
echo "ok (2): las cinco declaraciones estan dentro de la seccion"

# (3) Discriminacion: cada ancla tiene que fallar si su frase falta. Sin esto,
# un patron roto pasaria en verde sin mirar nada.
for a in 'progreso de un runbook lo escribe el lead' \
         'no registra hooks de agente ni tools' \
         'se trunca y escapa en el punto de interpolación' \
         'GitHub: sin verificar' \
         'exponen `residuales` y `eventos` a quien pase la auth del gateway'; do
  grep -qF "$a" "$SEC" \
    || fail "discriminacion rota: el ancla ya no casa: $a"
  printf 'seccion sin esa frase\n' > "$SEC.sonda"
  grep -qF "$a" "$SEC.sonda" \
    && { rm -f "$SEC.sonda"; fail "el ancla casa en texto vacio: $a"; }
done
rm -f "$SEC.sonda"
echo "ok (3): las cinco anclas discriminan"

echo "PASS test-spec-tablero"

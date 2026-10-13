#!/bin/bash
# U3a C3-r1 (fila 19.3): candados de los puntos cerrados por verificacion o
# por ausencia, sin cambio de conducta. Nada toca ~/bin, el estado real, el
# gateway ni tmux: solo lee el arbol. Uso: bash scripts/tests/test-u3a-19-3.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RAIZ="${U3A19_RAIZ:-$PWD}"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# 19.3-1-F1 (#207 F1): el diseño describe el modo ci-y-revisor (una sola copia
# de la regla, sin copias viejas sin el modo).
grep -q "modo_recibo: ci-y-revisor" "$RAIZ/docs/superpowers/specs/2026-09-19-native-harness-orchestration-design.md" \
  || fail "1-F1: el diseño no describe ci-y-revisor"
[ "$(grep -c "La ruta de merge consume el recibo" "$RAIZ/docs/superpowers/specs/2026-09-19-native-harness-orchestration-design.md")" = "1" ] \
  || fail "1-F1: hay copias de la regla de merge en el diseño"
echo "ok (1-F1): el diseño describe ci-y-revisor en copia unica"

# 19.3-3-F2 (#209 F2): el recibo de 14.23 R5 apunta al Task 3 Step 1 del plan.
grep -q "R5 cerrado: el loop del plan (Task 3 Step 1)" "$RAIZ/Plans.md" \
  || fail "3-F2: el recibo R5 no dice Task 3 Step 1"
grep -q "### Task 3: One adapter contract" "$RAIZ/docs/superpowers/plans/2026-09-19-native-harness-orchestration.md" \
  || fail "3-F2: el plan no trae el loop en Task 3"
echo "ok (3-F2): R5 apunta al Task 3 Step 1 del plan"

# 19.3-7-F2 (#213 F2): la spec ya no dice "ocho entradas".
if grep -rn "ocho entradas" "$RAIZ/docs/superpowers/specs" "$RAIZ/docs/superpowers/plans" "$RAIZ/scripts" 2>/dev/null | grep -v "test-u3a-19-3.sh" | grep -q .; then
  fail "7-F2: la spec sigue diciendo ocho entradas"
fi
echo "ok (7-F2): sin ocho entradas en spec, plan ni scripts"

# 19.3-13: ningun loop dice "cada 20 min" en su texto.
if grep -rn "cada 20 min" "$RAIZ/scripts" "$RAIZ/agents" 2>/dev/null | grep -v "test-u3a-19-3.sh" | grep -q .; then
  fail "13: un loop dice cada 20 min"
fi
echo "ok (13): ningun loop dice cada 20 min"

# 19.3-15: sin vigilantes huerfanos: el directorio del punto no existe y no
# hay procesos vigia vivos.
[ ! -d "${TMPDIR:-/tmp}/corridas/.arnes-vigia-bin" ] \
  || fail "15: existe \${TMPDIR}/corridas/.arnes-vigia-bin"
if pgrep -fl "arnes-vigia" 2>/dev/null | grep -q .; then
  fail "15: hay vigilantes vivos"
fi
echo "ok (15): sin directorio ni procesos huerfanos"

echo "TODO VERDE: u3a-19-3"

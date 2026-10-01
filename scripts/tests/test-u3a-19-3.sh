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

# 19.3-7-F1 (#213 F1, resuelta por #216): cursor-agent es fila legacy
# explicita y el preflight no la lanza ni la deja bloquear el verde.
grep -q "cursor-agent es fila legacy" "$RAIZ/scripts/mac/cli-modos.tsv" \
  || fail "7-F1: cursor-agent no esta marcada legacy en cli-modos.tsv"
grep -q "fila legacy fuera del registro" "$RAIZ/scripts/mac/corrida/preflight.sh" \
  || fail "7-F1: preflight sin la rama legacy"
grep -q "F2-g: la fila legacy fuera del registro" "$RAIZ/scripts/tests/test-corrida-preflight.sh" \
  || fail "7-F1: falta el caso F2-g que fija la legacy sin lanzar"
echo "ok (7-F1): legacy explicita que no bloquea ni se lanza"

# 19.3-12: por diseño los candidatos los provee el director; la observacion
# automatica trae next null. Candado al diseño declarado, sin cambio.
grep -q "los candidatos los provee el director" "$RAIZ/scripts/mac/corrida/reconciliar.sh" \
  || fail "12: reconciliar.sh no declara que los candidatos los provee el director"
grep -q '"candidates":{"exhausted":\[\],"next":None}' "$RAIZ/scripts/mac/corrida/reconciliar.sh" \
  || fail "12: la observacion automatica no trae next null"
echo "ok (12): candidatos del director por diseño declarado"

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

# 19.3-4-F1 (#210 F1, arreglado en el PR): el caso (2p) del candado existe.
grep -q "(2p)" "$RAIZ/scripts/tests/test-tmux-activity-watch.sh" \
  || fail "4-F1: falta el caso (2p) del candado huerfano"
echo "ok (4-F1): el caso (2p) fija el candado retomado"

# 19.3-8 (#214 F2, arreglado en 19.1): el hook Stop respeta OPENCLAW_WATCH_RUN.
grep -q "OPENCLAW_WATCH_RUN" "$RAIZ/scripts/mac/claude-stop-openclaw-event.sh" \
  || fail "8: el hook Stop ignora OPENCLAW_WATCH_RUN"
echo "ok (8): el hook Stop respeta OPENCLAW_WATCH_RUN"

# 19.3-10-F1 (#219 F1, arquitectura de eventos): ninguna publicacion hace
# get-modify-set del documento entero (progress.set ya no existe en la ruta).
if grep -rn "progress\.set" "$RAIZ/scripts/mac/corrida/lib.sh" "$RAIZ/scripts/mac/corrida/reconciliar.sh" "$RAIZ/scripts/mac/corrida/adaptador.sh" 2>/dev/null | grep -q .; then
  fail "10-F1: queda un progress.set de documento entero"
fi
echo "ok (10-F1): publicacion por eventos, sin set entero"

# 19.3 F9 de 19.7 (C2-r1 quito dos ramas, C3-r1 la tercera): aviso_dueno
# solo devuelve 0 o 1; ninguna rama rc_av == 2 queda en el vigia.
if grep -qF '[[ $rc_av == 2 ]]' "$RAIZ/scripts/mac/tmux-activity-watch.sh"; then
  fail "F9: queda una rama rc_av == 2 inalcanzable en el vigia"
fi
echo "ok (F9): sin ramas rc_av == 2 en el vigia"

# 19.3-9-confianza: cada CLI pide confianza en su carpeta; el runbook
# manda correr el preflight desde el checkout principal (unico que las pasa).
grep -q "checkout principal" "$RAIZ/docs/runbooks/native-harness-rollout.md" \
  || fail "9-confianza: el runbook no manda el checkout principal"
echo "ok (9-confianza): preflight desde el checkout principal"

echo "TODO VERDE: u3a-19-3"

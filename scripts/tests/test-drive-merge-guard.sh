#!/bin/bash
# 13.4 (Fase 13): el driver del merge-guard corre, y alguien lo corre.
#
# docs/agent-skills/verify/drive-merge-guard.ts existía desde la Fase 11 pero
# NADA lo ejecutaba: era el ejemplo que la skill enseña a copiar, verde o rojo
# sin testigo. Peor: sus seis casos mandaban todos el mismo agentId "main", así
# que la rama del allowlist del merge-guard (implementer/ingenieria pueden,
# verifier y agentId ausente no, 6.5c) tenía cero cobertura — reemplazar
# lib.ts:214 por `const allowlisted = false;` dejaba el driver en verde (medido,
# pegado en .saikit/scratch/V/tdd.md). El driver ahora trae los cuatro casos
# del allowlist y ESTE test lo mete a la batería.
#
# El symlink de openclaw se re-crea acá mismo con las cuatro líneas que la
# propia skill trae en su sección Drive: `node --test` (que corre ANTES en
# run-checks.sh) borra summa-gate/node_modules/openclaw en su teardown, así que
# este test no puede asumir que el enlace sobrevivió — por eso pasa igual
# corriendo después de la batería del plugin. Al terminar, borra el enlace.
#
# Uso: bash scripts/tests/test-drive-merge-guard.sh
set -u
cd "$(dirname "$0")/../.." || exit 1

elegir_node() {
  local c v
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v=$("$c" --version 2>/dev/null | sed 's/^v//;s/\..*//')
    [ -n "$v" ] && [ "$v" -ge 22 ] 2>/dev/null && { echo "$c"; return 0; }
  done
  return 1
}
NODE=$(elegir_node) || { echo "FAIL: no hay un node >= 22 disponible"; exit 1; }

# Las cuatro líneas de SKILL.md (sección Drive): OPENCLAW_NODE_MODULES primero
# porque en CI (ubuntu-latest) apunta al node_modules del workspace.
OC="${OPENCLAW_NODE_MODULES:-$HOME/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw}"
test -d "$OC" || { echo "FAIL: no hay instalacion de openclaw en $OC"; exit 1; }
( cd summa-gate && mkdir -p node_modules && { [ -e node_modules/openclaw ] || ln -s "$OC" node_modules/openclaw; } ) \
  || { echo "FAIL: no se pudo crear el symlink summa-gate/node_modules/openclaw"; exit 1; }
trap 'rm -f summa-gate/node_modules/openclaw' EXIT

SALIDA=$("$NODE" docs/agent-skills/verify/drive-merge-guard.ts 2>&1)
rc=$?

if [ $rc -ne 0 ]; then
  echo "FAIL: el driver del merge-guard salió $rc"
  printf '%s\n' "$SALIDA" | tail -15 | sed 's/^/  /'
  exit 1
fi

# El exit 0 solo no prueba que corrió lo que dice: sin esto, borrarle casos al
# driver (mientras los restantes siguen pasando) dejaría este test en verde.
# La línea final declara cuántos casos corrió y el DoD la fija en 10.
if ! printf '%s\n' "$SALIDA" | grep -q '^DRIVE VERDE: 10 casos'; then
  echo "FAIL: el driver no reportó los 10 casos esperados"
  printf '%s\n' "$SALIDA" | tail -3 | sed 's/^/  /'
  exit 1
fi

printf '%s\n' "$SALIDA" | tail -1
echo "OK: drive-merge-guard corrió y cerró en verde"

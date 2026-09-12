#!/bin/bash
# Corre los candados de este repo: la bateria del plugin summa-gate y las pruebas de
# contrato de scripts/tests/.
#
# Por que existe este archivo y no solo pasos en el workflow: hasta 2026-09-12 los
# candados no corrian en ningun lado. El workflow de CI nunca se habia commiteado, y su
# paso de Node estaba condicionado a un `package.json` en la raiz que este repo no tiene,
# asi que se saltaba entero. Consecuencia medida: `test-browser-profile-flag.sh` llevaba
# dias en rojo en `origin/main` sin que nadie lo supiera, porque nada la ejecutaba.
#
# Una sola definicion, tres consumidores: el hook de pre-commit, el workflow de CI, y un
# humano que quiera correrlos a mano. Si divergen, vuelve a pasar lo mismo.
#
# Vive en scripts/ y NO en tools/: `tools/` esta en .gitignore de este repo, asi que un
# script ahi no llega a nadie mas — el mismo defecto que el `/tmp/render-corpus-tsv.ts`
# que este bloque corrigio. Un `git add` de tools/ falla en silencio salvo con -f.
#
# Uso:  bash scripts/run-checks.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

fallas=0
paso() { printf '\n=== %s\n' "$1"; }

# --- node: las pruebas del plugin son .ts y `node --test` las corre por type stripping
# nativo, que existe desde 22.6. El node del PATH puede ser mas viejo (o no estar), asi
# que se elige explicitamente en vez de confiar en el default.
elegir_node() {
  local c
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    local v; v=$("$c" --version 2>/dev/null | sed 's/^v//;s/\..*//')
    [ -n "$v" ] && [ "$v" -ge 22 ] 2>/dev/null && { echo "$c"; return 0; }
  done
  return 1
}

NODE=$(elegir_node) || {
  echo "FAIL: no hay un node >= 22 disponible; la bateria del plugin no puede correr." >&2
  echo "      (no se saltea en silencio: un candado que no corre es un candado que no existe)" >&2
  exit 1
}

paso "bateria summa-gate  (node $("$NODE" --version))"
if (cd summa-gate && "$NODE" --test); then
  echo "OK: bateria summa-gate"
else
  echo "FAIL: bateria summa-gate"; fallas=$((fallas + 1))
fi

# Cross-review de qwen (2026-09-12): este script imprimia "TODO VERDE" con exit 0 en un
# arbol SIN una sola prueba — el `for` no encontraba nada y el `if -f` de verify-corpus se
# salteaba en silencio. O sea el candado escrito para que los candados no fueran decorativos
# podia decir verde sin correr nada, contradiciendo su propia cabecera. Ahora exige encontrar
# lo que tiene que correr.
paso "pruebas de contrato de scripts/"
corridas=0
for t in scripts/tests/*.sh; do
  [ -e "$t" ] || continue
  corridas=$((corridas + 1))
  if bash "$t" >/dev/null 2>&1; then
    printf '  OK    %s\n' "$(basename "$t")"
  else
    printf '  FALLA %s\n' "$(basename "$t")"
    bash "$t" 2>&1 | tail -3 | sed 's/^/        /'
    fallas=$((fallas + 1))
  fi
done

if [ "$corridas" -eq 0 ]; then
  echo "FAIL: no se encontro NINGUNA prueba en scripts/tests/ — un candado que no corre no existe"
  fallas=$((fallas + 1))
fi

paso "corpus de rendiciones re-derivable"
if [ -f summa-gate/verify-corpus.mjs ]; then
  if "$NODE" summa-gate/verify-corpus.mjs; then
    echo "OK: verify-corpus"
  else
    echo "FAIL: verify-corpus"; fallas=$((fallas + 1))
  fi
else
  # Antes esto se salteaba sin decir nada. Si el re-derivador desaparece, hay que enterarse.
  echo "FAIL: falta summa-gate/verify-corpus.mjs (el corpus deja de ser re-derivable)"
  fallas=$((fallas + 1))
fi

printf '\n'
if [ "$fallas" -eq 0 ]; then
  echo "TODO VERDE"
else
  echo "$fallas comprobacion(es) en rojo"
  exit 1
fi

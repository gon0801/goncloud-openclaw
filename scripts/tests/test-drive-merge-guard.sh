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
# corriendo después de la batería del plugin.
#
# r1: el enlace puede preexistir y el estado inicial se restaura (respaldo con
# mv, devolución al terminar). r2 (cross-review codex), tres huecos cerrados:
#   1. El trap se arma ANTES de tocar el enlace: cualquier fallo posterior
#      (incluso el propio ln de reposición) devuelve el estado original.
#   2. La restauración verifica CADA paso y nunca calla una pérdida: si no se
#      puede restaurar, exit != 0 con el diagnóstico y la ruta del respaldo
#      para recuperación manual. Sin `|| true` en el camino del enlace.
#   3. La preservación se PRUEBA: un caso planta un enlace preexistente, corre
#      este mismo script como subproceso y exige que el enlace siga ahí
#      apuntando al mismo destino. Con el trap revertido al `rm -f` de r1, ese
#      caso se pone rojo (corridas pegadas en tdd.md, sección r2).
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

LINK=summa-gate/node_modules/openclaw
RESPALDO_DIR=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
RESPALDO="$RESPALDO_DIR/openclaw.respaldo"
PREEXISTIA=0

# r2 hueco 1: el trap se arma ANTES de tocar el enlace. La restauración es la
# única dueña del estado: devuelve el original si llegó a respaldarse, no toca
# nada si el respaldo nunca se hizo (el mv falló y el original sigue en su
# sitio), y retira lo de esta corrida si no había original.
restaurar_enlace() {
  if [ "$PREEXISTIA" -eq 1 ]; then
    if [ -e "$RESPALDO" ] || [ -L "$RESPALDO" ]; then
      rm -f "$LINK" || {
        echo "FAIL restauración: no se pudo sacar el enlace de esta corrida ($LINK)." \
             "Original a salvo en $RESPALDO — recuperar a mano: mv '$RESPALDO' '$LINK'" >&2
        exit 1
      }
      mv "$RESPALDO" "$LINK" || {
        echo "FAIL restauración: no se pudo devolver el enlace original a $LINK." \
             "RECUPERAR A MANO: mv '$RESPALDO' '$LINK' (respaldo conservado)" >&2
        exit 1
      }
      if ! rmdir "$RESPALDO_DIR" 2>/dev/null; then
        echo "aviso: quedó el directorio de respaldo vacío $RESPALDO_DIR" >&2
      fi
    fi
    # Sin respaldo: el mv inicial falló y el original NUNCA se movió de $LINK.
    # Tocar algo acá sería destruir el estado que este test promete cuidar.
  else
    if [ -e "$LINK" ] || [ -L "$LINK" ]; then
      rm -f "$LINK" || {
        echo "FAIL limpieza: no se pudo retirar el enlace que esta corrida creó ($LINK)" >&2
        exit 1
      }
    fi
    if ! rmdir "$RESPALDO_DIR" 2>/dev/null; then
      echo "aviso: quedó el directorio de respaldo vacío $RESPALDO_DIR" >&2
    fi
  fi
}
trap restaurar_enlace EXIT

if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  PREEXISTIA=1
  mv "$LINK" "$RESPALDO" || { echo "FAIL: no se pudo respaldar $LINK"; exit 1; }
fi

( cd summa-gate && mkdir -p node_modules && { [ -e node_modules/openclaw ] || ln -s "$OC" node_modules/openclaw; } ) \
  || { echo "FAIL: no se pudo crear el symlink summa-gate/node_modules/openclaw"; exit 1; }

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

# r2 hueco 3: la preservación del enlace preexistente es un caso del test, no
# una promesa del comentario. Planta un enlace, corre el flujo COMPLETO como
# subproceso (este mismo script; el marcador evita la recursión) y exige que el
# enlace preexistente siga existiendo y apuntando al mismo destino. El enlace
# se planta hacia $OC —el openclaw real— porque la corrida hija lo usa para
# importar el plugin.
if [ -z "${PRESERVACION_HIJO:-}" ]; then
  # A esta altura $LINK es el enlace de ESTA corrida (el original, si lo hubo,
  # está respaldado): se retira para plantar el de la prueba.
  rm -f "$LINK" || { echo "FAIL preservación: no se pudo retirar el enlace propio para plantar"; exit 1; }
  ln -s "$OC" "$LINK" || { echo "FAIL preservación: no se pudo plantar el enlace de prueba"; exit 1; }
  PLANTADO=$(readlink "$LINK")
  SALIDA_HIJO=$(PRESERVACION_HIJO=1 bash "$0" 2>&1)
  rc_hijo=$?
  if [ $rc_hijo -ne 0 ]; then
    echo "FAIL preservación: la corrida hija salió $rc_hijo"
    printf '%s\n' "$SALIDA_HIJO" | tail -6 | sed 's/^/  /'
    rm -f "$LINK"
    exit 1
  fi
  if ! test -L "$LINK" || [ "$(readlink "$LINK")" != "$PLANTADO" ]; then
    echo "FAIL preservación: el enlace preexistente no sobrevivió a la corrida (test -L o destino cambiado)"
    rm -f "$LINK"
    exit 1
  fi
  rm -f "$LINK"
  echo "ok preservación: un enlace preexistente sobrevivió a la corrida apuntando a $PLANTADO"
fi

echo "OK: drive-merge-guard corrió, cerró en verde y preservó el enlace preexistente"

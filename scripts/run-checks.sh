#!/bin/bash
# Corre los candados de este repo: la bateria del plugin summa-gate, las pruebas de
# contrato de scripts/tests/ y el corpus de rendiciones.
#
# Por que existe este archivo y no solo pasos en el workflow: hasta 2026-09-12 los
# candados no corrian en ningun lado. El workflow de CI nunca se habia commiteado, y su
# paso de Node estaba condicionado a un `package.json` en la raiz que este repo no tiene,
# asi que se saltaba entero. Consecuencia medida: `test-browser-profile-flag.sh` llevaba
# dias en rojo en `origin/main` sin que nadie lo supiera, porque nada la ejecutaba.
#
# Una sola definicion, dos consumidores: el workflow de CI y un humano que quiera correrla
# a mano. Pre-commit conserva solo validaciones rapidas de archivos; la bateria completa
# corre una vez en CI por PR. Si los entrypoints divergen, vuelve a pasar lo mismo.
#
# Vive en scripts/ y NO en tools/: `tools/` esta en .gitignore de este repo, asi que un
# script ahi no llega a nadie mas — el mismo defecto que el `/tmp/render-corpus-tsv.ts`
# que este bloque corrigio. Un `git add` de tools/ falla en silencio salvo con -f.
#
# Fase 15.1 — inventario, logs y shards. Tres cambios de contrato:
#
#   SAIKIT_SHARD=i/5  la porcion i del reparto (i de 1 a 5)
#   sin SAIKIT_SHARD  la bateria completa, como siempre
#   --reparto         imprime el reparto (shard, peso, entrada) y no corre nada
#
# El reparto es por DURACION MEDIDA, no por nombre: hasta 2026-10-12 el shard 3/3 era "el
# resto" y tardaba 24 min contra 4 de los otros dos (run 38304658354). Cada entrada del
# inventario lleva el peso en segundos de scripts/ci-duraciones.tsv (1 si no esta medida) y
# se asigna, de la mas pesada a la mas liviana, al shard menos cargado. Es determinista:
# mismo inventario y mismos pesos dan el mismo reparto en los cinco runners, y por eso la
# union de los cinco es exactamente la bateria de siempre, con cada entrada una vez. El
# inventario shell sale del glob scripts/tests/*.sh (un test nuevo entra solo, sin tocar
# este archivo ni el workflow), con una excepcion documentada abajo:
# test-ci-coverage-contract.sh corre una vez por PR en el job ci-contract, no
# en los shards. Los pesos solo deciden el balance: un peso viejo o ausente
# desbalancea, nunca saca una entrada de la union. Un shard invalido (6/5, 1/3, x) sale 2
# ANTES de correr nada, y un arbol sin pruebas shell sale en rojo en cada shard.
#
# Cada entrada registra duracion, resultado y un log propio en logs/run-checks/ (que esta
# en .gitignore: salida de maquina, no fuente): resumen.txt (una linea por entrada:
# resultado, duracion_s, exit, id, log) y <entrada>.log con la salida COMPLETA y el exit
# code real al pie. Una entrada roja conserva esa PRIMERA salida — antes se re-ejecutaba
# la prueba para mostrar su cola, lo que duplicaba corridas caras y podia pintar distinto
# (una prueba que limpia su estado en la primera pasada sale 0 la segunda vez y el
# "diagnostico" miente). La duracion es en segundos enteros: date +%s es lo unico
# portable entre BSD y GNU sin sumar dependencias.
#
# Uso:  bash scripts/run-checks.sh
#       SAIKIT_SHARD=i/5 bash scripts/run-checks.sh
#       bash scripts/run-checks.sh --reparto
set -uo pipefail
# Algunos runners pueden exportar GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE/GIT_PREFIX al
# correr la bateria: cualquier prueba que arme un repo con git escaparia al repo real
# (Fase 9: el indice quedo con 16 archivos y origin/main movido). Se limpian aqui para
# todas las pruebas; cada prueba con git propio tambien se protege sola.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
cd "$(dirname "$0")/.." || exit 1

fallas=0
paso() { printf '\n=== %s\n' "$1"; }

# --- shards: la validacion va ANTES de correr cualquier cosa. Un valor invalido no es
# "corre lo que puedas": es un typo del workflow, y correr una porcion cualquiera de la
# bateria con cara de exito seria el falso verde que este archivo existe para impedir.
SHARDS_N=5
PESOS=scripts/ci-duraciones.tsv
SHARD=
if [ -z "${SAIKIT_SHARD:-}" ]; then
  SHARD=todo
else
  k=1
  while [ "$k" -le "$SHARDS_N" ]; do
    if [ "$SAIKIT_SHARD" = "$k/$SHARDS_N" ]; then SHARD=$k; fi
    k=$((k + 1))
  done
  if [ -z "$SHARD" ]; then
    echo "FAIL: SAIKIT_SHARD='${SAIKIT_SHARD}' no es un shard valido (1/$SHARDS_N a $SHARDS_N/$SHARDS_N; sin la variable, bateria completa)" >&2
    exit 2
  fi
fi

# --- inventario shell: SOLO el glob manda (Fase 15.1). Nadie mantiene una lista a mano
# que pueda quedarse corta: un archivo nuevo en scripts/tests/ ya esta en la bateria,
# con UNA excepcion: test-ci-coverage-contract.sh corre una sola vez por PR en el job
# ci-contract de quality.yml (sin condicion de omision); en este glob correria dos
# veces, una en un shard y otra en ci-contract. El gate genera su inventario con este
# MISMO filtro ("Auditar la union de los shards", quality.yml): si los dos filtros
# divergen, valida-union-shards.sh rebota ruidosamente (la union deja de ser el
# inventario).
shell_tests=()
for t in scripts/tests/*.sh; do
  [ -e "$t" ] || continue
  case $t in scripts/tests/test-ci-coverage-contract.sh) continue ;; esac
  shell_tests+=("$(basename "$t")")
done
node_tests=()
for t in scripts/tests/*.mjs; do
  [ -e "$t" ] || continue
  node_tests+=("$(basename "$t")")
done

# --- reparto: cada entrada (las cinco fijas de node/sintaxis/corpus y las del glob) va a
# UN shard. Salida de repartir: "<shard>\t<peso>\t<id>", una linea por entrada. El orden
# (peso descendente, id ascendente en orden C) va fijado con LC_ALL=C para que BSD y GNU
# sort repartan igual.
ENTRADAS_NODE="sintaxis-summa-gate bateria-summa-gate sintaxis-tablero-runbook bateria-tablero-runbook verify-corpus"
TAB=$(printf '\t')
repartir() {
  {
    printf '%s\n' $ENTRADAS_NODE
    printf '%s\n' ${shell_tests[@]+"${shell_tests[@]}"} ${node_tests[@]+"${node_tests[@]}"}
  } | awk -F'\t' -v pesos="$PESOS" '
      BEGIN {
        while ((getline l < pesos) > 0) {
          if (l ~ /^#/ || l == "") continue
          split(l, c, "\t"); p[c[2]] = c[1]
        }
      }
      $0 != "" { w = ($0 in p) ? p[$0] + 0 : 1; if (w < 1) w = 1; print w "\t" $0 }' \
    | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2 \
    | awk -F'\t' -v n="$SHARDS_N" '
      { m = 1; for (k = 2; k <= n; k++) if (c[k] + 0 < c[m] + 0) m = k
        c[m] += $1; print m "\t" $1 "\t" $2 }'
}
REPARTO=$(repartir)

if [ "${1:-}" = "--reparto" ]; then
  printf '%s\n' "$REPARTO" | LC_ALL=C sort -t "$TAB" -k1,1n -k2,2nr -k3,3
  printf '%s\n' "$REPARTO" | awk -F'\t' -v n="$SHARDS_N" '
    { c[$1] += $2; e[$1]++ }
    END { for (k = 1; k <= n; k++) printf "# shard %d/%d: %d s estimados, %d entradas\n", k, n, c[k], e[k] }'
  exit 0
fi

MIAS=$(printf '%s\n' "$REPARTO" | awk -F'\t' -v k="$SHARD" 'k == "todo" || $1 == k { print $3 }')
corre() { # $1=id de entrada -> 0 si esta corrida tiene que correrla
  case "
$MIAS
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# --- node: las pruebas del plugin son .ts y `node --test` las corre por type stripping
# nativo, que existe desde 22.6. El node del PATH puede ser mas viejo (o no estar), asi
# que se elige explicitamente en vez de confiar en el default. Solo se exige cuando este
# shard corre entradas node: uno que solo recibio shell no tiene por que romperse en una
# maquina sin node.
corre_node=0
for id in $ENTRADAS_NODE ${node_tests[@]+"${node_tests[@]}"}; do
  if corre "$id"; then corre_node=1; fi
done
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
NODE=
if [ "$corre_node" -eq 1 ]; then
  NODE=$(elegir_node) || {
    echo "FAIL: no hay un node >= 22 disponible; la bateria del plugin no puede correr." >&2
    echo "      (no se saltea en silencio: un candado que no corre es un candado que no existe)" >&2
    exit 1
  }
fi

# --- registro por entrada (Fase 15.1): UNA ejecucion, la primera salida al log.
# Cada invocacion escribe SU directorio (corrida-<marca>): una re-corrida del
# mismo shard nunca sobrescribe el resumen anterior (medido 2026-09-22: al
# truncar resumen.txt fijo, una segunda corrida dejaba el artifact como una
# corrida limpia y el gate no podia verla). El validador de la union rechaza un
# shard que trae mas de una corrida en su artifact.
LOGDIR="logs/run-checks/corrida-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$LOGDIR" || { echo "FAIL: no pude crear $LOGDIR" >&2; exit 1; }
RESUMEN="$LOGDIR/resumen.txt"
: >"$RESUMEN"
RC_ULT=0
DUR_ULT=0
ejecutar() { # $1=id, resto: funcion y args de la entrada
  local id=$1; shift
  local log="$LOGDIR/$id.log" t0
  t0=$(date +%s)
  printf '# entrada    : %s\n# inicio     : epoch %s\n' "$id" "$t0" >"$log"
  "$@" >>"$log" 2>&1
  RC_ULT=$?
  DUR_ULT=$(( $(date +%s) - t0 ))
  printf '# exit       : %s\n# duracion_s : %s\n' "$RC_ULT" "$DUR_ULT" >>"$log"
}
ok_entrada() { # $1=id
  printf '  OK    %s (%ss)\n' "$1" "$DUR_ULT"
  printf 'ok\t%s\t%s\t%s\t%s\n' "$DUR_ULT" "$RC_ULT" "$1" "$LOGDIR/$1.log" >>"$RESUMEN"
}
falla_entrada() { # $1=id $2=rc — la cola se lee del LOG, jamas se re-ejecuta
  printf '  FALLA %s (rc=%s, %ss)\n        primera salida completa: %s\n' \
    "$1" "$2" "$DUR_ULT" "$LOGDIR/$1.log"
  tail -3 "$LOGDIR/$1.log" | sed 's/^/        /'
  printf 'falla\t%s\t%s\t%s\t%s\n' "$DUR_ULT" "$2" "$1" "$LOGDIR/$1.log" >>"$RESUMEN"
  fallas=$((fallas + 1))
}
anotar_sin_log() { # $1=id sintetico $2=explicacion ya impresa: rojos que no llegaron a correr
  printf 'falla\t0\t2\t%s\t-\n' "$1" >>"$RESUMEN"
  fallas=$((fallas + 1))
}

cmd_sintaxis_summa()   { (cd summa-gate && PATH="$(dirname "$NODE"):$PATH" npm run check); }
cmd_bateria_summa()    { (cd summa-gate && "$NODE" --test); }
cmd_sintaxis_tablero() { (cd tablero-runbook && PATH="$(dirname "$NODE"):$PATH" npm run check); }
cmd_bateria_tablero()  { (cd tablero-runbook && "$NODE" --test --test-reporter tap --test-reporter-destination stdout); }
cmd_corpus()           { "$NODE" summa-gate/verify-corpus.mjs; }
cmd_shell()            { bash "scripts/tests/$1"; }
cmd_node_test()        { "$NODE" --test "scripts/tests/$1"; }

case "$SHARD" in
  todo) paso "bateria completa | logs y resumen en $LOGDIR" ;;
  *)    paso "shard $SAIKIT_SHARD | logs y resumen en $LOGDIR" ;;
esac

if corre sintaxis-summa-gate; then
  paso "sintaxis summa-gate  (node $("$NODE" --version))"
  ejecutar sintaxis-summa-gate cmd_sintaxis_summa
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada sintaxis-summa-gate; else falla_entrada sintaxis-summa-gate "$RC_ULT"; fi
fi

if corre bateria-summa-gate; then
  paso "bateria summa-gate  (node $("$NODE" --version))"
  ejecutar bateria-summa-gate cmd_bateria_summa
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada bateria-summa-gate; else falla_entrada bateria-summa-gate "$RC_ULT"; fi
fi

# --- tablero-runbook (Fase 7): mismos entrypoints que summa-gate, con UNA diferencia
# medida en Plans 7.3: `node --test` sobre un directorio sin pruebas sale 0 y reporta
# `# pass 0`, asi que el exit code solo no prueba que haya corrido nada. El guard de
# conteo exige al menos un pass; sin el, borrar todos los *.test.ts dejaria este bloque
# en verde y la bateria volveria a ser decorativa (el defecto que 5.2 ya corrigio una vez).
if corre sintaxis-tablero-runbook; then
  paso "sintaxis tablero-runbook  (node $("$NODE" --version))"
  ejecutar sintaxis-tablero-runbook cmd_sintaxis_tablero
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada sintaxis-tablero-runbook; else falla_entrada sintaxis-tablero-runbook "$RC_ULT"; fi
fi

if corre bateria-tablero-runbook; then
  paso "bateria tablero-runbook  (node $("$NODE" --version))"
  ejecutar bateria-tablero-runbook cmd_bateria_tablero
  LOG_TR="$LOGDIR/bateria-tablero-runbook.log"
  grep -E '^# (tests|pass|fail) ' "$LOG_TR" | sed 's/^/  /'
  if [ "$RC_ULT" -ne 0 ]; then
    # Sin esto la bateria solo imprime "# fail 1" y no QUE fallo: en CI, donde no se puede
    # correr nada a mano, eso cuesta una ronda entera por intento. Medido el 2026-09-17:
    # cinco rondas adivinando un fallo que solo ocurre en Linux.
    #
    # Los subtests anidados en TAP van indentados ("    not ok 17 - ..."), asi que un
    # `grep '^not ok '` no los ve: solo casa el resumen de la suite exterior, que no dice
    # nada util. Y el mensaje de error real viaja en un bloque YAML `error: |-` cuyo texto
    # esta en las lineas SIGUIENTES, mas indentadas — no en la linea `error:` misma. El
    # detalle vive en scripts/tap-detalle-fallas.awk (probado por
    # scripts/tests/test-run-checks-reporta-fallo.sh) para que sea la misma fuente que
    # corre aqui y la que la prueba verifica. Desde 15.1 el input es el LOG de la primera
    # (y unica) corrida, no una re-ejecucion.
    awk -f scripts/tap-detalle-fallas.awk "$LOG_TR" | head -40 | sed 's/^/  /'
    falla_entrada bateria-tablero-runbook "$RC_ULT"
  else
    pass_tr=$(sed -n 's/^# pass \([0-9][0-9]*\)[[:space:]]*$/\1/p' "$LOG_TR" | tail -1)
    pass_tr=${pass_tr:-0}
    if [ "$pass_tr" -eq 0 ]; then
      printf '  (reporto 0 pass — un candado que no corre no existe)\n'
      falla_entrada bateria-tablero-runbook "$RC_ULT"
    else
      ok_entrada bateria-tablero-runbook
    fi
  fi
fi

# Cross-review de qwen (2026-09-12): este script imprimia "TODO VERDE" con exit 0 en un
# arbol SIN una sola prueba — el `for` no encontraba nada y el `if -f` de verify-corpus se
# salteaba en silencio. O sea el candado escrito para que los candados no fueran decorativos
# podia decir verde sin correr nada, contradiciendo su propia cabecera. Ahora exige encontrar
# lo que tiene que correr. Con el reparto por duracion ya no hay "prueba estrella" de un
# shard que pueda faltar: el arbol sin pruebas shell es rojo en la bateria completa Y en
# cada shard, porque las cinco entradas fijas igual se reparten y un shard quedaria verde
# corriendo solo sintaxis.
paso "pruebas de contrato de scripts/ (${#shell_tests[@]} del glob)"
for id in ${shell_tests[@]+"${shell_tests[@]}"}; do
  corre "$id" || continue
  ejecutar "$id" cmd_shell "$id"
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada "$id"; else falla_entrada "$id" "$RC_ULT"; fi
done

for id in ${node_tests[@]+"${node_tests[@]}"}; do
  corre "$id" || continue
  ejecutar "$id" cmd_node_test "$id"
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada "$id"; else falla_entrada "$id" "$RC_ULT"; fi
done

if [ "${#shell_tests[@]}" -eq 0 ]; then
  echo "FAIL: no se encontro NINGUNA prueba en scripts/tests/ — un candado que no corre no existe"
  anotar_sin_log sin-pruebas-shell
fi

if corre verify-corpus; then
  paso "corpus de rendiciones re-derivable"
  if [ -f summa-gate/verify-corpus.mjs ]; then
    ejecutar verify-corpus cmd_corpus
    if [ "$RC_ULT" -eq 0 ]; then ok_entrada verify-corpus; else falla_entrada verify-corpus "$RC_ULT"; fi
  else
    # Antes esto se salteaba sin decir nada. Si el re-derivador desaparece, hay que enterarse.
    echo "  FALLA falta summa-gate/verify-corpus.mjs (el corpus deja de ser re-derivable)"
    anotar_sin_log falta-verify-corpus
  fi
fi

printf '\nresumen de la corrida: %s\n' "$RESUMEN"
if [ "$fallas" -eq 0 ]; then
  echo "TODO VERDE"
else
  echo "$fallas comprobacion(es) en rojo"
  exit 1
fi

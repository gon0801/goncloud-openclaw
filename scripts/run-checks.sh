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
#   SAIKIT_SHARD=1/3  solo scripts/tests/test-corrida-nucleo.sh
#   SAIKIT_SHARD=2/3  scripts/tests/test-tmux-activity-watch.sh + test-corrida-preflight.sh
#   SAIKIT_SHARD=3/3  el resto de scripts/tests/*.sh + Node (summa-gate y tablero-runbook)
#                     + sintaxis + corpus
#   sin SAIKIT_SHARD  la bateria completa, como siempre
#
# La union de los tres shards es exactamente la bateria de siempre: el inventario shell
# sale del glob scripts/tests/*.sh (un test nuevo entra solo, sin tocar este archivo ni
# el workflow) y las entradas node/sintaxis/corpus viven enteras en el shard 3. Un shard
# invalido (4/3, x) sale 2 ANTES de correr nada, y un shard valido cuya prueba ya no esta
# en el glob tambien sale en rojo: jamas un shard verde por no encontrar sus pruebas (el
# mismo principio que el guard de "corridas == 0" de mas abajo).
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
#       SAIKIT_SHARD=i/3 bash scripts/run-checks.sh
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
SHARD_NUCLEO=test-corrida-nucleo.sh
SHARD_WATCHDOG=test-tmux-activity-watch.sh
SHARD_PREFLIGHT=test-corrida-preflight.sh
case "${SAIKIT_SHARD:-}" in
  '') SHARD=todo ;;
  1/3|2/3|3/3) SHARD=${SAIKIT_SHARD%/*} ;;
  *)
    echo "FAIL: SAIKIT_SHARD='${SAIKIT_SHARD}' no es un shard valido (1/3, 2/3 o 3/3; sin la variable, bateria completa)" >&2
    exit 2
    ;;
esac

# --- inventario shell: SOLO el glob manda (Fase 15.1). Nadie mantiene una lista a mano
# que pueda quedarse corta: un archivo nuevo en scripts/tests/ ya esta en la bateria.
shell_tests=()
for t in scripts/tests/*.sh; do
  [ -e "$t" ] || continue
  shell_tests+=("$(basename "$t")")
done
node_tests=()
for t in scripts/tests/*.mjs; do
  [ -e "$t" ] || continue
  node_tests+=("$(basename "$t")")
done

shell_corre() { # $1=basename -> 0 si el shard actual tiene que correrlo
  case "$SHARD" in
    todo) return 0 ;;
    1) [ "$1" = "$SHARD_NUCLEO" ] ;;
    2) [ "$1" = "$SHARD_WATCHDOG" ] || [ "$1" = "$SHARD_PREFLIGHT" ] ;;
    3) [ "$1" != "$SHARD_NUCLEO" ] && [ "$1" != "$SHARD_WATCHDOG" ] && [ "$1" != "$SHARD_PREFLIGHT" ] ;;
  esac
}

glob_tiene() { # $1=basename: esta en el inventario que trajo el glob?
  local x
  for x in ${shell_tests[@]+"${shell_tests[@]}"}; do
    [ "$x" = "$1" ] && return 0
  done
  return 1
}

# --- node: las pruebas del plugin son .ts y `node --test` las corre por type stripping
# nativo, que existe desde 22.6. El node del PATH puede ser mas viejo (o no estar), asi
# que se elige explicitamente en vez de confiar en el default. Solo se exige cuando este
# shard corre entradas node: el 1 y el 2 son solo shell, y no tienen por que romperse
# en una maquina sin node.
corre_node=0
case "$SHARD" in todo|3) corre_node=1 ;; esac
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

if [ "$corre_node" -eq 1 ]; then
  paso "sintaxis summa-gate  (node $("$NODE" --version))"
  ejecutar sintaxis-summa-gate cmd_sintaxis_summa
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada sintaxis-summa-gate; else falla_entrada sintaxis-summa-gate "$RC_ULT"; fi

  paso "bateria summa-gate  (node $("$NODE" --version))"
  ejecutar bateria-summa-gate cmd_bateria_summa
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada bateria-summa-gate; else falla_entrada bateria-summa-gate "$RC_ULT"; fi

  # --- tablero-runbook (Fase 7): mismos entrypoints que summa-gate, con UNA diferencia
  # medida en Plans 7.3: `node --test` sobre un directorio sin pruebas sale 0 y reporta
  # `# pass 0`, asi que el exit code solo no prueba que haya corrido nada. El guard de
  # conteo exige al menos un pass; sin el, borrar todos los *.test.ts dejaria este bloque
  # en verde y la bateria volveria a ser decorativa (el defecto que 5.2 ya corrigio una vez).
  paso "sintaxis tablero-runbook  (node $("$NODE" --version))"
  ejecutar sintaxis-tablero-runbook cmd_sintaxis_tablero
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada sintaxis-tablero-runbook; else falla_entrada sintaxis-tablero-runbook "$RC_ULT"; fi

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
# lo que tiene que correr, y 15.1 agrega el caso espejo para shards: uno cuya prueba
# estrella desaparecio del glob (rename, borrado) revienta en vez de salir verde por vacio.
paso "pruebas de contrato de scripts/ (${#shell_tests[@]} del glob)"
case "$SHARD" in
  1)
    if ! glob_tiene "$SHARD_NUCLEO"; then
      printf '  FALLA el shard 1/3 esperaba %s y el glob no lo trae (renombrado o borrado)\n' "$SHARD_NUCLEO"
      anotar_sin_log "shard1-sin-$SHARD_NUCLEO"
    fi
    ;;
  2)
    for esperada in "$SHARD_WATCHDOG" "$SHARD_PREFLIGHT"; do
      if ! glob_tiene "$esperada"; then
        printf '  FALLA el shard 2/3 esperaba %s y el glob no lo trae (renombrado o borrado)\n' "$esperada"
        anotar_sin_log "shard2-sin-$esperada"
      fi
    done
    ;;
esac

corridas=0
for id in ${shell_tests[@]+"${shell_tests[@]}"}; do
  shell_corre "$id" || continue
  corridas=$((corridas + 1))
  ejecutar "$id" cmd_shell "$id"
  if [ "$RC_ULT" -eq 0 ]; then ok_entrada "$id"; else falla_entrada "$id" "$RC_ULT"; fi
done

if [ "$corre_node" -eq 1 ]; then
  for id in ${node_tests[@]+"${node_tests[@]}"}; do
    ejecutar "$id" cmd_node_test "$id"
    if [ "$RC_ULT" -eq 0 ]; then ok_entrada "$id"; else falla_entrada "$id" "$RC_ULT"; fi
  done
fi

case "$SHARD" in
  todo|3)
    if [ "$corridas" -eq 0 ]; then
      echo "FAIL: no se encontro NINGUNA prueba para este shard en scripts/tests/ — un candado que no corre no existe"
      anotar_sin_log sin-pruebas-shell
    fi
    ;;
esac

if [ "$corre_node" -eq 1 ]; then
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

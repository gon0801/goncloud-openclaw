#!/usr/bin/env bash
# Arranca una fase entera con UN comando. Es lo que claw corre cuando el dueño
# dice "empieza la Fase N".
#
# POR QUE EXISTE. Medido el 2026-09-18, preparando la Fase 12: entregar un
# runbook "listo" todavia obligaba a pegar a mano dos comandos (crear el
# worktree del lead y llamar a lanzar-lead.sh con el mensaje correcto), y los
# dos tienen trampas que ya costaron horas: el lanzador aborta con "ATORADO cwd
# inexistente" si el worktree no existe ANTES; y el lead no puede leer un
# runbook que todavia no esta en la rama por defecto, que fue justo lo que el
# lector fresco de la Fase 12 encontro corriendo arranque-de-fase.sh (ROJO en
# las cinco comprobaciones). Un comando que resuelve las dos cosas solo es la
# diferencia entre "el runbook esta escrito" y "la fase puede empezar".
#
# La regla que implementa: un mecanismo que toda fase corre igual es un script,
# y el runbook lo cita; nunca la secuencia. Aqui vive la unica copia de esa
# secuencia.
#
# Uso:
#   bash scripts/lanzar-fase.sh <N> -- <cli> <flag-sin-preguntas>
#   bash scripts/lanzar-fase.sh <N> --dry-run -- <cli> <flag>   # no toca nada
#   bash scripts/lanzar-fase.sh <N> --rama <rama> -- <cli> <flag>
#   bash scripts/lanzar-fase.sh <N> --prompt '<regex>' -- <cli> <flag>
#   bash scripts/lanzar-fase.sh <N> --sesion <nombre> -- <cli> <flag>
#
# Que hace, en orden:
#   1. valida <N> con la misma gramatica de runbook.sh
#   2. decide de que rama sale el lead: --rama, o origin/<default> si el runbook
#      ya esta ahi, o la unica rama remota que lo traiga (eso es Q0 pendiente)
#   3. crea /Users/dn/dev/wt-f<N>-lead si falta (jamas --force)
#   4. arma el mensaje, con el sentinel de instrucciones y el primer paso
#   5. llama a lanzar-lead.sh, que es quien marca la sesion y comprueba el cwd
#
# Salida: la ultima linea es `LISTO fase<N>-lead <cwd>` o `ATORADO <razon>`.
# Codigos: 0 ok · 1 uso o fase invalida · 2 el runbook no esta en ninguna rama ·
#          3 no se pudo crear el worktree · el resto los propaga lanzar-lead.sh.
set -u

RAIZ=$(cd "$(dirname "$0")/.." && pwd)
GIT_BIN=${GIT_BIN:-git}
DEV=${DEV_DIR:-/Users/dn/dev}
DRY=0; RAMA=""; PROMPT=""; SESION_OPT=""; N=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --rama)    RAMA=${2:-}; shift 2 ;;
    --prompt)  PROMPT=${2:-}; shift 2 ;;
    --sesion)  [ -n "${2:-}" ] || { echo "ATORADO sesion invalida: vacia" >&2; exit 1; }; SESION_OPT=$2; shift 2 ;;
    --)        shift; break ;;
    -*)        echo "ATORADO opcion desconocida: $1" >&2; exit 1 ;;
    *)         if [ -z "$N" ]; then N=$1; shift; else echo "ATORADO sobra: $1" >&2; exit 1; fi ;;
  esac
done
CLI=${1:-}; shift 2>/dev/null || true
FLAGS="$*"

# Misma gramatica que runbook.sh: acepta 9 y 9.1; rechaza .9, 9., 9..1, 1234, a9.
case "$N" in
  ''|*[!0-9.]*) echo "ATORADO fase invalida: '${N}'" >&2; exit 1 ;;
esac
echo "$N" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3})?$' || { echo "ATORADO fase invalida: '$N'" >&2; exit 1; }
[ -n "$CLI" ] || { echo "ATORADO falta el CLI despues de --" >&2; exit 1; }

DOC="docs/runbooks/autopilot-fase${N}.md"
SESION="${SESION_OPT:-fase${N}-lead}"
if [ -n "$SESION_OPT" ]; then
  case "$SESION_OPT" in
    *[!A-Za-z0-9_-]*) echo "ATORADO sesion invalida: '$SESION_OPT'" >&2; exit 1 ;;
  esac
fi
CWD="$DEV/wt-f${N}-lead"

"$GIT_BIN" -C "$RAIZ" fetch -q origin 2>/dev/null || true
DEFAULT=$("$GIT_BIN" -C "$RAIZ" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
DEFAULT=${DEFAULT:-main}

# De donde sale el lead. Si el runbook ya esta en la rama por defecto, el lead
# nace detached ahi. Si no, sale de la rama que lo trae: su Q0 es integrarlo.
Q0="no"
if [ -n "$RAMA" ]; then
  ORIGEN="$RAMA"
  "$GIT_BIN" -C "$RAIZ" cat-file -e "$ORIGEN:$DOC" 2>/dev/null \
    || { echo "ATORADO la rama '$ORIGEN' no trae $DOC" >&2; exit 2; }
  [ "$ORIGEN" = "origin/$DEFAULT" ] || Q0="si"
elif "$GIT_BIN" -C "$RAIZ" cat-file -e "origin/$DEFAULT:$DOC" 2>/dev/null; then
  ORIGEN="origin/$DEFAULT"
else
  ORIGEN=$("$GIT_BIN" -C "$RAIZ" for-each-ref --format='%(refname:short)' refs/remotes/origin \
    | while read -r r; do
        "$GIT_BIN" -C "$RAIZ" cat-file -e "$r:$DOC" 2>/dev/null && echo "$r"
      done | head -1)
  [ -n "$ORIGEN" ] || { echo "ATORADO $DOC no esta en ninguna rama de origin (subelo primero)" >&2; exit 2; }
  Q0="si"
fi

if [ "$Q0" = "si" ]; then
  PRIMERO="tu primer item de cola es Q0, integrar el PR que trae este runbook y sus filas del plan"
else
  PRIMERO="el runbook y sus filas ya estan en origin/$DEFAULT, asi que saltas Q0 y empiezas en Q1"
fi

MENSAJE="Ejecuta la Fase ${N} siguiendo ${DOC} de este arbol, que hereda docs/runbooks/base-openclaw.md. Tu primer paso es el 0.0 del base; ${PRIMERO}. -saikit:autopilot"

echo "fase=$N"
echo "origen=$ORIGEN"
echo "q0-pendiente=$Q0"
echo "cwd=$CWD"
echo "sesion=$SESION"

if [ "$DRY" = "1" ]; then
  echo "mensaje=$MENSAJE"
  echo "DRY-RUN: crearia el worktree si falta y llamaria a lanzar-lead.sh"
  echo "LISTO $SESION $CWD"
  exit 0
fi

# El worktree tiene que existir ANTES: lanzar-lead.sh aborta con codigo 1 si no.
if [ ! -d "$CWD" ]; then
  if [ "$Q0" = "si" ]; then
    "$GIT_BIN" -C "$RAIZ" worktree add "$CWD" "${ORIGEN#origin/}" 2>/dev/null \
      || "$GIT_BIN" -C "$RAIZ" worktree add "$CWD" --detach "$ORIGEN" \
      || { echo "ATORADO no pude crear $CWD" >&2; exit 3; }
  else
    "$GIT_BIN" -C "$RAIZ" worktree add "$CWD" --detach "$ORIGEN" \
      || { echo "ATORADO no pude crear $CWD" >&2; exit 3; }
  fi
fi

set -- -s "$SESION" -c "$CWD" -m "$MENSAJE"
[ -n "$PROMPT" ] && set -- "$@" -p "$PROMPT"
# shellcheck disable=SC2086
exec bash "$RAIZ/scripts/lanzar-lead.sh" "$@" -- "$CLI" $FLAGS

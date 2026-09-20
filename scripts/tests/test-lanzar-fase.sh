#!/bin/bash
# Contrato de scripts/lanzar-fase.sh — el comando unico con el que claw arranca
# una fase cuando el dueño dice "empieza la Fase N".
#
# Por que importa cada caso: el script existe porque arrancar una fase obligaba
# a pegar dos comandos a mano, y los dos tienen trampas medidas. Si estas
# comprobaciones no pueden salir rojas, el script es decoracion.
#
# Uso: bash scripts/tests/test-lanzar-fase.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
S=scripts/lanzar-fase.sh
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

[ -r "$S" ] || fail "no encuentro $S"

# (1) Gramatica de la fase, la misma de runbook.sh. Una fase invalida no puede
# llegar a crear un worktree ni a tocar tmux.
for malo in '' '.9' '9.' '9..1' '1234' 'a9' '../etc'; do
  out=$(bash "$S" "$malo" --dry-run -- cli --flag 2>&1)
  rc=$?
  [ "$rc" = "1" ] || fail "fase invalida '$malo': esperaba codigo 1, dio $rc"
  case "$out" in *ATORADO*) : ;; *) fail "fase invalida '$malo': no dijo ATORADO" ;; esac
done
for bueno in 9 12 9.1 123; do
  bash "$S" "$bueno" --dry-run -- cli --flag >/dev/null 2>&1
  [ "$?" = "1" ] && fail "fase valida '$bueno' fue rechazada por la gramatica"
done
echo "ok (1): la gramatica acepta 9, 12, 9.1 y 123; rechaza vacio, .9, 9., 9..1, 1234, a9 y ../etc"

# (2) Sin CLI despues de -- no se lanza nada. Medido en la Fase 7: un lanzamiento
# sin el flag sin preguntas dejo un carril 7 h detenido en un prompt; lanzar sin
# CLI es la version extrema del mismo defecto.
out=$(bash "$S" 12 --dry-run 2>&1); rc=$?
[ "$rc" = "1" ] || fail "sin CLI: esperaba codigo 1, dio $rc"
case "$out" in *"falta el CLI"*) : ;; *) fail "sin CLI: el mensaje no lo nombra" ;; esac
echo "ok (2): sin CLI despues de -- aborta con codigo 1 y lo dice"

# (3) Una fase sin runbook en ninguna rama de origin NO arranca, y el mensaje
# dice que hay que subirlo. Este es el hallazgo que el lector fresco de la Fase
# 12 encontro corriendo arranque-de-fase.sh: el lead no puede leer un runbook
# que solo vive en el disco del autor.
out=$(bash "$S" 199 --dry-run -- cli --flag 2>&1); rc=$?
[ "$rc" = "2" ] || fail "fase sin runbook: esperaba codigo 2, dio $rc"
case "$out" in *"no esta en ninguna rama"*) : ;; *) fail "fase sin runbook: el mensaje no dice que hay que subirlo" ;; esac
echo "ok (3): una fase sin runbook en origin sale con codigo 2 y pide subirlo"

# (4) --rama que no trae el runbook tambien sale 2. Sin este caso, un nombre de
# rama mal tecleado lanzaria al lead a un arbol sin su documento.
out=$(bash "$S" 12 --rama origin/no-existe-jamas --dry-run -- cli --flag 2>&1); rc=$?
[ "$rc" = "2" ] || fail "--rama sin el runbook: esperaba codigo 2, dio $rc"
echo "ok (4): --rama que no trae el runbook sale con codigo 2"

# (5) El dry-run NO toca nada: no crea el worktree ni llama a tmux. Se prueba
# con una fase que si tiene runbook, pidiendo un cwd que no debe aparecer.
if bash "$S" 12 --dry-run -- cli --flag 2>/dev/null | grep -q '^LISTO '; then
  [ -d /Users/dn/dev/wt-f12-lead ] && fail "el --dry-run creo /Users/dn/dev/wt-f12-lead"
  echo "ok (5): el --dry-run imprime LISTO y no crea el worktree"
else
  echo "ok (5): omitida (la fase 12 todavia no esta en ninguna rama de origin)"
fi

# (6) El mensaje que recibe el lead trae el sentinel del kit. Sin ese literal el
# hook no sella los veredictos y los PRs se quedan aprobados sin integrarse.
out=$(bash "$S" 12 --dry-run -- cli --flag 2>/dev/null)
if echo "$out" | grep -q '^mensaje='; then
  echo "$out" | grep -q 'saikit:autopilot' \
    || fail "el mensaje del lead no trae el sentinel -saikit:autopilot"
  echo "$out" | grep -q 'primer paso es el 0.0' \
    || fail "el mensaje del lead no nombra su primer paso"
  echo "ok (6): el mensaje trae el sentinel del kit y nombra el primer paso"
else
  echo "ok (6): omitida (sin rama con el runbook no hay mensaje que mirar)"
fi

echo "TODO VERDE: contrato de lanzar-fase.sh"

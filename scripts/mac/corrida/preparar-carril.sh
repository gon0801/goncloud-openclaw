#!/bin/bash
# corrida/preparar-carril.sh (Fase 14, Task 4). Reserva atomica de un carril:
# rama + worktree propios desde origin/<default> recien traido, tope de
# cuatro harnesses activos bajo el lock del run. Imprime el worktree
# canonico. Si el worktree no se crea, re-adquiere el lock y libera solo su
# token: una reserva ajena no se toca.
# Uso: corrida.sh preparar-carril <id> <carril> <repo> [--read-only]
corrida_preparar_carril() {
  [ "$#" -ge 3 ] || { echo "uso: corrida.sh preparar-carril <id> <carril> <repo> [--read-only]" >&2; return 2; }
  local id="$1" carril="$2" repo="$3"; shift 3
  local modo="write"
  while [ $# -gt 0 ]; do
    case "$1" in
      --read-only) modo="read-only"; shift;;
      *) echo "preparar-carril: flag desconocido $1" >&2; return 2;;
    esac
  done
  corrida_id_valido "$id" || { echo "preparar-carril: id invalido: $id" >&2; return 2; }
  corrida_id_valido "$carril" || { echo "preparar-carril: carril invalido: $carril" >&2; return 2; }
  # El entorno heredado manda sobre `git -C`: un GIT_DIR/GIT_WORK_TREE ajeno
  # operaria sobre otro repo. Se sueltan antes de cada git (identidad y
  # config —AUTHOR, CONFIG— no se tocan).
  unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local estado; estado="$(json_campo "$reg" estado)"
  [ "$estado" = "abierta" ] || { echo "preparar-carril: la corrida $id no esta abierta (estado: $estado)" >&2; return 1; }
  [ -d "$repo" ] || { echo "preparar-carril: sin repo: $repo" >&2; return 1; }
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "preparar-carril: no es repo git: $repo" >&2; return 1; }
  # Traer ANTES de resolver la rama por defecto: la base es el remoto, no
  # el clon. Con reintento acotado: los carriles de una corrida traen a la
  # vez y git niega el lock del ref a los perdedores (medido en la carrera
  # de Task 4); el fallo persistente tras 5 intentos si es de red.
  local intento=0
  while ! git -C "$repo" fetch origin --quiet 2>/dev/null; do
    intento=$((intento+1))
    if [ "$intento" -ge 5 ]; then
      echo "preparar-carril: no se pudo traer origin" >&2; return 1
    fi
    sleep 0.3
  done
  local default
  default="$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')"
  if [ -z "$default" ]; then
    if git -C "$repo" show-ref --verify --quiet refs/remotes/origin/main; then default="main"
    elif git -C "$repo" show-ref --verify --quiet refs/remotes/origin/master; then default="master"
    else echo "preparar-carril: sin rama por defecto en origin" >&2; return 1; fi
  fi
  local base; base="$(git -C "$repo" rev-parse "origin/$default" 2>/dev/null)" \
    || { echo "preparar-carril: sin base origin/$default" >&2; return 1; }
  local rama="corrida/$id/$carril"
  mkdir -p "$repo/.worktrees" \
    || { echo "preparar-carril: no se pudo crear .worktrees" >&2; return 1; }
  local fis canon
  fis="$(CDPATH= cd -P -- "$repo/.worktrees" && pwd)" \
    || { echo "preparar-carril: sin worktree canonico" >&2; return 1; }
  canon="$fis/$id-$carril"
  local token="$$-${RANDOM:-0}"
  if ! lock_tomar "$reg"; then
    echo "preparar-carril: lock del registro de $id no cede" >&2; return 1
  fi
  if [ "$(json_campo "$reg" estado)" != "abierta" ]; then
    lock_soltar "$reg"
    echo "preparar-carril: la corrida $id se cerro; no se reserva $carril" >&2; return 1
  fi
  # Barrido best-effort de reservas huerfanas antes de contar: una reserva
  # interrumpida (kill entre el unlock y el worktree add) no consume cupo
  # para siempre. Si el barrido falla, se sigue como antes.
  registro_barrer_reservas_huerfanas "$reg" >/dev/null 2>&1 || true
  local activos
  activos="$(registro_contar_harnesses_activos "$reg")"
  case "$activos" in ''|*[!0-9]*)
    lock_soltar "$reg"; echo "preparar-carril: no se pudo contar carriles activos" >&2; return 1;; esac
  [ "$activos" -lt 4 ] || { lock_soltar "$reg"; echo "capacidad agotada" >&2; return 1; }

  registro_worktree_libre "$reg" "$canon" \
    || { lock_soltar "$reg"; echo "preparar-carril: worktree ya reservado: $canon" >&2; return 1; }
  local rrc=0
  registro_reservar_carril "$reg" "$carril" "$canon" "$rama" "$base" "$modo" "$token" || rrc=$?
  if [ "$rrc" -eq 2 ]; then
    lock_soltar "$reg"; echo "preparar-carril: carril ya reservado: $carril" >&2; return 1
  fi
  if [ "$rrc" -ne 0 ]; then
    lock_soltar "$reg"; echo "preparar-carril: no se pudo reservar $carril" >&2; return 1
  fi
  lock_soltar "$reg"
  if ! git -C "$repo" worktree add -b "$rama" "$canon" "origin/$default" >/dev/null 2>&1; then
    if lock_tomar "$reg" 2>/dev/null; then
      registro_liberar_carril "$reg" "$carril" "$token" 2>/dev/null || true
      lock_soltar "$reg"
    fi
    echo "preparar-carril: no se pudo crear el worktree $canon" >&2
    return 1
  fi
  printf '%s\n' "$canon"
}

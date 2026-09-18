#!/bin/bash
# corrida/preflight.sh (9.3). preflight <id>: lo que fallo esa noche se prueba antes
# de arrancar. Imprime APTO o NO APTO <razones>; NO APTO no lanza y manda mensaje.
# Inyectables para pruebas: CORRIDA_STATE, OPENCLAW_BIN, TMUX_BIN, GH_BIN, REPO_DIR,
# WATCH_INSTALADO, CORRIDA_CANDADO_<CLASE> (permitido|negado|unknown). Bash 3.2.
corrida_preflight() {
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
  local id="$1"
  corrida_id_valido "$id" || { echo "NO APTO id invalido: $id"; return 2; }
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "NO APTO sin registro: $id"; return 1; }
  # Las sesiones de prueba (preflight-<id>-<cli>) mueren aunque un Ctrl-C corte a mitad:
  # un CLI real lanzado en modo sin preguntas no puede quedarse vivo por un interrupt.
  PF_ID="$id"
  pf_limpiar() {
    local s
    for s in "$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep "^preflight-$PF_ID-")"; do
      "$TMUX_BIN" kill-session -t "=$s" 2>/dev/null
    done
  }
  trap pf_limpiar EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  local GH="${GH_BIN:-$(command -v gh 2>/dev/null || echo gh)}"
  local REPO="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local WATCH="${WATCH_INSTALADO:-$HOME/bin/tmux-activity-watch.sh}"
  local razones="" unknowns=""

  razon() { razones="$razones
- $1"; }
  unknown() { unknowns="$unknowns
- $1"; }

  # (1) gh autenticado y con una lectura real.
  local login=""
  if "$GH" auth status >/dev/null 2>&1; then
    login="$("$GH" api user -q .login 2>/dev/null)" || login=""
    [ -n "$login" ] || razon "gh sin lectura real"
  else
    razon "gh sin autenticar"
  fi

  # (2) cada binario con flag conocido arranca bajo PATH minimo y el flag entra.
  local tabla; tabla="$(json_campo "$reg" cli_modos)"
  if [ ! -r "$tabla" ]; then
    razon "tabla de modos ilegible: $tabla"
  else
  local cli binario flag barra fila
  for cli in $(awk -F'\t' '$1 !~ /^#/ && $1 != "" {print $1}' "$tabla" 2>/dev/null); do
    fila="$(tsv_fila "$tabla" "$cli")"
    binario="$(printf '%s' "$fila" | cut -d'|' -f1)"
    flag="$(printf '%s' "$fila" | cut -d'|' -f2)"
    barra="$(printf '%s' "$fila" | cut -d'|' -f3)"
    [ "$flag" = "unknown" ] || [ -z "$flag" ] && { unknown "flag de $cli sin medir"; continue; }
    [ "$barra" != "unknown" ] && [ -z "$barra" ] && { razon "barra vacia en la tabla: $cli"; continue; }
    local bin
    bin="$(bash -c "PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:\$PATH; command -v $binario" 2>/dev/null)" \
      || { razon "binario no arranca: $cli"; continue; }
    local psn="preflight-$id-$cli" embebido="PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
    "$TMUX_BIN" has-session -t "=$psn" 2>/dev/null && "$TMUX_BIN" kill-session -t "=$psn" 2>/dev/null
    if "$TMUX_BIN" new-session -d -s "$psn" -x 80 -y 10 "$embebido $bin $flag" 2>/dev/null; then
      sleep 2
      if "$TMUX_BIN" has-session -t "=$psn" 2>/dev/null; then
        if [ "$barra" = "unknown" ]; then
          unknown "barra de $cli sin medir"
        else
          "$TMUX_BIN" capture-pane -p -t "=$psn:" 2>/dev/null | grep -qF -- "$barra" \
            || razon "flag no entra: $cli"
        fi
      else
        razon "binario muere al arrancar: $cli"
      fi
      "$TMUX_BIN" kill-session -t "=$psn" 2>/dev/null
    else
      razon "binario muere al arrancar: $cli"
    fi
  done
  fi

  # (3) vigilante corriendo y con el mismo blob que origin/<default>.
  if pgrep -f 'bin/tmux-activity-watch.sh' >/dev/null 2>&1; then
    local def Esperado instalado
    def="$(git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -z "$def" ] && def="main"
    Esperado="$(git -C "$REPO" rev-parse "origin/$def:scripts/mac/tmux-activity-watch.sh" 2>/dev/null)"
    instalado="$(git hash-object "$WATCH" 2>/dev/null)"
    if [ -n "$Esperado" ] && [ -n "$instalado" ]; then
      [ "$Esperado" = "$instalado" ] || razon "vigilante viejo"
    else
      unknown "blob del vigilante sin comparar"
    fi
  else
    razon "vigilante no corre"
  fi

  # (4) gateway responde.
  "$OPENCLAW_BIN" gateway call status --timeout 30000 >/dev/null 2>&1 \
    || razon "gateway no responde"

  # (5) message send --dry-run al canal de seguimiento.
  local dest; dest="$(json_campo "$reg" canal.destino)"
  if [ -n "$dest" ]; then
    "$OPENCLAW_BIN" message send --channel telegram -t "$dest" --dry-run --json -m "prueba" >/dev/null 2>&1 \
      || razon "sin envio al canal"
  else
    razon "registro sin destino"
  fi

  # (6) cada clase que el runbook declara O usa, contra los candados; y clases
  # usadas sin declarar. La DoD dice "cada clase que el runbook declara": una clase
  # declarada en la tabla y usada en prosa tambien se prueba.
  local runbook; runbook="$(json_campo "$reg" runbook)"
  local rb="$REPO/$runbook"
  if [ -f "$rb" ]; then
    local declaradas=" "
    declaradas="$declaradas$(sed -n '/## Clases de comando/,$p' "$rb" | grep -iE '\|( *`?)(ssh|red externa|psql|gh)(`? *\|)' | tr 'A-Z' 'a-z' | grep -oE 'ssh|red externa|psql|gh' | sort -u | tr '\n' ' ')"
    local usadas usadas_clases=" " u clase
    usadas="$(awk '/^```/{f=!f;next} f' "$rb" | grep -oE '(^|[^a-z-])(ssh|curl|wget|psql|gh)([^a-z-]|$)' | grep -oE 'ssh|curl|wget|psql|gh' | sort -u)"
    for u in $usadas; do
      case "$u" in curl|wget) clase="red externa";; *) clase="$u";; esac
      printf '%s' "$usadas_clases" | grep -qF " $clase " || usadas_clases="$usadas_clases $clase "
    done
    for clase in $usadas_clases; do
      printf '%s' "$declaradas" | grep -qF " $clase " \
        || razon "clase sin declarar: $clase"
    done
    local union="$declaradas$usadas_clases" cr
    for clase in ssh "red externa" psql gh; do
      printf '%s' "$union" | grep -qF " $clase " || continue
      candado_clase "$clase"; cr=$?
      [ "$cr" -eq 1 ] && razon "clase negada: $clase"
      [ "$cr" -eq 2 ] && unknown "clase sin medir: $clase"
    done
  else
    razon "runbook sin leer: $runbook"
  fi

  if [ -n "$razones" ]; then
    printf 'NO APTO%s\n' "$razones"
    [ -n "$unknowns" ] && printf 'QUEDA unknown:%s\n' "$unknowns"
    corrida_mensaje "$id" "DETENIDA" "la revision previa no paso y no se arranca" \
      "se revisa lo encontrado y se vuelve a intentar" "nada" >/dev/null 2>&1
    return 1
  fi
  printf 'APTO\n'
  [ -n "$unknowns" ] && printf 'QUEDA unknown:%s\n' "$unknowns"
  return 0
}

# candado_clase <clase>: 0 = permitido; 1 = NECESITA HUMANO (negado o binario ausente).
candado_clase() {
  local clase="$1" ovn ov
  ovn="CORRIDA_CANDADO_$(printf '%s' "$clase" | tr ' ' '_')"
  ov="${!ovn:-}"
  case "$ov" in permitido) return 0;; negado) return 1;; esac
  case "$clase" in
    gh) command -v "${GH_BIN:-gh}" >/dev/null 2>&1 && "$GH" auth status >/dev/null 2>&1 && return 0; return 1;;
    ssh) command -v ssh >/dev/null 2>&1 || return 1; return 2;;
    red\ externa) command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1; return 2;;
    psql) command -v psql >/dev/null 2>&1 || return 1; return 2;;
    *) return 2;;
  esac
  return 2
}

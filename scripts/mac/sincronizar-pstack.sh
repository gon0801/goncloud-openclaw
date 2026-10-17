#!/bin/bash
# Mantiene pstack ORIGINAL (cursor/plugins) como la única copia de las skills de pstack en esta
# Mac, para Claude Code y para los agentes que leen ~/.agents/skills (opencode, Muse, Grok).
#
# preparar: baja cursor/plugins, toma el árbol de Claude Code de pstack
#   (harness/pstack/claude-code) y las skills de cursor-team-kit que usamos, y deja la copia en
#   $PSTACK_OFICIAL. Cambia dos cosas del frontmatter: `disable-model-invocation: true` pasa a
#   `false` (en Claude Code esa marca deja la skill solo para el usuario, y nuestros agentes la
#   invocan solos) y un `name` de exhibición toma el nombre de la carpeta. Si el árbol no trae lo
#   que esperamos (poteto-mode, poteto-agent, el adaptador, un mínimo de skills) o la marca sigue
#   en `true`, falla y deja la copia anterior como estaba.
# activar: apunta ~/.agents/skills/<skill> y ~/.claude/skills/<skill> a la copia, y
#   ~/.claude/agents/{poteto-agent,comment-sicko}.md a sus agentes. Lo que había antes y no era un
#   enlace a la copia se mueve a un respaldo con fecha, y los enlaces nuevos quedan anotados ahí
#   para que restaurar los quite. Repetirlo no cambia nada.
# Sin argumentos (lo que corre launchd): preparar y, si la copia ya está activa, activar.
# Una corrida que falla avisa por claw o, si claw no contesta, con una notificación de la Mac.
#
# Uso: sincronizar-pstack.sh [preparar | activar | estado]
# Reversa: sincronizar-pstack.sh restaurar <dir de respaldo> (lo imprime activar).
set -euo pipefail

RAIZ=${PSTACK_OFICIAL:-$HOME/.agents/pstack-oficial}
SKILLS_DIR=${PSTACK_SKILLS_DIR:-$HOME/.agents/skills}
CLAUDE_SKILLS=${PSTACK_CLAUDE_SKILLS:-$HOME/.claude/skills}
CLAUDE_AGENTS=${PSTACK_CLAUDE_AGENTS:-$HOME/.claude/agents}
MARCA=${PSTACK_MARCA_ACTIVA:-$HOME/.agents/.pstack-oficial-activo}
# Las skills que activar enlazó alguna vez: la limpieza de enlaces rotos solo toca estas.
GESTIONADAS=${PSTACK_GESTIONADAS:-$HOME/.agents/.pstack-oficial-gestionadas}
MIN_SKILLS=${PSTACK_MIN_SKILLS:-40}
# Las de cursor-team-kit que ya usábamos con el port; el resto del kit no se instala.
TEAM_KIT=${PSTACK_TEAM_KIT:-deslop fix-ci fix-merge-conflicts get-pr-comments make-pr-easy-to-review thermo-nuclear-code-quality-review what-did-i-get-done}
AGENTES="poteto-agent.md comment-sicko.md"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
falla() { log "FALLA: $*"; exit 1; }

avisar() {
  local texto="La sincronización nocturna de pstack con cursor/plugins falló: ${1:-sin detalle}. Las skills siguen en la copia anterior. Dile a David, tal cual, que le pida a Claude en la Mac revisar ~/Library/Logs/sincronizar-pstack.log."
  if [ -n "${PSTACK_AVISO_CMD:-}" ]; then
    "$PSTACK_AVISO_CMD" "$texto" || true
    return 0
  fi
  if "${OPENCLAW_BIN:-$HOME/.openclaw-r/openclaw}" agent --agent main --deliver --timeout 180 \
      --message "$texto" >/dev/null 2>&1; then
    log "aviso enviado por claw"
  elif /usr/bin/osascript -e 'display notification "La sincronización de pstack falló. Ver ~/Library/Logs/sincronizar-pstack.log" with title "pstack"' >/dev/null 2>&1; then
    log "aviso local (claw no contestó)"
  else
    log "no se pudo avisar"
  fi
}

# El tarball de cursor/plugins en main. PSTACK_TARBALL (un .tgz local) lo sustituye en las pruebas.
bajar() {
  local destino=$1
  if [ -n "${PSTACK_TARBALL:-}" ]; then
    cp "$PSTACK_TARBALL" "$destino"
  else
    gh api repos/cursor/plugins/tarball/main > "$destino"
  fi
}

frontmatter() { awk '$0 == "---" { d++; if (d == 2) exit; next } d == 1' "$1"; }

# Dos cambios, solo dentro del frontmatter (entre los dos primeros `---`): la marca pasa a
# false, y un `name` de exhibición ("Poteto Mode") toma el nombre de la carpeta, porque Claude
# Code identifica la skill por ese campo (minúsculas y guiones).
habilitar_skill() {
  local archivo=$1 tmp carpeta
  carpeta=$(basename "$(dirname "$archivo")")
  tmp=$(mktemp "${archivo}.XXXXXX")
  awk -v carpeta="$carpeta" 'NR == 1 && $0 != "---" { print; next }
       $0 == "---" { delim++; print; next }
       delim == 1 && /^disable-model-invocation:[[:space:]]*true[[:space:]]*$/ { print "disable-model-invocation: false"; next }
       delim == 1 && /^name:/ { print "name: " carpeta; next }
       { print }' "$archivo" > "$tmp"
  mv "$tmp" "$archivo"
}

preparar() {
  local top origen kit nueva n s
  # Global: el trap de salida la lee después de que preparar regresa.
  TRABAJO=$(mktemp -d)
  trap 'rm -rf "$TRABAJO" "$RAIZ.nueva"' EXIT
  local trabajo=$TRABAJO
  bajar "$trabajo/plugins.tgz" || falla "no se pudo bajar cursor/plugins"
  mkdir "$trabajo/x"
  tar -xzf "$trabajo/plugins.tgz" -C "$trabajo/x" || falla "el tarball de cursor/plugins no se pudo abrir"
  top=$(find "$trabajo/x" -mindepth 1 -maxdepth 1 -type d | head -1)
  origen="$top/harness/pstack/claude-code"
  kit="$top/cursor-team-kit/skills"
  [ -d "$origen/skills" ] || falla "cursor/plugins ya no trae harness/pstack/claude-code/skills"

  nueva="$RAIZ.nueva"
  rm -rf "$nueva"
  mkdir -p "$nueva"
  cp -R "$origen/." "$nueva/"
  for s in $TEAM_KIT; do
    [ -d "$kit/$s" ] || falla "cursor-team-kit ya no trae la skill $s"
    rm -rf "${nueva:?}/skills/$s"
    cp -R "$kit/$s" "$nueva/skills/$s"
  done
  for archivo in "$nueva"/skills/*/SKILL.md; do habilitar_skill "$archivo"; done

  [ -f "$nueva/skills/poteto-mode/SKILL.md" ] || falla "falta skills/poteto-mode"
  frontmatter "$nueva/skills/poteto-mode/SKILL.md" | grep -qx "name: poteto-mode" || falla "poteto-mode no quedó con name: poteto-mode"
  for a in $AGENTES; do [ -f "$nueva/agents/$a" ] || falla "falta agents/$a"; done
  [ -f "$nueva/docs/harness/claude-code.md" ] || falla "falta docs/harness/claude-code.md (el aviso de arranque lo manda leer)"
  n=$(find "$nueva/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
  [ "$n" -ge "$MIN_SKILLS" ] || falla "solo $n skills (mínimo $MIN_SKILLS)"
  for archivo in "$nueva"/skills/*/SKILL.md; do
    if frontmatter "$archivo" | grep -q -E '^disable-model-invocation:[[:space:]]*true'; then
      falla "$(basename "$(dirname "$archivo")") quedó con disable-model-invocation: true (el formato cambió)"
    fi
  done
  printf 'origen: cursor/plugins %s\nfecha: %s\nskills: %s\n' "$(basename "$top")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" > "$nueva/ORIGEN"

  rm -rf "$RAIZ.anterior"
  [ -d "$RAIZ" ] && mv "$RAIZ" "$RAIZ.anterior"
  mv "$nueva" "$RAIZ"
  log "preparada: $(head -1 "$RAIZ/ORIGEN"), $n skills"
}

real() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# true solo si las dos rutas se resolvieron y son la misma; un python3 caído no cuenta como igual.
mismo_destino() {
  local a b
  a=$(real "$1") && b=$(real "$2") && [ -n "$a" ] && [ "$a" = "$b" ]
}

# Enlaza $1 a $2; lo que había y no resolvía a lo mismo va a $3. Un enlace relativo que ya
# llega al mismo lugar (como los de ~/.claude/skills) se queda como está.
enlazar() {
  local destino=$1 objetivo=$2 respaldo=$3
  if [ -L "$destino" ] && [ -e "$destino" ] && mismo_destino "$destino" "$objetivo"; then return 0; fi
  mkdir -p "$respaldo"
  if [ -e "$destino" ] || [ -L "$destino" ]; then
    mv "$destino" "$respaldo/"
  fi
  ln -s "$objetivo" "$destino"
  printf '%s\n' "$destino" >> "$respaldo/../creados.txt"
}

activar() {
  local fecha respaldo s nombre enlace
  [ -f "$RAIZ/ORIGEN" ] || falla "no hay copia preparada en $RAIZ (corre preparar)"
  fecha=$(date -u +%Y%m%dT%H%M%SZ)
  respaldo="$HOME/.agents/.respaldo-pstack-$fecha"
  mkdir -p "$SKILLS_DIR" "$CLAUDE_SKILLS" "$CLAUDE_AGENTS"
  for s in "$RAIZ"/skills/*/; do
    nombre=$(basename "$s")
    grep -qxF "$nombre" "$GESTIONADAS" 2>/dev/null || printf '%s\n' "$nombre" >> "$GESTIONADAS"
    enlazar "$SKILLS_DIR/$nombre" "$RAIZ/skills/$nombre" "$respaldo/agents-skills"
    enlazar "$CLAUDE_SKILLS/$nombre" "$SKILLS_DIR/$nombre" "$respaldo/claude-skills"
  done
  for a in $AGENTES; do
    enlazar "$CLAUDE_AGENTS/$a" "$RAIZ/agents/$a" "$respaldo/claude-agents"
  done
  # Una skill que el original retiró deja enlaces rotos hacia la copia: se quitan, pero solo los
  # de skills que activar gestionó; un enlace roto ajeno se queda.
  for enlace in "$SKILLS_DIR"/* "$CLAUDE_SKILLS"/*; do
    [ -L "$enlace" ] || continue
    [ -e "$enlace" ] && continue
    grep -qxF "$(basename "$enlace")" "$GESTIONADAS" 2>/dev/null || continue
    rm "$enlace"; log "retirada: $(basename "$enlace")"
  done
  touch "$MARCA"
  if [ -d "$respaldo" ]; then
    log "activada; lo anterior quedó en $respaldo (reversa: $0 restaurar $respaldo)"
  else
    log "activada; nada que mover"
  fi
}

restaurar() {
  local respaldo=${1:?uso: restaurar <dir de respaldo>} par dir destino item creado
  [ -d "$respaldo" ] || falla "no existe $respaldo"
  # Primero se quitan los enlaces que activar creó (los de skills nuevas incluidos); lo que había
  # antes vuelve después desde el respaldo.
  if [ -f "$respaldo/creados.txt" ]; then
    while IFS= read -r creado; do
      [ -L "$creado" ] && rm "$creado"
    done < "$respaldo/creados.txt"
  fi
  for par in "agents-skills:$SKILLS_DIR" "claude-skills:$CLAUDE_SKILLS" "claude-agents:$CLAUDE_AGENTS"; do
    dir="$respaldo/${par%%:*}"; destino=${par#*:}
    [ -d "$dir" ] || continue
    for item in "$dir"/* ; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      rm -rf "${destino:?}/$(basename "$item")"
      mv "$item" "$destino/"
    done
  done
  rm -f "$MARCA"
  log "restaurado desde $respaldo; la copia del original sigue en $RAIZ pero ya no está activa"
}

estado() {
  if [ -f "$RAIZ/ORIGEN" ]; then cat "$RAIZ/ORIGEN"; else echo "sin copia preparada"; fi
  if [ -f "$MARCA" ]; then echo "activa: sí"; else echo "activa: no"; fi
}

case "${1:-}" in
  preparar) preparar ;;
  activar) activar ;;
  restaurar) restaurar "${2:-}" ;;
  estado) estado ;;
  "")
    # Cada paso en su propio proceso: dentro de un `if !` bash apaga set -e, y una copia a medias
    # pasaría sin aviso.
    if ! bash "$0" preparar; then avisar "preparar no terminó"; exit 1; fi
    if [ -f "$MARCA" ]; then
      if ! bash "$0" activar; then avisar "activar no terminó"; exit 1; fi
    fi
    ;;
  *) echo "uso: $0 [preparar | activar | estado | restaurar <dir>]" >&2; exit 2 ;;
esac

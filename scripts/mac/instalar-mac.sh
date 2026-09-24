#!/bin/bash
# scripts/mac/instalar-mac.sh (9.10). Instala las herramientas de corrida en
# esta Mac desde el arbol del repo: ~/bin, ~/Library/LaunchAgents y
# ~/.tmux.conf, mas la linea de source en ~/.zshrc. Genera el plist con el
# $HOME y el uid de quien lo corre (la plantilla trae /Users/dn a fuego y en
# otra maquina no arranca ni avisa). Comprueba el blob de cada fuente contra
# la rama por defecto ANTES de tocar disco: adulterado = error sin escribir
# nada; ausente en la rama = se declara y se sigue. Nunca copia ni carga
# ai.goncloud.corrida-latido (reloj viejo; el watchdog global de PR #110 es
# el unico que manda progreso). Idempotente: solo escribe lo que difiere y
# respalda lo reemplazado en .anterior.
# Uso: instalar-mac.sh [--dry-run|--verificar]
# Env: HOME, INSTALAR_UID (def. id -u), INSTALAR_REF (def. origin/main),
#      LAUNCHCTL_BIN (def. launchctl), GIT_BIN (def. git).
set -u
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(cd "$AQUI/.." && pwd)"
QUIEN_UID="${INSTALAR_UID:-$(id -u)}"
REF="${INSTALAR_REF:-origin/main}"
LC_BIN="${LAUNCHCTL_BIN:-launchctl}"
GIT_BIN="${GIT_BIN:-git}"
MODO="${1:-instalar}"
case "$MODO" in instalar|--dry-run|--verificar) ;; *) echo "uso: instalar-mac.sh [--dry-run|--verificar]" >&2; exit 2;; esac

BIN_DIR="$HOME/bin"
LA_DIR="$HOME/Library/LaunchAgents"
PL_FUENTE="$AQUI/ai.goncloud.tmux-activity-watch.plist"
PL_NOMBRE="ai.goncloud.tmux-activity-watch.plist"
ETIQUETA="ai.goncloud.tmux-activity-watch"
LINEA_SOURCE="source ~/bin/agent-tmux-shell.zsh"
# Manifiesto binario: fuentes relativas a scripts/mac, destino ~/bin (cp -p
# conserva el +x). El latido viejo NO esta en esta lista: ni se copia ni se carga.
BINS="corrida.sh cli-modos.tsv agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh"

di() { printf '%s\n' "$1"; }
falla() { printf 'instalar-mac: error: %s\n' "$1" >&2; exit 1; }
avisa() { printf 'instalar-mac: aviso: %s\n' "$1" >&2; }

blob_de() { # $1 archivo: sha1 del blob (git) o cksum si no hay git
  if command -v "$GIT_BIN" >/dev/null 2>&1 && "$GIT_BIN" -C "$RAIZ" rev-parse --git-dir >/dev/null 2>&1; then
    "$GIT_BIN" -C "$RAIZ" hash-object "$1" 2>/dev/null && return 0
  fi
  cksum "$1" 2>/dev/null | awk '{print "ck"$1}' || echo "?"
}
ref_sha() {
  "$GIT_BIN" -C "$RAIZ" rev-parse --short "$REF" 2>/dev/null || echo "arbol-local"
}

# plist generada: $2 destino. Sustituye el /Users/dn a fuego de la plantilla
# por el HOME de quien corre (rutas del programa, HOME de entorno y logs).
generar_plist() { # $1 destino
  local esc; esc="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
  sed "s|/Users/dn|$esc|g" "$PL_FUENTE" >"$1" || return 1
}

# Fase 1: comprobar blobs contra la rama ANTES de tocar disco. Sale 0 si todo
# cuadra o solo hay ausentes-declarados; sale 1 si algo difiere (fail closed).
fase_blobs() {
  local git_ok=0 f rel esperado real
  if "$GIT_BIN" -C "$RAIZ" rev-parse --verify "$REF" >/dev/null 2>&1; then git_ok=1; fi
  [ "$git_ok" = "1" ] || { avisa "sin comprobacion de rama ($REF no resolvible); se instala por bytes"; return 0; }
  for f in $BINS tmux.conf "$(basename "$PL_FUENTE")"; do
    rel="scripts/mac/$f"
    esperado="$("$GIT_BIN" -C "$RAIZ" rev-parse "$REF:$rel" 2>/dev/null)" || { avisa "sin referencia en $REF: $rel (se declara y se sigue)"; continue; }
    real="$("$GIT_BIN" -C "$RAIZ" hash-object "$AQUI/$f" 2>/dev/null)" || falla "no se pudo leer $f"
    [ "$esperado" = "$real" ] || falla "blob distinto de $REF en $rel (rama ${esperado} vs arbol ${real})"
  done
  local c
  for c in "$AQUI"/corrida/*.sh; do
    f="$(basename "$c")"; rel="scripts/mac/corrida/$f"
    esperado="$("$GIT_BIN" -C "$RAIZ" rev-parse "$REF:$rel" 2>/dev/null)" || { avisa "sin referencia en $REF: $rel (se declara y se sigue)"; continue; }
    real="$("$GIT_BIN" -C "$RAIZ" hash-object "$c" 2>/dev/null)" || falla "no se pudo leer $f"
    [ "$esperado" = "$real" ] || falla "blob distinto de $REF en $rel"
  done
  return 0
}

copiar_si_difiere() { # $1 fuente $2 destino: copia solo si difiere; respalda .anterior
  if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi
  [ -f "$2" ] && cp -p "$2" "$2.anterior"
  cp -p "$1" "$2" || return 1
}

modo_dry() {
  local f sha
  di "instalaria desde $AQUI (ref $REF@$(ref_sha)) a HOME=$HOME uid=$QUIEN_UID:"
  for f in $BINS; do sha="$(blob_de "$AQUI/$f")"; di "  bin/$f  (blob ${sha})"; done
  for f in "$AQUI"/corrida/*.sh; do sha="$(blob_de "$f")"; di "  bin/corrida/$(basename "$f")  (blob ${sha})"; done
  di "  Library/LaunchAgents/$PL_NOMBRE  (generada con HOME=$HOME)"
  di "  .tmux.conf  (blob $(blob_de "$AQUI/tmux.conf"))"
  di "  .zshrc: agregaria \`$LINEA_SOURCE\` si falta"
  di "  cargaria: $LC_BIN bootstrap gui/$QUIEN_UID $LA_DIR/$PL_NOMBRE"
  di "  jamas: el reloj viejo de 9.5 (retirado; no se copia ni se carga)"
}

modo_verificar() {
  local mal=0 f tmp
  for f in $BINS; do
    [ -f "$BIN_DIR/$f" ] || { di "FALTA: bin/$f"; mal=$((mal+1)); continue; }
    cmp -s "$AQUI/$f" "$BIN_DIR/$f" || { di "DIFIERE: bin/$f"; mal=$((mal+1)); continue; }
  done
  for f in "$AQUI"/corrida/*.sh; do
    local b; b="$(basename "$f")"
    [ -f "$BIN_DIR/corrida/$b" ] || { di "FALTA: bin/corrida/$b"; mal=$((mal+1)); continue; }
    cmp -s "$f" "$BIN_DIR/corrida/$b" || { di "DIFIERE: bin/corrida/$b"; mal=$((mal+1)); continue; }
  done
  tmp="$(mktemp)" || falla "sin tmp para comparar el plist"
  generar_plist "$tmp" || { rm -f "$tmp"; falla "no se pudo generar el plist esperado"; }
  if [ ! -f "$LA_DIR/$PL_NOMBRE" ]; then di "FALTA: LaunchAgents/$PL_NOMBRE"; mal=$((mal+1));
  elif ! cmp -s "$tmp" "$LA_DIR/$PL_NOMBRE"; then di "DIFIERE: LaunchAgents/$PL_NOMBRE"; mal=$((mal+1)); fi
  rm -f "$tmp"
  if [ ! -f "$HOME/.tmux.conf" ]; then di "FALTA: .tmux.conf"; mal=$((mal+1));
  elif ! cmp -s "$AQUI/tmux.conf" "$HOME/.tmux.conf"; then di "DIFIERE: .tmux.conf"; mal=$((mal+1)); fi
  grep -qF "$LINEA_SOURCE" "$HOME/.zshrc" 2>/dev/null || { di "FALTA: linea de source en .zshrc"; mal=$((mal+1)); }
  if [ "$mal" = "0" ]; then di "verificado: instalacion sana contra $AQUI"; return 0; fi
  di "verificar: $mal problema(s) contra $AQUI" >&2; return 1
}

modo_instalar() {
  local f sha
  mkdir -p "$BIN_DIR" "$BIN_DIR/corrida" "$LA_DIR" || falla "no se pudieron crear directorios en $HOME"
  for f in $BINS; do copiar_si_difiere "$AQUI/$f" "$BIN_DIR/$f" || falla "no se pudo instalar bin/$f"; done
  for f in "$AQUI"/corrida/*.sh; do copiar_si_difiere "$f" "$BIN_DIR/corrida/$(basename "$f")" || falla "no se pudo instalar corrida/$(basename "$f")"; done
  local pl_tmp; pl_tmp="$(mktemp)" || falla "sin tmp para el plist"
  generar_plist "$pl_tmp" || { rm -f "$pl_tmp"; falla "no se pudo generar el plist"; }
  copiar_si_difiere "$pl_tmp" "$LA_DIR/$PL_NOMBRE" || { rm -f "$pl_tmp"; falla "no se pudo instalar el plist"; }
  rm -f "$pl_tmp"
  copiar_si_difiere "$AQUI/tmux.conf" "$HOME/.tmux.conf" || falla "no se pudo instalar .tmux.conf"
  [ -f "$HOME/.zshrc" ] || { touch "$HOME/.zshrc" || falla "no se pudo crear .zshrc"; }
  grep -qF "$LINEA_SOURCE" "$HOME/.zshrc" || printf '%s\n' "$LINEA_SOURCE" >>"$HOME/.zshrc"
  "$LC_BIN" bootout "gui/$QUIEN_UID/$ETIQUETA" >/dev/null 2>&1 || true
  "$LC_BIN" bootstrap "gui/$QUIEN_UID" "$LA_DIR/$PL_NOMBRE" >&2 || falla "launchctl no cargo $ETIQUETA"
  di "instalado desde $AQUI (ref $REF@$(ref_sha)):"
  for f in $BINS; do sha="$(blob_de "$AQUI/$f")"; di "  bin/$f  ${sha}"; done
  for f in "$AQUI"/corrida/*.sh; do sha="$(blob_de "$f")"; di "  bin/corrida/$(basename "$f")  ${sha}"; done
  di "  LaunchAgents/$PL_NOMBRE  (generada HOME=$HOME)"
  di "  .tmux.conf  $(blob_de "$AQUI/tmux.conf")"
  di "  .zshrc: $LINEA_SOURCE"
}

case "$MODO" in
  --dry-run) fase_blobs; modo_dry;;
  --verificar) modo_verificar;;
  instalar) fase_blobs; modo_instalar;;
esac

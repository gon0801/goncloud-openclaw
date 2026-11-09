#!/bin/bash
# Respaldo diario de OpenBot de la MacBook hacia gonserver, para poder reinstalarlo en
# otra Mac (docs/runbooks/reinstalar-desde-respaldo.md).
#
#   openbot-backup-AAAAMMDD.tar.gz  lo que una reinstalación necesita: openbot.db copiado
#                                   con `sqlite3 .backup` (tiene WAL), los *.json y *.bin
#                                   de la raíz, Preferences, Local State, Cookies y las
#                                   carpetas de estado de la app. Fuera lo regenerable:
#                                   provider-runtimes (1.7 GB), cachés, logs y Crashpad.
#
# Lo sube a clawbackup@gonserver, cuyo command= forzado es `recibe-respaldo openbot`
# (scripts/gonserver/): el nombre va como comando remoto, los datos por stdin, y el
# servidor contesta el sha256 que guardó. 3 intentos con tope, alternando WireGuard y
# Tailscale. Guarda los 2 más nuevos en la Mac y en el servidor. Una corrida que falla
# avisa con una notificación local de macOS; el aviso remoto lo da el vigía del servidor.
#
# Corre con el bash 3.2 de macOS. Todo lo de afuera se cambia por entorno para probarlo
# sin red (scripts/tests/test-respaldo-openbot.sh).
set -uo pipefail
umask 077

OB_RAIZ="${OB_RAIZ:-$HOME/Library/Application Support/OpenBot}"
OB_DIR="${OB_DIR:-$HOME/respaldo-openbot}"
OB_LOG="${OB_LOG:-$HOME/Library/Logs/goncloud/respaldo-openbot.log}"
OB_FECHA="${OB_FECHA:-$(date +%Y%m%d)}"
OB_GUARDAR="${OB_GUARDAR:-2}"
OB_MAX_BYTES="${OB_MAX_BYTES:-1073741824}"
OB_SQLITE3="${OB_SQLITE3:-/usr/bin/sqlite3}"
[ -x "$OB_SQLITE3" ] || OB_SQLITE3="$(command -v sqlite3 || true)"
OB_OSASCRIPT="${OB_OSASCRIPT:-/usr/bin/osascript}"
OB_TOPE_CREAR="${OB_TOPE_CREAR:-900}"

# Variables que comparten la subida y el ciclo de vida de scripts/mac/respaldo-comun.sh.
RC_DIR="$OB_DIR"
RC_SERVIDORES="${OB_SERVIDORES:-10.13.13.1 100.127.167.103}"   # WireGuard, luego Tailscale
RC_USUARIO="${OB_USUARIO:-clawbackup}"
RC_LLAVE="${OB_LLAVE:-$HOME/.ssh/openbot_goncloud}"
RC_SSH="${OB_SSH:-ssh}"
RC_INTENTOS="${OB_INTENTOS:-3}"
RC_ESPERA="${OB_ESPERA:-60}"              # segundos entre intentos de subida
RC_TOPE="${OB_TOPE:-900}"                 # segundos por intento de subida (~200 MB)

# Lo que OpenBot necesita al arrancar. Lo que no exista se anota y no es falla.
INCLUIR=(
  Preferences
  "Local State"
  Cookies
  automation
  agent-api-keys
  provider-state
  provider-handoffs
  provider-toolsets
  provider-work-steps
  local-skills
  custom-agents.json
  Partitions
  IndexedDB
  "Local Storage"
  "Session Storage"
  WebStorage
  avatars
  themes
  remote-desktop-runtime
)

# Las cachés de Electron viven dentro de Partitions/<partición>/. Solo ahí se excluyen por
# nombre, a cualquier profundidad, y tar las salta al copiar (así tampoco lee una caché que
# la app abierta cambia). Aplicarlas a otras entradas podría omitir estado legítimo con el
# mismo nombre. Los regenerables de la raíz (provider-runtimes, logs, Crashpad, Singleton*,
# DevToolsActivePort) ya quedan fuera porque no están en INCLUIR.
EXCLUIR=(
  --exclude=Cache
  --exclude='Code Cache'
  --exclude=GPUCache
  --exclude='*Dawn*'
  --exclude='*Graphite*'
  --exclude='Shared Dictionary'
  --exclude=blob_storage
)

mkdir -p "$(dirname "$OB_LOG")" "$OB_DIR"
exec >>"$OB_LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
FALLAS=""
falla() { FALLAS="${FALLAS:+$FALLAS; }$*"; log "FALLA: $*"; }
LIB="$(dirname "$0")/respaldo-comun.sh"
[ -r "$LIB" ] || { printf 'falta %s\n' "$LIB"; exit 1; }
. "$LIB"

avisar() {
  local texto="El respaldo de OpenBot a gonserver falló: $1. Revisa $OB_LOG."
  if [ -n "${OB_AVISO_CMD:-}" ]; then
    "$OB_AVISO_CMD" "$texto" && log "aviso enviado" && return 0
  elif "$OB_OSASCRIPT" -e 'on run argv' \
      -e 'display notification (item 1 of argv) with title "Respaldo OpenBot"' \
      -e 'end run' "$texto" >/dev/null 2>&1; then
    log "aviso local"; return 0
  fi
  log "no se pudo avisar"
}

trap al_salir EXIT
trampas_de_senal

tomar_lock || exit $?
limpiar_temporales
TMP="$(mktemp -d "$RC_DIR/.tmp.XXXXXX")"
log "inicio $OB_FECHA"

# Arma el archivo en un árbol temporal: openbot.db sale de `sqlite3 .backup` y se copia
# solo lo que la lista pide. Al copiar Partitions se quitan las cachés de Electron a
# cualquier profundidad; las demás entradas se copian enteras.
crear_archivo() {
  local destino="$OB_DIR/openbot-backup-$OB_FECHA.tar.gz"
  local arbol="$TMP/arbol" nombre origen tam
  mkdir -p "$arbol"
  if [ ! -f "$OB_RAIZ/openbot.db" ]; then
    falla "no existe $OB_RAIZ/openbot.db"; return 1
  fi
  if ! con_tope "$OB_TOPE_CREAR" "$OB_SQLITE3" "$OB_RAIZ/openbot.db" ".backup '$arbol/openbot.db'" \
      > "$TMP/sqlite.out" 2> "$TMP/sqlite.err"; then
    falla "sqlite3 .backup falló: $(tr '\n' ' ' < "$TMP/sqlite.err" | cut -c1-200)"; return 1
  fi
  if [ "$("$OB_SQLITE3" "$arbol/openbot.db" 'pragma integrity_check' 2>/dev/null)" != ok ]; then
    falla "la copia de openbot.db no pasa integrity_check"; return 1
  fi
  for origen in "$OB_RAIZ"/*.json "$OB_RAIZ"/*.bin; do
    [ -e "$origen" ] || continue
    cp -p "$origen" "$arbol/" || { falla "no se pudo copiar $(basename "$origen")"; return 1; }
  done
  for nombre in "${INCLUIR[@]}"; do
    origen="$OB_RAIZ/$nombre"
    if [ -e "$origen" ] || [ -L "$origen" ]; then
      if [ "$nombre" = Partitions ]; then
        if ! tar -cf - -C "$OB_RAIZ" "${EXCLUIR[@]}" "$nombre" 2> "$TMP/copia.err" \
            | tar -xf - -C "$arbol" 2>> "$TMP/copia.err"; then
          falla "no se pudo copiar $nombre: $(tr '\n' ' ' < "$TMP/copia.err" | cut -c1-200)"; return 1
        fi
      elif ! cp -pR "$origen" "$arbol/"; then
        falla "no se pudo copiar $nombre"; return 1
      fi
      log "incluido: $nombre"
    else
      log "omitido (no existe): $nombre"
    fi
  done
  local temporal="$TMP/openbot-backup-$OB_FECHA.tar.gz"
  if ! tar -czf "$temporal" -C "$arbol" . 2> "$TMP/tar.err"; then
    rm -f "$temporal"
    falla "tar falló: $(tr '\n' ' ' < "$TMP/tar.err" | cut -c1-200)"; return 1
  fi
  tam="$(wc -c < "$temporal" | tr -d ' ')"
  if [ "$tam" -gt "$OB_MAX_BYTES" ]; then
    rm -f "$temporal"
    falla "openbot-backup-$OB_FECHA.tar.gz pesa $tam bytes, más del tope $OB_MAX_BYTES: entró algo regenerable"
    return 1
  fi
  if ! mv -f "$temporal" "$destino"; then
    rm -f "$temporal"
    falla "no se pudo mover $temporal a $destino"; return 1
  fi
  log "archivo creado: $destino ($(du -h "$destino" | cut -f1), $tam bytes)"
  subir "$destino"
}

crear_archivo

ls -1 "$OB_DIR"/openbot-backup-*.tar.gz 2>/dev/null | sort -r | tail -n +"$((OB_GUARDAR + 1))" \
  | while IFS= read -r viejo; do rm -f "$viejo"; log "borrado local: $(basename "$viejo")"; done

[ -z "$FALLAS" ] || { log "terminado con fallas"; exit 1; }
log "terminado sin fallas"

#!/bin/bash
# Respaldo completo diario de la Mac mini del gateway hacia gonserver, para poder
# reinstalar en otra Mac (docs/runbooks/reinstalar-desde-respaldo.md).
#
#   openclaw-backup-AAAAMMDD.tar.gz  `openclaw backup create --verify`: ~/.openclaw entero.
#   openclaw-extras-AAAAMMDD.tar.gz  lo que vive fuera de ~/.openclaw y una reinstalación
#                                    necesita (lista en EXTRAS).
#
# Sube los dos a clawbackup@gonserver, cuyo command= forzado es
# `recibe-respaldo openclaw` (scripts/gonserver/): el nombre va como comando remoto, los
# datos por stdin, y el servidor contesta el sha256 que guardó. Cada subida tiene 3
# intentos con tope de tiempo, alternando WireGuard y Tailscale. Guarda los 2 más nuevos
# de cada uno en la Mac. Una corrida que falla avisa por Telegram; una que sale bien, no.
#
# Corre con el bash 3.2 de macOS. Todo lo de afuera se cambia por entorno para probarlo
# sin red (scripts/tests/test-respaldo-completo.sh).
set -uo pipefail
umask 077

RC_DIR="${RC_DIR:-$HOME/respaldo-completo}"   # fuera de ~/.openclaw: openclaw se niega a escribir dentro
RC_LOG="${RC_LOG:-$HOME/Library/Logs/goncloud/respaldo-completo.log}"
OPENCLAW_BIN="${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}"
RC_SERVIDORES="${RC_SERVIDORES:-10.13.13.1 100.127.167.103}"   # WireGuard, luego Tailscale
RC_USUARIO="${RC_USUARIO:-clawbackup}"
RC_LLAVE="${RC_LLAVE:-$HOME/.ssh/claw_goncloud}"
RC_SSH="${RC_SSH:-ssh}"
RC_INTENTOS="${RC_INTENTOS:-3}"
RC_ESPERA="${RC_ESPERA:-60}"              # segundos entre intentos de subida
RC_TOPE="${RC_TOPE:-1800}"                # segundos por intento de subida (3.9 GB ~ 8 min)
RC_TOPE_CREAR="${RC_TOPE_CREAR:-1800}"    # segundos para `backup create` (medido: 143 s)
RC_GUARDAR="${RC_GUARDAR:-2}"             # archivos de cada tipo que se quedan en la Mac
RC_TELEGRAM="${RC_TELEGRAM:-6470689715}"
RC_FECHA="${RC_FECHA:-$(date +%Y%m%d)}"

# Rutas relativas a $HOME. Sin una requerida no se reinstala: si falta (un patrón sin
# ninguna coincidencia), la corrida falla y avisa, aunque igual sube lo que hay. Una
# opcional que falta solo se anota. El script instalado también es requerido.
EXTRAS_REQUERIDOS="Library/LaunchAgents/ai.openclaw.*.plist goncloud-autoupdate .ssh .zshrc"
EXTRAS_OPCIONALES="Library/LaunchAgents/ai.goncloud.*.plist .claude .claude.json .openclaw-state .local/bin"

mkdir -p "$(dirname "$RC_LOG")" "$RC_DIR"
exec >>"$RC_LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
FALLAS=""
falla() { FALLAS="${FALLAS:+$FALLAS; }$*"; log "FALLA: $*"; }
# En segundo plano y con `wait` para que una señal a la corrida se atienda en el acto y
# no al terminar el hijo (una subida puede durar 30 min). `<&0` le pasa el stdin que el
# `&` cambiaría por /dev/null. El 2>/dev/null de `wait` calla el "Alarm clock" que bash
# imprime al vencer el tope, para que no se mezcle con el error de ssh.
HIJO=""
con_tope() {
  local rc
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$@" <&0 &
  HIJO=$!; wait "$HIJO" 2>/dev/null; rc=$?; HIJO=""
  return "$rc"
}
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

avisar() {
  local texto="El respaldo completo de la Mac mini a gonserver falló: $1. Revisa $RC_LOG."
  if [ -n "${RC_AVISO_CMD:-}" ]; then
    "$RC_AVISO_CMD" "$texto" && log "aviso enviado" && return 0
  elif con_tope 120 "$OPENCLAW_BIN" message send --channel telegram -t "$RC_TELEGRAM" \
      -m "$texto" --json >/dev/null 2>&1; then
    log "aviso enviado por Telegram"; return 0
  elif /usr/bin/osascript -e 'display notification "El respaldo completo falló. Ver ~/Library/Logs/goncloud/respaldo-completo.log" with title "Respaldo completo"' >/dev/null 2>&1; then
    log "aviso local (Telegram no contestó)"; return 0
  fi
  log "no se pudo avisar"
}
# El aviso sale una vez, al terminar, con todas las causas. El lock de otra corrida
# viva (3) no es una falla del respaldo. Lo pesado se borra antes de avisar: tras un
# SIGTERM, launchd manda SIGKILL a los 20 s.
al_salir() {
  local rc=$?
  [ -z "$HIJO" ] || kill "$HIJO" 2>/dev/null
  rm -rf "${TMP:-}" "${LOCK_PROPIO:-}"
  case "$rc" in 0|3) ;; *) avisar "${FALLAS:-salida inesperada (rc=$rc)}" ;; esac
}
trap al_salir EXIT
for senal in HUP INT TERM; do
  # shellcheck disable=SC2064  # la señal se fija al poner la trampa
  trap "falla 'corrida interrumpida por SIG$senal'; exit 1" "$senal"
done

LOCK="$RC_DIR/.lock"
# Identidad de un proceso = PID + hora de inicio: tras un reinicio el PID de una
# corrida muerta puede tenerlo otro proceso vivo, y eso no es dueño del lock.
identidad() { printf '%s %s' "$1" "$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ')"; }
if ! mkdir "$LOCK" 2>/dev/null; then
  dueno="$(cat "$LOCK/dueno" 2>/dev/null)"
  pid="${dueno%% *}"
  if [ -n "$pid" ] && [ "$(identidad "$pid")" = "$dueno" ]; then
    log "ABORTO: otra corrida (pid $pid) tiene el lock $LOCK"; exit 3
  fi
  log "lock huérfano (${dueno:-sin dueño}); se recupera"
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || { log "ABORTO: no se pudo tomar el lock $LOCK"; exit 3; }
fi
identidad $$ > "$LOCK/dueno"
LOCK_PROPIO="$LOCK"
# Con el lock tomado, un temporal que quede es de una corrida que murió sin limpiar
# (SIGKILL o apagón) y puede pesar 3.9 GB.
for viejo in "$RC_DIR"/.tmp.*; do
  [ -e "$viejo" ] || continue
  rm -rf "$viejo"; log "temporal de una corrida anterior borrado: $(basename "$viejo")"
done
TMP="$(mktemp -d "$RC_DIR/.tmp.XXXXXX")"
log "inicio $RC_FECHA"

# $1 archivo local. Lo sube con su nombre y compara el sha256 que contesta el servidor.
# StrictHostKeyChecking=yes: known_hosts de la Mini tiene que traer la llave de las dos
# direcciones de RC_SERVIDORES (cómo agregarla, en el runbook).
subir() {
  local archivo="$1" nombre local_sha remoto rc intento=1 host causa
  nombre="$(basename "$archivo")"; local_sha="$(sha256 "$archivo")"
  while :; do
    host="$(echo "$RC_SERVIDORES" | awk -v i="$intento" '{ print $((i - 1) % NF + 1) }')"
    con_tope "$RC_TOPE" "$RC_SSH" -i "$RC_LLAVE" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=4 "$RC_USUARIO@$host" "$nombre" < "$archivo" > "$TMP/ssh.out" 2> "$TMP/ssh.err"
    rc=$?; remoto="$(cat "$TMP/ssh.out")"
    if [ "$rc" -eq 0 ] && [ "$remoto" = "$local_sha" ]; then
      log "$nombre: subido a $host ($(du -h "$archivo" | cut -f1), sha256 $local_sha)"; return 0
    elif [ "$rc" -eq 0 ]; then
      causa="el sha256 no coincide (servidor: ${remoto:-vacío})"
    else
      causa="$(tr '\n' ' ' < "$TMP/ssh.err" | sed 's/ *$//' | cut -c1-160)"
      [ -n "$causa" ] || causa="sin respuesta en ${RC_TOPE}s"
    fi
    if [ "$intento" -ge "$RC_INTENTOS" ]; then
      falla "$nombre no se subió tras $intento intento(s): $causa"; return 1
    fi
    log "$nombre: intento $intento a $host falló ($causa); otro en ${RC_ESPERA}s"
    intento=$((intento + 1)); sleep "$RC_ESPERA"
  done
}

# 1. ~/.openclaw con el respaldo nativo, verificado.
crear_backup() {
  local destino="$RC_DIR/openclaw-backup-$RC_FECHA.tar.gz" sal="$TMP/crear"
  mkdir -p "$sal"
  if ! con_tope "$RC_TOPE_CREAR" "$OPENCLAW_BIN" backup create --output "$sal" --verify --json \
      > "$TMP/crear.json" 2> "$TMP/crear.err"; then
    falla "openclaw backup create falló: $(tail -3 "$TMP/crear.err" | tr '\n' ' ' | cut -c1-200)"
    return 1
  fi
  if ! grep -Eq '"verified"[[:space:]]*:[[:space:]]*true' "$TMP/crear.json"; then
    falla "openclaw backup create no verificó el archivo"; return 1
  fi
  set -- "$sal"/*.tar.gz
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    falla "openclaw backup create no dejó un solo .tar.gz en $sal"; return 1
  fi
  mv -f "$1" "$destino"
  log "backup creado: $destino ($(du -h "$destino" | cut -f1))"
  subir "$destino"
}

# 2. Lo de fuera de ~/.openclaw, con rutas absolutas sin la / inicial: se restaura a un
# directorio aparte y se copia de ahí (ver el runbook). La nota RESPALDO-EXTRAS.txt dice
# qué faltó: "falta (requerido): ..." u "omitido (no existe): ...". También trae las
# versiones de OpenClaw y node: en una Mac nueva hay que instalarlas antes de poder
# leer el backup con openclaw.
VERSIONES=""
listar_extras() { # $1 nota, $2 lista
  local patron ruta yo tipo patrones
  case "$0" in /*) yo="$0" ;; *) yo="$PWD/$0" ;; esac
  if [ -z "$VERSIONES" ]; then
    VERSIONES="openclaw: $(con_tope 60 "$OPENCLAW_BIN" --version 2>/dev/null | head -1)
node: $(con_tope 60 node --version 2>/dev/null) ($(command -v node))"
  fi
  printf 'Extras de %s, %s. Rutas relativas a /.\n%s\n' "$(hostname)" "$RC_FECHA" "$VERSIONES" > "$1"
  printf '%s\n' "$1" > "$2"
  if [ -f "$yo" ]; then printf '%s\n' "$yo" >> "$2"; else printf 'falta (requerido): %s\n' "$yo" >> "$1"; fi
  for tipo in requerido opcional; do
    if [ "$tipo" = requerido ]; then patrones="$EXTRAS_REQUERIDOS"; else patrones="$EXTRAS_OPCIONALES"; fi
    for patron in $patrones; do
      # shellcheck disable=SC2086  # el patrón se expande a propósito
      set -- "$HOME"/$patron
      if [ -e "$1" ] || [ -L "$1" ]; then
        # Sin sockets: tar no los archiva y su queja taparía la causa real de una falla.
        for ruta in "$@"; do find "$ruta" ! -type s; done
      elif [ "$tipo" = requerido ]; then
        printf 'falta (requerido): ~/%s\n' "$patron" >&3
      else
        printf 'omitido (no existe): ~/%s\n' "$patron" >&3
      fi
    done
  done 3>> "$1" >> "$2"
}
crear_extras() {
  local destino="$RC_DIR/openclaw-extras-$RC_FECHA.tar.gz" nota="$RC_DIR/RESPALDO-EXTRAS.txt"
  local lista="$TMP/extras.lista" intento armado="" faltan
  # Un archivo de ~/.claude que desaparece entre la lista y tar hace fallar a tar; con
  # la lista rehecha el segundo intento pasa. Dos fallas seguidas son una falla real.
  for intento in 1 2; do
    listar_extras "$nota" "$lista"
    sed 's|^/||' "$lista" > "$lista.rel"
    if tar -czf "$TMP/extras.tar.gz" --no-recursion -C / -T "$lista.rel" 2> "$TMP/tar.err"; then
      armado=1; break
    fi
    log "extras: tar falló en el intento $intento: $(tr '\n' ' ' < "$TMP/tar.err" | cut -c1-200)"
  done
  grep '^omitido' "$nota" | while IFS= read -r l; do log "extras: $l"; done
  faltan="$(sed -n 's/^falta (requerido): //p' "$nota" | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $0 }')"
  [ -z "$faltan" ] || falla "faltan extras requeridos: $faltan"
  if [ -z "$armado" ]; then
    falla "no se pudo armar los extras: $(tr '\n' ' ' < "$TMP/tar.err" | cut -c1-200)"; return 1
  fi
  mv -f "$TMP/extras.tar.gz" "$destino"
  log "extras creados: $destino ($(du -h "$destino" | cut -f1), $(wc -l < "$lista" | tr -d ' ') rutas)"
  subir "$destino"
}

# Un fallo de uno no detiene al otro: el que sí sale se sube.
crear_backup
crear_extras

for tipo in openclaw-backup openclaw-extras; do
  ls -1 "$RC_DIR/$tipo"-*.tar.gz 2>/dev/null | sort -r | tail -n +"$((RC_GUARDAR + 1))" \
    | while IFS= read -r viejo; do rm -f "$viejo"; log "borrado local: $(basename "$viejo")"; done
done

[ -z "$FALLAS" ] || { log "terminado con fallas"; exit 1; }
log "terminado sin fallas"

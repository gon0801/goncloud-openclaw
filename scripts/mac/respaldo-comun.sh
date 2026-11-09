#!/bin/bash
# Maquinaria compartida por los respaldos de la Mac que suben a gonserver:
# scripts/mac/respaldo-completo.sh (Mini) y scripts/mac/respaldo-openbot.sh (MacBook).
#
# Quien la carga define log(), falla(), avisar(), FALLAS, TMP y las variables RC_* que
# usa subir (RC_TOPE, RC_SERVIDORES, RC_USUARIO, RC_LLAVE, RC_SSH, RC_INTENTOS,
# RC_ESPERA). El archivo y el canal de aviso son de cada respaldo; el ciclo de vida
# (tope por intento, lock, señales, subida con sha256 y reintentos) es este.
HIJO=""

con_tope() {
  local rc
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$@" <&0 &
  HIJO=$!; wait "$HIJO" 2>/dev/null; rc=$?; HIJO=""
  return "$rc"
}
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# El aviso sale una vez, al terminar, con todas las causas. El lock de otra corrida
# viva (3) no es una falla del respaldo. Lo pesado se borra antes de avisar: tras un
# SIGTERM, launchd manda SIGKILL a los 20 s.
al_salir() {
  local rc=$?
  [ -z "$HIJO" ] || kill "$HIJO" 2>/dev/null
  rm -rf "${TMP:-}" "${LOCK_PROPIO:-}"
  case "$rc" in 0|3) ;; *) avisar "${FALLAS:-salida inesperada (rc=$rc)}" ;; esac
}

trampas_de_senal() {
  local senal
  for senal in HUP INT TERM; do
    # shellcheck disable=SC2064  # la señal se fija al poner la trampa
    trap "falla 'corrida interrumpida por SIG$senal'; exit 1" "$senal"
  done
}

# Identidad de un proceso = PID + hora de inicio: tras un reinicio el PID de una
# corrida muerta puede tenerlo otro proceso vivo, y eso no es dueño del lock.
identidad() { printf '%s %s' "$1" "$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ')"; }

tomar_lock() {
  LOCK="$RC_DIR/.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    local dueno pid
    dueno="$(cat "$LOCK/dueno" 2>/dev/null)"
    pid="${dueno%% *}"
    if [ -n "$pid" ] && [ "$(identidad "$pid")" = "$dueno" ]; then
      log "ABORTO: otra corrida (pid $pid) tiene el lock $LOCK"; return 3
    fi
    log "lock huérfano (${dueno:-sin dueño}); se recupera"
    rm -rf "$LOCK"
    if ! mkdir "$LOCK" 2>/dev/null; then
      log "ABORTO: no se pudo tomar el lock $LOCK"; return 3
    fi
  fi
  identidad $$ > "$LOCK/dueno"
  LOCK_PROPIO="$LOCK"
}

# Con el lock tomado, un temporal que quede es de una corrida que murió sin limpiar
# (SIGKILL o apagón).
limpiar_temporales() {
  local viejo
  for viejo in "$RC_DIR"/.tmp.*; do
    [ -e "$viejo" ] || continue
    rm -rf "$viejo"; log "temporal de una corrida anterior borrado: $(basename "$viejo")"
  done
}

# $1 archivo local. Lo sube con su nombre y compara el sha256 que contesta el servidor.
# StrictHostKeyChecking=yes: known_hosts tiene que traer la llave de las dos direcciones
# de RC_SERVIDORES (cómo agregarla, en el runbook).
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

#!/bin/bash
# Respaldo diario, de UN SOLO SENTIDO, de los workspaces vivos del gateway hacia
# GitHub: la rama `respaldo/runtime` de cada repo goncloud-workspace-*.
#
# Por qué desde la Mac: desde la separación del runtime (22/9) el sync del host está
# apagado y el host no tiene credenciales de GitHub; la Mac sí, y ya entra al host por
# SSH con la llave del túnel del gateway. No se crea ningún token.
#
# El gateway vive en la Mac mini desde el 2026-10-09. Este script siguió buscando la
# carpeta del host Windows y abortó cuatro noches seguidas sin que nadie lo viera: por
# eso la carpeta es un parámetro y una corrida que falla avisa.
#
# Qué NUNCA hace: escribir en el runtime (por SSH solo corre `tar -c`), empujar a una
# rama que no empiece con `respaldo/`, usar --force, ni respaldar un workspace que no
# llegó entero (sin IDENTITY.md aborta ese repo en vez de borrar su respaldo).
set -uo pipefail

RESPALDO_DIR="${RESPALDO_DIR:-$HOME/.openclaw-respaldo}"      # clones dedicados, nunca los de trabajo
RESPALDO_RAMA="${RESPALDO_RAMA:-respaldo/runtime}"
RESPALDO_FUENTE="${RESPALDO_FUENTE:-ssh}"                       # ssh | <dir local> (pruebas)
# HTTPS con la sesión de `gh` (credential helper global): bajo launchd no hay
# agente SSH con llaves cargadas, así que git@github.com falla con publickey.
RESPALDO_REMOTO_BASE="${RESPALDO_REMOTO_BASE:-https://github.com/gon0801}"
RESPALDO_MAX_MB="${RESPALDO_MAX_MB:-50}"                         # GitHub rechaza archivos >100 MB
# Carpeta del runtime en el host, relativa a su home (ssh arranca ahí).
RESPALDO_RUNTIME="${RESPALDO_RUNTIME:-.openclaw}"
RESPALDO_INTENTOS="${RESPALDO_INTENTOS:-3}"                     # copias por SSH antes de abortar
RESPALDO_ESPERA="${RESPALDO_ESPERA:-60}"                        # segundos entre intentos

# workspace vivo -> repo de respaldo
PARES="workspace:goncloud-workspace-main workspace-operaciones:goncloud-workspace-operaciones workspace-ingenieria:goncloud-workspace-ingenieria"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Una corrida que falla avisa: primero por claw, que le escribe a David por Telegram; si
# el gateway no contesta (suele ser la misma causa que tumbó el respaldo), con una
# notificación en esta Mac. RESPALDO_AVISO_CMD recibe el texto como $1 y sustituye a los dos.
ULTIMO=""
avisar() {
  local texto="El respaldo diario de las instrucciones de claw falló: ${1:-sin detalle}. Dile a David, tal cual, que el respaldo no corrió y que le pida a Claude en la Mac revisar ~/Library/Logs/respaldo-workspaces.log."
  if [ -n "${RESPALDO_AVISO_CMD:-}" ]; then
    "$RESPALDO_AVISO_CMD" "$texto" && log "aviso enviado"
    return 0
  fi
  if "${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}" agent --agent main --deliver --timeout 180 \
      --message "$texto" >/dev/null 2>&1; then
    log "aviso enviado por claw"
  elif /usr/bin/osascript -e 'display notification "El respaldo diario de claw falló. Ver ~/Library/Logs/respaldo-workspaces.log" with title "Respaldo de claw"' >/dev/null 2>&1; then
    log "aviso local (claw no contestó)"
  else
    log "no se pudo avisar"
  fi
}
# El aviso sale al terminar, con la causa de la última línea ABORTO o FALLA. El lock de
# otra corrida viva (3) no es una falla del respaldo.
al_salir() {
  local rc=$?
  rm -rf "${TMP:-}" "${LOCK_PROPIO:-}" "$RESPALDO_DIR/.ssh-error"
  case "$rc" in 0|3) ;; *) avisar "$ULTIMO" ;; esac
}
trap al_salir EXIT
falla() { ULTIMO="$*"; log "$*"; }

case "$RESPALDO_RAMA" in
  respaldo/?*) ;;
  *) falla "ABORTO: la rama '$RESPALDO_RAMA' no empieza con respaldo/"; exit 2 ;;
esac

mkdir -p "$RESPALDO_DIR"
LOCK="$RESPALDO_DIR/.lock"
# Identidad de un proceso = PID + hora de inicio: tras un reinicio el PID de una
# corrida muerta puede tenerlo otro proceso vivo, y eso no es dueño del lock.
identidad() { printf '%s %s' "$1" "$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ')"; }
if ! mkdir "$LOCK" 2>/dev/null; then
  # Un lock huérfano (corte de luz, SIGKILL) no puede detener los respaldos para
  # siempre: si su dueño ya no vive, se recupera.
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
TMP="$(mktemp -d "$RESPALDO_DIR/.fuente.XXXXXX")"

dirs=""
for par in $PARES; do dirs="$dirs ${par%%:*}"; done

# 1. Copia de solo lectura de los workspaces vivos.
if [ "$RESPALDO_FUENTE" = ssh ]; then
  # El CLI de OpenClaw lee su config con su propia semántica (JSON5); no se
  # parsea el archivo a mano.
  OC="${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}"
  campo() { "$OC" config get "gateway.remote.$1" --json 2>/dev/null | tail -1 \
    | python3 -c 'import json,os,sys; print(os.path.expanduser(json.load(sys.stdin)))' 2>/dev/null; }
  SSH_TARGET="$(campo sshTarget)"; SSH_ID="$(campo sshIdentity)"
  if [ -z "$SSH_TARGET" ] || [ -z "$SSH_ID" ]; then
    falla "ABORTO: no se pudo leer gateway.remote.sshTarget/sshIdentity con $OC"; exit 4
  fi
  # A las 04:30 la Mac puede despertar sin red: se reintenta antes de abortar.
  intento=1
  while :; do
    find "$TMP" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    # shellcheck disable=SC2086
    if "${RESPALDO_SSH:-ssh}" -i "$SSH_ID" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
      "$SSH_TARGET" "tar -cf - -C $RESPALDO_RUNTIME$dirs" 2> "$RESPALDO_DIR/.ssh-error" | tar -xf - -C "$TMP"; then
      break
    fi
    causa="$(tr '\n' ' ' < "$RESPALDO_DIR/.ssh-error" | cut -c1-160)"
    if [ "$intento" -ge "$RESPALDO_INTENTOS" ]; then
      falla "ABORTO: no se pudo copiar los workspaces por SSH tras $intento intento(s): $causa"; exit 4
    fi
    log "intento $intento de copia por SSH falló ($causa); otro en ${RESPALDO_ESPERA}s"
    intento=$((intento + 1)); sleep "$RESPALDO_ESPERA"
  done
else
  for d in $dirs; do
    [ -d "$RESPALDO_FUENTE/$d" ] && cp -R "$RESPALDO_FUENTE/$d" "$TMP/"
  done
fi

# El .git vivo (si lo hay) no se respalda; los archivos enormes tampoco.
find "$TMP" -name .git -prune -exec rm -rf {} +
while IFS= read -r grande; do
  log "omitido por tamaño (>${RESPALDO_MAX_MB} MB): ${grande#"$TMP"/}"
  rm -f "$grande"
done < <(find "$TMP" -type f -size +"${RESPALDO_MAX_MB}"M)

fallas=0
for par in $PARES; do
  ws="${par%%:*}"; repo="${par#*:}"; src="$TMP/$ws"; clon="$RESPALDO_DIR/$repo"
  if [ ! -f "$src/IDENTITY.md" ]; then
    falla "$repo: FALLA: $ws no llegó entero (sin IDENTITY.md); su respaldo no se toca"
    fallas=$((fallas + 1)); continue
  fi
  (
    set -e
    [ -d "$clon/.git" ] || git clone -q --no-checkout "$RESPALDO_REMOTO_BASE/$repo.git" "$clon"
    cd "$clon"
    git fetch -q origin
    if git rev-parse -q --verify "refs/remotes/origin/$RESPALDO_RAMA" >/dev/null; then
      git checkout -q -B "$RESPALDO_RAMA" "origin/$RESPALDO_RAMA"
    else
      git checkout -q -B "$RESPALDO_RAMA" origin/HEAD
    fi
    # Espejo exacto del vivo: lo que ya no existe allá se borra en la rama de respaldo.
    git rm -rq --cached --ignore-unmatch . >/dev/null
    find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$src/." .
    # El índice quedó vacío con el `git rm --cached` de arriba: se agrega lo que
    # existe y los borrados ya están registrados. Esto corre en un clon dedicado
    # de la Mac, jamás dentro del runtime.
    git add .
    if git diff --cached --quiet; then
      echo "sin cambios"
    else
      git -c user.name=openclaw-respaldo -c user.email=respaldo@openclaw.invalid \
        commit -q -m "respaldo: $ws $(date '+%Y-%m-%d %H:%M')"
      git push -q origin "HEAD:refs/heads/$RESPALDO_RAMA"
      echo "respaldado $(git rev-parse --short HEAD)"
    fi
  ) > "$TMP/.salida" 2>&1
  rc=$?
  if [ $rc -eq 0 ]; then
    log "$repo: $(tail -1 "$TMP/.salida")"
  else
    falla "$repo: FALLA (rc=$rc): $(tr '\n' ' ' < "$TMP/.salida" | cut -c1-300)"
    fallas=$((fallas + 1))
  fi
done

[ "$fallas" -eq 0 ] || { log "terminado con $fallas falla(s)"; exit 1; }
log "terminado sin fallas"

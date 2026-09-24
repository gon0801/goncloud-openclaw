#!/bin/bash
# Respaldo diario, de UN SOLO SENTIDO, de los workspaces vivos del gateway Windows
# hacia GitHub: la rama `respaldo/runtime` de cada repo goncloud-workspace-*.
#
# Por qué desde la Mac: desde la separación del runtime (22/9) el sync del host está
# apagado y el host no tiene credenciales de GitHub; la Mac sí, y ya entra al host por
# SSH con la llave del túnel del gateway. No se crea ningún token.
#
# Qué NUNCA hace: escribir en el runtime (por SSH solo corre `tar -c`), empujar a una
# rama que no empiece con `respaldo/`, usar --force, ni respaldar un workspace que no
# llegó entero (sin IDENTITY.md aborta ese repo en vez de borrar su respaldo).
set -uo pipefail

RESPALDO_DIR="${RESPALDO_DIR:-$HOME/.openclaw-respaldo}"      # clones dedicados, nunca los de trabajo
RESPALDO_RAMA="${RESPALDO_RAMA:-respaldo/runtime}"
RESPALDO_FUENTE="${RESPALDO_FUENTE:-ssh}"                       # ssh | <dir local> (pruebas)
RESPALDO_REMOTO_BASE="${RESPALDO_REMOTO_BASE:-git@github.com:gon0801}"
RESPALDO_MAX_MB="${RESPALDO_MAX_MB:-50}"                         # GitHub rechaza archivos >100 MB
RUNTIME_WIN='C:/Users/ehven/.openclaw'

# workspace vivo -> repo de respaldo
PARES="workspace:goncloud-workspace-main workspace-operaciones:goncloud-workspace-operaciones workspace-ingenieria:goncloud-workspace-ingenieria"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

case "$RESPALDO_RAMA" in
  respaldo/?*) ;;
  *) log "ABORTO: la rama '$RESPALDO_RAMA' no empieza con respaldo/"; exit 2 ;;
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
TMP="$(mktemp -d "$RESPALDO_DIR/.fuente.XXXXXX")"
trap 'rm -rf "$TMP" "$LOCK"' EXIT

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
    log "ABORTO: no se pudo leer gateway.remote.sshTarget/sshIdentity con $OC"; exit 4
  fi
  # shellcheck disable=SC2086
  if ! ssh -i "$SSH_ID" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=20 \
      "$SSH_TARGET" "tar -cf - -C $RUNTIME_WIN$dirs" | tar -xf - -C "$TMP"; then
    log "ABORTO: no se pudo copiar los workspaces por SSH"; exit 4
  fi
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
    log "$repo: FALLA: $ws no llegó entero (sin IDENTITY.md); su respaldo no se toca"
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
    log "$repo: FALLA (rc=$rc): $(tr '\n' ' ' < "$TMP/.salida" | cut -c1-300)"
    fallas=$((fallas + 1))
  fi
done

[ "$fallas" -eq 0 ] || { log "terminado con $fallas falla(s)"; exit 1; }
log "terminado sin fallas"

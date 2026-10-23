#!/bin/bash
# Lo que comparten cron-avisa-instala.sh, cron-avisa-checklist.sh y cron-avisa-rollback.sh.
# Se ejecutan en la Mac con `bash <script>`, sin argumentos, y llegan al servidor por `ssh goncloud`.
# Ninguno corre una tarea del cron. CRON_AVISA_SSH solo cambia el host, para pruebas.
AQUI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CA_HOST=${CRON_AVISA_SSH:-goncloud}

# Se antepone al script remoto. Las rutas por omisión son las del servidor; las variables CA_* solo
# las cambian las pruebas (con el ssh falso, el entorno local sí llega).
read -r -d '' PRELUDIO <<'REMOTO' || true
set -eu
BIN=${CA_BIN:-/usr/local/bin}
ESTADO=${CA_ESTADO:-/var/lib/goncloud-cron}
RESPALDO=${CA_RESPALDO:-/root/cron-avisa-respaldo}
CROND=${CA_CROND:-/etc/cron.d}
LOG=${CA_LOG:-/var/log/cron-avisa-instala.log}
REVISA_LINEA='5 9 * * * root /usr/local/bin/cron-avisa --revisa'
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG"; }
objetivos() {
  echo usuario:root
  echo usuario:gon
  for f in "$CROND"/*; do
    [ -f "$f" ] || continue
    n=${f##*/}
    case $n in *.* | cron-avisa) continue ;; esac
    echo "cron.d:$n"
  done
}
vivo() {
  case $1 in
    usuario:*) crontab -l -u "${1#usuario:}" 2>/dev/null || true ;;
    cron.d:*) cat "$CROND/${1#cron.d:}" ;;
  esac
}
escribe_crond() {
  t=$(mktemp "$CROND/.cron-avisa.XXXXXX")
  cat > "$t"
  chmod 644 "$t"
  chown root:root "$t"
  mv -f "$t" "$CROND/$1"
}
REMOTO

remoto() {
  { printf '%s\n' "$PRELUDIO"; cat; } | ssh "$CA_HOST" bash -s -- "$@"
}

llevar_archivos() {
  CA_STAGE=$(ssh "$CA_HOST" 'mktemp -d /tmp/cron-avisa.XXXXXX')
  scp -q "$AQUI/cron-avisa" "$AQUI/cron-avisa-envuelve.py" "$CA_HOST:$CA_STAGE/"
  trap 'ssh "$CA_HOST" rm -rf "$CA_STAGE" >/dev/null 2>&1 || true' EXIT
}

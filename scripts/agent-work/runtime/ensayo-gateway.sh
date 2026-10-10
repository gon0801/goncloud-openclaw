#!/usr/bin/env bash
# Uso: ensayo-gateway.sh <copia-de-la-mini> <prefijo-con-bin/openclaw> [puerto]
# Arma un estado aislado con la copia consistente del gateway vivo y arranca ese gateway sin poder
# dañar nada (ensayo_host.py): sin canales, sin credenciales, sin cron, en sandbox sin red.
# Imprime ENSAYO=<dir> CLI=<dir>/oc-cli PID=<pid>; se detiene con kill $(cat <dir>/gateway.pid).
set -euo pipefail
exec python3 "$(dirname "$0")/ensayo_host.py" up "$@"

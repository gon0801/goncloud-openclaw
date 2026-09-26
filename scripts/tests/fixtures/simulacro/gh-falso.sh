#!/bin/sh
# Doble de gh para --ensayo (9.9, pieza a): solo lo que corrida/preflight.sh
# consulta (auth status, api user -q .login). Siempre "autenticado".
set -u
case "$*" in
  "auth status") exit 0;;
  "api user -q .login") echo "sim9-usuario"; exit 0;;
  *) exit 0;;
esac

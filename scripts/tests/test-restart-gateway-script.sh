#!/bin/bash
# Prueba del fallo 2026-09-11: el script de reinicio del gateway existia SOLO en el arbol de
# trabajo de la Mac (sin trackear), asi que el sync nunca lo copio a la maquina Windows y
# `powershell -File C:\Users\ehven\.openclaw\scripts\restart-openclaw-gateway.ps1` murio con
# "The argument ... does not exist". El candado de verdad es (1): el script tiene que estar EN
# el repo, no solo en disco. (2) prueba que (1) puede fallar; sin eso (1) pasaria por vacio.
# Uso: bash scripts/tests/test-restart-gateway-script.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
PS1FILE=scripts/restart-openclaw-gateway.ps1
fail() { echo "FAIL: $1"; exit 1; }

# (1) ROJO antes del fix: sin trackear, el script no llega al gateway por el sync de repos.
git ls-files --error-unmatch "$PS1FILE" >/dev/null 2>&1 \
  || fail "$PS1FILE no esta trackeado: el sync no lo copia al gateway (ese fue el bug)"
echo "ok (1): $PS1FILE esta trackeado en el repo"

# (2) Discriminacion: un archivo que existe en disco pero no en el indice tiene que dar rojo
# con el mismo comando de (1).
PROBE="scripts/.probe-untracked-$$.ps1"
trap 'rm -f "$PROBE"' EXIT
printf '# temporal\n' > "$PROBE" || fail "no se pudo crear el archivo de sonda"
if git ls-files --error-unmatch "$PROBE" >/dev/null 2>&1; then
  fail "un archivo recien creado figura como trackeado: la comprobacion (1) no discrimina"
fi
rm -f "$PROBE"
echo "ok (2): la comprobacion distingue trackeado de solo-en-disco"

# (3) El script conserva los tres pasos que lo hacen util: matar SOLO el node del gateway,
# rearrancar la tarea programada y confirmar que el puerto vuelve a escuchar.
while IFS= read -r anchor; do
  [ -n "$anchor" ] || continue
  grep -qF -- "$anchor" "$PS1FILE" || fail "$PS1FILE: falta el paso: $anchor"
done <<'ANCHORS'
Name='node.exe'
openclaw\\dist\\index\.js gateway
Start-ScheduledTask -TaskName 'OpenClaw Gateway'
Get-NetTCPConnection -State Listen -LocalPort 18789
RESTART_OK
RESTART_FAIL
ANCHORS
echo "ok (3): el script mata el node del gateway, rearranca la tarea y verifica el 18789"

# (4) El filtro del proceso no puede ser solo "node.exe": en esa maquina corren otros node
# (chroma, MCP) y matarlos todos es un apagon, no un reinicio.
grep -qF 'CommandLine -match' "$PS1FILE" \
  || fail "$PS1FILE: el filtro no mira CommandLine; mataria cualquier node.exe"
echo "ok (4): filtra por CommandLine, no por nombre de proceso"

echo "PASS test-restart-gateway-script"

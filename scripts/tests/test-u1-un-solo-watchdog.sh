#!/bin/bash
# U1: un solo dueño del watchdog y de los avisos.
#
# - Liveness activa: gateway-watchdog.ps1 (único vigilante programado).
# - scripts/sync-repos.ps1: obsoleto (git add -A dentro del vivo, prohibido);
#   se conserva por historia, fuera del camino activo.
# - scripts/sync-seguro/: único camino de sync (desactivado por defecto, sin
#   git, sin Telegram, sin tareas programadas).
#
# Uso: bash scripts/tests/test-u1-un-solo-watchdog.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

[ -f gateway-watchdog.ps1 ] || fail "falta gateway-watchdog.ps1 (dueño de liveness)"
grep -q "U1-OBSOLETO" gateway-watchdog.ps1 && fail "el watchdog activo está marcado obsoleto"
grep -q "U1-OBSOLETO" scripts/sync-repos.ps1 || fail "sync-repos.ps1 perdió su marca U1-OBSOLETO"

# Watchdogs activos: solo el que vigila con gracia de arranque y log propio.
activos=$(git ls-files '*.ps1' | while IFS= read -r f; do
  case "$f" in *bak*|*fixtures*|workspace-*) continue ;; esac
  if grep -q "Watchdog-Log" "$f" && grep -q "bootGraceSeconds" "$f"; then
    printf '%s\n' "$f"
  fi
done)
[ "$activos" = "gateway-watchdog.ps1" ] || fail "dueño de watchdog != 1: [$activos]"

# Quien arranque la tarea del gateway es el watchdog o la herramienta manual.
arrancan=$(git ls-files '*.ps1' | while IFS= read -r f; do
  case "$f" in *bak*|*fixtures*|workspace-*) continue ;; esac
  if grep -q "Start-ScheduledTask" "$f"; then printf '%s\n' "$f"; fi
done | LC_ALL=C sort | tr '\n' ' ')
[ "$arrancan" = "gateway-watchdog.ps1 scripts/restart-openclaw-gateway.ps1 " ] \
  || fail "actores que arrancan el gateway: [$arrancan]"
grep -q "Watchdog-Log" scripts/restart-openclaw-gateway.ps1 \
  && fail "la herramienta manual de reinicio parece watchdog"

# Todo `git add -A` en código activo vive en un archivo marcado obsoleto (los
# tests viejos que nombran el patrón para fijar conducta pasada no son camino
# activo y no se tocan).
while IFS= read -r f; do
  case "$f" in *bak*|*fixtures*|workspace-*|scripts/tests/*) continue ;; esac
  if grep -q "git add -A" "$f"; then
    grep -q "U1-OBSOLETO" "$f" || fail "$f trae git add -A sin marca U1-OBSOLETO"
  fi
done < <(git ls-files --cached --others --exclude-standard '*.ps1' '*.sh' '*.mjs')

# Nuestro código ejecutable jamás usa ese patrón (este guard y el README lo
# nombran para prohibirlo, por eso se excluyen solos).
if grep -rn "git add -A" scripts/sync-seguro/*.mjs scripts/tests/test-u1-*.mjs 2>/dev/null; then
  fail "código nuevo con git add -A"
fi

# El sync nuevo solo nombra openclaw en sus guardias ("esta raíz sí es vivo,
# me niego") y en la política (denylist de openclaw.json, allowlist de
# openclaw.plugin.json); nunca como destino de git u operaciones.
if grep -n "openclaw" scripts/sync-seguro/*.mjs \
  | grep -v '=== ".openclaw"' \
  | grep -v "openclaw\\\\.json" \
  | grep -v "openclaw.plugin.json"; then
  fail "sync-seguro nombra openclaw fuera de guardia/política"
fi

# El sync nuevo: sin git, sin Telegram, sin programadores.
if grep -rn -E "git add|sendMessage|telegram|Telegram|Start-ScheduledTask|Register-ScheduledTask|schtasks|crontab" scripts/sync-seguro/*.mjs; then
  fail "scripts/sync-seguro trae git, avisos o programador"
fi

# Cero activaciones programadas del sync nuevo: solo sus scripts, sus pruebas,
# su README y el apuntador del obsoleto lo nombran.
while IFS= read -r f; do
  case "$f" in
    scripts/sync-seguro/*|scripts/tests/test-u1-*|scripts/sync-repos.ps1) ;;
    *) fail "sync-seguro referenciado fuera de su camino: $f" ;;
  esac
done < <(git ls-files --cached --others --exclude-standard | xargs grep -l "sync-seguro" 2>/dev/null)

echo "ok: un solo dueño de watchdog/avisos; sync viejo obsoleto; sync nuevo sin activar"

#!/bin/bash
# Vigía de rebase del gateway: prueba semanal de cuánto se alejó la versión
# pública de OpenClaw de nuestra rama de integración (R).
#
# POR QUÉ: dejar pasar un mes vuelve el rebase carísimo (2026.9.7 -> 2026.10.4:
# 3333 commits públicos y 48 archivos de código en conflicto). La decisión de
# David (2026-10-18) es actualizar cada 1-2 semanas: esta prueba mide la brecha
# cada lunes y avisa por Telegram una sola vez por versión.
#
# QUÉ HACE: lee la versión del canal latest en npm (nunca beta), trae SOLO ese
# tag desde origin (el repo pesa 9 GB: un fetch completo está prohibido), cuenta
# los commits nuevos, hace el merge en memoria (merge-tree no toca el árbol) para
# clasificar los archivos que chocan en "versión" y "código", escribe el reporte
# en ~/.local/state/vigia-rebase-r/ y avisa con una recomendación.
#
# QUÉ NUNCA HACE: tocar R más allá de dos escrituras de solo objetos: traer ese
# único tag (crea refs/tags/vX) y el merge en memoria (merge-tree --write-tree
# deja objetos sueltos en .git/objects; no crea refs ni toca el árbol de
# trabajo). Nada de checkout, rebase, merge real ni worktrees. Y jamás reporta
# "0 choques" por una falla: npm, fetch o merge-tree rotos salen != 0 con el
# motivo en stderr, y un choque que merge-tree no puede listar (p. ej. renombre
# de directorio: rc=1 sin archivos) sale como conflicto no clasificable.
set -euo pipefail

R="${R_REPO:-/Users/dn/dev/openclaw-agent-work-integration}"
RAMA="${R_RAMA:-feat/agent-work-integration}"
ESTADO="${VIGIA_ESTADO:-$HOME/.local/state/vigia-rebase-r}"
SIN_AVISO="${VIGIA_SIN_AVISO:-}"
# Timeouts en segundos; bajables por entorno para las pruebas.
T_NPM="${VIGIA_TIMEOUT_NPM:-120}"
T_FETCH="${VIGIA_TIMEOUT_FETCH:-600}"
T_MERGE="${VIGIA_TIMEOUT_MERGE:-300}"
T_SSH="${VIGIA_TIMEOUT_SSH:-60}"
DESTINO="${VIGIA_SSH_DESTINO:-gon@100.73.187.5}"
TARGET="${VIGIA_TELEGRAM_TARGET:-6470689715}"
# La Mini solo acepta id_gateway; bajo launchd el agente puede venir vacío.
LLAVE="${VIGIA_SSH_LLAVE:-$HOME/.ssh/id_gateway}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
falla() { printf '[%s] FALLA: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

# Muere el comando que se cuelga, no la corrida entera. alarm de perl porque
# macOS no trae timeout(1) de serie y bajo launchd no hay coreutils. El comando
# corre en su propio grupo de procesos: al vencer el plazo muere el grupo
# entero (npm y sus hijos), no solo el proceso de adelante, o un hijo vivo
# seguiría sosteniendo la salida y la corrida seguiría colgada.
con_timeout() {
  local secs=$1; shift
  perl -e '
    my $secs = shift @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) { setpgrp(0, 0); exec(@ARGV) or exit 127; }
    $SIG{ALRM} = sub { kill "TERM", -$pid; kill "KILL", -$pid; };
    alarm $secs;
    waitpid($pid, 0);
    my $st = $?;
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' "$secs" "$@"
}

[ -d "$R" ] || falla "no existe el repo R: $R"
git -C "$R" rev-parse --verify "$RAMA" >/dev/null 2>&1 \
  || falla "la rama $RAMA no existe en $R"

# 1. Versión pública del canal latest (nunca beta).
ver=$(con_timeout "$T_NPM" npm view openclaw dist-tags.latest | tr -d '[:space:]') \
  || falla "npm view falló (timeout ${T_NPM}s o red)"
case "$ver" in
  ''|*[!0-9.]*) falla "npm devolvió algo que no parece versión del canal latest: '$ver'" ;;
esac

# 2. Solo ese tag: lo demás ya está en el repo.
log "buscando el tag v$ver en origin..."
if ! salida=$(con_timeout "$T_FETCH" git -C "$R" fetch origin --no-tags "tag" "v$ver" 2>&1); then
  falla "no se pudo traer v$ver (timeout ${T_FETCH}s o red): $(printf '%s' "$salida" | tail -2 | tr '\n' ' ')"
fi

# 3. Base: la versión pública estable sobre la que ya está RAMA.
base=$(git -C "$R" tag --merged "$RAMA" 2>/dev/null \
        | grep -E '^v[0-9]+(\.[0-9]+)+$' | sed 's/^v//' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1) || true
[ -n "$base" ] || falla "no hay ningún tag v* estable en la historia de $RAMA: no sé contra qué comparar"

if [ "$base" = "$ver" ]; then
  log "al día: $RAMA ya está sobre v$base, última versión del canal latest"
  exit 0
fi
# R adelante del canal latest (p. ej. release candado sin publicar): el rango
# v$ver..v$base daría una brecha al revés y un aviso de una versión anterior.
# Misma salida que al día: nada que medir, sin aviso.
if [ "$(printf '%s\n' "$base" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$base" ]; then
  log "al día (adelantado): $RAMA va en v$base, más nueva que el canal latest (v$ver)"
  exit 0
fi

nuevos=$(git -C "$R" rev-list --count "v$base..v$ver") \
  || falla "no pude contar los commits de v$base..v$ver"

# 4. Choques: merge en memoria. 0 = limpio, 1 = conflictos, >1 = roto (falla,
#    nunca cuenta como "0 choques").
rc=0
mt=$(con_timeout "$T_MERGE" git -C "$R" merge-tree --write-tree --name-only --no-messages "$RAMA" "v$ver" 2>&1) || rc=$?
[ "$rc" -le 1 ] || falla "merge-tree falló (rc=$rc): $(printf '%s' "$mt" | tail -2 | tr '\n' ' ')"
# La primera línea es el OID del árbol resultante; el resto, los archivos en conflicto.
lineas=$(printf '%s\n' "$mt" | sed '1d;/^[[:space:]]*$/d')
# rc=1 sin archivos listados: git documenta choques que merge-tree no puede
# nombrar por archivo (p. ej. renombre de directorio). Contar cero aquí
# haría pasar un choque por merge limpio: se reporta como conflicto no
# clasificable en el log, el reporte y el aviso.
oscuro=0
if [ "$rc" -eq 1 ] && [ -z "$lineas" ]; then oscuro=1; fi
total=0; k=0; archivos_codigo=""; archivos_version=""
if [ -n "$lineas" ]; then
  RE_VERSION='(^|/)CHANGELOG|Info\.plist$|^package\.json$|^extensions/[^/]+/package\.json$|^docs/\.generated/'
  total=$(printf '%s\n' "$lineas" | grep -c . || true)
  k=$(printf '%s\n' "$lineas" | grep -Evc "$RE_VERSION" || true)
  archivos_codigo=$(printf '%s\n' "$lineas" | grep -Ev "$RE_VERSION" || true)
  archivos_version=$(printf '%s\n' "$lineas" | grep -E "$RE_VERSION" || true)
fi
total=${total:-0}; k=${k:-0}
n_version=$((total - k))

if [ "$oscuro" = 1 ]; then
  log "brecha medida: $RAMA va en v$base; pública v$ver: $nuevos commits nuevos, conflicto no clasificable (merge-tree chocó sin listar archivos)"
else
  log "brecha medida: $RAMA va en v$base; pública v$ver: $nuevos commits nuevos, $k archivos de código y $n_version de versión chocan"
fi

# 5. Reporte completo; los archivos de código, uno por línea.
mkdir -p "$ESTADO" || falla "no pude crear $ESTADO"
REPORTE="$ESTADO/$(date +%Y-%m-%d)-v$ver.txt"
{
  printf 'vigia-rebase-r %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf 'R: %s (rama %s)\n' "$R" "$RAMA"
  printf 'versión pública nueva: %s — claw va en: %s\n' "$ver" "$base"
  printf 'cambios públicos nuevos: %s\n' "$nuevos"
  if [ "$oscuro" = 1 ]; then
    printf 'conflicto no clasificable: merge-tree reportó choque sin listar archivos (p. ej. renombre de directorio); los conteos por archivo no aplican\n'
  else
    printf 'archivos en conflicto: %s de código, %s de versión\n' "$k" "$n_version"
    printf 'archivos de código que chocan:\n'
    if [ "$k" -gt 0 ]; then printf '%s\n' "$archivos_codigo"; else printf '(ninguno)\n'; fi
    printf 'archivos de versión que chocan:\n'
    if [ -n "$archivos_version" ]; then printf '%s\n' "$archivos_version"; else printf '(ninguno)\n'; fi
  fi
} > "$REPORTE" || falla "no pude escribir el reporte $REPORTE"
log "reporte: $REPORTE"

# 6. Aviso a David por Telegram, una sola vez por versión.
MARCA="$ESTADO/avisado-v$ver"
if [ -f "$MARCA" ]; then
  log "v$ver ya se había avisado; no repite"
  exit 0
fi
if [ -n "$SIN_AVISO" ]; then
  log "VIGIA_SIN_AVISO: corrida en seco, no avisa ni marca"
  exit 0
fi
if [ "$oscuro" = 1 ]; then
  recomendacion="Hay un choque que el conteo no pudo clasificar: revisa el reporte antes de actualizar."
  texto="🔄 OpenClaw $ver ya salió. claw va en $base: $nuevos cambios públicos, conflicto no clasificable (merge-tree chocó sin listar archivos). $recomendacion"
else
  if [ "$k" -le 10 ]; then
    recomendacion="Conviene actualizar esta semana."
  else
    recomendacion="Ya se juntó bastante: hay que actualizar ya."
  fi
  texto="🔄 OpenClaw $ver ya salió. claw va en $base: $nuevos cambios públicos, $k archivos de código chocan con lo nuestro. $recomendacion"
fi
if ! salida_ssh=$(con_timeout "$T_SSH" ssh -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$LLAVE" "$DESTINO" "~/.openclaw/bin/openclaw message send --channel telegram --target $TARGET --json --message '$texto'" 2>&1); then
  # Sin marca a propósito: la próxima corrida reintenta el aviso de esta versión.
  falla "el aviso por Telegram no salió: $(printf '%s' "$salida_ssh" | tail -2 | tr '\n' ' ')"
fi
# La marca solo con el envío confirmado: el CLI contesta --json con el
# messageId del mensaje entregado. Un rc 0 sin messageId (CLI viejo, salida
# recortada, envío no entregado) no prueba nada: sin marca y != 0, la próxima
# corrida reintenta. El || true guarda el rc de grep cuando no hay id.
id_mensaje=$(printf '%s' "$salida_ssh" | { grep -oE '"messageId"[[:space:]]*:[[:space:]]*"[^"]+"' || true; } | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//')
[ -n "$id_mensaje" ] \
  || falla "el envío no confirmó messageId (no hay marca): $(printf '%s' "$salida_ssh" | tail -2 | tr '\n' ' ')"
: > "$MARCA" || falla "el aviso salió pero no pude escribir la marca $MARCA: se repetiría"
log "aviso enviado por Telegram (messageId $id_mensaje): $texto"
exit 0

#!/bin/bash
# Prueba del incidente 2026-09-15 (corrida nocturna de claw): los runbooks de autopilot
# contradecían al kit de merge y al entorno de la Mac, y claw perdió la noche atascado:
# (a) la fase 6 mandaba commitear `saikit-setup-autopilot.sh` "en el PR del carril" cuando
# el gate lee `.saikit/autopilot.json` de `origin/<default>` (saikit-merge.sh línea 273) y
# rechaza al PR que lo toca (línea 427) — bootstrap imposible; (b) pedía `docker run`
# postgres cuando Docker no está en la Mac; (c) decía que `~/bin/glm` es "Claude Code
# apuntado a glm-5.3" cuando hoy ejecuta zcode; (d) daba comandos para el exec de la Mac
# (`pwsh` del cross-review, subcomandos de tmux) sin prefijo de PATH ni ruta absoluta,
# cuando el exec pasa por OpenClaw.app con el PATH de launchd (sin Homebrew ni ~/bin).
# Verifica: (1) el detector marca las formas malas y deja pasar las buenas y las
# prohibiciones (discrimina); (2) ningún runbook versionado contiene las formas malas.
# Alcance del paso (2): las contradicciones (a)-(c) se revisan en docs/runbooks/*.md;
# los comandos (d) solo en autopilot-fase6/7.md, que es donde claw corre por exec en el
# nodo Mac. `gh` lo cubre el detector y los fixtures: en estos runbooks no hay hoy
# instancias de `gh` por exec de la Mac (los `gh pr view/merge` citados corren en el
# gateway Windows o en la shell del lead), así que el escaneo de archivos no lo incluye.
# Uso: bash scripts/tests/test-runbooks-no-contradicen-entorno.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# (a) bootstrap imposible, (b) docker en una Mac sin Docker, (c) identidad vieja de glm.
# Una prohibición ("nunca ...") cita la forma mala sin mandarla: no es una contradicción.
BAD_FASE='commiteado en el PR del carril|docker run|Claude Code apuntado a'
mal_fase() { grep -n -E -e "$BAD_FASE" | grep -v -i -E 'nunca|jam[aá]s|never'; }

# (d) comandos del exec de la Mac sin prefijo de PATH ni ruta absoluta.
# `pwsh` pelado o cross-review.ps1 sin el prefijo del guardrail y sin su ruta absoluta;
# `tmux` pelado (la forma normal, `tmux capture-pane ...`) y tambien el subcomando suelto
# (`capture-pane ...`), los dos sin el binario absoluto.
mal_path() {
  local input; input=$(cat)
  {
    printf '%s\n' "$input" | grep -n -E -e '`pwsh[[:space:]]' -e 'cross-review\.ps1' \
      | grep -v 'export PATH=/opt/homebrew/bin' | grep -v '/Users/dn/.local/bin/pwsh' \
      | grep -v -i -E 'nunca|jam[aá]s|never' || true
    printf '%s\n' "$input" | grep -n -E -e '`tmux[[:space:]]' \
      -e '`(capture-pane|send-keys|set-environment|show-environment|list-sessions|new-session)' \
      | grep -v '/opt/homebrew/bin/tmux' \
      | grep -v -i -E 'nunca|jam[aá]s|never' || true
  } | grep .
}
# `gh` por exec de la Mac: el detector lo marca pelado y deja pasar el prefijado.
mal_gh() { grep -n -E -e '`gh[[:space:]]' | grep -v 'export PATH=/opt/homebrew/bin'; }

# (1) Discrimina: las formas de la noche del 15 se marcan...
for c in 'va commiteado en el PR del carril, es lo que el gate lee' \
         'docker run -d --name orbit-verify -p 127.0.0.1:5433:5432 postgres:16' \
         'se lanza con `~/bin/glm` (Claude Code apuntado a `glm-5.3`)' \
         '`pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto`' \
         'desde el worktree, `pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto -Excluir claude`' \
         'leyendo la pantalla (`capture-pane -p -t glm-wt-f7-P -S -60`)' \
         'se lee con `tmux capture-pane -p -t glm-wt-f7-P -S -60` y listo' \
         'arranca con `tmux new-session -d -s glm-wt-f7-P`' \
         'con `set-environment -t glm-wt-f7-P OPENCLAW_WATCH 1`' \
         '`gh pr checks 123 --watch`'; do
  if printf '%s\n' "$c" | grep -q 'cross-review\.ps1\|`pwsh[[:space:]]\|capture-pane\|set-environment\|`tmux[[:space:]]'; then
    printf '%s\n' "$c" | mal_path >/dev/null || fail "mal_path NO marca: $c"
  elif printf '%s\n' "$c" | grep -q '`gh[[:space:]]'; then
    printf '%s\n' "$c" | mal_gh >/dev/null || fail "mal_gh NO marca: $c"
  else
    printf '%s\n' "$c" | mal_fase >/dev/null || fail "mal_fase NO marca: $c"
  fi
done
# ...y las formas correctas y las prohibiciones no.
for c in 'un PR `bootstrap: .saikit/autopilot.json` con solo ese archivo, que mergea David a mano' \
         'Postgres de Homebrew en `127.0.0.1:5433` con una base desechable (Docker no está en la Mac)' \
         'se lanza con `~/bin/glm` (zcode, el CLI propio del runtime ZCode de Z.AI)' \
         '`export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; /Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 -Con auto`' \
         '`export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; pwsh -NoProfile -File x.ps1`' \
         '`/opt/homebrew/bin/tmux capture-pane -p -t sesion -S -60`' \
         'lanza con `/opt/homebrew/bin/tmux new-session -d -s x` y ya' \
         '`export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; gh pr checks 123`' \
         'Nunca pidas `docker run` en la Mac: Docker no está instalado' \
         'nunca digas "Claude Code apuntado a glm": hoy `~/bin/glm` es zcode'; do
  if printf '%s\n' "$c" | grep -q 'cross-review\.ps1\|`pwsh[[:space:]]\|capture-pane\|set-environment\|tmux[[:space:]]'; then
    printf '%s\n' "$c" | mal_path >/dev/null && fail "mal_path marca una forma correcta: $c"
  elif printf '%s\n' "$c" | grep -q '`gh[[:space:]]\|docker run\|Claude Code apuntado a\|commiteado en el PR'; then
    printf '%s\n' "$c" | mal_fase >/dev/null && fail "mal_fase marca una forma correcta: $c"
    printf '%s\n' "$c" | mal_gh >/dev/null && fail "mal_gh marca una forma correcta: $c"
  else
    printf '%s\n' "$c" | mal_path >/dev/null && fail "mal_path marca una forma correcta: $c"
    printf '%s\n' "$c" | mal_gh >/dev/null && fail "mal_gh marca una forma correcta: $c"
  fi
done
echo "ok (1): el detector marca bootstrap imposible, docker run, glm viejo y comandos sin PATH; deja pasar las formas buenas y las prohibiciones"

# (2) Ningún runbook versionado trae las formas malas.
n=$(git ls-files --cached --others --exclude-standard -- 'docs/runbooks/*.md' | wc -l)
[ "$n" -gt 0 ] || fail "no encontre runbooks que revisar"
hits=$(git ls-files -z --cached --others --exclude-standard -- 'docs/runbooks/*.md' \
  | xargs -0 grep -n -E -e "$BAD_FASE" -- 2>/dev/null | grep -v -i -E 'nunca|jam[aá]s|never')
[ -z "$hits" ] || fail "runbooks que contradicen al kit o al entorno:
$hits"
echo "ok (2): $n runbooks revisados, sin bootstrap imposible, sin docker run y sin glm viejo"

# (2b) Los comandos del exec de la Mac en los autopilot llevan prefijo o ruta absoluta.
AUTO=$(git ls-files --cached --others --exclude-standard -- 'docs/runbooks/autopilot-fase6.md' 'docs/runbooks/autopilot-fase7.md')
[ -n "$AUTO" ] || fail "no encontre los runbooks de autopilot"
hits2=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  out=$(mal_path < "$f" | sed "s|^|$f:|")
  [ -n "$out" ] && hits2="$hits2
$out"
done <<EOF
$AUTO
EOF
[ -z "$hits2" ] || fail "comandos del exec de la Mac sin prefijo de PATH ni ruta absoluta:$hits2"
echo "ok (2b): cross-review y tmux de los autopilot con prefijo de PATH o ruta absoluta"
echo "TODO VERDE: runbooks sin contradicciones con el kit ni con el entorno"

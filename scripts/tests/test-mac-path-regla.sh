#!/bin/bash
# Prueba del incidente 2026-09-15 (corrida nocturna de claw): el exec del nodo Mac sanea
# el PATH (`sanitizeHostExecEnv({blockPathOverrides:true})`, medido en el `dist` de
# OpenClaw 2026.9.4) e ignora `pathPrepend`, pero las skills de la Mac mandaban comandos
# pelados (`gh pr checks`, `tmux ...`, subcomandos sueltos como `capture-pane`) que en el
# exec mueren con `command not found`; `mac-terminal-control` pedía anteponer solo
# `$PATH:/opt/homebrew/bin` (sin `~/.local/bin` ni `~/bin`, donde viven `pwsh`, `muse` y
# los lanzadores); y `mac-tmux-control` decía que `glm` es Claude Code contra otro
# proveedor, cuando hoy es zcode.
# Verifica: (1) la regla del PATH existe con texto idéntico en las tres skills (ancla);
# (2) ninguna línea de comando de esas skills invoca `gh`, `pwsh`, `grok`, `zcode`,
# `kimi`, `codex` o `tmux` (ni un subcomando suelto de tmux) sin prefijo de PATH ni ruta
# absoluta, salvo dentro de prohibiciones; (3) el detector discrimina con fixtures inline.
# Qué cuenta como invocación: un tramo entre backticks que EMPIEZA con el tool + args
# (`` `gh pr ...` ``) o con un subcomando de tmux (`` `capture-pane ...` ``). No cuentan:
# nombres sueltos (`` `glm` ``), rutas absolutas (`` `/opt/homebrew/bin/gh ...` ``),
# tramos con `export PATH=/opt/homebrew/bin` dentro, citas de eventos o errores
# (`` `tmux: <session> quiet ...` ``, `` `gh: command not found` ``) ni líneas de
# prohibición (`never`/`nunca`/`jamás`).
# Uso: bash scripts/tests/test-mac-path-regla.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SK1=agents/main/agent/workshop-skills/mac-tmux-control/SKILL.md
SK2=agents/main/agent/workshop-skills/mac-terminal-control/SKILL.md
SK3=agents/implementer/agent/workshop-skills/mac-exec-detach-poll/SKILL.md
# El ancla va en el idioma de cada skill (las dos de main estan en ingles,
# mac-exec-detach-poll en espanol): mezclar idiomas dentro de una skill la vuelve
# ilegible para quien la lee de corrido. Lo que NO cambia entre idiomas, y es lo que
# de verdad sostiene la regla, es el prefijo exacto del PATH: se exige en las tres.
ANCLA_EN='the node exec sanitizes PATH and **`pathPrepend` is ignored**'
ANCLA_ES='el exec del nodo sanea el PATH y **`pathPrepend` se ignora**'
PREFIJO='export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH;'

# Invocaciones peladas en la entrada estándar: tramos `tool args...` o subcomandos de
# tmux que no traen prefijo de PATH ni ruta absoluta. Las prohibiciones se excluyen.
mal_cmd() {
  local input; input=$(cat)
  { printf '%s\n' "$input" | grep -v -i -E 'never|nunca|jam[aá]s' || true; } \
    | grep -o -E '`[^`]*`' \
    | grep -E -e '^`(gh|pwsh|grok|zcode|kimi|codex|tmux)[[:space:]]' \
      -e '^`(capture-pane|send-keys|set-environment|show-environment|list-sessions|new-session)([[:space:]]|`)'
}
# (3) Discrimina con fixtures inline: las formas peladas se marcan...
for c in '`gh pr checks 123 --watch`' \
         '`tmux new-session -d -s claw -c /tmp/x`' \
         '`tmux send-keys -t claw -l hola`' \
         '`capture-pane -p -t sesion -S -60`' \
         '`show-environment -t sesion OPENCLAW_WATCH`' \
         '`set-environment -t sesion OPENCLAW_WATCH 1`' \
         '`pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1`' \
         '`grok hola`' \
         '`zcode estado`' \
         'lee con `capture-pane` y decide'; do
  printf '%s\n' "$c" | mal_cmd | grep -v 'export PATH=/opt/homebrew/bin' | grep -v '^`/' | grep -q . \
    || fail "el detector NO marca: $c (la prueba no discrimina)"
done
# ...y las formas buenas, los nombres sueltos, las citas y las prohibiciones no.
for c in '`export PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:$PATH; gh pr checks 123`' \
         '`/opt/homebrew/bin/tmux capture-pane -p -t sesion -S -60`' \
         '`/opt/homebrew/bin/gh pr checks 123 --watch`' \
         '`/Users/dn/.local/bin/pwsh -NoProfile -File x.ps1`' \
         '`/opt/homebrew/bin/zcode` (= `glm`)' \
         'his shell wraps `claude`, `glm`, `deepseek`, `kimi-claude` through `~/bin/agent-tmux.sh`' \
         '`tmux: <session> quiet for Ns | read it`' \
         '(`gh: command not found` from `/bin/sh` on the gateway)' \
         'Never write to `/dev/ttysNNN` to "inject" input' \
         'never run `tmux new-session` without marking the session first'; do
  out=$(printf '%s\n' "$c" | mal_cmd | grep -v 'export PATH=/opt/homebrew/bin' | grep -v '^`/' || true)
  [ -z "$out" ] || fail "el detector marca una forma correcta: $c -> $out"
done
echo "ok (3): el detector marca invocaciones peladas y deja pasar prefijos, rutas absolutas, nombres, citas y prohibiciones"

# (1) La regla del PATH existe en las tres skills: mismo prefijo exacto en las tres,
# y el ancla en el idioma de cada archivo.
for f in "$SK1" "$SK2" "$SK3"; do
  [ -f "$f" ] || fail "falta $f"
  grep -qF "$PREFIJO" "$f" || fail "$f: falta el prefijo exacto del PATH"
done
grep -qF "$ANCLA_EN" "$SK1" || fail "$SK1: falta la regla del PATH (ancla en inglés)"
grep -qF "$ANCLA_EN" "$SK2" || fail "$SK2: falta la regla del PATH (ancla en inglés)"
grep -qF "$ANCLA_ES" "$SK3" || fail "$SK3: falta la regla del PATH (ancla en español)"
echo "ok (1): la regla del PATH está en las tres skills, con el mismo prefijo y en el idioma de cada una"

# (2) Ninguna línea de comando de esas skills invoca un tool pelado.
hits=""
for f in "$SK1" "$SK2" "$SK3"; do
  while IFS= read -r line; do
    case "$line" in
      *never*|*Never*|*NEVER*|*nunca*|*Nunca*|*NUNCA*|*jamás*|*jamas*|*JAMÁS*|*JAMAS*) continue ;;
    esac
    spans=$(printf '%s\n' "$line" | grep -o -E '`[^`]*`' || true)
    [ -z "$spans" ] && continue
    bad=$(printf '%s\n' "$spans" | grep -E -e '^`(gh|pwsh|grok|zcode|kimi|codex|tmux)[[:space:]]' \
      -e '^`(capture-pane|send-keys|set-environment|show-environment|list-sessions|new-session)([[:space:]]|`)' || true)
    bad=$(printf '%s\n' "$bad" | grep -v 'export PATH=/opt/homebrew/bin' | grep -v '^`/' || true)
    [ -n "$bad" ] && hits="$hits
$f: $line"
  done < "$f"
done
[ -z "$hits" ] || fail "invocaciones sin prefijo de PATH ni ruta absoluta:$hits"
echo "ok (2): las tres skills invocan tools solo con prefijo de PATH o ruta absoluta"
echo "TODO VERDE: regla del PATH en las skills de la Mac"

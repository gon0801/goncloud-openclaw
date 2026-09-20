#!/bin/bash
# Prueba del incidente 2026-09-11: operaciones corrio `openclaw browser reset-profile` con el flag
# global `--profile claw` en vez de `--browser-profile claw`. El global manda estado/config a
# ~/.openclaw-claw (no existe), el CLI se queda sin datos del gateway y falla con "gateway
# browser.request requires credentials": los agentes persiguieron una "clave" que no faltaba y el
# reinicio innecesario mato la corrida 11h. Y reset-profile manda el perfil logueado a la Papelera.
# Verifica: (1) el detector marca las formas del incidente y deja pasar las correctas (discrimina);
# (2) ninguna instruccion versionada para agentes usa la forma mala; (3) la skill con la regla esta
# en main/operaciones/ingenieria, identica y con sus anclas; (4) con CLI local, el mecanismo sigue.
# Uso: bash scripts/tests/test-browser-profile-flag.sh
# OJO SI ESTA PRUEBA SE PONE EN ROJO POR EL PASO (3), el de "difiere de":
# los archivos bajo agents/*/agent/workshop-skills/ son ARTEFACTOS GENERADOS. El cron
# "auto: snapshot .openclaw" los reescribe desde los workspaces vivos del gateway
# (C:\Users\ehven\.openclaw\agents\<agente>\agent\workshop-skills\) cada ~2 h.
# Arreglar la desviacion SOLO en el repo no sirve: el siguiente snapshot la revierte y la
# prueba vuelve a rojo sola. Medido el 2026-09-12: el arreglo se deshizo y reaparecio como
# conflicto de merge en el PR #25.
# El arreglo va en el gateway (copiar la copia de referencia sobre la desviada ahi), y
# despues el snapshot lo propaga al repo.
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
# Comando `openclaw browser` con el flag global suelto, o con reset-profile sobre claw.
BAD_FLAG='openclaw browser.*[[:space:]]--profile([[:space:]=]|$)'
BAD_RESET='openclaw browser.*(reset-profile.*claw|claw.*reset-profile)'
bad() { grep -n -E -e "$BAD_FLAG" -e "$BAD_RESET"; }

# (1) Discrimina: los comandos exactos del incidente se marcan; las formas correctas no.
for c in 'openclaw browser reset-profile --profile claw 2>&1' \
         'openclaw browser tabs --profile claw --json 2>&1' \
         'openclaw browser tabs --profile=claw' \
         'openclaw browser --browser-profile claw reset-profile'; do
  printf '%s\n' "$c" | bad >/dev/null || fail "el detector NO marca: $c (la prueba no discrimina)"
done
for c in 'openclaw browser --browser-profile claw tabs --json' \
         'openclaw browser tabs --browser-profile claw --json 2>&1' \
         'openclaw browser open https://example.com --browser-profile claw --label sc'; do
  printf '%s\n' "$c" | bad >/dev/null && fail "el detector marca una forma correcta: $c"
done
echo "ok (1): el detector marca --profile y reset-profile sobre claw, y deja pasar --browser-profile"

# (2) Ninguna instruccion versionada para agentes (skills, AGENTS/TOOLS, prompts de cron) usa la
# forma mala. Fuera: transcripts y memoria (historial real, pueden citar el incidente).
SPECS=('agents/*/agent/workshop-skills/*/SKILL.md' '*AGENTS.md' '*TOOLS.md' 'docs/cron-messages/*.txt')
n=$(git ls-files --cached --others --exclude-standard -- "${SPECS[@]}" | wc -l)
[ "$n" -gt 0 ] || fail "no encontre instrucciones versionadas que revisar"
hits=$(git ls-files -z --cached --others --exclude-standard -- "${SPECS[@]}" \
  | xargs -0 grep -n -E -e "$BAD_FLAG" -e "$BAD_RESET" -- 2>/dev/null)
[ -z "$hits" ] || fail "instrucciones con la forma mala del flag:
$hits"
echo "ok (2): $n instrucciones revisadas, ninguna usa --profile ni reset-profile sobre claw"

# (3) La regla vive como workshop skill en los agentes que corren o diagnostican el navegador,
# identica en los tres (sin deriva) y con sus anclas (los propios agentes editan sus skills).
SK=browser-cli-claw-profile
REF=agents/main/agent/workshop-skills/$SK/SKILL.md
for a in main operaciones ingenieria; do
  f=agents/$a/agent/workshop-skills/$SK/SKILL.md
  [ -f "$f" ] || fail "falta $f"
  cmp -s "$REF" "$f" || fail "$f difiere de $REF"
done
grep -qF 'openclaw browser --browser-profile claw tabs --json' "$REF" || fail "$REF: falta el comando correcto"
grep -qF 'requires credentials before opening a websocket' "$REF" || fail "$REF: falta la firma del error"
grep -qF 'NEVER run `reset-profile` on `claw`' "$REF" || fail "$REF: falta la prohibicion de reset-profile"
# Perdida del Edge 2026-09-11 7:33 PDT: operaciones y un sub-agente huerfano en la misma pestaña; y el
# CLI en Windows tarda 10-23 s en arrancar, asi que timeouts de 15-20 s lo matan antes de conectar.
grep -qF 'One session drives the claw browser at a time' "$REF" || fail "$REF: falta la regla de una sola sesion"
grep -qF 'timeoutSeconds >= 60' "$REF" || fail "$REF: falta el timeout minimo de 60 s"
echo "ok (3): skill $SK en main/operaciones/ingenieria, identica y con sus anclas"

# (4) Mecanismo, solo si hay CLI local. HOME temporal y sin red: falla antes de abrir el websocket.
# `--profile claw` debe desviar la config a ~/.openclaw-claw; `--browser-profile claw` no.
OC=${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}
if [ -x "$OC" ]; then
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  out=$(HOME="$T" "$OC" browser tabs --profile claw --json 2>&1)
  printf '%s' "$out" | grep -q '\.openclaw-claw/openclaw\.json' \
    || fail "--profile claw ya no desvia la config (cambio el CLI?): $out"
  out=$(HOME="$T" "$OC" browser --browser-profile claw tabs --json 2>&1)
  printf '%s' "$out" | grep -q '\.openclaw-claw' && fail "--browser-profile tambien desvia la config: $out"
  echo "ok (4): el CLI desvia la config a ~/.openclaw-claw solo con --profile"
else
  echo "skip (4): no hay CLI openclaw en $OC"
fi
echo "PASS test-browser-profile-flag"

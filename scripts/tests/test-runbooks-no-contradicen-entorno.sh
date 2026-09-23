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
         'primero `/opt/homebrew/bin/tmux list-sessions` y luego `/opt/homebrew/bin/tmux capture-pane -p -t x`' \
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
AUTO=$(git ls-files --cached --others --exclude-standard -- 'docs/runbooks/autopilot-fase6.md' 'docs/runbooks/autopilot-fase7.md' 'docs/runbooks/autopilot-fase9.md' 'docs/runbooks/loop-autopilot.md')
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
echo "ok (2b): cross-review y tmux de los autopilot y del loop con prefijo de PATH o ruta absoluta"

# (2b-bis) El comando que lanza a un implementador lleva ADENTRO su PATH y su flag de modo sin
# preguntas. Medido el 2026-09-17 (Fase 7): el comando terminaba en "$BIN" a secas. Desde el
# exec del gateway la sesion moria al arrancar (rc=0, `env: node: No such file or directory`), y
# una tabla aparte decia que flag agregar: los dos carriles se lanzaron sin flag y uno paso 7 h
# detenido en un prompt de permiso.
mal_lanzamiento() {
  grep -n -E -e 'new-session -d .*\$BIN' | grep -v -E 'PATH=/opt/homebrew/bin[^"]*\$BIN <flag>"'
}
for c in '  $T new-session -d -s <token>-wt-f7-P -c /Users/dn/dev/wt-f7-P "$BIN"' \
         '  $T new-session -d -s <token>-wt-f7-P -c /Users/dn/dev/wt-f7-P "$BIN" <flag>' \
         '  $T new-session -d -s x -c /d "PATH=/opt/homebrew/bin:/Users/dn/bin:\$PATH $BIN"'; do
  printf '%s\n' "$c" | mal_lanzamiento >/dev/null || fail "mal_lanzamiento NO marca: $c"
done
printf '%s\n' '  $T new-session -d -s x -c /d "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH $BIN <flag>"' \
  | mal_lanzamiento >/dev/null && fail "mal_lanzamiento marca el lanzamiento correcto"
hits2c=$(git ls-files -z --cached --others --exclude-standard -- 'docs/runbooks/*.md' | xargs -0 cat -- 2>/dev/null | mal_lanzamiento)
[ -z "$hits2c" ] || fail "un runbook lanza a un implementador sin PATH embebido o sin su flag dentro del comando:
$hits2c"
echo "ok (2b-bis): ningun runbook lanza a un implementador sin PATH embebido y flag dentro del comando"

# (2c) Ningun runbook de fase designa UN modelo como lead. El lead es un rol y el recibo
# persistente permite relevarlo sin perder una aprobacion valida del mismo head.
# Medido 2026-09-16: el runbook de la Fase 7 decia "lead: Claude" y no tenia ruta de relevo.
# La linea del lead aparece de dos formas, fila de tabla (`| **lead** |`) y vineta
# (`- **lead**:`), y la primera version de este detector solo miraba la fila: pasaba en
# verde justo el documento que lo motivo, que usa la vineta. Las dos se marcan.
MODELOS='claude|codex|kimi|grok|zcode|dsh|muse|cursor|glm|gpt|opus|sonnet|deepseek|qwen'
# Sin filtro de exencion: una linea que dice "Claude, de cualquier host del kit"
# nombra un modelo Y trae la frase exenta, y el filtro la borraba antes de buscar el
# modelo. La forma escrita como rol pasa sola, porque no nombra ninguno.
lead_designado() {
  grep -E '^([|-]) \*\*lead\*\*' \
    | grep -i -E "\b($MODELOS)\b"
}
FASES=$(git ls-files --cached --others --exclude-standard -- 'docs/runbooks/autopilot-fase*.md')
[ -n "$FASES" ] || fail "no encontre runbooks de fase"
hits3=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  out=$(lead_designado < "$f" | sed "s|^|$f:|")
  [ -n "$out" ] && hits3="$hits3
$out"
done <<EOF
$FASES
EOF
[ -z "$hits3" ] || fail "un runbook de fase designa un modelo como lead (el lead es un rol):$hits3"
# El detector discrimina: las dos formas con modelo se marcan, la forma con rol pasa.
printf '%s\n' '| **lead** | Claude, sesion en la Mac | manda |' | lead_designado | grep -q . \
  || fail "(2c) el detector NO marca la fila con modelo"
printf '%s\n' '- **lead**: tu (Claude, sesion en la Mac). Spike 7.0, briefs.' | lead_designado | grep -q . \
  || fail "(2c) el detector NO marca la vineta con modelo"
printf '%s\n' '- **lead**: Claude, de cualquier host del kit' | lead_designado | grep -q . \
  || fail "(2c) el detector NO marca un modelo cuando la linea trae la frase del rol"
printf '%s\n' '| **lead** | tu: un CLI en tmux, de cualquier host del kit | manda |' | lead_designado | grep -q . \
  && fail "(2c) el detector marca de mas: la fila escrita como rol"
echo "ok (2c): ningun runbook de fase designa un modelo como lead"

# (2d) Todo runbook NUEVO nace con seguimiento, clases y lanzamiento por
# corrida.sh. Medido 2026-09-18/19 (Fase 9): los runbooks viejos se escribieron
# antes de que corrida.sh existiera — sus corridas no se reescriben y quedan
# exentos POR NOMBRE, cada uno listado abajo. Cualquier autopilot-*.md que no
# este en esa lista es futuro y trae: (a) seccion "Seguimiento" CON CONTENIDO
# CONCRETO (quien manda; canal con mecanismo y sin marcas de indefinido;
# cadencia con numero+unidad en linea con marca de envio: palabras sueltas
# pasaban y son rojas desde la r2); (b) seccion literal "## Clases de comando"
# con al menos una fila VALIDA: clase del conjunto en celda propia (lo que el
# preflight lee) y ninguna mencion de herramienta fuera de esa celda — un
# comando real empieza por el ejecutable, una frase que lo trae en medio es
# mencion y la fila no cuenta (r2: la forma minima `| gh | leer PRs... |`
# pasa, `| gh | permiso para gh remoto |` no); (c) una llamada AFIRMATIVA a
# `corrida.sh lanzar-sesion` (con forma de orden y sin negacion que la
# preceda) y cero `new-session` escrito a mano. Heuristica documentada: el
# candado distingue formas, no intenciones; un falso rojo se arregla
# reescribiendo la linea. Una prohibicion ("nunca ...") cita la forma mala sin
# mandarla: no cuenta.
# Fase 16 se volvio historica tras la reinstalacion: no debe recuperar un
# lanzamiento afirmativo para satisfacer el contrato de los runbooks nuevos.
EXENTOS='autopilot-fase6.md autopilot-fase7.md autopilot-fase8.md autopilot-fase8-hallazgos.md autopilot-fase9.md autopilot-fase10.md autopilot-fase11.md autopilot-fase12.md autopilot-fase13.md autopilot-fase16.md autopilot-fase-saikit23.md'
exento() {
  case " $EXENTOS " in *" $1 "*) return 0;; esac
  return 1
}
tiene_seguimiento() { grep -q -E '^#{1,3} .*Seguimiento' "$1"; }
seccion_seguimiento() { # $1 archivo -> texto de la seccion (hasta el proximo ## o EOF)
  awk '/^#{1,3} .*Seguimiento/ {s=1; next} s && /^## / {exit} s {print}' "$1"
}
seguimiento_con_contenido() { # quien + canal concreto + cadencia en contexto de envio
  local sec plano; sec=$(seccion_seguimiento "$1")
  plano=$(printf '%s' "$sec" | tr '\n' ' ')
  printf '%s' "$plano" | grep -qiE 'lead|vig[ií]a|claw|hermes' || return 1
  printf '%s' "$plano" | grep -qiE 'David' || return 1
  printf '%s' "$plano" | grep -qiE 'cada cambio de estado' || return 1
  # canal: alguna linea con "canal" trae mecanismo y no dice que falta definir
  local cl; cl=$(printf '%s' "$sec" | grep -i 'canal' || true)
  [ -n "$cl" ] || return 1
  printf '%s' "$cl" \
    | grep -v -iE 'sin definir|sin resolver|sin concretar|no definid[oa]|por definir|por concretar|sigue pendiente|queda pendiente|pendiente de|falta definir|TBD|XXX' \
    | grep -qiE 'cron|telegram|gateway|rpc|chat' || return 1
  # cadencia: el contrato declara de forma inequívoca el máximo de 30 minutos.
  printf '%s' "$plano" \
    | grep -qiE '(al menos|como m[aá]ximo).*cada[[:space:]]+30[[:space:]]+minutos|cada[[:space:]]+30[[:space:]]+minutos.*(como m[aá]ximo)' || return 1
  return 0
}
fila_clase_valida() { # $1 archivo; 0 = hay fila con clase en celda propia y sin menciones
  awk '
    /^## Clases de comando[[:space:]]*$/ { dentro = 1; next }
    dentro && /^## / { exit }
    dentro { print }
  ' "$1" | awk -F'|' '
    function recorta(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return s }
    function es_clase(s) {
      s = tolower(recorta(s))
      return (s == "ssh" || s == "red externa" || s == "psql" || s == "gh")
    }
    function trae_mencion(s) { # comando real: la celda EMPIEZA por el ejecutable
      s = tolower(recorta(s))
      if (s ~ /^(gh|ssh|curl|wget|psql)([ \t]|$)/) return 0
      if (s ~ /(^|[^a-z])(gh|ssh|curl|wget|psql)([^a-z]|$)/) return 1
      if (index(s, "red externa") > 0) return 1
      return 0
    }
    {
      clase = 0
      for (i = 1; i <= NF; i++) if (es_clase($i)) clase = 1
      if (!clase) next
      for (i = 1; i <= NF; i++) if (!es_clase($i) && trae_mencion($i)) next
      ok = 1
    }
    END { exit ok ? 0 : 1 }
  '
}
tiene_clases() {
  grep -qF '## Clases de comando' "$1" || return 1
  fila_clase_valida "$1" || return 1
  return 0
}
clases_declaradas() { # $1 archivo -> una clase por línea
  awk '
    /^## Clases de comando[[:space:]]*$/ { dentro = 1; next }
    dentro && /^## / { exit }
    dentro { print }
  ' "$1" | awk -F'|' '
    function recorta(s) { gsub(/^[ \t`]+|[ \t`]+$/, "", s); return tolower(s) }
    {
      for (i = 1; i <= NF; i++) {
        celda = recorta($i)
        if (celda == "ssh" || celda == "red externa" || celda == "psql" || celda == "gh") print celda
      }
    }
  ' | sort -u
}
clases_usadas() { # $1 archivo -> clases citadas fuera de su tabla
  awk '
    /^## Clases de comando[[:space:]]*$/ { dentro = 1; next }
    dentro && /^## / { dentro = 0 }
    !dentro { print }
  ' "$1" | awk '
    {
      linea = tolower($0)
      gsub(/[^[:alnum:]_\.\/-]+/, " ", linea)
      n = split(linea, palabra, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        ejecutable = palabra[i]
        sub(/^.*\//, "", ejecutable)
        if (ejecutable == "gh" || ejecutable == "ssh" || ejecutable == "psql") print ejecutable
        if (ejecutable == "curl" || ejecutable == "wget") print "red externa"
        if (palabra[i] == "red" && palabra[i + 1] == "externa") print "red externa"
      }
    }
  ' | sort -u
}
clases_usadas_declaradas() { # $1 archivo; toda clase usada aparece en la tabla
  local declaradas clase
  declaradas=$(clases_declaradas "$1")
  while IFS= read -r clase; do
    [ -n "$clase" ] || continue
    printf '%s\n' "$declaradas" | grep -qFx -- "$clase" || return 1
  done <<EOF
$(clases_usadas "$1")
EOF
  return 0
}
sesion_a_mano() { # 0 = trae new-session mandado (rojo); prohibiciones no cuentan
  grep -n 'new-session' "$1" 2>/dev/null | grep -v -i -E 'nunca|jam[aá]s|never' | grep -q .
}
lanzamiento_afirmativo() { # $1 archivo; 0 = hay llamada afirmativa a lanzar-sesion
  local lineas; lineas=$(grep -nF 'corrida.sh lanzar-sesion' "$1" 2>/dev/null) || return 1
  # la negacion vale solo si precede a la llamada ("Lanza con X, nunca a mano" es afirmativa)
  local nums; nums=$(printf '%s\n' "$lineas" | sed 's/corrida\.sh lanzar-sesion.*//' \
    | grep -v -i -E 'nunca|jam[aá]s|never|tampoco|prohibido|evita|evitar|(^|[^a-zA-Z])no (llames|llamar|lances|lanzar|uses|usar|ejecutes|ejecutar|corras|correr)|(^|[^a-zA-Z])sin (llamar|lanzar|usar|ejecutar|correr)' \
    | cut -d: -f1 || true)
  [ -n "$nums" ] || return 1
  local n
  for n in $nums; do
    printf '%s\n' "$lineas" | grep -E "^$n:" \
      | grep -q -E '^[0-9]+:[[:space:]]*([`|>~-]|\$[[:space:]]+|[^[:space:]]*corrida\.sh lanzar-sesion)|(lanzan|lanza|lanzar|abren|abre|abrir|ejecutan|ejecuta|ejecutar|corren|corre|correr|usan|usa|usar)[[:space:]]+.*corrida\.sh lanzar-sesion' \
      && return 0
  done
  return 1
}
runbook_futuro_ok() { # $1 archivo; 0 = nace con todo
  tiene_seguimiento "$1" || return 1
  seguimiento_con_contenido "$1" || return 1
  tiene_clases "$1" || return 1
  clases_usadas_declaradas "$1" || return 1
  lanzamiento_afirmativo "$1" || return 1
  sesion_a_mano "$1" && return 1
  return 0
}
FXF=scripts/tests/fixtures/runbook-futuro
for fx in autopilot-bueno.md autopilot-malo-sin-seguimiento.md autopilot-malo-sin-clases.md autopilot-malo-clases-fuera-de-seccion.md autopilot-malo-clase-no-declarada.md autopilot-malo-new-session.md autopilot-malo-encabezados-vacios.md autopilot-malo-lanzar-negado.md autopilot-malo-seguimiento-vago.md autopilot-malo-seguimiento-sin-david.md autopilot-malo-seguimiento-sin-cambio.md autopilot-malo-seguimiento-lento.md; do
  [ -r "$FXF/$fx" ] || fail "(2d) no encuentro el fixture: $FXF/$fx"
  git check-ignore -q "$FXF/$fx" \
    && fail "(2d) $FXF/$fx esta en .gitignore: el commit no lo lleva y CI se queda sin el archivo"
done
runbook_futuro_ok "$FXF/autopilot-bueno.md" \
  || fail "(2d) el fixture bueno no pasa: un candado roto se pondria rojo con un runbook correcto"
runbook_futuro_ok "$FXF/autopilot-malo-sin-seguimiento.md" \
  && fail "(2d) el fixture sin Seguimiento paso: el candado no exige la seccion"
runbook_futuro_ok "$FXF/autopilot-malo-sin-clases.md" \
  && fail "(2d) el fixture sin Clases paso: el candado no exige una fila valida (clase sin frase-mencion)"
runbook_futuro_ok "$FXF/autopilot-malo-clases-fuera-de-seccion.md" \
  && fail "(2d) el fixture con una clase valida fuera de Clases paso: el candado lee mas alla de la seccion"
runbook_futuro_ok "$FXF/autopilot-malo-clase-no-declarada.md" \
  && fail "(2d) el fixture con ssh no declarado paso: el candado no compara clases usadas y declaradas"
runbook_futuro_ok "$FXF/autopilot-malo-new-session.md" \
  && fail "(2d) el fixture con new-session a mano paso: el candado deja abrir sesiones a mano"
runbook_futuro_ok "$FXF/autopilot-malo-encabezados-vacios.md" \
  && fail "(2d) el fixture con encabezados vacios paso: el candado no exige contenido"
runbook_futuro_ok "$FXF/autopilot-malo-lanzar-negado.md" \
  && fail "(2d) el fixture con lanzamiento negado paso: la llamada debe ser afirmativa"
runbook_futuro_ok "$FXF/autopilot-malo-seguimiento-vago.md" \
  && fail "(2d) el fixture con Seguimiento vago paso: palabras sueltas no declaran canal ni cadencia"
runbook_futuro_ok "$FXF/autopilot-malo-seguimiento-sin-david.md" \
  && fail "(2d) el fixture sin destinatario paso: el candado no exige que el seguimiento llegue a David"
runbook_futuro_ok "$FXF/autopilot-malo-seguimiento-sin-cambio.md" \
  && fail "(2d) el fixture sin cambio de estado paso: el candado no exige entrega en cada cambio"
runbook_futuro_ok "$FXF/autopilot-malo-seguimiento-lento.md" \
  && fail "(2d) el fixture con 60 minutos paso: el candado permite superar el maximo de 30 minutos"
# Los exentos existen (si uno se borra, su exencion sobra y se retira).
for e in $EXENTOS; do
  [ -f "docs/runbooks/$e" ] || fail "(2d) exento por nombre pero ausente: docs/runbooks/$e"
done
grep -Fq '**NO LANZAR ESTE RUNBOOK EN EL ESTADO REINSTALADO.**' docs/runbooks/autopilot-fase16.md \
  || fail '(2d) Fase 16 solo esta exenta mientras prohíba el lanzamiento viejo'
grep -Fq 'U1 debe definir un runbook nuevo revisado contra el host vivo' docs/runbooks/autopilot-fase16.md \
  || fail '(2d) Fase 16 exenta sin ruta de reemplazo revisada'
# Y ningun runbook futuro versionado sale en rojo.
NUEVOS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  b=${f##*/}
  exento "$b" && continue
  NUEVOS="$NUEVOS $b"
  runbook_futuro_ok "$f" || fail "(2d) $f: un runbook nuevo sin Seguimiento con contenido, sin fila de clases valida, sin lanzamiento afirmativo o con new-session a mano"
done <<EOF
$(git ls-files --cached --others --exclude-standard -- 'docs/runbooks/autopilot-*.md')
EOF
[ -z "$NUEVOS" ] && NUEVOS=" (ninguno todavia; los 11 exentos saltados, declarado)"
echo "ok (2d): runbooks futuros revisados:$NUEVOS; fixtures bueno/malo discriminan cada regla"
echo "TODO VERDE: runbooks sin contradicciones con el kit ni con el entorno"

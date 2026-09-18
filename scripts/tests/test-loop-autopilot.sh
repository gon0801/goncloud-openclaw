#!/bin/bash
# Candado de docs/runbooks/loop-autopilot.md, la parte invariante de todo runbook de fase.
# Nace del 2026-09-16: los runbooks de las fases 6 y 7 repetían el loop entero (40 y 36 KB),
# el de la 7 decía "lead: Claude" cuando el lead tiene que poder ser cualquier host del kit
# (con claw o kimi de lead, "sin estado del hook" en los seis merges), y las reglas que
# costaron la noche del 15 (bootstrap dentro del PR, catorce rondas cruzadas, pruebas que
# pasan sin el arreglo, CodeRabbit sin leer, recargas en ráfaga) no estaban escritas en
# ningún lugar único. Verifica: (1) el detector de "lead nombrado por modelo" discrimina;
# (2) el documento existe con sus 13 secciones; (3) cada regla tiene su ancla; (4) la fila
# del lead en la tabla de roles NO nombra ningún modelo; (5) toda sección de reglas cita
# su incidente con "Medido:". Cambiar una regla es cambiar su ancla en el mismo commit.
# Uso: bash scripts/tests/test-loop-autopilot.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

DOC=docs/runbooks/loop-autopilot.md
MODELOS='claude|codex|kimi|grok|zcode|dsh|muse|cursor|glm|gpt|opus|sonnet|deepseek|qwen'

# Detector: la fila del lead (la línea de la tabla de roles que empieza por "| **lead**")
# nombra un modelo. El resto del documento sí puede nombrarlos (la lista de hosts del kit,
# los implementadores, los revisores): la regla es que el ROL de lead no sea un modelo.
lead_nombra_modelo() { grep -E '^\| \*\*lead\*\*' | grep -i -E "\b($MODELOS)\b"; }

# (1) Discrimina: las formas malas se marcan...
for c in '| **lead** | tú (Claude, sesión en la Mac) | briefs y merges |' \
         '| **lead** | una sesión de kimi en tmux | todo |' \
         '| **lead** | Codex o Claude según cuota | audita |'; do
  printf '%s\n' "$c" | lead_nombra_modelo >/dev/null || fail "el detector NO marca: $c"
done
# ...y la forma correcta, y una mención de modelos fuera de la fila del lead, no.
for c in '| **lead** | un CLI en tmux, de cualquier host del kit | audita y mergea |' \
         '| **implementador** | muse, cursor, glm, u otro | escribe código |' \
         'Hosts que el kit conoce: `claude`, `codex`, `kimi`.'; do
  printf '%s\n' "$c" | lead_nombra_modelo >/dev/null && fail "el detector marca una forma correcta: $c"
done
echo "ok (1): el detector marca un lead nombrado por modelo y deja pasar el rol y las menciones ajenas"

# (2) El documento existe con sus 13 secciones, en orden.
[ -f "$DOC" ] || fail "falta $DOC"
prev=0
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
  ln=$(grep -n -E "^## $n\. " "$DOC" | head -1 | cut -d: -f1)
  [ -n "$ln" ] || fail "$DOC: falta la sección $n"
  [ "$ln" -gt "$prev" ] || fail "$DOC: la sección $n está fuera de orden"
  prev=$ln
done
echo "ok (2): las 13 secciones existen y van en orden"

# (3) Cada regla tiene su ancla. Cambiar la regla = cambiar el ancla en el mismo commit.
for a in 'LISTO <sha>' \
         'Enviar el progreso no lo hace alcanzable' \
         'sin reinicio la configuración nueva queda guardada y sin efecto' \
         'cierre-de-fase.sh <fase>' \
         'se gana con un comando' \
         'No es una compuerta de una sola pasada: es un bucle' \
         'El orden del cierre es' \
         'la del lead incluida' \
         'mktemp -d' \
         'No se limpia durante la corrida' \
         'El encargo viaja como archivo' \
         'sea el CLI que sea' \
         'ATORADO <razón en una línea>' \
         'muta él mismo' \
         'como draft' \
         'Un PR por carril, nunca por tarea' \
         'Tope: tres rondas por PR' \
         'excluyendo al modelo que implementó' \
         'ronda 2 la hace un modelo **distinto**' \
         'código 3' \
         'Tope de tres PRs abiertos' \
         'Los comentarios de CodeRabbit se leen' \
         'saikit-merge.sh' \
         'veredicto sellado' \
         'ya en `origin/<default>`' \
         'cada host que pueda ser lead' \
         'Ningún cambio de configuración del gateway lo hace claw' \
         'en tanda, no en ráfaga' \
         'America/New_York' \
         'runbook-progress.v1' \
         'git y en los PRs' \
         'otro host de la lista de preferencia' \
         'contra la DoD literal de cada fila' \
         'No repite' \
         'test-runbooks-no-contradicen-entorno.sh' \
         'Jamás `--no-verify`' \
         'rama del worktree en el que estás parado' \
         'se invoca por `bash`' \
         'hashea el token literal' \
         'ATORADO kit ausente en ' \
         '-Alcance last-commit' \
         'conjuntos cerrados' \
         'nunca lo escribe el lead' \
         'CodeRabbit no es un proveedor de modelo' \
         'El sync del gateway no es un cron'; do
  # `--` obligatorio: un ancla que empieza con `-` (como `-Alcance last-commit`)
  # la lee grep como bandera y sale "Invalid argument", no como ancla faltante.
  grep -qF -- "$a" "$DOC" || fail "$DOC: falta el ancla: $a"
done
echo "ok (3): las 36 anclas de reglas están"

# (4) La fila del lead no nombra ningún modelo. Es la regla central del documento.
hit=$(lead_nombra_modelo < "$DOC")
[ -z "$hit" ] || fail "$DOC: la fila del lead nombra un modelo (el lead es un rol): $hit"
grep -q -E '^\| \*\*lead\*\*' "$DOC" || fail "$DOC: no encuentro la fila del lead en la tabla de roles"
echo "ok (4): el lead es un rol, no un modelo"

# (5) Las secciones 1 a 12 citan su incidente. Sin "Medido:", la regla es una hipótesis.
# La 13 describe este mismo candado y no es una regla.
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ini=$(grep -n -E "^## $n\. " "$DOC" | head -1 | cut -d: -f1)
  fin=$(grep -n -E "^## $((n+1))\. " "$DOC" | head -1 | cut -d: -f1)
  [ -n "$fin" ] || fin=$(wc -l < "$DOC")
  sed -n "${ini},${fin}p" "$DOC" | grep -q '^Medido:' || fail "$DOC: la sección $n no cita su incidente (Medido:)"
done
echo "ok (5): cada sección de reglas cita el incidente que la originó"

# (6) La seccion 8 tiene que nombrar los DOS pasos de publicar una fase nueva, no uno.
# Medido el 2026-09-18: se aplico el cambio de configuracion, la lectura de vuelta dijo
# que la lista ya traia la fase, y desde la aplicacion seguia sin haber camino a ella
# porque el plugin lee esa lista al registrarse. Quedarse en el primer paso es
# exactamente el falso verde que costo el diagnostico, asi que el candado exige los dos
# en la misma seccion: sin el reinicio, este caso falla.
ini=$(grep -n -E '^## 8\. ' "$DOC" | head -1 | cut -d: -f1)
fin=$(grep -n -E '^## 9\. ' "$DOC" | head -1 | cut -d: -f1)
s8=$(sed -n "${ini},${fin}p" "$DOC")
printf '%s' "$s8" | grep -qF 'plugins.entries.tablero-runbook.config.fases' \
  || fail "$DOC: la sección 8 no nombra la lista de fases de la configuración, que es el primer paso"
printf '%s' "$s8" | grep -qF 'replacePaths' \
  || fail "$DOC: la sección 8 no dice que el arreglo se reemplaza, no se fusiona"
printf '%s' "$s8" | grep -q -i 'reiniciar el gateway' \
  || fail "$DOC: la sección 8 nombra el cambio de configuración pero NO el reinicio; sin él la lista nueva no tiene efecto y el dueño no llega a la fase"
printf '%s' "$s8" | grep -q -i 'excluye la que estás viendo' \
  || fail "$DOC: la sección 8 no dice dónde comprobar el enlace; la barra excluye la fase que se está viendo y comprobarlo ahí da un falso rojo"
echo "ok (6): la sección 8 exige los dos pasos de publicar una fase, y dónde comprobarlo"

echo "TODO VERDE: loop-autopilot"

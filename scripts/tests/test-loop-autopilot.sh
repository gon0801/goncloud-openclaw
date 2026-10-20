#!/bin/bash
# Candado de docs/runbooks/loop-autopilot.md, la parte invariante de todo runbook de fase.
# Nace del 2026-09-16: los runbooks de las fases 6 y 7 repetían el loop entero (40 y 36 KB),
# el de la 7 decía "lead: Claude" cuando el lead tiene que poder cambiar de host sin perder
# el recibo persistente del PR, y las reglas que
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
BASE=docs/runbooks/base-openclaw.md
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
         'arranque-de-fase.sh <fase>' \
         'El arranque se gana con su propio comando' \
         'se localiza con un comando, nunca con una ruta fija' \
         'Enviar el progreso no lo hace alcanzable' \
         'prueba que se escribio, no que algo lo este usando' \
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
         'la evidencia del verificador' \
         'no vuelve a correr la batería' \
         'como draft' \
         'antes de cualquier push o PR' \
         'revisa solo el delta' \
         'en el mismo PR' \
         'Un PR por carril, nunca por tarea' \
         'Solo un hallazgo bloqueante abre ronda' \
         'Tope 5+5 con relevo' \
         'cuenta como otra ronda' \
         'Un PR nunca se promueve con un bloqueante abierto' \
         'Un bloqueante nunca va a una fila del plan' \
         'Lo no bloqueante no abre ronda' \
         'excluyendo a los autores' \
         'Nunca revisa el modelo que implementó' \
         'Tope de tres PRs abiertos' \
         'Los comentarios de CodeRabbit se leen' \
         'en tanda, no en ráfaga' \
         'runbook-progress-events.v1' \
         'git y en los PRs' \
         'otro host de la lista de preferencia' \
         'la aceptación real de lo que la fase promete' \
         'No hay una revisión de código nueva al cierre' \
         'bloqueante adjudicado que siga abierto' \
         'no bloqueante no abre ronda ni impide el merge' \
         'cero bloqueantes adjudicados abiertos' \
         'residuales del paso 8' \
         'No repite' \
         'test-runbooks-no-contradicen-entorno.sh' \
         'Jamás `--no-verify`' \
         'politica-calidad.json' \
         'solo el coordinador' \
         'ai-review: descartar F' \
         'merge.py mergear <PR> --sha <head>' \
         'nunca lo escribe el lead' \
         'CodeRabbit no es un proveedor de modelo'; do
  # `--` obligatorio: un ancla que empieza con `-` (como `-Alcance last-commit`)
  # la lee grep como bandera y sale "Invalid argument", no como ancla faltante.
  grep -qF -- "$a" "$DOC" || fail "$DOC: falta el ancla: $a"
done
echo "ok (3): las anclas de reglas están"

# (3-r1) La ronda cierra en el PR: el primer bloque cercado de la seccion 4 es la
# gramatica de descarte y adjudicacion que la compuerta de merge lee. Nada de la
# cruzada vieja (ningun pwsh) vuelve a la seccion normativa.
r1cmd=$(awk '
  /^## 4\. / { in4=1 }
  in4 && /^## 5\. / { exit }
  in4 && /^```$/ { fence++; next }
  in4 && fence==1 { print }
' "$DOC")
printf '%s\n' "$r1cmd" | grep -qF 'ai-review: descartar F' \
  || fail "la seccion 4 no trae la gramatica de descarte del bot:
$r1cmd"
printf '%s\n' "$r1cmd" | grep -qF 'adjudicado F2' \
  || fail "la seccion 4 no trae la gramatica de adjudicacion con su head:
$r1cmd"
printf '%s\n' "$r1cmd" | grep -qiF 'pwsh' \
  && fail "la seccion 4 vuelve a traer el comando de la cruzada:
$r1cmd"
echo "ok (3-r1): la seccion 4 cierra la ronda con descarte y adjudicacion, sin cruzada"

# (3d) La regla 4 de base-openclaw.md justifica el veto de rebase con la historia
# que la revision y los checks fijan al head (sin esa justificacion el veto parece
# capricho). La cruzada y su -Base ya no existen: la justificacion sobrevive sin ellos.
grep -qF 'un rebase reescribe esa historia' "$BASE" \
  || fail "$BASE: la regla 4 ya no justifica el veto de rebase con la historia que fija el head"
echo "ok (3d): regla 4 de base-openclaw justificada con la historia del head"

# (3a) Entrega-sin-sello A retiro la autoridad ligada a una sesion. Estas formas
# reintroducirian el candado que detuvo Fase 9 aunque el resto de las anclas pase.
vieja=$(grep -nEi 'veredicto sellado|sin estado del hook|re-sell|para que el kit selle' "$DOC" "$BASE" || true)
[ -z "$vieja" ] || fail "reaparecio autoridad de sesion obsoleta: $vieja"
echo "ok (3a): autoridad de sesion ausente"

# (3b) La seccion 4 aplica la regla 4 de quality-kit: tope 5+5 con relevo guardado
# en politica-calidad.json, solo un bloqueante con reproduccion abre ronda, y nunca
# promover con un bloqueante abierto. Medido el 2026-09-18 tres veces: un tope de tres
# rondas llevo a la Fase 9 a promover el PR 81 con cuatro medias vivas; el criterio sin
# tope por altas y medias volvio la revision una cadena sin fin; y el tope de 2 dejaba
# dudas sobre que hacer con un bloqueante en la segunda ronda. El tope nuevo es decision
# del dueno del 2026-10-12 (5+5); los numeros viven en el JSON, no aqui.
s4_ini=$(grep -n -E '^## 4\. ' "$DOC" | head -1 | cut -d: -f1)
s4_fin=$(grep -n -E '^## 5\. ' "$DOC" | head -1 | cut -d: -f1)
[ -n "$s4_ini" ] && [ -n "$s4_fin" ] || fail "$DOC: no encuentro los limites de la seccion 4"
# Se mira solo lo que la seccion MANDA: las notas historicas ("Medido:" y la que fecha el
# tope viejo) nombran las reglas anteriores justamente para explicar por que cambiaron.
s4=$(sed -n "${s4_ini},${s4_fin}p" "$DOC" | grep -v '^Medido:' | grep -v 'estuvo escrito aqu')
printf '%s' "$s4" | grep -qF 'Solo un hallazgo bloqueante abre ronda' \
  || fail "$DOC: la seccion 4 no acota la ronda a un bloqueante"
printf '%s' "$s4" | grep -qF 'Tope 5+5 con relevo' \
  || fail "$DOC: la seccion 4 no trae el tope 5+5 con relevo"
printf '%s' "$s4" | grep -qF 'politica-calidad.json' \
  || fail "$DOC: la seccion 4 no apunta a la politica de calidad guardada como datos"
printf '%s' "$s4" | grep -qF 'Un PR nunca se promueve con un bloqueante abierto' \
  || fail "$DOC: la seccion 4 no prohibe promover con un bloqueante abierto"
viejo=$(printf '%s' "$s4" | grep -inE 'tope: *[0-9a-z]+ rondas|tope de [0-9a-z]+ rondas|no hay tope de rondas|ninguna alta ni media|altas ni medias' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 4 volvio a un tope fijo o al criterio de altas y medias: $viejo"
echo "ok (3b): la seccion 4 aplica el tope 5+5 de la politica y nunca promueve con un bloqueante abierto"

# (3c) Entrega-sin-sello C alinea las tres politicas que frenaban el relevo y el cierre.
# Medido 2026-09-20: el loop trataba cualquier comentario de CodeRabbit como revision no
# aprobada (catorce rondas por hallazgos bajos en el PR #48), mandaba una revision
# completa del codigo al cierre despues de que todos los carriles mergearon, y no nombraba
# los tres roles que el recibo exige. Cada regla se mira DENTRO de su seccion: nombrarla
# en otra seccion no la manda. Las formas viejas se marcan como negativas: si vuelven,
# el candado se pone rojo aunque las anclas nuevas sigan presentes.
seccion() { # $1 numero -> texto de esa seccion
  ini=$(grep -n -E "^## $1\. " "$DOC" | head -1 | cut -d: -f1)
  fin=$(grep -n -E "^## $(($1+1))\. " "$DOC" | head -1 | cut -d: -f1)
  [ -n "$fin" ] || fin=$(wc -l < "$DOC")
  sed -n "${ini},${fin}p" "$DOC"
}
s3=$(seccion 3)
printf '%s' "$s3" | grep -qF 'bloqueante adjudicado que siga abierto' \
  || fail "$DOC: el paso 7 no manda adjudicar CodeRabbit: solo un bloqueante abierto vuelve al loop"
printf '%s' "$s3" | grep -qF 'residuales del paso 8' \
  || fail "$DOC: el paso 7 no manda los comentarios no bloqueantes al cierre"
viejo=$(printf '%s' "$s3" | grep -inE 'no deja nada nuevo|Lo accionable se corrige' || true)
[ -z "$viejo" ] || fail "$DOC: el paso 7 volvio a exigir cero comentarios de CodeRabbit: $viejo"
s5=$(seccion 5)
printf '%s' "$s5" | grep -qF 'cero bloqueantes adjudicados abiertos' \
  || fail "$DOC: la seccion 5 no declara la compuerta de revision (cero bloqueantes adjudicados abiertos)"
viejo=$(printf '%s' "$s5" | grep -inE 'con comentarios accionables no es' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 5 volvio a tratar cualquier comentario como revision no aprobada: $viejo"
s6=$(seccion 6)
for regla in 'Revisión: el bot ai-review (DeepSeek) sobre el head, sin bloqueantes abiertos' 'CodeRabbit es opcional: si comenta, se lee y sus hilos Major/Critical se adjudican; si no comenta o está sin cuota, no frena ni se espera' 'cualquier agente Claw o CLI ejecuta `python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/merge.py mergear <PR> --sha <head> --repo <owner/repo>`' 'devuelve el faltan y no mergea' 'No se requiere orden adicional, recibo del lead ni tabla de preaprobaciones'; do
  printf '%s' "$s6" | grep -qF "$regla" || fail "$DOC: falta la regla de merge: $regla"
done
viejo=$(printf '%s' "$s6" | grep -F 'Con CI y CodeRabbit aprobados' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 6 volvio a exigir CodeRabbit aprobado: $viejo"
s7=$(seccion 7)
printf '%s' "$s7" | grep -qF 'sin permiso adicional ni ventana de cron' \
  || fail "$DOC: despliegue requiere permiso adicional"
s10=$(seccion 10)
printf '%s' "$s10" | grep -qF 'la aceptación real de lo que la fase promete' \
  || fail "$DOC: la seccion 10 no manda la aceptacion real de la promesa de la fase"
printf '%s' "$s10" | grep -qF 'No hay una revisión de código nueva al cierre' \
  || fail "$DOC: la seccion 10 no declara que el cierre no repite la revision de codigo"
# Lo que la seccion MANDA: la frase que prohibe la revision completa y la nota historica
# quedan fuera, porque las nombran justamente para prohibirlas o explicar por que.
s10_manda=$(printf '%s' "$s10" | grep -v 'No hay una revisión' | grep -v '^Medido:')
viejo=$(printf '%s' "$s10_manda" | grep -inE 'revisión completa|muta|mutar' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 10 volvio a mandar una revision completa de cierre: $viejo"
echo "ok (3c): revision ai-review por adjudicacion, CodeRabbit opcional, merge libre y cierre sin revision repetida"

for file in "$DOC" "$BASE" docs/runbooks/base-summonaikit.md; do
  grep -q 'CodeRabbit' "$file" || fail "$file: falta la mencion de CodeRabbit opcional"
  stale=$(grep -nEi 'sin cuota no bloquea|sin cuota no se espera|CodeRabbit sin cuota[^|]*\|[^|]*no bloquea|re-APPROVE|sha aprobado|Mergeado por David|No mergea ni despliega' "$file" || true)
  [ -z "$stale" ] || fail "$file: volvió un veto o una excepción obsoleta: $stale"
done
printf '%s' "$s3" | grep -qF 'El PR espera hasta tener su aprobación' \
  || fail "$DOC: CodeRabbit sin respuesta no puede habilitar el merge"
printf '%s' "$s6" | grep -qF 'Revisión: el bot ai-review (DeepSeek) sobre el head, sin bloqueantes abiertos' \
  || fail "$DOC: falta la revisión del bot ai-review (DeepSeek) antes del merge"
grep -qF 'los otros carriles continúan' "$BASE" \
  || fail "$BASE: la espera de CodeRabbit detiene otros carriles"
grep -qF 'los demás carriles continúan' docs/runbooks/base-summonaikit.md \
  || fail 'base-summonaikit: la espera de CodeRabbit detiene otros carriles'
grep -qF '6 Merge del PR' "$BASE" \
  || fail "$BASE: el indice vuelve a enviar al kit de merge"
grep -qF 'Completion: all three checks exit 0, the closure PR is `MERGED`' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure: abrir el PR volvió a ser el cierre'
grep -qF 'confirmed from the PR API' agents/main/agent/workshop-skills/post-merge-closure/SKILL.md \
  || fail 'post-merge-closure: falta confirmar el SHA integrado'
stale=$(grep -nE 'one PR open, nothing merged by you|owner.s to merge|Mergeado por David|Recibo de entrega.*APPROVE lead' \
  agents/main/agent/workshop-skills/post-merge-closure/SKILL.md "$BASE" docs/runbooks/base-summonaikit.md || true)
[ -z "$stale" ] || fail "volvió el veto de cierre o el recibo obligatorio: $stale"
echo "ok (3c-gate): CodeRabbit opcional para el PR, sin veto de rol ni recibo"

# (3e) La auditoria del lead precede al primer push y al primer PR; la correccion
# tras la revision se hace en local y se publica en el mismo PR. Si el orden se
# invierte, el candado queda rojo aunque las anclas nuevas sigan presentes.
s3_ini=$(grep -n -E '^## 3\. ' "$DOC" | head -1 | cut -d: -f1)
s3_fin=$(grep -n -E '^## 4\. ' "$DOC" | head -1 | cut -d: -f1)
rev_local=$(sed -n "${s3_ini},${s3_fin}p" "$DOC" | grep -n 'antes de cualquier push' | head -1 | cut -d: -f1)
push_pr=$(sed -n "${s3_ini},${s3_fin}p" "$DOC" | grep -n 'Primer push y PR' | head -1 | cut -d: -f1)
[ -n "$rev_local" ] && [ -n "$push_pr" ] \
  || fail "$DOC: el paso 3 no ordena auditoria y primer push"
[ "$rev_local" -lt "$push_pr" ] \
  || fail "$DOC: el primer push quedo antes de la auditoria del lead"
printf '%s' "$s3" | grep -qF 'permanece abierto' \
  || fail "$DOC: el paso 7 no manda mantener el PR abierto durante la correccion local"
echo "ok (3e): auditoria antes del primer push; correccion local al mismo PR"

# (3f) La cruzada de quality-kit y su maquinaria (APPROVE lead, -Excluir,
# -Desde) salieron del flujo (decision del dueno, 2026-10-12): los runbooks
# vivos no las nombran. Los runbooks de fases cerradas conservan la suya como
# historia fechada y quedan fuera de este barrido; el loop las conserva solo
# dentro de sus lineas Medido:, que cuentan por que salieron.
for file in docs/runbooks/*.md agents/*/agent/workshop-skills/*/SKILL.md; do
  case "$file" in *autopilot-fase*) continue ;; esac
  vieja=$(grep -v '^Medido:' "$file" | grep -in -E 'cross-review|-Excluir|-Desde|rondas? cruzada|APPROVE lead' || true)
  [ -z "$vieja" ] || fail "$file: volvio un mecanismo retirado (cruzada/-Excluir/-Desde/APPROVE lead): $vieja"
done
grep -qF 'La cruzada local de quality-kit salió del flujo' "$DOC" \
  || fail "$DOC: falta el Medido que fecha la salida de la cruzada"
echo "ok (3f): los runbooks vivos no nombran la cruzada ni su maquinaria; su salida queda fechada en Medido"

# (4) La fila del lead no nombra ningún modelo. Es la regla central del documento.
hit=$(lead_nombra_modelo < "$DOC")
[ -z "$hit" ] || fail "$DOC: la fila del lead nombra un modelo (el lead es un rol): $hit"
grep -q -E '^\| \*\*lead\*\*' "$DOC" || fail "$DOC: no encuentro la fila del lead en la tabla de roles"
echo "ok (4): el lead es un rol, no un modelo"

# (5) Las secciones 1 a 12 citan su incidente. Sin "Medido:", la regla es una hipótesis.
# La 6 retira la restricción de merge; la 13 describe este mismo candado.
for n in 1 2 3 4 5 7 8 9 10 11 12; do
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

# (7) Fase 9, 9.7: las secciones que mandan mensajes a David referencian el
# contrato que los sostiene. §1 (roles), §3 (loop por tarea), §8 (progreso y
# mensajes) y §12 (atores) nombran `seguimiento.v1`. El TIMEBOX con pausas se
# mudo del runbook de la Fase 7 (§3 lo define, §12 lo aplica).
for n in 1 3 8 12; do
  s=$(seccion "$n")
  printf '%s' "$s" | grep -qF 'seguimiento.v1' \
    || fail "$DOC: la sección $n no referencia seguimiento.v1"
done
s3=$(seccion 3)
printf '%s' "$s3" | grep -qF 'TIMEBOX con pausas' \
  || fail "$DOC: la sección 3 no define el TIMEBOX con pausas (mudado de Fase 7)"
printf '%s' "$s3" | grep -qF 'vuelve a 6 horas completas' \
  || fail "$DOC: la sección 3 no dice que el TIMEBOX vuelve a 6 horas completas al salir del dialogo"
printf '%s' "$s3" | grep -qF 'plantilla del encargo' \
  || fail "$DOC: la sección 3 no cita la plantilla del encargo de la skill autopilot-runbook"
printf '%s' "$s3" | grep -qF 'espejo de progreso' \
  || fail "$DOC: la sección 3 no nombra el espejo de progreso"
s12=$(seccion 12)
printf '%s' "$s12" | grep -qF 'TIMEBOX de 6 h' \
  || fail "$DOC: la sección 12 no aplica el TIMEBOX de 6 h"
echo "ok (7): §1, §3, §8 y §12 referencian seguimiento.v1; TIMEBOX con pausas en §3 y §12"

echo "TODO VERDE: loop-autopilot"

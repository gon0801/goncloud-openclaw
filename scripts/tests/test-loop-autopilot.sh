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
         'Un PR por carril, nunca por tarea' \
         'Solo un hallazgo bloqueante abre otra ronda' \
         'para en la primera que no traiga ninguno' \
         'Si el mismo bloqueante vuelve en dos rondas seguidas' \
         'Un PR nunca se promueve con un bloqueante abierto' \
         'Un bloqueante nunca va a una fila del plan' \
         'Lo no bloqueante no abre ronda' \
         '-Desde <sha que vio la ronda anterior>' \
         'excluyendo al modelo que implementó' \
         'Cada ronda cambia de revisor' \
         'código 3' \
         'Tope de tres PRs abiertos' \
         'Los comentarios de CodeRabbit se leen' \
         'en tanda, no en ráfaga' \
         'runbook-progress.v1' \
         'git y en los PRs' \
         'otro host de la lista de preferencia' \
         'la aceptación real de lo que la fase promete' \
         'No hay una revisión de código nueva al cierre' \
         'bloqueante adjudicado que siga abierto' \
         'no bloqueante no abre ronda ni impide el merge' \
         'cero bloqueantes adjudicados abiertos' \
         'residuales del recibo' \
         'No repite' \
         'test-runbooks-no-contradicen-entorno.sh' \
         'Jamás `--no-verify`' \
         '-Base <sha de la base del bloque>' \
         'conjunto cerrado' \
         'nunca lo escribe el lead' \
         'CodeRabbit no es un proveedor de modelo'; do
  # `--` obligatorio: un ancla que empieza con `-` (como `-Alcance last-commit`)
  # la lee grep como bandera y sale "Invalid argument", no como ancla faltante.
  grep -qF -- "$a" "$DOC" || fail "$DOC: falta el ancla: $a"
done
echo "ok (3): las anclas de reglas están"

# La ronda 1 pide el diff del bloque. -Desde, en cualquier sha, le dice al
# revisor que juzgue solo los arreglos; ese flag queda para las rondas siguientes.
r1cmd=$(awk '
  /^## 4\. / { in4=1 }
  in4 && /^## 5\. / { exit }
  in4 && /^```$/ { fence++; next }
  in4 && fence==1 { print }
' "$DOC")
printf '%s\n' "$r1cmd" | grep -qF -- '-Base <sha de la base del bloque>' \
  || fail "el comando de la ronda 1 no usa -Base:
$r1cmd"
printf '%s\n' "$r1cmd" | grep -qF -- '-Desde' \
  && fail "el comando de la ronda 1 no puede usar -Desde:
$r1cmd"
echo "ok (3-r1): la ronda 1 usa -Base y no -Desde"

# (3-r1b) El comando de ronda 1 que cita base-openclaw.md manda lo mismo que el §4
# del loop: -Base con el merge-base del bloque. Ni -Desde (eso es ronda de
# arreglos) ni -Alcance last-commit (la ronda 1 ve el diff completo del bloque).
# Es el ancla del residual del recibo de #126: el doc base y el loop no pueden
# volver a divergir sobre que diff ve la primera ronda.
r1base=$(awk '
  /La revisión cruzada/ { inr=1 }
  inr && /^```$/ { fence++; next }
  inr && fence==1 { print }
  inr && fence>=2 { exit }
' "$BASE")
[ -n "$r1base" ] || fail "$BASE: no encuentro el comando de la revisión cruzada"
printf '%s\n' "$r1base" | grep -qF -- '-Base <sha de la base del bloque>' \
  || fail "$BASE: el comando de la ronda 1 no usa -Base:
$r1base"
printf '%s\n' "$r1base" | grep -qF -- '-Desde' \
  && fail "$BASE: el comando de la ronda 1 no puede usar -Desde:
$r1base"
printf '%s\n' "$r1base" | grep -qF -- '-Alcance' \
  && fail "$BASE: el comando de la ronda 1 no puede usar -Alcance last-commit:
$r1base"
echo "ok (3-r1b): la ronda 1 de base-openclaw usa -Base y ni -Desde ni -Alcance"

# (3d) La regla 4 de base-openclaw.md justifica el veto de rebase con la historia
# que la ronda 1 lee con -Base (sin esa justificacion el veto parece capricho), y
# el doc deja dicho que los runbooks cerrados de fases 6 y 7 conservan su
# `-Alcance last-commit` como historia: el script aborta solo con un valor fuera
# del conjunto. Sin la nota, quien sigue un runbook viejo no sabe si rompe algo.
grep -qF '(`-Base`, loop §4) y un rebase reescribe esa historia' "$BASE" \
  || fail "$BASE: la regla 4 ya no justifica el veto de rebase con la historia que la ronda 1 lee con -Base"
grep -qF 'fases 6 y 7, ya cerradas, escriben `-Alcance last-commit`' "$BASE" \
  || fail "$BASE: falta declarar que los runbooks cerrados de fases 6 y 7 escriben -Alcance last-commit"
grep -qF 'aborta si el valor de `-Alcance` no está en ese conjunto' "$BASE" \
  || fail "$BASE: falta decir que el script aborta si el valor de -Alcance no está en el conjunto"
echo "ok (3d): regla 4 justificada con -Base e historia de fases 6 y 7 declarada"

# (3a) Entrega-sin-sello A retiro la autoridad ligada a una sesion. Estas formas
# reintroducirian el candado que detuvo Fase 9 aunque el resto de las anclas pase.
vieja=$(grep -nEi 'veredicto sellado|sin estado del hook|re-sell|para que el kit selle' "$DOC" "$BASE" || true)
[ -z "$vieja" ] || fail "reaparecio autoridad de sesion obsoleta: $vieja"
echo "ok (3a): autoridad de sesion ausente"

# (3b) La seccion 4 manda repetir mientras salgan bloqueantes, sin tope fijo, y nunca
# promover con un bloqueante abierto. Medido el 2026-09-18 tres veces: un tope de tres
# rondas llevo a la Fase 9 a promover el PR 81 con cuatro medias vivas; el criterio sin
# tope por altas y medias volvio la revision una cadena sin fin; y el tope de 2 dejaba
# dudas sobre que hacer con un bloqueante en la segunda ronda. Regla vigente
# (quality-kit #13): solo un bloqueante abre ronda, cada ronda ve solo los arreglos, se
# repite hasta la primera sin bloqueantes, y un bloqueante nunca va al plan ni se promueve.
s4_ini=$(grep -n -E '^## 4\. ' "$DOC" | head -1 | cut -d: -f1)
s4_fin=$(grep -n -E '^## 5\. ' "$DOC" | head -1 | cut -d: -f1)
[ -n "$s4_ini" ] && [ -n "$s4_fin" ] || fail "$DOC: no encuentro los limites de la seccion 4"
# Se mira solo lo que la seccion MANDA: las notas historicas ("Medido:" y la que fecha el
# tope viejo) nombran las reglas anteriores justamente para explicar por que cambiaron.
s4=$(sed -n "${s4_ini},${s4_fin}p" "$DOC" | grep -v '^Medido:' | grep -v 'estuvo escrito aqu')
printf '%s' "$s4" | grep -qF 'Se repite mientras una ronda traiga un bloqueante' \
  || fail "$DOC: la seccion 4 no manda repetir mientras salgan bloqueantes"
printf '%s' "$s4" | grep -qF 'Un PR nunca se promueve con un bloqueante abierto' \
  || fail "$DOC: la seccion 4 no prohibe promover con un bloqueante abierto"
viejo=$(printf '%s' "$s4" | grep -inE 'tope: *[0-9a-z]+ rondas|tope de [0-9a-z]+ rondas|no hay tope de rondas|ninguna alta ni media|altas ni medias' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 4 volvio a un tope fijo o al criterio de altas y medias: $viejo"
echo "ok (3b): la seccion 4 repite mientras salgan bloqueantes y nunca promueve con uno abierto"

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
printf '%s' "$s3" | grep -qF 'residuales del recibo' \
  || fail "$DOC: el paso 7 no manda los comentarios no bloqueantes a los residuales del recibo"
viejo=$(printf '%s' "$s3" | grep -inE 'no deja nada nuevo|Lo accionable se corrige' || true)
[ -z "$viejo" ] || fail "$DOC: el paso 7 volvio a exigir cero comentarios de CodeRabbit: $viejo"
s5=$(seccion 5)
printf '%s' "$s5" | grep -qF 'cero bloqueantes adjudicados abiertos' \
  || fail "$DOC: la seccion 5 no declara la compuerta de CodeRabbit (cero bloqueantes adjudicados abiertos)"
viejo=$(printf '%s' "$s5" | grep -inE 'con comentarios accionables no es' || true)
[ -z "$viejo" ] || fail "$DOC: la seccion 5 volvio a tratar cualquier comentario como revision no aprobada: $viejo"
s6=$(seccion 6)
for regla in 'Cualquier agente Claw o CLI puede ejecutar' 'gh pr merge <PR> --squash --match-head-commit <SHA>' 'CI y CodeRabbit estén aprobados' 'No se requiere orden adicional, recibo del lead ni el script del kit'; do
  printf '%s' "$s6" | grep -qF "$regla" || fail "$DOC: falta la regla de merge: $regla"
done
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
echo "ok (3c): CodeRabbit por adjudicacion, merge libre y cierre sin revision repetida"

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

# (7) Fase 9, 9.7: las secciones que hablan de corridas referencian la
# herramienta y el contrato que las sostienen. §1 (quien lanza y quien vigila),
# §3 (encargo e implementacion), §8 (progreso y mensajes), §9 (relevo del lead)
# y §12 (atores) nombran `corrida.sh` y `seguimiento.v1`: sin la referencia, el
# loop manda un mecanismo que ya vive en codigo con otro nombre. El TIMEBOX con
# pausas se mudo del runbook de la Fase 7 (§3 lo define, §12 lo aplica).
for n in 1 3 8 9 12; do
  s=$(seccion "$n")
  printf '%s' "$s" | grep -qF 'corrida.sh' \
    || fail "$DOC: la sección $n no referencia corrida.sh"
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
echo "ok (7): §1, §3, §8, §9 y §12 referencian corrida.sh y seguimiento.v1; TIMEBOX con pausas en §3 y §12"

echo "TODO VERDE: loop-autopilot"

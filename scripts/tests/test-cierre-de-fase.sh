#!/bin/bash
# Prueba de scripts/cierre-de-fase.sh, el candado que dice si una fase esta cerrada.
#
# Nace de un caso real: el 2026-09-17 claw reporto "la Fase 7 ya termino" con las ocho
# celdas del plan en cc:TODO, el plugin sin encender en el gateway, dos sesiones aun
# marcadas y un worktree abierto. Un merge es observable y por eso se cree; el cierre
# no lo era. Cada caso de aqui es una de esas cinco cosas, y cada uno se prueba por los
# DOS lados: la fase cerrada sale VERDE y la fase a medias sale ROJO nombrando que falta.
#
# Todo corre contra repos de juguete y un servidor tmux propio (-L). Nunca se toca el
# repo del usuario, su tmux, su gateway ni GitHub: `gh` y `openclaw` son stubs.
#
# Uso: bash scripts/tests/test-cierre-de-fase.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
# El hook de pre-commit exporta GIT_DIR, GIT_INDEX_FILE y compania. Heredarlas haria
# que los `git -C <repo de juguete>` de esta prueba operaran sobre el repo real, y el
# caso (3) pasaba en verde por eso: leia el Plans.md de verdad, no el de juguete.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX GIT_AUTHOR_DATE GIT_COMMITTER_DATE
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

S=scripts/cierre-de-fase.sh
[ -f "$S" ] || fail "falta $S"
/bin/bash -n "$S" || fail "$S no parsea con /bin/bash"
[ -x /opt/homebrew/bin/bash ] && { /opt/homebrew/bin/bash -n "$S" || fail "$S no parsea con el bash de homebrew"; }
echo "ok (1): el script parsea con bash 3.2 y con el de homebrew"

T=$(mktemp -d) || exit 1
L="cierre$$"
TM=$(command -v tmux || true); [ -z "$TM" ] && [ -x /opt/homebrew/bin/tmux ] && TM=/opt/homebrew/bin/tmux
trap '[ -n "${TM:-}" ] && "$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT

# Stubs: ni gh ni openclaw reales. Su salida se controla con archivos.
mkdir -p "$T/bin"
CFG="$T/config.json"; CI="$T/ci.txt"; TAB="$T/tablero.json"
CRONS="$T/crons.json"; SCRATCH="$T/scratch.json"
printf '{"plugins":{"entries":{"summa-gate":{}}}}' >"$CFG"
printf 'completed success' >"$CI"
printf '{"jobs":[]}' >"$CRONS"
printf '{}' >"$SCRATCH"
# El stub contesta segun el metodo: el comprobador pregunta por la configuracion y,
# aparte, por el tablero publicado. Un stub que contestara lo mismo a los dos haria
# pasar la comprobacion del tablero sin comprobar nada.
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "runbook.progress.get" ] && { cat "$TAB"; exit 0; }
done
case "\$*" in
  *cron\ scratch*) printf '%s\n' "SCRATCH \$*" >> "$T/scratch-calls.txt"; cat "$SCRATCH"; exit 0;;
  *cron\ list*) cat "$CRONS"; exit 0;;
esac
cat "$CFG"
STUB
cat >"$T/bin/gh" <<STUB
#!/bin/sh
cat "$CI"
STUB
chmod +x "$T/bin/openclaw" "$T/bin/gh"

# Repo de juguete: una fase 5 con dos filas y un plugin declarado en el encabezado.
R="$T/repo"; mkdir -p "$R"
git init -q "$R" && git -C "$R" config user.email t@t && git -C "$R" config user.name t
plan() { # $1 estado de las dos filas
  cat >"$R/Plans.md" <<PLAN
## Fase 5 — algo con plugin \`tablero-demo\` para ver cosas

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 5.0 | trabajo uno | su DoD | - | $1 |
| 5.1 | trabajo dos | su DoD | 5.0 | $1 |
PLAN
}
plan 'cc:完了'
# La fase de juguete publica tablero: sin documento versionado la comprobacion (7)
# sale VERDE por vacio y ninguno de sus casos ejercitaria nada.
mkdir -p "$R/.saikit/progress"
progreso() { # $1 estado del carril B
  cat >"$R/.saikit/progress/5.json" <<DOC
{"fase":"5","carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"$1"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}
DOC
}
tablero() { # $1 estado del carril B vivo, $2 cierre.at vivo (vacio = null)
  at=null; [ -n "${2:-}" ] && at="\"$2\""
  cat >"$TAB" <<DOC
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5",
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"$1"}],
 "cierre":{"at":$at}}}
DOC
}
progreso mergeado
tablero mergeado 2026-09-18T00:00:00Z
git -C "$R" add -A && git -C "$R" commit -q -m plan
git -C "$R" branch -f main HEAD 2>/dev/null
# Un "remoto" de verdad, para que ls-remote responda sin red.
REM="$T/remoto.git"; git init -q --bare "$REM"
git -C "$R" remote add origin "$REM" 2>/dev/null || git -C "$R" remote set-url origin "$REM"
git -C "$R" push -q origin HEAD:main

# Cinturon que SI puede fallar: el repo de juguete tiene que resolver a su propio .git.
# Si una variable de git sobreviviera al unset de arriba, cada `git -C "$R"` de esta
# prueba escribiria en el repo REAL. Medido el 2026-09-17, reproduciendo el fallo a
# mano: dejo 464 borrados en el indice del clon del usuario y le cambio la direccion
# del remoto a un temporal. Aqui se para antes de tocar nada.
# En macOS /var es un enlace a /private/var, asi que se comparan las dos rutas ya
# resueltas y no los textos.
real=$(cd "$R" && git rev-parse --absolute-git-dir 2>/dev/null)
esperado=$(cd "$R" && pwd -P)/.git
[ "$(cd "$(dirname "$real")" 2>/dev/null && pwd -P)/$(basename "$real")" = "$esperado" ] \
  || fail "los git de esta prueba no apuntan al repo de juguete sino a: $real"

corre() { REPO="$R" REF=origin/main TMUX_BIN="${TM:-/no/hay}" OPENCLAW_BIN="$T/bin/openclaw" GH_BIN="$T/bin/gh" bash "$S" "$@"; }

# (2) Todo cerrado: VERDE y salida 0. Sin este caso, un script que siempre dijera ROJO
# pasaria la prueba.
printf '{"plugins":{"entries":{"summa-gate":{},"tablero-demo":{}}}}' >"$CFG"
out=$(corre 5); rc=$?
[ "$rc" -eq 0 ] || fail "(2) una fase cerrada debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q "VERDE: la fase 5 puede declararse cerrada" || fail "(2) falta el veredicto VERDE:
$out"
printf '%s' "$out" | grep -q "ROJO" && fail "(2) no deberia haber ninguna linea ROJO:
$out"
echo "ok (2): una fase realmente cerrada sale VERDE y con codigo 0"

# (3) El caso de la Fase 7: filas sin cerrar con todo lo demas limpio.
plan 'cc:TODO'
git -C "$R" add -A && git -C "$R" commit -q -m abre && git -C "$R" push -q -f origin HEAD:main
out=$(corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(3) con filas abiertas debe salir 1; salio $rc"
printf '%s' "$out" | grep -q "^ROJO *plan" || fail "(3) el check del plan no salio ROJO:
$out"
printf '%s' "$out" | grep -q "5.0" && printf '%s' "$out" | grep -q "5.1" || fail "(3) el detalle debe nombrar las filas abiertas:
$out"
echo "ok (3): filas sin cerrar en el plan salen ROJO y se nombran"

# (4) El plugin construido y NO encendido: el caso de tablero-runbook.
plan 'cc:完了'; git -C "$R" add -A && git -C "$R" commit -q -m cierra && git -C "$R" push -q -f origin HEAD:main
printf '{"plugins":{"entries":{"summa-gate":{}}}}' >"$CFG"
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *despliegue" || fail "(4) un plugin declarado y ausente del gateway debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "tablero-demo" || fail "(4) el detalle debe nombrar el plugin:
$out"
# Y el otro lado: con el gateway apagado se declara unknown, no ROJO. No poder
# comprobar no es lo mismo que comprobar que esta mal.
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^unknown *despliegue" || fail "(4) sin gateway debe ser unknown, no ROJO:
$out"
printf '%s' "$out" | grep -q "^ROJO" && fail "(4) un unknown no puede hacer fallar el cierre:
$out"
echo "ok (4): plugin sin encender = ROJO; sin gateway = unknown y no bloquea"

# (5) Una rama de la fase viva en el remoto.
printf '{"plugins":{"entries":{"summa-gate":{},"tablero-demo":{}}}}' >"$CFG"
git -C "$R" push -q origin HEAD:refs/heads/fase5/carril
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *ramas" || fail "(5) una rama fase5/* viva debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "fase5/carril" || fail "(5) el detalle debe nombrar la rama:
$out"
git -C "$R" push -q origin --delete refs/heads/fase5/carril
corre 5 >/dev/null || fail "(5) al borrar la rama el cierre debe volver a VERDE"
echo "ok (5): una rama de la fase sin borrar sale ROJO y deja de salir al borrarla"

# (6) Un worktree de la fase abierto.
git -C "$R" worktree add -q "$T/wt-f5-P" -b fase5/otro HEAD 2>/dev/null
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *worktrees" || fail "(6) un worktree de la fase abierto debe salir ROJO:
$out"
git -C "$R" worktree remove "$T/wt-f5-P" && git -C "$R" branch -q -D fase5/otro
echo "ok (6): un worktree de la fase sin quitar sale ROJO"

# (7) Una sesion de la fase que sigue marcada: le manda avisos a claw que nadie atiende.
if [ -z "${TM:-}" ]; then
  echo "SKIP (7): sin tmux en esta maquina"
else
  "$TM" -L "$L" new-session -d -s f5-carril -x 80 -y 20 'cat' || fail "(7) no pude crear la sesion"
  SHIM="$T/tmux-shim"; printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" >"$SHIM"; chmod +x "$SHIM"
  con_shim() { REPO="$R" REF=origin/main TMUX_BIN="$SHIM" OPENCLAW_BIN="$T/bin/openclaw" GH_BIN="$T/bin/gh" bash "$S" "$@"; }
  # Sin marcar: no es asunto del cierre.
  out=$(con_shim 5)
  printf '%s' "$out" | grep -q "^ROJO *sesiones" && fail "(7) una sesion SIN marcar no debe salir ROJO:
$out"
  "$TM" -L "$L" set-environment -t f5-carril OPENCLAW_WATCH 1
  out=$(con_shim 5)
  printf '%s' "$out" | grep -q "^ROJO *sesiones" || fail "(7) una sesion marcada debe salir ROJO:
$out"
  printf '%s' "$out" | grep -q "f5-carril" || fail "(7) el detalle debe nombrar la sesion:
$out"
  "$TM" -L "$L" set-environment -t f5-carril -u OPENCLAW_WATCH
  con_shim 5 >/dev/null || fail "(7) al desmarcar, el cierre debe volver a VERDE"
  "$TM" -L "$L" kill-server 2>/dev/null
  echo "ok (7): una sesion de la fase marcada sale ROJO; desmarcada, verde"
fi

# (8) CI de la rama por defecto en rojo: una fase no cierra dejandola asi.
printf 'completed failure' >"$CI"
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *ci" || fail "(8) CI en rojo debe salir ROJO:
$out"
printf '' >"$CI"
out=$(corre 5)
printf '%s' "$out" | grep -q "^unknown *ci" || fail "(8) sin respuesta de CI debe ser unknown:
$out"
printf 'completed success' >"$CI"
echo "ok (8): CI en rojo bloquea el cierre; sin respuesta queda unknown"

# (9) --json: una linea por comprobacion, cada una JSON valido. Es lo que un agente lee.
plan 'cc:TODO'; git -C "$R" add -A && git -C "$R" commit -q -m abre2 && git -C "$R" push -q -f origin HEAD:main
out=$(corre 5 --json)
n=$(printf '%s\n' "$out" | grep -c '^{')   # grep -c sale 1 si no conto nada; la asercion de abajo es la que manda
[ "$n" -ge 5 ] || fail "(9) esperaba al menos 5 lineas JSON, hubo $n:
$out"
printf '%s\n' "$out" | python3 -c "
import sys, json
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    d=json.loads(l)
    assert set(d)=={'estado','check','detalle'}, d
    assert d['estado'] in ('VERDE','ROJO','unknown'), d
" || fail "(9) alguna linea no es JSON valido con las tres claves"
echo "ok (9): --json emite una linea valida por comprobacion"

# (10) Una fase que no existe en el plan no puede salir VERDE por vacio.
out=$(corre 99); rc=$?
[ "$rc" -eq 1 ] || fail "(10) una fase inexistente no puede salir 0"
printf '%s' "$out" | grep -q "no tiene ninguna fila de la fase 99" || fail "(10) debe decir que no hay filas:
$out"
echo "ok (10): una fase sin filas en el plan sale ROJO, no VERDE por vacio"

# (11) Los cuatro falsos verdes que encontro CodeRabbit sobre este mismo script. Los
# cuatro tienen la misma forma: una comprobacion que no se puede hacer devolvia VERDE
# en vez de unknown, o miraba el lugar equivocado.
plan 'cc:完了'; git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m v11; git -C "$R" push -q -f origin HEAD:main
printf '{"plugins":{"entries":{"summa-gate":{},"tablero-demo":{}}}}' >"$CFG"

# (a) variables de git heredadas: el script no puede terminar mirando otro repo.
OTRO="$T/otro"; git init -q "$OTRO"
out=$(GIT_DIR="$OTRO/.git" GIT_WORK_TREE="$OTRO" corre 5)
printf '%s' "$out" | grep -q "VERDE: la fase 5" \
  || fail "(11a) con GIT_DIR de otro repo el comprobador dejo de ver el suyo:
$out"

# (b) el remoto no contesta: es unknown, no VERDE.
MALO="$T/bin-malo"; mkdir -p "$MALO"
# El script llama `git -C <repo> ls-remote ...`, asi que el subcomando no es $1: se
# busca en todos los argumentos.
cat >"$MALO/git" <<'GITSTUB'
#!/bin/sh
for a in "$@"; do [ "$a" = "ls-remote" ] && exit 1; done
exec /usr/bin/git "$@"
GITSTUB
chmod +x "$MALO/git"
out=$(PATH="$MALO:$PATH" corre 5)
printf '%s' "$out" | grep -q "^unknown *ramas" \
  || fail "(11b) con el remoto caido y sin ramas locales, debe quedar unknown y no VERDE:
$out"
# Y con el remoto caido PERO una rama local de la fase viva: ROJO, no unknown. Saltarse
# la revision local cuando el remoto no contesta deja pasar trabajo suelto, porque un
# unknown no bloquea el cierre.
git -C "$R" branch fase5/local-con-remoto-caido >/dev/null 2>&1
out=$(PATH="$MALO:$PATH" corre 5)
printf '%s' "$out" | grep -q "^ROJO *ramas" \
  || fail "(11b-bis) con el remoto caido, una rama local de la fase debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "fase5/local-con-remoto-caido" || fail "(11b-bis) el detalle debe nombrarla"
git -C "$R" branch -D fase5/local-con-remoto-caido >/dev/null 2>&1

# (c) una rama LOCAL de la fase tambien cuenta.
git -C "$R" branch fase5/solo-local >/dev/null 2>&1
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *ramas" \
  || fail "(11c) una rama local de la fase sin borrar debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "fase5/solo-local" || fail "(11c) el detalle debe nombrarla"
git -C "$R" branch -D fase5/solo-local >/dev/null 2>&1

# (d) la consulta de CI que falla: unknown, no VERDE.
printf '#!/bin/sh\nprintf "completed success"\nexit 1\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"
out=$(corre 5)
printf '%s' "$out" | grep -q "^unknown *ci" \
  || fail "(11d) una consulta de CI que falla debe quedar unknown aunque haya escrito algo:
$out"
printf 'completed success' >"$CI"
printf '#!/bin/sh\ncat "%s"\n' "$CI" >"$T/bin/gh"; chmod +x "$T/bin/gh"

# (e) cc:TODO en otra columna no abre una fila cerrada.
cat >"$R/Plans.md" <<PLAN
## Fase 5 — algo con plugin \`tablero-demo\` para ver cosas

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 5.0 | arregla lo que quedo en cc:TODO la vez pasada | su DoD | - | cc:完了 |
| 5.1 | trabajo dos | su DoD | 5.0 | cc:完了 |
PLAN
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m v11e; git -C "$R" push -q -f origin HEAD:main
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *plan" \
  || fail "(11e) cc:TODO en el Contenido no abre una fila cuyo Status esta cerrado:
$out"
echo "ok (11): los cuatro falsos verdes de CodeRabbit mueren, y el Status se lee de su columna"

# (12) El tablero publicado. Medido el 2026-09-18: este comprobador dio VERDE con el
# tablero de la Fase 7 mostrando 75% y el cierre "implementando"; y dos dias antes, el
# de la Fase 6 sirviendo un fixture mientras el documento versionado estaba bien.
# Ninguna comprobacion miraba la copia publicada, que es lo unico que el dueno ve.
# El Plans.md que quedo del caso (11e) ya esta cerrado; se reusa.
progreso mergeado

# (12a) El fallo de la Fase 7: el tablero vivo muestra un carril sin terminar.
tablero implementando 2026-09-18T00:00:00Z
out=$(corre 5); rc=$?
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12a) un tablero publicado con un carril sin terminar debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "carriles sin terminar: B" \
  || fail "(12a) el detalle tiene que nombrar el carril, que es lo que hay que ir a ver:
$out"
[ "$rc" -eq 0 ] && fail "(12a) con el tablero en rojo la fase no puede salir con codigo 0:
$out"
echo "ok (12a): un tablero publicado a medias impide el cierre, y nombra el carril"

# (12b) El fallo de la Fase 6: el tablero vivo esta cerrado, pero dice otra cosa que el
# documento versionado. Sin comparar los dos, un fixture cerrado pasaria por bueno.
tablero atorado 2026-09-18T00:00:00Z
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12b) un tablero publicado que no coincide con lo versionado debe salir ROJO:
$out"
echo "ok (12b): un tablero publicado que contradice al documento versionado impide el cierre"

# (12c) Sin cierre.at el dueno abre la fase y la ve en curso, aunque los carriles
# esten todos mergeados.
tablero mergeado ""
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12c) un tablero publicado sin cierre.at debe salir ROJO:
$out"
echo "ok (12c): un tablero sin cierre declarado impide el cierre"

# (12d) Discrimina: cuando el tablero publicado coincide y esta cerrado, sale VERDE.
# Sin este caso, una comprobacion que siempre dijera ROJO pasaria los tres de arriba.
tablero mergeado 2026-09-18T00:00:00Z
out=$(corre 5); rc=$?
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  || fail "(12d) un tablero publicado, coincidente y cerrado tiene que salir VERDE:
$out"
[ "$rc" -eq 0 ] || fail "(12d) con todo en verde la fase debe salir 0; salio $rc:
$out"
echo "ok (12d): un tablero publicado, coincidente y cerrado sale VERDE"

# (12e) El gateway que no contesta es unknown, no VERDE por vacio: no poder mirar el
# tablero no es haberlo mirado. Es el mismo falso verde que CodeRabbit encontro en la
# consulta de ramas y en la de CI.
mv "$T/bin/openclaw" "$T/bin/openclaw.off"
printf '#!/bin/sh\nexit 1\n' >"$T/bin/openclaw"; chmod +x "$T/bin/openclaw"
out=$(corre 5)
printf '%s' "$out" | grep -q "^unknown *tablero" \
  || fail "(12e) sin respuesta del gateway el tablero es unknown, no VERDE:
$out"
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12e) un gateway caido no puede dar por bueno el tablero:
$out"
mv -f "$T/bin/openclaw.off" "$T/bin/openclaw"
echo "ok (12e): sin respuesta del gateway el tablero queda unknown"

# (12g) El falso verde que encontro CodeRabbit sobre esta misma comprobacion: un
# documento sin carriles se normalizaba a lista vacia, "ningun carril abierto" salia
# cierto por vacio, y con la misma fase y el mismo cierre.at los dos resumenes
# coincidian. VERDE sin haber mirado un solo carril.
cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12g) un tablero publicado SIN carriles no puede salir VERDE:
$out"
printf '%s' "$out" | grep -q "^unknown *tablero" \
  || fail "(12g) un tablero publicado sin carriles tiene que declararse unknown:
$out"
echo "ok (12g): un tablero sin carriles se declara, no se da por bueno"

# (12h) Lo mismo con un carril al que le falta el estado: la forma se valida antes de
# normalizarla, no despues.
cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","carriles":[{"id":"A"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12h) un carril sin estado no puede pasar por bueno:
$out"
printf '%s' "$out" | grep -q "sin id o sin estado" \
  || fail "(12h) el detalle tiene que decir que el carril viene incompleto:
$out"
echo "ok (12h): un carril sin id o sin estado se declara, no se normaliza a texto"

# (12g-bis) El falso verde EXACTO que encontro CodeRabbit, que (12g) no reproducia:
# los DOS lados sin carriles. Con el fixture de (12g) -- versionado con carriles, vivo
# sin ellos -- el script viejo ya salia ROJO por la comparacion, asi que ese caso no
# defendia la validacion de forma: un revert parcial que la dejara solo del lado vivo
# habria pasado la bateria. Hallazgo del revisor del lead, 2026-09-18.
cat >"$R/.saikit/progress/5.json" <<'DOC'
{"fase":"5","cierre":{"at":"2026-09-18T00:00:00Z"}}
DOC
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m sin-carriles-ambos
git -C "$R" push -q -f origin HEAD:main
cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12g-bis) con los dos lados sin carriles los resumenes coinciden por vacio: VERDE sin haber mirado un solo carril:
$out"
printf '%s' "$out" | grep -q "^unknown *tablero" \
  || fail "(12g-bis) los dos lados sin carriles tienen que declararse unknown:
$out"
echo "ok (12g-bis): los dos lados sin carriles no coinciden por vacio"
progreso mergeado
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m carriles-otra-vez
git -C "$R" push -q -f origin HEAD:main

# (12k) Lo que el dueno lee ARRIBA del tablero. El resumen comparaba fase, cierre.at y
# carriles, y nada mas: un tablero vivo con otro titulo y otra frase de siguiente paso
# pasaba por coincidente, y el dueno abria la fase "cerrada" y leia algo distinto de lo
# declarado. Hallazgo del revisor del lead, 2026-09-18. El banner de atencion tiene su
# propio candado en (12m), porque ahi ni siquiera basta con que los dos lados coincidan.
cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5",
 "titulo":"Autopilot de la Fase 5",
 "siguiente_paso":"Cierre pendiente, no lo mires todavia",
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12k) un tablero vivo con otro titulo y otra frase de siguiente paso no puede pasar por coincidente:
$out"
printf '%s' "$out" | grep -q "difiere en:.*titulo" \
  || fail "(12k) el detalle tiene que nombrar titulo, que es uno de los que divergen:
$out"
printf '%s' "$out" | grep -q "difiere en:.*siguiente_paso" \
  || fail "(12k) el detalle tiene que nombrar TODOS los que divergen, no solo el primero:
$out"
echo "ok (12k): un tablero con otro titulo y otro siguiente paso sale ROJO y los nombra a los dos"
tablero mergeado 2026-09-18T00:00:00Z

# (12l) Un campo cada uno, aislado. Medido por el revisor del lead en su segunda ronda:
# (12k) hacia divergir titulo, siguiente_paso y atencion a la vez y solo afirmaba sobre
# atencion, asi que quitar `titulo` o `siguiente_paso` del resumen dejaba la bateria
# entera en VERDE. Dos de los tres campos nuevos estaban indefensos. Un caso por campo.
for campo in titulo siguiente_paso; do
  if [ "$campo" = "titulo" ]; then
    cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","titulo":"Otro titulo distinto",
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
  else
    cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","siguiente_paso":"Todavia falta lo del cierre",
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
  fi
  out=$(corre 5)
  printf '%s' "$out" | grep -q "^ROJO *tablero" \
    || fail "(12l) el tablero vivo diverge solo en $campo y no salio ROJO; ese campo no esta defendido:
$out"
  printf '%s' "$out" | grep -q "difiere en:.*$campo" \
    || fail "(12l) el rechazo tiene que nombrar $campo, que es el unico que diverge:
$out"
done
echo "ok (12l): titulo y siguiente_paso estan defendidos cada uno por su cuenta"

# (12m) El banner de atencion encendido en LOS DOS lados. Coincidir no basta: el resumen
# cuadra y la comprobacion decia OK sobre un tablero que le pinta al dueno el aviso rojo
# arriba de todo. Y es el camino MAS probable, porque el lead escribe el documento, lo
# commitea y lo envia: los dos lados coinciden siempre. Hallazgo del revisor, 2da ronda.
cat >"$R/.saikit/progress/5.json" <<'DOC'
{"fase":"5","atencion_requerida":{"necesaria":true,"motivo":"algo que ver","desde":"2026-09-18T00:00:00Z"},
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}
DOC
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m atencion-los-dos
git -C "$R" push -q -f origin HEAD:main
cat >"$TAB" <<'DOC'
Gateway call: runbook.progress.get
{"ok":true,"doc":{"fase":"5","atencion_requerida":{"necesaria":true,"motivo":"algo que ver","desde":"2026-09-18T00:00:00Z"},
 "carriles":[{"id":"A","estado":"mergeado"},{"id":"B","estado":"mergeado"}],
 "cierre":{"at":"2026-09-18T00:00:00Z"}}}
DOC
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12m) los dos lados de acuerdo en que hace falta atencion no es una fase cerrada:
$out"
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12m) un tablero que pide atencion tiene que bloquear el cierre:
$out"
printf '%s' "$out" | grep -q "pide atencion" \
  || fail "(12m) el detalle tiene que decir que el tablero pide atencion:
$out"
echo "ok (12m): un tablero que pide atencion no cierra la fase, aunque lo versionado coincida"
progreso mergeado
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m sin-atencion
git -C "$R" push -q -f origin HEAD:main
tablero mergeado 2026-09-18T00:00:00Z

# (12n) La consulta al gateway que FALLA pero deja algo escrito. (12e) usa un stub que
# sale 1 sin escribir nada, asi que cubre las dos ramas a la vez y no defiende el arreglo:
# revertido, la bateria seguia en verde. Aqui el stub imprime un documento valido y sale 1.
mv "$T/bin/openclaw" "$T/bin/openclaw.ok"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "runbook.progress.get" ] && { cat "$TAB"; exit 1; }
done
cat "$CFG"
STUB
chmod +x "$T/bin/openclaw"
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12n) una consulta que fallo no puede darse por buena por lo que alcanzo a escribir:
$out"
printf '%s' "$out" | grep -q "^unknown *tablero" \
  || fail "(12n) una consulta que fallo tiene que declararse unknown:
$out"
mv -f "$T/bin/openclaw.ok" "$T/bin/openclaw"
echo "ok (12n): una consulta fallida se declara aunque haya escrito un documento valido"

# (12i) Los dos hallazgos del revisor del lead, 2026-09-18, sobre esta comprobacion.
#
# (12i-1) El nombre del documento. La Fase 6 real quedo versionada como `fase6.json` y
# la comprobacion solo miraba `<fase>.json`, asi que `cierre-de-fase.sh 6` imprimia
# "la fase 6 no publica tablero" -- VERDE por ausencia -- sobre una fase que publica y
# que el dueno tiene abierta en 7/7. Aqui el documento del repo de juguete se renombra
# a la forma vieja y la comprobacion tiene que seguir encontrandolo.
git -C "$R" mv .saikit/progress/5.json .saikit/progress/fase5.json
git -C "$R" commit -q -m nombre-viejo; git -C "$R" push -q -f origin HEAD:main
tablero mergeado 2026-09-18T00:00:00Z
out=$(corre 5)
printf '%s' "$out" | grep -q "no publica tablero" \
  && fail "(12i-1) un documento con el nombre viejo fase<N>.json se dio por ausente; asi la Fase 6 real salia VERDE sin comparar nada:
$out"
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  || fail "(12i-1) con el nombre viejo la comprobacion tiene que comparar igual:
$out"
echo "ok (12i-1): el documento se encuentra con cualquiera de los dos nombres"

# (12i-2) Discrimina de verdad: con el nombre viejo tambien tiene que salir ROJO cuando
# el tablero vivo no coincide. Sin este caso, (12i-1) pasaria con una comprobacion que
# dijera VERDE siempre que encuentre el archivo.
tablero atorado 2026-09-18T00:00:00Z
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *tablero" \
  || fail "(12i-2) con el nombre viejo la comparacion tiene que seguir siendo real:
$out"
echo "ok (12i-2): con el nombre viejo la comparacion sigue discriminando"
git -C "$R" mv .saikit/progress/fase5.json .saikit/progress/5.json
git -C "$R" commit -q -m nombre-canonico; git -C "$R" push -q -f origin HEAD:main
tablero mergeado 2026-09-18T00:00:00Z

# (12j) Una rama por defecto que no resuelve hacia fallar `show` igual que si el archivo
# no existiera, asi que un git roto quedaba indistinguible de una fase sin tablero: VERDE
# por ausencia. Es el mismo falso verde que CodeRabbit ya encontro en la consulta de
# ramas y en la de CI, otra vez.
out=$(REPO="$R" REF=origin/no-existe TMUX_BIN="${TM:-/no/hay}" OPENCLAW_BIN="$T/bin/openclaw" GH_BIN="$T/bin/gh" bash "$S" 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  && fail "(12j) con una rama por defecto que no resuelve, el tablero no puede salir VERDE:
$out"
printf '%s' "$out" | grep -q "^unknown *tablero" \
  || fail "(12j) una rama que no resuelve tiene que declararse unknown, no darse por buena:
$out"
echo "ok (12j): una rama por defecto ilegible se declara, no pasa por fase sin tablero"

# (12f) Una fase que no publica tablero no se bloquea por eso.
git -C "$R" rm -q .saikit/progress/5.json 2>/dev/null || true
git -C "$R" rm -q .saikit/progress/fase5.json 2>/dev/null || true
git -C "$R" commit -q -m sin-tablero; git -C "$R" push -q -f origin HEAD:main
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  || fail "(12f) una fase sin documento de progreso versionado no debe bloquearse:
$out"
echo "ok (12): el tablero publicado se compara con el versionado, y los dos falsos verdes de las Fases 6 y 7 mueren"

# (13) Reloj global y vigias legados: un corrida-vigia-5 restante es un resto sin
# migrar; avance-tareas se retira solo cuando no queda otro trabajo activo. El
# scratch se lee por UUID, nunca por nombre.
reloj_crons() { printf '%s\n' "$1" >"$CRONS"; }
reloj_scratch() { printf '%s\n' "$1" >"$SCRATCH"; : >"$T/scratch-calls.txt"; }
reloj_uuid1='{"name":"avance-tareas","id":"uuid-1","declarationKey":"avance-tareas","enabled":true,"schedule":{"kind":"every","everyMs":900000}}'
reloj_reloj() { # $1 trabajosActivos json
  reloj_scratch "{\"schema\":\"seguimiento-clock.v1\",\"corte\":{\"kind\":\"reporte-confirmado\",\"ultimoReporteConfirmado\":1000},\"ultimoEstado\":\"{}\",\"messageId\":null,\"trabajosActivos\":$1}"
}

# (13a) Un vigia legado restante bloquea el cierre y se nombra.
reloj_crons '{"jobs":[{"name":"corrida-vigia-5","enabled":true}]}'
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *reloj" \
  || fail "(13a) un corrida-vigia-5 restante debe salir ROJO:
$out"
printf '%s' "$out" | grep -q 'corrida-vigia-5' \
  || fail "(13a) el detalle debe nombrar el vigia legado:
$out"
echo "ok (13a): un vigia legado sin migrar bloquea el cierre"

# (13b) Reloj presente y rancio (solo esta fase): ROJO.
reloj_crons "{\"jobs\":[$reloj_uuid1]}"
reloj_reloj '["fase:5"]'
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *reloj" \
  || fail "(13b) el reloj rancio debe salir ROJO:
$out"
grep -q 'cron scratch uuid-1' "$T/scratch-calls.txt" \
  || fail "(13b) el scratch debio leerse por UUID: $(cat "$T/scratch-calls.txt" 2>/dev/null)"
grep -q 'cron scratch avance-tareas' "$T/scratch-calls.txt" \
  && fail "(13b) el scratch se pidio por nombre, no por UUID"
echo "ok (13b): el reloj rancio bloquea y el scratch se lee por UUID"

# (13c) Reloj compartido con otro trabajo: VERDE, se conserva.
reloj_reloj '["fase:5","corrida:otra"]'
out=$(corre 5); rc=$?
printf '%s' "$out" | grep -q "^VERDE *reloj" \
  || fail "(13c) el reloj compartido debe salir VERDE:
$out"
[ "$rc" -eq 0 ] || fail "(13c) con el reloj compartido el cierre debe salir 0; salio $rc:
$out"
echo "ok (13c): el reloj con otro trabajo activo se conserva"

# (13d) Scratch ilegible: fallo indeterminado, no verde.
reloj_scratch '{esto no es un scratch'
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *reloj" \
  || fail "(13d) el scratch ilegible debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "^VERDE *reloj" \
  && fail "(13d) el scratch ilegible no puede salir VERDE:
$out"
echo "ok (13d): el scratch ilegible bloquea el cierre"

# (13e) Reloj duplicado por declarationKey: fallo, no se adivina cual.
reloj_crons "{\"jobs\":[$reloj_uuid1,{\"name\":\"avance-otro\",\"id\":\"uuid-2\",\"declarationKey\":\"avance-tareas\",\"enabled\":true}]}"
out=$(corre 5)
printf '%s' "$out" | grep -q "^ROJO *reloj" \
  || fail "(13e) el reloj duplicado debe salir ROJO:
$out"
echo "ok (13e): el reloj duplicado bloquea el cierre"

# (13f) Sin reloj y sin legados: VERDE, nada que retirar.
reloj_crons '{"jobs":[]}'
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *reloj" \
  || fail "(13f) sin reloj debe salir VERDE:
$out"
echo "ok (13f): sin reloj no hay nada que retirar"

# (14) Entregables de la fase: la instalacion y el simulacro son carriles sin PR. Un
# remoto con todos los PR en MERGED no los prueba: medido 2026-09-17 (Fase 7), todo
# mergeado y CI en verde faltaban el plugin encendido y las celdas; y en la Fase 9 el
# simulacro era justamente el entregable que quedaba. El documento de progreso
# versionado declara los carriles: para cerrar la fase, cada uno tiene que estar en
# estado terminal, aunque los PR digan MERGED. Aqui A y B (los PR 97 y 98 de la Fase 9)
# estan mergeado y el plan cerrado: lo unico que falta es el entregable.
mkdir -p "$R/.saikit/progress"
entregables() { # $1 estado de Instalacion, $2 estado de Simulacro, $3 cierre.at (o null)
  cat >"$R/.saikit/progress/5.json" <<DOC
{"fase":"5","titulo":"Fase 5","siguiente_paso":"cierre",
 "carriles":[{"id":"A","estado":"mergeado","pr":97},{"id":"B","estado":"mergeado","pr":98},
             {"id":"I","nombre":"Instalacion","estado":"$1"},
             {"id":"S","nombre":"Simulacro","estado":"$2"}],
 "cierre":{"at":$3}}
DOC
  git -C "$R" add -A >/dev/null 2>&1
  git -C "$R" commit -q -m "entregables-$1-$2" 2>/dev/null
  git -C "$R" push -q -f origin HEAD:main
}

entregables pendiente pendiente null
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(14) con Instalacion y Simulacro pendientes y todos los PR mergeados, el cierre debe salir 1; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *entregables" \
  || fail "(14) el check de entregables no salio ROJO con un entregable pendiente:
$out"
printf '%s' "$out" | grep -q "Instalacion" \
  || fail "(14) el detalle debe nombrar el carril Instalacion:
$out"
printf '%s' "$out" | grep -q "Simulacro" \
  || fail "(14) el detalle debe nombrar el carril Simulacro:
$out"
echo "ok (14a): con todos los PR mergeados, un entregable pendiente impide el cierre y se nombra"

# (14b) El otro lado: con el entregable presente y el resto igual, VERDE. Sin este
# caso, una comprobacion que siempre dijera ROJO pasaria la de arriba.
entregables mergeado mergeado '"2026-09-18T00:00:00Z"'
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 0 ] || fail "(14b) con los entregables terminados el cierre debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q "^VERDE *entregables" \
  || fail "(14b) el check de entregables debe salir VERDE con todos terminados:
$out"
echo "ok (14b): con el entregable presente y el resto verde, la fase cierra"

# (14c) Un documento sin carriles legibles se declara unknown: no hay que dar por
# cerrada una fase cuyos entregables no se pudieron leer. Es el mismo falso verde que
# (12g) mato en el tablero publicado, aqui sobre el documento versionado.
printf '{"fase":"5","cierre":{"at":null}}' >"$R/.saikit/progress/5.json"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m entregables-sin-carriles
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^unknown *entregables" \
  || fail "(14c) un documento sin carriles debe declararse unknown, no VERDE:
$out"
printf '%s' "$out" | grep -q "^VERDE *entregables" \
  && fail "(14c) sin poder leer los entregables no puede salir VERDE:
$out"
echo "ok (14c): un documento de progreso sin carriles se declara, no se da por bueno"

# (14d) Un entregable ATORADO no esta terminado. Medido el 2026-09-22: el check
# contaba atorado como terminal, y una instalacion que revienta (pg_isready
# caido, copia parcial) producia cierre VERDE con el entregable a medias. Un
# carril atorado es un entregable pendiente con nombre y motivo: ROJO.
entregables atorado mergeado null
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(14d) con la instalacion atorada el cierre debe salir 1; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *entregables" \
  || fail "(14d) un entregable atorado debe salir ROJO, no contarse como terminado:
$out"
printf '%s' "$out" | grep -q "Instalacion" \
  || fail "(14d) el detalle debe nombrar el carril Instalacion:
$out"
echo "ok (14d): un entregable atorado es un entregable pendiente, no terminado"

# (14e) El documento tiene que ser EL de la fase: un progreso de OTRA fase con
# todos los carriles terminales no acredita los entregables de esta (CodeRabbit
# 2026-09-22: el check no miraba d.fase y otra fase cerrada daba VERDE aqui).
cat >"$R/.saikit/progress/5.json" <<'DOC'
{"fase":"6","titulo":"Otra fase","siguiente_paso":"x",
 "carriles":[{"id":"A","estado":"mergeado"}],
 "cierre":{"at":null}}
DOC
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m entregables-otra-fase
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(14e) un documento de otra fase no puede cerrar la fase 5; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *entregables" \
  || fail "(14e) el check de entregables debe salir ROJO con un documento de otra fase:
$out"
printf '%s' "$out" | grep -q "no corresponde a la fase" \
  || fail "(14e) el detalle debe nombrar el desajuste de fase:
$out"
echo "ok (14e): un documento de otra fase no acredita entregables ajenos"

# (14f) El conjunto terminal, estado por estado. Medido el 2026-09-22 (revision
# del bloque C): instalacion y simulacro atorados bloquean cada uno por su
# cuenta; omitido pasa SOLO porque la omision formal existe en el contrato
# runbook-progress.v1 (carril cancelado con detenido_por, regla 3) y un estado
# desconocido jamas produce VERDE.
atorado_de() { # $1 id, $2 nombre -> ROJO nombrando ese carril
  cat >"$R/.saikit/progress/5.json" <<DOC
{"fase":"5","titulo":"Fase 5","siguiente_paso":"cierre",
 "carriles":[{"id":"A","estado":"mergeado","pr":97},{"id":"B","estado":"mergeado","pr":98},
             {"id":"$1","nombre":"$2","estado":"atorado","detenido_por":"pg_isready caido"}],
 "cierre":{"at":null}}
DOC
  git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m "entregables-atorado-$1" 2>/dev/null
  git -C "$R" push -q -f origin HEAD:main
  local out; out=$(CIERRE_SIN_GATEWAY=1 corre 5); local rc=$?
  [ "$rc" -eq 1 ] || fail "(14f) con $2 atorado el cierre debe salir 1; salio $rc:
$out"
  printf '%s' "$out" | grep -q "^ROJO *entregables" \
    || fail "(14f) un entregable atorado ($2) debe salir ROJO:
$out"
  printf '%s' "$out" | grep -q "$2" \
    || fail "(14f) el detalle debe nombrar $2:
$out"
}
atorado_de I Instalacion
atorado_de S Simulacro
echo "ok (14f): instalacion y simulacro atorados bloquean el cierre, cada uno nombrado"

entregables omitido mergeado '"2026-09-18T00:00:00Z"'
# La omision formal existe en el contrato (runbook-progress.v1, regla 3: carril
# cancelado pasa a omitido con detenido_por): pasa, y lo declara.
sed -i.bak 's/"estado":"omitido"/"estado":"omitido","detenido_por":"cancelado por el operador"/' "$R/.saikit/progress/5.json" && rm -f "$R/.saikit/progress/5.json.bak"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m entregables-omitido-formal
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 0 ] || fail "(14g) con la omision formal del contrato el cierre debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q "^VERDE *entregables" \
  || fail "(14g) omitido formal debe contar como terminal:
$out"
echo "ok (14g): omitido pasa porque el contrato permite la omision formal"

cat >"$R/.saikit/progress/5.json" <<'DOC'
{"fase":"5","titulo":"Fase 5","siguiente_paso":"cierre",
 "carriles":[{"id":"A","estado":"mergeado","pr":97},{"id":"B","estado":"mergeado","pr":98},
             {"id":"I","nombre":"Instalacion","estado":"desconocido"}],
 "cierre":{"at":null}}
DOC
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m entregables-estado-desconocido
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(14h) un estado desconocido no puede cerrar la fase; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *entregables" \
  || fail "(14h) un estado desconocido debe salir ROJO, nunca VERDE:
$out"
echo "ok (14h): un estado desconocido jamas produce VERDE"

# (14i) Documento versionado PERO ilegible: es unknown, jamas el VERDE de "sin
# documento". Reproducido por el revisor del bloque C: con un doc de 0 bytes el
# cierre salia VERDE tratandolo como fase sin tablero.
: >"$R/.saikit/progress/5.json"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m entregables-doc-vacio
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^unknown *entregables" \
  || fail "(14i) un documento versionado ilegible debe declararse unknown:
$out"
printf '%s' "$out" | grep -q "^VERDE *entregables" \
  && fail "(14i) no pude leer los entregables no puede salir VERDE:
$out"
echo "ok (14i): documento presente pero ilegible es unknown, no verde por vacio"

# (15) usuario: por cada fila de la fase que declara una promesa observable (la
# linea literal "Promesa: <...> — ruta: <...>." dentro de su celda de Contenido,
# slot 16 de la skill autopilot-runbook), tiene que existir su linea FUNCIONA en
# docs/evidence/usuario-<fase>-*.md. Medido 2026-09-17: la Fase 7 shippeo un
# tablero que nadie abrio nunca -- este check es lo que impide cerrar una fase
# sobre una promesa que nadie fue a comprobar.
plan_promesa() { # $1 promesa (con marcador) de 5.0, $2 promesa (con marcador o vacio) de 5.1
  cat >"$R/Plans.md" <<PLAN
## Fase 5 — algo con plugin \`tablero-demo\` para ver cosas

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 5.0 | trabajo uno. $1 | su DoD | - | cc:完了 |
| 5.1 | trabajo dos. $2 | su DoD | 5.0 | cc:完了 |
PLAN
  git -C "$R" add -A >/dev/null 2>&1
  git -C "$R" commit -q -m plan-promesa 2>/dev/null
  git -C "$R" push -q -f origin HEAD:main
}
sin_evidencia_usuario() { rm -rf "$R/docs/evidence"; }

# (15a) Promesa cumplida con su evidencia FUNCIONA: VERDE.
plan_promesa 'Promesa: la pantalla de estado muestra "7 de 7" — ruta: abre http://x/tablero/5.' ''
mkdir -p "$R/docs/evidence"
cat >"$R/docs/evidence/usuario-5-2026-09-24.md" <<'EOF'
## 5.0
Promesa: la pantalla de estado muestra "7 de 7"
Ruta: abrí http://x/tablero/5
FUNCIONA la pantalla mostró "7 de 7" a las 10:32
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m evidencia-15a 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^VERDE *usuario" \
  || fail "(15a) una promesa cumplida con su FUNCIONA debe salir VERDE:
$out"
echo "ok (15a): promesa con evidencia FUNCIONA sale VERDE"

# (15b) Promesa declarada y SIN evidencia: ROJO nombrando la fila.
sin_evidencia_usuario
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m sin-evidencia-15b 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(15b) una promesa sin evidencia debe salir 1; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *usuario" \
  || fail "(15b) una promesa declarada sin evidencia debe salir ROJO:
$out"
printf '%s' "$out" | grep -q "5.0" \
  || fail "(15b) el detalle debe nombrar la fila 5.0:
$out"
echo "ok (15b): promesa sin evidencia sale ROJO y nombra la fila"

# (15c) Promesa declarada con evidencia que dice NO FUNCIONA: ROJO. Este es el caso
# que mata la mutacion "aceptar el archivo sin mirar su contenido": si el check solo
# comprobara que el archivo existe, este caso pasaria en VERDE.
mkdir -p "$R/docs/evidence"
cat >"$R/docs/evidence/usuario-5-2026-09-24.md" <<'EOF'
## 5.0
Promesa: la pantalla de estado muestra "7 de 7"
Ruta: abrí http://x/tablero/5
NO FUNCIONA la pantalla se quedó en blanco después de 20 segundos
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m evidencia-15c 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(15c) una evidencia NO FUNCIONA debe salir 1; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *usuario" \
  || fail "(15c) una evidencia que dice NO FUNCIONA debe salir ROJO, no darse por buena por existir el archivo:
$out"
echo "ok (15c): una evidencia NO FUNCIONA sale ROJO -- el check mira el contenido, no solo si el archivo existe"

# (15d) Ninguna fila declara promesa observable: VERDE con el detalle que lo dice.
plan_promesa '' ''
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^VERDE *usuario" \
  || fail "(15d) sin ninguna promesa declarada el check debe salir VERDE:
$out"
printf '%s' "$out" | grep -q "ninguna fila de la fase 5 declara promesa observable" \
  || fail "(15d) el detalle debe decir explicitamente que ninguna fila declara promesa:
$out"
echo "ok (15d): sin ninguna promesa declarada, VERDE con el detalle que lo dice"

# (15e) "Promesa: sin promesa observable." se lee como ausencia explicita, no como
# una promesa a medio llenar: no exige evidencia y no rompe el parseo de la otra fila.
plan_promesa 'Promesa: sin promesa observable.' 'Promesa: la pantalla de estado muestra "7 de 7" — ruta: abre http://x/tablero/5.'
mkdir -p "$R/docs/evidence"
cat >"$R/docs/evidence/usuario-5-2026-09-24.md" <<'EOF'
## 5.1
Promesa: la pantalla de estado muestra "7 de 7"
Ruta: abrí http://x/tablero/5
FUNCIONA la pantalla mostró "7 de 7" a las 10:32
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m evidencia-15e 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5)
printf '%s' "$out" | grep -q "^VERDE *usuario" \
  || fail "(15e) sin promesa observable en 5.0 y FUNCIONA en 5.1 debe salir VERDE:
$out"
echo "ok (15e): 'sin promesa observable' no exige evidencia, y la otra fila con FUNCIONA cierra"
sin_evidencia_usuario
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m limpia-evidencia-usuario 2>/dev/null
git -C "$R" push -q -f origin HEAD:main

# (15f) Dos archivos de evidencia con fechas distintas: gana el veredicto MAS
# RECIENTE, no el primero que aparezca al concatenar. El contrato dice que el bloque
# "termina" en su veredicto; sin este caso, un check que uniera todos los bloques de
# una fila y se quedara con el primer FUNCIONA que encontrara daria por cerrada una
# promesa que la ultima prueba dice rota -- justo lo que 9.12 existe para impedir.
# Hallazgo del lead sobre 182fde0, reproducido antes de este arreglo.
plan_promesa 'Promesa: la pantalla muestra "7 de 7" — ruta: abre http://x/tablero/5.' ''

# (15f-1) Viejo FUNCIONA, nuevo NO FUNCIONA: ROJO nombrando la fila.
sin_evidencia_usuario
mkdir -p "$R/docs/evidence"
cat >"$R/docs/evidence/usuario-5-2026-09-24.md" <<'EOF'
## 5.0
Promesa: la pantalla muestra "7 de 7"
Ruta: abrí http://x/tablero/5
FUNCIONA mostró "7 de 7" el día 24
EOF
cat >"$R/docs/evidence/usuario-5-2026-09-25.md" <<'EOF'
## 5.0
Promesa: la pantalla muestra "7 de 7"
Ruta: abrí http://x/tablero/5
NO FUNCIONA mostró un error 500 el día 25
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m evidencia-15f-1 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 1 ] || fail "(15f-1) un FUNCIONA viejo con un NO FUNCIONA mas nuevo debe salir 1; salio $rc:
$out"
printf '%s' "$out" | grep -q "^ROJO *usuario" \
  || fail "(15f-1) el veredicto mas reciente (NO FUNCIONA) debe ganar, no el mas viejo (FUNCIONA):
$out"
printf '%s' "$out" | grep -q "5.0" \
  || fail "(15f-1) el detalle debe nombrar la fila 5.0:
$out"
echo "ok (15f-1): con un FUNCIONA viejo y un NO FUNCIONA mas nuevo, gana el mas nuevo: ROJO"

# (15f-2) El otro lado: viejo NO FUNCIONA, nuevo FUNCIONA: VERDE. Sin este caso, un
# check que simplemente usara el ULTIMO archivo por nombre (en vez de el veredicto
# mas reciente) podria pasar (15f-1) por casualidad de orden alfabetico y no defender
# nada distinto.
sin_evidencia_usuario
mkdir -p "$R/docs/evidence"
cat >"$R/docs/evidence/usuario-5-2026-09-24.md" <<'EOF'
## 5.0
Promesa: la pantalla muestra "7 de 7"
Ruta: abrí http://x/tablero/5
NO FUNCIONA mostró un error 500 el día 24
EOF
cat >"$R/docs/evidence/usuario-5-2026-09-25.md" <<'EOF'
## 5.0
Promesa: la pantalla muestra "7 de 7"
Ruta: abrí http://x/tablero/5
FUNCIONA mostró "7 de 7" el día 25, ya re-probado
EOF
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m evidencia-15f-2 2>/dev/null
git -C "$R" push -q -f origin HEAD:main
out=$(CIERRE_SIN_GATEWAY=1 corre 5); rc=$?
[ "$rc" -eq 0 ] || fail "(15f-2) un NO FUNCIONA viejo con un FUNCIONA mas nuevo debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q "^VERDE *usuario" \
  || fail "(15f-2) el veredicto mas reciente (FUNCIONA) debe ganar, no el mas viejo (NO FUNCIONA):
$out"
echo "ok (15f-2): con un NO FUNCIONA viejo y un FUNCIONA mas nuevo (re-probado), gana el mas nuevo: VERDE"
sin_evidencia_usuario
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -q -m limpia-evidencia-15f 2>/dev/null
git -C "$R" push -q -f origin HEAD:main

echo "TODO VERDE: cierre-de-fase"

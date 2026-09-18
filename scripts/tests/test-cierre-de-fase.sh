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
printf '{"plugins":{"entries":{"summa-gate":{}}}}' >"$CFG"
printf 'completed success' >"$CI"
# El stub contesta segun el metodo: el comprobador pregunta por la configuracion y,
# aparte, por el tablero publicado. Un stub que contestara lo mismo a los dos haria
# pasar la comprobacion del tablero sin comprobar nada.
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "runbook.progress.get" ] && { cat "$TAB"; exit 0; }
done
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

# (12f) Una fase que no publica tablero no se bloquea por eso.
git -C "$R" rm -q .saikit/progress/5.json
git -C "$R" commit -q -m sin-tablero; git -C "$R" push -q -f origin HEAD:main
out=$(corre 5)
printf '%s' "$out" | grep -q "^VERDE *tablero" \
  || fail "(12f) una fase sin documento de progreso versionado no debe bloquearse:
$out"
echo "ok (12): el tablero publicado se compara con el versionado, y los dos falsos verdes de las Fases 6 y 7 mueren"

echo "TODO VERDE: cierre-de-fase"

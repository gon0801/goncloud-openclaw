#!/usr/bin/env bash
# `scripts/arranque-de-fase.sh` distingue una fase arrancada de una que no lo esta.
#
# Por que existe. Medido el 2026-09-18: claw reporto la Fase 9 terminada. Nunca la
# arranco del todo — la tarea 0.4 del runbook manda crear `corrida-vigia-<fase>` y
# `corrida-empuje-<fase>`, y ninguno existia. Sin esos crons no hay alarma, y sin alarma
# nadie se entera de que no hay alarma: ocho horas perdidas.
#
# La instruccion ya estaba escrita. Lo que faltaba era la comprobacion. Por eso este
# candado no se conforma con que el script exista: exige que cada linea pueda salir ROJO
# por SU propia causa, porque un comprobador que solo sabe decir VERDE no comprueba nada.
#
# No usa el repo, el gateway ni el tmux del usuario: `openclaw` y `tmux` son stubs cuya
# salida se controla con archivos, igual que en test-cierre-de-fase.sh.
#
# Uso: bash scripts/tests/test-arranque-de-fase.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'ROJO: %s\n' "$1"; exit 1; }

S=scripts/arranque-de-fase.sh
[ -f "$S" ] || fail "falta $S"

# Las variables locales de git contaminan los repos de juguete (mismo cinturon que
# test-sync-pull-identity.sh y test-cierre-de-fase.sh).
for v in $(git rev-parse --local-env-vars 2>/dev/null); do unset "$v"; done

T=$(mktemp -d) || exit 1
L="arr$$"
TM=$(command -v tmux || true); [ -z "$TM" ] && [ -x /opt/homebrew/bin/tmux ] && TM=/opt/homebrew/bin/tmux
trap '[ -n "${TM:-}" ] && "$TM" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/bin"
CRONS="$T/crons.json"; PROG="$T/prog.json"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "cron.list" ] && { cat "$CRONS"; exit 0; }
  [ "\$a" = "runbook.progress.get" ] && { cat "$PROG"; exit 0; }
done
echo '{}'
STUB
chmod +x "$T/bin/openclaw"

crons_con() { # $1..$n nombres encendidos; avance-tareas sale con cadencia de 15 min
  printf '{"jobs":[' >"$CRONS"; sep=""
  for n in "$@"; do
    if [ "$n" = "avance-tareas" ]; then
      printf '%s{"name":"%s","enabled":true,"schedule":{"kind":"every","everyMs":900000}}' "$sep" "$n" >>"$CRONS"
    else
      printf '%s{"name":"%s","enabled":true}' "$sep" "$n" >>"$CRONS"
    fi
    sep=","
  done
  printf ']}\n' >>"$CRONS"
}
prog_ok() { printf '{"ok":true,"doc":{"fase":"5"}}\n' >"$PROG"; }
prog_no() { printf '{"ok":false,"razon":"desconocida"}\n' >"$PROG"; }

# Repo de juguete con una fase 5 de dos filas.
R="$T/repo"; mkdir -p "$R/.saikit/progress"
git init -q "$R" && git -C "$R" config user.email t@t && git -C "$R" config user.name t
cat >"$R/Plans.md" <<'PLAN'
## Fase 5 — algo

| Task | Contenido | DoD | Depends | Status |
|------|-----------|-----|---------|--------|
| 5.0 | uno | su DoD | - | cc:TODO |
| 5.1 | dos | su DoD | 5.0 | cc:TODO |
PLAN
printf 'lead - tok-wt-f5-lead\ncron abc\ncron def\n' >"$R/.saikit/progress/5-sesiones.txt"
git -C "$R" add -A && git -C "$R" commit -q -m plan
REM="$T/remoto.git"; git init -q -b main --bare "$REM"
git -C "$R" remote add origin "$REM"; git -C "$R" push -q origin HEAD:main

# Cinturon: los git de esta prueba tienen que resolver al repo de juguete, no al real.
real=$(cd "$R" && git rev-parse --absolute-git-dir 2>/dev/null)
esperado=$(cd "$R" && pwd -P)/.git
[ "$(cd "$(dirname "$real")" 2>/dev/null && pwd -P)/$(basename "$real")" = "$esperado" ] \
  || fail "los git de esta prueba apuntan a $real, no al repo de juguete"

# tmux de juguete, en su propio servidor, con una sesion de la fase marcada.
if [ -n "${TM:-}" ]; then
  "$TM" -L "$L" new-session -d -s 'tok-wt-f5-lead' 2>/dev/null
  "$TM" -L "$L" set-environment -t 'tok-wt-f5-lead' OPENCLAW_WATCH 1 2>/dev/null
  SHIM="$T/bin/tmux"
  printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$TM" "$L" >"$SHIM"; chmod +x "$SHIM"
else
  SHIM=/no/hay
fi

corre() { REPO="$R" REF=origin/main TMUX_BIN="$SHIM" OPENCLAW_BIN="$T/bin/openclaw" bash "$S" "$@"; }

# (1) Todo hecho: VERDE y salida 0. Sin este caso, un script que siempre dijera ROJO
# pasaria todos los demas.
crons_con avance-tareas corrida-empuje-5; prog_ok
out=$(corre 5); rc=$?
if [ -n "${TM:-}" ]; then
  [ "$rc" -eq 0 ] || fail "(1) una fase arrancada debe salir 0; salio $rc:
$out"
  printf '%s' "$out" | grep -q "VERDE: la fase 5 esta arrancada" || fail "(1) falta el veredicto VERDE:
$out"
  printf '%s' "$out" | grep -q '^ROJO' && fail "(1) no deberia haber ninguna linea ROJO:
$out"
  echo "ok (1): una fase realmente arrancada sale VERDE y con codigo 0"
else
  echo "SKIP (1): sin tmux en esta maquina"
fi

# (2) EL CASO DE HOY: faltan el reloj global y el empuje.
crons_con otro-cron
out=$(corre 5); rc=$?
printf '%s' "$out" | grep -q '^ROJO *vigilantes' || fail "(2) sin el reloj global tiene que salir ROJO:
$out"
printf '%s' "$out" | grep -q 'avance-tareas' || fail "(2) el detalle tiene que nombrar el reloj que falta:
$out"
printf '%s' "$out" | grep -q 'corrida-empuje-5' || fail "(2) tiene que nombrar el empuje, no solo el reloj:
$out"
[ "$rc" -eq 0 ] && fail "(2) sin alarma la fase no puede salir con codigo 0:
$out"
echo "ok (2): sin el reloj global sale ROJO y los nombra a los dos"

# (2b) Creados pero apagados no es lo mismo que creados. Un cron apagado no avisa.
printf '{"jobs":[{"name":"avance-tareas","enabled":true,"schedule":{"kind":"every","everyMs":900000}},{"name":"corrida-empuje-5","enabled":false}]}\n' >"$CRONS"
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *vigilantes' || fail "(2b) un cron apagado no avisa: tiene que salir ROJO:
$out"
printf '%s' "$out" | grep -q 'apagados' || fail "(2b) el detalle tiene que distinguir apagado de ausente:
$out"
echo "ok (2b): un cron creado pero apagado tampoco cuenta"

# (2c) El reloj global con otra cadencia no es el reloj: 60 min deja huecos.
printf '{"jobs":[{"name":"avance-tareas","enabled":true,"schedule":{"kind":"every","everyMs":3600000}},{"name":"corrida-empuje-5","enabled":true}]}\n' >"$CRONS"
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *vigilantes' || fail "(2c) avance-tareas a 60 min tiene que salir ROJO:
$out"
printf '%s' "$out" | grep -q '15 min' || fail "(2c) el detalle tiene que nombrar la cadencia de 15 min:
$out"
echo "ok (2c): avance-tareas con otra cadencia no cuenta"

# (2d) Un vigia por corrida todavia puesto es legado sin migrar: se rechaza.
crons_con avance-tareas corrida-empuje-5 corrida-vigia-5
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *vigilantes' || fail "(2d) un corrida-vigia-5 presente tiene que salir ROJO:
$out"
printf '%s' "$out" | grep -q 'corrida-vigia-5' || fail "(2d) el detalle tiene que nombrar el vigia legado:
$out"
echo "ok (2d): un vigia por corrida sin migrar bloquea el arranque"

# (2e) Una fase que delega TODO seguimiento al watchdog global no crea un empuje
# propio. La excepcion es explicita: sin el flag, el contrato normal de (2) sigue
# exigiendo corrida-empuje; con el flag, avance-tareas sano basta y el legado sigue
# prohibido. Es el contrato de cierre de Fase 9 tras PR #110.
crons_con avance-tareas
out=$(corre 5 --solo-watchdog-global); rc=$?
[ "$rc" -eq 0 ] || fail "(2e) watchdog global sano con excepcion explicita debe salir 0; salio $rc:
$out"
printf '%s' "$out" | grep -q '^VERDE *vigilantes.*solo watchdog global' \
  || fail "(2e) la salida tiene que acreditar el modo global sin empuje propio:
$out"
crons_con avance-tareas corrida-vigia-5
out=$(corre 5 --solo-watchdog-global); rc=$?
[ "$rc" -ne 0 ] || fail "(2e) la excepcion no puede aceptar corrida-vigia-5 legado:
$out"
printf '%s' "$out" | grep -q '^ROJO *vigilantes.*corrida-vigia-5' \
  || fail "(2e) el legado debe seguir nombrado y rechazado:
$out"
echo "ok (2e): el modo global no exige empuje propio y sigue rechazando el vigia legado"

# (3) El primer progreso no enviado: el dueno se queda sin tablero.
crons_con corrida-vigia-5 corrida-empuje-5; prog_no
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *progreso' || fail "(3) sin avance enviado tiene que salir ROJO:
$out"
prog_ok
echo "ok (3): sin el primer avance enviado sale ROJO"

# (4) El apunte de sesiones ausente: al cerrar nadie sabe que quitar.
mv "$R/.saikit/progress/5-sesiones.txt" "$T/guardado.txt"
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *sesiones' || fail "(4) sin el apunte de sesiones tiene que salir ROJO:
$out"
# Y existir no basta: sin la linea del lead tampoco sirve.
printf 'cron abc\n' >"$R/.saikit/progress/5-sesiones.txt"
out=$(corre 5)
printf '%s' "$out" | grep -q '^ROJO *sesiones' || fail "(4) el apunte sin la linea del lead tiene que salir ROJO:
$out"
mv "$T/guardado.txt" "$R/.saikit/progress/5-sesiones.txt"
echo "ok (4): el apunte de sesiones ausente, o sin la linea del lead, sale ROJO"

# (5) La sesion del lead sin marcar: el vigilante no la mira.
if [ -n "${TM:-}" ]; then
  "$TM" -L "$L" set-environment -t 'tok-wt-f5-lead' -u OPENCLAW_WATCH 2>/dev/null
  out=$(corre 5)
  printf '%s' "$out" | grep -q '^ROJO *lead' || fail "(5) la sesion del lead sin marcar tiene que salir ROJO:
$out"
  "$TM" -L "$L" set-environment -t 'tok-wt-f5-lead' OPENCLAW_WATCH 1 2>/dev/null
  echo "ok (5): una sesion de la fase sin marcar sale ROJO"
else
  echo "SKIP (5): sin tmux en esta maquina"
fi

# (6) Una fase que no existe en el plan no sale VERDE por vacio.
out=$(corre 42)
printf '%s' "$out" | grep -q '^ROJO *plan' || fail "(6) una fase sin filas en el plan tiene que salir ROJO:
$out"
echo "ok (6): una fase que no esta en el plan sale ROJO, no VERDE por vacio"

# (7) Sin gateway es unknown, NUNCA VERDE. No poder mirar no es haber mirado: es el
# mismo falso verde que CodeRabbit encontro tres veces en cierre-de-fase.sh.
out=$(ARRANQUE_SIN_GATEWAY=1 REPO="$R" REF=origin/main TMUX_BIN="$SHIM" OPENCLAW_BIN="$T/bin/openclaw" bash "$S" 5)
printf '%s' "$out" | grep -q '^unknown *vigilantes' || fail "(7) sin gateway los vigilantes son unknown:
$out"
printf '%s' "$out" | grep -q '^VERDE *vigilantes' && fail "(7) sin gateway no se puede dar por buena la alarma:
$out"
printf '%s' "$out" | grep -q '^unknown *progreso' || fail "(7) sin gateway el progreso es unknown:
$out"
echo "ok (7): sin gateway las dos comprobaciones quedan unknown, nunca VERDE"

# (8) El gateway que falla DESPUES de escribir algo no se da por bueno. Es el mismo
# arreglo que la comprobacion (7) de cierre-de-fase.sh necesito el 2026-09-18.
cat >"$T/bin/openclaw" <<'STUB'
#!/bin/sh
echo '{"jobs":[{"name":"corrida-vigia-5","enabled":true},{"name":"corrida-empuje-5","enabled":true}]}'
exit 1
STUB
chmod +x "$T/bin/openclaw"
out=$(corre 5)
printf '%s' "$out" | grep -q '^VERDE *vigilantes' \
  && fail "(8) una consulta que fallo no puede darse por buena por lo que alcanzo a escribir:
$out"
echo "ok (8): una consulta fallida no cuenta aunque haya escrito una lista valida"

# El caso (8) dejo el stub saliendo 1 a proposito; se repone antes de seguir, o todo lo
# que venga despues mediria "gateway caido" en vez de lo suyo.
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
for a in "\$@"; do
  [ "\$a" = "cron.list" ] && { cat "$CRONS"; exit 0; }
  [ "\$a" = "runbook.progress.get" ] && { cat "$PROG"; exit 0; }
done
echo '{}'
STUB
chmod +x "$T/bin/openclaw"

# (9) El resumen distingue "todo comprobado" de "no pude comprobar lo esencial". Sin
# gateway las dos comprobaciones que motivaron el script quedan unknown; decir VERDE a
# secas ahi seria prometer mas de lo que se miro, que es el falso verde contra el que
# existe este script. Hallazgo de kimi en la revision cruzada, 2026-09-18.
if [ -n "${TM:-}" ]; then
  crons_con avance-tareas corrida-empuje-5; prog_ok
  out=$(ARRANQUE_SIN_GATEWAY=1 REPO="$R" REF=origin/main TMUX_BIN="$SHIM" OPENCLAW_BIN="$T/bin/openclaw" bash "$S" 5); rc=$?
  [ "$rc" -eq 0 ] || fail "(9) sin rojos tiene que salir 0 aunque haya unknowns; salio $rc:
$out"
  printf '%s' "$out" | grep -q 'VERDE con reservas' \
    || fail "(9) con dos comprobaciones sin hacer, el resumen no puede decir VERDE a secas:
$out"
  printf '%s' "$out" | grep -qE 'VERDE con reservas.*2 comprobacion' \
    || fail "(9) el resumen tiene que decir CUANTAS quedaron sin comprobar:
$out"
  echo "ok (9): con comprobaciones sin hacer el resumen lo dice, y no promete mas de lo que miro"

  # Y discrimina: con todo comprobado, el resumen NO lleva reservas.
  out=$(corre 5)
  printf '%s' "$out" | grep -q 'VERDE con reservas' \
    && fail "(9) con todo comprobado el resumen no debe llevar reservas:
$out"
  printf '%s' "$out" | grep -q 'VERDE: la fase 5 esta arrancada' \
    || fail "(9) con todo comprobado falta el veredicto limpio:
$out"
  echo "ok (9b): con todo comprobado el resumen es VERDE a secas"
else
  echo "SKIP (9): sin tmux en esta maquina"
fi

# (10) El gateway que contesta con exito pero con JSON roto. Era la unica rama de
# `vigilantes` sin prueba, justo en la comprobacion que motiva el cambio. Hallazgo de
# kimi. No puede salir VERDE ni ROJO: no se pudo leer, se declara.
cat >"$CRONS" <<'ROTO'
{"jobs":[{"name":"corrida-vigia-5", enabled: true,,}
ROTO
prog_ok
out=$(corre 5)
printf '%s' "$out" | grep -q '^VERDE *vigilantes' \
  && fail "(10) un JSON roto no puede dar los vigilantes por buenos:
$out"
printf '%s' "$out" | grep -q '^unknown *vigilantes' \
  || fail "(10) un JSON roto tiene que declararse unknown, no ROJO ni VERDE:
$out"
crons_con corrida-vigia-5 corrida-empuje-5
echo "ok (10): una respuesta ilegible se declara, no se interpreta"

echo "TODO VERDE: arranque-de-fase"

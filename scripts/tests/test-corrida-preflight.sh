#!/bin/bash
# 9.3 preflight: lo que fallo esa noche se prueba antes de arrancar. Stubs para
# gh/openclaw, tmux propio (-L), CLIs de mentira, vigilante de mentira. Ninguna
# prueba toca la red real ni sesiones del usuario.
# Uso: bash scripts/tests/test-corrida-preflight.sh
set -u
# Esta prueba arma un repo con git: sin esto, bajo el hook de pre-commit las ordenes
# git escaparian al repo real (exporta GIT_DIR/GIT_INDEX_FILE). Ver run-checks.sh.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba"

T=$(mktemp -d) || exit 1
L="preflight$$"
trap '[ -n "${VPID:-}" ] && kill "$VPID" 2>/dev/null; "$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ses" "$T/wbin"

# CLIs de mentira: anotan su argv (para probar que el flag LLEGA al binario).
ARGV_LOG="$T/argv.log"
cat >"$T/bin/cli-ok" <<'CLI'
#!/bin/sh
printf '%s\n' "$*" >> "$ARGV_LOG"
echo "BAR-OK-9"
sleep 30
CLI
cat >"$T/bin/cli-muere" <<'CLI'
#!/bin/sh
printf '%s\n' "$*" >> "$ARGV_LOG"
exit 3
CLI
cat >"$T/bin/cli-flag-malo" <<'CLI'
#!/bin/sh
printf '%s\n' "$*" >> "$ARGV_LOG"
echo "BAR-OTRA"
sleep 30
CLI
cat >"$T/bin/cli-lento" <<'CLI'
#!/bin/sh
printf '%s\n' "$*" >> "$ARGV_LOG"
sleep 3
echo "BAR-LENTO-9"
sleep 30
CLI
chmod +x "$T/bin"/cli-ok "$T/bin"/cli-muere "$T/bin"/cli-flag-malo "$T/bin"/cli-lento

# gh de mentira: GH_MODO=mal simula el 401.
cat >"$T/bin/gh" <<'STUB'
#!/bin/sh
if [ "${GH_MODO:-ok}" = "mal" ]; then
  echo "401: sin autenticar" >&2
  exit 1
fi
case "$*" in
  *auth\ status*) exit 0;;
  *api\ user*) printf 'dueno-de-mentira';;
esac
exit 0
STUB
# openclaw de mentira: gateway, dry-run y crons. GW_MODO/ENVIO_MODO fallan a pedido.
LLAMADAS="$T/llamadas.log"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ rm*) [ "\${CRON_RM_FAIL:-0}" = "1" ] && exit 1; printf '{}';;
  *cron\ list*) printf '{"jobs":[{"name":"verif-sync-repos","delivery":{"to":"DESTINO-PRE-9X"}}]}';;
  *cron\ add*) printf '{"id":"cron-1"}';;
  *gateway\ call\ status*) [ "\${GW_MODO:-ok}" = "mal" ] && exit 1; printf '{"ok":true}';;
  *message\ send*) [ "\${ENVIO_MODO:-ok}" = "mal" ] && exit 1; printf '{"messageId":"m1"}';;
esac
exit 0
STUB
chmod +x "$T/bin"/gh "$T/bin"/openclaw

# tmux con servidor propio.
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

# Repo de mentira: preflight compara el instalado contra origin/main de REPO_DIR,
# asi que se arma un repo propio y determinista (el checkout de CI no garantiza
# que origin/main exista). El caso rojo demuestra que la comparacion discrimina.
mkdir -p "$T/repo/scripts/mac" "$T/repo/scripts/tests"
cp scripts/mac/tmux-activity-watch.sh "$T/repo/scripts/mac/"
cp -r scripts/tests/fixtures "$T/repo/scripts/tests/"
git -C "$T/repo" init -q
git -C "$T/repo" add -A
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm semilla
git -C "$T/repo" update-ref refs/remotes/origin/main HEAD
git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" REPO_DIR="$T/repo"
export OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim" GH_BIN="$T/bin/gh"
export WATCH_INSTALADO="$T/wbin/tmux-activity-watch.sh" ARGV_LOG

# Vigilante de mentira: instalado = el blob de origin que preflight compara.
# Proceso con su nombre para que pgrep lo encuentre; muere en el trap del EXIT.
git -C "$T/repo" show "origin/main:scripts/mac/tmux-activity-watch.sh" >"$WATCH_INSTALADO" \
  || fail "sin blob de referencia del vigilante"
bash -c "exec -a \"$T/wbin/tmux-activity-watch.sh\" sleep 120" &
VPID=$!

modos() { # $1 archivo: filas "cli binario flag barra"
  rm -f "$T/m.tsv"
  while [ $# -gt 1 ]; do
    printf '%s\t%s\t%s\t%s\t--\t--\t--\n' "$2" "$3" "$4" "$5" >>"$T/m.tsv"
    shift 5 2>/dev/null || shift 4
  done
}
abrir() { # $1 id, $2 runbook
  bash "$CORR" abrir "$1" --runbook "$2" --vigia claw --cli-modos "$T/m.tsv" >/dev/null \
    || fail "abrir $1 fallo"
}
RB=scripts/tests/fixtures/corrida/runbook-simulacro.md

# VERDE con todo sano (y el flag llega de verdad al binario).
: > "$ARGV_LOG"
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-ok "$RB"
out=$(bash "$CORR" preflight t-ok) || fail "preflight sano debio dar APTO:
$out"
[ "$(printf '%s' "$out" | head -1)" = "APTO" ] || fail "primera linea distinta de APTO:
$out"
grep -q -- "--flag-ok-9" "$ARGV_LOG" || fail "el flag no llego al binario"

# ROJO con gh en 401.
export GH_MODO=mal
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-gh "$RB"
out=$(bash "$CORR" preflight t-gh 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con gh en 401 debio dar NO APTO"
printf '%s' "$out" | head -1 | grep -q "^NO APTO" || fail "sin NO APTO con gh en 401:
$out"
printf '%s' "$out" | grep -q "gh sin autenticar" || fail "NO APTO sin razon de gh:
$out"
grep -q "DETENIDA" "$T/corridas/t-gh/mensajes.jsonl" || fail "NO APTO no mando mensaje"
unset GH_MODO

# ROJO con binario que muere.
modos x muere cli-muere "--flag-9" "BAR-OK-9"
abrir t-muere "$RB"
out=$(bash "$CORR" preflight t-muere 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con binario que muere debio dar NO APTO"
printf '%s' "$out" | grep -q "binario muere al arrancar" || fail "NO APTO sin razon del binario:
$out"

# ROJO con flag que no entra (pero que llega al binario: la razon es la barra).
: > "$ARGV_LOG"
modos x mal cli-flag-malo "--flag-malo-9" "BAR-OK-9"
abrir t-flag "$RB"
out=$(bash "$CORR" preflight t-flag 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con flag que no entra debio dar NO APTO"
printf '%s' "$out" | grep -q "flag no entra: mal" || fail "NO APTO sin razon del flag:
$out"
grep -q -- "--flag-malo-9" "$ARGV_LOG" || fail "el flag del CLI malo no llego al binario"

# ROJO con barra vacia en la tabla: error, no acierto por omision.
modos x vacia cli-ok "--flag-ok-9" ""
abrir t-vacia "$RB"
out=$(bash "$CORR" preflight t-vacia 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con barra vacia debio dar NO APTO"
printf '%s' "$out" | grep -q "barra vacia" || fail "NO APTO sin razon de barra vacia:
$out"

# ROJO con vigilante viejo (y el instalado se restaura: los casos que siguen no
# heredan el watch roto).
printf '# linea ajena\n' >>"$WATCH_INSTALADO"
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-viejo "$RB"
out=$(bash "$CORR" preflight t-viejo 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con vigilante viejo debio dar NO APTO"
printf '%s' "$out" | grep -q "vigilante viejo" || fail "NO APTO sin razon del vigilante:
$out"
git -C "$T/repo" show "origin/main:scripts/mac/tmux-activity-watch.sh" >"$WATCH_INSTALADO"

# ROJO con la tabla ilegible: nada de APTO ciego sin haber probado binarios.
printf 'ok\tcli-ok\t--flag-ok-9\tBAR-OK-9\t--\t--\t--\n' >"$T/t-tabla.tsv"
bash "$CORR" abrir t-tabla --runbook "$RB" --vigia claw --cli-modos "$T/t-tabla.tsv" >/dev/null \
  || fail "abrir t-tabla fallo"
mv "$T/t-tabla.tsv" "$T/t-tabla.tsv.fuera"
out=$(bash "$CORR" preflight t-tabla 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con tabla ilegible debio dar NO APTO"
printf '%s' "$out" | grep -q "tabla de modos ilegible" || fail "NO APTO sin razon de tabla:
$out"

# ROJO con gateway caido.
export GW_MODO=mal
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-gw "$RB"
out=$(bash "$CORR" preflight t-gw 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con gateway caido debio dar NO APTO"
printf '%s' "$out" | grep -q "gateway no responde" || fail "NO APTO sin razon del gateway:
$out"
unset GW_MODO

# ROJO con el canal sin envio.
export ENVIO_MODO=mal
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-canal "$RB"
out=$(bash "$CORR" preflight t-canal 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con canal sin envio debio dar NO APTO"
printf '%s' "$out" | grep -q "sin envio al canal" || fail "NO APTO sin razon de envio:
$out"
unset ENVIO_MODO

# ROJO con runbook que declara ssh en sesion que lo niega.
export CORRIDA_CANDADO_ssh=negado
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-ssh scripts/tests/fixtures/corrida/runbook-con-ssh.md
out=$(bash "$CORR" preflight t-ssh 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con ssh negado debio dar NO APTO"
printf '%s' "$out" | grep -q "clase negada: ssh" || fail "NO APTO sin razon de ssh:
$out"
unset CORRIDA_CANDADO_ssh

# ROJO con ssh usado y no declarado en la tabla.
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-undecl scripts/tests/fixtures/corrida/runbook-mal-clases.md
out=$(bash "$CORR" preflight t-undecl 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con clase sin declarar debio dar NO APTO"
printf '%s' "$out" | grep -q "clase sin declarar: ssh" || fail "NO APTO sin razon de clase:
$out"

# ROJO con red externa usada y no declarada: la clase compuesta se nombra entera.
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-redud scripts/tests/fixtures/corrida/runbook-usa-red-sin-declarar.md
out=$(bash "$CORR" preflight t-redud 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con red externa sin declarar debio dar NO APTO"
printf '%s' "$out" | grep -q "clase sin declarar: red externa" || fail "la clase compuesta salio partida:
$out"

# ROJO con clase declarada en la tabla y nunca usada en bloques: tambien se prueba,
# incluso la clase compuesta ("red externa" no se parte en dos).
export CORRIDA_CANDADO_red_externa=negado
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-red scripts/tests/fixtures/corrida/runbook-declara-red.md
out=$(bash "$CORR" preflight t-red 2>&1); rc=$?
[ $rc -ne 0 ] || fail "red externa declarada y no usada debio dar NO APTO"
printf '%s' "$out" | grep -q "clase negada: red externa" || fail "NO APTO sin razon de red externa:
$out"
unset CORRIDA_CANDADO_red_externa

# ROJO con clase declarada en la tabla y nunca usada en bloques: tambien se prueba.
export CORRIDA_CANDADO_psql=negado
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-psql scripts/tests/fixtures/corrida/runbook-declara-psql.md
out=$(bash "$CORR" preflight t-psql 2>&1); rc=$?
[ $rc -ne 0 ] || fail "clase declarada y no usada debio dar NO APTO"
printf '%s' "$out" | grep -q "clase negada: psql" || fail "NO APTO sin razon de psql declarado:
$out"
unset CORRIDA_CANDADO_psql

# ROJO con runbook guardado como ruta absoluta: preflight lo lee igual (unificar).
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
bash "$CORR" abrir t-abs --runbook "$PWD/scripts/tests/fixtures/corrida/runbook-simulacro.md" --vigia claw --cli-modos "$T/m.tsv" >/dev/null \
  || fail "abrir t-abs fallo"
out=$(bash "$CORR" preflight t-abs 2>&1); rc=$?
[ $rc -eq 0 ] || fail "con runbook absoluto debio dar APTO:
$out"
printf '%s' "$out" | grep -q "runbook sin leer" && fail "el runbook absoluto no se leyo"

# (P) aislamiento git: env hostil no toca el indice ni las refs del centinela, y
# los unset que lo garantizan siguen en su sitio (ancla de regresion).
mkdir -p "$T/sentinela"
git -C "$T/sentinela" init -q
git -C "$T/sentinela" -c user.email=t@t -c user.name=t commit -qm x --allow-empty
antes_idx="$(git -C "$T/sentinela" ls-files | wc -l | tr -d ' ')"
antes_ref="$(git -C "$T/sentinela" rev-parse refs/remotes/origin/main 2>/dev/null || echo ninguna)"
(
  export GIT_DIR="$T/sentinela/.git" GIT_INDEX_FILE="$T/sentinela/.git/idx-hostil"
  bash "$CORR" preflight t-ok >/dev/null 2>&1
)
desp_idx="$(git -C "$T/sentinela" ls-files | wc -l | tr -d ' ')"
desp_ref="$(git -C "$T/sentinela" rev-parse refs/remotes/origin/main 2>/dev/null || echo ninguna)"
[ "$antes_idx" = "$desp_idx" ] || fail "el indice del centinela gano entradas"
[ "$antes_ref" = "$desp_ref" ] || fail "se movio origin/main del centinela"
grep -q "unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX" scripts/run-checks.sh \
  || fail "run-checks.sh perdio el unset de git"
grep -q "unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX" scripts/mac/corrida/preflight.sh \
  || fail "preflight.sh perdio el unset de git"

# (A3) una senal a mitad no deja sesiones de prueba vivas con un CLI real adentro.
# Determinista: se espera a que la sesion exista antes de senalar, sin sleep fijo.
modos x lento cli-lento "--flag-lento-9" "BAR-LENTO-9"
abrir t-int "$RB"
bash "$CORR" preflight t-int >/dev/null 2>&1 &
PPID_INT=$!
espera_sesion() { # $1 nombre: 0 cuando existe (max ~5 s)
  local k=0
  while [ "$k" -lt 50 ]; do
    "$TM_REAL" -L "$L" has-session -t "=$1" 2>/dev/null && return 0
    sleep 0.1; k=$((k+1))
  done
  return 1
}
espera_sesion preflight-t-int-lento || fail "la sesion de prueba nunca existio"
kill -TERM "$PPID_INT" 2>/dev/null
wait "$PPID_INT" 2>/dev/null
sleep 0.5
"$TM_REAL" -L "$L" has-session -t "=preflight-t-int-lento" 2>/dev/null \
  && fail "una senal a mitad dejo viva la sesion de prueba"

# (S) con DOS sesiones de prueba vivas, la senal las mata a las dos: la iteracion
# de pf_limpiar no puede llegar pegada en una sola palabra.
"$TM_REAL" -L "$L" new-session -d -s preflight-t-mul-a 'sleep 60' >/dev/null
"$TM_REAL" -L "$L" new-session -d -s preflight-t-mul-b 'sleep 60' >/dev/null
modos x lento cli-lento "--flag-lento-9" "BAR-LENTO-9"
abrir t-mul "$RB"
bash "$CORR" preflight t-mul >/dev/null 2>&1 &
PMUL=$!
espera_sesion preflight-t-mul-lento || fail "la sesion del caso multiple nunca existio"
kill -TERM "$PMUL" 2>/dev/null
wait "$PMUL" 2>/dev/null
sleep 0.5
"$TM_REAL" -L "$L" has-session -t "=preflight-t-mul-a" 2>/dev/null \
  && fail "la senal dejo viva a preflight-t-mul-a"
"$TM_REAL" -L "$L" has-session -t "=preflight-t-mul-b" 2>/dev/null \
  && fail "la senal dejo viva a preflight-t-mul-b"
"$TM_REAL" -L "$L" has-session -t "=preflight-t-mul-lento" 2>/dev/null \
  && fail "la senal dejo viva a la sesion en curso"

# ROJO con el vigilante sin correr (ultimo caso: pgrep de mentira, porque el
# vigilante REAL de la Mac tambien matchea el patron y contaminaria el caso).
mkdir -p "$T/nopgrep"
printf '#!/bin/sh\nexit 1\n' >"$T/nopgrep/pgrep"
chmod +x "$T/nopgrep/pgrep"
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-novig "$RB"
out="$(PATH="$T/nopgrep:$PATH" bash "$CORR" preflight t-novig 2>&1)"; rc=$?
[ $rc -ne 0 ] || fail "sin vigilante debio dar NO APTO"
printf '%s' "$out" | grep -q "vigilante no corre" || fail "NO APTO sin razon de vigilante:
$out"

kill "$VPID" 2>/dev/null
wait "$VPID" 2>/dev/null
echo "TODO VERDE: test-corrida-preflight"

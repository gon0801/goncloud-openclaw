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
texto_json() { # $1 linea de mensajes.jsonl -> su campo 'texto' decodificado (sin \uXXXX)
  printf '%s' "$1" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('texto',''))"
}

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
  *cron\ list*) printf '{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"DESTINO-PRE-9X"}}]}';;
  *cron\ add*) printf '{"id":"cron-1"}';;
  *gateway\ call\ status*) [ "\${GW_MODO:-ok}" = "mal" ] && exit 1; printf '{"ok":true}';;
  *message\ send*) [ "\${ENVIO_MODO:-ok}" = "mal" ] && exit 1; printf '{"messageId":"m1"}';;
  *browser\ tabs*)
    # B4: mecanismo del flag del navegador. "ok": solo --profile claw desvia la
    # config (la forma del incidente). "muda": la forma mala deja de desviar
    # (copia divergente, direccion 1). "doblez": --browser-profile TAMBIEN
    # desvia (copia divergente, direccion 2).
    prev=""
    mala=0
    for a in "\$@"; do
      if [ "\$prev" = "--profile" ] && [ "\$a" = "claw" ]; then mala=1; fi
      prev="\$a"
    done
    if [ "\$mala" = "1" ] && { [ "\${BROWSER_MODO:-ok}" = "ok" ] || [ "\${BROWSER_MODO:-ok}" = "rechaza" ] || [ "\${BROWSER_MODO:-ok}" = "gateway" ]; }; then
      printf 'config desviada a ~/.openclaw-claw/openclaw.json\n'
    fi
    if [ "\$mala" = "0" ] && [ "\${BROWSER_MODO:-ok}" = "doblez" ]; then
      printf 'config desviada a ~/.openclaw-claw/openclaw.json\n'
    fi
    if [ "\$mala" = "0" ] && [ "\${BROWSER_MODO:-ok}" = "rechaza" ]; then
      # CLI que no conoce el flag: usage de mentira, sin la ruta desviada.
      printf 'error: unknown option --browser-profile\n' >&2
      exit 64
    fi
    if [ "\$mala" = "0" ] && [ "\${BROWSER_MODO:-ok}" = "gateway" ]; then
      # El flag se acepto. Sale 1 porque no hay gateway, y nombra la config
      # real, no la desviada.
      printf 'gateway browser.request requires credentials\nConfig: %s/.openclaw/openclaw.json\n' "\$HOME" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$T/bin"/gh "$T/bin"/openclaw

# tmux con servidor propio. Cada llamada queda anotada: el caso F2-g prueba
# que la sesion de una fila legacy NUNCA se crea.
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
printf 'TMUX %s\n' "\$*" >> "$T/tmux-llamadas.log"
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
# Vive mientras viva esta prueba, sin tope fijo: un tope se queda corto si la
# suite tarda mas (14.25 R25) y aun asi no deja huerfanos si la matan con -9.
git -C "$T/repo" show "origin/main:scripts/mac/tmux-activity-watch.sh" >"$WATCH_INSTALADO" \
  || fail "sin blob de referencia del vigilante"
bash -c "exec -a \"$T/wbin/tmux-activity-watch.sh\" bash -c 'while kill -0 $$ 2>/dev/null; do sleep 1; done'" &
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
texto_json "$(tail -n 1 "$T/corridas/t-gh/mensajes.jsonl")" >"$T/det-gh.txt"
grep -q "falta: " "$T/det-gh.txt" \
  || fail "el aviso DETENIDA no dice que falta:
$(cat "$T/det-gh.txt")"
grep -q "gh sin autenticar" "$T/det-gh.txt" \
  || fail "el aviso DETENIDA no nombra la razon de gh:
$(cat "$T/det-gh.txt")"

# 14.27 R4: una razon con jerga (el CLI "script" que muere) queda fuera del
# aviso, pero la razon limpia de gh sigue diciendo que falta.
modos x script cli-muere "--flag-9" "BAR-OK-9"
abrir t-gh-jerga "$RB"
out=$(bash "$CORR" preflight t-gh-jerga 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con gh en 401 y binario que muere debio dar NO APTO"
printf '%s' "$out" | grep -q "binario muere al arrancar: script" || fail "NO APTO sin la razon del binario:
$out"
texto_json "$(tail -n 1 "$T/corridas/t-gh-jerga/mensajes.jsonl")" >"$T/det-gh-jerga.txt"
grep -q "falta: gh sin autenticar" "$T/det-gh-jerga.txt" \
  || fail "una razon con jerga borro del aviso la razon limpia de gh:
$(cat "$T/det-gh-jerga.txt")"
grep -q "script" "$T/det-gh-jerga.txt" \
  && fail "la razon con jerga llego al aviso:
$(cat "$T/det-gh-jerga.txt")"
unset GH_MODO

# ROJO con binario que muere.
modos x muere cli-muere "--flag-9" "BAR-OK-9"
abrir t-muere "$RB"
out=$(bash "$CORR" preflight t-muere 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con binario que muere debio dar NO APTO"
printf '%s' "$out" | grep -q "binario muere al arrancar" || fail "NO APTO sin razon del binario:
$out"

# ROJO con binario inyectado en la tabla (IA): rechazo cerrado, con diagnostico,
# y sin ejecutar nada de lo inyectado.
modos x inyecta "tocar; touch $T/inyeccion-9x; true" "--flag-9" "BAR-OK-9"
abrir t-iny "$RB"
out=$(bash "$CORR" preflight t-iny 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con binario inyectado debio dar NO APTO"
printf '%s' "$out" | grep -q "binario no arranca" || fail "NO APTO sin razon del binario inyectado:
$out"
printf '%s' "$out" | grep -q "binario invalido" || fail "la tabla inyectada no se diagnostica:
$out"
[ -e "$T/inyeccion-9x" ] && fail "la inyeccion del binario ejecuto codigo"

# ROJO con flag inyectado en la tabla (JA): rechazo cerrado, diagnostico y nada ejecutado.
modos x jaf cli-muere "--modo; touch $T/ja-marker-9x; true" "BAR-OK-9"
abrir t-jaf "$RB"
out=$(bash "$CORR" preflight t-jaf 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con flag inyectado debio dar NO APTO"
printf '%s' "$out" | grep -q "flag invalido" || fail "la tabla con flag inyectado no se diagnostica:
$out"
[ -e "$T/ja-marker-9x" ] && fail "la inyeccion del flag ejecuto codigo"

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

# B4 (7): mecanismo del navegador con el binario real. Con la copia IGUAL,
# APTO con el mecanismo PROBADO: su propio unknown no puede aparecer. Los
# unknowns de clase (ssh, red externa) son previos del sandbox (candado_clase
# sin CORRIDA_CANDADO_*, rc=2 medido) y no dicen nada del chequeo (7): exigir
# cero unknowns en TODO el output dio un falso rojo en CI (PR #123, artifact
# logs-run-checks-shard-2: "APTO / QUEDA unknown: clase sin medir ssh, red
# externa" con el mecanismo correctamente probado).
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-bro-ok "$RB"
out=$(bash "$CORR" preflight t-bro-ok 2>&1) || fail "preflight con navegador igual debio dar APTO:
$out"
printf '%s' "$out" | head -1 | grep -q "^APTO" || fail "primera linea distinta de APTO con navegador igual:
$out"
printf '%s' "$out" | grep -q "mecanismo del navegador sin probar" \
  && fail "el mecanismo del navegador quedo sin probar (unknown) con el binario presente:
$out"

# B4 (7): copia DIVERGENTE direccion 1 --profile claw mudo => NO APTO con razon.
export BROWSER_MODO=muda
abrir t-bro-muda "$RB"
out=$(bash "$CORR" preflight t-bro-muda 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con CLI divergente (--profile mudo) debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "ya no desvia la config" \
  || fail "NO APTO sin la razon de divergencia (direccion 1):
$out"
unset BROWSER_MODO

# B4 (7): copia DIVERGENTE direccion 2 --browser-profile tambien desvia => NO APTO.
export BROWSER_MODO=doblez
abrir t-bro-doblez "$RB"
out=$(bash "$CORR" preflight t-bro-doblez 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con CLI divergente (doble desvio) debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "tambien desvia" \
  || fail "NO APTO sin la razon de divergencia (direccion 2):
$out"
unset BROWSER_MODO

# B4 (8): el CLI RECHAZA --browser-profile (no lo conoce) => NO APTO. Medido el
# 2026-09-22: el preflight ignoraba el exit code de la sonda y con una salida de
# error que no menciona la ruta desviada declaraba APTO un CLI que no sabe
# ejecutar el flag que el runbook usa.
export BROWSER_MODO=rechaza
abrir t-bro-rechaza "$RB"
out=$(bash "$CORR" preflight t-bro-rechaza 2>&1); rc=$?
[ $rc -ne 0 ] || fail "un CLI que rechaza --browser-profile no puede salir APTO:
$out"
printf '%s' "$out" | grep -q "rechazo --browser-profile" \
  || fail "NO APTO sin nombrar el rechazo del flag:
$out"
unset BROWSER_MODO

# B4 (8): el CLI ACEPTA --browser-profile y sale 1 porque no hay gateway.
# Medido el 2026-09-22: cualquier exit distinto de 0 se leia como flag
# ausente, y el binario instalado (que si tiene el flag) dejaba la corrida
# NO APTO.
export BROWSER_MODO=gateway
abrir t-bro-gw "$RB"
out=$(bash "$CORR" preflight t-bro-gw 2>&1) || fail "un CLI que acepta --browser-profile y falla el gateway debe seguir APTO:
$out"
printf '%s' "$out" | head -1 | grep -q "^APTO" \
  || fail "primera linea distinta de APTO con fallo de gateway:
$out"
printf '%s' "$out" | grep -q "rechazo --browser-profile" \
  && fail "un fallo de gateway no es rechazo del flag:
$out"
unset BROWSER_MODO

# B4 (7): CLI AUSENTE => unknown explicito, jamas silencio (el resto de las
# razones siguen su curso: gateway y canal tampoco responden). El REGISTRO de
# la corrida (abrir) usa el stub SANO: abrir lee `openclaw cron list` y con el
# binario ausente muere ANTES de llegar a preflight ("abrir: sin lista de
# crons legible", CI run 35690236857 — exportar OPENCLAW_BIN ausente antes de
# abrir fue el defecto de la ronda 2). La ausencia se pasa SOLO al preflight,
# por env del comando: es exactamente la superficie que el chequeo (7) audita.
abrir t-bro-ausente "$RB"
out=$(OPENCLAW_BIN="$T/bin/openclaw-ausente" bash "$CORR" preflight t-bro-ausente 2>&1); rc=$?
[ $rc -ne 0 ] || fail "sin CLI el preflight no puede quedar APTO:
$out"
printf '%s' "$out" | grep -q "CLI openclaw ausente" \
  || fail "sin CLI instalado la ausencia debia quedar como unknown explicito:
$out"
texto_json "$(tail -n 1 "$T/corridas/t-bro-ausente/mensajes.jsonl")" >"$T/det-bro.txt"
sed -n '3p' "$T/det-bro.txt" | grep -q "gateway no responde" \
  || fail "el Que cambio del aviso no nombra gateway no responde:
$(cat "$T/det-bro.txt")"
sed -n '3p' "$T/det-bro.txt" | grep -q "sin envio al canal" \
  || fail "el Que cambio del aviso no nombra sin envio al canal:
$(cat "$T/det-bro.txt")"
grep -q "falta: " "$T/det-bro.txt" \
  || fail "las razones no quedaron unidas en una sola linea:
$(cat "$T/det-bro.txt")"

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

# CI #153: REPO_DIR sin origin/main (el checkout superficial de un shard no lo
# trae) NO puede decir "vigilante viejo" en falso. Sin --verify, `git
# rev-parse origin/main:<ruta>` en un repo sin ese remoto imprime el
# ARGUMENTO LITERAL por stdout (con el "fatal:" solo en stderr, que aqui va a
# /dev/null): "Esperado" quedaba no vacio, distinto del blob instalado, y
# preflight declaraba viejo un vigilante que nunca se pudo comparar.
mkdir -p "$T/repo-sin-origin/scripts/mac"
cp scripts/mac/tmux-activity-watch.sh "$T/repo-sin-origin/scripts/mac/"
git -C "$T/repo-sin-origin" init -q
git -C "$T/repo-sin-origin" add -A
git -C "$T/repo-sin-origin" -c user.email=t@t -c user.name=t commit -qm semilla
# A proposito: SIN remoto origin, como el checkout superficial de un shard de CI.
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-sin-origin "$RB"
out=$(REPO_DIR="$T/repo-sin-origin" bash "$CORR" preflight t-sin-origin 2>&1)
printf '%s' "$out" | grep -q "vigilante viejo" \
  && fail "REPO_DIR sin origin/main: el vigilante NO debia salir 'viejo' (regresion CI #153):
$out"
printf '%s' "$out" | grep -q "blob del vigilante sin comparar" \
  || fail "REPO_DIR sin origin/main: se esperaba el unknown 'blob del vigilante sin comparar':
$out"

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

# 14.20 (4) y (5): el bloque de sondas nativas (8) cubierto de punta a punta.
# Ruteo apagado no toca el veredicto; con ruteo activo, un registro de workers
# VACIO es NO APTO (dato, no unknown), un worker sano no agrega razones, uno
# muerto deja "sin trabajador compatible" y un arnes ilegible queda unknown.
REGW="$T/workers-nat.json"
cp scripts/tests/fixtures/workers/valid.json "$REGW"
cat >"$T/bin/worker-ok" <<'CLI'
#!/bin/sh
echo "worker falso 1.0"
exit 0
CLI
cat >"$T/bin/worker-muerto" <<'CLI'
#!/bin/sh
exit 9
CLI
chmod +x "$T/bin/worker-ok" "$T/bin/worker-muerto"
WPY_REAL="$PWD/scripts/mac/corrida-worker.py"
vaciar_registro() {
  python3 - "$REGW" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
rec["workers"] = []
json.dump(rec, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
}
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
# F2: estos casos cruzan con el registro del fixture (binario claude); la
# tabla del registro debe traer su fila medida o el candado vuelve todo NO APTO.
printf 'claude\tcli-ok\tx\tBAR-OK-9\t--\t--\t--\n' >>"$T/m.tsv"

vaciar_registro
abrir t-nat-off "$RB"
out=$(CORRIDA_NATIVE_ROUTING=off CORRIDA_WORKER_PY="$WPY_REAL" CORRIDA_WORKERS_REGISTRY="$REGW" \
  bash "$CORR" preflight t-nat-off 2>&1)
printf '%s\n' "$out" | head -1 | grep -q '^APTO' \
  || fail "con ruteo off el preflight dejo de ser APTO: $out"
printf '%s' "$out" | grep -q 'registro de workers sin entradas' \
  && fail "con ruteo off el bloque de sondas no debio correr: $out"

abrir t-nat-vacio "$RB"
out=$(CORRIDA_NATIVE_ROUTING=report CORRIDA_WORKER_PY="$WPY_REAL" CORRIDA_WORKERS_REGISTRY="$REGW" \
  bash "$CORR" preflight t-nat-vacio 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con el registro de workers vacio debio dar NO APTO: $out"
printf '%s' "$out" | grep -q 'registro de workers sin entradas' \
  || fail "NO APTO sin la razon del registro vacio: $out"

cp scripts/tests/fixtures/workers/valid.json "$REGW"
abrir t-nat-ok "$RB"
out=$(CORRIDA_NATIVE_ROUTING=report CORRIDA_WORKER_PY="$WPY_REAL" CORRIDA_WORKERS_REGISTRY="$REGW" \
  CORRIDA_WORKER_BIN_CLAUDE="$T/bin/worker-ok" bash "$CORR" preflight t-nat-ok 2>&1)
printf '%s\n' "$out" | head -1 | grep -q '^APTO' || fail "con un worker sano debio dar APTO: $out"
printf '%s' "$out" | grep -q 'sin trabajador compatible' \
  && fail "un worker sano debio contar como apto: $out"

abrir t-nat-muerto "$RB"
out=$(CORRIDA_NATIVE_ROUTING=report CORRIDA_WORKER_PY="$WPY_REAL" CORRIDA_WORKERS_REGISTRY="$REGW" \
  CORRIDA_WORKER_BIN_CLAUDE="$T/bin/worker-muerto" bash "$CORR" preflight t-nat-muerto 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con el unico worker muerto debio dar NO APTO: $out"
printf '%s' "$out" | grep -q 'sin trabajador compatible' \
  || fail "NO APTO sin la razon de sin trabajador compatible: $out"

abrir t-nat-sinpy "$RB"
out=$(CORRIDA_NATIVE_ROUTING=report CORRIDA_WORKER_PY="$T/bin/no-existe.py" CORRIDA_WORKERS_REGISTRY="$REGW" \
  bash "$CORR" preflight t-nat-sinpy 2>&1)
printf '%s\n' "$out" | head -1 | grep -q '^APTO' \
  || fail "con el arnes ilegible el veredicto no cambia: $out"
printf '%s' "$out" | grep -q 'sondas nativas sin medir' \
  || fail "sin el arnes de workers debio quedar unknown explicito: $out"

# 14.7 F2 (decision de David, 2026-09-27): preflight cruza la tabla de modos
# con el registro de workers. La barra de un binario seleccionable (uno que el
# registro puede arrancar) sin medir es razon de NO APTO: verde implica que
# adaptador start puede arrancar. Un worker futuro agregado al registro sin
# fila en la tabla tambien bloquea. Las filas legacy fuera del registro no
# bloquean el verde (siguen como unknown explicito).
REGF2="$T/workers-f2.json"
python3 - "$REGF2" <<'PY'
import json, sys
ws = [{"id": b, "binary": b} for b in ("claude", "codex", "zcode", "kimi", "grok")]
json.dump({"schema": "workers.v1", "max_external_sessions": 4, "workers": ws},
          open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
for b in claude codex zcode kimi grok; do
  cp "$T/bin/cli-ok" "$T/bin/$b" || fail "sin stub de $b"
done
modos_f2() { # $1 flag de claude, $2 barra de claude; las otras cuatro filas verdes.
  # Columna 1 = el seleccionable que cruza el registro; columna 2 = binario de
  # mentira: los reales estan instalados en esta Mac y bin_de_tabla los
  # resuelve antes que los stubs (medido en el primer rojo: codex real con
  # flag "x" dio "flag no entra").
  rm -f "$T/m.tsv"
  printf 'claude\tcli-ok\t%s\t%s\t--\t--\t--\n' "$1" "$2" >>"$T/m.tsv"
  local b
  for b in codex zcode kimi grok; do
    printf '%s\tcli-ok\tx\tBAR-OK-9\t--\t--\t--\n' "$b" >>"$T/m.tsv"
  done
}
export CORRIDA_WORKERS_REGISTRY="$REGF2"

# F2-a: barra de claude sin medir (flag tambien unknown, como la tabla real de
# hoy) => NO APTO con la razon de la barra.
modos_f2 unknown unknown
abrir t-f2-claude "$RB"
out=$(bash "$CORR" preflight t-f2-claude 2>&1); rc=$?
[ $rc -ne 0 ] || fail "F2: la barra de un seleccionable sin medir debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "barra de claude sin medir" || fail "F2: NO APTO sin la razon de la barra sin medir:
$out"

# F2-b: las cinco barras medidas => APTO (verde ahora dice que se puede arrancar).
modos_f2 x BAR-OK-9
abrir t-f2-verde "$RB"
out=$(bash "$CORR" preflight t-f2-verde 2>&1); rc=$?
[ $rc -eq 0 ] || fail "F2: con las cinco barras medidas debio dar APTO:
$out"

# F2-c (mutacion in-suite del contrato): volver la barra de claude a unknown,
# con el flag ya medido, => NO APTO otra vez.
modos_f2 x unknown
abrir t-f2-mut "$RB"
out=$(bash "$CORR" preflight t-f2-mut 2>&1); rc=$?
[ $rc -ne 0 ] || fail "F2: la mutacion barra->unknown debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "barra de claude sin medir" || fail "F2: la mutacion no cayo por la razon de la barra:
$out"

# F2-d: worker futuro en el registro sin fila en la tabla => NO APTO.
python3 - "$REGF2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["workers"].append({"id": "futuro", "binary": "futuro"})
json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
modos_f2 x BAR-OK-9
abrir t-f2-futuro "$RB"
out=$(bash "$CORR" preflight t-f2-futuro 2>&1); rc=$?
[ $rc -ne 0 ] || fail "F2: un worker futuro sin fila en la tabla debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "sin fila en la tabla de modos: futuro" || fail "F2: NO APTO sin la razon del worker futuro:
$out"

# restaurar el registro sin el worker futuro: el caso legacy necesita el
# registro limpio de cinco seleccionables.
python3 - "$REGF2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["workers"] = [w for w in d["workers"] if w.get("binary") != "futuro"]
json.dump(d, open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY

# F2-e: una fila legacy (deepseek) fuera del registro no bloquea el verde y
# queda como unknown explicito.
modos_f2 x BAR-OK-9
printf 'deepseek\tcli-ok\tunknown\tunknown\t--\t--\t--\n' >>"$T/m.tsv"
abrir t-f2-legacy "$RB"
out=$(bash "$CORR" preflight t-f2-legacy 2>&1); rc=$?
[ $rc -eq 0 ] || fail "F2: una fila legacy fuera del registro no debe bloquear el verde:
$out"
printf '%s' "$out" | grep -q "flag de deepseek sin medir" || fail "F2: la fila legacy debio quedar como unknown explicito:
$out"
# F2-f: barra doble-guion en un seleccionable es "sin medir" (el adaptador
# la rechaza igual que unknown: adaptador.sh, caso unknown|--); no puede dar
# APTO ni caer por "flag no entra".
rm -f "$T/m.tsv"
printf 'claude\tcli-ok\tx\t--\t--\t--\t--\n' >>"$T/m.tsv"
for b in codex zcode kimi grok; do
  printf '%s\tcli-ok\tx\tBAR-OK-9\t--\t--\t--\n' "$b" >>"$T/m.tsv"
done
abrir t-f2-dash "$RB"
out=$(bash "$CORR" preflight t-f2-dash 2>&1); rc=$?
[ $rc -ne 0 ] || fail "F2-f: la barra doble-guion de un seleccionable debio dar NO APTO:
$out"
printf '%s' "$out" | grep -q "barra de claude sin medir" || fail "F2-f: la barra doble-guion no cayo por sin medir:
$out"

# F2-g: una fila legacy con flag y barra MEDIDOS cuyo binario (columna 2) ya
# no esta en el registro (la forma del defecto cursor-agent, observado en vivo
# 2026-09-29 como NO APTO "flag no entra: cursor-agent") no se lanza: queda
# como legacy explicita y el verde se mantiene. Sin el arreglo el binario de
# mentira muere al arrancar y el preflight da NO APTO por una CLI que nadie
# selecciona. La fila cuyo binario SI esta en el registro se sigue lanzando.
REGL="$T/workers-legacy.json"
python3 - "$REGL" <<'PY'
import json, sys
ws = [{"id": "ok", "binary": "cli-ok"}]
json.dump({"schema": "workers.v1", "max_external_sessions": 4, "workers": ws},
          open(sys.argv[1], "w"), indent=1, sort_keys=True)
PY
: > "$ARGV_LOG"
rm -f "$T/m.tsv"
printf 'cli-ok\tcli-ok\tx\tBAR-OK-9\t--\t--\t--\n' >>"$T/m.tsv"
printf 'legado\tcli-muere\t--flag-legado-9\tBAR-OK-9\t--\t--\t--\n' >>"$T/m.tsv"
abrir t-f2leg "$RB"
out=$(CORRIDA_WORKERS_REGISTRY="$REGL" bash "$CORR" preflight t-f2leg 2>&1); rc=$?
[ $rc -eq 0 ] || fail "F2-g: la fila legacy fuera del registro debio seguir APTO:
$out"
printf '%s' "$out" | grep -q "fila legacy fuera del registro: legado" \
  || fail "F2-g: la fila legacy no quedo como unknown explicito:
$out"
grep -q -- "--flag-legado-9" "$ARGV_LOG" \
  && fail "F2-g: el binario legacy se lanzo (su flag llego al argv)"
grep -q "new-session.*preflight-t-f2leg-legado" "$T/tmux-llamadas.log" \
  && fail "F2-g: se creo la sesion tmux de la fila legacy"
grep -q "new-session.*preflight-t-f2leg-cli-ok" "$T/tmux-llamadas.log" \
  || fail "F2-g: la fila del registro dejo de lanzarse"
grep -q "^x$" "$ARGV_LOG" || fail "F2-g: el flag de la fila del registro no llego al binario"
unset CORRIDA_WORKERS_REGISTRY

kill "$VPID" 2>/dev/null
wait "$VPID" 2>/dev/null
echo "TODO VERDE: test-corrida-preflight"

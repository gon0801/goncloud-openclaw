#!/bin/bash
# 9.3 preflight: lo que fallo esa noche se prueba antes de arrancar. Stubs para
# gh/openclaw, tmux propio (-L), CLIs de mentira, vigilante de mentira. Ninguna
# prueba toca la red real ni sesiones del usuario.
# Uso: bash scripts/tests/test-corrida-preflight.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba"

T=$(mktemp -d) || exit 1
L="preflight$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ses" "$T/wbin"

# CLIs de mentira.
cat >"$T/bin/cli-ok" <<'CLI'
#!/bin/sh
echo "BAR-OK-9"
sleep 30
CLI
cat >"$T/bin/cli-muere" <<'CLI'
#!/bin/sh
exit 3
CLI
cat >"$T/bin/cli-flag-malo" <<'CLI'
#!/bin/sh
echo "BAR-OTRA"
sleep 30
CLI
chmod +x "$T/bin"/cli-ok "$T/bin/cli-muere" "$T/bin/cli-flag-malo"

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
# openclaw de mentira: gateway, dry-run y crons.
LLAMADAS="$T/llamadas.log"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ list*) printf '{"jobs":[{"name":"verif-sync-repos","delivery":{"to":"DESTINO-PRE-9X"}}]}';;
  *cron\ add*) printf '{"id":"cron-1"}';;
  *cron\ rm*) printf '{}';;
  *gateway\ call\ status*) printf '{"ok":true}';;
  *message\ send*) printf '{"messageId":"m1"}';;
esac
exit 0
STUB
chmod +x "$T/bin/gh" "$T/bin/openclaw"

# tmux con servidor propio.
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" REPO_DIR="$PWD"
export OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim" GH_BIN="$T/bin/gh"
export WATCH_INSTALADO="$T/wbin/tmux-activity-watch.sh"

# Vigilante de mentira: instalado = blob real del repo, proceso con su nombre.
cp scripts/mac/tmux-activity-watch.sh "$WATCH_INSTALADO"
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

# VERDE con todo sano.
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-ok scripts/tests/fixtures/corrida/runbook-simulacro.md
out=$(bash "$CORR" preflight t-ok) || fail "preflight sano debio dar APTO:
$out"
[ "$(printf '%s' "$out" | head -1)" = "APTO" ] || fail "primera linea distinta de APTO:
$out"

# ROJO con gh en 401.
export GH_MODO=mal
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-gh scripts/tests/fixtures/corrida/runbook-simulacro.md
out=$(bash "$CORR" preflight t-gh 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con gh en 401 debio dar NO APTO"
printf '%s' "$out" | head -1 | grep -q "^NO APTO" || fail "sin NO APTO con gh en 401:
$out"
printf '%s' "$out" | grep -q "gh" || fail "NO APTO sin razon de gh:
$out"
grep -q "DETENIDA" "$T/corridas/t-gh/mensajes.jsonl" || fail "NO APTO no mando mensaje"
unset GH_MODO

# ROJO con binario que muere.
modos x muere cli-muere "--flag-9" "BAR-OK-9"
abrir t-muere scripts/tests/fixtures/corrida/runbook-simulacro.md
out=$(bash "$CORR" preflight t-muere 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con binario que muere debio dar NO APTO"
printf '%s' "$out" | grep -q "muere" || fail "NO APTO sin razon del binario:
$out"

# ROJO con flag que no entra.
modos x mal cli-flag-malo "--flag-malo-9" "BAR-OK-9"
abrir t-flag scripts/tests/fixtures/corrida/runbook-simulacro.md
out=$(bash "$CORR" preflight t-flag 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con flag que no entra debio dar NO APTO"
printf '%s' "$out" | grep -q "flag no entra" || fail "NO APTO sin razon del flag:
$out"

# ROJO con vigilante viejo.
printf '# linea ajena\n' >>"$WATCH_INSTALADO"
modos x ok cli-ok "--flag-ok-9" "BAR-OK-9"
abrir t-viejo scripts/tests/fixtures/corrida/runbook-simulacro.md
out=$(bash "$CORR" preflight t-viejo 2>&1); rc=$?
[ $rc -ne 0 ] || fail "con vigilante viejo debio dar NO APTO"
printf '%s' "$out" | grep -q "vigilante viejo" || fail "NO APTO sin razon del vigilante:
$out"

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

kill $VPID 2>/dev/null
echo "TODO VERDE: test-corrida-preflight"

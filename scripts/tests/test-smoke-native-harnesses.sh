#!/bin/bash
# 14.7 Task 10 Step 1: humos en falso del driver de humos nativos. Stubs para
# las seis CLIs (doble fake del harness), openclaw y tmux propios (-L). El
# driver debe: crear repo desechable desde origin/main, entregar la edicion
# minima, observar transcripcion y completion, archivar evidencia redactada
# (ningun token en pantalla), cerrar tmux y la corrida, y salir != 0 si omite
# un worker pedido. Ninguna prueba toca la red real ni sesiones del usuario.
# Uso: bash scripts/tests/test-smoke-native-harnesses.sh
set -u
# Bajo el hook de pre-commit las ordenes git escaparian al repo real.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

DRIVER=scripts/mac/smoke-native-harnesses.sh
[ -f "$DRIVER" ] || fail "falta el driver $DRIVER"

TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba"

T=$(mktemp -d) || exit 1
L="smoke$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/corridas" "$T/argv"

# Remoto desechable: repo de mentira con main y origin/main en el mismo SHA.
OSHA="$(git -C "$T" init -q -b main origin 2>/dev/null && git -C "$T/origin" rev-parse --verify -q HEAD || true)"
git -C "$T/origin" -c user.email=t@t -c user.name=t commit -qm semilla --allow-empty
printf 'base\n' >"$T/origin/README.md"
git -C "$T/origin" add -A
git -C "$T/origin" -c user.email=t@t -c user.name=t commit -qm base
OSHA="$(git -C "$T/origin" rev-parse HEAD)"

# Dobles de las seis CLIs: el mismo fake del contrato del adaptador.
FAKE=scripts/tests/fixtures/harness/fake-native-cli.sh
[ -f "$FAKE" ] || fail "falta $FAKE"
for b in claude codex zcode kimi cursor-agent grok; do
  cp "$FAKE" "$T/bin/$b" || fail "sin doble $b"
done
chmod +x "$T/bin/"*
# claude envuelve al doble y suelta un token con forma real en pantalla: la
# evidencia redactada no puede contenerlo.
mv "$T/bin/claude" "$T/bin/.claude-doble"
cat >"$T/bin/claude" <<STUB
#!/bin/sh
printf 'credencial de prueba ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n'
exec "$T/bin/.claude-doble" "\$@"
STUB
chmod +x "$T/bin/claude"

# Tabla de modos y registro: los binarios reales del registro resuelven a los
# dobles por CORRIDA_WORKER_BIN_<ID> (los reales de la Mac no se tocan).
printf 'recibido\n' >"$T/brief-marker.txt"
for b in claude codex zcode kimi cursor-agent grok; do
  printf '%s\t%s\t--fake-9\tFAKE-BARRA-9\t--\t--\t--\n' "$b" "$b" >>"$T/modos.tsv"
done

# openclaw de mentira: cron list para abrir, gateway y envio OK.
cat >"$T/bin/openclaw" <<'STUB'
#!/bin/sh
case "$*" in
  *cron\ list*) printf '{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"DESTINO-SMOKE-9X"}}]}';;
  *cron\ rm*) printf '{}';;
  *gateway\ call\ status*) printf '{"ok":true}';;
  *message\ send*) printf '{"messageId":"m1"}';;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"

# tmux con servidor propio.
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim"
export OPENCLAW_BIN="$T/bin/openclaw" CORRIDA_CLI_MODOS="$T/modos.tsv"
export FAKE_ARGV_DIR="$T/argv" FAKE_BAR="FAKE-BARRA-9" FAKE_HARNESS_MODE=complete
export CORRIDA_WORKER_BIN_CLAUDE_FABLE="$T/bin/claude" CORRIDA_WORKER_BIN_CODEX="$T/bin/codex" \
  CORRIDA_WORKER_BIN_ZCODE="$T/bin/zcode" CORRIDA_WORKER_BIN_KIMI_CODING="$T/bin/kimi" \
  CORRIDA_WORKER_BIN_CURSOR="$T/bin/cursor-agent" CORRIDA_WORKER_BIN_GROK="$T/bin/grok"

sin_humos() { # ningun resto de sesion del driver en el server de prueba
  if "$TM_REAL" -L "$L" list-sessions -F '#{session_name}' 2>/dev/null | grep -q '^smoke-'; then
    return 1
  fi
  return 0
}

chequea_evidencia() { # $1 dir de evidencia; contratos transversales
  local ev="$1" w
  for w in claude codex zcode kimi cursor grok; do
    [ -f "$ev/$w/resultado.json" ] || fail "sin resultado.json de $w"
    [ -f "$ev/$w/pantalla.txt" ] || fail "sin transcripcion de $w"
    grep -q "RECIBIDO: humo $w" "$ev/$w/pantalla.txt" \
      || fail "la transcripcion de $w no prueba la entrega:
$(head -5 "$ev/$w/pantalla.txt")"
    grep -qF 'ADAPTADOR-MARCA: completo' "$ev/$w/pantalla.txt" \
      || fail "la transcripcion de $w no prueba el evento de completion"
    grep -q "FAKE-BARRA-9" "$ev/$w/pantalla.txt" \
      || fail "la transcripcion de $w no muestra la barra"
  done
  grep -rq "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456" "$ev" \
    && fail "un token con forma real sobrevivio en la evidencia"
  grep -q "\[REDACTADO\]" "$ev/claude/pantalla.txt" \
    || fail "el token no quedo redactado en la transcripcion de claude"
  grep -q "RECIBIDO" "$ev/resumen.json" \
    && fail "el resumen lleva transcripcion, no el registro de version/outcome/duracion/archivo"
  python3 - "$ev/resumen.json" <<'PY' || fail "el resumen no pasa el contrato"
import json, sys
d = json.load(open(sys.argv[1]))
rs = d["resultados"]
assert len(rs) == 6, rs
for r in rs:
    assert r["outcome"] == "passed", r
    assert r["version"].strip(), r
    assert isinstance(r["duracion_seg"], int), r
    assert r["archivo"], r
    assert all(r["chequeos"][k] for k in
               ("arranque", "auth", "entrega", "transcripcion", "completitud", "parada")), r
PY
}

# RUN 1: los seis con dobles sanos => rc 0, seis passed, evidencia redactada,
# repo desechable desde origin/main, tmux y corridas cerradas.
out="$(bash "$DRIVER" --worker all --repo "$T/origin" --evidence-dir "$T/ev" 2>&1)"; rc=$?
[ $rc -eq 0 ] || fail "con los seis dobles sanos el driver debio salir 0:
$out"
grep -q "humo claude: passed" <<<"$out" || fail "sin linea de resultado de claude:
$out"
chequea_evidencia "$T/ev"
[ "$(git -C "$T/ev/repo-claude" rev-parse HEAD 2>/dev/null)" = "$OSHA" ] \
  || fail "el repo desechable de claude no esta en origin/main del remoto"
python3 - "$T/corridas" <<'PY' || fail "las corridas de humo no quedaron cerradas"
import glob, json, sys
regs = glob.glob(sys.argv[1] + "/smoke-*/registro.json")
assert len(regs) == 6, regs
for r in regs:
    assert json.load(open(r))["estado"] == "cerrada", r
PY
sin_humos || fail "el driver dejo sesiones de tmux vivas (run 1)"

# RUN 2: sin binario de grok => rc != 0, grok unavailable, cinco passed, y las
# seis filas igual escritas (un omittedo jamas cuenta como passed).
rm -f "$T/bin/grok"
out="$(bash "$DRIVER" --worker all --repo "$T/origin" --evidence-dir "$T/ev2" 2>&1)"; rc=$?
[ $rc -ne 0 ] || fail "con grok sin binario el driver debio salir distinto de 0:
$out"
python3 - "$T/ev2/resumen.json" <<'PY' || fail "el resumen del run 2 no pasa"
import json, sys
d = json.load(open(sys.argv[1]))
por = {r["worker"]: r for r in d["resultados"]}
assert len(por) == 6, por
assert por["grok"]["outcome"] == "unavailable", por["grok"]
for w in ("claude", "codex", "zcode", "kimi", "cursor"):
    assert por[w]["outcome"] == "passed", por[w]
PY
sin_humos || fail "el driver dejo sesiones de tmux vivas (run 2)"

# RUN 3: seleccion explicita de un worker => rc 0 con una sola fila.
out="$(bash "$DRIVER" --worker kimi --repo "$T/origin" --evidence-dir "$T/ev3" 2>&1)"; rc=$?
[ $rc -eq 0 ] || fail "con seleccion explicita de kimi el driver debio salir 0:
$out"
python3 - "$T/ev3/resumen.json" <<'PY' || fail "el resumen del run 3 no pasa"
import json, sys
d = json.load(open(sys.argv[1]))
assert [r["worker"] for r in d["resultados"]] == ["kimi"], d
assert d["resultados"][0]["outcome"] == "passed", d
PY

echo "TODO VERDE: test-smoke-native-harnesses"

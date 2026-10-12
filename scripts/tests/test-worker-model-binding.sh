#!/bin/bash
# worker_argv entrega la argv una por linea y el adaptador la relee con
# `read`: un caracter de control dentro de un argumento (del registro o de un
# marcador sustituido) lo parte y el worker arranca con otro modelo. Origen: #247.
# Uso: bash scripts/tests/test-worker-model-binding.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

argv() { # $1 registro $2 worker $3 clave $4 worktree; stdout argv; rc de worker_argv
  CORRIDA_WORKERS_REGISTRY="$1" bash -c '. scripts/mac/corrida/lib.sh; worker_argv "$1" "$2" "$3" brief ses ses' _ "$2" "$3" "$4"
}

got="$(argv scripts/mac/workers.v1.json claude_opus start:write /tmp/wt)" \
  || fail "worker_argv rechazo el registro real"
want="$(printf '%s\n' --model claude-opus-5-5 --effort xhigh --permission-mode acceptEdits)"
[ "$got" = "$want" ] || fail "argv de claude_opus distinto: $got"

got="$(argv scripts/mac/workers.v1.json grok start:write /tmp/wt)" \
  || fail "worker_argv rechazo un worktree normal"
want="$(printf '%s\n' --reasoning-effort high --allow /tmp/wt)"
[ "$got" = "$want" ] || fail "argv de grok distinto: $got"

for sep in '\n' '\r' '\t' '\x7f' '\x00'; do
  python3 - "$T/reg.json" "$sep" <<'PY'
import json, sys
reg = json.load(open("scripts/mac/workers.v1.json"))
sep = sys.argv[2].encode().decode("unicode_escape")
cmd = next(w for w in reg["workers"] if w["id"] == "claude_opus")["commands"]["start:write"]
i = cmd.index("--model")
cmd[i:i + 2] = ["--model" + sep + "wrong"]
json.dump(reg, open(sys.argv[1], "w"))
PY
  out="$(python3 scripts/mac/corrida-worker.py registry validate --registry "$T/reg.json")"
  [ "$out" = "ERROR invalid command" ] || fail "registry validate acepto --model${sep}wrong: $out"
  if got="$(argv "$T/reg.json" claude_opus start:write /tmp/wt)"; then
    fail "worker_argv acepto --model${sep}wrong: $(printf '%s' "$got" | tr '\n' ' ')"
  fi
  [ -z "$got" ] || fail "worker_argv emitio argv parcial con --model${sep}wrong"
done

for wt in "$(printf '/tmp/wt\n--model\nwrong')" "$(printf '/tmp/wt\rx')" "$(printf '/tmp/wt\tx')"; do
  if got="$(argv scripts/mac/workers.v1.json grok start:write "$wt")"; then
    fail "worker_argv acepto un worktree con caracter de control: $(printf '%s' "$got" | tr '\n' ' ')"
  fi
  [ -z "$got" ] || fail "worker_argv emitio argv parcial con worktree de control"
done

python3 - "$T/eff.json" <<'PY'
import json, sys
reg = json.load(open("scripts/mac/workers.v1.json"))
next(w for w in reg["workers"] if w["id"] == "grok")["effort"] = "high\n--model\nwrong"
json.dump(reg, open(sys.argv[1], "w"))
PY
if got="$(argv "$T/eff.json" grok start:write /tmp/wt)"; then
  fail "worker_argv acepto un effort con salto de linea: $(printf '%s' "$got" | tr '\n' ' ')"
fi

echo "PASS test-worker-model-binding"

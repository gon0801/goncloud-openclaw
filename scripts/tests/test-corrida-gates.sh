#!/bin/bash
# Task 6: compuertas de calidad por SHA con evidencia persistente.
# La compuerta relee el PR autoritativo y valida contra el contrato del kit
# instalado (doble de test con la misma interfaz); jamas inventa otra
# aprobacion. La indisponibilidad declarada de un bot no es aprobacion.
# Uso: bash scripts/tests/test-corrida-gates.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
PW=scripts/mac/corrida-worker.py
FIX=scripts/tests/fixtures/gates
KIT="$FIX/kit"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/corridas" "$T/wt"
git init -q -b main "$T/wt" 2>/dev/null || fail "sin worktree"
export CORRIDA_STATE="$T/corridas" SAIKIT_KIT_DIR="$KIT"
unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

# gh falso: sirve los comentarios y el PR del fixture apuntado por env.
cat >"$T/bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *issues/*/comments*) cat "${GH_COMMENTS:?sin GH_COMMENTS}";;
  *pr\ view*) cat "${GH_PR:?sin GH_PR}";;
  *) echo "gh falso: $*" >&2; exit 1;;
esac
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# shellcheck disable=SC1091
. "$KIT/tools/lib/entrega_contract.sh" || fail "el doble del kit no carga"

materializar() { # $1 fixture $2 dir
  python3 - "$FIX/$1" "$2" "$T/wt" <<'PY' || fail "no se materializo $1"
import json,sys,os
d = json.load(open(sys.argv[1]))
os.makedirs(sys.argv[2], exist_ok=True)
rec = json.loads(json.dumps(d["record"]).replace("@WT@", sys.argv[3]))
json.dump(rec, open(os.path.join(sys.argv[2], "record.json"), "w"), sort_keys=True)
json.dump(d["evidence"], open(os.path.join(sys.argv[2], "evidence.json"), "w"), sort_keys=True)
json.dump(d["comments"], open(os.path.join(sys.argv[2], "comments.json"), "w"))
json.dump(d["pr"], open(os.path.join(sys.argv[2], "pr.json"), "w"), sort_keys=True)
json.dump(d["pr_gh"], open(os.path.join(sys.argv[2], "pr-gh.json"), "w"))
json.dump({"action": d["action"], "sha": d["sha"], "expect": d["expect"]},
          open(os.path.join(sys.argv[2], "meta.json"), "w"), sort_keys=True)
PY
}

# (1) El doble del kit habla la interfaz soportada: halla, revoca, ausenta y
# valida con los mismos codigos y prefijo que el contrato real.
materializar 01-merge-ok.json "$T/k1"
export GH_COMMENTS="$T/k1/comments.json" GH_PR="$T/k1/pr.json"
H="$(python3 -c "import json; print(json.load(open('$T/k1/meta.json'))['sha'])")"
entrega_recibo_del_pr "o/r" 7 "$H" >"$T/k1/recibo.json" \
  || fail "el doble no hallo el recibo valido"
entrega_validar "$T/k1/recibo.json" "o/r" 7 "$H" \
  || fail "el doble no valido el recibo valido"
materializar 02-merge-sin-recibo.json "$T/k2"
export GH_COMMENTS="$T/k2/comments.json"
entrega_recibo_del_pr "o/r" 7 "$H" >"$T/k2/recibo.json" 2>"$T/k2/err" \
  && fail "el doble hallo un recibo ausente"
grep -q '^recibo: sin recibo' "$T/k2/err" || fail "sin-recibo: $(cat "$T/k2/err")"
materializar 03-merge-revocado.json "$T/k3"
export GH_COMMENTS="$T/k3/comments.json"
entrega_recibo_del_pr "o/r" 7 "$H" >"$T/k3/recibo.json" 2>"$T/k3/err" \
  && fail "el doble hallo un recibo revocado"
grep -q '^recibo: revocado' "$T/k3/err" || fail "revocado: $(cat "$T/k3/err")"
materializar 08-merge-revisor-autor.json "$T/k8"
export GH_COMMENTS="$T/k8/comments.json"
entrega_recibo_del_pr "o/r" 7 "$H" >"$T/k8/recibo.json" \
  || fail "el doble no hallo el recibo con autor"
entrega_validar "$T/k8/recibo.json" "o/r" 7 "$H" 2>"$T/k8/err" \
  && fail "el doble valido identidad reutilizada"
grep -q 'identidad reutilizada' "$T/k8/err" || fail "identidad: $(cat "$T/k8/err")"
python3 - "$T/k1/recibo.json" "$T/k1f.json" <<'PY' || fail "sin recibo FAIL"
import json,sys
r = json.load(open(sys.argv[1]))
r["verifier"]["resultado"] = "FAIL"
json.dump(r, open(sys.argv[2], "w"))
PY
entrega_validar "$T/k1f.json" "o/r" 7 "$H" 2>"$T/k1f.err" \
  && fail "el doble valido un verifier en FAIL"
grep -q 'distinto de PASS' "$T/k1f.err" || fail "FAIL: $(cat "$T/k1f.err")"
echo "ok (1): el doble del kit halla, revoca, ausenta y valida"

# Lee el recibo de un caso materializado con el doble. Deja receipt.json
# (vacio si no hay) y receipt.status con 0|1|3.
leer_recibo() { # $1 dir
  export GH_COMMENTS="$1/comments.json"
  local sha
  sha="$(python3 -c "import json; print(json.load(open('$1/meta.json'))['sha'])")"
  if entrega_recibo_del_pr "o/r" 7 "$sha" >"$1/receipt.json" 2>"$1/recibo.err"; then
    if entrega_validar "$1/receipt.json" "o/r" 7 "$sha" 2>"$1/recibo.err"; then
      printf '0' >"$1/receipt.status"
    else
      printf '1' >"$1/receipt.status"
    fi
  else
    : >"$1/receipt.json"
    printf '1' >"$1/receipt.status"
  fi
}

# (2) Tabla python pura: cada fixture da su veredicto y codigo literales.
for fx in 01-merge-ok 02-merge-sin-recibo 03-merge-revocado 04-merge-otro-sha \
    05-merge-ci-rojo 06-merge-ci-ausente 07-merge-ci-stale 08-merge-revisor-autor \
    09-merge-bloqueante 10-merge-bot-declarado 11-merge-bot-pendiente \
    12-merge-reanuda-recibo 13-merge-residual 14-pushpr-delta-ok \
    15-pushpr-mismo-revisor 16-merge-bloqueante-repetido 17-merge-rebase-mecanico \
    18-deploy-mapea 19-canary-registra 20-rollback-sin-verificar \
    21-rollback-verificado 22-crossreview-autor 23-pushpr-sin-review \
    24-deploy-sin-merge 25-merge-kit-rechaza 26-merge-bot-stale 27-merge-autor-evidencia; do
  materializar "$fx.json" "$T/py-$fx"
  leer_recibo "$T/py-$fx"
  meta_accion="$(python3 -c "import json; print(json.load(open('$T/py-$fx/meta.json'))['action'])")"
  meta_sha="$(python3 -c "import json; print(json.load(open('$T/py-$fx/meta.json'))['sha'])")"
  python3 "$PW" gate --record "$T/py-$fx/record.json" --lane l1 \
    --action "$meta_accion" --sha "$meta_sha" \
    --evidence "$T/py-$fx/evidence.json" --receipt "$T/py-$fx/receipt.json" \
    --receipt-status "$(cat "$T/py-$fx/receipt.status")" \
    --receipt-error "$(cat "$T/py-$fx/recibo.err")" \
    --pr "$T/py-$fx/pr.json" >"$T/py-$fx/out.json" \
    || fail "$fx: gate rechazo la entrada"
  got="$(python3 -c "import json; d=json.load(open('$T/py-$fx/out.json')); print(d['verdict']+' '+d['code'])")"
  exp="$(python3 -c "import json; d=json.load(open('$FIX/$fx.json'))['expect']; print(d['verdict']+' '+d['code'])")"
  [ "$got" = "$exp" ] || fail "$fx: dio [$got], esperado [$exp]"
  python3 - "$T/py-$fx/out.json" <<'PY' || fail "$fx: proyeccion incompleta"
import json,sys
p = json.load(open(sys.argv[1]))["projection"]
for k in ("source_url", "repo", "pr", "reviewed_sha", "result", "availability"):
    assert p.get(k) not in (None, ""), (k, p)
PY
done
echo "ok (2): los 27 fixtures dan su veredicto y codigo"

# (3) Extremo a extremo: compuerta.sh relee el PR falso, valida con el kit,
# decide, registra el evento y proyecta sin sustituir el recibo.
for fx in 01-merge-ok 02-merge-sin-recibo 03-merge-revocado 04-merge-otro-sha \
    05-merge-ci-rojo 06-merge-ci-ausente 07-merge-ci-stale 08-merge-revisor-autor \
    09-merge-bloqueante 10-merge-bot-declarado 11-merge-bot-pendiente \
    12-merge-reanuda-recibo 13-merge-residual 14-pushpr-delta-ok \
    15-pushpr-mismo-revisor 16-merge-bloqueante-repetido 17-merge-rebase-mecanico \
    18-deploy-mapea 19-canary-registra 20-rollback-sin-verificar \
    21-rollback-verificado 22-crossreview-autor 23-pushpr-sin-review \
    24-deploy-sin-merge 25-merge-kit-rechaza 26-merge-bot-stale 27-merge-autor-evidencia; do
  materializar "$fx.json" "$T/e2e-$fx"
  run="g-${fx%%-*}"
  mkdir -p "$T/corridas/$run"
  cp "$T/e2e-$fx/record.json" "$T/corridas/$run/registro.json"
  export GH_COMMENTS="$T/e2e-$fx/comments.json" GH_PR="$T/e2e-$fx/pr-gh.json"
  meta_accion="$(python3 -c "import json; print(json.load(open('$T/e2e-$fx/meta.json'))['action'])")"
  meta_sha="$(python3 -c "import json; print(json.load(open('$T/e2e-$fx/meta.json'))['sha'])")"
  exp_verdict="$(python3 -c "import json; print(json.load(open('$FIX/$fx.json'))['expect']['verdict'])")"
  if bash "$CORR" compuerta "$run" l1 "$meta_accion" --sha "$meta_sha" \
      --evidence "$T/e2e-$fx/evidence.json" >"$T/e2e-$fx.out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$exp_verdict" = "allow" ]; then
    [ "$rc" -eq 0 ] || fail "$fx e2e: salio $rc: $(cat "$T/e2e-$fx.out")"
    grep -q "^ALLOW $meta_accion " "$T/e2e-$fx.out" || fail "$fx e2e sin ALLOW"
  else
    [ "$rc" -eq 1 ] || fail "$fx e2e: salio $rc: $(cat "$T/e2e-$fx.out")"
    grep -q "^DENY $meta_accion " "$T/e2e-$fx.out" || fail "$fx e2e sin DENY"
  fi
  ev_kind="gate.allow"
  [ "$exp_verdict" = "allow" ] || ev_kind="gate.deny"
  python3 - "$T/corridas/$run/registro.json" "$ev_kind" <<'PY' || fail "$fx e2e sin evento $ev_kind"
import json,sys
evs = json.load(open(sys.argv[1]))["lanes"][0]["events"]
assert any(e["kind"] == sys.argv[2] for e in evs), [e["kind"] for e in evs]
PY
done
python3 - "$T/corridas/g-10/registro.json" <<'PY' || fail "10: la declaracion parece aprobacion"
import json,sys
evs = json.load(open(sys.argv[1]))["lanes"][0]["events"]
g = [e for e in evs if e["kind"] == "gate.allow"][0]
assert g["payload"]["projection"]["availability"] == "unavailable", g
assert g["payload"]["projection"]["result"] != "approved", g
PY
python3 - "$T/corridas/g-16/registro.json" <<'PY' || fail "16: el carril sigue vivo"
import json,sys
c = json.load(open(sys.argv[1]))["lanes"][0]
assert c["estado"] == "stopped", c["estado"]
PY
python3 - "$T/corridas/g-17/registro.json" <<'PY' || fail "17: sin correspondencia de rebase"
import json,sys
ev = json.load(open(sys.argv[1]))["lanes"][0]["evidence"]
rb = ev.get("rebase") or {}
assert rb.get("old_sha") == "4" * 40 and rb.get("new_sha") == "5" * 40, ev
PY
python3 - "$T/corridas/g-18/registro.json" <<'PY' || fail "18: sin mapeo de SHAs"
import json,sys
ev = json.load(open(sys.argv[1]))["lanes"][0]["evidence"]
dp = ev.get("deploy") or {}
assert dp.get("reviewed_head") == "1" * 40 and dp.get("merge_commit") == "2" * 40, ev
PY
echo "ok (3): compuerta.sh decide, registra y proyecta en 27 casos"

# (4) Entradas rotas y kit ausente: diagnostico y fail-closed.
materializar 01-merge-ok.json "$T/e4"
export GH_COMMENTS="$T/e4/comments.json" GH_PR="$T/e4/pr-gh.json"
H4="$(python3 -c "import json; print(json.load(open('$T/e4/meta.json'))['sha'])")"
mkdir -p "$T/corridas/g-err"
cp "$T/e4/record.json" "$T/corridas/g-err/registro.json"
bash "$CORR" compuerta g-err l1 volar --sha "$H4" --evidence "$T/e4/evidence.json" \
  >/dev/null 2>&1 && fail "compuerta acepto accion desconocida"
bash "$CORR" compuerta g-err l1 merge --sha "$H4" --evidence "$T/no-existe.json" \
  >/dev/null 2>&1 && fail "compuerta acepto evidencia ausente"
SAIKIT_KIT_DIR="$T/sin-kit" bash "$CORR" compuerta g-err l1 merge --sha "$H4" \
  --evidence "$T/e4/evidence.json" >"$T/e4.out" 2>&1 \
  && fail "merge sin kit dio allow"
grep -q '^DENY merge kit-no-disponible' "$T/e4.out" \
  || fail "sin kit: $(cat "$T/e4.out")"
# Ramas sueltas: compuertas de registro en allow, canary sin deploy y CI
# pendiente en deny. Derivan de 01 para no multiplicar fixtures.
veredicto_gate() { # $1 dir $2 accion -> "verdict code"
  python3 "$PW" gate --record "$1/record.json" --lane l1 --action "$2" \
    --sha "$H4" --evidence "$1/evidence.json" --receipt "$1/receipt.json" \
    --receipt-status "$(cat "$1/receipt.status")" --receipt-error "$(cat "$1/recibo.err")" --pr "$1/pr.json" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verdict']+' '+d['code'])"
}
materializar 01-merge-ok.json "$T/e4b"
leer_recibo "$T/e4b"
[ "$(veredicto_gate "$T/e4b" cross-review)" = "allow cross-review-ok" ] \
  || fail "cross-review allow"
[ "$(veredicto_gate "$T/e4b" ci)" = "allow ci-ok" ] || fail "ci allow"
[ "$(veredicto_gate "$T/e4b" coderabbit)" = "allow coderabbit-ok" ] \
  || fail "coderabbit allow"
materializar 10-merge-bot-declarado.json "$T/e4c"
leer_recibo "$T/e4c"
[ "$(veredicto_gate "$T/e4c" coderabbit)" = "allow coderabbit-ok" ] \
  || fail "coderabbit declarado allow"
materializar 19-canary-registra.json "$T/e4d"
python3 - "$T/e4d/record.json" <<'PY' || fail "sin delivery"
import json,sys
d = json.load(open(sys.argv[1]))
d["lanes"][0]["delivery"] = {}
json.dump(d, open(sys.argv[1], "w"))
PY
leer_recibo "$T/e4d"
H19="$(python3 -c "import json; print(json.load(open('$T/e4d/meta.json'))['sha'])")"
got19="$(python3 "$PW" gate --record "$T/e4d/record.json" --lane l1 --action canary \
  --sha "$H19" --evidence "$T/e4d/evidence.json" --receipt "$T/e4d/receipt.json" \
  --receipt-status "$(cat "$T/e4d/receipt.status")" --pr "$T/e4d/pr.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verdict']+' '+d['code'])")"
[ "$got19" = "deny sin-deploy" ] || fail "canary sin deploy: [$got19]"
python3 - "$T/e4b/evidence.json" <<'PY' || fail "sin ci pendiente"
import json,sys
d = json.load(open(sys.argv[1]))
d["ci"]["conclusion"] = "pending"
json.dump(d, open(sys.argv[1], "w"))
PY
[ "$(veredicto_gate "$T/e4b" merge)" = "deny ci-pendiente" ] \
  || fail "merge con CI pendiente"
python3 - "$T/e4d/evidence.json" <<'PY' || fail "sin canary failed"
import json,sys
d = json.load(open(sys.argv[1]))
d["canary"]["result"] = "failed"
json.dump(d, open(sys.argv[1], "w"))
PY
python3 - "$T/e4d/record.json" <<'PY' || fail "sin deploy"
import json,sys
d = json.load(open(sys.argv[1]))
d["lanes"][0]["delivery"] = {"deploy": {"sha": "2" * 40}}
json.dump(d, open(sys.argv[1], "w"))
PY
got_cf="$(python3 "$PW" gate --record "$T/e4d/record.json" --lane l1 --action canary \
  --sha "$H19" --evidence "$T/e4d/evidence.json" --receipt "$T/e4d/receipt.json" \
  --receipt-status "$(cat "$T/e4d/receipt.status")" \
  --receipt-error "$(cat "$T/e4d/recibo.err")" --pr "$T/e4d/pr.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verdict']+' '+d['code']+' '+d['projection']['result'])")"
[ "$got_cf" = "allow canary-ok failed" ] || fail "canary failed: [$got_cf]"
echo "ok (4): accion y evidencia rotas mueren; sin kit no hay merge"

# (5) Mutacion de compuertas: sin cada condicion, el fixture que la exige
# cambia de veredicto o codigo. Si un mutante da lo mismo que el original,
# la condicion no protege nada y el lazo queda rojo.
mkdir -p "$T/mut"
cp "$PW" "$T/mut/corrida-worker.py"
cp -r scripts/mac/corrida_worker "$T/mut/corrida_worker"
mutante() { # $1 nombre $2 patron-sed $3 fixture
  rm -rf "$T/mut/corrida_worker"
  cp -r scripts/mac/corrida_worker "$T/mut/corrida_worker"
  sed -i.bak "$2" "$T/mut/corrida_worker/gates.py" && rm -f "$T/mut/corrida_worker/gates.py.bak" \
    || fail "mutante $1 sin aplicar"
  cmp -s scripts/mac/corrida_worker/gates.py "$T/mut/corrida_worker/gates.py" \
    && fail "mutante $1: el patron no toco nada"
  materializar "$3.json" "$T/mut-$1"
  leer_recibo "$T/mut-$1"
  meta_accion="$(python3 -c "import json; print(json.load(open('$T/mut-$1/meta.json'))['action'])")"
  meta_sha="$(python3 -c "import json; print(json.load(open('$T/mut-$1/meta.json'))['sha'])")"
  orig="$(python3 -c "import json; d=json.load(open('$FIX/$3.json'))['expect']; print(d['verdict']+' '+d['code'])")"
  got="$(python3 "$T/mut/corrida-worker.py" gate --record "$T/mut-$1/record.json" \
    --lane l1 --action "$meta_accion" --sha "$meta_sha" \
    --evidence "$T/mut-$1/evidence.json" --receipt "$T/mut-$1/receipt.json" \
    --receipt-status "$(cat "$T/mut-$1/receipt.status")" \
    --receipt-error "$(cat "$T/mut-$1/recibo.err")" \
    --pr "$T/mut-$1/pr.json" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['verdict']+' '+d['code'])" 2>/dev/null || true)"
  [ "$got" != "$orig" ] || fail "mutante $1 sobrevivio (dio $got)"
}
mutante sin-recibo 's/if receipt is None:/if False and receipt is None:/' \
  02-merge-sin-recibo
mutante sin-ci 's/if ci is None:/if False and ci is None:/' \
  06-merge-ci-ausente
mutante sin-autor 's/reviewer in authors:/reviewer in []:/' \
  27-merge-autor-evidencia
mutante bot-aprueba 's/unavailable-declared/unavailable-declared-zzz/' \
  10-merge-bot-declarado
mutante sin-bloqueante 's/if open_blockers:/if False and open_blockers:/' \
  09-merge-bloqueante
echo "ok (5): cinco mutantes caen"

echo "TODO VERDE: corrida-gates"

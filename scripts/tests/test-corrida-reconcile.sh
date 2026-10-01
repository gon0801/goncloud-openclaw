#!/bin/bash
# Task 5: reducer persistente y reconciliacion idempotente tras reinicio.
# Python propone efectos y no ejecuta nada; reconciliar.sh ejecuta un efecto
# cerrado, registra y re-invoca. Cada crash fixture converge en dos
# invocaciones sin duplicar efectos; repetir la misma entrada da el mismo
# digest. Uso: bash scripts/tests/test-corrida-reconcile.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
. scripts/mac/corrida/lib.sh

# Completa un registro de fixture con los campos del contrato que los
# productores reales escriben (abrir), para que validar_registro juzgue solo
# lo que el caso mueve: los carriles y sus estados.
completar_registro() { # $1 reg $2 id $3 modos
  python3 - "$1" "$2" "$3" <<'PY' || fail "no se completo $1"
import json,sys
p,i,modos=sys.argv[1:4]
d=json.load(open(p))
d.setdefault("vigia","claw")
d["seguimiento_global"]=True
d.setdefault("runbook","loop-autopilot")
d.setdefault("canal",{"cron":"prueba","destino":"dest-prueba"})
d.setdefault("cli_modos",modos)
d.setdefault("inicio","2026-09-26T00:00:00+0000")
d.setdefault("simulacro",False)
d.setdefault("timebox_horas",6)
d.setdefault("sesiones",[])
d["id"]=i
json.dump(d,open(p,"w"),sort_keys=True,indent=2)
PY
}
registro_valido() { # $1 reg
  validar_registro "$1" >/dev/null 2>&1 \
    || fail "registro fuera de contrato $1: $(validar_registro "$1" 2>&1 | tr '\n' ' ')"
}

CORR=scripts/mac/corrida.sh
PW=scripts/mac/corrida-worker.py
FIX=scripts/tests/fixtures/reconcile
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba de reconciliacion"

T=$(mktemp -d) || exit 1
L="reconc$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/corridas" "$T/argv" "$T/wt" "$T/wt2"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_WORK_TREE GIT_NAMESPACE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

FAKE=scripts/tests/fixtures/harness/fake-native-cli.sh
[ -f "$FAKE" ] || fail "falta $FAKE"
for b in codex kimi; do cp "$FAKE" "$T/bin/$b" || fail "no se copio el doble $b"; done
chmod +x "$T/bin/"*
printf 'codex\tcodex\t--fake-9\tFAKE-BARRA-9\t--\t--\t--\n' >"$T/modos.tsv"
printf 'kimi\tkimi\t--fake-9\tFAKE-BARRA-9\t--\t--\t--\n' >>"$T/modos.tsv"
printf 'haz lo pedido y termina\n' >"$T/brief.txt"

cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

cat >"$T/bin/openclaw-stub" <<STUB
#!/bin/sh
printf '%s\\n' "OPENCLAW \$*" >> "$T/openclaw.log"
case "\$*" in
  *"message send"*) printf 'preambulo\\n{"messageId":"42"}\\n';;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw-stub"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim"
export OPENCLAW_BIN="$T/bin/openclaw-stub" FAKE_ARGV_DIR="$T/argv" FAKE_BAR="FAKE-BARRA-9"
export CORRIDA_WORKER_BIN_CODEX="$T/bin/codex" CORRIDA_WORKER_BIN_KIMI="$T/bin/kimi"
# Registro propio del arnes (ids codex/kimi): los fixtures de reconcile no
# dependen del registro real ni de su reparto por modelo (14.13).
export CORRIDA_WORKERS_REGISTRY="$PWD/scripts/tests/fixtures/reconcile/workers.json"

git init -q -b main "$T/wt" || fail "no se creo el worktree"
printf 'base\n' >"$T/wt/f.txt"
git -C "$T/wt" add f.txt && git -C "$T/wt" commit -qm base || fail "commit base"

# Materializa un fixture: sustituye @WT@/@WT2@/@MODOS@ y deja record.json,
# obs1.json y obs2.json bajo $2. Imprime la ruta del dir.
materializar() { # $1 fixture $2 dir
  python3 - "$FIX/$1" "$2" "$T/wt" "$T/wt2" "$T/modos.tsv" <<'PY' || fail "no se materializo $1"
import json,sys,os
fx, out, wt, wt2, modos = sys.argv[1:6]
d = json.load(open(fx))
os.makedirs(out, exist_ok=True)
txt = json.dumps(d)
txt = txt.replace("@WT2@", wt2).replace("@WT@", wt).replace("@MODOS@", modos)
d = json.loads(txt)
json.dump(d["record"], open(os.path.join(out, "record.json"), "w"), sort_keys=True, indent=2)
json.dump(d["obs1"], open(os.path.join(out, "obs1.json"), "w"), sort_keys=True, indent=2)
json.dump(d["obs2"], open(os.path.join(out, "obs2.json"), "w"), sort_keys=True, indent=2)
if "events" in d:
    json.dump(d["events"], open(os.path.join(out, "events.json"), "w"), sort_keys=True, indent=2)
PY
}

ops_de() { # $1 salida-reconcile -> ops una por linea
  python3 -c "import json,sys; [print(e['op']) for e in json.load(open(sys.argv[1]))['effects']]" "$1"
}

# Aplica los efectos propuestos como eventos (lo que reconciliar.sh hace al
# ejecutar): record_observed -> observed.<kind>; el resto -> intent.<op>.
aplicar_efectos() { # $1 salida-reconcile $2 record
  python3 - "$1" "$2" <<'PY' || fail "no se aplicaron efectos de $1"
import json,sys
out = json.load(open(sys.argv[1]))
evs = []
for e in out["effects"]:
    op = e["op"]
    if op == "record_observed":
        evs.append({"lane": e["lane"], "kind": "observed." + e["args"]["kind"], "payload": e["args"].get("payload", {})})
    else:
        evs.append({"lane": e["lane"], "kind": "intent." + op, "payload": e.get("args", {})})
json.dump(evs, open(sys.argv[1] + ".evs", "w"))
PY
  python3 "$PW" state reduce --record "$2" --events "$1.evs" >/dev/null \
    || fail "reduce de efectos propuestos ($1)"
}

# (1) Duplicados: el segundo reduce no cambia nada y el estado queda identico.
materializar 01-duplicate-events.json "$T/c01"
cp "$T/c01/record.json" "$T/c01/r.json"
got="$(python3 "$PW" state reduce --record "$T/c01/r.json" --events "$T/c01/events.json")" \
  || fail "state reduce rechazo eventos validos"
[ "$got" = "APPLIED 2 DUPLICATED 1" ] || fail "dedup: dio [$got]"
sha1="$(python3 -c "import hashlib; print(hashlib.sha1(open('$T/c01/r.json','rb').read()).hexdigest())")"
got="$(python3 "$PW" state reduce --record "$T/c01/r.json" --events "$T/c01/events.json")" \
  || fail "replay del reduce fallo"
[ "$got" = "APPLIED 0 DUPLICATED 3" ] || fail "replay: dio [$got]"
sha2="$(python3 -c "import hashlib; print(hashlib.sha1(open('$T/c01/r.json','rb').read()).hexdigest())")"
[ "$sha1" = "$sha2" ] || fail "el replay cambio el estado"
[ "$(stat -f %p "$T/c01/r.json" 2>/dev/null || stat -c %a "$T/c01/r.json")" != "*600*" ] || true
modo="$(python3 -c "import os; print(oct(os.stat('$T/c01/r.json').st_mode & 0o777))")"
[ "$modo" = "0o600" ] || fail "el registro quedo con modo $modo"
echo "ok (1): duplicados colapsan, el replay es byte-identico y el modo es 600"

# (2) Tabla python pura: inv1 propone lo esperado, inv2 con obs2 tambien, y el
# digest de la misma entrada no cambia entre llamadas.
for fx in 01-duplicate-events 02-vanished-session 03-push-exists 04-pr-exists \
    05-merge-exists 06-deploy-partial 07-failed-resumes-once 08-quota-skips-resume \
    09-auth-skips-resume 10-missing-binary-skips-resume 11-silent-alive-kept \
    12-predecessor-blocks 13-candidates-exhausted 14-repeated-launch-once \
    15-phase23-pending 16-test-failed-no-fallback 17-dirty-diff-survives \
    18-handoff-exhausted-stops 19-reservado-sin-sesion \
    20-successor-fails-again 21-blocked-by-reason; do
  materializar "$fx.json" "$T/py-$fx"
  cp "$T/py-$fx/record.json" "$T/py-$fx/r.json"
  if [ -f "$T/py-$fx/events.json" ]; then
    python3 "$PW" state reduce --record "$T/py-$fx/r.json" --events "$T/py-$fx/events.json" >/dev/null \
      || fail "$fx: reduce inicial"
  fi
  python3 "$PW" reconcile --record "$T/py-$fx/r.json" --observations "$T/py-$fx/obs1.json" >"$T/py-$fx/out1.json" \
    || fail "$fx: reconcile inv1 rechazo la entrada"
  python3 "$PW" reconcile --record "$T/py-$fx/r.json" --observations "$T/py-$fx/obs1.json" >"$T/py-$fx/out1b.json" \
    || fail "$fx: reconcile inv1b rechazo la entrada"
  d1="$(python3 -c "import json; print(json.load(open('$T/py-$fx/out1.json'))['digest'])")"
  d1b="$(python3 -c "import json; print(json.load(open('$T/py-$fx/out1b.json'))['digest'])")"
  [ "$d1" = "$d1b" ] || fail "$fx: el digest cambio entre llamadas identicas"
  cmp -s "$T/py-$fx/out1.json" "$T/py-$fx/out1b.json" || fail "$fx: la salida cambio entre llamadas identicas"
  ops1="$(ops_de "$T/py-$fx/out1.json" | tr '\n' ' ')"
  exp1="$(python3 -c "import json; print(' '.join(json.load(open('$FIX/$fx.json'))['expect_py1']))")"
  [ "$ops1" = "$exp1" ] || [ "$ops1" = "$exp1 " ] || fail "$fx inv1: ops [$ops1], esperadas [$exp1]"
  forb="$(python3 -c "import json; print(json.load(open('$FIX/$fx.json')).get('forbid_op') or json.load(open('$FIX/$fx.json')).get('forbid_op_py1') or '')")"
  if [ -n "$forb" ]; then
    ops_de "$T/py-$fx/out1.json" | grep -qx "$forb" && fail "$fx: propuso el op prohibido $forb"
  fi
  aplicar_efectos "$T/py-$fx/out1.json" "$T/py-$fx/r.json"
  if [ "$fx" = "14-repeated-launch-once" ]; then
    python3 "$PW" reconcile --record "$T/py-$fx/r.json" --observations "$T/py-$fx/obs1.json" >"$T/py-$fx/out1c.json" \
      || fail "$fx: reconcile inv1c fallo"
    o1c="$(ops_de "$T/py-$fx/out1c.json" | tr '\n' ' ')"
    [ "$o1c" = "launch_successor " ] || fail "$fx inv1c: ops [$o1c], esperada [launch_successor]"
    aplicar_efectos "$T/py-$fx/out1c.json" "$T/py-$fx/r.json"
  fi
  python3 "$PW" reconcile --record "$T/py-$fx/r.json" --observations "$T/py-$fx/obs2.json" >"$T/py-$fx/out2.json" \
    || fail "$fx: reconcile inv2 rechazo la entrada"
  ops2="$(ops_de "$T/py-$fx/out2.json" | tr '\n' ' ')"
  exp2="$(python3 -c "import json; print(' '.join(json.load(open('$FIX/$fx.json'))['expect_py2']))")"
  [ "$ops2" = "$exp2" ] || [ "$ops2" = "$exp2 " ] || fail "$fx inv2: ops [$ops2], esperadas [$exp2]"
done
echo "ok (2): los 21 fixtures proponen lo esperado y repiten byte-identico"
# (2b) 14.21 P1: orden del plan Task 5 Step 3: registry, tmux, worktree/HEAD,
# remota, PR, EVIDENCIA, merge, deploy, canary. El orden de los efectos es
# contrato: la evidencia se registra antes del merge y el canary va al final.
materializar 22-evidencia-antes.json "$T/py-22-evid"
cp "$T/py-22-evid/record.json" "$T/py-22-evid/r.json"
python3 "$PW" reconcile --record "$T/py-22-evid/r.json" --observations "$T/py-22-evid/obs1.json" \
  >"$T/py-22-evid/out.json" || fail "P1: reconcile rechazo la entrada"
orden="$(python3 -c "
import json,sys
e=json.load(open(sys.argv[1]))['effects']
print(' '.join(x['op']+':'+str(x['args'].get('kind')) for x in e))" "$T/py-22-evid/out.json")"
[ "$orden" = "record_observed:session.vanished record_observed:push.done record_observed:pr.open record_observed:test.failed record_observed:merge.done record_observed:canary.done" ] \
  || fail "P1: orden distinto al del plan Step 3: $orden"
echo "ok (2b): remota y PR antes de la evidencia, evidencia antes del merge y canary al final"

# (2c) 14.25 R20: un carril que vuelve a un trabajador anterior (A->B->A->B)
# registra el lanzamiento nuevo aunque su payload repita el de una tenencia
# vieja; reintentar el mismo lanzamiento sigue siendo duplicado.
mkdir -p "$T/py-r20"
printf '{"schema":"corrida.v2","lanes":[{"id":"l1","worker":"A","session":"sA","estado":"activo"}]}\n' \
  >"$T/py-r20/r.json"
for paso in 'B sB' 'A sA' 'B sB'; do
  set -- $paso
  printf '[{"lane":"l1","kind":"intent.launch_successor","payload":{"worker":"%s","session":"%s"}},{"lane":"l1","kind":"observed.launched","payload":{"worker":"%s","session":"%s"}}]\n' \
    "$1" "$2" "$1" "$2" >"$T/py-r20/ev.json"
  python3 "$PW" state reduce --record "$T/py-r20/r.json" --events "$T/py-r20/ev.json" >"$T/py-r20/out" \
    || fail "R20: state reduce rechazo el paso $paso"
done
printf '[{"lane":"l1","kind":"observed.launched","payload":{"worker":"B","session":"sB"}}]\n' >"$T/py-r20/ev.json"
[ "$(python3 "$PW" state reduce --record "$T/py-r20/r.json" --events "$T/py-r20/ev.json")" = "APPLIED 0 DUPLICATED 1" ] \
  || fail "R20: el reintento del ultimo lanzamiento no fue duplicado"
python3 - "$T/py-r20/r.json" <<'PY2' || fail "R20: la vuelta a B no quedo registrada"
import json, sys
c = json.load(open(sys.argv[1]))["lanes"][0]
assert c["worker"] == "B" and c["session"] == "sB", (c["worker"], c["session"])
assert [e["payload"]["worker"] for e in c["events"] if e["kind"] == "observed.launched"] == ["B", "A", "B"], c["events"]
PY2
# B21: relanzar el MISMO trabajador y sesion tras un intent nuevo (el sucesor
# murio y el relevo cae otra vez en el) es un lanzamiento nuevo, no un
# duplicado eterno que deja el intent colgado en la tenencia.
printf '[{"lane":"l1","kind":"intent.launch_successor","payload":{"worker":"B","session":"sB","preserve_worktree":true}},{"lane":"l1","kind":"observed.launched","payload":{"worker":"B","session":"sB"}}]\n' \
  >"$T/py-r20/ev.json"
got_rl="$(python3 "$PW" state reduce --record "$T/py-r20/r.json" --events "$T/py-r20/ev.json")"
[ "$got_rl" = "APPLIED 2 DUPLICATED 0" ] || fail "B21: el relanzamiento del mismo trabajador dio [$got_rl]"
printf '[{"lane":"l1","kind":"observed.launched","payload":{"worker":"B","session":"sB"}}]\n' >"$T/py-r20/ev.json"
[ "$(python3 "$PW" state reduce --record "$T/py-r20/r.json" --events "$T/py-r20/ev.json")" = "APPLIED 0 DUPLICATED 1" ] \
  || fail "B21: el reintento del relanzamiento no fue duplicado"

# (2d) 14.25 R21/R29: lo anotado en la tenencia anterior no tapa la actual.
# R21: un sucesor lanzado tras un relevo previo se confirma contra la
# observacion; R29: un bloqueo del trabajador anterior no impide anotar el
# mismo bloqueo del actual.
mkdir -p "$T/py-r21"
python3 - "$T/py-r21" <<'PY2' || fail "R21/R29: no se armaron los casos"
import json, os, sys
d = sys.argv[1]
def ev(i, kind, payload):
    return {"id": f"l1:{kind}:{i:02d}", "lane": "l1", "kind": kind, "payload": payload}
base = {"id": "l1", "estado": "handoff", "worker": "B", "session": "sB",
        "handoff": {"resumes": 1}, "delivery": {}, "evidence": {}}
r21 = dict(base, events=[
    ev(1, "intent.launch_successor", {"worker": "B", "session": "sB"}),
    ev(2, "observed.launched", {"worker": "B", "session": "sB"}),
    ev(3, "intent.launch_successor", {"worker": "A", "session": "sA"}),
])
r29 = dict(base, estado="activo", events=[
    ev(1, "observed.handoff.blocked", {"reason": "predecessor-writing"}),
    ev(2, "intent.launch_successor", {"worker": "B", "session": "sB"}),
    ev(3, "observed.launched", {"worker": "B", "session": "sB"}),
])
obs_r21 = {"tmux": {"sessions": ["sA"]}, "registry": {"workers": ["A", "B"]},
           "candidates": {"exhausted": [], "next": None},
           "lanes": {"l1": {"session_alive": False, "successor_session": "sA",
                            "successor": {"worker": "A"}}}}
obs_r29 = {"tmux": {"sessions": []}, "registry": {"workers": ["A", "B"]},
           "candidates": {"exhausted": [], "next": {"worker": "A", "session": "sA"}},
           "lanes": {"l1": {"session_alive": False, "inspect": "failed",
                            "predecessor_alive": True}}}
for nombre, carril, obs in (("r21", r21, obs_r21), ("r29", r29, obs_r29)):
    json.dump({"schema": "corrida.v2", "lanes": [carril]}, open(os.path.join(d, nombre + ".json"), "w"))
    json.dump(obs, open(os.path.join(d, nombre + "-obs.json"), "w"))
PY2
python3 "$PW" reconcile --record "$T/py-r21/r21.json" --observations "$T/py-r21/r21-obs.json" >"$T/py-r21/r21.out" \
  || fail "R21: reconcile rechazo la entrada"
python3 - "$T/py-r21/r21.out" <<'PY2' || fail "R21: el sucesor vivo de la segunda tenencia no se confirmo: $(cat "$T/py-r21/r21.out")"
import json, sys
e = json.load(open(sys.argv[1]))["effects"]
assert any(x["op"] == "record_observed" and x["args"]["kind"] == "launched"
           and x["args"]["payload"] == {"worker": "A", "session": "sA"} for x in e), e
PY2
python3 "$PW" reconcile --record "$T/py-r21/r29.json" --observations "$T/py-r21/r29-obs.json" >"$T/py-r21/r29.out" \
  || fail "R29: reconcile rechazo la entrada"
python3 - "$T/py-r21/r29.out" <<'PY2' || fail "R29: el bloqueo de la tenencia actual no se anoto: $(cat "$T/py-r21/r29.out")"
import json, sys
e = json.load(open(sys.argv[1]))["effects"]
assert any(x["op"] == "record_observed" and x["args"]["kind"] == "handoff.blocked"
           and x["args"]["payload"] == {"reason": "predecessor-writing"} for x in e), e
PY2
echo "ok (2c/2d): la tenencia entra al id del evento y acota tmux y bloqueos"


e2e_prepara() { # $1 caso $2 fixture: registro en CORRIDA_STATE + obs listas
  materializar "$2" "$T/e2e-$1"
  mkdir -p "$T/corridas/$1"
  cp "$T/e2e-$1/record.json" "$T/corridas/$1/registro.json"
  completar_registro "$T/corridas/$1/registro.json" "$1" "$T/modos.tsv"
  cp "$T/e2e-$1/obs1.json" "$T/e2e-$1-o1.json"
  cp "$T/e2e-$1/obs2.json" "$T/e2e-$1-o2.json"
}

# (3) Efectos ya ocurridos se registran sin repetirse: dos invocaciones,
# la segunda sin nada nuevo que ejecutar.
for par in "r3:03-push-exists" "r4:04-pr-exists" "r5:05-merge-exists" \
    "r6:06-deploy-partial" "r15:15-phase23-pending" "r16:16-test-failed-no-fallback"; do
  caso="${par%%:*}"; fx="${par##*:}"
  e2e_prepara "$caso" "$fx.json"
  bash "$CORR" reconciliar "$caso" --observations "$T/e2e-$caso-o1.json" >"$T/e2e-$caso-1.out" \
    || fail "$fx e2e inv1 fallo"
  grep -q '^CONVERGED ' "$T/e2e-$caso-1.out" || fail "$fx e2e inv1 no convergio"
  bash "$CORR" reconciliar "$caso" --observations "$T/e2e-$caso-o2.json" >"$T/e2e-$caso-2.out" \
    || fail "$fx e2e inv2 fallo"
  grep -q '^CONVERGED ' "$T/e2e-$caso-2.out" || fail "$fx e2e inv2 no convergio"
  [ "$(grep -c '^EXECUTED ' "$T/e2e-$caso-2.out" || true)" -eq 0 ] \
    || fail "$fx e2e inv2 ejecuto de mas: $(cat "$T/e2e-$caso-2.out")"
  registro_valido "$T/corridas/$caso/registro.json"
done
python3 - "$T/corridas/r3/registro.json" <<'PY' || fail "r3 sin push registrado"
import json,sys
d = json.load(open(sys.argv[1]))
dl = d["lanes"][0].get("delivery") or {}
assert dl.get("push", {}).get("head") == "c" * 40, dl
PY
python3 - "$T/corridas/r15/registro.json" <<'PY' || fail "r15 sin medicion pendiente"
import json,sys
d = json.load(open(sys.argv[1]))
evs = d["lanes"][0]["events"]
kinds = [e["kind"] for e in evs]
assert "observed.canary.done" in kinds, kinds
c = [e for e in evs if e["kind"] == "observed.canary.done"][0]
assert c["payload"].get("pending_hosts") == ["muse"], c
assert not any(k in ("observed.lane.stopped", "observed.lane.archived") for k in kinds), kinds
PY
python3 - "$T/corridas/r16/registro.json" <<'PY' || fail "r16 aprobo por fallback"
import json,sys
d = json.load(open(sys.argv[1]))
kinds = [e["kind"] for e in d["lanes"][0]["events"]]
assert "observed.test.failed" in kinds, kinds
assert not any("pass" in k or "complete" in k or "approved" in k for k in kinds), kinds
PY
echo "ok (3): push/PR/merge/deploy/canary/test convergen en dos invocaciones"

# (4) Sesion desvanecida con commits: resume real una sola vez.
e2e_prepara r2 02-vanished-session.json
bash "$CORR" reconciliar r2 --observations "$T/e2e-r2-o1.json" >"$T/e2e-r2-1.out" \
  || fail "r2 e2e inv1 fallo"
grep -q '^EXECUTED resume_lane l1$' "$T/e2e-r2-1.out" || fail "r2 inv1 no reanudo: $(cat "$T/e2e-r2-1.out")"
"$TMUX_BIN" has-session -t "=ses-v" 2>/dev/null || fail "r2: la sesion no vive tras el resume"
# B5: el nombre tmux no es el id de sesion de la CLI; el resume retoma la
# conversacion mas reciente del worktree y jamas recibe el nombre tmux.
[ "$(tail -n1 "$T/argv/codex.argv")" = "resume --last --sandbox workspace-write" ] \
  || fail "r2: argv de resume inesperada: $(tail -n1 "$T/argv/codex.argv")"
bash "$CORR" reconciliar r2 --observations "$T/e2e-r2-o2.json" >"$T/e2e-r2-2.out" \
  || fail "r2 e2e inv2 fallo"
n2="$(grep -c '^EXECUTED resume_lane ' "$T/e2e-r2-1.out" "$T/e2e-r2-2.out" | awk -F: '{s+=$2} END {print s}')"
[ "$n2" -eq 1 ] || fail "r2: resume ejecutado $n2 veces"
registro_valido "$T/corridas/r2/registro.json"
echo "ok (4): la sesion desvanecida reanuda una vez y converge"

# (4c) B21 sin --observations: tras el resume, reconciliar vuelve a observar
# y ve viva la sesion reanudada; con la foto vieja la daba por caida y
# anotaba un bloqueo de relevo sin candidato.
mkdir -p "$T/corridas/r4c" "$T/bin-gh4c"
printf '#!/bin/sh\nexit 0\n' >"$T/bin-gh4c/gh"; chmod +x "$T/bin-gh4c/gh"
python3 - "$T/corridas/r4c/registro.json" "$T/wt" <<'PY' || fail "r4c sin registro"
import json,sys
lane = {"id":"l1","branch":"corrida/r4c/l1","worktree":sys.argv[2],"base_remote_sha":"a"*40,
        "owner":"l1","mode":"write","role":"write","estado":"activo","token":"9-t",
        "worker":"codex","harness":"codex-cli","provider":"openai","reported_model":"unknown",
        "session":"ses-auto","events":[],"evidence":{},"handoff":{"attempts":[],"resumes":0}}
json.dump({"schema":"corrida.v2","id":"r4c","estado":"abierta","lanes":[lane]},open(sys.argv[1],"w"))
PY
completar_registro "$T/corridas/r4c/registro.json" "r4c" "$T/modos.tsv"
PATH="$T/bin-gh4c:$PATH" bash "$CORR" reconciliar r4c >"$T/r4c.out" || fail "r4c fallo: $(cat "$T/r4c.out")"
grep -q '^EXECUTED resume_lane l1$' "$T/r4c.out" || fail "r4c no reanudo: $(cat "$T/r4c.out")"
grep -q '^CONVERGED ' "$T/r4c.out" || fail "r4c no convergio: $(cat "$T/r4c.out")"
"$TMUX_BIN" has-session -t "=ses-auto" 2>/dev/null || fail "r4c: la sesion reanudada no vive"
python3 - "$T/corridas/r4c/registro.json" <<'PY' || fail "r4c: la sesion reanudada se tomo por caida"
import json,sys
kinds = [e["kind"] for e in json.load(open(sys.argv[1]))["lanes"][0]["events"]]
assert "observed.resumed" in kinds and "observed.handoff.blocked" not in kinds, kinds
PY
"$TMUX_BIN" kill-session -t "=ses-auto" 2>/dev/null
echo "ok (4c): sin --observations re-observa tras el resume y confirma la sesion viva"

# (5) Reconciliacion repetida: el sucesor queda lanzado y registrado (el
# fixture conserva su nombre historico "launch-once").
# B21: tras el launch la llamada termina (REOBSERVAR) y la segunda, con la
# foto nueva, converge sin tocar al sucesor.
e2e_prepara r14 14-repeated-launch-once.json
bash "$CORR" reconciliar r14 --observations "$T/e2e-r14-o1.json" >"$T/e2e-r14-1.out" \
  || fail "r14 e2e inv1 fallo"
grep -q '^EXECUTED handoff_lane l1$' "$T/e2e-r14-1.out" || fail "r14 inv1 sin handoff"
grep -q '^EXECUTED launch_successor l1$' "$T/e2e-r14-1.out" || fail "r14 inv1 sin launch"
bash "$CORR" reconciliar r14 --observations "$T/e2e-r14-o2.json" >"$T/e2e-r14-2.out" \
  || fail "r14 e2e inv2 fallo"
grep -q '^CONVERGED ' "$T/e2e-r14-2.out" || fail "r14 inv2 no convergio"
n14="$(grep -c '^EXECUTED launch_successor ' "$T/e2e-r14-1.out" "$T/e2e-r14-2.out" | awk -F: '{s+=$2} END {print s}')"
[ "$n14" -ge 1 ] || fail "r14: sin lanzamiento registrado"
python3 - "$T/corridas/r14/registro.json" <<'PY' || fail "r14 sin sucesor registrado"
import json,sys
c = json.load(open(sys.argv[1]))["lanes"][0]
lanzados = [e for e in c["events"] if e["kind"] == "observed.launched"]
assert lanzados, c["events"]
u = lanzados[-1]["payload"]
assert u.get("worker") == "kimi" and u.get("session") == "ses-r2", u
PY
echo "ok (5): el sucesor se lanza una vez y queda registrado"

# (5b) B1 de la practica 14.13: relevo por cuota con el predecesor ya
# detenido. La foto del director no trae al sucesor (aun no existia); tras
# lanzarlo, reconciliar no puede tomarlo por desaparecido ni matarlo.
mkdir -p "$T/corridas/r5b"
python3 - "$T/corridas/r5b/registro.json" "$T/wt" "$T/brief.txt" "$T/r5b-o1.json" "$T/r5b-o2.json" <<'PY' || fail "r5b sin registro"
import json,sys
reg,wt,brief,o1,o2 = sys.argv[1:6]
def ev(n,kind,payload): return {"id":"l1:%s:%02d"%(kind,n),"lane":"l1","kind":kind,"payload":payload,"at":"2026-09-29T10:17:02Z"}
lane = {"id":"l1","branch":"corrida/r5b/l1","worktree":wt,"base_remote_sha":"a"*40,
        "owner":"l1","mode":"write","role":"write","estado":"handoff","token":"9-t",
        "worker":"codex","harness":"codex-cli","provider":"openai","reported_model":"unknown",
        "session":"ses-pred","brief":brief,"evidence":{"inspect":"quota"},
        "handoff":{"attempts":[],"resumes":0},
        "events":[ev(1,"observed.inspect.quota",{"session":"ses-pred"}),
                  ev(2,"intent.handoff_lane",{"reason":"quota","from_worker":"codex","from_session":"ses-pred",
                     "to_worker":"kimi","to_session":"ses-suc","preserve_worktree":True,"dirty":True,"commits_ahead":1}),
                  ev(3,"intent.stop_lane",{"session":"ses-pred"})]}
json.dump({"schema":"corrida.v2","id":"r5b","estado":"abierta","lanes":[lane]},open(reg,"w"))
base = {"registry":{"workers":["codex","kimi"]},"candidates":{"exhausted":["codex"],"next":{"worker":"kimi","session":"ses-suc"}}}
lo = {"session_alive":False,"predecessor_alive":False,"children_writing":False,"worktree_exists":True,
      "dirty":True,"commits_ahead":1,"remote_branch":False}
json.dump(dict(base,tmux={"sessions":[]},lanes={"l1":lo}),open(o1,"w"))
json.dump(dict(base,tmux={"sessions":["ses-suc"]},
               lanes={"l1":dict(lo,session_alive=True,successor_session="ses-suc",successor={"worker":"kimi"})}),open(o2,"w"))
PY
completar_registro "$T/corridas/r5b/registro.json" "r5b" "$T/modos.tsv"
# B3/B4: el director elige al sucesor con el selector (la decision queda en
# el carril) y el relevo publica en el tablero y avisa una vez por Telegram.
cat >"$T/bin/openclaw-r5b" <<STUB
#!/bin/sh
printf '%s\\n' "OPENCLAW \$*" >> "$T/r5b-openclaw.log"
case "\$*" in
  *"message send"*) printf '{"messageId":"77"}\\n';;
  *"runbook.progress.get"*)
    if [ -s "$T/r5b-events.jsonl" ]; then
      printf '{"ok":true,"revision":%s,"doc":%s}\\n' "\$(wc -l <"$T/r5b-events.jsonl" | tr -d ' ')" "\$(cat "$T/r5b-tablero.json")"
    else
      printf '{"ok":true,"doc":%s}\\n' "\$(cat "$T/r5b-tablero.json")"
    fi;;
  *"runbook.progress.set"*)
    while [ \$# -gt 0 ]; do [ "\$1" = "--params" ] && printf '%s' "\$2" >"$T/r5b-tablero.json"; shift; done
    printf '{"ok":true}\\n';;
  *"runbook.progress.event"*)
    while [ \$# -gt 0 ]; do [ "\$1" = "--params" ] && printf '%s' "\$2" >>"$T/r5b-events.jsonl" && printf '\\n' >>"$T/r5b-events.jsonl"; shift; done
    printf '{"ok":true,"revision":%s}\\n' "\$(wc -l <"$T/r5b-events.jsonl" | tr -d ' ')";;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw-r5b"
python3 - "$T/r5b-tablero.json" <<'PY' || fail "r5b sin tablero"
import json,sys
car={"id":"l1","nombre":"relevo","repo":"gon0801/goncloud-openclaw","rama":None,"tareas":["14.13"],
  "estado":"implementando","paso_loop":1,"pr":None,"head":None,"approve_lead":None,"ci":"sin-ci",
  "coderabbit":"pendiente","residuales":[],"detenido_por":None,"ultimo_evento":None}
json.dump({"schema":"runbook-progress.v1","runbook":"docs/runbooks/x.md","fase":"14.13","corrida":"r5b",
  "titulo":"relevo","lead":{"agente":"claude","inicio":"2026-09-29T10:00:00Z","actualizado":"2026-09-29T10:00:00Z"},
  "atencion_requerida":{"necesaria":False,"motivo":None,"desde":None},"siguiente_paso":"relevo",
  "carriles":[car],"cola":[],"notas":[],"eventos":[],
  "cierre":{"at":None,"telegram_message_id":None,"resumen":None}},open(sys.argv[1],"w"))
PY
printf '{"role":"write","task_type":"general"}\n' >"$T/r5b-req.json"
printf '{"health":{"codex":"available","kimi":"available"},"exhausted":["codex"]}\n' >"$T/r5b-st.json"
bash "$CORR" seleccionar r5b l1 --request "$T/r5b-req.json" --state "$T/r5b-st.json" >"$T/r5b-sel.out" \
  || fail "r5b: seleccionar fallo: $(cat "$T/r5b-sel.out")"
export OPENCLAW_BIN="$T/bin/openclaw-r5b"
export PROGRESS_EVENTS_BIN="$PWD/scripts/mac/progress-events.py" PROGRESS_EVENTS_STATE_DIR="$T/r5b-progress-events"
bash "$CORR" reconciliar r5b --observations "$T/r5b-o1.json" >"$T/r5b-1.out" || fail "r5b inv1 fallo: $(cat "$T/r5b-1.out")"
grep -q '^EXECUTED launch_successor l1$' "$T/r5b-1.out" || fail "r5b inv1 sin launch: $(cat "$T/r5b-1.out")"
grep -q 'resume_lane\|handoff_lane' "$T/r5b-1.out" && fail "r5b: tomo al sucesor recien lanzado por caido: $(cat "$T/r5b-1.out")"
tail -n1 "$T/r5b-1.out" | grep -q '^REOBSERVAR ' || fail "r5b: tras el launch no pidio re-observar: $(cat "$T/r5b-1.out")"
"$TMUX_BIN" has-session -t "=ses-suc" 2>/dev/null || fail "r5b: el sucesor no sigue vivo tras reconciliar"
bash "$CORR" reconciliar r5b --observations "$T/r5b-o2.json" >"$T/r5b-2.out" || fail "r5b inv2 fallo"
[ "$(cat "$T/r5b-2.out")" = "CONVERGED 0" ] || fail "r5b inv2 no convergio limpio: $(cat "$T/r5b-2.out")"
"$TMUX_BIN" has-session -t "=ses-suc" 2>/dev/null || fail "r5b: la segunda pasada mato al sucesor"
python3 - "$T/corridas/r5b/registro.json" <<'PY' || fail "r5b: registro del relevo inesperado"
import json,sys
c = json.load(open(sys.argv[1]))["lanes"][0]
kinds = [e["kind"] for e in c["events"]]
assert kinds.count("observed.launched") == 1, kinds
assert "observed.handoff.blocked" not in kinds and "intent.resume_lane" not in kinds, kinds
assert c["worker"] == "kimi" and c["session"] == "ses-suc" and c["estado"] == "activo", c
PY
registro_valido "$T/corridas/r5b/registro.json"
AVISO_R5B="El trabajo de la parte l1 pasó de OpenAI (Codex) a Kimi porque se acabó la cuota; lo avanzado se conservó."
[ "$(grep -c 'message send' "$T/r5b-openclaw.log")" -eq 1 ] \
  || fail "r5b: el relevo no mando exactamente un aviso: $(cat "$T/r5b-openclaw.log")"
grep -qF "$AVISO_R5B" "$T/r5b-openclaw.log" \
  || fail "r5b: el aviso no dice el relevo en palabras del dueno: $(cat "$T/r5b-openclaw.log")"
python3 - "$T/r5b-tablero.json" "$T/corridas/r5b" "$AVISO_R5B" "$T/r5b-events.jsonl" <<'PY' || fail "r5b: tablero o seleccion del relevo sin publicar"
import json,os,sys
d=json.load(open(sys.argv[1]))
events=[json.loads(line) for line in open(sys.argv[4])]
workers=[e for e in events if e.get("kind")=="part.worker"]
assert len(workers)==1 and workers[0]["worker"]["id"]=="kimi", workers
assert workers[0]["worker"]["provider"]=="kimi" and workers[0]["worker"]["effort"] is None, workers
assert "codex (quota-exhausted)" in workers[0]["note"], workers
lane=json.load(open(os.path.join(sys.argv[2],"registro.json")))["lanes"][0]
assert lane["selection"]["winner"]=="kimi" and lane["selection"]["discarded"]==[{"worker":"codex","reasons":["quota-exhausted"]}], lane["selection"]
filas=[json.loads(l) for l in open(os.path.join(sys.argv[2],"mensajes.jsonl"))]
assert [(f["etiqueta"],f["ok"]) for f in filas]==[("AVANZA",True)], filas
PY
node --experimental-strip-types --input-type=module - "$T/r5b-tablero.json" <<'JS' || fail "r5b: el tablero publicado no pasa el validador del plugin"
import fs from "node:fs";
import { validarProgreso } from "./tablero-runbook/contrato.ts";
const r = validarProgreso(JSON.parse(fs.readFileSync(process.argv[2], "utf8")));
if (!r.ok) { console.error(r.razones.join("\n")); process.exit(1); }
JS
bash "$CORR" cerrar r5b >/dev/null 2>&1 || fail "r5b: cerrar fallo"
python3 - "$T/corridas/r5b/archive/l1/selection.json" <<'PY' || fail "r5b: el archivo no guarda el porque de la seleccion"
import json,sys
s=json.load(open(sys.argv[1]))
assert s["winner"]=="kimi" and s["worker"]=="kimi" and s["model"]=="router" and s["effort"] is None, s
assert s["parts"] and s["score"]==s["candidates"][0]["score"] and s["discarded"], s
assert len(s["selections"])==1, s["selections"]
PY
export OPENCLAW_BIN="$T/bin/openclaw-stub"
echo "ok (5b): el relevo lanza al sucesor una vez, no lo mata, lo publica y lo avisa una vez"

# (6) Predecesor escribiendo bloquea; al liberarse, el handoff avanza.
e2e_prepara r12 12-predecessor-blocks.json
bash "$CORR" reconciliar r12 --observations "$T/e2e-r12-o1.json" >"$T/e2e-r12-1.out" \
  || fail "r12 e2e inv1 fallo"
grep -q 'handoff_lane\|launch_successor' "$T/e2e-r12-1.out" \
  && fail "r12 inv1 lanzo con el predecesor escribiendo"
bash "$CORR" reconciliar r12 --observations "$T/e2e-r12-o2.json" >"$T/e2e-r12-2.out" \
  || fail "r12 e2e inv2 fallo"
grep -q '^EXECUTED handoff_lane l1$' "$T/e2e-r12-2.out" || fail "r12 inv2 sin handoff"
registro_valido "$T/corridas/r12/registro.json"
echo "ok (6): el predecesor vivo bloquea y su salida desbloquea"

# (7) El diff sucio y los commits sobreviven al handoff.
printf 'sucio\n' >>"$T/wt/f.txt"
e2e_prepara r17 17-dirty-diff-survives.json
bash "$CORR" reconciliar r17 --observations "$T/e2e-r17-o1.json" >"$T/e2e-r17-1.out" \
  || fail "r17 e2e inv1 fallo"
grep -q '^EXECUTED handoff_lane l1$' "$T/e2e-r17-1.out" || fail "r17 inv1 sin handoff"
registro_valido "$T/corridas/r17/registro.json"
grep -q 'sucio' "$T/wt/f.txt" || fail "r17: el handoff limpio el diff"
python3 - "$T/corridas/r17/registro.json" <<'PY' || fail "r17 sin preserve"
import json,sys
evs = json.load(open(sys.argv[1]))["lanes"][0]["events"]
h = [e for e in evs if e["kind"] == "intent.handoff_lane"]
assert h and h[0]["payload"].get("preserve_worktree") is True, evs
# B21: la foto previa al stop ya no decide nada; antes anotaba un
# stop-unconfirmed falso contra la sesion que el stop acababa de cerrar.
assert not [e for e in evs if e["kind"] == "observed.handoff.blocked"], evs
PY
tail -n1 "$T/e2e-r17-1.out" | grep -qx 'REOBSERVAR 3' \
  || fail "r17: tras el stop la llamada no pidio re-observar: $(cat "$T/e2e-r17-1.out")"
echo "ok (7): diff y commits sobreviven al handoff"

# (8) Sin candidatos solo se detiene su carril.
e2e_prepara r13 13-candidates-exhausted.json
bash "$CORR" reconciliar r13 --observations "$T/e2e-r13-o1.json" >"$T/e2e-r13-1.out" \
  || fail "r13 e2e inv1 fallo"
grep -q '^EXECUTED mark_lane_stopped l1$' "$T/e2e-r13-1.out" || fail "r13 inv1 no detuvo l1"
python3 - "$T/corridas/r13/registro.json" <<'PY' || fail "r13 toco el carril ajeno"
import json,sys
cs = {c["id"]: c for c in json.load(open(sys.argv[1]))["lanes"]}
assert cs["l1"]["estado"] == "stopped", cs["l1"]
assert cs["l2"]["estado"] == "activo" and cs["l2"]["events"] == [], cs["l2"]
PY
registro_valido "$T/corridas/r13/registro.json"
echo "ok (8): el agotamiento detiene solo su carril"

# (9) Cerrar archiva antes de detener: transcript, seleccion, eventos y
# evidencia con modo 600 y secretos redactados; el reintento converge.
mkdir -p "$T/corridas/r9"
python3 - "$T/corridas/r9/registro.json" "$T/modos.tsv" "$T/wt" <<'PY' || fail "r9 sin registro"
import json,sys
d = {"schema": "corrida.v2", "id": "r9", "estado": "abierta",
     "cli_modos": sys.argv[2], "sesiones": [],
     "canal": {"cron": "prueba", "destino": "dest-prueba"},
     "lanes": [{"id": "l1", "branch": "corrida/r9/l1", "worktree": sys.argv[3],
                "base_remote_sha": "a" * 40, "owner": "l1", "mode": "write",
                "role": "write", "estado": "activo", "token": "9-t",
                "worker": "codex", "harness": "codex-cli", "provider": "openai",
                "reported_model": "m-test", "session": "ses-cierre",
                "events": [{"id": "l1:observed.push.done:01", "kind": "observed.push.done",
                            "lane": "l1", "payload": {"branch": "corrida/r9/l1"}}],
                "evidence": {"note": "token ghp_falso12345abc"},
                "handoff": {"attempts": [], "exhausted": False, "resumes": 0}}]}
open(sys.argv[1], "w").write(json.dumps(d) + "\n")
PY
completar_registro "$T/corridas/r9/registro.json" "r9" "$T/modos.tsv"
FAKE_HARNESS_MODE= "$TMUX_BIN" new-session -d -s "ses-cierre" -x 200 -y 50 -c "$T/wt" "$T/bin/codex" || fail "r9 sin sesion"
"$TMUX_BIN" send-keys -t "=ses-cierre:" -l -- "reviso ghp_otropantalla9" || fail "r9 sin teclas"
sleep 1
bash "$CORR" cerrar r9 >"$T/e2e-r9.out" || fail "cerrar r9 fallo"
grep -q '^cerrada r9$' "$T/e2e-r9.out" || fail "cerrar r9: $(cat "$T/e2e-r9.out")"
for f in transcript.txt selection.json events.jsonl evidence.json; do
  [ -f "$T/corridas/r9/archive/l1/$f" ] || fail "r9 sin archive/l1/$f"
done
modo9="$(python3 -c "import os; print(oct(os.stat('$T/corridas/r9/archive/l1/evidence.json').st_mode & 0o777))")"
[ "$modo9" = "0o600" ] || fail "r9 archive con modo $modo9"
grep -q 'ghp_falso' "$T/corridas/r9/archive/l1/evidence.json" \
  && fail "r9: el secreto quedo sin redactar"
grep -q 'ghp_otropantalla9' "$T/corridas/r9/archive/l1/transcript.txt" \
  && fail "r9: la pantalla quedo sin redactar"
grep -q 'm-test' "$T/corridas/r9/archive/l1/selection.json" \
  || fail "r9: selection.json sin reported_model"
"$TMUX_BIN" has-session -t "=ses-cierre" 2>/dev/null \
  && fail "r9: la sesion sigue viva tras el archivo"
bash "$CORR" cerrar r9 >"$T/e2e-r9b.out" || fail "reintento de cerrar fallo"
grep -q '^cerrada r9$' "$T/e2e-r9b.out" || fail "reintento no idempotente"
registro_valido "$T/corridas/r9/registro.json"
echo "ok (9): cerrar archiva redactado, detiene y reintenta limpio"

# (9b) 14.22 P3/P4: los archivados nacen 600 (umask 077; sin ventana 644 entre
# creacion y chmod) y el reintento sin sesion no pisa el transcript real.
mkdir -p "$T/corridas/r9b"
python3 - "$T/corridas/r9b/registro.json" "$T/modos.tsv" "$T/wt" <<'PY' || fail "r9b sin registro"
import json,sys
d = {"schema": "corrida.v2", "id": "r9b", "estado": "abierta",
     "cli_modos": sys.argv[2], "sesiones": [],
     "canal": {"cron": "prueba", "destino": "dest-prueba"},
     "lanes": [{"id": "l1", "branch": "corrida/r9b/l1", "worktree": sys.argv[3],
                "base_remote_sha": "a" * 40, "owner": "l1", "mode": "write",
                "role": "write", "estado": "activo", "token": "9-t",
                "worker": "codex", "harness": "codex-cli", "provider": "openai",
                "reported_model": "m-test", "session": "ses-r9b",
                "events": [], "evidence": {},
                "handoff": {"attempts": [], "exhausted": False, "resumes": 0}}]}
open(sys.argv[1], "w").write(json.dumps(d) + "\n")
PY
P3OUT="$T/p3.out"
bash -c '
  . scripts/mac/corrida/lib.sh
  AQUI=scripts/mac/corrida
  source scripts/mac/corrida/cerrar.sh
  redactar_texto() {
    entrada=$(cat)
    case "$entrada" in
      *"worker"*) return 1 ;;
    esac
    printf "%s\n" "$entrada" | tr -d "\000-\010\013\014\016-\037\177"
  }
  cerrar_archivar_lanes r9b "$1"
' p3 "$T/corridas/r9b/registro.json" >/dev/null 2>&1
[ -f "$T/corridas/r9b/archive/l1/transcript.txt" ]   || fail "r9b: el montaje no llego a escribir el transcript"
modo_p3="$(python3 -c "import os; print(oct(os.stat('$T/corridas/r9b/archive/l1/transcript.txt').st_mode & 0o777))")"
[ "$modo_p3" = "0o600" ] \
  || fail "P3: el archivado nacio con modo $modo_p3 antes del chmod (falta umask 077)"
# P4: segunda pasada sin sesion (capture falla) no pisa el transcript con contenido.
P4TXT="$T/corridas/r9b/archive/l1/transcript.txt"
printf 'PANTALLA REAL DEL CARRIL\n' >"$P4TXT"
sal_p4="$(bash -c '
  . scripts/mac/corrida/lib.sh
  AQUI=scripts/mac/corrida
  source scripts/mac/corrida/cerrar.sh
  cerrar_archivar_lanes r9b "$1"
' cerrar-p4 "$T/corridas/r9b/registro.json" 2>&1); rc_p4=$?"
grep -q 'PANTALLA REAL DEL CARRIL' "$P4TXT" \
  || fail "P4: el reintento sin sesion piso el transcript real: $(cat "$P4TXT")"
# 14.25 R18: el umask 077 queda encerrado en el archivado; el resto de cerrar
# (mensajes, registro) sigue con el umask del llamador.
umask_r18="$(bash -c '
  . scripts/mac/corrida/lib.sh
  AQUI=scripts/mac/corrida
  source scripts/mac/corrida/cerrar.sh
  umask 022
  cerrar_archivar_lanes r9b "$1" >/dev/null 2>&1
  umask
' cerrar-r18 "$T/corridas/r9b/registro.json")"
[ "$umask_r18" = "0022" ] || fail "R18: el archivado dejo el umask en $umask_r18 para el resto de cerrar"
echo "ok (9b): archivados nacen 600 y el reintento no pisa el transcript"

# (9c) 14.22 P7: reconciliar_observar lista PRs con --state all; un PR ya
# mergeado se ve y alimenta observed.merge.done.
GHLOG="$T/gh.log"
mkdir -p "$T/bin-gh" "$T/wt-obs"
printf 'uno\n' >"$T/wt-obs/f.txt"
git -C "$T/wt-obs" init -q -b main 2>/dev/null || git -C "$T/wt-obs" init -q
git -C "$T/wt-obs" add f.txt && git -C "$T/wt-obs" -c user.email=t@t -c user.name=t commit -qm uno
cat >"$T/bin-gh/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$GHLOG"
case "\$*" in
  *"pr list"*) printf '{"number":7,"headRefOid":"c","mergedAt":"2026-09-27T00:00:00Z","mergeCommit":{"oid":"d"}}';;
esac
exit 0
STUB
chmod +x "$T/bin-gh/gh"
mkdir -p "$T/corridas/r9c"
python3 - "$T/corridas/r9c/registro.json" "$T/wt-obs" <<'PY' || fail "r9c sin registro"
import json,sys
d = {"schema": "corrida.v2", "id": "r9c", "estado": "abierta",
     "cli_modos": "inexistente.tsv", "sesiones": [],
     "lanes": [{"id": "l1", "branch": "corrida/r9c/l1", "worktree": sys.argv[2],
                "base_remote_sha": "a" * 40, "owner": "l1", "mode": "write",
                "role": "write", "estado": "activo", "token": "9-t",
                "worker": "codex", "session": "ses-x", "events": [], "evidence": {}}]}
open(sys.argv[1], "w").write(json.dumps(d) + "\n")
PY
: > "$GHLOG"
obs9c="$(PATH="$T/bin-gh:$PATH" bash -c '
  . scripts/mac/corrida/lib.sh
  AQUI=scripts/mac/corrida
  source scripts/mac/corrida/reconciliar.sh
  reconciliar_observar r9c "$1"
' observar "$T/corridas/r9c/registro.json")" || fail "P7: reconciliar_observar fallo"
grep -q -- '--state all' "$GHLOG" \
  || fail "P7: gh pr list sin --state all; los mergeados son invisibles"
python3 - "$obs9c" "$T/corridas/r9c/registro.json" <<'PY' || fail "P7: el merge visto no se registra como observed.merge.done"
import json,os,subprocess,sys
obs = json.load(open(sys.argv[1]))
assert obs["lanes"]["l1"]["merge"] == {"merged": True, "merge_commit": "d"}, obs["lanes"]["l1"]
out = subprocess.run([sys.executable, "scripts/mac/corrida-worker.py", "reconcile",
  "--record", sys.argv[2], "--observations", sys.argv[1]],
  capture_output=True, text=True)
assert out.returncode == 0, out.stderr
kinds = [e["op"] + ":" + str(e.get("args", {}).get("kind")) for e in json.loads(out.stdout)["effects"]]
assert "record_observed:merge.done" in kinds, kinds
PY
echo "ok (9c): los PR mergeados se ven (--state all) y registran merge.done"

# (10) Entradas rotas mueren con diagnostico, sin escribir nada.
printf 'no-json' >"$T/malo.json"
python3 "$PW" reconcile --record "$T/malo.json" --observations "$T/c01/obs1.json" >/dev/null 2>&1 \
  && fail "reconcile acepto un record roto"
printf '[{"lane":"l1","kind":"volar","payload":{}}]' >"$T/malev.json"
cp "$T/c01/record.json" "$T/malr.json"
out="$(python3 "$PW" state reduce --record "$T/malr.json" --events "$T/malev.json" 2>&1)" \
  && fail "reduce acepto un kind desconocido"
printf '%s\n' "$out" | grep -qx 'ERROR invalid event' || fail "diagnostico: $out"
bash "$CORR" reconciliar no-existe --observations "$T/c01/obs1.json" >/dev/null 2>&1 \
  && fail "reconciliar acepto una corrida inexistente"
# Sin candidato y sin agotamiento declarado no se detiene: se bloquea visible.
python3 - "$T/nocand-r.json" "$T/nocand-o.json" <<'PY' || fail "sin obs no-candidate"
import json,sys
r = {"schema": "corrida.v2", "id": "run-t", "estado": "abierta", "lanes":
 [{"id": "l1", "branch": "corrida/run-t/l1", "worktree": "/tmp/x",
   "base_remote_sha": "a" * 40, "owner": "l1", "mode": "write", "role": "write",
   "estado": "activo", "token": "9-t", "worker": "codex", "session": "ses-n",
   "events": [], "evidence": {}, "handoff": {"attempts": [], "exhausted": False, "resumes": 0}}]}
o = {"registry": {"workers": ["codex"]}, "tmux": {"sessions": ["ses-n"]},
 "candidates": {"exhausted": [], "next": None},
 "lanes": {"l1": {"session_alive": True, "inspect": "quota", "predecessor_alive": False,
  "children_writing": False, "worktree_exists": True, "remote_branch": False}}}
json.dump(r, open(sys.argv[1], "w")); json.dump(o, open(sys.argv[2], "w"))
PY
ops_nc="$(python3 "$PW" reconcile --record "$T/nocand-r.json" --observations "$T/nocand-o.json" \
  | python3 -c "import json,sys; print(' '.join(e['op'] for e in json.load(sys.stdin)['effects']))")"
[ "$ops_nc" = "record_observed record_observed" ] || fail "no-candidate: [$ops_nc]"
echo "ok (10): entradas rotas con diagnostico"

# (11) 19.3-2 y 19.3-10-F2: sin campo muerto en el fixture y sin
# silencio cuando el aviso del relevo no se puede armar.
grep -q "expect_launch_count_e2e" "$FIX/14-repeated-launch-once.json" \
  && fail "(11) el fixture trae el campo muerto expect_launch_count_e2e"
. scripts/mac/corrida/reconciliar.sh
TR="$T/relevo-falla"
mkdir -p "$TR/rr"
printf '{"id":"rr","lanes":[]}' >"$TR/rr/registro.json"
printf '{"schema":"workers.v1","workers":[]}' >"$TR/w.json"
out=$(CORRIDA_STATE="$TR" CORRIDA_WORKERS_REGISTRY="$TR/w.json" \
  reconciliar_anunciar_relevo rr "$TR/rr/registro.json" l1 kimi_k3 2>&1) \
  || fail "(11) el relevo fallido debio salir 0 con aviso, no error: $out"
printf '%s' "$out" | grep -q "no se pudo armar el aviso del relevo de l1" \
  || fail "(11) el relevo que no se arma cayo en silencio: [$out]"
echo "ok (11): sin campo muerto y el relevo fallido avisa por stderr"

echo "TODO VERDE: corrida-reconcile"

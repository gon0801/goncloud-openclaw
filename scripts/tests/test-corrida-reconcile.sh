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
    18-handoff-exhausted-stops 19-reservado-sin-sesion; do
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
echo "ok (2): los 19 fixtures proponen lo esperado y repiten byte-identico"

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
bash "$CORR" reconciliar r2 --observations "$T/e2e-r2-o2.json" >"$T/e2e-r2-2.out" \
  || fail "r2 e2e inv2 fallo"
n2="$(grep -c '^EXECUTED resume_lane ' "$T/e2e-r2-1.out" "$T/e2e-r2-2.out" | awk -F: '{s+=$2} END {print s}')"
[ "$n2" -eq 1 ] || fail "r2: resume ejecutado $n2 veces"
registro_valido "$T/corridas/r2/registro.json"
echo "ok (4): la sesion desvanecida reanuda una vez y converge"

# (5) Reconciliacion repetida lanza al sucesor una sola vez.
e2e_prepara r14 14-repeated-launch-once.json
bash "$CORR" reconciliar r14 --observations "$T/e2e-r14-o1.json" >"$T/e2e-r14-1.out" \
  || fail "r14 e2e inv1 fallo"
grep -q '^EXECUTED handoff_lane l1$' "$T/e2e-r14-1.out" || fail "r14 inv1 sin handoff"
grep -q '^EXECUTED launch_successor l1$' "$T/e2e-r14-1.out" || fail "r14 inv1 sin launch"
bash "$CORR" reconciliar r14 --observations "$T/e2e-r14-o2.json" >"$T/e2e-r14-2.out" \
  || fail "r14 e2e inv2 fallo"
grep -q '^CONVERGED ' "$T/e2e-r14-2.out" || fail "r14 inv2 no convergio"
n14="$(grep -c '^EXECUTED launch_successor ' "$T/e2e-r14-1.out" "$T/e2e-r14-2.out" | awk -F: '{s+=$2} END {print s}')"
[ "$n14" -eq 1 ] || fail "r14: launch ejecutado $n14 veces"
registro_valido "$T/corridas/r14/registro.json"
python3 - "$T/corridas/r14/registro.json" <<'PY' || fail "r14 sin sucesor registrado"
import json,sys
c = json.load(open(sys.argv[1]))["lanes"][0]
assert c["worker"] == "kimi" and c["session"] == "ses-r2", c
PY
echo "ok (5): el sucesor se lanza una sola vez aunque la observacion no cambie"

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
b = [e for e in evs if e["kind"] == "observed.handoff.blocked"]
assert b and b[-1]["payload"].get("reason") == "stop-unconfirmed", evs
PY
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

echo "TODO VERDE: corrida-reconcile"

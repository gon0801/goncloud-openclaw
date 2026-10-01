#!/bin/bash
# The native publisher imports a legacy run once and retries one worker tenure.
set -eu
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/corridas/run-1" "$tmp/bin"
export CORRIDA_STATE="$tmp/corridas" PROGRESS_EVENTS_STATE_DIR="$tmp/outbox"
export PROGRESS_EVENTS_BIN="$PWD/scripts/mac/progress-events.py"
export OPENCLAW_BIN="$tmp/bin/openclaw" FAKE_PROGRESS_STATE="$tmp/gateway.json"
python3 - "$tmp" <<'PY'
import json, sys
from pathlib import Path
base = Path(sys.argv[1])
doc = {"schema":"runbook-progress.v1","runbook":"docs/runbooks/x.md","fase":"14.13","corrida":"run-1",
 "titulo":"prueba","lead":{"agente":"claude","inicio":"2026-09-29T10:00:00Z","actualizado":"2026-09-29T10:00:00Z"},
 "atencion_requerida":{"necesaria":False,"motivo":None,"desde":None},"siguiente_paso":"probar",
 "carriles":[{"id":"lane-1","nombre":"lane-1","repo":"gon0801/goncloud-openclaw","rama":None,"tareas":["14.13"],
  "estado":"implementando","paso_loop":1,"pr":None,"head":None,"approve_lead":None,"ci":"sin-ci",
  "coderabbit":"pendiente","residuales":[],"detenido_por":None,"ultimo_evento":None}],
 "cola":[],"notas":["nota del lead"],"eventos":[],"cierre":{"at":None,"telegram_message_id":None,"resumen":None}}
(base / "doc.json").write_text(json.dumps(doc))
reg={"schema":"corrida.v2","id":"run-1","estado":"abierta","lanes":[{"id":"lane-1","estado":"reservado","events":[],
 "selection":{"winner":"codex","health":"available","score":90,"parts":{"fit":90},"candidates":[],"discarded":[]}}]}
(base / "corridas/run-1/registro.json").write_text(json.dumps(reg))
PY
cat > "$tmp/bin/openclaw" <<'SH'
#!/bin/sh
python3 - "$@" <<'PY'
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
method=args[args.index('call')+1]
params=json.loads(args[args.index('--params')+1])
path=Path(os.environ['FAKE_PROGRESS_STATE'])
state=json.loads(path.read_text()) if path.exists() else {'events':[], 'fail_worker_once':True}
doc=json.loads(Path(os.environ['FAKE_PROGRESS_STATE']).with_name('doc.json').read_text())
if method=='runbook.progress.get':
    response={'ok':True,'doc':doc}
    if state['events']: response['revision']=len(state['events'])
elif method=='runbook.progress.event':
    if params['kind']=='run.opened' and state.get('reject_open_count',0):
        state['reject_open_count']-=1
        response={'ok':False,'reason':'legacy projection changed or invalid'}
    elif params['kind']=='run.opened' and params['doc']!=doc:
        response={'ok':False,'reason':'legacy projection changed or invalid'}
    elif params['kind']=='part.worker' and state['fail_worker_once']:
        state['fail_worker_once']=False
        response={'ok':False,'reason':'network'}
    elif any(e['id']==params['id'] for e in state['events']):
        response={'ok':True,'revision':len(state['events']),'duplicate':True}
    else:
        state['events'].append(params)
        response={'ok':True,'revision':len(state['events'])}
else:
    raise SystemExit('unexpected method: '+method)
path.write_text(json.dumps(state))
print(json.dumps(response))
PY
SH
chmod +x "$tmp/bin/openclaw"
bash -c '. scripts/mac/corrida/lib.sh; . scripts/mac/corrida/adaptador.sh; adaptador_registrar_sesion "$1" lane-1 codex session-7' _ "$tmp/corridas/run-1/registro.json"
for attempt in 1 2 3; do
  bash -c '. scripts/mac/corrida/lib.sh; tablero_carril_publicar run-1 lane-1' >"$tmp/out" 2>"$tmp/err"
  [ ! -s "$tmp/out" ] || { cat "$tmp/out"; exit 1; }
done
# El arranque inicial no registra observed.launched. El primer relevo recibe
# una nueva tenencia al registrar su sesion, y la confirmacion la conserva.
python3 - "$tmp/corridas/run-1/registro.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); c=d['lanes'][0]
assert c['progress_worker_generation']==0, c
c['events'].append({'id':'successor-1','kind':'intent.launch_successor',
                    'payload':{'worker':'codex','session':'session-7'}})
del c['progress_worker_generation']
json.dump(d,open(p,'w'))
PY
# Un registro legado puede recibir el intent antes de migrar. Mientras siga
# activo el predecesor, no debe cambiar su generacion, incluso si se reusa
# el mismo worker y el mismo nombre de sesion.
bash -c '. scripts/mac/corrida/lib.sh; tablero_carril_publicar run-1 lane-1' >"$tmp/out" 2>"$tmp/err"
python3 - "$tmp/gateway.json" "$tmp/corridas/run-1/registro.json" <<'PY'
import json,sys
assert len(json.load(open(sys.argv[1]))['events'])==2
p=sys.argv[2]; d=json.load(open(p)); c=d['lanes'][0]
c['estado']='reservado'
for key in ('worker','session','harness','provider','model','effort','reported_model'):
    c.pop(key,None)
json.dump(d,open(p,'w'))
PY
bash -c '. scripts/mac/corrida/lib.sh; . scripts/mac/corrida/adaptador.sh; adaptador_registrar_sesion "$1" lane-1 codex session-7' _ "$tmp/corridas/run-1/registro.json"
bash -c '. scripts/mac/corrida/lib.sh; tablero_carril_publicar run-1 lane-1' >"$tmp/out" 2>"$tmp/err"
python3 - "$tmp/corridas/run-1/registro.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['lanes'][0]['events'].append(
 {'id':'launch-1','kind':'observed.launched','payload':{'worker':'codex','session':'session-7'}})
json.dump(d,open(p,'w'))
PY
bash -c '. scripts/mac/corrida/lib.sh; tablero_carril_publicar run-1 lane-1' >"$tmp/out" 2>"$tmp/err"
python3 - "$tmp/gateway.json" "$tmp/outbox" <<'PY'
import json, pathlib, sys
events=json.load(open(sys.argv[1]))['events']
assert [e['kind'] for e in events]==['run.opened','part.worker','part.worker'], events
assert events[0]['doc']['notas']==['nota del lead'] and events[0]['roundBudget']=={} and events[0]['importLegacy'] is True, events[0]
worker=events[1]
assert worker['corrida']=='run-1' and worker['carril']=='lane-1', worker
assert worker['generation']==0 and events[2]['generation']==1, events
assert worker['worker']=={'id':'codex','harness':'codex-cli','provider':'openai','model':'router',
 'effort':'medium','reported_model':None,'health':'available'}, worker['worker']
assert 'puntaje 90' in worker['note'], worker['note']
assert events[2]['id']!=worker['id'] and events[2]['worker']['id']=='codex', events[2]
assert json.load(open(pathlib.Path(sys.argv[1]).parent/'corridas/run-1/registro.json'))['lanes'][0]['progress_worker_generation']==1
assert len(list(pathlib.Path(sys.argv[2]).glob('runs/run-1/queue/*.json')))==0
assert len(list(pathlib.Path(sys.argv[2]).glob('runs/run-1/sent/*.json')))==3
PY
# Tres versiones del mismo snapshot legacy durante una caida conservan tres
# IDs de importacion. Las dos obsoletas se archivan y la ultima se publica.
python3 - "$tmp" <<'PY'
import json,sys
from pathlib import Path
b=Path(sys.argv[1]); d=json.loads((b/'doc.json').read_text()); d['corrida']='run-legacy'
(b/'doc.json').write_text(json.dumps(d))
reg={'schema':'corrida.v2','id':'run-legacy','estado':'abierta','lanes':[
 {'id':'lane-1','estado':'activo','worker':'codex','session':'session-legacy','events':[]}]}
p=b/'corridas/run-legacy/registro.json'; p.parent.mkdir(parents=True); p.write_text(json.dumps(reg))
(b/'legacy-gateway.json').write_text(json.dumps({'events':[],'fail_worker_once':False,'reject_open_count':2}))
PY
export FAKE_PROGRESS_STATE="$tmp/legacy-gateway.json"
for version in 1 2 3; do
  python3 - "$tmp/doc.json" "$version" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['titulo']='version '+sys.argv[2]
json.dump(d,open(p,'w'))
PY
  bash -c '. scripts/mac/corrida/lib.sh; tablero_carril_publicar run-legacy lane-1' >"$tmp/out" 2>"$tmp/err"
done
python3 - "$tmp" <<'PY'
import json,sys
from pathlib import Path
b=Path(sys.argv[1]); root=b/'outbox/runs/run-legacy'
assert len([p for p in (root/'superseded').glob('open-*.json') if not p.name.endswith('.superseded.json')])==2, list((root/'superseded').glob('*.json'))
assert len(list((root/'sent').glob('open-*.json')))==1, list((root/'sent').glob('*.json'))
events=json.loads((b/'legacy-gateway.json').read_text())['events']
assert [e['kind'] for e in events]==['run.opened','part.worker'], events
assert events[0]['doc']['titulo']=='version 3', events[0]
PY
echo 'ok: worker event imports once and retries durably'

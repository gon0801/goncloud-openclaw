#!/bin/bash
# APLICAR_VIGIA_SYNC.sh — actualiza el mensaje del cron verif-sync-repos (id fijo) a v2.
# Job vivo: 2d763be5-6390-4ccf-a3a4-621c91c41e94; agente main; cron 40 */2 * * * America/New_York;
# tools exec,message,automations. Solo edita --message; no toca horario, agente, tools ni enabled.
# Mensaje: docs/cron-messages/verif-sync-repos.v2.txt
# Forma probada: copia de APLICAR_VERIF_20H.sh (cron edit --message + .pre.json/.post.json).
# Ventanas cerradas (corridas de negocio): 12:55-13:35Z (7h) 16:55-17:25Z (11h) 01:55-02:25Z (20h).
# Uso: ./docs/cron-messages/APLICAR_VIGIA_SYNC.sh          # edit + verify (lo corre el lead en Q2)
#      ./docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test   # seco: no toca el gateway; valida msg local
# Compatible con bash 3.2 (macOS).
set -u
cd "$(dirname "$0")/../.." || exit 1
OC=~/.openclaw/bin/openclaw
ID=2d763be5-6390-4ccf-a3a4-621c91c41e94
NAME=verif-sync-repos
MSG=docs/cron-messages/verif-sync-repos.v2.txt
mkdir -p docs/cron-messages/backup docs/cron-messages/evidence
LOCKDIR=/tmp/aplicar_vigia_sync.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "ABORTO: otra corrida en curso ($LOCKDIR)."; exit 1; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
now_min() { date -u +%H:%M | awk -F: '{print $1*60+$2}'; }
in_win() { a=$(echo "$1" | awk -F: '{print $1*60+$2}'); b=$(echo "$2" | awk -F: '{print $1*60+$2}'); n=$(now_min); [ "$n" -ge "$a" ] && [ "$n" -lt "$b" ]; }
for w in "12:55 13:35" "16:55 17:25" "01:55 02:25"; do
  # shellcheck disable=SC2086
  if in_win $w; then echo "ABORTO: dentro de ventana cerrada ($w UTC)."; exit 1; fi
done
TS=$(date -u +%Y%m%dT%H%M%SZ)-$$
DRY=0
[ "${1:-}" = "--test" ] && DRY=1

# --- 0. Chequeo local del mensaje (ASCII, anclas) antes de tocar el gateway.
python3 - "$MSG" <<'PY' || exit 1
import sys
m=open(sys.argv[1]).read()
body=m.rstrip('\n')
def fail(x): print('MSG_FAIL:', x); sys.exit(1)
bad=[c for c in body if ord(c)>127]
if bad: fail('no-ASCII: %r' % bad[:5])
if '$(' in body or '`' in body: fail('command substitution / backticks')
for a in ['LOG=', 'VIGIA SYNC REPOS v2', 'CASO A', 'CASO B', 'CASO C', 'CASO D',
          'SKILLS', 'skill-collection-review-', 'Ya esta en main',
          'target 6470689715', 'openclaw cron runs', '--limit 1 --json',
          'DIFERIDO_D', '23:00 a 08:00']:
    if a not in body: fail('falta ancla %r' % a)
if not body.startswith('LOG='): fail('LOG= debe ser la primera linea')
print('msg local OK, len', len(body), 'lines', body.count('\n')+1)
PY

if [ "$DRY" -eq 1 ]; then
  echo "== --test (seco): no se edita el gateway"
  # Escribe un .pre/.post de ejemplo a partir del get actual (solo lectura) + message del .txt,
  # para que el commit tenga artefactos verificables sin aplicar.
  $OC cron get "$ID" --json > "docs/cron-messages/backup/$ID.$TS.pre.json" 2>/dev/null \
    || { echo "ABORTO: cron get (lectura) fallo"; exit 1; }
  python3 - "$ID" "$TS" "$MSG" <<'PY' || exit 1
import json,sys
uid,ts,msgf=sys.argv[1:4]
pre=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.pre.json'))
want=open(msgf).read().rstrip('\n')
post=json.loads(json.dumps(pre))
post['payload']=dict(post.get('payload') or {})
post['payload']['message']=want
out=f'docs/cron-messages/backup/{uid}.{ts}.post.json'
json.dump(post, open(out,'w'), indent=2, ensure_ascii=False)
open(out,'a').write('\n')
# verify contract
def fail(x): print('VERIFY_FAIL:', x); sys.exit(1)
if post['payload']['message']!=want: fail('message != txt')
if post.get('agentId')!=pre.get('agentId'): fail('agentId muto')
if post.get('schedule')!=pre.get('schedule'): fail('schedule muto')
if (post.get('payload') or {}).get('toolsAllow')!=(pre.get('payload') or {}).get('toolsAllow'): fail('toolsAllow muto')
if post.get('enabled')!=pre.get('enabled'): fail('enabled muto')
print(f"seco OK: pre+post en backup/ agentId={post.get('agentId')} toolsAllow={post['payload'].get('toolsAllow')} enabled={post.get('enabled')}")
PY
  echo "FIN seco. Artefactos: backup/$ID.$TS.pre.json backup/$ID.$TS.post.json"
  echo "(El lead aplica de verdad en Q2 sin --test.)"
  exit 0
fi

# --- 1. edit (message desde archivo)
echo "== edit $NAME ($ID) $(date -u +%H:%M:%SZ)"
$OC cron get "$ID" --json > "docs/cron-messages/backup/$ID.$TS.pre.json" 2>/dev/null \
  || { echo "ABORTO: backup pre-edit fallo"; exit 1; }
$OC cron edit "$ID" --message "$(cat "$MSG")" >/dev/null \
  || { echo "ABORTO: cron edit fallo"; exit 1; }

# --- 2. verify contra lo persistido
$OC cron get "$ID" --json > "docs/cron-messages/backup/$ID.$TS.post.json" 2>/dev/null \
  || { echo "ABORTO: post-get fallo"; exit 1; }
python3 - "$ID" "$TS" "$MSG" <<'PY' || { echo "VERIFY FALLO: revisar backup/$ID.$TS.post.json"; exit 1; }
import json,sys
uid,ts,msgf=sys.argv[1:4]
pre=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.pre.json'))
d=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.post.json'))
def fail(x): print('VERIFY_FAIL:', x); sys.exit(1)
if d.get('ok') is False: fail(d)
want=open(msgf).read().rstrip('\n'); m=d['payload']['message']
if m!=want: fail('message persistido != archivo')
if any(ord(c)>127 for c in m): fail('no-ASCII persistido')
if d.get('agentId')!=pre.get('agentId'): fail('agentId %r (era %r)' % (d.get('agentId'), pre.get('agentId')))
if d.get('schedule')!=pre.get('schedule'): fail('schedule muto: %r' % d.get('schedule'))
if d['payload'].get('toolsAllow')!=(pre.get('payload') or {}).get('toolsAllow'):
    fail('toolsAllow muto: %r' % d['payload'].get('toolsAllow'))
if d.get('enabled')!=pre.get('enabled'): fail('enabled muto')
print(f"verify OK: id={uid} rev={d.get('configRevision','')[:24]}... next={d.get('state',{}).get('nextRunAtMs')} toolsAllow={d['payload'].get('toolsAllow')}")
PY
echo "$NAME listo: $ID"
echo "FIN. Evidencia: backup/$ID.$TS.post.json"
echo "Reversa: cron edit $ID --message \"\$(python3 -c 'import json;print(json.load(open(\"docs/cron-messages/backup/$ID.$TS.pre.json\"))[\"payload\"][\"message\"])')\""

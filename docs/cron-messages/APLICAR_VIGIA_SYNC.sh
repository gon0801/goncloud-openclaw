#!/bin/bash
# APLICAR_VIGIA_SYNC.sh — actualiza el mensaje del cron verif-sync-repos (id fijo) a v2.
# Job vivo: 2d763be5-6390-4ccf-a3a4-621c91c41e94; agente main; cron 40 */2 * * * America/New_York;
# tools exec,message,automations. Solo edita --message; no toca horario, agente, tools ni enabled.
# Mensaje: docs/cron-messages/verif-sync-repos.v2.txt
# Forma probada: copia de APLICAR_VERIF_20H.sh (cron edit --message + .pre.json/.post.json).
# Ventanas cerradas (corridas de negocio): 12:55-13:35Z (7h) 16:55-17:25Z (11h) 01:55-02:25Z (20h).
#
# Uso:
#   ./docs/cron-messages/APLICAR_VIGIA_SYNC.sh
#       edit + verify (lead en Q2)
#   ./docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test
#       seco: valida msg, fabrica pre/post de ejemplo, DECLARA el recorrido D1/D2
#       (no crea jobs). La corrida real falta hasta Q2.
#   VIGIA_SYNC_EJECUTAR=1 ./docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test
#       Q2: seco + crea/corre/borra vigia-sync-prueba-D1 y D2 (--tools exec),
#       evidencia en .saikit/scratch/M/*.runs.json. No edita el vigia vivo.
#
# Compatible con bash 3.2 (macOS).
set -u
cd "$(dirname "$0")/../.." || exit 1
OC=~/.openclaw/bin/openclaw
ID=2d763be5-6390-4ccf-a3a4-621c91c41e94
NAME=verif-sync-repos
MSG=docs/cron-messages/verif-sync-repos.v2.txt
LOG_PRUEBA='C:\Users\ehven\.openclaw-state\vigia-sync-prueba\sync-repos.log'
# Linea SKILLS real del snapshot 43097da (verifier, 10 archivos).
SKILLS_LINE='2026-09-19 09:10:00 .openclaw SKILLS verifier 10 archivo(s): cron-payload-verify/SKILL.md,egress-suppression-verify/SKILL.md,lane-claim-verify/SKILL.md,lane-claim-verify/history-rewrite.md,regression-triage/SKILL.md,regression-triage/full-battery.md,test-discrimination-verify/SKILL.md,test-discrimination-verify/fixtures.md,test-discrimination-verify/live-leak-probe.md,test-discrimination-verify/rules.md'
mkdir -p docs/cron-messages/backup docs/cron-messages/evidence .saikit/scratch/M
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
EJECUTAR=0
[ "${VIGIA_SYNC_EJECUTAR:-0}" = "1" ] && EJECUTAR=1

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
          'DIFERIDO_D', '23:00 a 08:00', 'tail -400', 'Lo reviso ahora?',
          'cola leida en PASO 1']:
    if a not in body: fail('falta ancla %r' % a)
# La instruccion de lectura debe ser tail -400 (el minimo); mencionar el bug
# viejo de tail -80 en la prosa de la ventana esta bien.
if 'tail -400 de la ruta LOG=' not in body:
    fail('PASO 1 debe mandar tail -400 de la ruta LOG=')
if not body.startswith('LOG='): fail('LOG= debe ser la primera linea')
print('msg local OK, len', len(body), 'lines', body.count('\n')+1)
PY

msg_con_log_prueba() {
  # Primera linea LOG= apunta al log de prueba; el resto igual.
  python3 - "$MSG" "$LOG_PRUEBA" <<'PY'
import sys
msg=open(sys.argv[1]).read().rstrip('\n')
log=sys.argv[2]
lines=msg.split('\n')
if not lines[0].startswith('LOG='):
    raise SystemExit('MSG sin LOG= inicial')
lines[0]='LOG='+log
sys.stdout.write('\n'.join(lines))
PY
}

declarar_recorrido_d1_d2() {
  echo "== recorrido D1/D2 (lo que Q2 ejecuta con VIGIA_SYNC_EJECUTAR=1 $0 --test)"
  echo "LOG_PRUEBA=$LOG_PRUEBA"
  echo "D1 name=vigia-sync-prueba-D1  tools=exec  mensaje=v2 con LOG=prueba"
  echo "    log = cola (tail -400 del sync real o fixture) + linea SKILLS de 43097da:"
  echo "    $SKILLS_LINE"
  echo "    expect: summary/salida nombra verifier y sus archivos (CASO D); Telegram imposible (--tools exec)"
  echo "D2 name=vigia-sync-prueba-D2  tools=exec  mismo mensaje"
  echo "    log = misma cola SIN la linea SKILLS"
  echo "    expect: callado en D (nada que avisar por skills)"
  echo "ambos: --at 30m --session isolated --no-deliver --keep-after-run"
  echo "        cron run --wait --wait-timeout 10m"
  echo "        evidencia: .saikit/scratch/M/vigia-sync-prueba-D1.$TS.runs.json (y D2)"
  echo "        cleanup: cron rm de cada id"
  echo "armado del log en el gateway (antes del run), por exec:"
  echo "  mkdir -p .../vigia-sync-prueba; armar D1 con SKILLS; copiar a D2 sin SKILLS (o reescribir entre runs)"
}

ejecutar_pruebas_d1_d2() {
  echo "== PRUEBA D1/D2 $(date -u +%H:%M:%SZ)  (VIGIA_SYNC_EJECUTAR=1)"
  local MSG_PRUEBA
  MSG_PRUEBA=$(msg_con_log_prueba) || return 1
  # Aviso: el log de prueba debe existir YA en el gateway en LOG_PRUEBA.
  # Q2 lo arma (cola real + SKILLS_LINE) antes de este bloque; D2 se arma sin la linea
  # entre el run de D1 y el de D2, o con dos archivos si se prefiere.
  echo "-- armado esperado del log: $LOG_PRUEBA (D1 con SKILLS; D2 sin ella)"
  echo "-- SKILLS_LINE: $SKILLS_LINE"

  run_one() {
    local label="$1"  # D1 o D2
    local jname="vigia-sync-prueba-$label"
    echo "== add $jname"
    local OUT TID
    OUT=$($OC cron add --name "$jname" --agent main --session isolated --no-deliver \
      --at 30m --keep-after-run --timeout-seconds 600 --tools exec \
      --description "Prueba CASO D del vigia sync ($label); solo exec, sin Telegram." \
      --message "$MSG_PRUEBA" --json 2>&1) \
      || { echo "PRUEBA $label: add fallo: $OUT" | cut -c1-400; return 1; }
    TID=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("job",{}).get("id",""))' 2>/dev/null)
    [ -n "$TID" ] || { echo "PRUEBA $label: sin id: $OUT" | cut -c1-400; return 1; }
    echo "-- $jname id=$TID"
    echo "-- run --wait (max 10m)"
    $OC cron run "$TID" --wait --wait-timeout 10m --json \
      > ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.run.json" 2>&1 || true
    $OC cron runs "$TID" --limit 1 --json \
      > ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.runs.json" 2>&1 || true
    python3 - "$label" "$TS" <<'PY'
import json,sys
label,ts=sys.argv[1:3]
path=f'.saikit/scratch/M/vigia-sync-prueba-{label}.{ts}.runs.json'
try:
    r=json.load(open(path))
    e=(r.get('entries') or r.get('runs') or [None])[0] or {}
    print(f'PRUEBA {label} status:', e.get('status'), e.get('completionStatus'),
          'dur:', (e.get('durationMs') or 0)//1000, 's')
    print(f'PRUEBA {label} summary:', (e.get('summary') or '<sin summary>')[:700])
except Exception as ex:
    print(f'PRUEBA {label}: no pude leer runs:', ex)
PY
    echo "-- rm $TID"
    $OC cron rm "$TID" >/dev/null 2>&1 && echo "rm $TID OK" || echo "rm $TID FALLO: borrar a mano"
    echo "$TID"
  }

  echo "NOTA Q2: antes de D1, escribir en el gateway $LOG_PRUEBA = cola + SKILLS_LINE."
  echo "NOTA Q2: antes de D2, reescribir el mismo archivo SIN la linea SKILLS."
  run_one D1 || return 1
  echo "NOTA Q2: ahora el log debe quedar sin la linea SKILLS para D2."
  run_one D2 || return 1
  echo "PRUEBA D1/D2 terminada. Evidencia en .saikit/scratch/M/vigia-sync-prueba-D*.$TS.runs.json"
}

if [ "$DRY" -eq 1 ]; then
  echo "== --test (seco): no se edita el vigia vivo"
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
def fail(x): print('VERIFY_FAIL:', x); sys.exit(1)
if post['payload']['message']!=want: fail('message != txt')
if post.get('agentId')!=pre.get('agentId'): fail('agentId muto')
if post.get('schedule')!=pre.get('schedule'): fail('schedule muto')
if (post.get('payload') or {}).get('toolsAllow')!=(pre.get('payload') or {}).get('toolsAllow'): fail('toolsAllow muto')
if post.get('enabled')!=pre.get('enabled'): fail('enabled muto')
print(f"seco OK: pre+post en backup/ agentId={post.get('agentId')} toolsAllow={post['payload'].get('toolsAllow')} enabled={post.get('enabled')}")
PY
  declarar_recorrido_d1_d2
  if [ "$EJECUTAR" -eq 1 ]; then
    ejecutar_pruebas_d1_d2 || exit 1
  else
    echo "SECO: no se crearon jobs. Falta la corrida real en Q2:"
    echo "  VIGIA_SYNC_EJECUTAR=1 $0 --test"
  fi
  echo "FIN seco. Artefactos: backup/$ID.$TS.pre.json backup/$ID.$TS.post.json"
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

#!/bin/bash
# APLICAR_VERIF_20H.sh — crea (o actualiza) el cron verif-digest-20h en el gateway y lo verifica.
# Job: agente main, sesion aislada, sin entrega, dom-jue 20:45 CDMX, timeout 600 s.
# Mensaje: docs/cron-messages/verif-digest-20h.v1.txt (una linea, ASCII puro).
# Idempotente: si ya existe un job con ese nombre, edita el message en vez de duplicar.
# Crear un cron NO publica config (vive en sqlite): no invalida runtimes de agentes en vuelo.
# Ventanas cerradas (corridas de negocio): 12:55-13:35Z (7h) 16:55-17:25Z (11h) 01:55-02:25Z (20h).
# Uso: ./docs/cron-messages/APLICAR_VERIF_20H.sh          # add-or-update + verify
#      ./docs/cron-messages/APLICAR_VERIF_20H.sh --test   # ademas corre una PRUEBA one-shot
#        (MODO PRUEBA: clasifica contra datos reales, NO manda Telegram) y muestra su resultado.
# Compatible con bash 3.2 (macOS).
set -u
cd "$(dirname "$0")/../.." || exit 1
OC=~/.openclaw/bin/openclaw
NAME=verif-digest-20h
MSG=docs/cron-messages/verif-digest-20h.v1.txt
mkdir -p docs/cron-messages/backup docs/cron-messages/evidence
LOCKDIR=/tmp/aplicar_verif_20h.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "ABORTO: otra corrida en curso ($LOCKDIR)."; exit 1; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
now_min() { date -u +%H:%M | awk -F: '{print $1*60+$2}'; }
in_win() { a=$(echo "$1" | awk -F: '{print $1*60+$2}'); b=$(echo "$2" | awk -F: '{print $1*60+$2}'); n=$(now_min); [ "$n" -ge "$a" ] && [ "$n" -lt "$b" ]; }
for w in "12:55 13:35" "16:55 17:25" "01:55 02:25"; do
  # shellcheck disable=SC2086
  if in_win $w; then echo "ABORTO: dentro de ventana cerrada ($w UTC)."; exit 1; fi
done
TS=$(date -u +%Y%m%dT%H%M%SZ)-$$

# --- 0. Chequeo local del mensaje (ASCII, una linea, anclas) antes de tocar el gateway.
python3 - "$MSG" <<'PY' || exit 1
import sys
m=open(sys.argv[1]).read()
body=m.rstrip('\n')
def fail(x): print('MSG_FAIL:', x); sys.exit(1)
if '\n' in body: fail('mas de una linea')
bad=[c for c in body if ord(c)>127]
if bad: fail('no-ASCII: %r' % bad[:5])
if '$(' in body or '`' in body: fail('command substitution / backticks')
for a in ['INTENTO 1/3','eeae2a74-6389-4e83-a80a-d0ae6cdc7988','agent:operaciones:cron:eeae2a74-6389-4e83-a80a-d0ae6cdc7988',
          'CASO A','CASO B','CASO C','envios-del-dia','NUNCA correr','target 6470689715','MODO PRUEBA','INTENTO 3/3']:
    if a not in body: fail('falta ancla %r' % a)
print('msg local OK, len', len(body))
PY

# --- 1. Existe ya? (por nombre)
EXISTING=$($OC cron list --json 2>/dev/null | python3 -c '
import json,sys; d=json.load(sys.stdin); jobs=d.get("jobs") or d
ids=[j["id"] for j in jobs if j.get("name")==sys.argv[1]]
print(" ".join(ids))' "$NAME")
case "$(echo $EXISTING | wc -w | tr -d ' ')" in
  0) ACTION=add ;;
  1) ACTION=edit; ID=$EXISTING ;;
  *) echo "ABORTO: hay varios jobs llamados $NAME ($EXISTING); limpiar a mano."; exit 1 ;;
esac

# --- 2. add o edit (message siempre desde archivo, nunca retipeado)
if [ "$ACTION" = add ]; then
  echo "== add $NAME $(date -u +%H:%M:%SZ)"
  OUT=$($OC cron add --name "$NAME" --agent main --session isolated --no-deliver \
        --cron "45 20 * * 0-4" --tz America/Mexico_City --exact --timeout-seconds 600 \
        --description "Verifica que el digest packing-digest-20h salio; si no, avisa a David por Telegram. Solo lectura." \
        --message "$(cat "$MSG")" --json 2>&1) || { echo "ABORTO: cron add fallo: $OUT" | cut -c1-400; exit 1; }
  ID=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("job",{}).get("id",""))' 2>/dev/null)
  [ -n "$ID" ] || { echo "ABORTO: no pude leer el id del add: $OUT" | cut -c1-400; exit 1; }
else
  echo "== edit $NAME ($ID) $(date -u +%H:%M:%SZ)"
  $OC cron get "$ID" --json > "docs/cron-messages/backup/$ID.$TS.pre.json" 2>/dev/null || { echo "ABORTO: backup pre-edit fallo"; exit 1; }
  $OC cron edit "$ID" --message "$(cat "$MSG")" --timeout-seconds 600 >/dev/null || { echo "ABORTO: cron edit fallo"; exit 1; }
fi

# --- 3. verify contra lo persistido
$OC cron get "$ID" --json > "docs/cron-messages/backup/$ID.$TS.post.json" 2>/dev/null || { echo "ABORTO: post-get fallo"; exit 1; }
python3 - "$ID" "$TS" "$MSG" <<'PY' || { echo "VERIFY FALLO: revisar backup/$ID.$TS.post.json (el job queda creado; corregir con cron edit o cron rm)"; exit 1; }
import json,sys
uid,ts,msgf=sys.argv[1:4]
d=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.post.json'))
def fail(x): print('VERIFY_FAIL:', x); sys.exit(1)
if d.get('ok') is False: fail(d)
want=open(msgf).read().rstrip('\n'); m=d['payload']['message']
if m!=want: fail('message persistido != archivo')
if any(ord(c)>127 for c in m): fail('no-ASCII persistido')
if d.get('agentId')!='main': fail('agentId %r' % d.get('agentId'))
if d.get('sessionTarget')!='isolated': fail('sessionTarget %r' % d.get('sessionTarget'))
if d.get('delivery',{}).get('mode')!='none': fail('delivery %r' % d.get('delivery'))
s=d.get('schedule',{})
if s.get('expr')!='45 20 * * 0-4' or s.get('tz')!='America/Mexico_City': fail('schedule %r' % s)
if d['payload'].get('timeoutSeconds')!=600: fail('timeout %r' % d['payload'].get('timeoutSeconds'))
if not d.get('enabled'): fail('disabled')
print(f"verify OK: id={uid} rev={d['configRevision'][:24]}... next={d.get('state',{}).get('nextRunAtMs')} toolsAllow={d['payload'].get('toolsAllow')}")
PY
echo "$NAME listo: $ID"

# --- 4. PRUEBA opcional: one-shot MODO PRUEBA (no manda Telegram), lo corro ya y leo el resultado.
if [ "${1:-}" = "--test" ]; then
  echo "== PRUEBA one-shot $(date -u +%H:%M:%SZ)"
  TOUT=$($OC cron add --name "$NAME-PRUEBA" --agent main --session isolated --no-deliver \
         --at 30m --keep-after-run --timeout-seconds 600 \
         --message "MODO PRUEBA (no enviar Telegram; en CASO C solo terminar con la linea VERIF 20H FALLA). $(cat "$MSG")" --json 2>&1) \
         || { echo "PRUEBA: add fallo: $TOUT" | cut -c1-300; exit 1; }
  TID=$(printf '%s' "$TOUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("job",{}).get("id",""))' 2>/dev/null)
  [ -n "$TID" ] || { echo "PRUEBA: sin id: $TOUT" | cut -c1-300; exit 1; }
  echo "-- run --wait (max 10m) job $TID"
  $OC cron run "$TID" --wait --wait-timeout 10m --json > "docs/cron-messages/evidence/verif-20h-prueba.$TS.json" 2>&1
  $OC cron runs "$TID" --limit 1 --json > "docs/cron-messages/evidence/verif-20h-prueba.$TS.runs.json" 2>&1
  python3 - "$TS" <<'PY'
import json,sys
ts=sys.argv[1]
try:
    r=json.load(open(f'docs/cron-messages/evidence/verif-20h-prueba.{ts}.runs.json'))
    e=(r.get('entries') or r.get('runs') or [None])[0] or {}
    print('PRUEBA status:', e.get('status'), e.get('completionStatus'), 'model:', e.get('provider'), e.get('model'), 'dur:', (e.get('durationMs') or 0)//1000, 's')
    print('PRUEBA summary:', (e.get('summary') or '<sin summary>')[:700])
except Exception as ex:
    print('PRUEBA: no pude leer runs:', ex)
PY
  echo "-- limpio el job de prueba"
  $OC cron rm "$TID" >/dev/null 2>&1 && echo "rm $TID OK" || echo "rm $TID FALLO: borrar a mano"
fi
echo "FIN. Evidencia: backup/$ID.$TS.post.json"

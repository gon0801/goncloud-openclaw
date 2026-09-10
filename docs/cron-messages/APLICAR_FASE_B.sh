#!/bin/bash
# APLICAR_FASE_B.sh — B1 (v14 en 7h/11h/20h + timeout 20h) + B2 (report message).
# CORRER SOLO DESPUES DE 13:35Z del 10-sep y FUERA de ventanas cerradas:
#   12:55-13:35Z (7h)  13:40-14:05Z (verif)  16:55-17:25Z (11h)  01:55-02:25Z (20h)
# Hace backup fresco de cada job, regenera el message desde ESE backup,
# edita desde archivo y verifica (message exacto, ASCII, configRevision, anclas).
# Si un verify falla, restaura el message del backup y aborta (rollback best-effort).
# Compatible con bash 3.2 (macOS): sin arrays asociativos.
# Uso: ./docs/cron-messages/APLICAR_FASE_B.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
OC=~/.openclaw/bin/openclaw
mkdir -p docs/cron-messages/backup
LOCKDIR=/tmp/aplicar_fase_b.lock
if ! mkdir "$LOCKDIR" 2>/dev/null; then echo "ABORTO: otra corrida en curso ($LOCKDIR)."; exit 1; fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
uuid_for() { # $1=7h|11h|20h -> uuid en stdout
  case "$1" in
    7h) echo 76b279ba-1a21-4d74-9a56-41da9514559e ;;
    11h) echo 9e907473-a32e-46e6-b2bf-180aadf3f14c ;;
    20h) echo eeae2a74-6389-4e83-a80a-d0ae6cdc7988 ;;
  esac
}
now_min() { date -u +%H:%M | awk -F: '{print $1*60+$2}'; }
in_win() { # $1=HH:MM $2=HH:MM -> 0 si ahora dentro
  a=$(echo "$1" | awk -F: '{print $1*60+$2}'); b=$(echo "$2" | awk -F: '{print $1*60+$2}'); n=$(now_min)
  [ "$n" -ge "$a" ] && [ "$n" -lt "$b" ]
}
check_windows() { # aborta si estamos en ventana cerrada (se re-chequea por job)
  for w in "12:55 13:35" "13:40 14:05" "16:55 17:25" "01:55 02:25"; do
    # shellcheck disable=SC2086
    if in_win $w; then echo "ABORTO: dentro de ventana cerrada ($w UTC)."; exit 1; fi
  done
}
need_get() { # $1=id $2=outfile -> 0 si trajo un job valido (no {"ok":false})
  $OC cron get "$1" --json > "$2" 2>/dev/null || return 1
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("ok",True) is not False else 1)' "$2" || return 1
}
rollback() { # $1=id $2=pre-backup.json -> restaura message previo, best-effort
  echo "ROLLBACK $1 desde $2"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["payload"]["message"])' "$2" > /tmp/fb_rollback.txt \
    && $OC cron edit "$1" --message "$(cat /tmp/fb_rollback.txt)" >/dev/null \
    && echo "rollback OK" || echo "ROLLBACK FALLO: restaurar a mano desde $2"
}
check_windows
echo "OK ventanas: $(date -u +%H:%MZ), fuera de corridas."
TS=$(date -u +%Y%m%dT%H%M%SZ)-$$
for job in 7h 11h 20h; do
  id=$(uuid_for "$job")
  echo "===== B1 $job ($id) $TS"
  check_windows
  need_get "$id" "docs/cron-messages/backup/$id.$TS.json" || { echo "ABORTO: cron get $job fallo"; exit 1; }
  python3 docs/cron-messages/gen_v14.py --src "docs/cron-messages/backup/$id.$TS.json" --job "$job" --out "docs/cron-messages/$job.$TS.v14.txt" || exit 1
  [ -s "docs/cron-messages/$job.$TS.v14.txt" ] || { echo "ABORTO: v14 vacio"; exit 1; }
  echo "-- edit $(date -u +%H:%M:%SZ)"
  if [ "$job" = 20h ]; then
    $OC cron edit "$id" --message "$(cat "docs/cron-messages/$job.$TS.v14.txt")" --timeout-seconds 3600 || exit 1
  else
    $OC cron edit "$id" --message "$(cat "docs/cron-messages/$job.$TS.v14.txt")" || exit 1
  fi
  need_get "$id" "docs/cron-messages/backup/$id.$TS.post.json" || { echo "ABORTO: post-get $job fallo"; rollback "$id" "docs/cron-messages/backup/$id.$TS.json"; exit 1; }
  if ! python3 - "$id" "$job" "$TS" <<'PY'; then
import json,sys
def fail(msg):
    print(f'VERIFY_FAIL: {msg}'); sys.exit(1)
uid,job,ts=sys.argv[1],sys.argv[2],sys.argv[3]
pre=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.json'))
post=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.post.json'))
want=open(f'docs/cron-messages/{job}.{ts}.v14.txt').read().rstrip('\n')
m=post['payload']['message']
if m != want: fail('message persistido != generado')
if not all(ord(c) < 128 for c in m): fail('no-ASCII')
if 'v14' not in m.split('\n')[0]: fail('sin marker v14')
if post['configRevision']==pre['configRevision']: fail('configRevision no cambio')
if job == '20h' and post['payload'].get('timeoutSeconds')!=3600: fail('timeout no quedo')
for a in ['v14 single-line','CENSUS V2 v4c','div[role=option]','tr[role=row]',
          '/home/claw/send_sales_digest.sh']:
    if m.count(a)!=1: fail(f'{a}: {m.count(a)}x')
exp2x=1 if job=='20h' else 2  # +R7 y +GUARD solo en 7h/11h
if m.count('sessions_send agent:main:main')!=exp2x: fail('sessions_send count')
if m.count('tool message')!=exp2x: fail('tool message count')
print(f'verify {job}: message exacto, ascii, rev {post["configRevision"][:24]}..., timeout ok')
PY
    echo "VERIFY FALLO en $job"
    rollback "$id" "docs/cron-messages/backup/$id.$TS.json"
    exit 1
  fi
done
echo "===== B2 report-7h-estreno"
RID=74e9a2e7-076a-49f0-9245-96300ab049ac
check_windows
if ! need_get "$RID" "docs/cron-messages/backup/$RID.$TS.json"; then
  if grep -qi 'not found' "docs/cron-messages/backup/$RID.$TS.json" 2>/dev/null; then
    echo "report job ya no existe (main lo borro tras reportar): nada que hacer."
  else
    echo "ABORTO: cron get report fallo (red/auth/CLI)"; exit 1
  fi
else
  python3 - "$TS" <<'PY' || exit 1
import json,sys
def fail(msg):
    print(f'B2_REGEN_FAIL: {msg}'); sys.exit(1)
ts=sys.argv[1]
d=json.load(open(f'docs/cron-messages/backup/74e9a2e7-076a-49f0-9245-96300ab049ac.{ts}.json'))
m=d['payload']['message']
a='sessions_history sessionKey=agent:operaciones:main limit=8'
if m.count(a)!=1: fail('ancla B2 != 1x')
m=m.replace(a,'sessions_history sessionKey=agent:main:main limit=8 (el 7h y el verif reportan ahi via sessions_send)')
n=m.count('—')
m=m.replace('—','-')
if '\n' in m: fail('salto de linea')
if any(ord(c) > 127 for c in m): fail('no-ASCII tras sanear')
open(f'docs/cron-messages/report-7h-estreno.B2.{ts}.txt','w').write(m)
print(f'B2 regenerado OK, len {len(m)}, emdash saneados {n}')
PY
  [ -s "docs/cron-messages/report-7h-estreno.B2.$TS.txt" ] || { echo "ABORTO: B2 vacio"; exit 1; }
  echo "-- edit $(date -u +%H:%M:%SZ)"
  $OC cron edit "$RID" --message "$(cat "docs/cron-messages/report-7h-estreno.B2.$TS.txt")" || exit 1
  need_get "$RID" "docs/cron-messages/backup/$RID.$TS.post.json" || { echo "ABORTO: post-get report fallo"; rollback "$RID" "docs/cron-messages/backup/$RID.$TS.json"; exit 1; }
  if ! python3 - "$TS" <<'PY'; then
import json,sys
def fail(msg):
    print(f'VERIFY_FAIL B2: {msg}'); sys.exit(1)
ts=sys.argv[1]
pre=json.load(open(f'docs/cron-messages/backup/74e9a2e7-076a-49f0-9245-96300ab049ac.{ts}.json'))
post=json.load(open(f'docs/cron-messages/backup/74e9a2e7-076a-49f0-9245-96300ab049ac.{ts}.post.json'))
want=open(f'docs/cron-messages/report-7h-estreno.B2.{ts}.txt').read().rstrip('\n')
m=post['payload']['message']
if m != want: fail('message persistido != generado')
if not all(ord(c) < 128 for c in m): fail('no-ASCII')
if post['configRevision']==pre['configRevision']: fail('configRevision no cambio')
if m.count('agent:main:main')!=1: fail('ancla B2 no quedo 1x')
print('verify B2 OK')
PY
    echo "VERIFY FALLO en B2"
    rollback "$RID" "docs/cron-messages/backup/$RID.$TS.json"
    exit 1
  fi
  echo "B2 aplicado y verificado. Tras 14:00Z: 'openclaw cron rm $RID' si main no lo borro."
fi
echo "FASE B1+B2 lista. B3/B4 (scp + T3/T4) van por separado, ver PR."

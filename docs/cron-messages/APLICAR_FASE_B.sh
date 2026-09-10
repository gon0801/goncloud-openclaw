#!/bin/bash
# APLICAR_FASE_B.sh — B1 (v14 en 7h/11h/20h + timeout 20h) + B2 (report message).
# CORRER SOLO DESPUES DE 13:35Z del 10-sep y FUERA de ventanas cerradas:
#   12:55-13:35Z (7h)  13:40-14:05Z (verif)  16:55-17:25Z (11h)  01:55-02:25Z (20h)
# Hace backup fresco de cada job, regenera el message desde ESE backup,
# edita desde archivo y verifica (v14, ASCII, configRevision, anclas 1x).
# Uso: ./docs/cron-messages/APLICAR_FASE_B.sh   (sale 1 = abortado, nada a medias
# por job: cada job es backup->edit->verify atomico en secuencia).
set -u
cd "$(dirname "$0")/../.." || exit 1
OC=~/.openclaw/bin/openclaw
now_min() { date -u +%H:%M | awk -F: '{print $1*60+$2}'; }
in_win() { # $1=HH:MM $2=HH:MM -> 0 si ahora dentro
  a=$(echo "$1" | awk -F: '{print $1*60+$2}'); b=$(echo "$2" | awk -F: '{print $1*60+$2}'); n=$(now_min)
  [ "$n" -ge "$a" ] && [ "$n" -lt "$b" ]
}
for w in "12:55 13:35" "13:40 14:05" "16:55 17:25" "01:55 02:25"; do
  # shellcheck disable=SC2086
  if in_win $w; then echo "ABORTO: dentro de ventana cerrada ($w UTC). Espera a que cierre."; exit 1; fi
done
echo "OK ventanas: $(date -u +%H:%MZ), fuera de corridas."
declare -A UUID=( [7h]=76b279ba-1a21-4d74-9a56-41da9514559e [11h]=9e907473-a32e-46e6-b2bf-180aadf3f14c [20h]=eeae2a74-6389-4e83-a80a-d0ae6cdc7988 )
TS=$(date -u +%Y%m%dT%H%M%SZ)
for job in 7h 11h 20h; do
  id=${UUID[$job]}
  echo "===== B1 $job ($id) $TS"
  $OC cron get "$id" --json > "docs/cron-messages/backup/$id.$TS.json" || exit 1
  python3 docs/cron-messages/gen_v14.py --src "docs/cron-messages/backup/$id.$TS.json" --job "$job" --out "docs/cron-messages/$job.$TS.v14.txt" || exit 1
  echo "-- edit $(date -u +%H:%M:%SZ)"
  $OC cron edit "$id" --message "$(cat "docs/cron-messages/$job.$TS.v14.txt")" || exit 1
  if [ "$job" = 20h ]; then
    echo "-- timeout 20h $(date -u +%H:%M:%SZ)"
    $OC cron edit "$id" --timeout-seconds 3600 || exit 1
  fi
  $OC cron get "$id" --json > "docs/cron-messages/backup/$id.$TS.post.json" || exit 1
  python3 - "$id" "$TS" <<'PY' || exit 1
import json,sys
uid,ts=sys.argv[1],sys.argv[2]
pre=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.json'))
post=json.load(open(f'docs/cron-messages/backup/{uid}.{ts}.post.json'))
m=post['payload']['message']; line1=m.split('\n')[0]
assert 'v14' in line1, 'sin marker v14'
assert m.count('Â')==0, 'mojibake'
assert post['configRevision']!=pre['configRevision'], 'configRevision no cambio'
assert len(m) >= 0.95*len(pre['payload']['message']), 'truncado?'
need=['v14 single-line','CENSUS V2 v4c','div[role=option]','tr[role=row]',
      '/home/claw/send_sales_digest.sh']
for a in need:
    assert m.count(a)==1, f'{a}: {m.count(a)}x'
exp2x=1 if uid.startswith('eeae') else 2  # +R7 y +GUARD solo en 7h/11h
assert m.count('sessions_send agent:main:main')==exp2x, 'sessions_send count'
assert m.count('tool message')==exp2x, 'tool message count'
print(f'verify {uid[:8]}: v14 OK, ascii OK, rev {post["configRevision"][:24]}..., anclas 1x')
PY
done
echo "===== B2 report-7h-estreno"
RID=74e9a2e7-076a-49f0-9245-96300ab049ac
if ! $OC cron get "$RID" --json > "docs/cron-messages/backup/$RID.$TS.json" 2>/dev/null; then
  echo "report job ya no existe (main lo borro tras reportar): nada que hacer."
else
  python3 - "$TS" <<'PY' || exit 1
import json,sys
ts=sys.argv[1]
d=json.load(open(f'docs/cron-messages/backup/74e9a2e7-076a-49f0-9245-96300ab049ac.{ts}.json'))
m=d['payload']['message']
a='sessions_history sessionKey=agent:operaciones:main limit=8'
assert m.count(a)==1, 'ancla B2 != 1x'
m=m.replace(a,'sessions_history sessionKey=agent:main:main limit=8 (el 7h y el verif reportan ahi via sessions_send)')
assert '\n' not in m
open(f'docs/cron-messages/report-7h-estreno.B2.{ts}.txt','w').write(m)
print('B2 regenerado OK, len',len(m))
PY
  echo "-- edit $(date -u +%H:%M:%SZ)"
  $OC cron edit "$RID" --message "$(cat "docs/cron-messages/report-7h-estreno.B2.$TS.txt")" || exit 1
  echo "B2 aplicado. Tras 14:00Z: 'openclaw cron get $RID || cron rm $RID' si main no lo borro."
fi
echo "FASE B1+B2 lista. B3/B4 (scp + T3/T4) van por separado, ver PR."

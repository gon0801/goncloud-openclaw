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

# Franja de silencio CDMX 23:00-08:00: D1 diferiria (DIFERIDO_D) y la asercion fallaria
# sin que nada este roto. Rehusar la corrida real; reintentar fuera de la franja.
en_franja_silencio_cdmx() {
  local h
  h=$(TZ=America/Mexico_City date +%H)
  h=$((10#$h))
  [ "$h" -ge 23 ] || [ "$h" -lt 8 ]
}

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
  echo "ANTES de D1: el script ESCRIBE el log (cola sync + SKILLS_LINE) via cron --command en el gateway"
  echo "D1 name=vigia-sync-prueba-D1  tools=exec  mensaje=v2 con LOG=prueba"
  echo "    expect: assert-d1 → nombra verifier + archivos; Telegram imposible (--tools exec)"
  echo "ANTES de D2: el script REESCRIBE el log (cola SIN lineas SKILLS)"
  echo "D2 name=vigia-sync-prueba-D2  tools=exec  mismo mensaje"
  echo "    expect: assert-d2 → callado en D"
  echo "ambos: --at 30m --session isolated --no-deliver --keep-after-run"
  echo "        cron run --wait --wait-timeout 10m → assert → cron rm verificado con cron list"
  echo "        evidencia: .saikit/scratch/M/vigia-sync-prueba-D*.$TS.runs.json"
}

# Escribe LOG_PRUEBA en el gateway por un one-shot --command (exec del CLI).
# con_skills=1 → cola + SKILLS_LINE; con_skills=0 → cola filtrada sin lineas SKILLS.
escribir_log_prueba() {
  local con_skills="$1"
  local label="$2"
  local LOG_UNIX='/c/Users/ehven/.openclaw-state/vigia-sync-prueba/sync-repos.log'
  local LOG_REAL='/c/Users/ehven/.openclaw/logs/sync-repos.log'
  local DIR_UNIX='/c/Users/ehven/.openclaw-state/vigia-sync-prueba'
  local cmd
  if [ "$con_skills" = "1" ]; then
    # shellcheck disable=SC2016
    cmd=$(printf "mkdir -p '%s' && { tail -400 '%s' 2>/dev/null || true; printf '%%s\\n' '%s'; } > '%s' && (grep -c ' SKILLS ' '%s' || true)" \
      "$DIR_UNIX" "$LOG_REAL" "$SKILLS_LINE" "$LOG_UNIX" "$LOG_UNIX")
  else
    cmd=$(printf "mkdir -p '%s' && { tail -400 '%s' 2>/dev/null || true; } | grep -v ' SKILLS ' > '%s' || :; (grep -c ' SKILLS ' '%s' || echo 0)" \
      "$DIR_UNIX" "$LOG_REAL" "$LOG_UNIX" "$LOG_UNIX")
  fi
  echo "-- escribir_log_prueba ($label) con_skills=$con_skills"
  local OUT TID
  # --no-deliver: sin esto el runner marca completionStatus=failed (announce→last
  # fall-closed) y `cron run` sale ≠0 aunque el comando haya escrito el log.
  OUT=$($OC cron add --name "vigia-sync-write-$label" --at 1m --delete-after-run \
    --no-deliver --timeout-seconds 120 --command "$cmd" --json 2>&1) \
    || { echo "ABORTO: no pude crear job de escritura del fixture: $OUT" | cut -c1-400; return 1; }
  TID=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id") or d.get("job",{}).get("id",""))' 2>/dev/null)
  [ -n "$TID" ] || { echo "ABORTO: write-job sin id: $OUT" | cut -c1-400; return 1; }
  $OC cron run "$TID" --wait --wait-timeout 3m --json >/dev/null 2>&1 \
    || { echo "ABORTO: write-job $TID no corrio"; $OC cron rm "$TID" >/dev/null 2>&1 || true; return 1; }
  # cleanup del writer (delete-after-run puede bastar; igual verificamos)
  if $OC cron get "$TID" --json >/dev/null 2>&1; then
    $OC cron rm "$TID" >/dev/null 2>&1 || { echo "ABORTO: no pude borrar write-job $TID"; return 1; }
  fi
  echo "-- fixture escrito ($label) id_writer=$TID"
}

cron_list_status() {
  # Imprime: present | absent | unknown
  local tid="$1"
  local raw
  if ! raw=$($OC cron list --json 2>/dev/null); then
    echo unknown
    return
  fi
  # Usa el parser estricto (clave jobs presente aunque []): no fall-open con {}.
  printf '%s' "$raw" | python3 scripts/tests/vigia_sync_prueba_assert.py list-status "$tid" -
}

rm_y_verificar() {
  local tid="$1"
  local rm_ok=1
  if ! $OC cron rm "$tid" >/dev/null 2>&1; then
    rm_ok=0
  fi
  local list_st
  list_st=$(cron_list_status "$tid")
  python3 scripts/tests/vigia_sync_prueba_assert.py assert-rm "$tid" "$rm_ok" "$list_st" \
    || { echo "ABORTO: cleanup de $tid incompleto — borrar a mano (list=$list_st)"; return 1; }
  echo "rm $tid OK (list=$list_st)"
}

ejecutar_pruebas_d1_d2() {
  echo "== PRUEBA D1/D2 $(date -u +%H:%M:%SZ)  (VIGIA_SYNC_EJECUTAR=1)"
  local MSG_PRUEBA ASSERT
  MSG_PRUEBA=$(msg_con_log_prueba) || return 1
  ASSERT=scripts/tests/vigia_sync_prueba_assert.py
  [ -f "$ASSERT" ] || { echo "ABORTO: falta $ASSERT"; return 1; }

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
      > ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.run.json" 2>&1 \
      || { echo "PRUEBA $label: cron run fallo"; rm_y_verificar "$TID" || true; return 1; }
    $OC cron runs "$TID" --limit 1 --json \
      > ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.runs.json" 2>&1 \
      || { echo "PRUEBA $label: cron runs fallo"; rm_y_verificar "$TID" || true; return 1; }
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
    # Asercion de resultado (DoD): falla el script si no calza.
    if [ "$label" = "D1" ]; then
      python3 "$ASSERT" assert-d1 ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.runs.json" \
        || { echo "PRUEBA D1 ASSERT FALLO"; rm_y_verificar "$TID" || true; return 1; }
    else
      python3 "$ASSERT" assert-d2 ".saikit/scratch/M/vigia-sync-prueba-$label.$TS.runs.json" \
        || { echo "PRUEBA D2 ASSERT FALLO"; rm_y_verificar "$TID" || true; return 1; }
    fi
    rm_y_verificar "$TID" || return 1
  }

  escribir_log_prueba 1 D1 || return 1
  run_one D1 || return 1
  escribir_log_prueba 0 D2 || return 1
  run_one D2 || return 1
  echo "PRUEBA D1/D2 terminada VERDE. Evidencia en .saikit/scratch/M/vigia-sync-prueba-D*.$TS.runs.json"
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
    if en_franja_silencio_cdmx; then
      echo "ABORTO: franja de silencio CDMX (23:00-08:00): D1 diferiria el aviso (DIFERIDO_D)"
      echo "        y la asercion fallaria sin que el vigia este roto. Reintenta fuera de la franja:"
      echo "        TZ=America/Mexico_City date  # hora actual CDMX"
      echo "        VIGIA_SYNC_EJECUTAR=1 $0 --test"
      exit 1
    fi
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

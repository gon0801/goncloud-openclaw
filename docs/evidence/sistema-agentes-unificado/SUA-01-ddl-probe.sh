#!/usr/bin/env bash
# Ejecuta el DDL del diseño de SUA-01 junto al esquema real de R y comprueba que cada
# restricción rechaza su estado ilegal. Uso: probe.sh <documento de diseño> <checkout de R>
set -euo pipefail
doc="$1"; r="$2"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
db="$work/t.db"
awk '/^```sql$/{f=1;next} /^```$/{if(f){exit}} f' "$doc" > "$work/ddl.sql"
sqlite3 "$db" < "$r/src/state/openclaw-state-schema.sql"
sqlite3 "$db" "PRAGMA foreign_keys=ON;" ".read $work/ddl.sql"

run() { sqlite3 "$db" "PRAGMA foreign_keys=ON; $1" >/dev/null 2>"$work/err"; }
ok=0; bad=0
legal() { if run "$2"; then ok=$((ok+1)); else bad=$((bad+1)); echo "FALLA (debía entrar): $1: $(cat "$work/err")"; fi; }
# Con un tercer argumento, el rechazo tiene que venir de esa restricción y no de otra.
illegal() {
  if run "$2"; then bad=$((bad+1)); echo "FALLA (debía rechazarse): $1"
  elif [ -n "${3:-}" ] && ! grep -q "$3" "$work/err"; then bad=$((bad+1)); echo "FALLA (lo rechazó otra restricción): $1: $(cat "$work/err")"
  else ok=$((ok+1)); fi
}

T="INSERT INTO managed_tasks (task_id, requester_scope, task_key, requester_json, assignment_json, assignment_digest, producer_id, producer_token, generation, created_at, updated_at) VALUES"
legal "tareas" "$T ('t-a','{\"kind\":\"root\",\"rootId\":\"r1\"}','unit:A:1','{}','{}','d','x','p',1,1,1), ('t-a2','{\"kind\":\"root\",\"rootId\":\"r1\"}','unit:A:2','{}','{}','d','x','p',1,1,1), ('t-b','{\"kind\":\"root\",\"rootId\":\"r1\"}','unit:B:1','{}','{}','d','x','p',1,1,1);"
ROOT="INSERT INTO managed_roots (root_id, owner_scope, open_idempotency, open_digest, contract_version, owner_json, request_digest, authority_json, budget_json, quality_policy, created_at) VALUES"
legal "raíz" "$ROOT ('r1','dueño','k1','od','sistema-agentes.meta.v1','{}','rd','{}','{}','quality-kit.regla4',1);"
illegal "dos raíces para el mismo pedido" "$ROOT ('r2','dueño','k1','od','sistema-agentes.meta.v1','{}','rd','{}','{}','q',1);"

C="INSERT INTO managed_root_controls (root_id, epoch, prev_epoch, prev_state, command, state, reason, command_id, command_digest, receipt_json, created_at) VALUES"
illegal "raíz que nace pausada" "$C ('r1',1,NULL,NULL,'open','paused',NULL,'open','d','{}',1);"
illegal "primera época que no es 1" "$C ('r1',2,NULL,NULL,'open','active',NULL,'open','d','{}',1);"
legal "época 1 activa" "$C ('r1',1,NULL,NULL,'open','active',NULL,'open','d','{}',1);"
illegal "resume sobre activa" "$C ('r1',2,1,'active','resume','active',NULL,'c-x','d','{}',1);"
illegal "época saltada" "$C ('r1',3,1,'active','pause','paused',NULL,'c-x','d','{}',1);"
illegal "sale de un estado que no era el anterior" "$C ('r1',2,1,'paused','resume','active',NULL,'c-x','d','{}',1);"
legal "pause" "$C ('r1',2,1,'active','pause','paused','motivo','c-1','d','{}',1);"
illegal "pause sobre pausada" "$C ('r1',3,2,'paused','pause','paused',NULL,'c-x','d','{}',1);"
illegal "la misma orden con otra época" "$C ('r1',3,2,'paused','resume','active',NULL,'c-1','d','{}',1);"
illegal "época repetida" "$C ('r1',2,1,'active','cancel','cancelled',NULL,'c-y','d','{}',1);"
legal "resume" "$C ('r1',3,2,'paused','resume','active',NULL,'c-2','d','{}',1);"

P="INSERT INTO managed_root_plans (root_id, revision, prev_revision, plan_digest, assumptions_json, scope_change_json, revision_id, revision_digest, receipt_json, created_at) VALUES"
illegal "revisión 2 sin revisión 1" "$P ('r1',2,1,'pd','[]',NULL,'rev-2','d','{}',1);"
legal "revisión 1" "$P ('r1',1,NULL,'pd','[]',NULL,'open','d','{}',1);"
illegal "revisión 3 sin revisión 2" "$P ('r1',3,2,'pd','[]',NULL,'rev-3','d','{}',1);"
illegal "dos revisiones 1" "$P ('r1',1,NULL,'pd','[]',NULL,'otra','d','{}',1);"
U="INSERT INTO managed_root_units (root_id, revision, unit_id, unit_digest, unit_json) VALUES"
legal "unidades" "$U ('r1',1,'A','ha','{}'), ('r1',1,'B','hb','{}');"
illegal "unidad de una revisión que no existe" "$U ('r1',9,'Z','hz','{}');"

K="INSERT INTO managed_root_commits (root_id, commit_id, commit_digest, plan_revision, control_epoch, receipt_json, created_at) VALUES"
illegal "commit que cita una revisión que no existe" "$K ('r1','k-x','d',9,3,'{}',1);"
illegal "commit que cita una época que no existe" "$K ('r1','k-x','d',1,9,'{}',1);"
legal "commit" "$K ('r1','k-1','d',1,3,'{}',1);"
illegal "commit repetido" "$K ('r1','k-1','d2',1,3,'{}',1);"

A="INSERT INTO managed_root_attempts (root_id, unit_id, attempt, prev_attempt, plan_revision, unit_digest, task_id, commit_id, admission_epoch, outcome, outcome_ref, created_at, updated_at) VALUES"
illegal "intento de una unidad que el plan no tiene" "$A ('r1','Z',1,NULL,1,'hz','t-a','k-1',NULL,NULL,NULL,1,1);"
illegal "intento con otra huella que la de su unidad" "$A ('r1','A',1,NULL,1,'otra','t-a','k-1',NULL,NULL,NULL,1,1);"
illegal "intento sin el commit que lo escribió" "$A ('r1','A',1,NULL,1,'ha','t-a','k-9',NULL,NULL,NULL,1,1);"
illegal "intento 2 sin intento 1" "$A ('r1','A',2,1,1,'ha','t-a','k-1',NULL,NULL,NULL,1,1);"
illegal "intento sobre una tarea que no existe" "$A ('r1','A',1,NULL,1,'ha','fantasma','k-1',NULL,NULL,NULL,1,1);"
illegal "intento admitido en una época que no existió" "$A ('r1','A',1,NULL,1,'ha','t-a','k-1',9,NULL,NULL,1,1);"
legal "intento 1 de A" "$A ('r1','A',1,NULL,1,'ha','t-a','k-1',3,NULL,NULL,1,1);"
illegal "dos C para la misma unidad e intento" "$A ('r1','A',1,NULL,1,'ha','t-a2','k-1',NULL,NULL,NULL,1,1);"
illegal "dos intentos vivos de una unidad" "$A ('r1','A',2,1,1,'ha','t-a2','k-1',NULL,NULL,NULL,1,1);"
illegal "una tarea para dos intentos" "$A ('r1','B',1,NULL,1,'hb','t-a','k-1',NULL,NULL,NULL,1,1);"
illegal "terminado sin la orden que lo terminó" "UPDATE managed_root_attempts SET outcome='failed' WHERE task_id='t-a';"
illegal "resultado de intento inventado" "UPDATE managed_root_attempts SET outcome='done', outcome_ref='commit:k-1' WHERE task_id='t-a';"
legal "A falla" "UPDATE managed_root_attempts SET outcome='failed', outcome_ref='commit:k-1' WHERE task_id='t-a';"
legal "intento 2 de A, aceptado" "$A ('r1','A',2,1,1,'ha','t-a2','k-1',NULL,'accepted','commit:k-1',1,1);"
legal "intento 1 de B" "$A ('r1','B',1,NULL,1,'hb','t-b','k-1',NULL,NULL,NULL,1,1);"

E="INSERT INTO managed_root_evidence (root_id, evidence_id, plan_revision, unit_id, attempt, criterion_id, verifier_role, outcome, expires_at, claim_json, claim_digest, commit_id, created_at) VALUES"
legal "claim" "$E ('r1','e-1',1,'A',2,'c1','reviewer','passed',NULL,'{}','d','k-1',1);"
illegal "evidenceId repetido" "$E ('r1','e-1',1,'A',2,'c1','reviewer','failed',NULL,'{}','d2','k-1',1);"
illegal "resultado de claim fuera del contrato" "$E ('r1','e-2',1,'A',2,'c1','reviewer','ok',NULL,'{}','d','k-1',1);"
illegal "verificador fuera del contrato" "$E ('r1','e-3',1,'A',2,'c1','amigo','passed',NULL,'{}','d','k-1',1);"
illegal "claim sobre un intento que no existe" "$E ('r1','e-4',1,'A',9,'c1','ci','passed',NULL,'{}','d','k-1',1);"
illegal "claim de una revisión que no existe" "$E ('r1','e-5',9,'A',2,'c1','ci','passed',NULL,'{}','d','k-1',1);"

F="INSERT INTO managed_root_effects (root_id, effect_id, plan_revision, unit_id, unit_digest, intent_json, intent_digest, destination, resource_ref, cancellable, commit_id, state, start_id, started_epoch, settlement_json, created_at, updated_at) VALUES"
legal "efecto preparado" "$F ('r1','f-1',1,'A','ha','{}','d','dest',NULL,0,'k-1','prepared',NULL,NULL,NULL,1,1);"
illegal "preparado que ya tiene permiso" "$F ('r1','f-2',1,'A','ha','{}','d','dest',NULL,0,'k-1','prepared','s-1',3,NULL,1,1);"
illegal "started sin permiso" "UPDATE managed_root_effects SET state='started' WHERE effect_id='f-1';"
illegal "permiso sin época" "UPDATE managed_root_effects SET state='started', start_id='s-1' WHERE effect_id='f-1';"
illegal "permiso de una época que no existió" "UPDATE managed_root_effects SET state='started', start_id='s-1', started_epoch=9 WHERE effect_id='f-1';"
legal "permiso" "UPDATE managed_root_effects SET state='started', start_id='s-1', started_epoch=3 WHERE effect_id='f-1';"
illegal "confirmado sin prueba" "UPDATE managed_root_effects SET state='confirmed' WHERE effect_id='f-1';"
illegal "estado de efecto inventado" "UPDATE managed_root_effects SET state='voided' WHERE effect_id='f-1';"
legal "confirmado" "UPDATE managed_root_effects SET state='confirmed', settlement_json='{}' WHERE effect_id='f-1';"
illegal "escritor exigido sin unidad" "$F ('r1','f-3',NULL,NULL,NULL,'{}','d','dest','repo:x',0,'k-1','prepared',NULL,NULL,NULL,1,1);"
illegal "unidad a medias" "$F ('r1','f-4',NULL,'A',NULL,'{}','d','dest',NULL,0,'k-1','prepared',NULL,NULL,NULL,1,1);"
legal "efecto de la raíz, sin unidad" "$F ('r1','f-5',NULL,NULL,NULL,'{}','d',NULL,NULL,1,'k-1','prepared',NULL,NULL,NULL,1,1);"

W="INSERT INTO managed_root_writers (resource_ref, root_id, unit_id, commit_id, claimed_at, released_at, release_ref) VALUES"
legal "escritor" "$W ('repo:x#rama','r1','A','k-1',1,NULL,NULL);"
legal "otra raíz" "$ROOT ('r9','otro','k9','od','sistema-agentes.meta.v1','{}','rd','{}','{}','q',1); $C ('r9',1,NULL,NULL,'open','active',NULL,'open','d','{}',1); $P ('r9',1,NULL,'pd','[]',NULL,'open','d','{}',1); $K ('r9','k-9','d',1,1,'{}',1);"
illegal "dos dueños vivos de un recurso" "$W ('repo:x#rama','r9','Q','k-9',1,NULL,NULL);"
illegal "liberado sin la orden que lo liberó" "UPDATE managed_root_writers SET released_at=2 WHERE resource_ref='repo:x#rama';"
legal "liberar" "UPDATE managed_root_writers SET released_at=2, release_ref='commit:k-1' WHERE resource_ref='repo:x#rama';"
legal "el recurso libre pasa a otra raíz" "$W ('repo:x#rama','r9','Q','k-9',3,NULL,NULL);"

N="INSERT INTO managed_root_counters (root_id, counter_ref, ordinal, prev_ordinal, commit_id) VALUES"
illegal "contador que salta" "$N ('r1','rondas:A',7,6,'k-1');"
legal "contador a 1" "$N ('r1','rondas:A',1,NULL,'k-1');"
illegal "dos commits suben al mismo valor" "$N ('r1','rondas:A',1,NULL,'k-1');"
illegal "contador en cero" "$N ('r1','rondas:B',0,NULL,'k-1');"
illegal "contador sin commit" "$N ('r1','rondas:A',2,1,'k-x');"
legal "contador a 2" "$N ('r1','rondas:A',2,1,'k-1');"

Q="INSERT INTO managed_root_requesters (root_id, generation, prev_generation, instance, created_at) VALUES"
illegal "generación 5 sin las anteriores" "$Q ('r1',5,4,'inst-5',1);"
legal "solicitante" "$Q ('r1',1,NULL,'inst-1',1);"
illegal "dos generaciones con la misma instancia" "$Q ('r1',2,1,'inst-1',1);"
illegal "generación repetida" "$Q ('r1',1,NULL,'inst-2',1);"
legal "generación 2" "$Q ('r1',2,1,'inst-2',1);"

# El cerco de una pausa sobre una tabla de hoy.
D="INSERT INTO managed_task_admissions (task_id, admission_key, request_digest, claim_id, state, native_run_id, native_generation, created_at, updated_at) VALUES"
legal "admisión claimed atada a un host" "$D ('t-b','epoch-3','rd','claim-1','claimed','host-claim:{}',1,1,1);"
illegal "cercar sin anular claim_id y request_digest" "UPDATE managed_task_admissions SET state='fenced' WHERE task_id='t-b' AND state='claimed';"
legal "cercar anulando las dos columnas" "UPDATE managed_task_admissions SET state='fenced', claim_id=NULL, request_digest=NULL WHERE task_id='t-b' AND state='claimed';"
illegal "volver a admitir con la llave cercada" "$D ('t-b','epoch-3','rd','claim-2','claimed',NULL,NULL,1,1);"
legal "admitir otra vez con otra llave" "$D ('t-b','epoch-5','rd','claim-2','claimed',NULL,NULL,1,1);"
illegal "dos admisiones activas de una tarea" "$D ('t-b','epoch-6','rd','claim-3','claimed',NULL,NULL,1,1);"

legal "cancel" "$C ('r1',4,3,'active','cancel','cancelled',NULL,'c-3','d','{}',1);"
illegal "orden tras cancelled" "$C ('r1',5,4,'cancelled','resume','active',NULL,'c-4','d','{}',1);"
illegal "cancel tras cancelled" "$C ('r1',5,4,'cancelled','cancel','cancelled',NULL,'c-5','d','{}',1);"

# Un CHECK que vale NULL pasa en SQLite. Cada cadena tiene que rechazar un prev_ en NULL fuera de su primera fila.
illegal "orden tras cancelled con prev en NULL" "$C ('r1',5,NULL,NULL,'resume','active',NULL,'n-1','d','{}',1);" "CHECK constraint failed"
illegal "época saltada con prev en NULL" "$C ('r1',9,NULL,NULL,'pause','paused',NULL,'n-2','d','{}',1);" "CHECK constraint failed"
illegal "orden con prev_state en NULL" "$C ('r1',5,4,NULL,'resume','active',NULL,'n-3','d','{}',1);" "CHECK constraint failed"
illegal "raíz que nace pausada, sin prev" "$C ('r9',2,NULL,NULL,'pause','paused',NULL,'n-4','d','{}',1);" "CHECK constraint failed"
illegal "revisión 5 con prev en NULL" "$P ('r1',5,NULL,'pd','[]',NULL,'rev-5','d','{}',1);" "CHECK constraint failed"
illegal "intento 7 con prev en NULL" "$A ('r1','B',7,NULL,1,'hb','t-a','k-1',NULL,'failed','commit:k-1',1,1);" "CHECK constraint failed"
illegal "contador 9 con prev en NULL" "$N ('r1','rondas:A',9,NULL,'k-1');" "CHECK constraint failed"
illegal "generación 9 con prev en NULL" "$Q ('r1',9,NULL,'inst-9',1);" "CHECK constraint failed"

fk="$(sqlite3 "$db" "PRAGMA foreign_key_check;")"
[ -z "$fk" ] || { bad=$((bad+1)); echo "FALLA: foreign_key_check: $fk"; }
echo "sqlite $(sqlite3 --version | cut -d' ' -f1): $ok comprobaciones bien, $bad mal"
[ "$bad" -eq 0 ]

#!/bin/bash
# test-corrida-seguimiento-global.sh — una sola reloj global para el seguimiento.
#
# Antes: cada `corrida.sh abrir` creaba su propio cron `corrida-vigia-<id>` con
# parte horario a Telegram. Ahora: abrir escribe `corrida.v2` con
# `seguimiento_global:true` y no crea ningun cron; el unico reloj es el
# `avance-tareas` del director (cada 15 min) con el corte consolidado cada 30.
# `cerrar` solo quita el cron legado exacto en v1; en v2 nunca toca el reloj
# compartido. `corrida_mensaje AVANZA` acumula el evento para el proximo corte
# en vez de mandar; NECESITO/DETENIDA/CERRADA siguen inmediatas por v1.
#
# Todo contra stubs: ningun Telegram real, ningun cron vivo, ningun tmux.
# Uso: bash scripts/tests/test-corrida-seguimiento-global.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
RB="$PWD/scripts/tests/fixtures/corrida/runbook-simulacro.md"
MODOS="$PWD/scripts/tests/fixtures/corrida/cli-modos-simulacro.tsv"
[ -f "$CORR" ] || fail "falta $CORR"
[ -f "$RB" ] || fail "falta $RB"
[ -f "$MODOS" ] || fail "falta $MODOS"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

LLAMADAS="$T/llamadas.log"; : >"$LLAMADAS"
JOBS="$T/jobs.txt"; : >"$JOBS"
STATE="$T/corridas"

# Stub openclaw: anota, no manda. JOBS trae un objeto de job por linea.
# LISTA_MALA=1 hace fallar cron list; CRON_RM_FAIL=1 todo cron rm;
# CRON_RM_FAIL_ID=<id> solo ese rm.
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ list*)
    [ "\${LISTA_MALA:-0}" = "1" ] && exit 1
    printf '{"jobs":[{"name":"verif-sync-repos","enabled":true,"delivery":{"to":"DESTINO-9G"}}'
    while IFS= read -r linea; do
      [ -n "\$linea" ] && printf ',%s' "\$linea"
    done < "$JOBS"
    printf ']}';;
  *cron\ rm*)
    [ "\${CRON_RM_FAIL:-0}" = "1" ] && exit 1
    ultimo=""
    for a in "\$@"; do ultimo="\$a"; done
    [ -n "\${CRON_RM_FAIL_ID:-}" ] && [ "\$ultimo" = "\$CRON_RM_FAIL_ID" ] && exit 1
    grep -v "\"id\":\"\$ultimo\"" "$JOBS" > "$JOBS.n" 2>/dev/null; mv "$JOBS.n" "$JOBS"
    printf '{}';;
  *message\ send*) printf '{"messageId":"m9"}';;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$STATE"
export OPENCLAW_BIN="$T/bin/openclaw"

avance_ok() {
  printf '%s\n' '{"name":"avance-tareas","id":"uuid-avance","enabled":true,"schedule":{"kind":"every","everyMs":900000},"delivery":{"to":"DESTINO-9G"}}' >"$JOBS"
}
legado() { # $1 nombre, $2 id
  printf '%s\n' "{\"name\":\"$1\",\"id\":\"$2\",\"enabled\":true,\"schedule\":{\"kind\":\"every\",\"everyMs\":3600000}}" >>"$JOBS"
}
escribe_v1() { # $1 id, $2 cronid
  RID="$1" RCID="$2" RDIR="$STATE/$1" python3 - <<'PY'
import json,os
d={'schema':'corrida.v1','id':os.environ['RID'],'runbook':'docs/runbooks/x.md','vigia':'claw',
'simulacro':False,'canal':{'cron':'verif-sync-repos','destino':'DESTINO-9G'},
'cli_modos':'x.tsv','cron_vigia_id':os.environ['RCID'],
'inicio':'2026-09-20T10:00:00+0000','timebox_horas':6,'sesiones':[],
'preaprobaciones':[],'estado':'abierta'}
os.makedirs(os.environ['RDIR'],exist_ok=True)
p=os.path.join(os.environ['RDIR'],'registro.json')
open(p,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(p,0o600)
PY
}

# (1) abrir no crea vigia por corrida: escribe v2 con reloj global.
avance_ok
bash "$CORR" abrir nueva --runbook "$RB" --vigia claw --cli-modos "$MODOS" >/dev/null \
  || fail "abrir nueva fallo"
grep -q 'corrida-vigia-nueva' "$LLAMADAS" && fail "abrir creó un vigía por corrida"
grep -q '"schema": *"corrida.v2"' "$STATE/nueva/registro.json" || fail "no escribió v2"
grep -q '"seguimiento_global": *true' "$STATE/nueva/registro.json" || fail "no declaró reloj global"
grep -q 'cron_vigia_id' "$STATE/nueva/registro.json" && fail "v2 trae cron_vigia_id"
echo "ok (1): abrir escribe v2 sin crear vigía por corrida"

# (2) cerrar v2 no borra el reloj compartido; el cierre inmediato sigue saliendo.
: >"$LLAMADAS"
bash "$CORR" cerrar nueva >/dev/null || fail "cerrar nueva fallo"
grep -q 'cron rm .*avance-tareas' "$LLAMADAS" && fail "cerrar borró el reloj compartido"
grep -q 'cron rm' "$LLAMADAS" && fail "cerrar v2 toco algun cron"
grep -q '"etiqueta": "CERRADA", "ok": true' "$STATE/nueva/mensajes.jsonl" \
  || fail "cerrar v2 no mando el CERRADA inmediato"
grep -q '"estado": *"cerrada"' "$STATE/nueva/registro.json" || fail "nueva no quedo cerrada"
echo "ok (2): cerrar v2 conserva el reloj compartido y manda el cierre"

# (3) cerrar v1 quita SU cron legado por id, una sola vez.
escribe_v1 vieja cron-viejo
legado corrida-vigia-vieja cron-viejo
: >"$LLAMADAS"
bash "$CORR" cerrar vieja >/dev/null || fail "cerrar vieja fallo"
[ "$(grep -c 'cron rm cron-viejo' "$LLAMADAS")" -eq 1 ] || fail "v1 no limpió su cron"
grep -q '"estado": *"cerrada"' "$STATE/vieja/registro.json" || fail "vieja no quedo cerrada"
echo "ok (3): cerrar v1 limpia su cron legado por id"

# (4) corrida_mensaje por etiqueta: AVANZA acumula sin mandar; las otras tres
# salen de inmediato por la via v1, una vez cada una.
bash "$CORR" abrir etq --runbook "$RB" --vigia claw --cli-modos "$MODOS" >/dev/null \
  || fail "abrir etq fallo"
. scripts/mac/corrida/lib.sh
: >"$LLAMADAS"
rm -f "$STATE/etq/mensajes.jsonl"
corrida_mensaje etq AVANZA "1 de 2 partes terminadas" "quedo listo el nucleo" "sigue la revision" "nada" \
  || fail "AVANZA no acumulo"
grep -q 'message send' "$LLAMADAS" && fail "AVANZA mando en vez de acumular"
[ -f "$STATE/etq/mensajes.jsonl" ] && fail "AVANZA anoto entrega en mensajes.jsonl"
grep -q '"cambio": *"quedo listo el nucleo"' "$STATE/etq/eventos-seguimiento.jsonl" \
  || fail "AVANZA no dejo el evento acumulado"
for etq2 in "NECESITO TU RESPUESTA" DETENIDA CERRADA; do
  : >"$LLAMADAS"
  corrida_mensaje etq "$etq2" "1 de 2 partes terminadas" "algo material" "sigue igual" "nada" \
    || fail "$etq2 no salio de inmediato"
  [ "$(grep -c 'message send' "$LLAMADAS")" -eq 1 ] || fail "$etq2 no uso la via inmediata una vez"
done
corrida_mensaje etq "ETIQUETA-RARA" "1 de 2 partes" "x" "y" "nada" >/dev/null 2>&1 \
  && fail "una etiqueta desconocida debio fallar cerrada"
echo "ok (4): AVANZA acumula para el corte; NECESITO/DETENIDA/CERRADA salen de inmediato"

# (5) seguimiento --json: inventario de solo lectura.
S2="$T/seg"; mkdir -p "$S2"
S2STATE="$S2/corridas"
STATE_SAVED="$STATE"
CORRIDA_STATE="$S2STATE"; export CORRIDA_STATE
STATE="$S2STATE"
escribe_v1 v1abierta cron-v1abierta
bash "$CORR" abrir v2abierta --runbook "$RB" --vigia claw --cli-modos "$MODOS" >/dev/null \
  || fail "abrir v2abierta fallo"
bash "$CORR" abrir vcerrada --runbook "$RB" --vigia claw --cli-modos "$MODOS" >/dev/null \
  || fail "abrir vcerrada fallo"
bash "$CORR" cerrar vcerrada >/dev/null || fail "cerrar vcerrada fallo"
mkdir -p "$S2STATE/mala"
printf '{no es json' >"$S2STATE/mala/registro.json"
md5sums_antes=$(find "$S2STATE" -type f -exec md5 {} + | sort)
llamadas_antes=$(wc -l <"$LLAMADAS" | tr -d ' ')
out=$(bash "$CORR" seguimiento --json) || fail "seguimiento --json fallo"
md5sums_despues=$(find "$S2STATE" -type f -exec md5 {} + | sort)
[ "$md5sums_antes" = "$md5sums_despues" ] || fail "seguimiento --json escribio en el estado"
[ "$(wc -l <"$LLAMADAS" | tr -d ' ')" = "$llamadas_antes" ] || fail "seguimiento --json invoco al stub"
OUT="$T/seg-out.json"; printf '%s' "$out" >"$OUT"
SEGF="$OUT" python3 - <<'PY' || fail "el inventario no trae lo esperado"
import json,os
d=json.loads(open(os.environ['SEGF']).read())
assert d.get('schema')=='corrida-seguimiento.v1', d.get('schema')
ids=sorted(c.get('trabajoId') for c in d.get('corridas',[]))
assert ids==['corrida:v1abierta','corrida:v2abierta'], ids
assert all(c.get('id') and c.get('inicio') and c.get('estado')=='abierta' and c.get('runbook') for c in d['corridas'])
assert not any('vcerrada' in (c.get('trabajoId','')+c.get('id','')) for c in d['corridas']), 'la cerrada debio omitirse'
errs=d.get('errores',[])
assert any('mala' in e for e in errs), errs
PY
echo "ok (5): seguimiento --json inventaria sin escribir ni llamar"
STATE="$STATE_SAVED"; CORRIDA_STATE="$STATE"; export CORRIDA_STATE

# (6) migrar-seguimiento --dry-run: lista sin mutar.
escribe_v1 mig1 cron-mig1
legado corrida-vigia-mig1 cron-mig1
md5_antes=$(find "$STATE" -type f -name registro.json -exec md5 {} + | sort)
out=$(bash "$CORR" migrar-seguimiento --dry-run) || fail "dry-run fallo"
printf '%s' "$out" | grep -q 'mig1' || fail "dry-run no lista mig1"
printf '%s' "$out" | grep -q 'cron-mig1' || fail "dry-run no lista el id legado"
md5_despues=$(find "$STATE" -type f -name registro.json -exec md5 {} + | sort)
[ "$md5_antes" = "$md5_despues" ] || fail "dry-run muto registros"
grep -q 'cron rm' "$LLAMADAS" && fail "dry-run toco crons"
echo "ok (6): dry-run lista sin mutar"

# (7) apply con reloj global sano: limpia legados y reescribe a v2; la segunda
# corrida es no-op.
avance_ok
legado corrida-vigia-mig1 cron-mig1
: >"$LLAMADAS"
bash "$CORR" migrar-seguimiento --apply >/dev/null || fail "apply fallo"
grep -q 'cron rm cron-mig1' "$LLAMADAS" || fail "apply no quito el legado"
grep -q '"schema": *"corrida.v2"' "$STATE/mig1/registro.json" || fail "mig1 no quedo v2"
grep -q 'cron_vigia_id' "$STATE/mig1/registro.json" && fail "mig1 conserva cron_vigia_id"
: >"$LLAMADAS"
out=$(bash "$CORR" migrar-seguimiento --apply) || fail "el segundo apply debio ser no-op verde"
grep -q 'cron rm' "$LLAMADAS" && fail "el segundo apply toco crons"
echo "ok (7): apply migra a v2 y la segunda corrida es no-op"

# (8) sin reloj global sano no se muta nada: falta, apagado, duplicado, mala cadencia.
caso_reloj() { # $1 descripcion, resto: lineas de JOBS (el canal lo pone el stub)
  desc="$1"; shift
  rm -rf "$STATE/norelj"; escribe_v1 norelj cron-norelj
  legado corrida-vigia-norelj cron-norelj
  : >"$JOBS"
  for linea in "$@"; do
    printf '%s\n' "$linea" >>"$JOBS"
  done
  : >"$LLAMADAS"
  if bash "$CORR" migrar-seguimiento --apply >/dev/null 2>&1; then
    fail "apply con reloj $desc debio fallar"
  fi
  grep -q '"schema": *"corrida.v1"' "$STATE/norelj/registro.json" \
    || fail "apply con reloj $desc muto el registro"
  grep -q 'cron rm' "$LLAMADAS" && fail "apply con reloj $desc toco crons"
  echo "ok (8-$desc): sin reloj sano no se muta"
}
AVANCE='{"name":"avance-tareas","id":"uuid-avance","enabled":true,"schedule":{"kind":"every","everyMs":900000},"delivery":{"to":"DESTINO-9G"}}'
AVANCE_OFF='{"name":"avance-tareas","id":"uuid-avance","enabled":false,"schedule":{"kind":"every","everyMs":900000},"delivery":{"to":"DESTINO-9G"}}'
AVANCE_60='{"name":"avance-tareas","id":"uuid-avance","enabled":true,"schedule":{"kind":"every","everyMs":3600000},"delivery":{"to":"DESTINO-9G"}}'
caso_reloj falta
caso_reloj apagado "$AVANCE_OFF"
caso_reloj duplicado "$AVANCE" "$AVANCE"
caso_reloj mala-cadencia "$AVANCE_60"
echo "ok (8): reloj ausente/apagado/duplicado/mal-cadencia no muta"

# (9) lista ilegible: se para sin escribir.
rm -rf "$STATE/nolista"; escribe_v1 nolista cron-nolista
legado corrida-vigia-nolista cron-nolista
avance_ok
: >"$LLAMADAS"
if LISTA_MALA=1 bash "$CORR" migrar-seguimiento --apply >/dev/null 2>&1; then
  fail "apply con lista ilegible debio fallar"
fi
grep -q '"schema": *"corrida.v1"' "$STATE/nolista/registro.json" \
  || fail "apply con lista ilegible muto el registro"
echo "ok (9): lista ilegible no muta"

# (10) remocion parcial: el fallo deja ese registro v1 y se reporta.
rm -rf "$STATE/parc1" "$STATE/parc2"
escribe_v1 parc1 cron-parc1
escribe_v1 parc2 cron-parc2
avance_ok
legado corrida-vigia-parc1 cron-parc1
legado corrida-vigia-parc2 cron-parc2
: >"$LLAMADAS"
out=$(CRON_RM_FAIL_ID=cron-parc1 bash "$CORR" migrar-seguimiento --apply 2>&1); rc=$?
[ "$rc" -ne 0 ] || fail "apply parcial debio salir distinto de cero"
grep -q '"schema": *"corrida.v1"' "$STATE/parc1/registro.json" \
  || fail "el registro con fallo debio quedar v1"
grep -q '"schema": *"corrida.v2"' "$STATE/parc2/registro.json" \
  || fail "el registro sano debio migrar"
printf '%s' "$out" | grep -q 'parc1' || fail "el parcial no nombra el pendiente"
echo "ok (10): el fallo parcial deja v1 y se reporta"

# (11) crons legados duplicados del mismo nombre: se quitan todos.
rm -rf "$STATE/dup"
escribe_v1 dup cron-dup-1
avance_ok
legado corrida-vigia-dup cron-dup-1
legado corrida-vigia-dup cron-dup-2
: >"$LLAMADAS"
bash "$CORR" migrar-seguimiento --apply >/dev/null || fail "apply con duplicados fallo"
grep -q 'cron rm cron-dup-1' "$LLAMADAS" || fail "no quito cron-dup-1"
grep -q 'cron rm cron-dup-2' "$LLAMADAS" || fail "no quito cron-dup-2"
grep -q '"schema": *"corrida.v2"' "$STATE/dup/registro.json" || fail "dup no quedo v2"
echo "ok (11): los duplicados legados se quitan todos"

echo "TODO VERDE: corrida-seguimiento-global"

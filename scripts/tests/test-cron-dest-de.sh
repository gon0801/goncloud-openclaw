#!/bin/bash
# cron_dest_de tambien lee failureAlert: el 24/9 los crons de negocio restaurados
# llevan el destino de David en failureAlert.to (delivery queda en {"mode":"none"}).
# Regla: delivery.to manda si existe; si no, failureAlert.to SOLO cuando
# failureAlert.channel=="telegram"; la logica de homonimos (createdAtMs -> el mas
# reciente; sin el, mismo destino -> ese, distinto -> AMBIGUO) se aplica igual al
# destino ya resuelto. abrir usa cron_dest_de con su default --canal-de.
# Uso: bash scripts/tests/test-cron-dest-de.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Stub de openclaw: cron list devuelve el JSON que la prueba deja en JOBS_JSON.
cat >"$T/bin/openclaw" <<'STUB'
#!/bin/sh
case "$*" in
  *cron\ list*) printf '%s' "$JOBS_JSON";;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"
export OPENCLAW_BIN="$T/bin/openclaw"

. scripts/mac/corrida/lib.sh

# (a) solo failureAlert telegram -> se resuelve el destino.
export JOBS_JSON='{"jobs":[{"name":"cuotas-proveedores","delivery":{"mode":"none"},"failureAlert":{"channel":"telegram","to":"DAVID-1","mode":"announce"}}]}'
out="$(cron_dest_de cuotas-proveedores)"
[ "$out" = "DAVID-1" ] || fail "failureAlert telegram no resolvio destino: '$out'"
echo "ok (a): failureAlert.channel=telegram resuelve el destino"

# (b) failureAlert con channel distinto de telegram -> sin destino.
export JOBS_JSON='{"jobs":[{"name":"cuotas-proveedores","delivery":{"mode":"none"},"failureAlert":{"channel":"slack","to":"CANAL-SLACK-1"}}]}'
out="$(cron_dest_de cuotas-proveedores)"
[ -z "$out" ] || fail "failureAlert no-telegram no debio resolver destino: '$out'"
echo "ok (b): failureAlert.channel!=telegram no resuelve destino"

# (c) delivery.to presente y failureAlert.to distinto -> gana delivery.to.
export JOBS_JSON='{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"DELIVERY-1"},"failureAlert":{"channel":"telegram","to":"DAVID-2"}}]}'
out="$(cron_dest_de cuotas-proveedores)"
[ "$out" = "DELIVERY-1" ] || fail "delivery.to no gano sobre failureAlert.to: '$out'"
echo "ok (c): delivery.to gana sobre failureAlert.to"

# (d) homonimos por failureAlert sin createdAtMs y con destinos distintos -> AMBIGUO
# (la logica de homonimos se conserva sobre el destino ya resuelto).
export JOBS_JSON='{"jobs":[
  {"name":"cuotas-proveedores","delivery":{"mode":"none"},"failureAlert":{"channel":"telegram","to":"DAVID-1"}},
  {"name":"cuotas-proveedores","delivery":{"mode":"none"},"failureAlert":{"channel":"telegram","to":"DAVID-2"}}
]}'
out="$(cron_dest_de cuotas-proveedores)"
[ "$out" = "AMBIGUO" ] || fail "homonimos con failureAlert distinto no dio AMBIGUO: '$out'"
echo "ok (d): homonimos por failureAlert sin createdAtMs -> AMBIGUO"

# (e) default de abrir: sin --canal-de, resuelve contra el cron cuotas-proveedores.
RB="$PWD/scripts/tests/fixtures/corrida/runbook-simulacro.md"
MODOS="$PWD/scripts/tests/fixtures/corrida/cli-modos-simulacro.tsv"
export JOBS_JSON='{"jobs":[{"name":"cuotas-proveedores","delivery":{"mode":"none"},"failureAlert":{"channel":"telegram","to":"DAVID-3"}}]}'
export CORRIDA_STATE="$T/state-default"
out="$(bash scripts/mac/corrida.sh abrir t-default --runbook "$RB" --vigia claw --cli-modos "$MODOS" --simulacro 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "abrir con el default de canal-de fallo: $out"
grep -q '"destino": *"DAVID-3"' "$CORRIDA_STATE/t-default/registro.json" \
  || fail "abrir no guardo el destino de cuotas-proveedores por default"
echo "ok (e): el default de abrir (--canal-de) es cuotas-proveedores"

echo "OK: test-cron-dest-de.sh"

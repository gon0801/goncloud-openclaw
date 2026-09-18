#!/bin/bash
# Todo `.saikit/progress/*.json` del repo tiene que pasar el validador del propio plugin.
#
# Por que existe. Medido el 2026-09-17: `.saikit/progress/fase6.json` llevaba dos dias
# con `cierre.resumen` de 340 caracteres, 40 por encima del tope del spec. El gateway lo
# rechazaba, asi que el tablero seguia sirviendo el fixture del canary — una Fase 6 con
# un carril atorado que no existe — y cualquiera que lo abriera veia datos falsos.
#
# El aviso SI existia: el envio fallaba y el fallo estaba escrito como residual en
# Plans.md. Y aun asi durmio dos dias, porque por diseno un envio fallido no bloquea
# (loop-autopilot §8). Por eso la prevencion no puede ser un log mas ruidoso: tiene que
# estar del lado del que escribe, y correr donde corre todo lo demas.
#
# No duplica la logica: importa `validarProgreso` del plugin. Si el contrato cambia,
# este candado cambia con el, sin quedarse atras.
#
# Uso: bash scripts/tests/test-progreso-valido.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

LIB=tablero-runbook/lib.ts
[ -f "$LIB" ] || fail "falta $LIB: sin el validador del plugin este candado no sirve"

NODE=$(ls -d "$HOME"/.openclaw/tools/node-*/bin/node 2>/dev/null | head -1)
[ -n "$NODE" ] || NODE=$(command -v node || true)
if [ -z "$NODE" ]; then
  echo "SKIP: sin node en esta maquina; el contrato se valida en CI"
  exit 0
fi

docs=$(ls .saikit/progress/*.json 2>/dev/null || true)
if [ -z "$docs" ]; then
  echo "ok (1): no hay documentos de progreso que validar"
  echo "TODO VERDE: progreso-valido"
  exit 0
fi

# (1) Cada documento pasa el validador del plugin.
malos=0
for f in $docs; do
  salida=$("$NODE" -e "
const { validarProgreso } = require('./$LIB');
const fs = require('node:fs');
let d;
try { d = JSON.parse(fs.readFileSync(process.argv[1], 'utf8')); }
catch (e) { console.log('JSON invalido: ' + e.message); process.exit(1); }
const r = validarProgreso(d);
if (r.ok) { process.exit(0); }
console.log((r.razones || []).join(' | '));
process.exit(1);
" "$f" 2>&1)
  if [ $? -ne 0 ]; then
    printf '  RECHAZADO %s: %s\n' "$f" "$salida"
    malos=$((malos + 1))
  fi
done
[ "$malos" -eq 0 ] || fail "$malos documento(s) de progreso que el gateway va a rechazar; el tablero se quedaria con lo que tuviera cargado"
echo "ok (1): $(printf '%s\n' "$docs" | wc -l | tr -d ' ') documento(s) de progreso pasan el validador del plugin"

# (2) El candado discrimina: un documento fuera de norma tiene que salir RECHAZADO.
# Sin este caso, un validador que siempre dijera que si dejaria pasar la prueba.
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
primero=$(printf '%s\n' "$docs" | head -1)
"$NODE" -e "
const fs = require('node:fs');
const d = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
d.cierre = d.cierre || {};
d.cierre.resumen = 'x'.repeat(340);   // el tope del spec es 300
fs.writeFileSync(process.argv[2], JSON.stringify(d));
" "$primero" "$TMP/fuera-de-norma.json"
razon=$("$NODE" -e "
const { validarProgreso } = require('./$LIB');
const d = JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8'));
const r = validarProgreso(d);
console.log(r.ok ? 'ACEPTADO' : (r.razones || []).join(' | '));
" "$TMP/fuera-de-norma.json" 2>&1)
case "$razon" in
  ACEPTADO) fail "(2) el validador acepto un resumen de 340 caracteres: este candado no discrimina" ;;
  *excede*300*) : ;;
  *) fail "(2) el rechazo no nombra el tope ni el largo, que es lo que costo dos dias de diagnostico: $razon" ;;
esac
echo "ok (2): un documento fuera de norma sale rechazado, y la razon nombra el tope y el largo"

echo "TODO VERDE: progreso-valido"

#!/bin/bash
# tablero-trabajo.sh contra un gateway falso que valida cada documento con el
# validarProgreso del plugin (el mismo que corre en runbook.progress.set) y lo
# guarda en disco. Nada toca el gateway real.
# Uso: bash scripts/tests/test-tablero-trabajo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
RAIZ="$PWD"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

S=scripts/mac/tablero-trabajo.sh
[ -f "$S" ] || fail "falta $S"
/bin/bash -n "$S" || fail "$S no parsea con /bin/bash"
NODE=$(ls -d "$HOME"/.openclaw/tools/node-*/bin/node 2>/dev/null | head -1)
[ -n "$NODE" ] || NODE=$(command -v node || true)
[ -n "$NODE" ] || fail "sin node: el gateway falso valida con contrato.ts"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export STORE="$T/store"; mkdir -p "$STORE"
cat >"$T/gateway.mjs" <<'JS'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
const [raiz, store, metodo, paramsJson] = process.argv.slice(2);
const { validarProgreso } = await import(`${raiz}/tablero-runbook/contrato.ts`);
const params = JSON.parse(paramsJson);
const out = (o) => process.stdout.write(`[plugins] aviso de config que el CLI antepone\n${JSON.stringify(o, null, 2)}\n`);
if (metodo === "runbook.progress.get") {
  const f = `${store}/${params.corrida}.json`;
  out(existsSync(f) ? { ok: true, doc: JSON.parse(readFileSync(f, "utf8")) } : { ok: false, razon: "desconocida" });
} else if (metodo === "runbook.progress.set") {
  const v = validarProgreso(params);
  appendFileSync(`${store}/recibidos.jsonl`, `${JSON.stringify({ ok: v.ok, razones: v.razones, doc: params })}\n`);
  if (process.env.FAKE_SET_FALLA) out({ ok: false, razones: ["fase: rechazo inyectado"] });
  else if (!v.ok) out({ ok: false, razones: v.razones });
  else { writeFileSync(`${store}/${params.corrida}.json`, JSON.stringify(params)); out({ ok: true }); }
} else {
  process.exit(3);
}
JS
cat >"$T/openclaw" <<STUB
#!/bin/bash
[ "\$1 \$2" = "gateway call" ] && [ "\$4" = "--params" ] || exit 64
exec "$NODE" --experimental-strip-types "$T/gateway.mjs" "$RAIZ" "\$STORE" "\$3" "\$5"
STUB
chmod +x "$T/openclaw"
export OPENCLAW_BIN="$T/openclaw"
tt() { bash "$S" "$@"; }
doc() { python3 -c "import json,sys; d=json.load(open('$STORE/$1.json')); print(eval(sys.argv[1]))" "$2"; }

# (1) abrir crea un documento de corrida con una parte por argumento.
out=$(tt abrir migrar-correo "Migrar el correo a Fastmail" "Exportar buzones" "Importar en Fastmail" "Cambiar DNS" \
  --siguiente "exportar los buzones de Gmail" 2>&1) || fail "(1) abrir fallo: $out"
[ "$(doc migrar-correo "d['corrida'], d['fase'], d['lead']['agente'], len(d['carriles'])")" = "('migrar-correo', '0', 'claw', 3)" ] \
  || fail "(1) forma del documento: $(cat "$STORE/migrar-correo.json")"
[ "$(doc migrar-correo "[c['estado'] for c in d['carriles']]")" = "['implementando', 'pendiente', 'pendiente']" ] \
  || fail "(1) la primera parte arranca en implementando y el resto pendiente"
[ "$(doc migrar-correo "d['siguiente_paso']")" = "exportar los buzones de Gmail" ] || fail "(1) --siguiente no llego"
printf '%s' "$out" | grep -q "0 de 3 partes terminadas" || fail "(1) abrir no imprime el resumen: $out"
echo "ok (1): abrir"

# (2) abrir otra vez no pisa el documento abierto.
tt paso migrar-correo 1 mergeado "buzones exportados" >/dev/null || fail "(2) paso previo fallo"
antes=$(cat "$STORE/migrar-correo.json")
n=$(wc -l <"$STORE/recibidos.jsonl")
out=$(tt abrir migrar-correo "Otro titulo" "Otra parte" 2>&1) || fail "(2) abrir repetido debe salir 0: $out"
[ "$(cat "$STORE/migrar-correo.json")" = "$antes" ] || fail "(2) abrir repetido piso el documento"
[ "$(wc -l <"$STORE/recibidos.jsonl")" = "$n" ] || fail "(2) abrir repetido llamo a set"
printf '%s' "$out" | grep -q "ya estaba abierto" || fail "(2) abrir repetido no lo dice: $out"
echo "ok (2): abrir es idempotente"

# (3) paso cambia la parte, anota el evento y mueve el siguiente paso.
tt paso migrar-correo p2 implementando "importando 3 de 5 buzones" --siguiente "terminar la importacion" --pr 42 >/dev/null \
  || fail "(3) paso fallo"
[ "$(doc migrar-correo "d['carriles'][0]['estado'], d['carriles'][1]['estado'], d['carriles'][1]['pr'], d['carriles'][1]['ultimo_evento']['que']")" \
  = "('mergeado', 'implementando', 42, 'importando 3 de 5 buzones')" ] || fail "(3) carril: $(cat "$STORE/migrar-correo.json")"
[ "$(doc migrar-correo "d['eventos'][-1]['carril'], d['eventos'][-1]['que'], d['siguiente_paso']")" \
  = "('p2', 'importando 3 de 5 buzones', 'terminar la importacion')" ] || fail "(3) evento o siguiente"
tt paso migrar-correo 3 atorado "el registrador pide 2FA" >/dev/null || fail "(3) paso atorado fallo"
[ "$(doc migrar-correo "d['carriles'][2]['detenido_por']")" = "el registrador pide 2FA" ] || fail "(3) atorado sin detenido_por"
tt paso migrar-correo 3 implementando "ya entro el 2FA" >/dev/null || fail "(3) salir de atorado fallo"
[ "$(doc migrar-correo "d['carriles'][2]['detenido_por']")" = "None" ] || fail "(3) detenido_por no se limpio"
out=$(tt paso migrar-correo 9 mergeado "x" 2>&1) && fail "(3) parte inexistente debe fallar"
printf '%s' "$out" | grep -q "Cambiar DNS" || fail "(3) el error no lista las partes: $out"
tt paso migrar-correo 1 terminado "x" >/dev/null 2>&1 && fail "(3) estado fuera de lista debe fallar"
echo "ok (3): paso"

# (4) atencion pide y suelta a David.
tt atencion migrar-correo "Necesito el codigo 2FA del registrador" >/dev/null || fail "(4) atencion fallo"
[ "$(doc migrar-correo "d['atencion_requerida']['necesaria'], d['atencion_requerida']['motivo']")" \
  = "(True, 'Necesito el codigo 2FA del registrador')" ] || fail "(4) atencion no quedo puesta"
tt atencion migrar-correo --resuelta >/dev/null || fail "(4) --resuelta fallo"
[ "$(doc migrar-correo "d['atencion_requerida']")" = "{'necesaria': False, 'motivo': None, 'desde': None}" ] \
  || fail "(4) --resuelta no limpio"
echo "ok (4): atencion"

# (5) agregar suma una parte; cerrar pone cierre.at y resumen; cerrar dos veces no pisa.
tt agregar migrar-correo "Avisar a los contactos" >/dev/null || fail "(5) agregar fallo"
[ "$(doc migrar-correo "d['carriles'][3]['id'], d['carriles'][3]['estado']")" = "('p4', 'pendiente')" ] || fail "(5) agregar"
tt cerrar migrar-correo "Correo migrado a Fastmail; DNS apuntando" >/dev/null || fail "(5) cerrar fallo"
[ "$(doc migrar-correo "bool(d['cierre']['at']), d['cierre']['resumen']")" = "(True, 'Correo migrado a Fastmail; DNS apuntando')" ] \
  || fail "(5) cierre"
antes=$(cat "$STORE/migrar-correo.json")
tt cerrar migrar-correo "otro" >/dev/null || fail "(5) cerrar repetido debe salir 0"
[ "$(cat "$STORE/migrar-correo.json")" = "$antes" ] || fail "(5) cerrar repetido piso el cierre"
tt paso migrar-correo 4 implementando "x" >/dev/null 2>&1 && fail "(5) paso sobre cerrado debe fallar"
tt abrir migrar-correo "de nuevo" "parte" >/dev/null 2>&1 && fail "(5) reabrir un id cerrado debe fallar"
echo "ok (5): agregar y cerrar"

# (6) todo documento que recibio el gateway paso validarProgreso.
malos=$(python3 -c "import json; print(sum(1 for l in open('$STORE/recibidos.jsonl') if not json.loads(l)['ok']))")
total=$(wc -l <"$STORE/recibidos.jsonl" | tr -d ' ')
[ "$total" -ge 9 ] || fail "(6) el gateway recibio solo $total documentos"
[ "$malos" = "0" ] || fail "(6) $malos de $total documentos no pasan validarProgreso: $(grep '"ok":false' "$STORE/recibidos.jsonl" | head -1)"
echo "ok (6): los $total documentos enviados pasan validarProgreso"

# (7) un set con ok:false sale distinto de 0 y muestra las razones.
out=$(FAKE_SET_FALLA=1 tt abrir otro-trabajo "Titulo" "Parte" 2>&1) && fail "(7) set rechazado debe salir distinto de 0"
printf '%s' "$out" | grep -q "rechazo inyectado" || fail "(7) no muestra las razones del gateway: $out"
[ ! -f "$STORE/otro-trabajo.json" ] || fail "(7) guardo pese al rechazo"
# El rechazo real del validador tambien llega: un titulo de puros espacios no se manda.
tt abrir otro-trabajo "   " "Parte" >/dev/null 2>&1 && fail "(7) titulo vacio debe fallar"
tt abrir "Mal/Id" "T" "P" >/dev/null 2>&1 && fail "(7) id fuera de CORRIDA_RE debe fallar"
echo "ok (7): los rechazos salen distinto de 0"

# (8) un gateway que no contesta JSON es un fallo, no un exito callado.
printf '#!/bin/sh\necho "gateway caido" >&2; exit 1\n' >"$T/caido"; chmod +x "$T/caido"
OPENCLAW_BIN="$T/caido" tt ver migrar-correo >/dev/null 2>&1 && fail "(8) CLI sin JSON debe fallar"
echo "ok (8): gateway sin respuesta falla"

# (9) el reloj de avance-tareas lo reporta mientras esta abierto y lo suelta al cerrar:
# el documento se deja en disco como lo guarda manejarSet (bajo la fase y bajo
# la corrida) y se corre el mismo inventario y decision que usa el tick.
cat >"$T/tick.mjs" <<'JS'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
const [raiz, docPath, dir] = process.argv.slice(2);
const { listarSeguimientoActivo } = await import(`${raiz}/tablero-runbook/seguimiento.ts`);
const { decidirSeguimiento } = await import(`${raiz}/tablero-runbook/seguimiento-clock.ts`);
const doc = JSON.parse(readFileSync(docPath, "utf8"));
rmSync(dir, { recursive: true, force: true });
mkdirSync(`${dir}/progress/c`, { recursive: true });
writeFileSync(`${dir}/progress/${doc.fase}.json`, JSON.stringify(doc));
writeFileSync(`${dir}/progress/c/${doc.corrida}.json`, JSON.stringify(doc));
const lista = await listarSeguimientoActivo({ stateDir: dir }, { ghPath: "/sin/gh" });
const ahora = Math.floor(Date.now() / 1000);
const d = decidirSeguimiento({
  ahora,
  previo: { schema: "seguimiento-clock.v1", corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: ahora - 3600 },
    ultimoEstado: "", ultimoInmediato: null, trabajosActivos: [] },
  activas: lista.activas, sueltas: [], inmediato: null, problemas: lista.problemas,
});
process.stdout.write(`${lista.activas.map((a) => a.trabajoId).join(",")}|${d.accion}|${d.tipo ?? ""}\n${d.mensaje ?? ""}`);
JS
tick() { "$NODE" --experimental-strip-types "$T/tick.mjs" "$RAIZ" "$STORE/revisar-facturas.json" "$T/state"; }
tt abrir revisar-facturas "Revisar facturas de septiembre" "Bajar facturas" "Cuadrar contra el banco" "Pagar lo pendiente" \
  --siguiente "cuadrar contra el banco" >/dev/null || fail "(9) abrir fallo"
tt paso revisar-facturas 1 mergeado "facturas bajadas" >/dev/null || fail "(9) paso fallo"
out=$(tick) || fail "(9) el tick fallo: $out"
printf '%s' "$out" | head -1 | grep -qx "corrida:revisar-facturas|SEND|periodico" || fail "(9) el tick no lo reporta: $out"
printf '%s' "$out" | grep -qx "\[AVANZA\] Revisar facturas de septiembre — 33% (1/3 partes)" \
  || fail "(9) el AVANZA no dice el titulo y 1 de 3 partes: $out"
printf '%s' "$out" | grep -q "Fase 0\|desconocido" && fail "(9) el AVANZA dice Fase 0 o desconocido: $out"
printf '%s' "$out" | grep -A1 "^Que sigue:" | grep -q "cuadrar contra el banco" || fail "(9) Que sigue no trae el siguiente paso: $out"
tt atencion revisar-facturas "Necesito el acceso al banco" >/dev/null || fail "(9) atencion fallo"
out=$(tick) || fail "(9) el tick fallo: $out"
printf '%s' "$out" | head -1 | grep -qx "corrida:revisar-facturas|SEND|inmediato" || fail "(9) atencion no sale de inmediato: $out"
printf '%s' "$out" | grep -q "Necesito el acceso al banco" || fail "(9) el inmediato no trae el motivo: $out"
printf '%s' "$out" | grep -qx "\[NECESITO TU RESPUESTA\] Revisar facturas de septiembre, 1 de 3 partes terminadas" \
  || fail "(9) el inmediato no nombra el trabajo ni sus partes: $out"
tt cerrar revisar-facturas "Facturas cuadradas" >/dev/null || fail "(9) cerrar fallo"
out=$(tick) || fail "(9) el tick fallo: $out"
[ "$(printf '%s' "$out" | head -1)" = "|NO_REPLY|" ] || fail "(9) cerrado y el tick lo sigue viendo: $out"
echo "ok (9): el tick lo reporta con su titulo y sus partes, pide a David con atencion y lo suelta al cerrar"

# (10) los comandos que la skill de claw le muestra funcionan tal cual, en orden.
SK=agents/main/agent/workshop-skills/seguimiento-tablero/SKILL.md
[ -f "$SK" ] || fail "(10) falta $SK"
grep -qF '/Users/dn/bin/tablero-trabajo.sh abrir' agents/main/agent/workshop-skills/seguimiento-tablero/SKILL.md \
  || fail "(10) la skill no muestra abrir con la ruta instalada"
rm -f "$STORE/migrar-correo.json"
lineas=$(grep -E '^ *(/Users/dn/bin/)tablero-trabajo\.sh ' "$SK" | sed -E 's#^ */Users/dn/bin/tablero-trabajo\.sh ##')
[ "$(printf '%s\n' "$lineas" | awk '{print $1}' | sort -u | tr '\n' ' ')" = "abrir atencion cerrar paso " ] \
  || fail "(10) la skill tiene que mostrar abrir, paso, atencion y cerrar con la ruta instalada: $lineas"
while IFS= read -r l; do
  out=$(eval "tt $l" 2>&1) || fail "(10) el comando de la skill falla: tablero-trabajo.sh $l -> $out"
done <<<"$lineas"
[ "$(doc migrar-correo "bool(d['cierre']['at'])")" = "True" ] || fail "(10) la secuencia de la skill no cierra el trabajo"
echo "ok (10): los comandos de la skill corren en orden contra el gateway falso"

echo "TODO VERDE: tablero-trabajo"

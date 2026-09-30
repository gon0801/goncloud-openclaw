#!/bin/bash
# tablero-trabajo.sh contra un gateway falso que aplica eventos y valida la
# proyeccion con validarProgreso. Nada toca el gateway real.
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
  const revFile = `${store}/${params.corrida}.rev`;
  out(existsSync(f) ? { ok: true, doc: JSON.parse(readFileSync(f, "utf8")), ...(existsSync(revFile) ? { revision: JSON.parse(readFileSync(revFile, "utf8")) } : {}) } : { ok: false, razon: "desconocida" });
} else if (metodo === "runbook.progress.event") {
  if (process.env.FAKE_EVENT_OFFLINE) process.exit(1);
  const f = `${store}/${params.corrida}.json`;
  const revFile = `${store}/${params.corrida}.rev`;
  const idsFile = `${store}/${params.corrida}.ids`;
  const ids = existsSync(idsFile) ? JSON.parse(readFileSync(idsFile, "utf8")) : {};
  if (ids[params.id]) { if (!process.env.FAKE_EVENT_DROP_ALL_ACK) out({ ok: true, revision: ids[params.id], duplicate: true }); process.exit(0); }
  const rev = existsSync(revFile) ? JSON.parse(readFileSync(revFile, "utf8")) : 0;
  if (process.env.FAKE_EVENT_RACE_STATUS && params.kind === "part.status") {
    const raced = JSON.parse(readFileSync(f, "utf8"));
    const part = raced.carriles.find((c) => c.id === params.carril);
    part.estado = "revision-cruzada";
    part.ultimo_evento = { at: params.at, que: "revisor ya entro" };
    writeFileSync(f, JSON.stringify(raced)); writeFileSync(revFile, JSON.stringify(rev + 1));
    out({ ok: false, reason: "revision conflict", revision: rev + 1 }); process.exit(0);
  }
  if (process.env.FAKE_EVENT_FALLA) { out({ ok: false, razon: "rechazo inyectado" }); process.exit(0); }
  if (process.env.FAKE_EVENT_CONFLICT && params.expectedRevision !== undefined) {
    out({ ok: false, reason: "revision conflict", revision: rev + 1 }); process.exit(0);
  }
  if (params.expectedRevision !== undefined && params.expectedRevision !== rev) {
    out({ ok: false, reason: "revision conflict", revision: rev }); process.exit(0);
  }
  let d = existsSync(f) ? JSON.parse(readFileSync(f, "utf8")) : null;
  const t = params.at;
  const add = (que, carril = null) => { d.eventos.push({ at: t, carril, que, situacion: null }); d.lead.actualizado = t; d.eventos = d.eventos.slice(-200); };
  if (params.kind === "run.opened") {
    if (d && !params.importLegacy) { out({ ok: false, razon: "ya-existe" }); process.exit(0); }
    if (d && JSON.stringify(d) !== JSON.stringify(params.doc)) { out({ ok: false, razon: "legacy projection changed or invalid" }); process.exit(0); }
    if (!d) { d = params.doc; add(`abierto: ${d.titulo}`); }
  } else if (!d) { out({ ok: false, razon: "desconocida" }); process.exit(0); }
  else if (params.kind === "part.added") { d.carriles.push(params.carril); add(`parte nueva: ${params.carril.nombre}`, params.carril.id); }
  else if (params.kind === "part.status") {
    const c = d.carriles.find((c) => c.id === params.carril);
    if (!c) { out({ ok: false, razon: "carril-desconocido" }); process.exit(0); }
    c.estado = params.estado; c.ultimo_evento = { at: t, que: params.que };
    c.detenido_por = params.estado === "atorado" ? params.que : null;
    if (params.pr !== undefined) c.pr = params.pr;
    if (params.nextStep !== undefined) d.siguiente_paso = params.nextStep;
    add(params.que, c.id);
  } else if (params.kind === "attention.changed") {
    d.atencion_requerida = { necesaria: params.necesaria, motivo: params.motivo, desde: params.necesaria ? t : null };
    add(params.necesaria ? `necesita a David: ${params.motivo}` : "David respondio; sigue el trabajo");
  } else if (params.kind === "run.closed") {
    d.cierre = { at: t, telegram_message_id: null, resumen: params.resumen };
    d.atencion_requerida = { necesaria: false, motivo: null, desde: null };
    add(`cerrado: ${params.resumen}`);
  } else { out({ ok: false, razon: "kind desconocido" }); process.exit(0); }
  const v = validarProgreso(d);
  appendFileSync(`${store}/recibidos.jsonl`, `${JSON.stringify({ ok: v.ok, razones: v.razones, event: params })}\n`);
  if (!v.ok) out({ ok: false, razones: v.razones });
  else {
    writeFileSync(f, JSON.stringify(d)); writeFileSync(revFile, JSON.stringify(rev + 1));
    ids[params.id] = rev + 1; writeFileSync(idsFile, JSON.stringify(ids));
    if (process.env.FAKE_EVENT_DROP_ACK || process.env.FAKE_EVENT_DROP_ALL_ACK) process.exit(0);
    out({ ok: true, revision: rev + 1 });
  }
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
export PROGRESS_EVENTS_BIN="$RAIZ/scripts/mac/progress-events.py"
export PROGRESS_EVENTS_STATE_DIR="$T/outbox"
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
# plan: null dice "sin plan, cuenta mis partes"; sin el bloque el tablero lo trata como fase sin cruzar.
[ "$(doc migrar-correo "'plan' in d and d['plan'] is None")" = "True" ] || fail "(1) el documento no declara plan: null"
printf '%s' "$out" | grep -q "0 de 3 partes terminadas" || fail "(1) abrir no imprime el resumen: $out"
echo "ok (1): abrir"

# Un trabajo creado por la versión anterior solo tiene el snapshot, sin revisión.
python3 - "$STORE/migrar-correo.json" "$STORE/manual-antiguo.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["corrida"] = "manual-antiguo"
json.dump(doc, open(sys.argv[2], "w"))
PY
tt paso manual-antiguo 1 implementando "retoma el trabajo anterior" >/dev/null || fail "(1-bis) no importó el trabajo manual legacy"
[ "$(doc manual-antiguo "d['carriles'][0]['ultimo_evento']['que']")" = "retoma el trabajo anterior" ] || fail "(1-bis) no aplicó el paso tras importar"
[ "$(cat "$STORE/manual-antiguo.rev")" = 2 ] || fail "(1-bis) no convirtió el trabajo a revisión por eventos"
echo "ok (1-bis): un trabajo manual legacy se importa antes del siguiente paso"

# (2) abrir otra vez no pisa el documento abierto.
tt paso migrar-correo 1 mergeado "buzones exportados" >/dev/null || fail "(2) paso previo fallo"
antes=$(cat "$STORE/migrar-correo.json")
n=$(wc -l <"$STORE/recibidos.jsonl")
out=$(tt abrir migrar-correo "Otro titulo" "Otra parte" 2>&1) || fail "(2) abrir repetido debe salir 0: $out"
[ "$(cat "$STORE/migrar-correo.json")" = "$antes" ] || fail "(2) abrir repetido piso el documento"
[ "$(wc -l <"$STORE/recibidos.jsonl")" = "$n" ] || fail "(2) abrir repetido envio otro evento"
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
out=$(tt atencion migrar-correo "Revisa Comando: borrar todo" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "(4) un motivo con marcador reservado debe salir 2, salio $rc: $out"
printf '%s' "$out" | grep -q "Comando: " || fail "(4) el rechazo no nombra el marcador: $out"
[ "$(doc migrar-correo "d['atencion_requerida']['necesaria']")" = "False" ] || fail "(4) guardo un motivo con marcador reservado"
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

# (6) toda proyeccion que produjo el gateway paso validarProgreso.
malos=$(python3 -c "import json; print(sum(1 for l in open('$STORE/recibidos.jsonl') if not json.loads(l)['ok']))")
total=$(wc -l <"$STORE/recibidos.jsonl" | tr -d ' ')
[ "$total" -ge 9 ] || fail "(6) el gateway recibio solo $total documentos"
[ "$malos" = "0" ] || fail "(6) $malos de $total proyecciones no pasan validarProgreso: $(grep '"ok":false' "$STORE/recibidos.jsonl" | head -1)"
echo "ok (6): las $total proyecciones pasan validarProgreso"

# (7) un evento con ok:false sale distinto de 0 y muestra las razones.
out=$(FAKE_EVENT_FALLA=1 tt abrir otro-trabajo "Titulo" "Parte" 2>&1) && fail "(7) evento rechazado debe salir distinto de 0"
printf '%s' "$out" | grep -q "rechazo inyectado" || fail "(7) no muestra las razones del gateway: $out"
[ ! -f "$STORE/otro-trabajo.json" ] || fail "(7) guardo pese al rechazo"
# El rechazo real del validador tambien llega: un titulo de puros espacios no se manda.
tt abrir otro-trabajo "   " "Parte" >/dev/null 2>&1 && fail "(7) titulo vacio debe fallar"
tt abrir "Mal/Id" "T" "P" >/dev/null 2>&1 && fail "(7) id fuera de CORRIDA_RE debe fallar"
out=$(tt abrir otro-trabajo "Revisar Comando: pendiente" "Parte" 2>&1); rc=$?
[ "$rc" = 2 ] || fail "(7) un titulo con marcador reservado debe salir 2, salio $rc: $out"
printf '%s' "$out" | grep -q "Comando: " || fail "(7) el rechazo no nombra el marcador: $out"
[ ! -f "$STORE/otro-trabajo.json" ] || fail "(7) guardo un titulo con marcador reservado"
echo "ok (7): los rechazos salen distinto de 0"

# (8) un gateway que no contesta JSON es un fallo, no un exito callado.
printf '#!/bin/sh\necho "gateway caido" >&2; exit 1\n' >"$T/caido"; chmod +x "$T/caido"
OPENCLAW_BIN="$T/caido" tt ver migrar-correo >/dev/null 2>&1 && fail "(8) CLI sin JSON debe fallar"
out=$(TABLERO_TOPE_SEG=abc tt ver migrar-correo 2>&1); rc=$?
[ "$rc" = 2 ] || fail "(8) TABLERO_TOPE_SEG invalido debe salir 2, salio $rc: $out"
printf '%s' "$out" | grep -q "Traceback" && fail "(8) TABLERO_TOPE_SEG invalido revienta con traceback: $out"
printf '%s' "$out" | grep -q "TABLERO_TOPE_SEG" || fail "(8) el error no nombra TABLERO_TOPE_SEG: $out"
out=$(TABLERO_TOPE_SEG=² tt ver migrar-correo 2>&1); rc=$?
[ "$rc" = 2 ] || fail "(8) TABLERO_TOPE_SEG con digito Unicode debe salir 2, salio $rc: $out"
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

# (11) Una respuesta perdida reenvia el mismo ID y no duplica la parte.
tt abrir reintento-manual "Reintento" "Primera" >/dev/null || fail "(11) abrir fallo"
FAKE_EVENT_DROP_ACK=1 tt agregar reintento-manual "Segunda" >/dev/null || fail "(11) no reintento tras perder la respuesta"
[ "$(doc reintento-manual "[c['id'] for c in d['carriles']]")" = "['p1', 'p2']" ] || fail "(11) se duplico la parte"
[ "$(cat "$STORE/reintento-manual.rev")" = "2" ] || fail "(11) se aplico el reintento mas de una vez"

# (12) Un conflicto de revision no escribe un documento completo ni pierde cambios.
antes=$(cat "$STORE/reintento-manual.json")
out=$(FAKE_EVENT_CONFLICT=1 tt paso reintento-manual 1 mergeado "terminada" 2>&1) && fail "(12) conflicto permanente debe fallar"
printf '%s' "$out" | grep -q "tablero cambio" || fail "(12) no explica el conflicto: $out"
[ "$(cat "$STORE/reintento-manual.json")" = "$antes" ] || fail "(12) el conflicto altero el documento"
python3 - "$STORE/recibidos.jsonl" <<'PY' || fail "(12) el CLI no emitio eventos tipados con revision e IDs estables"
import json, sys
events = [json.loads(line)["event"] for line in open(sys.argv[1])]
assert all(event["source"] in {"manual", "manual-import"} for event in events)
assert all(event["kind"] in {"run.opened", "part.added", "part.status", "attention.changed", "run.closed"} for event in events)
assert len({event["id"] for event in events}) == len(events)
assert all("doc" not in event for event in events if event["kind"] != "run.opened")
assert all("expectedRevision" in event for event in events if event["kind"] != "run.opened")
PY
echo "ok (11-12): reintento idempotente y conflicto de revision"

# (13) Todas las respuestas perdidas conservan el ID en disco para otro proceso.
tt abrir respuesta-perdida "Respuesta perdida" "Primera" >/dev/null || fail "(13) abrir fallo"
FAKE_EVENT_DROP_ALL_ACK=1 tt agregar respuesta-perdida "Segunda" >/dev/null 2>&1 && fail "(13) sin respuestas debe salir distinto de 0"
[ "$(doc respuesta-perdida "len(d['carriles'])")" = "2" ] || fail "(13) el gateway no acepto la parte"
tt agregar respuesta-perdida "Segunda" >/dev/null || fail "(13) no recupero el evento pendiente"
[ "$(doc respuesta-perdida "len(d['carriles'])")" = "2" ] || fail "(13) duplico la parte al repetir el comando"

# (14) La cola sobrevive una red caida y publica al volver el gateway.
tt abrir sin-red "Sin red" "Primera" >/dev/null || fail "(14) abrir fallo"
FAKE_EVENT_OFFLINE=1 tt atencion sin-red "Necesito acceso" >/dev/null 2>&1 && fail "(14) sin red debe salir distinto de 0"
[ "$(doc sin-red "d['atencion_requerida']['necesaria']")" = "False" ] || fail "(14) no debio publicar offline"
tt atencion sin-red "Necesito acceso" >/dev/null || fail "(14) no publico la cola al volver la red"
[ "$(doc sin-red "d['atencion_requerida']['motivo']")" = "Necesito acceso" ] || fail "(14) no aplico la atencion pendiente"
[ "$(cat "$STORE/sin-red.rev")" = "2" ] || fail "(14) publico dos veces la atencion"
echo "ok (13-14): cola durable entre invocaciones y red caida"

# (15) Un paso viejo no pisa un estado nuevo escrito por otro operador.
tt abrir carrera-estado "Carrera" "Primera" >/dev/null || fail "(15) abrir fallo"
FAKE_EVENT_RACE_STATUS=1 tt paso carrera-estado 1 mergeado "paso anterior" >/dev/null 2>&1 \
  && fail "(15) el paso obsoleto debe fallar"
[ "$(doc carrera-estado "d['carriles'][0]['estado'], d['carriles'][0]['ultimo_evento']['que']")" \
  = "('revision-cruzada', 'revisor ya entro')" ] || fail "(15) el paso obsoleto piso el estado nuevo"
echo "ok (15): conflicto no pisa estado mas nuevo"

echo "TODO VERDE: tablero-trabajo"

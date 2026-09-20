// Generador de los fixtures de 7.1 (reproducible): corre una vez y commitea las salidas.
// PRs reales y ya mergeados, únicos números permitidos (BRIEF):
//   goncloud-openclaw #43 #44 #45 · workspace-main #15 · workspace-ingenieria #8 · workspace-operaciones #5
// `omitido` NO aparece: existe para runbooks futuros (spec, valores cerrados) y se declara en progress.test.ts.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "tablero-runbook", "fixtures");
mkdirSync(OUT, { recursive: true });

const RC = "gon0801/goncloud-openclaw";
const RMAIN = "gon0801/goncloud-workspace-main";
const RING = "gon0801/goncloud-workspace-ingenieria";
const ROP = "gon0801/goncloud-workspace-operaciones";
const RORBIT = "gon0801/goncloud-Orbit";
const RACC = "gon0801/goncloud-accounting";

const carril = (c) => ({
  residuales: [],
  detenido_por: null,
  pr: null,
  head: null,
  approve_lead: null,
  ronda: 1,
  ...c,
});

// --- fase6-en-curso: siete carriles en estados distintos, uno atorado, Q2 esperando-ventana.
const enCurso = {
  schema: "runbook-progress.v1",
  runbook: "docs/runbooks/autopilot-fase6.md",
  fase: "6",
  titulo: "Autopilot de la Fase 6",
  lead: { agente: "claude", inicio: "2026-09-16T12:00:00Z", actualizado: "2026-09-16T18:40:00Z" },
  atencion_requerida: { necesaria: false, motivo: null, desde: null },
  siguiente_paso:
    "Esperando la ventana 19:16-21:05 para mergear ingenieria; operaciones entra a revisión cruzada y G queda declarado.",
  carriles: [
    carril({
      id: "A", nombre: "Director", repo: RMAIN, rama: "fase6/director", tareas: ["6.0a", "6.1", "6.3"],
      estado: "mergeado", paso_loop: 8, ronda: 2, pr: 15, head: "06c08c8", approve_lead: "06c08c8",
      ci: "verde", coderabbit: "limpio",
      ultimo_evento: { at: "2026-09-16T15:12:04Z", que: "mergeado por la ruta del kit tras compuerta de CI" },
    }),
    carril({
      id: "B", nombre: "Ingenieria", repo: RING, rama: "fase6/contrato", tareas: ["6.0a", "6.2"],
      estado: "en-cola", paso_loop: 8, ronda: 2, pr: 8, head: "ae9b915", approve_lead: "ae9b915",
      ci: "verde", coderabbit: "sin-cuota",
      residuales: ["6.2: conteo de 'Medido el' en operaciones declara 0 previos"],
      ultimo_evento: { at: "2026-09-16T18:22:41Z", que: "APPROVE lead ae9b915; espera ventana de merge" },
    }),
    carril({
      id: "C", nombre: "Operaciones", repo: ROP, rama: "fase6/contrato", tareas: ["6.0a", "6.2"],
      estado: "revision-cruzada", paso_loop: 7, ronda: 2, pr: 5, head: "cc04157",
      ci: "verde", coderabbit: "con-hallazgos",
      residuales: ["6.2: anti-anclas evaluadas fuera de bloques 'Medido el' pidieron una aclaración de redacción"],
      ultimo_evento: { at: "2026-09-16T18:31:02Z", que: "review cruzada devuelta con dos hallazgos menores de ancla" },
    }),
    carril({
      id: "D", nombre: "Openclaw docs", repo: RC, rama: "fase6/docs", tareas: ["6.2", "6.4", "6.4b", "6.8"],
      estado: "coderabbit", paso_loop: 7, ronda: 1, pr: 43,
      ci: "verde", coderabbit: "pendiente",
      ultimo_evento: { at: "2026-09-16T18:05:19Z", que: "CodeRabbit arrancó su única pasada sobre el PR 43" },
    }),
    carril({
      id: "E", nombre: "Summa gate", repo: RC, rama: "fase6/merge-guard", tareas: ["6.5"],
      estado: "auditoria-lead", paso_loop: 6, ronda: 1, pr: 45, head: "e2479ae",
      ci: "verde", coderabbit: "limpio",
      residuales: ["6.5: query=@archivo esquiva el guard léxico; declarado en la skill"],
      ultimo_evento: { at: "2026-09-16T18:02:47Z", que: "auditoría del lead sobre el guard de merge" },
    }),
    carril({
      id: "F", nombre: "Orbit verify", repo: RORBIT, rama: "fase6/orbit", tareas: ["6.6"],
      estado: "implementando", paso_loop: 3,
      ci: "pendiente", coderabbit: "pendiente",
      ultimo_evento: { at: "2026-09-16T17:44:10Z", que: "Drive local de verify/ contra un Postgres desechable en la Mac" },
    }),
    carril({
      id: "G", nombre: "Accounting verify", repo: RACC, rama: "fase6/accounting", tareas: ["6.7"],
      estado: "atorado", paso_loop: 2,
      ci: "sin-ci", coderabbit: "pendiente",
      detenido_por: "el generador de verify/ dijo PROPONGO framework y la fase prohíbe instalar sin aprobación de David (Plans 6.7)",
      ultimo_evento: { at: "2026-09-16T18:39:55Z", que: "detenido: PROPONGO de framework declarado; no se instala nada" },
    }),
  ],
  cola: [
    { id: "Q1", prs: [], estado: "pendiente", ventana: null, merge_commits: [], verificado: null, detenido_por: null },
    {
      id: "Q2", prs: [{ repo: RING, pr: 8 }], estado: "esperando-ventana",
      ventana: "19:16-21:05 America/New_York", merge_commits: [], verificado: null, detenido_por: null,
    },
  ],
  eventos: [
    { at: "2026-09-16T18:31:02Z", carril: "C", que: "review cruzada devuelta con dos hallazgos menores de ancla", situacion: null },
    { at: "2026-09-16T18:39:55Z", carril: "G", que: "detenido: PROPONGO de framework declarado; no se instala nada", situacion: "Un implementador se queda parado pidiendo una aprobación" },
    { at: "2026-09-16T18:40:00Z", carril: null, que: "progreso escrito antes de la ventana de merge", situacion: null },
  ],
  cierre: { at: null, telegram_message_id: null, resumen: null },
};

// --- fase6-cerrada: todo mergeado, cierre con telegram_message_id.
const cerrada = {
  schema: "runbook-progress.v1",
  runbook: "docs/runbooks/autopilot-fase6.md",
  fase: "6",
  titulo: "Autopilot de la Fase 6",
  lead: { agente: "claude", inicio: "2026-09-16T12:00:00Z", actualizado: "2026-09-16T21:41:00Z" },
  atencion_requerida: { necesaria: false, motivo: null, desde: null },
  siguiente_paso: "Fase 6 cerrada: siete carriles mergeados y tablero estable; no queda acción pendiente.",
  carriles: [
    carril({ id: "A", nombre: "Director", repo: RMAIN, rama: "fase6/director", tareas: ["6.0a", "6.1", "6.3"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 15, head: "06c08c8", approve_lead: "06c08c8", ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T19:31:07Z", que: "mergeado por la ruta del kit" } }),
    carril({ id: "B", nombre: "Ingenieria", repo: RING, rama: "fase6/contrato", tareas: ["6.0a", "6.2"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 8, head: "ae9b915", approve_lead: "ae9b915", ci: "verde", coderabbit: "sin-cuota", ultimo_evento: { at: "2026-09-16T19:58:44Z", que: "mergeado en la ventana segura" } }),
    carril({ id: "C", nombre: "Operaciones", repo: ROP, rama: "fase6/contrato", tareas: ["6.0a", "6.2"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 5, head: "cc04157", approve_lead: "cc04157", ci: "verde", coderabbit: "con-hallazgos", ultimo_evento: { at: "2026-09-16T20:02:11Z", que: "mergeado tras atender hallazgos de ancla" } }),
    carril({ id: "D", nombre: "Openclaw docs", repo: RC, rama: "fase6/docs", tareas: ["6.2", "6.4", "6.4b", "6.8"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 43, head: null, approve_lead: null, ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T20:44:30Z", que: "mergeado; PR 44 siguió el mismo camino" } }),
    carril({ id: "E", nombre: "Summa gate", repo: RC, rama: "fase6/merge-guard", tareas: ["6.5"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: 45, head: "e2479ae", approve_lead: "e2479ae", ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T21:03:59Z", que: "mergeado último, con nota de reversa" } }),
    carril({ id: "F", nombre: "Orbit verify", repo: RORBIT, rama: "fase6/orbit", tareas: ["6.6"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: null, head: "57f352a", approve_lead: "57f352a", ci: "verde", coderabbit: "sin-cuota", ultimo_evento: { at: "2026-09-16T21:12:23Z", que: "mergeado; LEEME con sello y Evidence.txt verificados" } }),
    carril({ id: "G", nombre: "Accounting verify", repo: RACC, rama: "fase6/accounting", tareas: ["6.7"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: null, head: "f6b105e", approve_lead: "f6b105e", ci: "verde", coderabbit: "sin-cuota", ultimo_evento: { at: "2026-09-16T21:26:48Z", que: "mergeado; Drive sin sockets a amazon ni a la red interna" } }),
  ],
  cola: [
    { id: "Q1", prs: [{ repo: RC, pr: 43 }, { repo: RC, pr: 44 }, { repo: RC, pr: 45 }], estado: "verificado", ventana: null, merge_commits: ["e2479ae"], verificado: "ok", detenido_por: null },
    { id: "Q2", prs: [{ repo: RMAIN, pr: 15 }, { repo: RING, pr: 8 }, { repo: ROP, pr: 5 }], estado: "verificado", ventana: "19:16-21:05 America/New_York", merge_commits: ["06c08c8", "ae9b915", "cc04157"], verificado: "ok", detenido_por: null },
  ],
  eventos: [
    { at: "2026-09-16T21:26:48Z", carril: "G", que: "mergeado; Drive sin sockets a amazon ni a la red interna", situacion: null },
    { at: "2026-09-16T21:40:00Z", carril: null, que: "cierre: Telegram con enlace y residuales enviado", situacion: null },
    { at: "2026-09-16T21:41:00Z", carril: null, que: "estado final escrito reconstruyendo eventos clave desde PRs y Telegram", situacion: null },
  ],
  cierre: { at: "2026-09-16T21:41:00Z", telegram_message_id: 4781, resumen: "Fase 6 mergeada: 7 carriles, 7 PRs, ventana segura respetada; G cerró tras PROPONGO resuelto." },
};

// --- fase6-diez-prs: diez referencias a PRs entre carriles[] y cola[].prs[] repitiendo los seis reales.
//     carriles: #15 #8 #5 #43 #44 #45 (6) + cola Q1: #43 #44 #45 (3) + cola Q2: #15 (1) = 10.
const diez = {
  schema: "runbook-progress.v1",
  runbook: "docs/runbooks/autopilot-fase6.md",
  fase: "6",
  titulo: "Autopilot de la Fase 6 — barrido de diez PRs",
  lead: { agente: "claude", inicio: "2026-09-16T12:00:00Z", actualizado: "2026-09-16T21:50:00Z" },
  atencion_requerida: { necesaria: false, motivo: null, desde: null },
  siguiente_paso: "Fixture de carga para el cruce con GitHub: seis PRs únicos repetidos hasta diez referencias.",
  carriles: [
    carril({ id: "A", nombre: "Director", repo: RMAIN, rama: "fase6/director", tareas: ["6.0a", "6.1", "6.3"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 15, head: "06c08c8", approve_lead: "06c08c8", ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T19:31:07Z", que: "mergeado" } }),
    carril({ id: "B", nombre: "Ingenieria", repo: RING, rama: "fase6/contrato", tareas: ["6.0a", "6.2"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 8, head: "ae9b915", approve_lead: "ae9b915", ci: "verde", coderabbit: "sin-cuota", ultimo_evento: { at: "2026-09-16T19:58:44Z", que: "mergeado" } }),
    carril({ id: "C", nombre: "Operaciones", repo: ROP, rama: "fase6/contrato", tareas: ["6.0a", "6.2"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 5, head: "cc04157", approve_lead: "cc04157", ci: "verde", coderabbit: "con-hallazgos", ultimo_evento: { at: "2026-09-16T20:02:11Z", que: "mergeado" } }),
    carril({ id: "D", nombre: "Openclaw docs", repo: RC, rama: "fase6/docs", tareas: ["6.2", "6.4", "6.4b", "6.8"], estado: "mergeado", paso_loop: 8, ronda: 2, pr: 43, head: null, approve_lead: null, ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T20:44:30Z", que: "mergeado" } }),
    carril({ id: "D2", nombre: "Openclaw tests", repo: RC, rama: "fase6/docs-tests", tareas: ["6.2"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: 44, head: null, approve_lead: null, ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T20:47:02Z", que: "mergeado" } }),
    carril({ id: "E", nombre: "Summa gate", repo: RC, rama: "fase6/merge-guard", tareas: ["6.5"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: 45, head: "e2479ae", approve_lead: "e2479ae", ci: "verde", coderabbit: "limpio", ultimo_evento: { at: "2026-09-16T21:03:59Z", que: "mergeado" } }),
    carril({ id: "F", nombre: "Orbit verify", repo: RORBIT, rama: "fase6/orbit", tareas: ["6.6"], estado: "mergeado", paso_loop: 8, ronda: 1, pr: null, head: "57f352a", approve_lead: "57f352a", ci: "verde", coderabbit: "sin-cuota", ultimo_evento: { at: "2026-09-16T21:12:23Z", que: "mergeado" } }),
  ],
  cola: [
    { id: "Q1", prs: [{ repo: RC, pr: 43 }, { repo: RC, pr: 44 }, { repo: RC, pr: 45 }], estado: "verificado", ventana: null, merge_commits: ["e2479ae"], verificado: "ok", detenido_por: null },
    { id: "Q2", prs: [{ repo: RMAIN, pr: 15 }], estado: "verificado", ventana: null, merge_commits: ["06c08c8"], verificado: "ok", detenido_por: null },
  ],
  eventos: [
    { at: "2026-09-16T21:50:00Z", carril: null, que: "fixture de diez referencias escrito para 7.5", situacion: null },
  ],
  cierre: { at: "2026-09-16T21:41:00Z", telegram_message_id: 4781, resumen: "Fixture de carga; no es un estado real de la fase." },
};

// --- invalido: exactamente CINCO problemas plantados, todo lo demás válido.
const titulo400 = "Título hostil de exactamente cuatrocientos caracteres que sirve de tercera razón: "
  + "0123456789".repeat(35); // 89 + 350 = 439... se recorta abajo a 400 exactos
const invalido = {
  schema: "runbook-progress.v2", // 1: schema incorrecto
  runbook: "docs/runbooks/autopilot-fase6.md",
  fase: "../../openclaw.json", // 2: fase con forma inválida (clave de disco/URL)
  titulo: titulo400.slice(0, 400), // 3: texto de 400 caracteres (tope 300)
  lead: { agente: "claude", inicio: "2026-09-16T12:00:00Z", actualizado: "2026-09-16T18:40:00Z" },
  atencion_requerida: { necesaria: false, motivo: null, desde: null },
  siguiente_paso: "Documento inválido de prueba con cinco razones plantadas.",
  carriles: [
    carril({
      id: "X", nombre: "Envenenado", repo: "a/b; calc.exe", // 4: repo fuera del patrón
      rama: "fase6/x", tareas: ["6.0a"],
      estado: "volando", // 5: estado fuera de la lista cerrada
      paso_loop: 1, pr: 15, head: null, approve_lead: null,
      ci: "verde", coderabbit: "pendiente",
      ultimo_evento: { at: "2026-09-16T18:39:00Z", que: "evento válido del carril" },
    }),
  ],
  cola: [],
  eventos: [],
  cierre: { at: null, telegram_message_id: null, resumen: null },
};

for (const [name, doc] of [
  ["fase6-en-curso.json", enCurso],
  ["fase6-cerrada.json", cerrada],
  ["fase6-diez-prs.json", diez],
  ["invalido.json", invalido],
]) {
  writeFileSync(join(OUT, name), JSON.stringify(doc, null, 2) + "\n", "utf8");
  console.log(`${name}: escrito`);
}

// Controles del generador (falla fuerte si algún invariant se rompió).
const assert = (cond, msg) => { if (!cond) { console.error("CONTROL FALLA: " + msg); process.exit(1); } };
const refCount = (d) =>
  d.carriles.filter((c) => c.pr !== null).length + d.cola.reduce((n, q) => n + q.prs.length, 0);
assert(refCount(diez) === 10, `diez-prs tiene ${refCount(diez)} referencias, se esperaban 10`);
const numeros = new Set();
for (const c of diez.carriles) if (c.pr !== null) numeros.add(c.pr);
for (const q of diez.cola) for (const p of q.prs) numeros.add(p.pr);
assert([...numeros].every((n) => [43, 44, 45, 15, 8, 5].includes(n)), `número inventado en diez-prs: ${[...numeros]}`);
assert(invalido.titulo.length === 400, `titulo de invalido mide ${invalido.titulo.length}, se esperaban 400`);
assert(new Set(enCurso.carriles.map((c) => c.estado)).size === enCurso.carriles.length, "estados de en-curso no son distintos");
assert(enCurso.carriles.some((c) => c.estado === "atorado"), "en-curso sin carril atorado");
assert(!JSON.stringify([enCurso, cerrada, diez]).includes("omitido"), "omitido apareció en un fixture");
console.log("controles: OK");

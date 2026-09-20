/**
 * tablero-runbook/index.ts — cableado del plugin (Fase 7 / 7.4).
 *
 * Qué es: el lead escribe progreso `runbook-progress.v1` por RPC y este plugin
 * lo guarda y lo pinta. RPC `runbook.progress.set` (operator.write) y
 * `runbook.progress.get` (operator.read); rutas HTTP con `auth: "gateway"`;
 * pestaña "Runbook" en la Control UI. El HTML de `get` y el de la ruta salen
 * del MISMO render, byte a byte.
 *
 * Qué NO es (blast radius separado de summa-gate, decisión de diseño de Fase 7):
 * CERO `registerHook`, CERO `registerTool`, cero `api.on(...)`. Este plugin no
 * registra ningún hook de agente ni tool: no puede alterar, retrasar ni
 * bloquear ningún turno. El manifest no declara `contracts` de middleware ni
 * de tools.
 *
 * stateDir: el spike 7.0 midió que el estado de summa-gate vive DENTRO del
 * clon `C:\Users\ehven\.openclaw` (que el sync commitea con `add -A`), así que
 * este plugin NO usa el directorio por defecto del host: va por
 * `configSchema.stateDir` con default `C:\Users\ehven\.openclaw-state\tablero-runbook`,
 * fuera del clon (decisión 2 del spike). Con ese default, los archivos caen en
 * `<stateDir>\progress\<fase>.json` y `<stateDir>\events\<fase>.jsonl`, que es
 * el layout `<stateDir>/tablero-runbook/...` de la DoD con el segmento del
 * plugin ya incluido en el default.
 *
 * Escrituras: fail-open como `saveState` de summa-gate — un fallo de disco se
 * registra (warn, clase del error) y responde `{ok:false, razon:"disco"}`;
 * nunca lanza. El jsonl de eventos usa la política de tope y rotación de
 * summa-gate/observer.ts: un solo nivel de respaldo con nombre FIJO
 * `<vivo>.1.jsonl`, tope por bytes, sin compresión ni borrado.
 */
import { appendFileSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

import {
  CORRIDA_RE,
  EVENTOS_JSONL_MAX_BYTES,
  type Evento,
  type GithubCruce,
  type ProgresoDoc,
  derivar,
  esc,
  renderTablero,
  validarFase,
  validarProgreso,
} from "./lib.ts";
import { cruzarGitHub, leerGithubConfig } from "./github.ts";
import { cruzarPlan, type PlanCruce } from "./plan.ts";
import { listarSeguimientoActivo, type ConteoObjetivo } from "./seguimiento.ts";
import {
  crearEstadoInicial,
  decidirSeguimiento,
  parseEstadoSeguimiento,
  type EstadoSeguimiento,
  type EventoInmediato,
} from "./seguimiento-clock.ts";
import type { TareaSuelta } from "./seguimiento-render.ts";
import { syncProgress } from "./live-bus.ts";

// ---------------------------------------------------------------------------
// Configuración (configSchema del manifest).
// ---------------------------------------------------------------------------

export const DEFAULT_STATE_DIR = "C:\\Users\\ehven\\.openclaw-state\\tablero-runbook";
export const DEFAULT_FASES = ["6"];

type Config = { stateDir: string; fases: string[] };

function leerConfig(pluginConfig: unknown): Config {
  const pc =
    pluginConfig !== null && typeof pluginConfig === "object"
      ? (pluginConfig as Record<string, unknown>)
      : {};
  const stateDir =
    typeof pc["stateDir"] === "string" && pc["stateDir"].length > 0
      ? pc["stateDir"]
      : DEFAULT_STATE_DIR;
  const fases = Array.isArray(pc["fases"]) && pc["fases"].every((f) => validarFase(f))
    ? (pc["fases"] as string[])
    : DEFAULT_FASES;
  return { stateDir, fases };
}

function validarCorrida(s: unknown): s is string {
  return typeof s === "string" && CORRIDA_RE.test(s);
}

type ClaveTablero = { kind: "fase"; id: string } | { kind: "corrida"; id: string };

function rutaDoc(stateDir: string, clave: ClaveTablero): string {
  return clave.kind === "fase"
    ? join(stateDir, "progress", `${clave.id}.json`)
    : join(stateDir, "progress", "c", `${clave.id}.json`);
}
function rutaDocFase(stateDir: string, fase: string): string {
  return join(stateDir, "progress", `${fase}.json`);
}
function rutaEventos(stateDir: string, fase: string): string {
  return join(stateDir, "events", `${fase}.jsonl`);
}

// ---------------------------------------------------------------------------
// Persistencia. Todas las funciones de escritura se llaman SOLO después de
// validarFase + validarProgreso: un documento inválido no toca disco, ni
// siquiera con el mkdir del directorio.
// ---------------------------------------------------------------------------

function guardarDoc(stateDir: string, fase: string, doc: ProgresoDoc): void {
  mkdirSync(join(stateDir, "progress"), { recursive: true });
  writeFileSync(rutaDocFase(stateDir, fase), `${JSON.stringify(doc, null, 2)}\n`, "utf8");
}

function guardarDocCorrida(stateDir: string, corrida: string, doc: ProgresoDoc): void {
  mkdirSync(join(stateDir, "progress", "c"), { recursive: true });
  writeFileSync(join(stateDir, "progress", "c", `${corrida}.json`), `${JSON.stringify(doc, null, 2)}\n`, "utf8");
}

function descubrirNav(stateDir: string): { fases: string[]; corridas: string[] } {
  const fases: string[] = [];
  const corridas: string[] = [];
  try {
    for (const name of readdirSync(join(stateDir, "progress"))) {
      if (!name.endsWith(".json")) continue;
      const base = name.slice(0, -5);
      if (validarFase(base)) fases.push(base);
    }
  } catch {}
  try {
    for (const name of readdirSync(join(stateDir, "progress", "c"))) {
      if (!name.endsWith(".json")) continue;
      const base = name.slice(0, -5);
      if (validarCorrida(base)) corridas.push(base);
    }
  } catch {}
  return { fases, corridas };
}

function extrasHtml(plan: PlanCruce | undefined, corridas: string[], clave: ClaveTablero): string {
  let extra = "";
  if (plan !== undefined) {
    extra += `<p class="plan">${esc(plan.rotulo)}</p>`;
    if (plan.kind === "cruzado") {
      for (const [id, item] of Object.entries(plan.items)) {
        if (item.discrepa) extra += `<span class="plan-disc">discrepancia: ${esc(id)}</span>`;
      }
    }
  }
  const otras = corridas.filter((c) => !(clave.kind === "corrida" && clave.id === c));
  if (otras.length > 0) {
    extra += `<nav class="corridas">${otras
      .map((c) => `<a href="/runbook/tablero/c/${encodeURIComponent(c)}">${esc(c)}</a>`)
      .join("")}</nav>`;
  }
  return extra;
}

function leerEventosJsonl(ruta: string): Evento[] {
  let crudo: string;
  try {
    crudo = readFileSync(ruta, "utf8");
  } catch {
    return [];
  }
  const eventos: Evento[] = [];
  for (const linea of crudo.split("\n")) {
    if (!linea.trim()) continue;
    try {
      eventos.push(JSON.parse(linea) as Evento);
    } catch {
      // línea corrupta de una corrida anterior: se salta, no se pierde el resto
    }
  }
  return eventos;
}

/**
 * Append al jsonl de la fase con la rotación de observer.ts: si la línea nueva
 * cruzaría el tope de bytes, el archivo vivo se renombra a `<fase>.jsonl.1.jsonl`
 * (nombre FIJO, se sobrescribe) y se arranca uno nuevo. Un solo nivel; tope
 * real 2 x EVENTOS_JSONL_MAX_BYTES. El delta deduplica contra lo ya
 * persistido (clave at+carril+que): reenviar el mismo documento no duplica líneas.
 */
function agregarEventos(stateDir: string, fase: string, eventos: Evento[]): { lineas: number } {
  const ruta = rutaEventos(stateDir, fase);
  const previos = leerEventosJsonl(ruta);
  // El jsonl de disco guarda TODOS (spec, regla 4): el tope EVENTOS_TOPE
  // es solo para la vista en memoria de fusionarEventos. El delta se
  // calcula contra previos sin topar, deduplicando por clave at+carril+que.
  const vistos = new Set(previos.map((e) => `${e?.at ?? ""}\u0000${e?.carril ?? ""}\u0000${e?.que ?? ""}`));
  const porEscribir: Evento[] = [];
  for (const e of Array.isArray(eventos) ? eventos : []) {
    const clave = `${e?.at ?? ""}\u0000${e?.carril ?? ""}\u0000${e?.que ?? ""}`;
    if (vistos.has(clave)) continue;
    vistos.add(clave);
    porEscribir.push(e);
  }
  if (porEscribir.length === 0) return { lineas: 0 };

  mkdirSync(join(stateDir, "events"), { recursive: true });
  let bytesAntes = 0;
  try {
    bytesAntes = statSync(ruta).size;
  } catch {
    bytesAntes = 0;
  }
  for (const e of porEscribir) {
    const linea = `${JSON.stringify(e)}\n`;
    if (bytesAntes > 0 && bytesAntes + Buffer.byteLength(linea, "utf8") > EVENTOS_JSONL_MAX_BYTES) {
      renameSync(ruta, `${ruta}.1.jsonl`);
      bytesAntes = 0;
    }
    appendFileSync(ruta, linea, "utf8");
    bytesAntes += Buffer.byteLength(linea, "utf8");
  }
  return { lineas: porEscribir.length };
}

// ---------------------------------------------------------------------------
// Handlers compartidos por RPC y rutas.
// ---------------------------------------------------------------------------

type Logger = {
  debug?: (message: string) => void;
  info: (message: string) => void;
  warn: (message: string) => void;
  error: (message: string) => void;
};

type RespuestaSet =
  | { ok: true }
  | { ok: false; razones: string[] }
  | { ok: false; razon: "disco" };

function manejarSet(log: Logger, cfg: Config, params: unknown): RespuestaSet {
  const p = params !== null && typeof params === "object" ? (params as Record<string, unknown>) : {};
  // El canary envía el documento COMO params (--params @fixture.json); se acepta
  // también {doc: {...}} para llamadas programáticas.
  const doc =
    p["schema"] === undefined && p["doc"] !== null && typeof p["doc"] === "object"
      ? (p["doc"] as unknown)
      : params;

  // DoD literal: fase por validarFase ANTES de tocar disco. validarProgreso ya
  // la valida por dentro y devuelve TODAS las razones juntas (el lead corrige
  // en una pasada); el chequeo explícito de abajo solo sella la garantía.
  const fase = (doc as { fase?: unknown } | null)?.fase;
  const veredicto = validarProgreso(doc);
  if (!veredicto.ok || !validarFase(fase)) {
    const razones = [...veredicto.razones];
    if (!validarFase(fase) && !razones.some((r) => /fase/.test(r))) {
      razones.push("fase: no casa ^[0-9]{1,3}(\\.[0-9]{1,3})?$ — es clave de disco y de URL");
    }
    return { ok: false, razones };
  }

  try {
    guardarDoc(cfg.stateDir, fase, doc as ProgresoDoc);
    const corrida = (doc as ProgresoDoc).corrida;
    if (validarCorrida(corrida)) {
      guardarDocCorrida(cfg.stateDir, corrida, doc as ProgresoDoc);
    }
    agregarEventos(cfg.stateDir, fase, (doc as ProgresoDoc).eventos ?? []);
  } catch (err) {
    const ctor = err !== null && typeof err === "object" ? (err as { constructor?: { name?: unknown } }).constructor : undefined;
    const nombre = typeof ctor?.name === "string" && ctor.name ? ctor.name : "Error";
    log.warn(`tablero-runbook: fallo de disco al persistir progreso (${nombre})`);
    return { ok: false, razon: "disco" };
  }
  // Live bus (opcional): avisa al BFF sin bloquear ni tumbar el set.
  syncProgress(fase);
  return { ok: true };
}

type RespuestaTablero =
  | { ok: true; doc: ProgresoDoc; derivado: ReturnType<typeof derivar>; html: string; plan?: PlanCruce }
  | { ok: false; razon: "desconocida" | "disco" };

async function armarTablero(
  cfg: Config,
  cfgGithub: ReturnType<typeof leerGithubConfig>,
  clave: ClaveTablero,
): Promise<RespuestaTablero> {
  let crudo: string;
  try {
    crudo = readFileSync(rutaDoc(cfg.stateDir, clave), "utf8");
  } catch {
    return { ok: false, razon: "desconocida" };
  }
  let doc: ProgresoDoc;
  try {
    doc = JSON.parse(crudo) as ProgresoDoc;
  } catch {
    return { ok: false, razon: "desconocida" };
  }
  const derivado = derivar(doc);
  const docOk = validarProgreso(doc).ok;
  // 7.5: el cruce con GitHub corre solo tras validarProgreso y solo con
  // github.enabled. Apagado, no se ejecuta nada y el render rotula
  // "GitHub: sin verificar".
  const github: GithubCruce | undefined =
    cfgGithub.enabled && docOk
      ? await cruzarGitHub(doc, cfgGithub)
      : undefined;
  let plan: PlanCruce | undefined;
  if (doc.plan !== undefined && docOk) {
    try {
      plan = await cruzarPlan(doc, { ghPath: cfgGithub.ghPath });
    } catch {
      plan = { kind: "sin-verificar", rotulo: "plan: sin verificar" };
    }
  }
  const nav = descubrirNav(cfg.stateDir);
  let html = renderTablero(doc, derivado, github, nav.fases);
  const extra = extrasHtml(plan, nav.corridas, clave);
  if (extra) html = html.replace("</main>", `${extra}</main>`);
  return { ok: true, doc, derivado, html, plan };
}

const HEADERS_HTML = {
  "Content-Type": "text/html; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
} as const;
const HEADERS_JSON = {
  "Content-Type": "application/json",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
} as const;

/**
 * Parte por "/" ANTES de decodificar. Un `%2f` no puede saltar de segmento y
 * convertirse en una ruta de disco; `..` y mayúsculas mueren en validarFase
 * o validarCorrida, nunca en join().
 */
function formaCorridaEnUrl(url: string | undefined): boolean {
  const limpio = (url ?? "").split("?")[0]?.split("#")[0] ?? "";
  const segs = limpio.split("/").filter(Boolean);
  return segs.length >= 4 && segs[2] === "c";
}

function claveDeUrl(url: string | undefined): ClaveTablero | undefined {
  const limpio = (url ?? "").split("?")[0]?.split("#")[0] ?? "";
  const segs = limpio.split("/").filter(Boolean);
  if (segs.length === 3) {
    let crudo: string;
    try {
      crudo = decodeURIComponent(segs[2] ?? "");
    } catch {
      return undefined;
    }
    if (crudo.endsWith(".json")) crudo = crudo.slice(0, -5);
    return validarFase(crudo) ? { kind: "fase", id: crudo } : undefined;
  }
  if (segs.length === 4 && segs[2] === "c") {
    let crudo: string;
    try {
      crudo = decodeURIComponent(segs[3] ?? "");
    } catch {
      return undefined;
    }
    if (crudo.endsWith(".json")) crudo = crudo.slice(0, -5);
    return validarCorrida(crudo) ? { kind: "corrida", id: crudo } : undefined;
  }
  return undefined;
}

type ReqLike = { method?: string; url?: string };
type ResLike = {
  writeHead: (status: number, headers: Record<string, string>) => void;
  end: (chunk?: string) => void;
};

function servirTablero(
  log: Logger,
  cfg: Config,
  cfgGithub: ReturnType<typeof leerGithubConfig>,
  req: ReqLike,
  res: ResLike,
): Promise<void> {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { "Content-Type": "text/plain; charset=utf-8", Allow: "GET" });
    res.end("solo GET");
    return Promise.resolve();
  }
  const clave = claveDeUrl(req.url);
  if (clave === undefined) {
    res.writeHead(400, HEADERS_HTML);
    res.end(
      formaCorridaEnUrl(req.url)
        ? "<!doctype html><p>corrida inválida: debe casar ^[a-z0-9][a-z0-9-]{0,40}$</p>"
        : "<!doctype html><p>fase inválida: debe casar ^[0-9]{1,3}(\\.[0-9]{1,3})?$</p>",
    );
    return Promise.resolve();
  }
  return armarTablero(cfg, cfgGithub, clave).then((respuesta) => {
    if (!respuesta.ok) {
      const status = respuesta.razon === "disco" ? 500 : 404;
      res.writeHead(status, HEADERS_HTML);
      if (clave.kind === "corrida") {
        res.end(
          `<!doctype html><p>corrida ${esc(clave.id)}: sin documento. Escribila con runbook.progress.set incluyendo el campo corrida.</p>`,
        );
        return;
      }
      res.end(`<!doctype html><p>fase ${clave.id}: ${respuesta.razon === "disco" ? "fallo de disco" : "sin documento"}</p>`);
      return;
    }
    res.writeHead(200, HEADERS_HTML);
    res.end(respuesta.html);
  });
}

function servirJson(
  cfg: Config,
  cfgGithub: ReturnType<typeof leerGithubConfig>,
  req: ReqLike,
  res: ResLike,
): Promise<void> {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { "Content-Type": "text/plain; charset=utf-8", Allow: "GET" });
    res.end("solo GET");
    return Promise.resolve();
  }
  const clave = claveDeUrl(req.url);
  if (clave === undefined) {
    res.writeHead(400, HEADERS_JSON);
    res.end(JSON.stringify({
      ok: false,
      razon: formaCorridaEnUrl(req.url) ? "corrida inválida" : "fase inválida",
    }));
    return Promise.resolve();
  }
  return armarTablero(cfg, cfgGithub, clave).then((respuesta) => {
    // Regla 8 del spec: get y la ruta .json exponen el documento completo
    // (residuales y eventos incluidos) a quien pase la auth del gateway.
    if (!respuesta.ok) {
      res.writeHead(respuesta.razon === "disco" ? 500 : 404, HEADERS_JSON);
      if (clave.kind === "corrida") {
        res.end(JSON.stringify({
          ok: false,
          razon: respuesta.razon,
          como: "runbook.progress.set con campo corrida",
        }));
        return;
      }
      res.end(JSON.stringify({ ok: false, razon: respuesta.razon }));
      return;
    }
    res.writeHead(200, HEADERS_JSON);
    res.end(JSON.stringify(respuesta.doc));
  });
}

// ---------------------------------------------------------------------------
// Reloj de seguimiento (Task 3): `runbook.progress.decide` es la única entrada
// que AGENTS.md nombra. El reloj puro vive en seguimiento-clock.ts; aquí solo
// se angosta el insumo `unknown`, se pone la hora y se cargan los resúmenes
// activos. Este RPC no envía nada ni escribe el scratch.
// ---------------------------------------------------------------------------

let relojInyectado: (() => number) | undefined;

/** Solo tests: fija la hora que `runbook.progress.decide` ve como `ahora`. */
export function _setRelojSeguimientoForTest(fn: (() => number) | undefined): void {
  relojInyectado = fn;
}

function ahoraSeguimiento(): number {
  const ms = relojInyectado?.() ?? Date.now();
  return Math.floor(ms / 1000);
}

function esObjetoParams(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function parseInmediato(v: unknown): EventoInmediato | null {
  if (v === undefined || v === null) return null;
  if (!esObjetoParams(v)) throw new Error("evento-invalido");
  const tipo = v["tipo"];
  if (tipo !== "NECESITO TU RESPUESTA" && tipo !== "DETENIDA" && tipo !== "CERRADA") {
    throw new Error("evento-invalido");
  }
  const texto = v["texto"];
  if (typeof texto !== "string" || texto.length === 0 || texto.length > 2000) {
    throw new Error("evento-invalido");
  }
  return { tipo, texto };
}

function parseConteo(v: unknown): ConteoObjetivo {
  if (!esObjetoParams(v)) throw new Error("evento-invalido");
  if (v["kind"] === "conocido") {
    const completadas = v["completadas"];
    const total = v["total"];
    const porcentaje = v["porcentaje"];
    // Conteos imposibles fuera: enteros, 0 <= completadas <= total,
    // porcentaje entero 0-100 igual al redondeo del sistema (0/0 solo 0%).
    if (typeof completadas !== "number" || !Number.isInteger(completadas)
      || typeof total !== "number" || !Number.isInteger(total)
      || typeof porcentaje !== "number" || !Number.isInteger(porcentaje)) {
      throw new Error("evento-invalido");
    }
    if (total < 0 || completadas < 0 || completadas > total) {
      throw new Error("evento-invalido");
    }
    if (porcentaje < 0 || porcentaje > 100) throw new Error("evento-invalido");
    const esperado = total === 0 ? 0 : Math.round((100 * completadas) / total);
    if (total === 0 ? completadas !== 0 || porcentaje !== 0 : porcentaje !== esperado) {
      throw new Error("evento-invalido");
    }
    return { kind: "conocido", completadas, total, porcentaje };
  }
  if (v["kind"] === "desconocido") {
    const motivo = v["motivo"];
    if (motivo !== "plan-sin-verificar" && motivo !== "unidad-desconocida") {
      throw new Error("evento-invalido");
    }
    return { kind: "desconocido", motivo };
  }
  throw new Error("evento-invalido");
}

function parseSueltas(v: unknown): TareaSuelta[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v)) throw new Error("evento-invalido");
  const sueltas: TareaSuelta[] = [];
  for (const e of v) {
    if (!esObjetoParams(e)) throw new Error("evento-invalido");
    const nombre = e["nombre"];
    if (typeof nombre !== "string" || nombre.length === 0) {
      throw new Error("evento-invalido");
    }
    const progreso = parseConteo(e["progreso"]);
    const a = e["actividad"];
    if (!esObjetoParams(a)) throw new Error("evento-invalido");
    const detalle = a["detalle"];
    const iniciadaEn = a["iniciadaEn"];
    const ultimaEvidencia = a["ultimaEvidencia"];
    if (typeof detalle !== "string" || typeof iniciadaEn !== "string" || typeof ultimaEvidencia !== "string") {
      throw new Error("evento-invalido");
    }
    if (Number.isNaN(Date.parse(iniciadaEn))) throw new Error("evento-invalido");
    sueltas.push({ nombre, progreso, actividad: { detalle, iniciadaEn, ultimaEvidencia } });
  }
  return sueltas;
}

type RespuestaDecide =
  | { ok: false; razon: "estado-invalido" | "evento-invalido" }
  | ReturnType<typeof decidirSeguimiento>;

async function manejarDecide(
  cfg: Config,
  cfgGithub: ReturnType<typeof leerGithubConfig>,
  params: unknown,
): Promise<RespuestaDecide> {
  if (!esObjetoParams(params)) return { ok: false, razon: "evento-invalido" };
  const modo = params["modo"];
  if (modo !== "iniciar" && modo !== "tick") return { ok: false, razon: "evento-invalido" };
  let inmediato: EventoInmediato | null;
  let sueltas: TareaSuelta[];
  try {
    inmediato = parseInmediato(params["inmediato"]);
    sueltas = parseSueltas(params["tareasSueltas"]);
  } catch {
    return { ok: false, razon: "evento-invalido" };
  }
  const ahora = ahoraSeguimiento();
  const lista = await listarSeguimientoActivo(cfg, cfgGithub);
  if (modo === "iniciar") {
    // Solo "iniciar" crea estado, y exige estado:null explícito: crear sobre
    // un estado existente reiniciaría el corte en silencio. La creación
    // siempre devuelve el estado inicial en NO_REPLY para persistirlo de
    // inmediato; lo pendiente (incluida corrupción o atención) sale en el
    // primer tick, nunca en la creación.
    if (params["estado"] !== null) return { ok: false, razon: "estado-invalido" };
    return {
      accion: "NO_REPLY",
      estado: crearEstadoInicial(ahora, lista.activas),
    };
  }
  let previo: EstadoSeguimiento;
  try {
    previo = parseEstadoSeguimiento(params["estado"]);
  } catch {
    return { ok: false, razon: "estado-invalido" };
  }
  return decidirSeguimiento({
    ahora,
    previo,
    activas: lista.activas,
    sueltas,
    inmediato,
    problemas: lista.problemas,
  });
}

// ---------------------------------------------------------------------------
// Plugin entry.
// ---------------------------------------------------------------------------

export default definePluginEntry({
  id: "tablero-runbook",
  name: "Tablero de Runbook",
  description:
    "Guarda y pinta el progreso runbook-progress.v1 que el lead escribe: RPC set/get, tablero HTML y JSON por ruta autenticada del gateway. Sin hooks de agente ni tools.",
  register(api) {
    const log: Logger = api.logger;
    const cfg = leerConfig((api as { pluginConfig?: unknown }).pluginConfig);
    const cfgGithub = leerGithubConfig((api as { pluginConfig?: unknown }).pluginConfig);

    // -- RPC ---------------------------------------------------------------
    api.registerGatewayMethod(
      "runbook.progress.set",
      ({ params, respond }) => {
        respond(true, manejarSet(log, cfg, params));
      },
      { scope: "operator.write" },
    );

    api.registerGatewayMethod(
      "runbook.progress.get",
      async ({ params, respond }) => {
        const p = params !== null && typeof params === "object" ? (params as Record<string, unknown>) : {};
        const fase = p["fase"];
        const corrida = p["corrida"];
        let clave: ClaveTablero | undefined;
        if (validarFase(fase)) {
          clave = { kind: "fase", id: fase };
        } else if (fase !== undefined) {
          respond(true, { ok: false, razon: "fase inválida" });
          return;
        } else if (validarCorrida(corrida)) {
          clave = { kind: "corrida", id: corrida };
        } else if (corrida !== undefined) {
          respond(true, { ok: false, razon: "corrida inválida" });
          return;
        } else {
          respond(true, { ok: false, razon: "fase inválida" });
          return;
        }
        const respuesta = await armarTablero(cfg, cfgGithub, clave);
        if (!respuesta.ok) {
          respond(true, { ok: false, razon: respuesta.razon });
          return;
        }
        const payload: Record<string, unknown> = {
          ok: true,
          doc: respuesta.doc,
          derivado: respuesta.derivado,
          html: respuesta.html,
        };
        if (respuesta.plan !== undefined) payload["plan"] = respuesta.plan;
        respond(true, payload);
      },
      { scope: "operator.read" },
    );

    api.registerGatewayMethod(
      "runbook.progress.list",
      async ({ respond }) => {
        respond(true, await listarSeguimientoActivo(cfg, cfgGithub));
      },
      { scope: "operator.read" },
    );

    api.registerGatewayMethod(
      "runbook.progress.decide",
      async ({ params, respond }) => {
        respond(true, await manejarDecide(cfg, cfgGithub, params));
      },
      { scope: "operator.read" },
    );

    // -- Rutas HTTP (auth gateway: el host las protege; sin credencial el    //    handler no corre) ---------------------------------------------------
    api.registerHttpRoute({
      path: "/runbook/tablero",
      match: "prefix",
      auth: "gateway",
      handler: (req, res) => {
        return servirTablero(log, cfg, cfgGithub, req, res).catch((err: unknown) => {
          const ctor = err !== null && typeof err === "object" ? (err as { constructor?: { name?: unknown } }).constructor : undefined;
          log.warn(`tablero-runbook: fallo sirviendo el tablero (${typeof ctor?.name === "string" ? ctor.name : "Error"})`);
          res.writeHead(500, HEADERS_HTML);
          res.end("<!doctype html><p>error interno</p>");
        });
      },
    });

    api.registerHttpRoute({
      path: "/runbook/progress",
      match: "prefix",
      auth: "gateway",
      handler: (req, res) => {
        return servirJson(cfg, cfgGithub, req, res).catch((err: unknown) => {
          const ctor = err !== null && typeof err === "object" ? (err as { constructor?: { name?: unknown } }).constructor : undefined;
          log.warn(`tablero-runbook: fallo sirviendo el json (${typeof ctor?.name === "string" ? ctor.name : "Error"})`);
          res.writeHead(500, HEADERS_JSON);
          res.end(JSON.stringify({ ok: false, razon: "disco" }));
        });
      },
    });

    // -- Pestaña de la Control UI (confirmada PRESENTE por el spike 7.0) -----
    api.session.controls.registerControlUiDescriptor({
      surface: "tab",
      id: "runbook",
      label: "Runbook",
      path: "/runbook/tablero/6",
      group: "control",
      requiredScopes: ["operator.read"],
    });

    log.info(`tablero-runbook: plugin registrado (stateDir=${cfg.stateDir}, fases=${cfg.fases.join(",")})`);
  },
});

import { execFile } from "node:child_process";

import { PLAN_RUTA_MAX, REPO_RE, type ProgresoDoc } from "./lib.ts";

export type EstadoPlan = "pendiente" | "implementando" | "mergeado" | "unknown";

export type PlanItem = {
  estado: EstadoPlan;
  marcador: string;
  discrepa: boolean;
};

export type PlanCruce =
  | { kind: "nulo"; rotulo: "plan: no declarado" }
  | { kind: "sin-verificar"; rotulo: "plan: sin verificar" }
  | { kind: "ruta-no-encontrada"; rotulo: "plan: ruta no encontrada" }
  | {
      kind: "cruzado";
      rotulo: "plan";
      items: Record<string, PlanItem>;
    };

export const PLAN_PRESUPUESTO_MS = 8_000;
export const PLAN_CACHE_MS = 60_000;
export const PLAN_CONCURRENCIA = 4;

const SIN_VERIFICAR: PlanCruce = { kind: "sin-verificar", rotulo: "plan: sin verificar" };
const RUTA_NO_ENCONTRADA: PlanCruce = { kind: "ruta-no-encontrada", rotulo: "plan: ruta no encontrada" };
const NULO: PlanCruce = { kind: "nulo", rotulo: "plan: no declarado" };

const MARCA_A_ESTADO: Record<string, EstadoPlan> = {
  "cc:TODO": "pendiente",
  "cc:WIP": "implementando",
  "cc:完了": "mergeado",
  "cc:DONE": "mergeado",
};

const COLA_A_PLAN: Record<string, EstadoPlan> = {
  pendiente: "pendiente",
  "esperando-ventana": "pendiente",
  mergeando: "implementando",
  sync: "implementando",
  verificado: "mergeado",
};

const CARRIL_A_PLAN: Record<string, EstadoPlan> = {
  pendiente: "pendiente",
  implementando: "implementando",
  "revision-cruzada": "implementando",
  coderabbit: "implementando",
  "auditoria-lead": "implementando",
  "en-cola": "implementando",
  mergeado: "mergeado",
};

type ExecFileLike = (
  cmd: string,
  args: readonly string[],
  opts: Record<string, unknown>,
  cb: (err: Error | null, stdout: string) => void,
) => { kill: (signal?: string) => void };

let execInyectado: ExecFileLike | undefined;

export function _setPlanExecForTest(fn: ExecFileLike | undefined): void {
  execInyectado = fn;
}

let cache = new Map<string, { at: number; valor: PlanCruce }>();

export function _resetPlanCacheForTest(): void {
  cache = new Map();
}

export function estadoDeMarcador(marcador: string): EstadoPlan {
  return MARCA_A_ESTADO[marcador] ?? "unknown";
}

const FILA_RE = /^\|\s*([A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*)\s*\|/;
const MARCADOR_RE = /cc:TODO|cc:WIP|cc:完了|cc:DONE|cc:\S+/g;
const HEADING_RE = /^(#{1,6})\s+(.+)$/;

export function extraerItems(
  md: string,
  seccion: string | null,
): Record<string, { estado: EstadoPlan; marcador: string }> {
  const lineas = md.split(/\r?\n/);
  let start = 0;
  let end = lineas.length;
  if (seccion !== null) {
    let nivel = 0;
    let hallada = false;
    for (let i = 0; i < lineas.length; i++) {
      const h = HEADING_RE.exec(lineas[i] ?? "");
      if (!h) continue;
      const lev = (h[1] ?? "").length;
      const texto = (h[2] ?? "").trim();
      if (!hallada && texto.includes(seccion)) {
        hallada = true;
        start = i + 1;
        nivel = lev;
        continue;
      }
      if (hallada && lev <= nivel) {
        end = i;
        break;
      }
    }
    if (!hallada) return {};
  }
  const items: Record<string, { estado: EstadoPlan; marcador: string }> = {};
  for (const linea of lineas.slice(start, end)) {
    const fila = FILA_RE.exec(linea);
    if (!fila) continue;
    const marcas = linea.match(MARCADOR_RE);
    if (!marcas || marcas.length === 0) continue;
    const marcador = marcas[marcas.length - 1] ?? "";
    const id = fila[1];
    if (id === undefined) continue;
    items[id] = { estado: estadoDeMarcador(marcador), marcador };
  }
  return items;
}

function rutaPlanOk(v: string): boolean {
  if (v.length === 0 || v.length > PLAN_RUTA_MAX) return false;
  if (v.startsWith("/") || v.startsWith("\\") || /^[A-Za-z]:/.test(v)) return false;
  return !v.split(/[/\\]/).some((seg) => seg === "..");
}

function es404(err: Error | null): boolean {
  if (!err) return false;
  const extra = err as Error & { status?: unknown; code?: unknown };
  if (extra.status === 404 || extra.code === 404) return true;
  return /Not Found/i.test(err.message);
}

function textoDeArchivo(json: unknown): string | undefined {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return undefined;
  const o = json as Record<string, unknown>;
  if (o["type"] !== "file") return undefined;
  if (o["encoding"] !== "base64" || typeof o["content"] !== "string") return undefined;
  try {
    return Buffer.from(o["content"].replace(/\s+/g, ""), "base64").toString("utf8");
  } catch {
    return undefined;
  }
}

function leadDeItem(doc: ProgresoDoc, itemId: string): EstadoPlan | undefined {
  const cola = (Array.isArray(doc.cola) ? doc.cola : []).find((q) => q?.id === itemId);
  if (cola) return COLA_A_PLAN[cola.estado] ?? "unknown";
  const carril = (Array.isArray(doc.carriles) ? doc.carriles : []).find(
    (c) => Array.isArray(c?.tareas) && c.tareas.includes(itemId),
  );
  if (carril) return CARRIL_A_PLAN[carril.estado] ?? "unknown";
  return undefined;
}

function conDiscrepa(
  extraidos: Record<string, { estado: EstadoPlan; marcador: string }>,
  doc: ProgresoDoc,
): Record<string, PlanItem> {
  const items: Record<string, PlanItem> = {};
  for (const [id, raw] of Object.entries(extraidos)) {
    const lead = leadDeItem(doc, id);
    items[id] = {
      estado: raw.estado,
      marcador: raw.marcador,
      discrepa: lead !== undefined && lead !== raw.estado,
    };
  }
  return items;
}

type GhRes = { kind: "ok"; stdout: string } | { kind: "404" } | { kind: "error" };

function consultar(
  exec: ExecFileLike,
  ghPath: string,
  repo: string,
  rutaApi: string,
  timeout: number,
  vivos: Set<{ kill: (signal?: string) => void }>,
): Promise<GhRes> {
  return new Promise((resolver) => {
    if (timeout <= 0) {
      resolver({ kind: "error" });
      return;
    }
    const args = ["api", "repos/" + repo + "/contents/" + rutaApi];
    let child: { kill: (signal?: string) => void };
    try {
      child = exec(
        ghPath,
        args,
        { shell: false, timeout: Math.max(200, timeout), killSignal: "SIGKILL", windowsHide: true },
        (err, stdout) => {
          vivos.delete(child);
          if (err) {
            resolver(es404(err) ? { kind: "404" } : { kind: "error" });
            return;
          }
          resolver({ kind: "ok", stdout: typeof stdout === "string" ? stdout : "" });
        },
      );
      vivos.add(child);
    } catch {
      resolver({ kind: "error" });
    }
  });
}

async function leerMarkdown(
  exec: ExecFileLike,
  ghPath: string,
  repo: string,
  rutaApi: string,
  deadline: number,
  vivos: Set<{ kill: (signal?: string) => void }>,
): Promise<{ kind: "texto"; md: string } | { kind: "404" } | { kind: "error" }> {
  const primero = await consultar(exec, ghPath, repo, rutaApi, deadline - Date.now(), vivos);
  if (primero.kind !== "ok") return primero;

  let parsed: unknown;
  try {
    parsed = JSON.parse(primero.stdout);
  } catch {
    return { kind: "error" };
  }

  const archivo = textoDeArchivo(parsed);
  if (archivo !== undefined) return { kind: "texto", md: archivo };

  if (!Array.isArray(parsed)) return { kind: "error" };

  const files: string[] = [];
  for (const entry of parsed) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) continue;
    const o = entry as Record<string, unknown>;
    if (o["type"] !== "file" || typeof o["path"] !== "string") continue;
    if (!rutaPlanOk(o["path"])) continue;
    files.push(o["path"]);
  }

  const partes: string[] = [];
  for (let i = 0; i < files.length; i += PLAN_CONCURRENCIA) {
    if (Date.now() >= deadline) return { kind: "error" };
    const tanda = files.slice(i, i + PLAN_CONCURRENCIA);
    const resultados = await Promise.all(
      tanda.map((p) => consultar(exec, ghPath, repo, p, deadline - Date.now(), vivos)),
    );
    for (const r of resultados) {
      if (r.kind !== "ok") return { kind: "error" };
      let j: unknown;
      try {
        j = JSON.parse(r.stdout);
      } catch {
        return { kind: "error" };
      }
      const texto = textoDeArchivo(j);
      if (texto === undefined) return { kind: "error" };
      partes.push(texto);
    }
  }
  return { kind: "texto", md: partes.join("\n") };
}

export async function cruzarPlan(
  doc: ProgresoDoc,
  cfg: { ghPath: string },
  tiempos?: { presupuesto?: number; cache?: number },
): Promise<PlanCruce | undefined> {
  if (doc.plan === undefined) return undefined;
  if (doc.plan === null) return NULO;

  const repo = doc.plan.repo;
  const ruta = doc.plan.ruta;
  const seccion = doc.plan.seccion;
  if (typeof repo !== "string" || !REPO_RE.test(repo) || typeof ruta !== "string" || !rutaPlanOk(ruta)) {
    return SIN_VERIFICAR;
  }
  if (!cfg.ghPath.endsWith(".exe")) return SIN_VERIFICAR;

  const presupuesto = tiempos?.presupuesto ?? PLAN_PRESUPUESTO_MS;
  const cacheMs = tiempos?.cache ?? PLAN_CACHE_MS;
  const clave = `${cfg.ghPath}|${repo}|${ruta}`;
  const memo = cache.get(clave);
  const ahora = Date.now();
  if (memo !== undefined && ahora - memo.at < cacheMs) return memo.valor;

  const exec = execInyectado ?? (execFile as unknown as ExecFileLike);
  const vivos = new Set<{ kill: (signal?: string) => void }>();
  const verdugo = setTimeout(() => {
    for (const child of vivos) {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
  }, presupuesto);
  verdugo.unref?.();

  const tope = new Promise<PlanCruce>((resolve) => {
    const t = setTimeout(() => resolve(SIN_VERIFICAR), presupuesto);
    t.unref?.();
  });

  const trabajo = (async (): Promise<PlanCruce> => {
    const leido = await leerMarkdown(
      exec,
      cfg.ghPath,
      repo,
      ruta.replace(/\/$/, ""),
      ahora + presupuesto,
      vivos,
    );
    if (leido.kind === "404") return RUTA_NO_ENCONTRADA;
    if (leido.kind === "error") return SIN_VERIFICAR;
    return {
      kind: "cruzado",
      rotulo: "plan",
      items: conDiscrepa(extraerItems(leido.md, seccion ?? null), doc),
    };
  })();

  let resultado: PlanCruce;
  try {
    resultado = await Promise.race([trabajo, tope]);
  } catch {
    resultado = SIN_VERIFICAR;
  }
  clearTimeout(verdugo);
  cache.set(clave, { at: Date.now(), valor: resultado });
  return resultado;
}

/**
 * proyeccion.ts — espejo JS del schema `sistema-agentes.proyeccion.v1`
 * (scripts/sistema_agentes/contrato.py:413-441, _FECHA:110, prohibidos:78-108).
 * contrato.py es la fuente de verdad; este espejo se actualiza en el mismo PR
 * que el Python. Recolecta TODAS las razones (convención del repo).
 */
export const PROYECCION_LITERAL = "sistema-agentes.proyeccion.v1";

/** Espejo de _FECHA con fullmatch; los rangos (mes 13, día 32) los mata Date.parse. */
export const FECHA_Z_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

export type ProyeccionUnit = {
  unitId: string;
  state: string;
  host: string;
  executor: string;
  modelId: string | null;
  nextCheckAt: string;
  error: string | null;
};

export type ProyeccionDoc = {
  schema: string;
  rootId: string;
  planRevision: number;
  controlEpoch: number;
  generatedAt: string;
  progress: { declared: number | null; observed: number | null; accepted: number | null };
  units: ProyeccionUnit[];
  freshness: { staleAfterMs: number };
};

const CAMPOS_RAIZ = [
  "schema",
  "rootId",
  "planRevision",
  "controlEpoch",
  "generatedAt",
  "progress",
  "units",
  "freshness",
] as const;
const CAMPOS_PROGRESS = ["declared", "observed", "accepted"] as const;
const CAMPOS_UNIT = [
  "unitId",
  "state",
  "host",
  "executor",
  "modelId",
  "nextCheckAt",
  "error",
] as const;

const NOMBRES_PROHIBIDOS = new Set(
  [
    "key",
    "token",
    "secret",
    "session",
    "signature",
    "credential",
    "authorization",
    "cookie",
    "jwt",
    "password",
    "passwd",
    "apikey",
    "idtoken",
    "accesstoken",
    "authtoken",
    "clientsecret",
    "privatekey",
    "keymaterial",
    "refreshtoken",
    "bearertoken",
    "appsecret",
    "secretvalue",
    "rawsecret",
    "secretinput",
    "apitoken",
  ],
);
const SUFIJO_PROHIBIDO_RE = /[_-](?:key|token|secret|password|passwd)$/i;

function esFechaZ(v: unknown): boolean {
  return typeof v === "string" && FECHA_Z_RE.test(v) && Number.isFinite(Date.parse(v));
}

function esEntero(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v);
}

const ruta = (donde: string, nombre: string): string => (donde === "" ? nombre : `${donde}.${nombre}`);

/** Objeto cerrado estilo _forma_de_objeto: extras y faltantes con su ruta. */
function objetoCerrado(
  v: unknown,
  campos: readonly string[],
  donde: string,
  razones: string[],
): Record<string, unknown> | null {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    razones.push(`${donde}: se esperaba objeto`);
    return null;
  }
  const o = v as Record<string, unknown>;
  for (const nombre of Object.keys(o)) {
    if (!campos.includes(nombre)) razones.push(`campo fuera de la tabla: ${ruta(donde, nombre)}`);
  }
  for (const nombre of campos) {
    if (!(nombre in o)) razones.push(`falta el campo: ${ruta(donde, nombre)}`);
  }
  return o;
}

/** Espejo de _campos_prohibidos: nombres y sufijos, recursivo por objetos y listas. */
function camposProhibidos(valor: unknown, donde: string, razones: string[]): void {
  if (Array.isArray(valor)) {
    valor.forEach((hijo, i) => camposProhibidos(hijo, `${donde}[${i}]`, razones));
    return;
  }
  if (valor === null || typeof valor !== "object") return;
  for (const [nombre, hijo] of Object.entries(valor as Record<string, unknown>)) {
    const hijoRuta = ruta(donde, nombre);
    if (NOMBRES_PROHIBIDOS.has(nombre.toLowerCase()) || SUFIJO_PROHIBIDO_RE.test(nombre)) {
      razones.push(`campo-prohibido: ${hijoRuta}`);
    }
    camposProhibidos(hijo, hijoRuta, razones);
  }
}

export function validarProyeccion(doc: unknown): { ok: boolean; razones: string[] } {
  const razones: string[] = [];
  if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
    return { ok: false, razones: ["el documento no es un objeto JSON"] };
  }
  const d = objetoCerrado(doc, CAMPOS_RAIZ, "", razones);
  camposProhibidos(doc, "", razones);
  if (d === null) return { ok: razones.length === 0, razones };

  if (d["schema"] !== PROYECCION_LITERAL) {
    razones.push(`schema: se esperaba literal "${PROYECCION_LITERAL}"`);
  }
  if (typeof d["rootId"] !== "string" || d["rootId"].length === 0) razones.push("rootId: falta o vacío");
  for (const campo of ["planRevision", "controlEpoch"] as const) {
    if (!esEntero(d[campo]) || d[campo] < 1) razones.push(`${campo}: entero >= 1`);
  }
  if (!esFechaZ(d["generatedAt"])) razones.push("generatedAt: no es fecha ISO 8601 en UTC con Z");

  const progress = objetoCerrado(d["progress"], CAMPOS_PROGRESS, "progress", razones);
  if (progress !== null) {
    for (const campo of CAMPOS_PROGRESS) {
      const v = progress[campo];
      if (!(v === null || (esEntero(v) && v >= 0 && v <= 100))) {
        razones.push(`progress.${campo}: entero 0..100 o null`);
      }
    }
  }

  if (!Array.isArray(d["units"])) {
    razones.push("units: se esperaba lista");
  } else {
    (d["units"] as unknown[]).forEach((u, i) => {
      const donde = `units[${i}]`;
      const o = objetoCerrado(u, CAMPOS_UNIT, donde, razones);
      if (o === null) return;
      if (typeof o["unitId"] !== "string" || o["unitId"].length === 0) {
        razones.push(`${donde}.unitId: falta o vacío`);
      }
      for (const campo of ["state", "host", "executor"] as const) {
        if (typeof o[campo] !== "string") razones.push(`${donde}.${campo}: se esperaba texto`);
      }
      if (o["modelId"] !== null && typeof o["modelId"] !== "string") {
        razones.push(`${donde}.modelId: texto o null`);
      }
      if (!esFechaZ(o["nextCheckAt"])) razones.push(`${donde}.nextCheckAt: no es fecha ISO 8601 en UTC con Z`);
      if (o["error"] !== null && typeof o["error"] !== "string") {
        razones.push(`${donde}.error: texto o null`);
      }
    });
  }

  const freshness = objetoCerrado(d["freshness"], ["staleAfterMs"], "freshness", razones);
  // Sin rango: espejo fiel; el derivador exige > 0 del lado del emisor.
  if (freshness !== null && !esEntero(freshness["staleAfterMs"])) {
    razones.push("freshness.staleAfterMs: entero");
  }

  return { ok: razones.length === 0, razones };
}

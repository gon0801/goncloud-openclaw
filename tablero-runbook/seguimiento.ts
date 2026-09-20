/**
 * tablero-runbook/seguimiento.ts — resumen objetivo del trabajo activo.
 *
 * Los porcentajes salen de las unidades del plan que ya consume `plan.ts`,
 * nunca de estimaciones: solo `mergeado` cuenta como terminada. Un carril
 * `omitido` no entra en el denominador de la fase (sus tareas exclusivas se
 * excluyen); un carril `atorado` sí cuenta mientras no se omita. Lo que no se
 * puede verificar (`sin-verificar`, `ruta-no-encontrada`, `nulo`, unidad
 * `unknown` o tarea ausente del cruce) es `desconocido`, nunca 0%.
 *
 * Puro salvo `listarSeguimientoActivo`, que lee el stateDir existente y el
 * cruce acotado de `plan.ts`. No agrega otro directorio de estado. Los valores
 * de disco y RPC entran como `unknown` y se angostan con `validarProgreso`;
 * este módulo no fabrica `ProgresoDoc` ni `PlanCruce` con `as`.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { CORRIDA_RE, validarFase, validarProgreso, type ProgresoDoc } from "./lib.ts";
import { cruzarPlan, type PlanCruce } from "./plan.ts";

export type ConteoObjetivo =
  | { kind: "conocido"; completadas: number; total: number; porcentaje: number }
  | { kind: "desconocido"; motivo: "plan-sin-verificar" | "unidad-desconocida" };

export type ResumenCarril = {
  id: string;
  nombre: string;
  estado: string;
  progreso: ConteoObjetivo;
  actividad: { detalle: string; iniciadaEn: string; ultimaEvidencia: string };
};

export type ResumenSeguimiento = {
  trabajoId: `fase:${string}` | `corrida:${string}`;
  fase: string;
  titulo: string;
  progreso: ConteoObjetivo;
  carriles: ResumenCarril[];
  siguientePaso: string;
  atencionRequerida: { necesaria: boolean; motivo: string | null };
  actualizado: string;
};

const SIN_VERIFICAR: PlanCruce = { kind: "sin-verificar", rotulo: "plan: sin verificar" };

function esProgresoDoc(v: unknown): v is ProgresoDoc {
  return validarProgreso(v).ok;
}

function porcentajeDe(completadas: number, total: number): number {
  return total === 0 ? 0 : Math.round((100 * completadas) / total);
}

/**
 * Cuenta las tareas del carril contra el cruce. Devuelve `desconocido` en
 * cuanto una tarea falta del cruce o su estado es `unknown`: adivinar
 * contamina el porcentaje que David audita con la fracción.
 */
function contarTareas(tareas: string[], items: Record<string, { estado: string }>): ConteoObjetivo {
  let completadas = 0;
  for (const id of tareas) {
    const item = items[id];
    if (item === undefined || item.estado === "unknown") {
      return { kind: "desconocido", motivo: "unidad-desconocida" };
    }
    if (item.estado === "mergeado") completadas += 1;
  }
  return { kind: "conocido", completadas, total: tareas.length, porcentaje: porcentajeDe(completadas, tareas.length) };
}

export function resumirSeguimiento(doc: ProgresoDoc, plan: PlanCruce): ResumenSeguimiento {
  const trabajoId = typeof doc.corrida === "string" && doc.corrida.length > 0
    ? `corrida:${doc.corrida}`
    : `fase:${doc.fase}`;
  const base = {
    trabajoId,
    fase: doc.fase,
    titulo: doc.titulo,
    siguientePaso: doc.siguiente_paso,
    atencionRequerida: {
      necesaria: doc.atencion_requerida.necesaria,
      motivo: doc.atencion_requerida.motivo,
    },
    actualizado: doc.lead.actualizado,
  };

  const carriles: ResumenCarril[] = (Array.isArray(doc.carriles) ? doc.carriles : []).map((c) => {
    const progresoCarril: ConteoObjetivo = plan.kind === "cruzado"
      ? contarTareas(Array.isArray(c.tareas) ? c.tareas : [], plan.items)
      : { kind: "desconocido", motivo: "plan-sin-verificar" };
    return {
      id: String(c.id),
      nombre: String(c.nombre),
      estado: String(c.estado),
      progreso: progresoCarril,
      actividad: {
        detalle: c.detenido_por ?? String(c.estado),
        iniciadaEn: c.ultimo_evento?.at ?? doc.lead.inicio,
        ultimaEvidencia: c.ultimo_evento?.que ?? String(c.estado),
      },
    };
  });

  let progreso: ConteoObjetivo;
  if (plan.kind !== "cruzado") {
    progreso = { kind: "desconocido", motivo: "plan-sin-verificar" };
  } else {
    // Denominador de fase: tareas distintas de carriles no omitidos. Una tarea
    // compartida por dos carriles incluidos cuenta una sola vez; una tarea que
    // solo vive en carriles omitidos sale del denominador.
    const incluidas: string[] = [];
    const vistas = new Set<string>();
    for (const c of Array.isArray(doc.carriles) ? doc.carriles : []) {
      if (c.estado === "omitido") continue;
      for (const id of Array.isArray(c.tareas) ? c.tareas : []) {
        if (vistas.has(id)) continue;
        vistas.add(id);
        incluidas.push(id);
      }
    }
    progreso = contarTareas(incluidas, plan.items);
  }

  return { ...base, progreso, carriles };
}

export type MotivoProblema = "ilegible" | "json-invalido" | "documento-invalido";

export type ProblemaSeguimiento = {
  trabajoId: `fase:${string}` | `corrida:${string}`;
  motivo: MotivoProblema;
};

export type ListaSeguimiento = {
  ok: true;
  activas: ResumenSeguimiento[];
  problemas: ProblemaSeguimiento[];
};

/**
 * Marcador conservador para un trabajo cuyo documento no se puede usar: el
 * trabajo sigue visible en el inventario (desconocido, sin carriles) para
 * que el director nunca lo confunda con "nada activo". El motivo real viaja
 * en `problemas`, sin exponer contenido crudo del archivo.
 */
function resumenConservador(
  trabajoId: `fase:${string}` | `corrida:${string}`,
  fase: string,
  titulo: string,
): ResumenSeguimiento {
  return {
    trabajoId,
    fase,
    titulo,
    progreso: { kind: "desconocido", motivo: "unidad-desconocida" },
    carriles: [],
    siguientePaso: "",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: "",
  };
}

function nombreDeTrabajo(trabajoId: `fase:${string}` | `corrida:${string}`): { fase: string; titulo: string } {
  if (trabajoId.startsWith("corrida:")) {
    const id = trabajoId.slice("corrida:".length);
    return { fase: id, titulo: `Corrida ${id}` };
  }
  const id = trabajoId.slice("fase:".length);
  return { fase: id, titulo: `Fase ${id}` };
}

function reportarRoto(
  trabajoId: `fase:${string}` | `corrida:${string}`,
  motivo: MotivoProblema,
  vistos: Set<string>,
  activas: ResumenSeguimiento[],
  problemas: ProblemaSeguimiento[],
): void {
  vistos.add(trabajoId);
  const { fase, titulo } = nombreDeTrabajo(trabajoId);
  activas.push(resumenConservador(trabajoId, fase, titulo));
  problemas.push({ trabajoId, motivo });
}

/**
 * Inventario activo para `runbook.progress.list`: todo documento abierto del
 * stateDir existente (fases en `progress/*.json`, corridas en `progress/c/`),
 * cada uno resumido con su cruce acotado. Los cerrados (`cierre.at` puesto)
 * no aparecen. Un archivo que nombra una fase o corrida pero no se puede
 * leer, parsear o validar NO desaparece: conserva su `trabajoId` con un
 * resumen conservador y su causa en `problemas`, para que el director nunca
 * lo confunda con "nada activo" ni retire el reloj. Deduplica por
 * `trabajoId` estable: un doc con `corrida` vive en disco bajo ambas claves.
 * Ordenado por `trabajoId` para que el corte de 30 minutos sea determinístico.
 */
export async function listarSeguimientoActivo(
  cfg: { stateDir: string },
  cfgGithub: { ghPath: string },
): Promise<ListaSeguimiento> {
  const rutas: Array<{ ruta: string; trabajoId: `fase:${string}` | `corrida:${string}` }> = [];
  try {
    for (const name of readdirSync(join(cfg.stateDir, "progress"))) {
      if (!name.endsWith(".json")) continue;
      const base = name.slice(0, -5);
      if (validarFase(base)) rutas.push({ ruta: join(cfg.stateDir, "progress", name), trabajoId: `fase:${base}` });
    }
  } catch {
    // Sin directorio no hay trabajo activo, no es un error.
  }
  try {
    for (const name of readdirSync(join(cfg.stateDir, "progress", "c"))) {
      if (!name.endsWith(".json")) continue;
      const base = name.slice(0, -5);
      if (CORRIDA_RE.test(base)) {
        rutas.push({ ruta: join(cfg.stateDir, "progress", "c", name), trabajoId: `corrida:${base}` });
      }
    }
  } catch {
    // Sin corridas no hay nada que sumar.
  }

  const vistos = new Set<string>();
  const activas: ResumenSeguimiento[] = [];
  const problemas: ProblemaSeguimiento[] = [];
  for (const { ruta, trabajoId } of rutas) {
    if (vistos.has(trabajoId)) continue;
    let crudo: string;
    try {
      crudo = readFileSync(ruta, "utf8");
    } catch {
      reportarRoto(trabajoId, "ilegible", vistos, activas, problemas);
      continue;
    }
    let crudoDoc: unknown;
    try {
      crudoDoc = JSON.parse(crudo);
    } catch {
      reportarRoto(trabajoId, "json-invalido", vistos, activas, problemas);
      continue;
    }
    if (!esProgresoDoc(crudoDoc)) {
      reportarRoto(trabajoId, "documento-invalido", vistos, activas, problemas);
      continue;
    }
    if (crudoDoc.cierre.at !== null) continue;
    let plan: PlanCruce = SIN_VERIFICAR;
    if (crudoDoc.plan !== undefined && crudoDoc.plan !== null) {
      try {
        const cruzado = await cruzarPlan(crudoDoc, { ghPath: cfgGithub.ghPath });
        if (cruzado !== undefined) plan = cruzado;
      } catch {
        plan = SIN_VERIFICAR;
      }
    }
    const resumen = resumirSeguimiento(crudoDoc, plan);
    if (vistos.has(resumen.trabajoId)) continue;
    vistos.add(resumen.trabajoId);
    activas.push(resumen);
  }
  const porId = (a: { trabajoId: string }, b: { trabajoId: string }): number =>
    (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0);
  activas.sort(porId);
  problemas.sort(porId);
  return { ok: true, activas, problemas };
}

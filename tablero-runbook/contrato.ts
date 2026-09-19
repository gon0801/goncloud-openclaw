/** Modelo tipado y validador del progreso. Sin disco ni red. */

export const SCHEMA_LITERAL = "runbook-progress.v1";

/** `omitido` existe para runbooks que CANCELAN un carril; Fase 6 no lo usó. */
export const CARRIL_ESTADOS = [
  "pendiente",
  "implementando",
  "revision-cruzada",
  "coderabbit",
  "auditoria-lead",
  "en-cola",
  "mergeado",
  "atorado",
  "revertido",
  "omitido",
] as const;

export const CI_ESTADOS = ["pendiente", "verde", "rojo", "sin-ci", "unknown"] as const;
export const CODERABBIT_ESTADOS = [
  "pendiente",
  "limpio",
  "con-hallazgos",
  "sin-cuota",
  "unknown",
] as const;
export const COLA_ESTADOS = [
  "pendiente",
  "esperando-ventana",
  "mergeando",
  "sync",
  "verificado",
  "revertido",
  "atorado",
] as const;
export const VERIFICADO_VALORES = ["pendiente", "ok", "fallo", "unknown"] as const;

/** Validar ES sanitizar: forma cerrada de clave de disco/URL; ahí se cierra el path traversal. */
export const FASE_RE = /^[0-9]{1,3}(\.[0-9]{1,3})?$/;
/** Propia, no `FASE_RE`: admite `[a-z0-9-]`. Validar ES sanitizar. */
export const CORRIDA_RE = /^[a-z0-9][a-z0-9-]{0,40}$/;
/** `owner/repo`; nunca empieza con `-` (spec, valores cerrados). */
export const REPO_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,38}\/[A-Za-z0-9._-]{1,100}$/;

export const TEXTO_MAX = 300;
export const SIGUIENTE_PASO_MAX = 160;
export const PLAN_RUTA_MAX = 200;
export const NOTAS_TOPE = 8;
export const PR_MAX = 10_000_000;
export const PASO_LOOP_MAX = 8;

const ISO_LIGERO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;

export type Evento = {
  at: string;
  carril?: string | null;
  que: string;
  situacion?: string | null;
};

export type PrRef = { repo: string; pr: number | null };

export type Carril = {
  id: string;
  nombre: string;
  repo: string;
  rama: string | null;
  tareas: string[];
  estado: string;
  paso_loop: number;
  ronda?: number;
  pr: number | null;
  head: string | null;
  approve_lead: string | null;
  ci: string;
  coderabbit: string;
  residuales: string[];
  detenido_por: string | null;
  ultimo_evento: { at: string; que: string } | null;
};

export type ColaItem = {
  id: string;
  prs: PrRef[];
  estado: string;
  ventana: string | null;
  merge_commits: string[];
  verificado: string | null;
  detenido_por: string | null;
  avance?: number;
};

export type ProgresoDoc = {
  schema: string;
  runbook: string;
  fase: string;
  titulo: string;
  lead: { agente: string; inicio: string; actualizado: string };
  atencion_requerida: { necesaria: boolean; motivo: string | null; desde: string | null };
  siguiente_paso: string;
  carriles: Carril[];
  cola: ColaItem[];
  eventos: Evento[];
  cierre: { at: string | null; telegram_message_id: number | null; resumen: string | null };
  corrida?: string;
  proyecto?: string;
  plan?: { repo: string; ruta: string; seccion: string | null } | null;
  notas?: string[];
};

// ---------------------------------------------------------------------------
// validarFase / validarProgreso
// ---------------------------------------------------------------------------

export function validarFase(s: unknown): boolean {
  return typeof s === "string" && FASE_RE.test(s);
}

function esTexto(v: unknown, max: number): boolean {
  return typeof v === "string" && v.length > 0 && v.length <= max;
}

function esIsoLigero(v: unknown): boolean {
  return typeof v === "string" && ISO_LIGERO_RE.test(v);
}

function esRutaPlan(v: unknown): boolean {
  if (typeof v !== "string" || v.length === 0 || v.length > PLAN_RUTA_MAX) return false;
  if (v.startsWith("/") || v.startsWith("\\") || /^[A-Za-z]:/.test(v)) return false;
  return !v.split(/[/\\]/).some((seg) => seg === "..");
}

type Veredicto = { ok: boolean; razones: string[] };

/**
 * Valida un documento `runbook-progress.v1` contra los valores cerrados del
 * spec. Recolecta TODAS las razones (el lead las quiere juntas para corregir
 * en una pasada). El orden de los bloques es deliberado: schema y fase primero
 * porque son la identidad del documento; después los textos del encabezado;
 * después carriles (repo antes que estado); al final cola, eventos y cierre.
 */
export function validarProgreso(doc: unknown): Veredicto {
  const razones: string[] = [];
  if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
    return { ok: false, razones: ["el documento no es un objeto JSON"] };
  }
  const d = doc as Record<string, unknown>;

  // Identidad (reglas 1 y 2 del spec).
  if (d["schema"] !== SCHEMA_LITERAL) {
    razones.push(`schema: se esperaba literal "${SCHEMA_LITERAL}"`);
  }
  if (!validarFase(d["fase"])) {
    razones.push("fase: no casa ^[0-9]{1,3}(\\.[0-9]{1,3})?$ — es clave de disco y de URL");
  }
  if (d["corrida"] !== undefined && (typeof d["corrida"] !== "string" || !CORRIDA_RE.test(d["corrida"]))) {
    razones.push("corrida: no casa ^[a-z0-9][a-z0-9-]{0,40}$ — es clave de disco y de URL");
  }

  // Encabezado.
  if (!esTexto(d["titulo"], TEXTO_MAX)) {
    razones.push(typeof d["titulo"] === "string" && d["titulo"].length > TEXTO_MAX
      ? `titulo: excede ${TEXTO_MAX} caracteres`
      : "titulo: falta o vacío");
  }
  if (!esTexto(d["siguiente_paso"], SIGUIENTE_PASO_MAX)) {
    razones.push(typeof d["siguiente_paso"] === "string" && d["siguiente_paso"].length > SIGUIENTE_PASO_MAX
      ? `siguiente_paso: excede ${SIGUIENTE_PASO_MAX} caracteres`
      : "siguiente_paso: falta o vacío");
  }
  if (!esTexto(d["runbook"], TEXTO_MAX)) razones.push("runbook: falta la ruta del runbook");
  if (d["proyecto"] !== undefined && !esTexto(d["proyecto"], TEXTO_MAX)) {
    razones.push(typeof d["proyecto"] === "string" && (d["proyecto"] as string).length > TEXTO_MAX
      ? `proyecto: excede ${TEXTO_MAX} caracteres`
      : "proyecto: falta o vacío");
  }
  if (d["plan"] !== undefined && d["plan"] !== null) {
    if (typeof d["plan"] !== "object" || Array.isArray(d["plan"])) {
      razones.push("plan: debe ser objeto o null");
    } else {
      const p = d["plan"] as Record<string, unknown>;
      if (typeof p["repo"] !== "string" || !REPO_RE.test(p["repo"])) {
        razones.push("plan.repo: no casa el patrón owner/repo cerrado");
      }
      if (!esRutaPlan(p["ruta"])) razones.push("plan.ruta: ruta relativa ≤200, sin .. ni absoluta");
      if (p["seccion"] !== null && !esTexto(p["seccion"], TEXTO_MAX)) {
        razones.push("plan.seccion: debe ser texto acotado o null");
      }
    }
  }

  const lead = d["lead"];
  if (lead === null || typeof lead !== "object" || Array.isArray(lead)) {
    razones.push("lead: falta o no es objeto");
  } else {
    const l = lead as Record<string, unknown>;
    if (!esTexto(l["agente"], TEXTO_MAX)) razones.push("lead.agente: falta o vacío");
    if (!esIsoLigero(l["inicio"])) razones.push("lead.inicio: no tiene forma ISO");
    if (!esIsoLigero(l["actualizado"])) razones.push("lead.actualizado: no tiene forma ISO");
  }

  const aten = d["atencion_requerida"];
  if (aten === null || typeof aten !== "object" || Array.isArray(aten)) {
    razones.push("atencion_requerida: falta o no es objeto");
  } else {
    const a = aten as Record<string, unknown>;
    if (typeof a["necesaria"] !== "boolean") razones.push("atencion_requerida.necesaria: no es booleano");
    if (a["motivo"] !== null && !esTexto(a["motivo"], TEXTO_MAX)) {
      razones.push("atencion_requerida.motivo: debe ser texto acotado o null");
    }
    if (a["desde"] !== null && !esIsoLigero(a["desde"])) {
      razones.push("atencion_requerida.desde: no tiene forma ISO ni es null");
    }
  }

  // Carriles.
  const carriles = d["carriles"];
  if (!Array.isArray(carriles)) {
    razones.push("carriles: no es una lista");
  } else {
    const vistos = new Set<string>();
    carriles.forEach((c: unknown, i: number) => {
      const donde = `carriles[${i}]`;
      if (c === null || typeof c !== "object" || Array.isArray(c)) {
        razones.push(`${donde}: no es objeto`);
        return;
      }
      const o = c as Record<string, unknown>;
      if (!esTexto(o["id"], 100)) {
        razones.push(`${donde}.id: falta o vacío`);
      } else if (vistos.has(o["id"])) {
        razones.push(`${donde}.id: repetido ("${o["id"]}") — los ids son únicos y estables`);
      } else {
        vistos.add(o["id"]);
      }
      if (typeof o["repo"] !== "string" || !REPO_RE.test(o["repo"])) {
        razones.push(`${donde}.repo: no casa el patrón owner/repo cerrado`);
      }
      const pr = o["pr"];
      if (
        pr !== null &&
        (typeof pr !== "number" || !Number.isInteger(pr) || pr < 1 || pr >= PR_MAX)
      ) {
        razones.push(`${donde}.pr: debe ser entero positivo < ${PR_MAX} o null`);
      }
      if (!(CARRIL_ESTADOS as readonly string[]).includes(o["estado"] as string)) {
        razones.push(`${donde}.estado: valor fuera de la lista cerrada`);
      }
      const paso = o["paso_loop"];
      if (typeof paso !== "number" || !Number.isInteger(paso) || paso < 0 || paso > PASO_LOOP_MAX) {
        razones.push(`${donde}.paso_loop: entero 0 a ${PASO_LOOP_MAX}`);
      }
      if (!(CI_ESTADOS as readonly string[]).includes(o["ci"] as string)) {
        razones.push(`${donde}.ci: valor fuera de la lista cerrada`);
      }
      if (!(CODERABBIT_ESTADOS as readonly string[]).includes(o["coderabbit"] as string)) {
        razones.push(`${donde}.coderabbit: valor fuera de la lista cerrada`);
      }
      if (typeof o["nombre"] === "string" && o["nombre"].length > TEXTO_MAX) {
        razones.push(`${donde}.nombre: excede ${TEXTO_MAX} caracteres`);
      } else if (!esTexto(o["nombre"], TEXTO_MAX)) {
        razones.push(`${donde}.nombre: falta o vacío`);
      }
      if (o["rama"] !== null && !esTexto(o["rama"], TEXTO_MAX)) {
        razones.push(`${donde}.rama: debe ser texto acotado o null`);
      }
      for (const [campo, tope] of [
        ["head", TEXTO_MAX],
        ["approve_lead", TEXTO_MAX],
        ["detenido_por", TEXTO_MAX],
      ] as const) {
        if (o[campo] !== null && !esTexto(o[campo], tope)) {
          razones.push(`${donde}.${campo}: debe ser texto acotado o null`);
        }
      }
      // Regla 7 del spec: atorado lleva detenido_por no nulo.
      if (o["estado"] === "atorado" && !esTexto(o["detenido_por"], TEXTO_MAX)) {
        razones.push(`${donde}.detenido_por: obligatorio cuando estado es atorado`);
      }
      if (!Array.isArray(o["tareas"])) {
        razones.push(`${donde}.tareas: no es una lista`);
      } else if (o["tareas"].some((t: unknown) => !esTexto(t, TEXTO_MAX))) {
        razones.push(`${donde}.tareas: algún ítem no es texto acotado`);
      }
      if (!Array.isArray(o["residuales"])) {
        razones.push(`${donde}.residuales: no es una lista`);
      } else if (o["residuales"].some((t: unknown) => !esTexto(t, TEXTO_MAX))) {
        razones.push(`${donde}.residuales: algún ítem no es texto acotado`);
      }
      const ue = o["ultimo_evento"];
      if (ue !== null && ue !== undefined) {
        if (ue === null || typeof ue !== "object" || Array.isArray(ue)) {
          razones.push(`${donde}.ultimo_evento: debe ser objeto o null`);
        } else {
          const u = ue as Record<string, unknown>;
          if (!esIsoLigero(u["at"])) razones.push(`${donde}.ultimo_evento.at: no tiene forma ISO`);
          if (!esTexto(u["que"], TEXTO_MAX)) razones.push(`${donde}.ultimo_evento.que: falta o vacío`);
        }
      }
    });
  }

  // Cola.
  const cola = d["cola"];
  if (!Array.isArray(cola)) {
    razones.push("cola: no es una lista");
  } else {
    cola.forEach((q: unknown, j: number) => {
      const donde = `cola[${j}]`;
      if (q === null || typeof q !== "object" || Array.isArray(q)) {
        razones.push(`${donde}: no es objeto`);
        return;
      }
      const o = q as Record<string, unknown>;
      if (!esTexto(o["id"], 100)) razones.push(`${donde}.id: falta o vacío`);
      if (!(COLA_ESTADOS as readonly string[]).includes(o["estado"] as string)) {
        razones.push(`${donde}.estado: valor fuera de la lista cerrada`);
      }
      if (o["verificado"] !== null && !(VERIFICADO_VALORES as readonly string[]).includes(o["verificado"] as string)) {
        razones.push(`${donde}.verificado: valor fuera de la lista cerrada`);
      }
      if (o["estado"] === "atorado" && !esTexto(o["detenido_por"], TEXTO_MAX)) {
        razones.push(`${donde}.detenido_por: obligatorio cuando estado es atorado`);
      } else if (o["detenido_por"] !== null && !esTexto(o["detenido_por"], TEXTO_MAX)) {
        razones.push(`${donde}.detenido_por: debe ser texto acotado o null`);
      }
      if (o["ventana"] !== null && !esTexto(o["ventana"], TEXTO_MAX)) {
        razones.push(`${donde}.ventana: debe ser texto acotado o null`);
      }
      if (!Array.isArray(o["prs"])) {
        razones.push(`${donde}.prs: no es una lista`);
      } else {
        o["prs"].forEach((p: unknown, k: number) => {
          if (p === null || typeof p !== "object" || Array.isArray(p)) {
            razones.push(`${donde}.prs[${k}]: no es objeto`);
            return;
          }
          const po = p as Record<string, unknown>;
          if (typeof po["repo"] !== "string" || !REPO_RE.test(po["repo"])) {
            razones.push(`${donde}.prs[${k}].repo: no casa el patrón owner/repo cerrado`);
          }
          const n = po["pr"];
          if (n !== null && (typeof n !== "number" || !Number.isInteger(n) || n < 1 || n >= PR_MAX)) {
            razones.push(`${donde}.prs[${k}].pr: debe ser entero positivo < ${PR_MAX} o null`);
          }
        });
      }
      if (!Array.isArray(o["merge_commits"])) {
        razones.push(`${donde}.merge_commits: no es una lista`);
      } else if (o["merge_commits"].some((m: unknown) => !esTexto(m, TEXTO_MAX))) {
        razones.push(`${donde}.merge_commits: algún ítem no es texto acotado`);
      }
      const av = o["avance"];
      if (av !== undefined && (typeof av !== "number" || !Number.isInteger(av) || av < 0 || av > 100)) {
        razones.push(`${donde}.avance: entero 0 a 100`);
      }
    });
  }

  // Eventos.
  const eventos = d["eventos"];
  if (!Array.isArray(eventos)) {
    razones.push("eventos: no es una lista");
  } else {
    eventos.forEach((e: unknown, i: number) => {
      const donde = `eventos[${i}]`;
      if (e === null || typeof e !== "object" || Array.isArray(e)) {
        razones.push(`${donde}: no es objeto`);
        return;
      }
      const o = e as Record<string, unknown>;
      if (!esIsoLigero(o["at"])) razones.push(`${donde}.at: no tiene forma ISO`);
      if (o["carril"] !== null && o["carril"] !== undefined && !esTexto(o["carril"], 100)) {
        razones.push(`${donde}.carril: debe ser texto corto o null`);
      }
      if (!esTexto(o["que"], TEXTO_MAX)) razones.push(`${donde}.que: falta o vacío`);
      if (o["situacion"] !== null && o["situacion"] !== undefined && !esTexto(o["situacion"], TEXTO_MAX)) {
        razones.push(`${donde}.situacion: debe ser texto acotado o null`);
      }
    });
  }

  if (d["notas"] !== undefined) {
    const notas = d["notas"];
    if (!Array.isArray(notas)) razones.push("notas: no es una lista");
    else if (notas.length > NOTAS_TOPE) razones.push(`notas: más de ${NOTAS_TOPE} líneas`);
    else if (notas.some((n: unknown) => !esTexto(n, TEXTO_MAX))) {
      razones.push("notas: alguna línea no es texto acotado");
    }
  }

  // Cierre.
  const cierre = d["cierre"];
  if (cierre === null || typeof cierre !== "object" || Array.isArray(cierre)) {
    razones.push("cierre: falta o no es objeto");
  } else {
    const c = cierre as Record<string, unknown>;
    if (c["at"] !== null && !esIsoLigero(c["at"])) razones.push("cierre.at: no tiene forma ISO ni es null");
    const tg = c["telegram_message_id"];
    if (tg !== null && (typeof tg !== "number" || !Number.isInteger(tg) || tg < 1)) {
      razones.push("cierre.telegram_message_id: entero positivo o null");
    }
    if (c["resumen"] !== null && !esTexto(c["resumen"], TEXTO_MAX)) {
      // La razon nombra el tope y el largo real, como ya hace `titulo`. Medido el
      // 2026-09-17: con el mensaje generico, un documento rechazado por 40 caracteres
      // de mas costo dos dias — el tablero siguio sirviendo el fixture del canary y
      // nadie supo por que, porque hubo que ir a leer el fuente para saber el tope.
      razones.push(typeof c["resumen"] === "string" && (c["resumen"] as string).length > TEXTO_MAX
        ? `cierre.resumen: excede ${TEXTO_MAX} caracteres (tiene ${(c["resumen"] as string).length})`
        : "cierre.resumen: debe ser texto acotado o null");
    }
  }

  return { ok: razones.length === 0, razones };
}

export type Derivado = {
  totalCarriles: number;
  mergeados: number;
  porcentajeMergeado: number;
  carrilesAtorados: string[];
  colaAtorada: string[];
  siguienteCola: { id: string; estado: string; prs: number } | null;
  minutosDesdeUltimoEvento: number | null;
};

const COLA_TERMINADA = new Set(["verificado", "revertido"]);

export function derivar(doc: ProgresoDoc, ahora: number = Date.now()): Derivado {
  const carriles = Array.isArray(doc.carriles) ? doc.carriles : [];
  const mergeados = carriles.filter((c) => c?.estado === "mergeado").length;
  const atorados = carriles.filter((c) => c?.estado === "atorado").map((c) => String(c.id));
  const cola = Array.isArray(doc.cola) ? doc.cola : [];
  const colaAtorada = cola.filter((q) => q?.estado === "atorado").map((q) => String(q.id));
  const siguiente = cola.find((q) => !COLA_TERMINADA.has(q?.estado ?? "")) ?? null;

  let ultimoMs: number | null = null;
  const considerar = (at: unknown): void => {
    if (typeof at !== "string") return;
    const ms = Date.parse(at);
    if (Number.isNaN(ms)) return;
    if (ultimoMs === null || ms > ultimoMs) ultimoMs = ms;
  };
  for (const e of Array.isArray(doc.eventos) ? doc.eventos : []) considerar(e?.at);
  for (const c of carriles) considerar(c?.ultimo_evento?.at);
  const minutos =
    ultimoMs === null ? null : Math.max(0, Math.floor((ahora - ultimoMs) / 60000));

  return {
    totalCarriles: carriles.length,
    mergeados,
    porcentajeMergeado: carriles.length === 0 ? 0 : Math.round((100 * mergeados) / carriles.length),
    carrilesAtorados: atorados,
    colaAtorada,
    siguienteCola: siguiente
      ? { id: String(siguiente.id), estado: String(siguiente.estado), prs: Array.isArray(siguiente.prs) ? siguiente.prs.length : 0 }
      : null,
    minutosDesdeUltimoEvento: minutos,
  };
}

// fusionarEventos — append-only. Tope de ÍTEMS en memoria; el jsonl rota por bytes en index.ts.
export const EVENTOS_TOPE = 1000;
export const EVENTOS_JSONL_MAX_BYTES = 5 * 1024 * 1024;

function claveEvento(e: Evento): string {
  return `${e?.at ?? ""}\u0000${e?.carril ?? ""}\u0000${e?.que ?? ""}`;
}

export function fusionarEventos(previo: Evento[], nuevo: Evento[]): Evento[] {
  const vistas = new Set((Array.isArray(previo) ? previo : []).map(claveEvento));
  const fusion = [...(Array.isArray(previo) ? previo : [])];
  for (const e of Array.isArray(nuevo) ? nuevo : []) {
    if (vistas.has(claveEvento(e))) continue;
    fusion.push(e);
    vistas.add(claveEvento(e));
  }
  return fusion.length > EVENTOS_TOPE ? fusion.slice(fusion.length - EVENTOS_TOPE) : fusion;
}


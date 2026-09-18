/**
 * tablero-runbook/lib.ts — núcleo puro del tablero de runbook (Fase 7 / 7.3).
 *
 * Contrato: el lead escribe el progreso como `runbook-progress.v1` (SSOT en
 * docs/spec/runbook-progress.v1.md) y este módulo SOLO valida, deriva y pinta.
 * Nunca infiere progreso; nunca toca disco ni red (el cableado vive en index.ts,
 * el cruce con GitHub en github.ts). Sin dependencias: Node puro.
 *
 * Qué se reusa de summa-gate en vez de reescribirse: la política de tope y
 * rotación del jsonl (summa-gate/observer.ts: OBSERVER_MAX_BYTES, un solo nivel
 * de respaldo con nombre FIJO `<vivo>.1.jsonl`) se aplica igual en los eventos
 * de este plugin; la sanitización de claves para nombres de archivo es la misma
 * idea que summa-gate/index.ts:87-89 (aquí ni hace falta: `fase` tiene forma
 * cerrada numérica, así que validar ES sanitizar).
 *
 * Regla de seguridad del render (spec, regla 3): TODO texto se trunca primero
 * y se escapa después, en el punto de interpolación, sin excepciones por campo.
 * Una sola función `esc()` en todo el módulo.
 */

// ---------------------------------------------------------------------------
// Valores cerrados del spec (docs/spec/runbook-progress.v1.md, "Valores cerrados").
// Exportados para que los tests anclen las listas completas.
// ---------------------------------------------------------------------------

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

/** Es clave de disco y de URL, por eso la forma es cerrada (spec, valores cerrados). */
export const FASE_RE = /^[0-9]{1,3}(\.[0-9]{1,3})?$/;
/** `owner/repo`; nunca empieza con `-` (spec, valores cerrados). */
export const REPO_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,38}\/[A-Za-z0-9._-]{1,100}$/;

export const TEXTO_MAX = 300;
export const SIGUIENTE_PASO_MAX = 160;
export const PR_MAX = 10_000_000; // entero positivo menor que 10 000 000
export const PASO_LOOP_MAX = 8; // el loop tiene pasos que saturan en 8 (regla 5 del runbook f7)

const ISO_LIGERO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;

// ---------------------------------------------------------------------------
// Tipos del documento (forma v1 del spec).
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// derivar — lo que la interfaz calcula (el JSON nunca lo trae, spec § última).
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// esc / truncar — una sola función de escape, truncar SIEMPRE antes.
// ---------------------------------------------------------------------------

const ESC_MAP: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

/** La única función de escape del plugin. Se aplica en el punto de interpolación. */
export function esc(s: string): string {
  return s.replace(/[&<>"']/g, (ch) => ESC_MAP[ch] ?? ch);
}

/**
 * Trunca ANTES de escapar: escapar primero y truncar después puede cortar una
 * entidad a la mitad ("&am…"), que es exactamente el mutante que la batería
 * clava. El marcador "…" no forma parte del tope.
 */
export function truncar(s: string, max: number): string {
  return s.length > max ? `${s.slice(0, max)}…` : s;
}

/** El único camino al HTML para un valor dinámico: truncar primero, escapar después. */
function t(v: unknown, max: number = TEXTO_MAX): string {
  const s = typeof v === "string" ? v : String(v ?? "");
  return esc(truncar(s, max));
}

// ---------------------------------------------------------------------------
// renderTablero — HTML autocontenido: CSS inline, sin scripts, sin fuentes remotas.
// ---------------------------------------------------------------------------

/** Mapa `owner/repo#123` → estado vivo de GitHub; `null` = intentó y no pudo ("unknown"). */
export type GithubCruce = Record<string, string | null>;

export function clavePr(repo: string, pr: number | null): string {
  return `${repo}#${pr}`;
}

function rotuloGithub(github: GithubCruce | undefined, repo: string, pr: number | null): string {
  if (pr === null || pr === undefined) return "";
  if (github === undefined) return '<span class="gh gh-off">GitHub: sin verificar</span>';
  const valor = github[clavePr(repo, pr)];
  return valor === null || valor === undefined
    ? '<span class="gh gh-unk">GitHub: unknown</span>'
    : `<span class="gh gh-ok">GitHub: ${t(valor, 100)}</span>`;
}

const CSS = `:root{color-scheme:light dark}
*{box-sizing:border-box}
body{font:14px/1.45 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;margin:0;padding:24px;background:#f6f7f9;color:#1c2430}
main{max-width:1080px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:15px;margin:28px 0 8px;text-transform:uppercase;letter-spacing:.06em;color:#5b6675}
.atencion{background:#8a1c1c;color:#fff;padding:12px 16px;border-radius:8px;margin:0 0 16px;font-weight:600}
.siguiente{font-size:17px;margin:8px 0 20px;padding:10px 14px;background:#eef3fb;border-left:4px solid #2b5cb8;border-radius:6px}
.resumen{display:flex;flex-wrap:wrap;gap:12px;margin:0 0 8px}
.resumen div{background:#fff;border:1px solid #dde3ea;border-radius:8px;padding:8px 14px}
.resumen .num{font-size:20px;font-weight:700;display:block}
.barra{height:8px;background:#dde3ea;border-radius:4px;overflow:hidden;margin:6px 0 2px}
.barra i{display:block;height:100%;background:#2f9e44}
table{border-collapse:collapse;width:100%;background:#fff;border:1px solid #dde3ea;border-radius:8px}
th,td{text-align:left;padding:7px 10px;border-top:1px solid #e6eaf0;vertical-align:top;font-size:13px}
th{border-top:0;background:#eef1f5;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.estado{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;background:#e5e8ec}
.estado.mergeado{background:#d9f0dd}.estado.atorado{background:#f6d7d7}.estado.en-cola,.estado.esperando-ventana{background:#fdeecb}
.gh{display:inline-block;margin-top:3px;font-size:12px;padding:1px 7px;border-radius:8px}
.gh-off{background:#e5e8ec;color:#444}.gh-ok{background:#dce8f8}.gh-unk{background:#f0e0d0}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}
ul.res{margin:0;padding-left:16px}
.eventos li{margin:4px 0}
footer{margin-top:28px;color:#5b6675;font-size:12px;border-top:1px solid #ccd4dd;padding-top:10px}
nav.fases a{margin-right:10px}
a{color:#2b5cb8}`;

/**
 * Pinta el tablero. Determinístico: nada de Date.now() adentro (el tiempo llega
 * vía `derivado`), así la ruta HTTP y `runbook.progress.get` producen el MISMO
 * HTML byte a byte.
 */
export function renderTablero(
  doc: ProgresoDoc,
  derivado: Derivado,
  github?: GithubCruce,
  fases?: string[],
): string {
  const filasCarriles = (Array.isArray(doc.carriles) ? doc.carriles : []).map((c) => {
    const prTxt =
      c.pr === null || c.pr === undefined
        ? "—"
        : `${t(c.repo, 160)} <span class="mono">#${t(c.pr, 10)}</span>`;
    const gh = rotuloGithub(github, c.repo, c.pr ?? null);
    const residuales = (Array.isArray(c.residuales) ? c.residuales : [])
      .map((r) => `<li>${t(r)}</li>`)
      .join("");
    const detenido = c.detenido_por ? `<div class="det">${t(c.detenido_por)}</div>` : "";
    const ue = c.ultimo_evento
      ? `<div>${t(c.ultimo_evento.at, 40)}</div><div>${t(c.ultimo_evento.que, 120)}</div>`
      : "—";
    return `<tr>
<td><strong>${t(c.id, 100)}</strong><div>${t(c.nombre)}</div></td>
<td><span class="estado ${t(c.estado, 30)}">${t(c.estado, 30)}</span>${detenido}</td>
<td>${prTxt}${gh ? `<div>${gh}</div>` : ""}</td>
<td>${t(c.ci, 20)}</td>
<td>${t(c.coderabbit, 20)}</td>
<td>${residuales ? `<ul class="res">${residuales}</ul>` : "—"}</td>
<td>${ue}</td>
</tr>`;
  }).join("\n");

  const filasCola = (Array.isArray(doc.cola) ? doc.cola : []).map((q) => {
    const prs = (Array.isArray(q.prs) ? q.prs : [])
      .map((p) => {
        const gh = rotuloGithub(github, p.repo, p.pr ?? null);
        return `<li><span class="mono">${t(p.repo, 160)}#${t(p.pr ?? "—", 10)}</span>${gh ? ` ${gh}` : ""}</li>`;
      })
      .join("");
    return `<tr>
<td><strong>${t(q.id, 100)}</strong></td>
<td><span class="estado ${t(q.estado, 30)}">${t(q.estado, 30)}</span>${q.detenido_por ? `<div class="det">${t(q.detenido_por)}</div>` : ""}</td>
<td>${t(q.ventana ?? "—", 120)}</td>
<td>${prs ? `<ul class="res">${prs}</ul>` : "—"}</td>
<td>${t(q.verificado ?? "—", 20)}</td>
</tr>`;
  }).join("\n");

  const eventos = (Array.isArray(doc.eventos) ? doc.eventos : [])
    .slice(-20)
    .reverse()
    .map((e) => `<li><span class="mono">${t(e.at, 40)}</span> ${e.carril ? `[${t(e.carril, 100)}] ` : ""}${t(e.que)}${e.situacion ? ` <em>(${t(e.situacion, 120)})</em>` : ""}</li>`)
    .join("\n");

  const banner =
    doc.atencion_requerida?.necesaria === true
      ? `<div class="atencion">⚠ ${t(doc.atencion_requerida.motivo ?? "Atención requerida")} <span class="mono">desde ${t(doc.atencion_requerida.desde ?? "—", 40)}</span></div>`
      : "";

  const navFases = (fases ?? [])
    .filter((f) => f !== doc.fase && validarFase(f))
    .map((f) => `<a href="/runbook/tablero/${encodeURIComponent(f)}">Fase ${t(f, 12)}</a>`)
    .join("");
  const nav = navFases ? `<nav class="fases">Fases: ${navFases}</nav>` : "";

  return `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${t(doc.titulo)}</title>
<style>${CSS}</style>
</head>
<body>
${banner}
<main>
<h1>${t(doc.titulo)}</h1>
<p class="siguiente">${t(doc.siguiente_paso, SIGUIENTE_PASO_MAX)}</p>
<div class="resumen">
<div><span class="num">${t(derivado.mergeados)}/${t(derivado.totalCarriles)}</span>mergeados</div>
<div class="barra-wrap"><div class="barra"><i style="width:${t(Math.min(100, Math.max(0, derivado.porcentajeMergeado)), 3)}%"></i></div>${t(derivado.porcentajeMergeado)}%</div>
<div><span class="num">${t(derivado.carrilesAtorados.length)}</span>atorados${derivado.carrilesAtorados.length ? ` <span class="mono">(${derivado.carrilesAtorados.map((id) => t(id, 100)).join(", ")})</span>` : ""}</div>
<div><span class="num">${derivado.siguienteCola ? t(derivado.siguienteCola.id, 100) : "—"}</span>siguiente de cola${derivado.siguienteCola ? ` (${t(derivado.siguienteCola.estado, 30)})` : ""}</div>
<div><span class="num">${derivado.minutosDesdeUltimoEvento === null ? "—" : t(derivado.minutosDesdeUltimoEvento)}</span>min desde el último evento</div>
<div><span class="num" style="font-size:14px">${github === undefined ? "GitHub: sin verificar" : "GitHub"}</span>${github === undefined ? "cruce apagado" : "cruce activo"}</div>
</div>
<h2>Carriles</h2>
<table>
<tr><th>Carril</th><th>Estado</th><th>Repo / PR</th><th>CI</th><th>CodeRabbit</th><th>Residuales</th><th>Último evento</th></tr>
${filasCarriles}
</table>
<h2>Cola de merge</h2>
<table>
<tr><th>Ítem</th><th>Estado</th><th>Ventana</th><th>PRs</th><th>Verificado</th></tr>
${filasCola}
</table>
<h2>Eventos (últimos 20)</h2>
<ul class="eventos">
${eventos || "<li>—</li>"}
</ul>
${nav}
<footer>La fuente de verdad es el runbook (${t(doc.runbook, 200)}); este tablero es una copia que solo pinta lo que el lead escribió. Lo rotulado "GitHub" viene del cruce vivo; lo demás lo reportó el lead.</footer>
</main>
</body>
</html>
`;
}

// ---------------------------------------------------------------------------
// fusionarEventos — append-only, nunca pierde los previos, con tope.
// La política de tope/rotación es la de summa-gate/observer.ts: un solo nivel
// de respaldo con nombre fijo; aquí el tope es de ÍTEMS en memoria (el jsonl de
// disco, que guarda todos, rota por bytes en index.ts con el mismo criterio).
// ---------------------------------------------------------------------------

/** Tope de la vista en memoria; el jsonl de disco guarda todos (spec, regla 4). */
export const EVENTOS_TOPE = 1000;
/** Tope de bytes del jsonl de eventos por fase; mismo criterio que OBSERVER_MAX_BYTES. */
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

/**
 * tablero-runbook/seguimiento-clock.ts — reloj 15/30 del seguimiento.
 *
 * La vigilancia interna corre cada 15 minutos; el Telegram consolidado sale
 * cada 30. `decidirSeguimiento` es puro: nunca llama a Telegram, al disco ni
 * al reloj. Dada la época actual, los resúmenes activos, las tareas sueltas,
 * el último estado confirmado (scratch de la automatización `avance-tareas`)
 * y un eventual evento inmediato, devuelve `NO_REPLY` o `SEND`.
 *
 * Solo el llamador escribe el scratch, y solo tras entrega confirmada
 * (`ok:true` más `messageId`): combina `estadoTrasConfirmar` con ese
 * `messageId` y persiste el `EstadoSeguimiento` completo. Un envío fallido
 * deja el scratch anterior byte por byte y el siguiente tick reintenta.
 * Un `SEND` no expone un próximo estado de nombre general.
 */
import type { ConteoObjetivo, ProblemaSeguimiento, ResumenSeguimiento } from "./seguimiento.ts";
import { renderSeguimientoV2, sanearTextoPropietario, type TareaSuelta } from "./seguimiento-render.ts";

export const SCHEMA_SEGUIMIENTO_CLOCK = "seguimiento-clock.v1";

/**
 * 30 minutos entre reportes periódicos; la vigilancia interna corre cada 15.
 * El `ahora` de este módulo es época en SEGUNDOS (el RPC convierte los ms de
 * `Date.now` en la frontera): los ticks del plan se escriben 900/1800 y el
 * scratch guarda segundos.
 */
export const VENTANA_REPORTE_SECS = 1800;

export type CorteSeguimiento =
  | { kind: "esperando-primer-reporte"; inicioVentana: number }
  | { kind: "reporte-confirmado"; ultimoReporteConfirmado: number };

export type EstadoSeguimiento = {
  schema: "seguimiento-clock.v1";
  corte: CorteSeguimiento;
  ultimoEstado: string;
  messageId: number | null;
  trabajosActivos: string[];
};

export type EstadoTrasConfirmar = Omit<EstadoSeguimiento, "messageId">;

export type EventoInmediato = {
  tipo: "NECESITO TU RESPUESTA" | "DETENIDA" | "CERRADA";
  texto: string;
};

export type DecisionSeguimiento =
  | { accion: "NO_REPLY"; estado: EstadoSeguimiento }
  | {
    accion: "SEND";
    tipo: "periodico" | "inmediato";
    mensaje: string;
    estadoTrasConfirmar: EstadoTrasConfirmar;
  };

export type EntradaDecision = {
  ahora: number;
  previo: EstadoSeguimiento;
  activas: ResumenSeguimiento[];
  sueltas?: TareaSuelta[];
  inmediato?: EventoInmediato | null;
  problemas?: ProblemaSeguimiento[];
};

/** Base de la ventana de 30 minutos: el inicio o el último corte confirmado. */
function inicioVentanaDe(corte: CorteSeguimiento): number {
  switch (corte.kind) {
    case "esperando-primer-reporte":
      return corte.inicioVentana;
    case "reporte-confirmado":
      return corte.ultimoReporteConfirmado;
    default: {
      const nunca: never = corte;
      throw new Error(`seguimiento-clock: corte desconocido (${JSON.stringify(nunca)})`);
    }
  }
}

type ResumenDigest = { t: string; f: string; c: number; n: number; p: number | null };

function esNumeroFinito(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function esObjeto(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function digestConteo(p: ConteoObjetivo): { c: number; n: number; p: number | null } {
  if (p.kind === "desconocido") return { c: 0, n: 0, p: null };
  return { c: p.completadas, n: p.total, p: p.porcentaje };
}

/**
 * Resumen estable del corte: identificadores de trabajo más conteos y
 * porcentajes por fase (las sueltas van con su nombre). Es lo que se compara
 * entre ventanas para el `Que cambió` y para no repetir un inmediato tratado.
 */
function resumenEstable(
  activas: ResumenSeguimiento[],
  sueltas: TareaSuelta[],
  inmediato: EventoInmediato | null,
): string {
  const a: ResumenDigest[] = activas.map((r) => {
    const d = digestConteo(r.progreso);
    return { t: r.trabajoId, f: r.fase, c: d.c, n: d.n, p: d.p };
  }).sort((x, y) => (x.t < y.t ? -1 : x.t > y.t ? 1 : 0));
  const s = sueltas.map((t) => {
    const d = digestConteo(t.progreso);
    return { t: `suelta:${t.nombre}`, f: "", c: d.c, n: d.n, p: d.p };
  }).sort((x, y) => (x.t < y.t ? -1 : x.t > y.t ? 1 : 0));
  return JSON.stringify({
    a,
    s,
    i: inmediato === null ? null : { tipo: inmediato.tipo, texto: inmediato.texto },
  });
}

function leerResumen(previo: string): Map<string, { c: number; n: number }> {
  const mapa = new Map<string, { c: number; n: number }>();
  try {
    const d: unknown = JSON.parse(previo);
    const arr: unknown = esObjeto(d) && Array.isArray(d["a"]) ? d["a"] : d;
    if (!Array.isArray(arr)) return mapa;
    for (const e of arr) {
      if (!esObjeto(e)) continue;
      const t = e["t"];
      const c = e["c"];
      const n = e["n"];
      if (typeof t !== "string") continue;
      if (typeof c !== "number" || typeof n !== "number") continue;
      mapa.set(t, { c, n });
    }
  } catch {
    // Resumen ilegible: sin base para el diff, el cambio queda vacío y el
    // reporte cae al texto de continuidad con la última evidencia.
  }
  return mapa;
}

/** `Que cambió` derivado de conteos, sin inventar prosa: compara contra el último corte confirmado. */
function derivarCambio(
  ultimoEstado: string,
  activas: ResumenSeguimiento[],
): string {
  const prev = leerResumen(ultimoEstado);
  if (prev.size === 0) return "";
  const lineas: string[] = [];
  for (const r of activas) {
    if (r.progreso.kind === "desconocido") continue;
    const p = prev.get(r.trabajoId);
    if (p === undefined) {
      lineas.push(`Fase ${r.fase} entró al seguimiento con ${r.progreso.completadas}/${r.progreso.total} tareas.`);
    } else if (p.c !== r.progreso.completadas || p.n !== r.progreso.total) {
      lineas.push(`Fase ${r.fase} avanzó de ${p.c}/${p.n} a ${r.progreso.completadas}/${r.progreso.total}.`);
    }
  }
  return lineas.join(" ");
}

function derivarSiguiente(activas: ResumenSeguimiento[]): string {
  return activas.map((r) => r.siguientePaso).filter((s) => s !== "").join(" ");
}

function derivarNecesita(activas: ResumenSeguimiento[]): string {
  for (const r of activas) {
    if (r.atencionRequerida.necesaria) {
      return r.atencionRequerida.motivo ?? "se necesita tu respuesta";
    }
  }
  return "nada";
}

type AtencionPendiente = { trabajoId: string; fase: string; motivo: string | null };

/** Fases que piden una decisión, en orden estable. Solo cuenta `necesaria: true`. */
function atencionPendiente(activas: ResumenSeguimiento[]): AtencionPendiente[] {
  return activas
    .filter((r) => r.atencionRequerida.necesaria)
    .map((r) => ({ trabajoId: r.trabajoId, fase: r.fase, motivo: r.atencionRequerida.motivo }))
    .sort((a, b) => (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0));
}

function puntuarFinal(s: string): string {
  return /[.?!]$/.test(s) ? s : `${s}.`;
}

/** NECESITO derivado del estado autoritativo, en lenguaje para el propietario. */
function textoAtencion(pendientes: AtencionPendiente[]): string {
  return pendientes.map((p) => {
    const motivo = p.motivo !== null ? sanearTextoPropietario(p.motivo) : null;
    if (motivo !== null) return `Necesito tu respuesta para Fase ${p.fase}: ${puntuarFinal(motivo)}`;
    return `Necesito tu respuesta para Fase ${p.fase}. Tienes una decisión pendiente.`;
  }).join(" ");
}

function palabraMotivo(motivo: ProblemaSeguimiento["motivo"]): string {
  switch (motivo) {
    case "ilegible": return "archivo ilegible";
    case "json-invalido": return "contenido ilegible";
    case "documento-invalido": return "documento inválido";
    default: {
      const nunca: never = motivo;
      return `problema ${JSON.stringify(nunca)}`;
    }
  }
}

function nombreProblema(trabajoId: ProblemaSeguimiento["trabajoId"]): string {
  if (trabajoId.startsWith("corrida:")) return `corrida ${trabajoId.slice("corrida:".length)}`;
  return `Fase ${trabajoId.slice("fase:".length)}`;
}

/**
 * DETENIDA por trabajo ilegible: nombra cada trabajo con su causa en palabras
 * llanas y ordena no retirar el seguimiento hasta verificarlo. Sin rutas,
 * contenido crudo ni jerga: los identificadores salen del nombre del archivo,
 * nunca de su contenido.
 */
function textoProblemas(problemas: ProblemaSeguimiento[]): string {
  const partes = [...problemas]
    .sort((a, b) => (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0))
    .map((p) => `${nombreProblema(p.trabajoId)} (${palabraMotivo(p.motivo)})`);
  const lista = partes.length === 1
    ? partes[0]
    : `${partes.slice(0, -1).join(", ")} y ${partes[partes.length - 1]}`;
  return `No pude leer el avance de ${lista}; no retiro el seguimiento hasta verificarlo.`;
}

export function crearEstadoInicial(ahora: number, activas: ResumenSeguimiento[]): EstadoSeguimiento {
  return {
    schema: SCHEMA_SEGUIMIENTO_CLOCK,
    corte: { kind: "esperando-primer-reporte", inicioVentana: ahora },
    ultimoEstado: resumenEstable(activas, [], null),
    messageId: null,
    trabajosActivos: activas.map((r) => r.trabajoId).sort(),
  };
}

export function decidirSeguimiento(args: EntradaDecision): DecisionSeguimiento {
  const { ahora, previo, activas } = args;
  const sueltas = args.sueltas ?? [];
  const explicito = args.inmediato ?? null;
  const problemas = [...(args.problemas ?? [])]
    .sort((a, b) => (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0));
  const ids = [
    ...activas.map((r) => r.trabajoId),
    ...sueltas.map((s) => `suelta:${s.nombre}`),
  ].sort();

  // Prioridad del inmediato: lo explícito del director (observación fresca),
  // luego la triage de corrupción (el estado no es confiable), luego la
  // atención que el propio resumen pide. Lo derivado entra al resumen
  // estable, así un motivo ya confirmado no se repite y uno nuevo sí sale.
  const pendientes = atencionPendiente(activas);
  const efectivo: EventoInmediato | null = explicito
    ?? (problemas.length > 0
      ? { tipo: "DETENIDA", texto: textoProblemas(problemas) }
      : null)
    ?? (pendientes.length > 0
      ? { tipo: "NECESITO TU RESPUESTA", texto: textoAtencion(pendientes) }
      : null);

  if (efectivo !== null) {
    const dig = resumenEstable(activas, sueltas, efectivo);
    if (dig === previo.ultimoEstado) {
      return { accion: "NO_REPLY", estado: { ...previo, trabajosActivos: ids } };
    }
    return {
      accion: "SEND",
      tipo: "inmediato",
      mensaje: efectivo.texto,
      estadoTrasConfirmar: {
        schema: SCHEMA_SEGUIMIENTO_CLOCK,
        corte: previo.corte,
        ultimoEstado: dig,
        trabajosActivos: ids,
      },
    };
  }

  if (activas.length === 0 && sueltas.length === 0) {
    return { accion: "NO_REPLY", estado: { ...previo, trabajosActivos: [] } };
  }

  switch (previo.corte.kind) {
    case "esperando-primer-reporte":
    case "reporte-confirmado":
      break;
    default: {
      const nunca: never = previo.corte;
      throw new Error(`seguimiento-clock: corte desconocido (${JSON.stringify(nunca)})`);
    }
  }

  if (ahora - inicioVentanaDe(previo.corte) >= VENTANA_REPORTE_SECS) {
    const mensaje = renderSeguimientoV2({
      fases: activas,
      tareasSueltas: sueltas,
      ahora: ahora * 1000,
      cambio: derivarCambio(previo.ultimoEstado, activas),
      siguiente: derivarSiguiente(activas),
      necesita: derivarNecesita(activas),
    });
    return {
      accion: "SEND",
      tipo: "periodico",
      mensaje,
      estadoTrasConfirmar: {
        schema: SCHEMA_SEGUIMIENTO_CLOCK,
        corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: ahora },
        ultimoEstado: resumenEstable(activas, sueltas, null),
        trabajosActivos: ids,
      },
    };
  }

  return { accion: "NO_REPLY", estado: { ...previo, trabajosActivos: ids } };
}

/**
 * Angosta el scratch de la automatización sin fabricar tipos con `as`: lo
 * que falta o no casa (incluida una versión desconocida) lanza, y el modo
 * `tick` del RPC lo convierte en `estado-invalido` en vez de reiniciar el
 * corte en silencio.
 */
export function parseEstadoSeguimiento(raw: unknown): EstadoSeguimiento {
  const invalido = "seguimiento-clock: estado-invalido en el scratch";
  if (!esObjeto(raw)) throw new Error(invalido);
  if (raw["schema"] !== SCHEMA_SEGUIMIENTO_CLOCK) throw new Error(invalido);
  const corteRaw = raw["corte"];
  if (!esObjeto(corteRaw)) throw new Error(invalido);
  let corte: CorteSeguimiento;
  if (corteRaw["kind"] === "esperando-primer-reporte" && esNumeroFinito(corteRaw["inicioVentana"])) {
    corte = { kind: "esperando-primer-reporte", inicioVentana: corteRaw["inicioVentana"] };
  } else if (corteRaw["kind"] === "reporte-confirmado" && esNumeroFinito(corteRaw["ultimoReporteConfirmado"])) {
    corte = { kind: "reporte-confirmado", ultimoReporteConfirmado: corteRaw["ultimoReporteConfirmado"] };
  } else {
    throw new Error(invalido);
  }
  const ultimoEstado = raw["ultimoEstado"];
  if (typeof ultimoEstado !== "string") throw new Error(invalido);
  const messageId = raw["messageId"];
  if (messageId !== null && !(typeof messageId === "number" && Number.isInteger(messageId) && messageId > 0)) {
    throw new Error(invalido);
  }
  const trabajos = raw["trabajosActivos"];
  if (!Array.isArray(trabajos) || trabajos.some((t) => typeof t !== "string")) {
    throw new Error(invalido);
  }
  return {
    schema: SCHEMA_SEGUIMIENTO_CLOCK,
    corte,
    ultimoEstado,
    messageId,
    trabajosActivos: trabajos.filter((t): t is string => typeof t === "string"),
  };
}

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
import { renderSeguimientoV2, sanearTextoPropietario, validarMensajeV1, type TareaSuelta } from "./seguimiento-render.ts";

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
  ultimoInmediato: { firma: string; messageId: number | null } | null;
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

/** NECESITO derivado del estado autoritativo, en seguimiento.v1 exacto. */
function textoAtencion(pendientes: AtencionPendiente[], activas: ResumenSeguimiento[]): string {
  const primera = pendientes[0];
  const doc = activas.find((r) => r.trabajoId === primera.trabajoId);
  const avance = doc !== undefined && doc.progreso.kind === "conocido"
    ? `${doc.progreso.completadas} de ${doc.progreso.total} partes terminadas`
    : "avance desconocido";
  const necesita = pendientes.map((p) => {
    const motivo = p.motivo !== null ? sanearTextoPropietario(p.motivo) : null;
    return motivo !== null ? puntuarFinal(motivo) : "Tienes una decisión pendiente.";
  }).join(" ");
  return [
    `[NECESITO TU RESPUESTA] Corrida, ${avance}`,
    `Que cambio: La fase ${primera.fase} llegó a una decisión que no está preaprobada.`,
    "Que sigue: El trabajo espera tu respuesta antes de continuar.",
    `Que necesito de ti: ${necesita}`,
  ].join("\n");
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
 * DETENIDA por trabajo ilegible, en seguimiento.v1 exacto: nombra cada
 * trabajo con su causa en palabras llanas y ordena no retirar el seguimiento
 * hasta verificarlo. Sin rutas, contenido crudo ni jerga: los identificadores
 * salen del nombre del archivo, nunca de su contenido. El avance es
 * desconocido por definición: jamás se inventa un conteo.
 */
function textoProblemas(problemas: ProblemaSeguimiento[]): string {
  const partes = [...problemas]
    .sort((a, b) => (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0))
    .map((p) => `${nombreProblema(p.trabajoId)} (${palabraMotivo(p.motivo)})`);
  const lista = partes.length === 1
    ? partes[0]
    : `${partes.slice(0, -1).join(", ")} y ${partes[partes.length - 1]}`;
  return [
    "[DETENIDA] Corrida, avance desconocido",
    `Que cambio: No pude leer el avance de ${lista}.`,
    "Que sigue: Reviso el registro y aviso cuando esté verificado.",
    "Que necesito de ti: nada por ahora; no retires el seguimiento hasta verificarlo.",
  ].join("\n");
}

export function crearEstadoInicial(
  ahora: number,
  activas: ResumenSeguimiento[],
  sueltas: TareaSuelta[] = [],
): EstadoSeguimiento {
  const ids = [
    ...activas.map((r) => r.trabajoId),
    ...sueltas.map((s) => `suelta:${s.nombre}`),
  ].sort();
  return {
    schema: SCHEMA_SEGUIMIENTO_CLOCK,
    corte: { kind: "esperando-primer-reporte", inicioVentana: ahora },
    ultimoEstado: resumenEstable(activas, sueltas, null),
    ultimoInmediato: null,
    messageId: null,
    trabajosActivos: ids,
  };
}

/** Firma estable de la condición inmediata tratada: lo explícito por texto, lo derivado por causa. */
function firmaInmediato(
  explicito: EventoInmediato | null,
  problemas: ProblemaSeguimiento[],
  pendientes: AtencionPendiente[],
): string | null {
  if (explicito !== null) return `e:${explicito.tipo}:${explicito.texto}`;
  if (problemas.length > 0) {
    return `p:${problemas.map((p) => `${p.trabajoId}:${p.motivo}`).join("|")}`;
  }
  if (pendientes.length > 0) {
    return `n:${pendientes.map((p) => `${p.trabajoId}:${p.motivo}`).join("|")}`;
  }
  return null;
}

function componerInmediato(
  problemas: ProblemaSeguimiento[],
  pendientes: AtencionPendiente[],
  activas: ResumenSeguimiento[],
): EventoInmediato | null {
  if (problemas.length > 0) {
    return { tipo: "DETENIDA", texto: textoProblemas(problemas) };
  }
  if (pendientes.length > 0) {
    return { tipo: "NECESITO TU RESPUESTA", texto: textoAtencion(pendientes, activas) };
  }
  return null;
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
  // atención que el propio resumen pide. El corte periódico y la condición
  // inmediata tratada viven en campos separados: confirmar uno nunca borra
  // ni bloquea al otro, así un inmediato confirmado no silencia el próximo
  // corte debido.
  const pendientes = atencionPendiente(activas);
  const derivado = explicito === null ? componerInmediato(problemas, pendientes, activas) : null;
  const efectivo = explicito ?? derivado;
  if (efectivo !== null) {
    if (explicito !== null) {
      const v1 = validarMensajeV1(efectivo.texto);
      if (!v1.ok || v1.etiqueta !== efectivo.tipo) {
        throw new Error("decidirSeguimiento: inmediato explícito inválido");
      }
    } else {
      const v1 = validarMensajeV1(efectivo.texto);
      if (!v1.ok || v1.etiqueta !== efectivo.tipo) {
        throw new Error("decidirSeguimiento: inmediato derivado inválido");
      }
    }
    const firma = firmaInmediato(explicito, problemas, pendientes);
    const ya = previo.ultimoInmediato;
    // El scratch solo se persiste tras entrega confirmada, así que una firma
    // presente ya fue entregada; exigir además el messageId anidado repetiría
    // el aviso en cada tick, porque el contrato público solo llena el
    // messageId del nivel superior y el anidado queda informativo.
    if (ya === null || ya.firma !== firma) {
      return {
        accion: "SEND",
        tipo: "inmediato",
        mensaje: efectivo.texto,
        estadoTrasConfirmar: {
          schema: SCHEMA_SEGUIMIENTO_CLOCK,
          corte: previo.corte,
          ultimoEstado: previo.ultimoEstado,
          ultimoInmediato: { firma: firma ?? "", messageId: null },
          trabajosActivos: ids,
        },
      };
    }
    // Ya entregado y confirmado: no se repite, pero tampoco silencia el
    // corte periódico que pueda estar debido. Sigue abajo.
  }

  // Sin condición inmediata activa se registra inactiva; con condición ya
  // tratada se conserva pendiente.
  const sinCondicion = efectivo === null;
  const silencio = (): EstadoSeguimiento => ({
    ...previo,
    trabajosActivos: ids,
    ultimoInmediato: sinCondicion ? null : previo.ultimoInmediato,
  });

  if (activas.length === 0 && sueltas.length === 0) {
    return { accion: "NO_REPLY", estado: silencio() };
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
        // Regla del spec: la condición desaparecida se registra inactiva
        // (null); si vuelve, es un evento nuevo y sale otra vez.
        ultimoInmediato: sinCondicion ? null : previo.ultimoInmediato,
        trabajosActivos: ids,
      },
    };
  }

  return { accion: "NO_REPLY", estado: silencio() };
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
  // Sin despliegue vivo anterior, el scratch viejo no trae ultimoInmediato:
  // ausente vale null. Presente, debe traer firma y messageId válidos.
  let ultimoInmediato: EstadoSeguimiento["ultimoInmediato"] = null;
  const inmediatoRaw = raw["ultimoInmediato"];
  if (inmediatoRaw !== undefined && inmediatoRaw !== null) {
    if (!esObjeto(inmediatoRaw) || typeof inmediatoRaw["firma"] !== "string") {
      throw new Error(invalido);
    }
    const mid = inmediatoRaw["messageId"];
    if (mid !== null && !(typeof mid === "number" && Number.isInteger(mid) && mid > 0)) {
      throw new Error(invalido);
    }
    ultimoInmediato = { firma: inmediatoRaw["firma"], messageId: mid };
  }
  return {
    schema: SCHEMA_SEGUIMIENTO_CLOCK,
    corte,
    ultimoEstado,
    ultimoInmediato,
    messageId,
    trabajosActivos: trabajos.filter((t): t is string => typeof t === "string"),
  };
}

/**
 * tablero-runbook/seguimiento-clock.ts — reloj 15 del seguimiento, reporte
 * periodico en la cuadrícula de 15 minutos.
 *
 * La vigilancia interna corre cada 15 minutos; el Telegram consolidado sale
 * en esa cuadrícula, como mucho uno por ventana de 25 minutos (R12) y solo
 * si hay novedad desde el último corte enviado (o un latido cada 4 horas):
 * en cuadrícula sana el primer tick que cumple la ventana es el de +1800, y
 * un tick desfasado del cron que caiga entre 1500 y 1800 también la cumple. `decidirSeguimiento` es puro: nunca llama a Telegram, al disco ni
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
import { nombreCuerpo, nombreEncabezado, renderSeguimientoV2, sanearTextoPropietario, tieneMarcadorReservado, validarMensajeV1, type TareaSuelta } from "./seguimiento-render.ts";

export const SCHEMA_SEGUIMIENTO_CLOCK = "seguimiento-clock.v1";

/**
 * Ventana de 25 minutos para el reporte periodico (R12: tolerancia de desfase
 * del cron de 15 min — un tick que caiga entre 1500 y 1800 desde el corte
 * ahora envía; el primer tick de cuadrícula que la cumple es +1800, y eliminar
 * el doble mensaje con el latido es otra decisión, no de esta constante); la
 * vigilancia interna corre cada 15.
 * El `ahora` de este módulo es época en SEGUNDOS (el RPC convierte los ms de
 * `Date.now` en la frontera): los ticks del plan se escriben 900/1800 y el
 * scratch guarda segundos.
 */
export const VENTANA_REPORTE_SECS = 1500;

/**
 * Un documento cuyo `actualizado` tiene más de un día sale del reporte
 * periódico y se pregunta UNA vez si sigue vivo. Medido el 2026-09-29: la
 * Fase 9 quedó sin cierre y salió 11 días seguidos como avance desconocido.
 */
export const RANCIO_SECS = 86400;

/**
 * Sin novedad el corte no sale: a David le llega solo lo que cambió. Cada 4
 * horas sale igual un latido, para que el silencio no se confunda con un
 * reloj muerto. Medido el 2026-10-07: el corte salía cada 30 minutos sin
 * cambio alguno.
 */
export const LATIDO_SIN_NOVEDAD_SECS = 14400;

export type CorteSeguimiento =
  | { kind: "esperando-primer-reporte"; inicioVentana: number }
  | { kind: "reporte-confirmado"; ultimoReporteConfirmado: number };

export type EstadoSeguimiento = {
  schema: "seguimiento-clock.v1";
  corte: CorteSeguimiento;
  ultimoEstado: string;
  /**
   * `entregados`: una firma por pendiente ya avisado. Ausente en un scratch
   * anterior a la firma por pendiente, donde `firma` era la del conjunto.
   */
  ultimoInmediato: { firma: string; messageId: number | null; entregados?: string[] } | null;
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

type ResumenDigest = { t: string; f: string; c: number; n: number; p: number | null; x?: string[]; q?: boolean };

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

function digestSueltas(sueltas: TareaSuelta[]): ResumenDigest[] {
  return sueltas.map((t) => {
    const d = digestConteo(t.progreso);
    return { t: `suelta:${t.nombre}`, f: "", c: d.c, n: d.n, p: d.p };
  }).sort((x, y) => (x.t < y.t ? -1 : x.t > y.t ? 1 : 0));
}

/**
 * Resumen estable del corte: por trabajo, sus conteos, sus partes atoradas y
 * si pide atención (las sueltas van con su nombre). Es lo que se compara
 * contra el último corte enviado para saber si hay novedad.
 */
function resumenEstable(
  activas: ResumenSeguimiento[],
  sueltas: TareaSuelta[],
  inmediato: EventoInmediato | null,
): string {
  const a: ResumenDigest[] = activas.map((r) => {
    const d = digestConteo(r.progreso);
    const x = r.carriles.filter((c) => c.estado === "atorado").map((c) => c.id).sort();
    return { t: r.trabajoId, f: r.fase, c: d.c, n: d.n, p: d.p, x, q: r.atencionRequerida.necesaria };
  }).sort((x, y) => (x.t < y.t ? -1 : x.t > y.t ? 1 : 0));
  return JSON.stringify({
    a,
    s: digestSueltas(sueltas),
    i: inmediato === null ? null : { tipo: inmediato.tipo, texto: inmediato.texto },
  });
}

type DigestPrevio = { c: number; n: number; x: string[] | null; q: boolean | null };

function leerResumen(previo: string): { trabajos: Map<string, DigestPrevio>; sueltas: string } | null {
  try {
    const d: unknown = JSON.parse(previo);
    if (!esObjeto(d) || !Array.isArray(d["a"])) return null;
    const trabajos = new Map<string, DigestPrevio>();
    for (const e of d["a"]) {
      if (!esObjeto(e)) continue;
      const t = e["t"];
      const c = e["c"];
      const n = e["n"];
      if (typeof t !== "string" || typeof c !== "number" || typeof n !== "number") continue;
      const x = e["x"];
      const q = e["q"];
      trabajos.set(t, {
        c,
        n,
        x: Array.isArray(x) ? x.filter((v): v is string => typeof v === "string") : null,
        q: typeof q === "boolean" ? q : null,
      });
    }
    return { trabajos, sueltas: JSON.stringify(d["s"] ?? []) };
  } catch {
    return null;
  }
}

function cuantas(n: number, una: string, varias: string): string {
  return n === 1 ? una : `${n} ${varias}`;
}

/**
 * Novedades desde el último corte enviado, en frases fijas armadas con
 * conteos y estados: nunca con texto libre de un agente. `null` cuando el
 * estado guardado no se puede comparar (scratch viejo o ilegible).
 */
function novedadesDesde(
  ultimoEstado: string,
  vivas: ResumenSeguimiento[],
  sueltas: TareaSuelta[],
): string[] | null {
  const previo = leerResumen(ultimoEstado);
  if (previo === null) return null;
  const frases: string[] = [];
  const presentes = new Set<string>();
  for (const r of vivas) {
    presentes.add(r.trabajoId);
    const nombre = nombreCuerpo(r);
    const p = previo.trabajos.get(r.trabajoId);
    if (p === undefined) {
      frases.push(`${nombre} entró al seguimiento.`);
      continue;
    }
    if (r.progreso.kind === "conocido") {
      const { completadas, total } = r.progreso;
      if (completadas > p.c && total === p.n) {
        const singular = r.unidad === "partes" ? "una parte" : "una tarea";
        frases.push(`${nombre} terminó ${cuantas(completadas - p.c, singular, r.unidad)}.`);
      } else if (completadas !== p.c || total !== p.n) {
        frases.push(`${nombre} cambió su cuenta: ahora van ${completadas} de ${total} ${r.unidad}.`);
      }
    }
    const atoradasAntes = p.x;
    if (atoradasAntes !== null) {
      const atoradas = r.carriles.filter((c) => c.estado === "atorado").map((c) => c.id);
      const nuevas = atoradas.filter((id) => !atoradasAntes.includes(id)).length;
      const sueltasYa = atoradasAntes.filter((id) => !atoradas.includes(id)).length;
      if (nuevas > 0) frases.push(`${nombre} tiene ${cuantas(nuevas, "una parte atorada", "partes atoradas")}.`);
      if (sueltasYa > 0) frases.push(`${nombre} destrabó ${cuantas(sueltasYa, "una parte", "partes")}.`);
    }
    if (p.q !== null && p.q !== r.atencionRequerida.necesaria) {
      frases.push(r.atencionRequerida.necesaria
        ? `${nombre} necesita tu respuesta.`
        : `${nombre} ya no necesita tu respuesta.`);
    }
  }
  const salieron = [...previo.trabajos.keys()].filter((t) => !presentes.has(t)).length;
  if (salieron > 0) {
    frases.push(salieron === 1 ? "Un trabajo salió del seguimiento." : `${salieron} trabajos salieron del seguimiento.`);
  }
  if (JSON.stringify(digestSueltas(sueltas)) !== previo.sueltas) {
    frases.push("Cambiaron las tareas sueltas.");
  }
  return frases;
}

function derivarNecesita(activas: ResumenSeguimiento[]): string {
  for (const r of activas) {
    if (r.atencionRequerida.necesaria) {
      return r.atencionRequerida.motivo ?? "se necesita tu respuesta";
    }
  }
  return "nada";
}

type AtencionPendiente = { trabajoId: string; fase: string; motivo: string | null; rancia: boolean };

const MESES = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
];

/** Una fecha ilegible cuenta como rancia: no hay forma de saber que se mueve. */
function partirPorFrescura(
  activas: ResumenSeguimiento[],
  ahora: number,
  problemas: ProblemaSeguimiento[],
): { vivas: ResumenSeguimiento[]; rancias: ResumenSeguimiento[] } {
  // El resumen conservador de un documento ilegible trae `actualizado` vacío;
  // ese trabajo ya sale como DETENIDA y sigue en el reporte como desconocido.
  const conProblema = new Set<string>(problemas.map((p) => p.trabajoId));
  const vivas: ResumenSeguimiento[] = [];
  const rancias: ResumenSeguimiento[] = [];
  for (const r of activas) {
    const ms = Date.parse(r.actualizado);
    const rancia = !conProblema.has(r.trabajoId) && (!Number.isFinite(ms) || ahora - ms / 1000 > RANCIO_SECS);
    (rancia ? rancias : vivas).push(r);
  }
  return { vivas, rancias };
}

/** Motivo estable entre ticks (fecha, no "hace N horas") para que la firma no cambie. */
function motivoRancio(r: ResumenSeguimiento): string {
  const nombre = r.trabajoId.startsWith("corrida:") ? nombreCuerpo(r) : `La Fase ${r.fase}`;
  const ms = Date.parse(r.actualizado);
  if (!Number.isFinite(ms)) return `${nombre} no registra avance: ¿sigue viva o la cierro?`;
  const d = new Date(ms);
  return `${nombre} no se mueve desde el ${d.getUTCDate()} de ${MESES[d.getUTCMonth()]}: ¿sigue viva o la cierro?`;
}

/** Fases que piden una decisión, en orden estable: las que la piden y las rancias. */
function atencionPendiente(vivas: ResumenSeguimiento[], rancias: ResumenSeguimiento[]): AtencionPendiente[] {
  return [
    ...vivas
      .filter((r) => r.atencionRequerida.necesaria)
      .map((r) => ({ trabajoId: r.trabajoId, fase: r.fase, motivo: r.atencionRequerida.motivo, rancia: false })),
    ...rancias.map((r) => ({ trabajoId: r.trabajoId, fase: r.fase, motivo: motivoRancio(r), rancia: true })),
  ].sort((a, b) => (a.trabajoId < b.trabajoId ? -1 : a.trabajoId > b.trabajoId ? 1 : 0));
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
    const motivo = p.motivo !== null && !tieneMarcadorReservado(p.motivo) ? sanearTextoPropietario(p.motivo) : null;
    return motivo !== null ? puntuarFinal(motivo) : "Tienes una decisión pendiente.";
  }).join(" ");
  const esCorrida = doc !== undefined && primera.trabajoId.startsWith("corrida:");
  const quien = esCorrida ? nombreCuerpo(doc) : `La fase ${primera.fase}`;
  // La línea 1 exige "N de M partes" (seguimiento.v1) sea cual sea la unidad.
  return [
    `[NECESITO TU RESPUESTA] ${esCorrida ? nombreEncabezado(doc) : "Corrida"}, ${avance}`,
    primera.rancia
      ? `Que cambio: ${quien} lleva más de un día sin avance.`
      : `Que cambio: ${quien} llegó a una decisión que no está preaprobada.`,
    primera.rancia
      ? "Que sigue: Queda fuera del reporte periódico hasta que se cierre o vuelva a moverse."
      : "Que sigue: El trabajo espera tu respuesta antes de continuar.",
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

/** Firma de un pendiente: un trabajo rancio se pregunta una vez, diga lo que diga su fecha. */
function firmaPendiente(p: AtencionPendiente): string {
  return p.rancia ? `${p.trabajoId}:rancia` : `${p.trabajoId}:${p.motivo ?? ""}`;
}

/**
 * Pendientes ya avisados. Un scratch anterior a la firma por pendiente solo
 * trae la firma del conjunto: si es la del conjunto de hoy, todo él cuenta
 * como avisado.
 */
function pendientesEntregados(
  ya: EstadoSeguimiento["ultimoInmediato"],
  pendientes: AtencionPendiente[],
): string[] {
  if (ya === null) return [];
  const actuales = pendientes.map(firmaPendiente);
  if (ya.entregados !== undefined) return ya.entregados.filter((f) => actuales.includes(f));
  return ya.firma === firmaInmediato(null, [], pendientes) ? actuales : [];
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
  const { vivas, rancias } = partirPorFrescura(activas, ahora, problemas);
  const pendientes = atencionPendiente(vivas, rancias);
  const soloPendientes = explicito === null && problemas.length === 0;
  // Con solo atención pendiente, el aviso lleva lo que falta avisar: lo ya
  // entregado no vuelve a salir porque otro pendiente aparezca o cambie.
  const entregados = soloPendientes ? pendientesEntregados(previo.ultimoInmediato, pendientes) : [];
  const porAvisar = soloPendientes
    ? pendientes.filter((p) => !entregados.includes(firmaPendiente(p)))
    : pendientes;
  const derivado = explicito === null ? componerInmediato(problemas, porAvisar, activas) : null;
  const efectivo = explicito ?? derivado;
  const firma = firmaInmediato(explicito, problemas, pendientes);
  if (efectivo !== null) {
    const v1 = validarMensajeV1(efectivo.texto);
    if (!v1.ok || v1.etiqueta !== efectivo.tipo) {
      throw new Error(`decidirSeguimiento: inmediato ${explicito !== null ? "explícito" : "derivado"} inválido`);
    }
    const ya = previo.ultimoInmediato;
    // El scratch solo se persiste tras entrega confirmada, así que una firma
    // presente ya fue entregada; exigir además el messageId anidado repetiría
    // el aviso en cada tick, porque el contrato público solo llena el
    // messageId del nivel superior y el anidado queda informativo.
    if (soloPendientes || ya === null || ya.firma !== firma) {
      return {
        accion: "SEND",
        tipo: "inmediato",
        mensaje: efectivo.texto,
        estadoTrasConfirmar: {
          schema: SCHEMA_SEGUIMIENTO_CLOCK,
          corte: previo.corte,
          ultimoEstado: previo.ultimoEstado,
          // Otro aviso (explícito o de corrupción) no borra lo ya avisado
          // de la atención: si no, se repetiría al volver a ser lo único.
          ultimoInmediato: soloPendientes
            ? { firma: firma ?? "", messageId: null, entregados: pendientes.map(firmaPendiente) }
            : ya?.entregados !== undefined
              ? { firma: firma ?? "", messageId: null, entregados: ya.entregados }
              : { firma: firma ?? "", messageId: null },
          trabajosActivos: ids,
        },
      };
    }
    // Ya entregado y confirmado: no se repite, pero tampoco silencia el
    // corte periódico que pueda estar debido. Sigue abajo.
  }

  // Sin condición inmediata activa se registra inactiva; con condición ya
  // tratada se conserva pendiente. Un pendiente que desapareció sale de la
  // lista de avisados: si vuelve, es un evento nuevo.
  const sinCondicion = explicito === null && problemas.length === 0 && pendientes.length === 0;
  const inmediatoVigente: EstadoSeguimiento["ultimoInmediato"] = sinCondicion
    ? null
    : soloPendientes
      ? { firma: firma ?? "", messageId: previo.ultimoInmediato?.messageId ?? null, entregados }
      : previo.ultimoInmediato;
  const silencio = (): EstadoSeguimiento => ({
    ...previo,
    trabajosActivos: ids,
    ultimoInmediato: inmediatoVigente,
  });

  if (vivas.length === 0 && sueltas.length === 0) {
    return { accion: "NO_REPLY", estado: silencio() };
  }

  let primerCorte: boolean;
  switch (previo.corte.kind) {
    case "esperando-primer-reporte":
      primerCorte = true;
      break;
    case "reporte-confirmado":
      primerCorte = false;
      break;
    default: {
      const nunca: never = previo.corte;
      throw new Error(`seguimiento-clock: corte desconocido (${JSON.stringify(nunca)})`);
    }
  }

  const desdeElCorte = ahora - inicioVentanaDe(previo.corte);
  if (desdeElCorte < VENTANA_REPORTE_SECS) {
    return { accion: "NO_REPLY", estado: silencio() };
  }

  // El primer corte y el de un estado que no se puede comparar salen siempre.
  // Después solo sale lo que trae novedad; sin ella, un latido cada 4 horas.
  const comparadas = novedadesDesde(previo.ultimoEstado, vivas, sueltas);
  let novedades: string[];
  if (primerCorte) {
    novedades = comparadas !== null && comparadas.length > 0 ? comparadas : ["Empezó el seguimiento."];
  } else if (comparadas === null) {
    novedades = ["Estado actual del trabajo."];
  } else if (comparadas.length > 0) {
    novedades = comparadas;
  } else if (desdeElCorte >= LATIDO_SIN_NOVEDAD_SECS) {
    novedades = [];
  } else {
    return { accion: "NO_REPLY", estado: silencio() };
  }

  return {
    accion: "SEND",
    tipo: "periodico",
    mensaje: renderSeguimientoV2({
      fases: vivas,
      tareasSueltas: sueltas,
      ahora: ahora * 1000,
      novedades,
      necesita: derivarNecesita(vivas),
    }),
    estadoTrasConfirmar: {
      schema: SCHEMA_SEGUIMIENTO_CLOCK,
      corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: ahora },
      ultimoEstado: resumenEstable(vivas, sueltas, null),
      ultimoInmediato: inmediatoVigente,
      trabajosActivos: ids,
    },
  };
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
    const entregados = inmediatoRaw["entregados"];
    if (entregados !== undefined && !(Array.isArray(entregados) && entregados.every((f) => typeof f === "string"))) {
      throw new Error(invalido);
    }
    ultimoInmediato = entregados === undefined
      ? { firma: inmediatoRaw["firma"], messageId: mid }
      : { firma: inmediatoRaw["firma"], messageId: mid, entregados: entregados.filter((f): f is string => typeof f === "string") };
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

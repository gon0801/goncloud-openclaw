/**
 * seguimiento-clock.test.ts — máquina de estados 15/30 (`seguimiento-clock.v1`).
 *
 * TDD rojo-primero: este archivo se escribió ANTES de `seguimiento-clock.ts`.
 * Dos ticks de 15 minutos producen como máximo un Telegram periódico; un
 * permiso, una caída o un cierre salen de inmediato sin duplicar el reporte
 * de rutina. El corte confirmado solo avanza con `ok:true` más `messageId`.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ResumenSeguimiento } from "./seguimiento.ts";
import {
  crearEstadoInicial,
  decidirSeguimiento,
  parseEstadoSeguimiento,
  type EstadoSeguimiento,
  type EstadoTrasConfirmar,
  type EventoInmediato,
  type ProblemaSeguimiento,
} from "./seguimiento-clock.ts";

function resumen14(completadas: number, total: number, porcentaje: number): ResumenSeguimiento {
  return {
    trabajoId: "fase:14",
    fase: "14",
    titulo: "Fase 14",
    progreso: { kind: "conocido", completadas, total, porcentaje },
    carriles: [
      {
        id: "M",
        nombre: "Implementación",
        estado: "implementando",
        progreso: { kind: "conocido", completadas, total, porcentaje },
        actividad: {
          detalle: "Muse está corrigiendo el último caso del vigilante.",
          iniciadaEn: "2026-09-19T10:20:00Z",
          ultimaEvidencia: "el caso del vigilante quedó en verde local",
        },
      },
    ],
    siguientePaso: "Terminar la corrección y comenzar la revisión.",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: "2026-09-19T10:30:00Z",
  };
}

function resumen15(): ResumenSeguimiento {
  return {
    trabajoId: "fase:15",
    fase: "15",
    titulo: "Fase 15",
    progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
    carriles: [
      {
        id: "A",
        nombre: "Trabajo",
        estado: "implementando",
        progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
        actividad: {
          detalle: "Avance en curso.",
          iniciadaEn: "2026-09-19T10:00:00Z",
          ultimaEvidencia: "evidencia reciente",
        },
      },
    ],
    siguientePaso: "Cerrar el pendiente.",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: "2026-09-19T10:30:00Z",
  };
}

function resumenAtencion(motivo: string | null): ResumenSeguimiento {
  const base = resumen14(1, 4, 25);
  return { ...base, atencionRequerida: { necesaria: true, motivo } };
}

function corteEn(ultimoReporteConfirmado: number, activas: ResumenSeguimiento[]): EstadoSeguimiento {
  return {
    ...crearEstadoInicial(ultimoReporteConfirmado, activas),
    corte: { kind: "reporte-confirmado", ultimoReporteConfirmado },
  };
}

const V1_DETENIDA = "[DETENIDA] Corrida, 1 de 4 partes terminadas\nQue cambio: algo material\nQue sigue: sigue igual\nQue necesito de ti: nada.";
const V1_NECESITO = "[NECESITO TU RESPUESTA] Corrida, 1 de 4 partes terminadas\nQue cambio: algo material\nQue sigue: sigue igual\nQue necesito de ti: responde.";
const V1_CERRADA = "[CERRADA] Corrida, cierre en palabras\nQue cambio: x\nQue sigue: y\nQue necesito de ti: nada.";

/**
 * Contrato público (spec seguimiento.v2 l.111): quien llama combina
 * `estadoTrasConfirmar` SOLO con el `messageId` del nivel superior. El
 * `messageId` anidado de `ultimoInmediato` queda informativo y nadie fuera
 * de los tests lo escribe: este helper simula al llamador real.
 */
function confirmado(estadoTrasConfirmar: EstadoTrasConfirmar, messageId: number): EstadoSeguimiento {
  const estado: EstadoSeguimiento = { ...estadoTrasConfirmar, messageId };
  return estado;
}

describe("decidirSeguimiento", () => {
  it("dispatch state stays silent at 15 minutes and sends at 30", () => {
    const activas = [resumen14(1, 4, 25)];
    const previo = crearEstadoInicial(0, activas);
    const primero = decidirSeguimiento({ ahora: 900, previo, activas, inmediato: null });
    assert.equal(primero.accion, "NO_REPLY");
    if (primero.accion !== "NO_REPLY") throw new Error("tick 1 inesperado");
    const segundo = decidirSeguimiento({ ahora: 1800, previo: primero.estado, activas, inmediato: null });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("tick 2 inesperado");
    assert.equal(segundo.tipo, "periodico");
  });

  it("a failed delivery does not advance the confirmed cut", () => {
    const activas = [resumen14(1, 4, 25)];
    const d1 = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, activas), activas, inmediato: null });
    const d2 = decidirSeguimiento({ ahora: 2700, previo: corteEn(0, activas), activas, inmediato: null });
    assert.equal(d1.accion, "SEND");
    assert.equal(d2.accion, "SEND");
  });

  it("immediate decisions bypass the periodic cut", () => {
    const activas = [resumen14(1, 4, 25)];
    const inmediato: EventoInmediato = { tipo: "NECESITO TU RESPUESTA", texto: V1_NECESITO };
    const d = decidirSeguimiento({ ahora: 901, previo: corteEn(900, activas), activas, inmediato });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("inmediato inesperado");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, V1_NECESITO);
  });

  it("a restart from confirmed scratch sends at most once per two ticks", () => {
    const activas = [resumen14(1, 4, 25)];
    const previo = corteEn(0, activas);
    const primero = decidirSeguimiento({ ahora: 900, previo, activas, inmediato: null });
    assert.equal(primero.accion, "NO_REPLY");
    if (primero.accion !== "NO_REPLY") throw new Error("tick tras reinicio inesperado");
    const segundo = decidirSeguimiento({ ahora: 1800, previo: primero.estado, activas, inmediato: null });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("corte tras reinicio inesperado");
    assert.equal(segundo.tipo, "periodico");
  });

  it("DETENIDA and CERRADA also bypass the periodic cut", () => {
    const activas = [resumen14(1, 4, 25)];
    for (const [tipo, texto] of [["DETENIDA", V1_DETENIDA], ["CERRADA", V1_CERRADA]] as const) {
      const d = decidirSeguimiento({
        ahora: 901, previo: corteEn(900, activas), activas,
        inmediato: { tipo, texto },
      });
      assert.equal(d.accion, "SEND");
      if (d.accion !== "SEND") throw new Error(`${tipo} inesperado`);
      assert.equal(d.tipo, "inmediato");
      assert.equal(d.mensaje, texto);
    }
  });

  it("a repeated identical immediate is not sent twice", () => {
    const activas = [resumen14(1, 4, 25)];
    const inmediato: EventoInmediato = { tipo: "DETENIDA", texto: V1_DETENIDA };
    const primero = decidirSeguimiento({ ahora: 901, previo: corteEn(900, activas), activas, inmediato });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer inmediato inesperado");
    const previo = confirmado(primero.estadoTrasConfirmar, 41);
    const segundo = decidirSeguimiento({ ahora: 902, previo, activas, inmediato });
    assert.equal(segundo.accion, "NO_REPLY");
  });

  it("a confirmed periodic send advances the cut; an immediate preserves it", () => {
    const activas = [resumen14(1, 4, 25)];
    const per = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, activas), activas, inmediato: null });
    assert.equal(per.accion, "SEND");
    if (per.accion !== "SEND") throw new Error("periodico inesperado");
    assert.deepEqual(per.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 1800 });
    const inm = decidirSeguimiento({
      ahora: 1900, previo: corteEn(1800, activas), activas,
      inmediato: { tipo: "NECESITO TU RESPUESTA", texto: V1_NECESITO },
    });
    assert.equal(inm.accion, "SEND");
    if (inm.accion !== "SEND") throw new Error("inmediato inesperado");
    assert.deepEqual(inm.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 1800 });
  });

  it("closing one phase removes it from the next cut without moving the due report", () => {
    const catorce = resumen14(2, 4, 50);
    const quince = resumen15();
    const previo = corteEn(0, [catorce, quince]);
    // Cierra la 14: el siguiente corte periódico solo trae la 15, y como el
    // corte confirmado sigue en 0, el reporte ya debido no se pospone.
    const d = decidirSeguimiento({ ahora: 1800, previo, activas: [quince], inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("corte tras cierre inesperado");
    assert.match(d.mensaje, /Fase 15/);
    assert.doesNotMatch(d.mensaje, /Fase 14/);
  });

  it("two phases consolidate into a single message", () => {
    const activas = [resumen14(2, 4, 50), resumen15()];
    const d = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("consolidado inesperado");
    assert.match(d.mensaje, /Fase 14/);
    assert.match(d.mensaje, /Fase 15/);
    assert.equal(d.mensaje.match(/Que cambió:/g)?.length, 1);
  });

  it("with no active work a tick stays silent instead of rendering emptiness", () => {
    const previo = corteEn(0, [resumen14(2, 4, 50)]);
    const d = decidirSeguimiento({ ahora: 1800, previo, activas: [], inmediato: null });
    assert.equal(d.accion, "NO_REPLY");
    if (d.accion !== "NO_REPLY") throw new Error("vacio inesperado");
    assert.deepEqual(d.estado.trabajosActivos, []);
  });

  it("a due cut with changed counts names the advance; unchanged counts confirm continuity", () => {
    const antes = [resumen14(1, 4, 25)];
    const primero = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, antes), activas: antes, inmediato: null });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer corte inesperado");
    const previo = confirmado(primero.estadoTrasConfirmar, 7);
    const despues = [resumen14(2, 4, 50)];
    const segundo = decidirSeguimiento({ ahora: 3600, previo, activas: despues, inmediato: null });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("segundo corte inesperado");
    assert.match(segundo.mensaje, /avanzó de 1\/4 a 2\/4/);
    const tercero = decidirSeguimiento({
      ahora: 5400,
      previo: confirmado(segundo.estadoTrasConfirmar, 8),
      activas: despues,
      inmediato: null,
    });
    assert.equal(tercero.accion, "SEND");
    if (tercero.accion !== "SEND") throw new Error("tercer corte inesperado");
    assert.match(tercero.mensaje, /sigue en curso/);
  });
});

describe("parseEstadoSeguimiento", () => {
  it("round-trips a created state and rejects malformed scratch", () => {
    const estado = crearEstadoInicial(100, [resumen14(1, 4, 25)]);
    assert.deepEqual(parseEstadoSeguimiento(JSON.parse(JSON.stringify(estado))), estado);
    for (const malo of [null, undefined, 42, "x", [], {},
      { ...estado, schema: "otro.v9" },
      { ...estado, corte: { kind: "inexistente" } },
      { ...estado, corte: { kind: "reporte-confirmado" } },
      { ...estado, ultimoEstado: 7 },
      { ...estado, messageId: "siete" },
      { ...estado, trabajosActivos: "fase:14" },
      { ...estado, ultimoInmediato: { firma: 7, messageId: null } },
      { ...estado, ultimoInmediato: { firma: "x", messageId: -1 } },
    ]) {
      assert.throws(() => parseEstadoSeguimiento(malo), /estado/i);
    }
  });

  it("round-trips the immediate field and tolerates scratches without it", () => {
    const estado = crearEstadoInicial(100, [resumen14(1, 4, 25)]);
    const conInmediato = {
      ...estado,
      ultimoInmediato: { firma: "n:fase:14:Elegir", messageId: 9 },
    };
    assert.deepEqual(parseEstadoSeguimiento(JSON.parse(JSON.stringify(conInmediato))), conInmediato);
    const { ultimoInmediato, ...viejo } = conInmediato;
    assert.deepEqual(parseEstadoSeguimiento(viejo).ultimoInmediato, null);
  });
});

describe("estado inicial con sueltas", () => {
  const suelta = {
    nombre: "Suelta",
    progreso: { kind: "conocido", completadas: 0, total: 1, porcentaje: 0 } as const,
    actividad: { detalle: "En curso", iniciadaEn: "2026-09-19T10:00:00Z", ultimaEvidencia: "Comenzó" },
  };

  it("keeps standalone identities and their digest in the initial cut", () => {
    const solo = crearEstadoInicial(50, [], [suelta]);
    assert.deepEqual(solo.trabajosActivos, ["suelta:Suelta"]);
    assert.notEqual(solo.ultimoEstado, crearEstadoInicial(50, []).ultimoEstado);
    const mixto = crearEstadoInicial(50, [resumen14(1, 4, 25)], [suelta]);
    assert.deepEqual(mixto.trabajosActivos, ["fase:14", "suelta:Suelta"]);
  });
});

describe("trabajo ilegible", () => {
  const problemas: ProblemaSeguimiento[] = [{ trabajoId: "fase:14", motivo: "ilegible" }];

  it("an unreadable active work item becomes DETENIDA, never silence", () => {
    const d = decidirSeguimiento({
      ahora: 901, previo: corteEn(900, []), activas: [], problemas,
      inmediato: null,
    });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("ilegible inesperado");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, "[DETENIDA] Corrida, avance desconocido\nQue cambio: No pude leer el avance de Fase 14 (archivo ilegible).\nQue sigue: Reviso el registro y aviso cuando esté verificado.\nQue necesito de ti: nada por ahora; no retires el seguimiento hasta verificarlo.");
    assert.doesNotMatch(d.mensaje, /private|tmp|\.json/);
    assert.deepEqual(d.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 900 });
  });

  it("a confirmed corrupt state does not resend", () => {
    const primero = decidirSeguimiento({
      ahora: 901, previo: corteEn(900, []), activas: [], problemas,
      inmediato: null,
    });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer ilegible inesperado");
    const segundo = decidirSeguimiento({
      ahora: 902, previo: confirmado(primero.estadoTrasConfirmar, 3),
      activas: [], problemas, inmediato: null,
    });
    assert.equal(segundo.accion, "NO_REPLY");
  });

  it("the due periodic cut with only corrupt work sends a safe report, never throws", () => {
    // Recorrido completo del hallazgo 1: el resumen ilegible se conserva con
    // su forma conservadora (desconocido, sin carriles) y en `problemas`.
    const corrupta: ResumenSeguimiento = {
      trabajoId: "fase:14",
      fase: "14",
      titulo: "Fase 14",
      progreso: { kind: "desconocido", motivo: "plan-sin-verificar" },
      carriles: [],
      siguientePaso: "",
      atencionRequerida: { necesaria: false, motivo: null },
      actualizado: "2026-09-19T10:30:00Z",
    };
    const primero = decidirSeguimiento({
      ahora: 900, previo: corteEn(0, [corrupta]), activas: [corrupta], problemas, inmediato: null,
    });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer ilegible inesperado");
    assert.equal(primero.tipo, "inmediato");
    // Confirmación por contrato público: messageId SOLO en el nivel superior.
    const previo = confirmado(primero.estadoTrasConfirmar, 41);
    // Minuto 30: la corrupción no pospone el corte debido (spec l.120-126) y
    // el único trabajo activo sigue sin carriles: el reporte sale seguro,
    // sin lanzar y sin inventar actividad.
    const segundo = decidirSeguimiento({
      ahora: 1800, previo, activas: [corrupta], problemas, inmediato: null,
    });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("corte con solo corrupcion inesperado");
    assert.equal(segundo.tipo, "periodico");
    assert.match(segundo.mensaje, /\[AVANZA\] Fase 14 — desconocido/);
    assert.match(segundo.mensaje, /sin lectura nueva del avance en esta ventana\./);
    assert.doesNotMatch(segundo.mensaje, /minutos en la unidad actual/);
    assert.doesNotMatch(segundo.mensaje, /última evidencia/);
    assert.deepEqual(segundo.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 1800 });
  });

  it("a changed corruption report sends again", () => {
    const primero = decidirSeguimiento({
      ahora: 901, previo: corteEn(900, []), activas: [], problemas,
      inmediato: null,
    });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer ilegible inesperado");
    const previo = confirmado(primero.estadoTrasConfirmar, 3);
    const mas: ProblemaSeguimiento[] = [...problemas, { trabajoId: "corrida:otra", motivo: "json-invalido" }];
    const segundo = decidirSeguimiento({ ahora: 902, previo, activas: [], problemas: mas, inmediato: null });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("segundo ilegible inesperado");
    assert.match(segundo.mensaje, /corrida otra/);
  });

  it("an explicit immediate wins over corruption triage", () => {
    const d = decidirSeguimiento({
      ahora: 901, previo: corteEn(900, []), activas: [], problemas,
      inmediato: { tipo: "CERRADA", texto: V1_CERRADA },
    });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("explicito inesperado");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, V1_CERRADA);
  });

  it("a crude explicit immediate never goes out raw", () => {
    const activas = [resumen14(1, 4, 25)];
    for (const texto of ["cuota agotada", V1_DETENIDA.replace("[DETENIDA]", "[AVANZA]")]) {
      assert.throws(
        () => decidirSeguimiento({
          ahora: 901, previo: corteEn(900, activas), activas,
          inmediato: { tipo: "DETENIDA", texto },
        }),
        /inmediato explícito inválido/,
      );
    }
  });
});

describe("atencion requerida", () => {
  const V1_ATENCION = "[NECESITO TU RESPUESTA] Corrida, 1 de 4 partes terminadas\nQue cambio: La fase 14 llegó a una decisión que no está preaprobada.\nQue sigue: El trabajo espera tu respuesta antes de continuar.\nQue necesito de ti: Elegir A o B.";

  it("needed attention at minute 15 sends NECESITO without waiting", () => {
    const activas = [resumenAtencion("Elegir A o B")];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, V1_ATENCION);
  });

  it("no attention before the cut stays silent", () => {
    const activas = [resumen14(1, 4, 25)];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "NO_REPLY");
  });

  it("the same confirmed reason does not resend; a different one does", () => {
    const activas = [resumenAtencion("Elegir A o B")];
    const primero = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primera atencion inesperada");
    const previo = confirmado(primero.estadoTrasConfirmar, 11);
    const repetido = decidirSeguimiento({ ahora: 901, previo, activas, inmediato: null });
    assert.equal(repetido.accion, "NO_REPLY");
    const cambiado = decidirSeguimiento({
      ahora: 902, previo, activas: [resumenAtencion("Elegir C")], inmediato: null,
    });
    assert.equal(cambiado.accion, "SEND");
    if (cambiado.accion !== "SEND") throw new Error("motivo nuevo inesperado");
    assert.match(cambiado.mensaje, /Elegir C/);
    assert.match(cambiado.mensaje, /^\[NECESITO TU RESPUESTA\] Corrida, /);
  });

  it("a public-contract confirmation (top-level messageId only) dedups the next tick", () => {
    const activas = [resumenAtencion("Elegir A o B")];
    const primero = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primera atencion inesperada");
    // El llamador real persiste `{ ...estadoTrasConfirmar, messageId }` y nada
    // más: el messageId anidado nunca se llena fuera de los tests.
    const previo = confirmado(primero.estadoTrasConfirmar, 21);
    assert.equal(previo.ultimoInmediato !== null ? previo.ultimoInmediato.messageId : undefined, null);
    const segundo = decidirSeguimiento({ ahora: 905, previo, activas, inmediato: null });
    assert.equal(segundo.accion, "NO_REPLY");
    if (segundo.accion !== "NO_REPLY") throw new Error("dedup tras confirmacion publica roto");
  });

  it("a condition gone exactly at the due periodic cut is registered inactive, not left treated", () => {
    const conAtencion = resumenAtencion("Elegir A o B");
    const sinAtencion = { ...conAtencion, atencionRequerida: { necesaria: false, motivo: null } };
    const r0 = decidirSeguimiento({
      ahora: 900, previo: crearEstadoInicial(0, [conAtencion]), activas: [conAtencion], inmediato: null,
    });
    assert.equal(r0.accion, "SEND");
    if (r0.accion !== "SEND") throw new Error("primera atencion inesperada");
    const previo = confirmado(r0.estadoTrasConfirmar, 30);
    // Minuto 30: la condición desaparece justo cuando el periódico está debido.
    const r30 = decidirSeguimiento({ ahora: 1800, previo, activas: [sinAtencion], inmediato: null });
    assert.equal(r30.accion, "SEND");
    if (r30.accion !== "SEND") throw new Error("periodico inesperado");
    assert.equal(r30.tipo, "periodico");
    assert.equal(r30.estadoTrasConfirmar.ultimoInmediato, null);
    // Si la condición vuelve, es un evento nuevo (spec l.98-99): sale otra vez.
    const r1860 = decidirSeguimiento({
      ahora: 1860, previo: confirmado(r30.estadoTrasConfirmar, 31), activas: [conAtencion], inmediato: null,
    });
    assert.equal(r1860.accion, "SEND");
    if (r1860.accion !== "SEND") throw new Error("retorno inesperado");
    assert.equal(r1860.tipo, "inmediato");
  });

  it("a reason with line breaks or control characters falls back to the safe sentence instead of throwing", () => {
    for (const motivo of ["Elegir\nA o B", "Elegir\rA o B", "Elegir A o B\u0007"]) {
      const activas = [resumenAtencion(motivo)];
      const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
      assert.equal(d.accion, "SEND", `deberia enviar con motivo seguro: ${JSON.stringify(motivo)}`);
      if (d.accion !== "SEND") throw new Error("atencion segura inesperada");
      assert.equal(d.tipo, "inmediato");
      assert.equal(
        d.mensaje,
        "[NECESITO TU RESPUESTA] Corrida, 1 de 4 partes terminadas\nQue cambio: La fase 14 llegó a una decisión que no está preaprobada.\nQue sigue: El trabajo espera tu respuesta antes de continuar.\nQue necesito de ti: Tienes una decisión pendiente.",
      );
    }
  });

  it("a dirty reason falls back to safe owner language", () => {
    const activas = [resumenAtencion("revisa /tmp/x en commit abcdef1")];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("atencion sucia inesperada");
    assert.doesNotMatch(d.mensaje, /\/tmp\/x/);
    assert.doesNotMatch(d.mensaje, /abcdef1/);
    assert.match(d.mensaje, /Que necesito de ti: Tienes una decisión pendiente\./);
  });

  it("an attention immediate preserves the periodic cut", () => {
    const activas = [resumenAtencion("Elegir A o B")];
    const d = decidirSeguimiento({ ahora: 900, previo: corteEn(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.deepEqual(d.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 0 });
  });

  it("a null reason uses the safe sentence; a question keeps single punctuation", () => {
    const nula = decidirSeguimiento({
      ahora: 900, previo: crearEstadoInicial(0, [resumenAtencion(null)]),
      activas: [resumenAtencion(null)], inmediato: null,
    });
    assert.equal(nula.accion, "SEND");
    if (nula.accion !== "SEND") throw new Error("atencion nula inesperada");
    assert.equal(nula.mensaje, "[NECESITO TU RESPUESTA] Corrida, 1 de 4 partes terminadas\nQue cambio: La fase 14 llegó a una decisión que no está preaprobada.\nQue sigue: El trabajo espera tu respuesta antes de continuar.\nQue necesito de ti: Tienes una decisión pendiente.");
    const pregunta = decidirSeguimiento({
      ahora: 900, previo: crearEstadoInicial(0, [resumenAtencion("¿Sigo por A?")]),
      activas: [resumenAtencion("¿Sigo por A?")], inmediato: null,
    });
    assert.equal(pregunta.accion, "SEND");
    if (pregunta.accion !== "SEND") throw new Error("pregunta inesperada");
    assert.match(pregunta.mensaje, /Que necesito de ti: ¿Sigo por A\?\n?$/);
  });

  it("attention minute 0-15-30-45 with confirmations, then lapse and return", () => {
    const catorce = resumenAtencion("Elegir A o B");
    const quince = resumen15();
    const ambas = [catorce, quince];
    const r0 = decidirSeguimiento({ ahora: 0, previo: crearEstadoInicial(0, ambas), activas: ambas, inmediato: null });
    assert.equal(r0.accion, "SEND");
    if (r0.accion !== "SEND") throw new Error("minuto 0 inesperado");
    let previo = confirmado(r0.estadoTrasConfirmar, 1);
    const r15 = decidirSeguimiento({ ahora: 900, previo, activas: ambas, inmediato: null });
    assert.equal(r15.accion, "NO_REPLY");
    if (r15.accion !== "NO_REPLY") throw new Error("minuto 15 inesperado");
    const r30 = decidirSeguimiento({ ahora: 1800, previo: r15.estado, activas: ambas, inmediato: null });
    assert.equal(r30.accion, "SEND");
    if (r30.accion !== "SEND") throw new Error("minuto 30 inesperado");
    assert.equal(r30.tipo, "periodico");
    assert.match(r30.mensaje, /Fase 15/);
    previo = confirmado(r30.estadoTrasConfirmar, 2);
    const r45 = decidirSeguimiento({ ahora: 2700, previo, activas: ambas, inmediato: null });
    assert.equal(r45.accion, "NO_REPLY");
    const sinAtencion = [{ ...catorce, atencionRequerida: { necesaria: false, motivo: null } }, quince];
    const r46 = decidirSeguimiento({ ahora: 2760, previo: r45.estado, activas: sinAtencion, inmediato: null });
    assert.equal(r46.accion, "NO_REPLY");
    if (r46.accion !== "NO_REPLY") throw new Error("lapso inesperado");
    assert.equal(r46.estado.ultimoInmediato, null);
    const vuelve = decidirSeguimiento({ ahora: 2820, previo: r46.estado, activas: ambas, inmediato: null });
    assert.equal(vuelve.accion, "SEND");
    if (vuelve.accion !== "SEND") throw new Error("retorno inesperado");
    assert.equal(vuelve.tipo, "inmediato");
  });

  it("persistent corruption still lets the healthy phase report", () => {
    const sana = resumen15();
    const probs: ProblemaSeguimiento[] = [{ trabajoId: "fase:14", motivo: "ilegible" }];
    const r1 = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, [sana]), activas: [sana], problemas: probs, inmediato: null });
    assert.equal(r1.accion, "SEND");
    if (r1.accion !== "SEND") throw new Error("detenida esperada");
    assert.match(r1.mensaje, /^\[DETENIDA\] Corrida, /);
    const previo = confirmado(r1.estadoTrasConfirmar, 5);
    const r2 = decidirSeguimiento({ ahora: 1800, previo, activas: [sana], problemas: probs, inmediato: null });
    assert.equal(r2.accion, "SEND");
    if (r2.accion !== "SEND") throw new Error("periodico esperado");
    assert.equal(r2.tipo, "periodico");
    assert.match(r2.mensaje, /Fase 15/);
    const r3 = decidirSeguimiento({
      ahora: 1860, previo: confirmado(r2.estadoTrasConfirmar, 6),
      activas: [sana], problemas: probs, inmediato: null,
    });
    assert.equal(r3.accion, "NO_REPLY");
    const otra: ProblemaSeguimiento[] = [{ trabajoId: "fase:14", motivo: "documento-invalido" }];
    const r4 = decidirSeguimiento({
      ahora: 1920, previo: confirmado(r2.estadoTrasConfirmar, 6),
      activas: [sana], problemas: otra, inmediato: null,
    });
    assert.equal(r4.accion, "SEND");
    if (r4.accion !== "SEND") throw new Error("nueva causa esperada");
    assert.match(r4.mensaje, /documento inválido/);
  });
});

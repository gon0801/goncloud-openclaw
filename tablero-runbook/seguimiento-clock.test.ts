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

function confirmado(estadoTrasConfirmar: EstadoTrasConfirmar, messageId: number): EstadoSeguimiento {
  return { ...estadoTrasConfirmar, messageId };
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
    const inmediato: EventoInmediato = { tipo: "NECESITO TU RESPUESTA", texto: "¿Sigo por A o por B?" };
    const d = decidirSeguimiento({ ahora: 901, previo: corteEn(900, activas), activas, inmediato });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("inmediato inesperado");
    assert.equal(d.tipo, "inmediato");
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
    for (const tipo of ["DETENIDA", "CERRADA"] as const) {
      const d = decidirSeguimiento({
        ahora: 901, previo: corteEn(900, activas), activas,
        inmediato: { tipo, texto: "motivo material" },
      });
      assert.equal(d.accion, "SEND");
      if (d.accion !== "SEND") throw new Error(`${tipo} inesperado`);
      assert.equal(d.tipo, "inmediato");
      assert.equal(d.mensaje, "motivo material");
    }
  });

  it("a repeated identical immediate is not sent twice", () => {
    const activas = [resumen14(1, 4, 25)];
    const inmediato: EventoInmediato = { tipo: "DETENIDA", texto: "cuota agotada" };
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
      inmediato: { tipo: "NECESITO TU RESPUESTA", texto: "¿Sigo?" },
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
    ]) {
      assert.throws(() => parseEstadoSeguimiento(malo), /estado/i);
    }
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
    assert.match(d.mensaje, /Fase 14/);
    assert.match(d.mensaje, /ilegible/);
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
      inmediato: { tipo: "CERRADA", texto: "cierre observado" },
    });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("explicito inesperado");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, "cierre observado");
  });
});

describe("atencion requerida", () => {
  it("needed attention at minute 15 sends NECESITO without waiting", () => {
    const activas = [resumenAtencion("Elegir A o B")];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.equal(d.tipo, "inmediato");
    assert.equal(d.mensaje, "Necesito tu respuesta para Fase 14: Elegir A o B.");
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
  });

  it("a dirty reason falls back to safe owner language", () => {
    const activas = [resumenAtencion("revisa /tmp/x en commit abcdef1")];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("atencion sucia inesperada");
    assert.doesNotMatch(d.mensaje, /\/tmp\/x/);
    assert.doesNotMatch(d.mensaje, /abcdef1/);
    assert.match(d.mensaje, /Fase 14/);
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
    assert.equal(nula.mensaje, "Necesito tu respuesta para Fase 14. Tienes una decisión pendiente.");
    const pregunta = decidirSeguimiento({
      ahora: 900, previo: crearEstadoInicial(0, [resumenAtencion("¿Sigo por A?")]),
      activas: [resumenAtencion("¿Sigo por A?")], inmediato: null,
    });
    assert.equal(pregunta.accion, "SEND");
    if (pregunta.accion !== "SEND") throw new Error("pregunta inesperada");
    assert.equal(pregunta.mensaje, "Necesito tu respuesta para Fase 14: ¿Sigo por A?");
  });
});

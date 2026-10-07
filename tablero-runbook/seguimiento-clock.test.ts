/**
 * seguimiento-clock.test.ts — máquina de estados 15/30 (`seguimiento-clock.v1`).
 *
 * Dos ticks de 15 minutos producen como máximo un Telegram periódico, y solo
 * si hay novedad (o toca el latido de 4 horas); un permiso, una caída o un
 * cierre salen de inmediato sin duplicar el reporte de rutina ni repetir un
 * pendiente ya avisado. El corte confirmado solo avanza con `ok:true` más `messageId`.
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
import { validarMensajeV1 } from "./seguimiento-render.ts";

function resumen14(completadas: number, total: number, porcentaje: number): ResumenSeguimiento {
  return {
    trabajoId: "fase:14",
    fase: "14",
    titulo: "Fase 14",
    unidad: "tareas",
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
    unidad: "tareas",
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

function resumenCorrida(completadas: number, titulo = "Migrar el correo"): ResumenSeguimiento {
  const porcentaje = Math.round((100 * completadas) / 3);
  return {
    ...resumen14(completadas, 3, porcentaje),
    trabajoId: "corrida:migrar-correo",
    fase: "0",
    titulo,
    unidad: "partes",
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

  it("R12: cuadricula de 15 min — tick 900 mudo, tick desfasado 1795 envia (tolerancia), tick 1800 envia; ciclo nuevo 2700 mudo y 3600 envia", () => {
    // Con novedad (una tarea más): la ventana es lo único que decide.
    const antes = [resumen14(1, 4, 25)];
    const activas = [resumen14(2, 4, 50)];
    const d900 = decidirSeguimiento({ ahora: 900, previo: corteEn(0, antes), activas, inmediato: null });
    assert.equal(d900.accion, "NO_REPLY");
    const dDesfase = decidirSeguimiento({ ahora: 1795, previo: corteEn(0, antes), activas, inmediato: null });
    assert.equal(dDesfase.accion, "SEND");
    if (dDesfase.accion !== "SEND") throw new Error("desfase R12 inesperado");
    assert.equal(dDesfase.tipo, "periodico");
    const d1800 = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, antes), activas, inmediato: null });
    assert.equal(d1800.accion, "SEND");
    const d2700 = decidirSeguimiento({ ahora: 2700, previo: corteEn(1800, antes), activas, inmediato: null });
    assert.equal(d2700.accion, "NO_REPLY");
    const d3600 = decidirSeguimiento({ ahora: 3600, previo: corteEn(1800, antes), activas, inmediato: null });
    assert.equal(d3600.accion, "SEND");
  });

  it("without news a due tick stays silent; the heartbeat goes out four hours after the last cut", () => {
    const activas = [resumen14(1, 4, 25)];
    const previo = corteEn(0, activas);
    for (const ahora of [1800, 3600, 14399]) {
      const d = decidirSeguimiento({ ahora, previo, activas, inmediato: null });
      assert.equal(d.accion, "NO_REPLY", `tick ${ahora}`);
      if (d.accion !== "NO_REPLY") throw new Error("silencio esperado");
      // El silencio no mueve el corte ni el estado contra el que se compara.
      assert.deepEqual(d.estado.corte, previo.corte);
      assert.equal(d.estado.ultimoEstado, previo.ultimoEstado);
    }
    const latido = decidirSeguimiento({ ahora: 14400, previo, activas, inmediato: null });
    assert.equal(latido.accion, "SEND");
    if (latido.accion !== "SEND") throw new Error("latido esperado");
    assert.equal(latido.tipo, "periodico");
    assert.equal(latido.mensaje, "Sin novedad: todo sigue en curso.\nFase 14: 1 de 4 tareas.\nAhora: Implementación.\nNo necesito nada de ti.\n");
    assert.deepEqual(latido.estadoTrasConfirmar.corte, { kind: "reporte-confirmado", ultimoReporteConfirmado: 14400 });
  });

  it("news accumulated during silent ticks goes out in the first due cut, compared against the last one sent", () => {
    const previo = corteEn(0, [resumen14(1, 4, 25)]);
    const mudo = decidirSeguimiento({ ahora: 900, previo, activas: [resumen14(2, 4, 50)], inmediato: null });
    if (mudo.accion !== "NO_REPLY") throw new Error("ventana no cumplida");
    const d = decidirSeguimiento({ ahora: 1800, previo: mudo.estado, activas: [resumen14(3, 4, 75)], inmediato: null });
    if (d.accion !== "SEND") throw new Error("corte esperado");
    assert.match(d.mensaje, /^Fase 14 terminó 2 tareas\.\n/);
  });

  it("a part getting stuck or unstuck is news; so is an attention request appearing or clearing", () => {
    const base = resumen14(1, 4, 25);
    const atorada: ResumenSeguimiento = { ...base, carriles: [{ ...base.carriles[0]!, estado: "atorado" }] };
    const seAtora = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, [base]), activas: [atorada], inmediato: null });
    if (seAtora.accion !== "SEND") throw new Error("atorada esperada");
    assert.equal(seAtora.mensaje, "Fase 14 tiene una parte atorada.\nFase 14: 1 de 4 tareas.\nAtorada: Implementación.\nNo necesito nada de ti.\n");
    const seSuelta = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, [atorada]), activas: [base], inmediato: null });
    if (seSuelta.accion !== "SEND") throw new Error("destrabada esperada");
    assert.match(seSuelta.mensaje, /^Fase 14 destrabó una parte\.\n/);

    const pide = resumenAtencion("Falta tu visto bueno");
    const yaAvisado = { ...corteEn(0, [pide]), ultimoInmediato: { firma: "x", messageId: null, entregados: ["fase:14:Falta tu visto bueno"] } };
    const seLibera = decidirSeguimiento({ ahora: 1800, previo: yaAvisado, activas: [base], inmediato: null });
    if (seLibera.accion !== "SEND") throw new Error("liberada esperada");
    assert.match(seLibera.mensaje, /^Fase 14 ya no necesita tu respuesta\.\n/);
    assert.equal(seLibera.estadoTrasConfirmar.ultimoInmediato, null);
  });

  it("a job leaving the cut is news for the ones that remain", () => {
    const d = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, [resumen14(2, 4, 50), resumen15()]), activas: [resumen15()], inmediato: null });
    if (d.accion !== "SEND") throw new Error("corte esperado");
    assert.match(d.mensaje, /^Un trabajo salió del seguimiento\.\n/);
  });

  it("a saved state that cannot be compared sends one plain cut instead of failing or going silent", () => {
    for (const ultimoEstado of ["", "fase:9|0/3", "[1,2]"]) {
      const previo = { ...corteEn(0, []), ultimoEstado };
      const d = decidirSeguimiento({ ahora: 1800, previo, activas: [resumen14(1, 4, 25)], inmediato: null });
      if (d.accion !== "SEND") throw new Error(`corte esperado con ${JSON.stringify(ultimoEstado)}`);
      assert.match(d.mensaje, /^Estado actual del trabajo\.\n/);
    }
  });

  it("a state saved before stuck parts and attention were tracked compares by counts and does not invent news", () => {
    const viejo = JSON.stringify({ a: [{ t: "fase:14", f: "14", c: 1, n: 4, p: 25 }], s: [], i: null });
    const base = resumen14(1, 4, 25);
    const atorada: ResumenSeguimiento = { ...base, carriles: [{ ...base.carriles[0]!, estado: "atorado" }] };
    const previo = { ...corteEn(0, []), ultimoEstado: viejo };
    assert.equal(decidirSeguimiento({ ahora: 1800, previo, activas: [atorada], inmediato: null }).accion, "NO_REPLY");
    const avanza = decidirSeguimiento({ ahora: 1800, previo, activas: [resumen14(2, 4, 50)], inmediato: null });
    if (avanza.accion !== "SEND") throw new Error("avance esperado");
    assert.match(avanza.mensaje, /^Fase 14 terminó una tarea\.\n/);
  });

  it("a failed delivery does not advance the confirmed cut", () => {
    const antes = [resumen14(1, 4, 25)];
    const activas = [resumen14(2, 4, 50)];
    const d1 = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, antes), activas, inmediato: null });
    const d2 = decidirSeguimiento({ ahora: 2700, previo: corteEn(0, antes), activas, inmediato: null });
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
    const activas = [resumen14(2, 4, 50)];
    const previo = corteEn(0, [resumen14(1, 4, 25)]);
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
    const activas = [resumen14(2, 4, 50)];
    const per = decidirSeguimiento({ ahora: 1800, previo: corteEn(0, [resumen14(1, 4, 25)]), activas, inmediato: null });
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
    assert.equal(d.mensaje.match(/^Empezó el seguimiento\.$/gm)?.length, 1);
    assert.equal(d.mensaje.match(/^No necesito nada de ti\.$/gm)?.length, 1);
  });

  it("with no active work a tick stays silent instead of rendering emptiness", () => {
    const previo = corteEn(0, [resumen14(2, 4, 50)]);
    const d = decidirSeguimiento({ ahora: 1800, previo, activas: [], inmediato: null });
    assert.equal(d.accion, "NO_REPLY");
    if (d.accion !== "NO_REPLY") throw new Error("vacio inesperado");
    assert.deepEqual(d.estado.trabajosActivos, []);
  });

  it("a due cut with changed counts names the advance; unchanged counts stay silent until the heartbeat", () => {
    const antes = [resumen14(1, 4, 25)];
    const primero = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, antes), activas: antes, inmediato: null });
    assert.equal(primero.accion, "SEND");
    if (primero.accion !== "SEND") throw new Error("primer corte inesperado");
    const previo = confirmado(primero.estadoTrasConfirmar, 7);
    const despues = [resumen14(2, 4, 50)];
    const segundo = decidirSeguimiento({ ahora: 3600, previo, activas: despues, inmediato: null });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("segundo corte inesperado");
    assert.match(segundo.mensaje, /^Fase 14 terminó una tarea\.\nFase 14: 2 de 4 tareas\.\n/);
    const trasSegundo = confirmado(segundo.estadoTrasConfirmar, 8);
    assert.equal(decidirSeguimiento({ ahora: 5400, previo: trasSegundo, activas: despues, inmediato: null }).accion, "NO_REPLY");
    const tercero = decidirSeguimiento({ ahora: 3600 + 14400, previo: trasSegundo, activas: despues, inmediato: null });
    assert.equal(tercero.accion, "SEND");
    if (tercero.accion !== "SEND") throw new Error("latido inesperado");
    assert.match(tercero.mensaje, /^Sin novedad: todo sigue en curso\.\n/);
  });
});

describe("decidirSeguimiento con una corrida", () => {
  it("names the corrida by its title in the advance, never as Fase 0", () => {
    const primero = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, [resumenCorrida(0)]), activas: [resumenCorrida(0)], inmediato: null });
    if (primero.accion !== "SEND") throw new Error("primer corte inesperado");
    const segundo = decidirSeguimiento({
      ahora: 3600, previo: confirmado(primero.estadoTrasConfirmar, 7), activas: [resumenCorrida(1)], inmediato: null,
    });
    if (segundo.accion !== "SEND") throw new Error("segundo corte inesperado");
    assert.match(segundo.mensaje, /^Migrar el correo terminó una parte\.\nMigrar el correo: 1 de 3 partes\.\n/);
    assert.doesNotMatch(segundo.mensaje, /Fase 0/);
  });

  it("an attention request names the corrida and its parts and stays valid v1", () => {
    const activas = [{ ...resumenCorrida(1), atencionRequerida: { necesaria: true, motivo: "Necesito el código del banco" } }];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.equal(d.mensaje, [
      "[NECESITO TU RESPUESTA] Migrar el correo, 1 de 3 partes terminadas",
      "Que cambio: Migrar el correo llegó a una decisión que no está preaprobada.",
      "Que sigue: El trabajo espera tu respuesta antes de continuar.",
      "Que necesito de ti: Necesito el código del banco.",
    ].join("\n"));
    assert.equal(validarMensajeV1(d.mensaje).ok, true);
  });

  it("a title that is not owner language falls back and the attention still validates", () => {
    const activas = [{ ...resumenCorrida(1, "Arreglar el merge del repo"), atencionRequerida: { necesaria: true, motivo: null } }];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.match(d.mensaje, /^\[NECESITO TU RESPUESTA\] migrar-correo, 1 de 3 partes terminadas$/m);
    assert.match(d.mensaje, /^Que cambio: Trabajo migrar-correo llegó a una decisión/m);
    assert.equal(validarMensajeV1(d.mensaje).ok, true);
  });

  it("fase15-ci: line 1 keeps the id, the body falls back to a plain phrase, and it stays valid v1", () => {
    const activas = [{
      ...resumenCorrida(1, "Autopilot de la Fase 15 — CI completa sin siete minutos de espera"),
      trabajoId: "corrida:fase15-ci",
      atencionRequerida: { necesaria: true, motivo: null },
    }];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.match(d.mensaje, /^\[NECESITO TU RESPUESTA\] fase15-ci, 1 de 3 partes terminadas$/m);
    assert.match(d.mensaje, /^Que cambio: Trabajo en curso llegó a una decisión/m);
    assert.equal(validarMensajeV1(d.mensaje).ok, true);
  });

  it("a title carrying a reserved marker falls back to the id and never breaks the tick", () => {
    const titulo = "Revisar Comando: pendiente";
    const atencion = [{ ...resumenCorrida(1, titulo), atencionRequerida: { necesaria: true, motivo: null } }];
    const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, atencion), activas: atencion, inmediato: null });
    if (d.accion !== "SEND") throw new Error("atencion inesperada");
    assert.match(d.mensaje, /^\[NECESITO TU RESPUESTA\] migrar-correo, 1 de 3 partes terminadas$/m);
    assert.match(d.mensaje, /^Que cambio: Trabajo migrar-correo llegó a una decisión/m);
    assert.equal(validarMensajeV1(d.mensaje).ok, true);

    const activas = [resumenCorrida(1, titulo)];
    const p = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
    if (p.accion !== "SEND") throw new Error("periódico esperado");
    assert.match(p.mensaje, /^migrar-correo: 1 de 3 partes\.$/m);
    assert.doesNotMatch(p.mensaje, /Comando: /);

    const rancia = [{ ...resumenCorrida(1, titulo), actualizado: "2026-09-01T00:00:00Z" }];
    const r = decidirSeguimiento({ ahora: Date.parse("2026-09-29T12:00:00Z") / 1000, previo: crearEstadoInicial(0, rancia), activas: rancia, inmediato: null });
    if (r.accion !== "SEND") throw new Error("rancia esperada");
    assert.equal(validarMensajeV1(r.mensaje).ok, true);
  });

  it("an attention reason carrying a reserved marker is neutralized and never breaks the tick", () => {
    for (const motivo of ["Revisa Comando: x", `Revisa Comando: ${"x".repeat(250)}`, "Dime Que sigue: algo"]) {
      const activas = [{ ...resumenCorrida(1), atencionRequerida: { necesaria: true, motivo } }];
      const d = decidirSeguimiento({ ahora: 900, previo: crearEstadoInicial(0, activas), activas, inmediato: null });
      if (d.accion !== "SEND") throw new Error("atencion inesperada");
      assert.match(d.mensaje, /^Que necesito de ti: Tienes una decisión pendiente\.$/m, motivo);
      assert.equal(validarMensajeV1(d.mensaje).ok, true, motivo);
    }
  });

  it("a corrida entering the cut is described in the unit it was counted in", () => {
    const primero = decidirSeguimiento({ ahora: 1800, previo: crearEstadoInicial(0, [resumen14(1, 4, 25)]), activas: [resumen14(1, 4, 25)], inmediato: null });
    if (primero.accion !== "SEND") throw new Error("primer corte inesperado");
    const activas = [resumen14(1, 4, 25), resumenCorrida(1)];
    const segundo = decidirSeguimiento({ ahora: 3600, previo: confirmado(primero.estadoTrasConfirmar, 7), activas, inmediato: null });
    if (segundo.accion !== "SEND") throw new Error("segundo corte inesperado");
    assert.match(segundo.mensaje, /^Migrar el correo entró al seguimiento\.\n/);
    assert.match(segundo.mensaje, /^Migrar el correo: 1 de 3 partes\.$/m);
    assert.match(segundo.mensaje, /^Fase 14: 1 de 4 tareas\.$/m);
  });
});

describe("aviso inmediato por pendiente", () => {
  const T0 = Date.parse("2026-10-07T12:00:00Z") / 1000;
  const iso = (secs: number): string => new Date(secs * 1000).toISOString();

  function encargos(motivo: string | null): ResumenSeguimiento {
    return {
      ...resumenCorrida(1, "Encargos durables"),
      trabajoId: "corrida:encargos",
      actualizado: iso(T0 - 600),
      atencionRequerida: { necesaria: motivo !== null, motivo },
    };
  }
  /** Trabajo abierto que no se mueve desde hace seis días: rancio. */
  function u3a(): ResumenSeguimiento {
    return { ...resumenCorrida(1, "Cerrar el tablero viejo"), trabajoId: "corrida:u3a", actualizado: iso(T0 - 6 * 86400) };
  }
  const RANCIA = "Cerrar el tablero viejo no se mueve desde el 1 de octubre: ¿sigue viva o la cierro?";

  it("when one pending item changes its text, only that one is sent: the stale job is not asked again", () => {
    // Medido el 2026-10-07: el aviso juntaba todos los pendientes y firmaba
    // el conjunto, así que cada cambio de texto reenviaba también lo viejo.
    const activas1 = [encargos("Falta iniciar la sesión del revisor"), u3a()];
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0, activas1), activas: activas1, inmediato: null });
    if (r1.accion !== "SEND") throw new Error("primer aviso esperado");
    assert.ok(r1.mensaje.includes("Falta iniciar la sesión del revisor."), r1.mensaje);
    assert.ok(r1.mensaje.includes(RANCIA), r1.mensaje);

    const activas2 = [encargos("Falta tu visto bueno para seguir"), u3a()];
    const r2 = decidirSeguimiento({ ahora: T0 + 300, previo: confirmado(r1.estadoTrasConfirmar, 5), activas: activas2, inmediato: null });
    if (r2.accion !== "SEND") throw new Error("segundo aviso esperado");
    assert.equal(r2.tipo, "inmediato");
    assert.ok(r2.mensaje.includes("Falta tu visto bueno para seguir."), r2.mensaje);
    assert.ok(!r2.mensaje.includes("Cerrar el tablero viejo"), r2.mensaje);
    assert.equal(validarMensajeV1(r2.mensaje).ok, true);

    const r3 = decidirSeguimiento({ ahora: T0 + 600, previo: confirmado(r2.estadoTrasConfirmar, 6), activas: activas2, inmediato: null });
    assert.equal(r3.accion, "NO_REPLY");
  });

  it("an item that clears does not resend the ones that stay; if it comes back it is sent alone", () => {
    const con = [encargos("Falta tu visto bueno para seguir"), u3a()];
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0, con), activas: con, inmediato: null });
    if (r1.accion !== "SEND") throw new Error("primer aviso esperado");
    const sin = [encargos(null), u3a()];
    const r2 = decidirSeguimiento({ ahora: T0 + 300, previo: confirmado(r1.estadoTrasConfirmar, 5), activas: sin, inmediato: null });
    assert.equal(r2.accion, "NO_REPLY");
    if (r2.accion !== "NO_REPLY") throw new Error("silencio esperado");
    assert.deepEqual(r2.estado.ultimoInmediato?.entregados, ["corrida:u3a:rancia"]);
    const r3 = decidirSeguimiento({ ahora: T0 + 600, previo: r2.estado, activas: con, inmediato: null });
    if (r3.accion !== "SEND") throw new Error("regreso esperado");
    assert.ok(r3.mensaje.includes("Falta tu visto bueno para seguir."), r3.mensaje);
    assert.ok(!r3.mensaje.includes("Cerrar el tablero viejo"), r3.mensaje);
  });

  it("a stale job is asked once while it stays stale, whatever its date says", () => {
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0, [u3a()]), activas: [u3a()], inmediato: null });
    if (r1.accion !== "SEND") throw new Error("pregunta esperada");
    const otraFecha = [{ ...u3a(), actualizado: iso(T0 - 5 * 86400) }];
    const r2 = decidirSeguimiento({ ahora: T0 + 900, previo: confirmado(r1.estadoTrasConfirmar, 5), activas: otraFecha, inmediato: null });
    assert.equal(r2.accion, "NO_REPLY");
  });

  it("a scratch saved before per-item signatures counts its whole bundle as already sent", () => {
    const activas = [encargos("Falta tu visto bueno para seguir"), u3a()];
    const firmaDelConjunto = `n:corrida:encargos:Falta tu visto bueno para seguir|corrida:u3a:${RANCIA}`;
    const viejo: EstadoSeguimiento = { ...corteEn(T0, activas), ultimoInmediato: { firma: firmaDelConjunto, messageId: null } };
    assert.equal(decidirSeguimiento({ ahora: T0 + 60, previo: viejo, activas, inmediato: null }).accion, "NO_REPLY");
    const cambia = [encargos("Falta iniciar la sesión del revisor"), u3a()];
    const d = decidirSeguimiento({ ahora: T0 + 60, previo: viejo, activas: cambia, inmediato: null });
    if (d.accion !== "SEND") throw new Error("aviso esperado");
    assert.ok(d.mensaje.includes("Falta iniciar la sesión del revisor."), d.mensaje);
  });

  it("another immediate notice confirmed in between keeps the items already delivered", () => {
    const activas = [encargos("Falta tu visto bueno para seguir"), u3a()];
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0, activas), activas, inmediato: null });
    if (r1.accion !== "SEND") throw new Error("primer aviso esperado");
    const r2 = decidirSeguimiento({
      ahora: T0 + 60, previo: confirmado(r1.estadoTrasConfirmar, 5), activas,
      inmediato: { tipo: "DETENIDA", texto: V1_DETENIDA },
    });
    if (r2.accion !== "SEND") throw new Error("detenida esperada");
    const r3 = decidirSeguimiento({ ahora: T0 + 120, previo: confirmado(r2.estadoTrasConfirmar, 6), activas, inmediato: null });
    assert.equal(r3.accion, "NO_REPLY");
  });

  it("the scratch round-trips the delivered items and rejects a malformed list", () => {
    const estado: EstadoSeguimiento = {
      ...corteEn(T0, []),
      ultimoInmediato: { firma: "n:x", messageId: null, entregados: ["corrida:u3a:rancia"] },
    };
    assert.deepEqual(parseEstadoSeguimiento(JSON.parse(JSON.stringify(estado))), estado);
    for (const entregados of ["x", [1], { a: 1 }]) {
      assert.throws(
        () => parseEstadoSeguimiento({ ...estado, ultimoInmediato: { firma: "n:x", messageId: null, entregados } }),
        /estado-invalido/,
      );
    }
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
      unidad: "tareas",
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
    // El único trabajo activo sigue sin carriles y sin novedad: el latido
    // sale seguro, sin lanzar y sin inventar actividad.
    assert.equal(decidirSeguimiento({
      ahora: 1800, previo, activas: [corrupta], problemas, inmediato: null,
    }).accion, "NO_REPLY");
    const segundo = decidirSeguimiento({
      ahora: 14400, previo, activas: [corrupta], problemas, inmediato: null,
    });
    assert.equal(segundo.accion, "SEND");
    if (segundo.accion !== "SEND") throw new Error("corte con solo corrupcion inesperado");
    assert.equal(segundo.tipo, "periodico");
    assert.equal(segundo.mensaje, "Sin novedad: todo sigue en curso.\nFase 14: avance desconocido.\nNo necesito nada de ti.\n");
    assert.deepEqual(segundo.estadoTrasConfirmar.corte,
      { kind: "reporte-confirmado", ultimoReporteConfirmado: 14400 });
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

describe("seguimiento rancio", () => {
  // Medido el 2026-09-29: la Fase 9 quedó sin cierre desde el 19 y el reporte
  // periódico la mandó como "[AVANZA] Fase 9 — desconocido" 11 días seguidos.
  const T0 = Date.parse("2026-09-29T12:00:00Z") / 1000;
  const haceSecs = (s: number): string => new Date((T0 - s) * 1000).toISOString();
  const fase = (id: string, actualizado: string): ResumenSeguimiento => ({
    ...resumen15(),
    trabajoId: `fase:${id}`,
    fase: id,
    titulo: `Fase ${id}`,
    actualizado,
  });
  const nueve = fase("9", "2026-09-19T10:30:00Z");
  const MOTIVO_9 = "La Fase 9 no se mueve desde el 19 de septiembre: ¿sigue viva o la cierro?";

  it("a stale doc asks once whether it is still alive, and never goes into the periodic report", () => {
    const activas = [nueve];
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0 - 1800, activas), activas, inmediato: null });
    assert.equal(r1.accion, "SEND");
    if (r1.accion !== "SEND") throw new Error("rancia esperada");
    assert.equal(r1.tipo, "inmediato");
    assert.match(r1.mensaje, /^\[NECESITO TU RESPUESTA\] /);
    assert.ok(r1.mensaje.includes(`Que necesito de ti: ${MOTIVO_9}`), r1.mensaje);
    assert.doesNotMatch(r1.mensaje, /AVANZA|minutos/);
    assert.deepEqual(r1.estadoTrasConfirmar.trabajosActivos, ["fase:9"]);

    const r2 = decidirSeguimiento({
      ahora: T0 + 1800, previo: confirmado(r1.estadoTrasConfirmar, 7), activas, inmediato: null,
    });
    assert.equal(r2.accion, "NO_REPLY");
    if (r2.accion !== "NO_REPLY") throw new Error("repetición inesperada");
    assert.deepEqual(r2.estado.trabajosActivos, ["fase:9"]);

    const r3 = decidirSeguimiento({ ahora: T0 + 3 * 86400, previo: r2.estado, activas, inmediato: null });
    assert.equal(r3.accion, "NO_REPLY");
  });

  it("with one live and one stale doc the periodic report names only the live one", () => {
    const quince = fase("15", haceSecs(3600));
    const activas = [quince, nueve];
    const r1 = decidirSeguimiento({ ahora: T0, previo: corteEn(T0 - 1800, activas), activas, inmediato: null });
    assert.equal(r1.accion, "SEND");
    if (r1.accion !== "SEND") throw new Error("rancia esperada");
    assert.equal(r1.tipo, "inmediato");
    assert.ok(r1.mensaje.includes(MOTIVO_9), r1.mensaje);

    const r2 = decidirSeguimiento({
      ahora: T0 + 60, previo: confirmado(r1.estadoTrasConfirmar, 8), activas, inmediato: null,
    });
    assert.equal(r2.accion, "SEND");
    if (r2.accion !== "SEND") throw new Error("periódico esperado");
    assert.equal(r2.tipo, "periodico");
    assert.match(r2.mensaje, /^Fase 15: 1 de 2 tareas\.$/m);
    assert.doesNotMatch(r2.mensaje, /Fase 9/);
    assert.deepEqual(r2.estadoTrasConfirmar.trabajosActivos, ["fase:15", "fase:9"]);

    const r3 = decidirSeguimiento({
      ahora: T0 + 120, previo: confirmado(r2.estadoTrasConfirmar, 9), activas, inmediato: null,
    });
    assert.equal(r3.accion, "NO_REPLY");
  });

  it("a doc updated 23 hours ago is still live; 25 hours ago is stale", () => {
    const d23 = decidirSeguimiento({
      ahora: T0, previo: corteEn(T0 - 1800, []), activas: [fase("14", haceSecs(23 * 3600))], inmediato: null,
    });
    assert.equal(d23.accion, "SEND");
    if (d23.accion !== "SEND") throw new Error("periódico esperado");
    assert.equal(d23.tipo, "periodico");
    assert.match(d23.mensaje, /^Fase 14: /m);

    const d25 = decidirSeguimiento({
      ahora: T0, previo: corteEn(T0 - 1800, []), activas: [fase("14", haceSecs(25 * 3600))], inmediato: null,
    });
    assert.equal(d25.accion, "SEND");
    if (d25.accion !== "SEND") throw new Error("rancia esperada");
    assert.equal(d25.tipo, "inmediato");
    assert.ok(d25.mensaje.includes("La Fase 14 no se mueve desde el 28 de septiembre: ¿sigue viva o la cierro?"), d25.mensaje);
  });

  it("a stale corrida is named by its title; an unreadable date counts as stale", () => {
    const corrida: ResumenSeguimiento = { ...nueve, trabajoId: "corrida:c9", fase: "0", titulo: "Revisar facturas", actualizado: "" };
    const d = decidirSeguimiento({ ahora: T0, previo: corteEn(T0, []), activas: [corrida], inmediato: null });
    assert.equal(d.accion, "SEND");
    if (d.accion !== "SEND") throw new Error("rancia esperada");
    assert.ok(d.mensaje.includes("Revisar facturas no registra avance: ¿sigue viva o la cierro?"), d.mensaje);
  });

  it("the NECESITO of a stale corrida names it by its title in every line, never as La fase 0", () => {
    const corrida: ResumenSeguimiento = {
      ...resumenCorrida(1, "Revisar facturas"), actualizado: "2026-09-19T10:30:00Z",
    };
    const d = decidirSeguimiento({ ahora: T0, previo: corteEn(T0 - 1800, [corrida]), activas: [corrida], inmediato: null });
    if (d.accion !== "SEND") throw new Error("rancia esperada");
    assert.equal(d.mensaje, [
      "[NECESITO TU RESPUESTA] Revisar facturas, 1 de 3 partes terminadas",
      "Que cambio: Revisar facturas lleva más de un día sin avance.",
      "Que sigue: Queda fuera del reporte periódico hasta que se cierre o vuelva a moverse.",
      "Que necesito de ti: Revisar facturas no se mueve desde el 19 de septiembre: ¿sigue viva o la cierro?",
    ].join("\n"));
    assert.equal(validarMensajeV1(d.mensaje).ok, true);
  });

  it("an unreadable doc stays DETENIDA and in the periodic report, not asked as stale", () => {
    const conservador: ResumenSeguimiento = {
      ...fase("14", ""),
      progreso: { kind: "desconocido", motivo: "unidad-desconocida" },
      carriles: [],
    };
    const problemas: ProblemaSeguimiento[] = [{ trabajoId: "fase:14", motivo: "ilegible" }];
    const r1 = decidirSeguimiento({
      ahora: T0, previo: corteEn(T0 - 1800, [conservador]), activas: [conservador], problemas, inmediato: null,
    });
    assert.equal(r1.accion, "SEND");
    if (r1.accion !== "SEND") throw new Error("detenida esperada");
    assert.match(r1.mensaje, /^\[DETENIDA\] /);
    const trasDetenida = confirmado(r1.estadoTrasConfirmar, 3);
    assert.equal(decidirSeguimiento({
      ahora: T0 + 60, previo: trasDetenida, activas: [conservador], problemas, inmediato: null,
    }).accion, "NO_REPLY");
    const r2 = decidirSeguimiento({
      ahora: T0 - 1800 + 14400, previo: trasDetenida, activas: [conservador], problemas, inmediato: null,
    });
    assert.equal(r2.accion, "SEND");
    if (r2.accion !== "SEND") throw new Error("latido esperado");
    assert.equal(r2.mensaje, "Sin novedad: todo sigue en curso.\nFase 14: avance desconocido.\nNo necesito nada de ti.\n");
  });
});

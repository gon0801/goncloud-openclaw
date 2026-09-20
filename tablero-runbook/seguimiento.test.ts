/**
 * seguimiento.test.ts — resumen objetivo del trabajo activo (watchdog/Telegram).
 *
 * TDD rojo-primero: este archivo se escribió ANTES de `seguimiento.ts`.
 * Los conteos salen de las unidades del plan, nunca de estimaciones:
 * solo `mergeado` cuenta como terminada; los carriles `omitido` no entran
 * en el denominador; los atorados sí; lo no verificable es `desconocido`.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { type ProgresoDoc } from "./lib.ts";
import { type EstadoPlan, type PlanCruce } from "./plan.ts";
import { resumirSeguimiento } from "./seguimiento.ts";

function carrilBase(over: Record<string, unknown>): Record<string, unknown> {
  return {
    id: "X",
    nombre: "Carril",
    repo: "gon0801/goncloud-openclaw",
    rama: null,
    tareas: [],
    estado: "pendiente",
    paso_loop: 0,
    pr: null,
    head: null,
    approve_lead: null,
    ci: "sin-ci",
    coderabbit: "pendiente",
    residuales: [],
    detenido_por: null,
    ultimo_evento: null,
    ...over,
  };
}

function docBase(over: Record<string, unknown>): ProgresoDoc {
  return {
    schema: "runbook-progress.v1",
    runbook: "docs/runbooks/autopilot-fase14.md",
    fase: "14",
    titulo: "Fase 14",
    lead: {
      agente: "muse",
      inicio: "2026-09-19T10:00:00Z",
      actualizado: "2026-09-19T10:30:00Z",
    },
    atencion_requerida: { necesaria: false, motivo: null, desde: null },
    siguiente_paso: "Terminar la corrección y comenzar la revisión.",
    carriles: [],
    cola: [],
    eventos: [],
    cierre: { at: null, telegram_message_id: null, resumen: null },
    ...over,
  } as ProgresoDoc;
}

function docConCarriles(): ProgresoDoc {
  return docBase({
    carriles: [
      carrilBase({
        id: "M",
        nombre: "Implementación",
        tareas: ["14.1", "14.3"],
        estado: "implementando",
        paso_loop: 1,
        ultimo_evento: {
          at: "2026-09-19T10:20:00Z",
          que: "Muse está corrigiendo el último caso del vigilante.",
        },
      }),
      carrilBase({
        id: "R",
        nombre: "Revisión",
        tareas: ["14.2", "14.4"],
        estado: "pendiente",
        paso_loop: 0,
      }),
    ],
  });
}

function docConOmitidoYAtorado(): ProgresoDoc {
  return docBase({
    carriles: [
      carrilBase({
        id: "A",
        nombre: "Implementación",
        tareas: ["14.1", "14.2"],
        estado: "atorado",
        paso_loop: 2,
        detenido_por: "cuota agotada en el CLI",
        ultimo_evento: {
          at: "2026-09-19T10:25:00Z",
          que: "el CLI agotó su cuota a mitad del caso",
        },
      }),
      carrilBase({
        id: "O",
        nombre: "Superficie vieja",
        tareas: ["14.3"],
        estado: "omitido",
        paso_loop: 0,
        detenido_por: "cancelado por el lead",
      }),
    ],
  });
}

const MARCADOR_DE_ESTADO: Record<EstadoPlan, string> = {
  pendiente: "cc:TODO",
  implementando: "cc:WIP",
  mergeado: "cc:DONE",
  unknown: "cc:FOO",
};

function planCruzado(estados: Record<string, EstadoPlan>): PlanCruce {
  const items: Record<string, { estado: EstadoPlan; marcador: string; discrepa: boolean }> = {};
  for (const [id, estado] of Object.entries(estados)) {
    items[id] = { estado, marcador: MARCADOR_DE_ESTADO[estado], discrepa: false };
  }
  return { kind: "cruzado", rotulo: "plan", items };
}

const sinVerificar: PlanCruce = { kind: "sin-verificar", rotulo: "plan: sin verificar" };

describe("resumirSeguimiento", () => {
  it("derives phase and lane counts from plan units", () => {
    const r = resumirSeguimiento(docConCarriles(), planCruzado({
      "14.1": "mergeado", "14.2": "mergeado", "14.3": "implementando", "14.4": "pendiente",
    }));
    assert.deepEqual(r.progreso, { kind: "conocido", completadas: 2, total: 4, porcentaje: 50 });
    assert.deepEqual(r.carriles.find((c) => c.id === "M")?.progreso,
      { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 });
  });

  it("excludes omitted-only tasks but keeps blocked tasks", () => {
    const r = resumirSeguimiento(docConOmitidoYAtorado(), planCruzado({
      "14.1": "mergeado", "14.2": "pendiente", "14.3": "pendiente",
    }));
    assert.deepEqual(r.progreso, { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 });
  });

  it("does not turn an unavailable plan into zero", () => {
    assert.deepEqual(resumirSeguimiento(docConCarriles(), sinVerificar).progreso,
      { kind: "desconocido", motivo: "plan-sin-verificar" });
  });

  it("an unknown plan unit poisons the count instead of guessing", () => {
    const r = resumirSeguimiento(docConCarriles(), planCruzado({
      "14.1": "mergeado", "14.2": "unknown", "14.3": "implementando", "14.4": "pendiente",
    }));
    assert.deepEqual(r.progreso, { kind: "desconocido", motivo: "unidad-desconocida" });
  });

  it("a verified empty set is zero of zero, not unknown", () => {
    const doc = docBase({ carriles: [] });
    const r = resumirSeguimiento(doc, planCruzado({}));
    assert.deepEqual(r.progreso, { kind: "conocido", completadas: 0, total: 0, porcentaje: 0 });
  });

  it("derives lane activity without inventing prose or timestamps", () => {
    const r = resumirSeguimiento(docConOmitidoYAtorado(), planCruzado({
      "14.1": "mergeado", "14.2": "pendiente", "14.3": "pendiente",
    }));
    const atorado = r.carriles.find((c) => c.id === "A");
    assert.equal(atorado?.actividad.detalle, "cuota agotada en el CLI");
    assert.equal(atorado?.actividad.iniciadaEn, "2026-09-19T10:25:00Z");
    assert.equal(atorado?.actividad.ultimaEvidencia, "el CLI agotó su cuota a mitad del caso");
    const omitido = r.carriles.find((c) => c.id === "O");
    assert.equal(omitido?.actividad.detalle, "cancelado por el lead");
    assert.equal(omitido?.actividad.iniciadaEn, "2026-09-19T10:00:00Z");
    assert.equal(omitido?.actividad.ultimaEvidencia, "omitido");
  });

  it("keeps a stable trabajoId and carries the next step and attention", () => {
    const r = resumirSeguimiento(docConCarriles(), planCruzado({
      "14.1": "mergeado", "14.2": "mergeado", "14.3": "implementando", "14.4": "pendiente",
    }));
    assert.equal(r.trabajoId, "fase:14");
    assert.equal(r.siguientePaso, "Terminar la corrección y comenzar la revisión.");
    assert.deepEqual(r.atencionRequerida, { necesaria: false, motivo: null });
    const conCorrida = docBase({
      corrida: "vigia-test",
      carriles: [carrilBase({ id: "M", tareas: ["14.1"], estado: "implementando", paso_loop: 1 })],
    });
    const rc = resumirSeguimiento(conCorrida, planCruzado({ "14.1": "implementando" }));
    assert.equal(rc.trabajoId, "corrida:vigia-test");
  });
});

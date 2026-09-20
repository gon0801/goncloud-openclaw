import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  CORRIDA_RE,
  FASE_RE,
  SCHEMA_LITERAL,
  type ProgresoDoc,
  validarProgreso,
} from "./lib.ts";

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));
}

function clon<T>(v: T): T {
  return structuredClone(v);
}

function razonesDe(nombre: string): string[] {
  const v = validarProgreso(fixture(nombre));
  assert.equal(v.ok, false, `${nombre} debería rechazarse`);
  return v.razones;
}

describe("documento v1 sin campos v2", () => {
  it("prueba999-en-curso.json sigue validando", () => {
    const v = validarProgreso(fixture("prueba999-en-curso.json"));
    assert.equal(v.ok, true, `v1 debe validar; razones: ${JSON.stringify(v.razones)}`);
  });
});

describe("documento v1 con campos v2 presentes", () => {
  it("v2-campos-validos.json pasa (schema sigue siendo v1)", () => {
    const crudo = fixture("v2-campos-validos.json") as ProgresoDoc;
    assert.equal(crudo.schema, SCHEMA_LITERAL);
    assert.equal(crudo.corrida, "fase12-tablero");
    const v = validarProgreso(crudo);
    assert.equal(v.ok, true, `debería validar; razones: ${JSON.stringify(v.razones)}`);
  });

  it("plan: null y plan.ruta de directorio son válidos", () => {
    const d = clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
    d.plan = null;
    assert.equal(validarProgreso(d).ok, true);
    d.plan = { repo: "gon0801/goncloud-Orbit", ruta: "plans/", seccion: null };
    assert.equal(validarProgreso(d).ok, true);
  });

  it("el literal runbook-progress.v2 sigue rechazado (candado de progress.test.ts)", () => {
    const d = clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
    d.schema = "runbook-progress.v2";
    const v = validarProgreso(d);
    assert.equal(v.ok, false);
    assert.ok(v.razones.some((r) => /schema/.test(r)));
  });
});

describe("corrida presente", () => {
  it("rechaza ..", () => {
    assert.ok(razonesDe("v2-corrida-dotdot.json").some((r) => /corrida/.test(r)));
  });

  it("rechaza /", () => {
    assert.ok(razonesDe("v2-corrida-slash.json").some((r) => /corrida/.test(r)));
  });

  it("rechaza mayúscula", () => {
    assert.ok(razonesDe("v2-corrida-mayuscula.json").some((r) => /corrida/.test(r)));
  });

  it("rechaza vacía", () => {
    assert.ok(razonesDe("v2-corrida-vacia.json").some((r) => /corrida/.test(r)));
  });

  it("fase12-tablero es válida (si corrida usara FASE_RE, este caso falla)", () => {
    assert.equal(FASE_RE.test("fase12-tablero"), false, "FASE_RE no debe aceptar una corrida con letras");
    assert.equal(CORRIDA_RE.test("fase12-tablero"), true);
    const d = clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
    d.corrida = "fase12-tablero";
    assert.equal(validarProgreso(d).ok, true);
  });

  it("Fase12-tablero es inválida (si CORRIDA_RE fuera case-insensitive, este caso falla)", () => {
    assert.equal(CORRIDA_RE.ignoreCase, false);
    assert.equal(CORRIDA_RE.test("Fase12-tablero"), false);
    const d = clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
    d.corrida = "Fase12-tablero";
    const v = validarProgreso(d);
    assert.equal(v.ok, false);
    assert.ok(v.razones.some((r) => /corrida/.test(r)));
  });
});

describe("plan.ruta presente", () => {
  it("rechaza segmento ..", () => {
    assert.ok(razonesDe("v2-plan-ruta-dotdot.json").some((r) => /plan\.ruta/.test(r)));
  });

  it("rechaza ruta absoluta", () => {
    assert.ok(razonesDe("v2-plan-ruta-absoluta.json").some((r) => /plan\.ruta/.test(r)));
  });

  it("rechaza unidad de Windows", () => {
    const d = clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
    d.plan = { repo: "gon0801/goncloud-openclaw", ruta: "C:\\Windows\\Plans.md", seccion: null };
    const v = validarProgreso(d);
    assert.equal(v.ok, false);
    assert.ok(v.razones.some((r) => /plan\.ruta/.test(r)));
  });
});

describe("cola[].avance presente", () => {
  it("rechaza 101", () => {
    assert.ok(razonesDe("v2-avance-101.json").some((r) => /avance/.test(r)));
  });

  it("rechaza -1", () => {
    assert.ok(razonesDe("v2-avance-negativo.json").some((r) => /avance/.test(r)));
  });

  it("rechaza no entero", () => {
    assert.ok(razonesDe("v2-avance-no-entero.json").some((r) => /avance/.test(r)));
  });
});

describe("notas presentes", () => {
  it("rechaza 9 líneas", () => {
    assert.ok(razonesDe("v2-notas-9-lineas.json").some((r) => /notas/.test(r)));
  });
});

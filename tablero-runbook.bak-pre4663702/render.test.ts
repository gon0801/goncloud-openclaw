import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import {
  type Carril,
  type ColaItem,
  type ProgresoDoc,
  derivar,
  esc,
  renderTablero,
  truncar,
} from "./lib.ts";

function fixture(name: string): unknown {
  return JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8"));
}

function clon<T>(v: T): T {
  return structuredClone(v);
}

function baseDoc(): ProgresoDoc {
  return clon(fixture("v2-campos-validos.json")) as ProgresoDoc;
}

function carril(parcial: Partial<Carril> & Pick<Carril, "id">): Carril {
  return {
    nombre: parcial.nombre ?? parcial.id,
    repo: "gon0801/goncloud-Orbit",
    rama: "fase11/x",
    tareas: parcial.tareas ?? [parcial.id],
    estado: "pendiente",
    paso_loop: 1,
    ronda: 1,
    pr: null,
    head: null,
    approve_lead: null,
    ci: "pendiente",
    coderabbit: "pendiente",
    residuales: [],
    detenido_por: null,
    ultimo_evento: null,
    ...parcial,
  };
}

function cola(parcial: Partial<ColaItem> & Pick<ColaItem, "id">): ColaItem {
  return {
    prs: [],
    estado: "pendiente",
    ventana: null,
    merge_commits: [],
    verificado: null,
    detenido_por: null,
    ...parcial,
  };
}

function htmlDe(doc: ProgresoDoc): string {
  return renderTablero(doc, derivar(doc, Date.parse("2026-09-18T12:00:00Z")));
}

function porcentajeGlobal(html: string): number {
  const m = html.match(/%GLOBAL[\s\S]{0,240}?(\d+)\s*%/);
  assert.ok(m, `el HTML no muestra %GLOBAL con un entero: ${html.slice(0, 800)}`);
  return Number(m[1]);
}

describe("renderTablero (12.3)", () => {
  it("%GLOBAL promedia avance: 100/0/0 + omitido 100 da 33, no 50", () => {
    const doc = baseDoc();
    doc.carriles = [
      carril({ id: "A", estado: "mergeado", tareas: ["i1"] }),
      carril({ id: "B", estado: "pendiente", tareas: ["i2"] }),
      carril({ id: "C", estado: "pendiente", tareas: ["i3"] }),
      carril({ id: "X", estado: "omitido", tareas: ["i4"], nombre: "No corre" }),
    ];
    doc.cola = [
      cola({ id: "i1", avance: 100 }),
      cola({ id: "i2", avance: 0 }),
      cola({ id: "i3", avance: 0 }),
      cola({ id: "i4", avance: 100 }),
    ];
    const html = htmlDe(doc);
    assert.equal(porcentajeGlobal(html), 33);
    assert.notEqual(porcentajeGlobal(html), 50);
    assert.notEqual(porcentajeGlobal(html), derivar(doc).porcentajeMergeado);
  });

  it("ítem sin carril se pinta y cuenta (cierre)", () => {
    const doc = baseDoc();
    doc.carriles = [carril({ id: "A", tareas: ["A.5"] })];
    doc.cola = [
      cola({ id: "A.5", avance: 40 }),
      cola({ id: "Cierre", avance: 80 }),
    ];
    const html = htmlDe(doc);
    assert.ok(html.includes("Cierre"), "el ítem sin carril no se pintó");
    assert.doesNotThrow(() => htmlDe(doc));
    assert.equal(porcentajeGlobal(html), 60);
  });

  it("notas de 9 líneas o 400 caracteres se truncan antes de escapar", () => {
    const doc = baseDoc();
    const unica = "NOTA-NUEVE-NO-DEBE-SALIR";
    doc.notas = [
      "n1",
      "n2",
      "n3",
      "n4",
      "n5",
      "n6",
      "n7",
      "n8",
      unica,
    ];
    const html = htmlDe(doc);
    assert.ok(html.includes("n8"));
    assert.ok(!html.includes(unica), "la novena nota no se truncó");

    const largo = `${"A".repeat(298)}&${"B".repeat(100)}`;
    doc.notas = [largo];
    const html2 = htmlDe(doc);
    assert.ok(html2.includes(`${"A".repeat(298)}&amp;…`) || html2.includes(`${"A".repeat(298)}&amp;`));
    assert.ok(!html2.includes(largo), "la nota de 400 entró entera");
    const entidadRota = /&(?!amp;|lt;|gt;|quot;|#39;)/;
    assert.ok(!entidadRota.test(html2), "se escapó antes de truncar");
    assert.ok(!entidadRota.test(esc(truncar(largo, 300))));
  });

  it("get de Fase 11: renglones A B D R y %GLOBAL distinto de porcentajeMergeado", () => {
    const doc = baseDoc();
    doc.fase = "11";
    doc.proyecto = "Orbit";
    doc.titulo = "Autopilot de la Fase 11";
    doc.carriles = [
      carril({ id: "A", nombre: "Corrida diaria", tareas: ["A.5"], estado: "mergeado", pr: 10 }),
      carril({ id: "B", nombre: "Pantalla", tareas: ["A.6"], estado: "en-cola", pr: 11 }),
      carril({ id: "D", nombre: "Envio", tareas: ["E.0b"], estado: "pendiente", pr: null }),
      carril({ id: "R", nombre: "Revision", tareas: ["R.1"], estado: "implementando", pr: 12 }),
    ];
    doc.cola = [
      cola({ id: "Q1", avance: 100 }),
      cola({ id: "Q2", avance: 0 }),
      cola({ id: "Q3", avance: 0 }),
      cola({ id: "Q4", avance: 20 }),
      cola({ id: "Q5", avance: 10 }),
    ];
    const derivado = derivar(doc, Date.parse("2026-09-18T12:00:00Z"));
    const html = renderTablero(doc, derivado);
    for (const id of ["A", "B", "D", "R"]) {
      assert.ok(html.includes(`>${id}<`) || html.includes(`>${id}</`) || new RegExp(`\\b${id}\\b`).test(html), `falta el renglón ${id}`);
    }
    const global = porcentajeGlobal(html);
    assert.notEqual(String(global), String(derivado.porcentajeMergeado));
    assert.match(html, /11 · Orbit — Autopilot de la Fase 11|11 · Orbit/);
    assert.match(html, /ítems en master/);
  });
});

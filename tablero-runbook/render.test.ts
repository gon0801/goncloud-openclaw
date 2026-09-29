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

// Task 8 + 14.13d: detalle nativo del carril dentro de <details>.
describe("bloques nativos del carril (Task 8)", () => {
  function docNativo(worker: Record<string, unknown>, execution?: Record<string, unknown>): ProgresoDoc {
    const doc = baseDoc();
    const nuevo = carril({ id: "N1", estado: "implementando" }) as Record<string, unknown>;
    nuevo["worker"] = worker;
    if (execution) nuevo["execution"] = execution;
    (doc as Record<string, unknown>)["carriles"] = [nuevo];
    (doc as Record<string, unknown>)["cola"] = [];
    return doc as ProgresoDoc;
  }

  const workerBase = {
    id: "claude_fable",
    harness: "claude-code",
    provider: "anthropic",
    model: "claude-fable-5-1",
    effort: "high",
    reported_model: "claude-fable-5-1",
    health: "available",
  };
  const executionBase = {
    worktree: "/Users/dn/dev/wt/f14-a",
    session: "ses-f14-a",
    visibility: "visible",
    attach_command: "/opt/homebrew/bin/tmux attach -t =ses-f14-a",
    started_at: "2026-09-27T10:05:00Z",
  };

  it("muestra worker, harness, provider/model/effort, salud, worktree, sesión y visibilidad", () => {
    const html = htmlDe(docNativo(workerBase, executionBase));
    for (const esperado of [
      "claude_fable",
      "claude-code",
      "anthropic",
      "claude-fable-5-1",
      "high",
      "available",
      "/Users/dn/dev/wt/f14-a",
      "ses-f14-a",
      "visible",
    ]) {
      assert.ok(html.includes(esperado), `falta ${esperado} en el HTML`);
    }
    assert.match(html, /<details class="nativo">/);
    assert.match(html, /<summary>nativo<\/summary>/);
  });

  it("B21: sin effort declarado dice que corre el de la CLI y no inventa un nivel", () => {
    const html = htmlDe(docNativo({ ...workerBase, effort: null }));
    assert.ok(html.includes("anthropic/claude-fable-5-1 · effort de la CLI · salud available"), html);
    const conEffort = htmlDe(docNativo(workerBase));
    assert.ok(!conEffort.includes("effort de la CLI"), "con effort declarado no dice el de la CLI");
  });

  it("escapa el effort y el model: nada de <script> ni <b> crudos", () => {
    const html = htmlDe(
      docNativo({
        ...workerBase,
        effort: "<script>alert(1)</script>",
        model: "<b>negrita</b>",
      }),
    );
    assert.ok(!html.includes("<script>alert"), `script crudo: ${html.slice(0, 400)}`);
    assert.ok(!html.includes("<b>negrita"), "b crudo");
    assert.ok(html.includes("&lt;script&gt;"), "effort sin escapar");
    assert.ok(html.includes("&lt;b&gt;negrita&lt;/b&gt;"), "model sin escapar");
  });

  it("el attach_command solo aparece dentro de <code> cuando la visibilidad es degraded", () => {
    const degradado = htmlDe(docNativo(workerBase, { ...executionBase, visibility: "degraded" }));
    const codeIdx = degradado.indexOf("<code");
    assert.ok(codeIdx >= 0, "degraded sin <code>");
    const attachIdx = degradado.indexOf("attach -t =ses-f14-a");
    assert.ok(attachIdx > codeIdx, "attach fuera del <code> en degraded");
    const visible = htmlDe(docNativo(workerBase, executionBase));
    assert.ok(!visible.includes("<code"), "visible no debe pintar el attach en code");
  });

  it("trunca un model gigante a 300 caracteres", () => {
    const html = htmlDe(docNativo({ ...workerBase, model: "m".repeat(400) }));
    assert.ok(!html.includes("m".repeat(301)), "el model no se trunco");
  });

  it("sin button ni form: el attach jamas es ejecutable", () => {
    const html = htmlDe(docNativo(workerBase, { ...executionBase, visibility: "degraded" }));
    assert.ok(!html.includes("<button"), "button");
    assert.ok(!html.includes("<form"), "form");
    assert.ok(!html.includes("onclick"), "onclick");
  });

  it("atencion derivada: worker roto y rollback fallido quedan anotados", () => {
    const doc = docNativo({ ...workerBase, health: "broken" }, executionBase);
    (doc.carriles[0] as Record<string, unknown>)["delivery"] = {
      merge: { status: "pending", sha: null },
      deploy: { status: "pending", sha: null },
      canary: { status: "pending", sha: null },
      rollback: { status: "blocked", sha: null },
    };
    const html = htmlDe(doc);
    assert.match(html, /atenci[oó]n: worker-broken/);
    assert.match(html, /rollback-fallido/);
  });
});

// 14.3 r2 B2: la linea de execution pinta el inicio y el transcurrido,
// calculados contra lead.actualizado (determinista: nada de Date.now()).
describe("elapsed del carril nativo (r2 B2)", () => {
  function docConInicio(startedAt: string): ProgresoDoc {
    const doc = baseDoc();
    const c = carril({ id: "N2", estado: "implementando" }) as Record<string, unknown>;
    c["worker"] = {
      id: "claude_fable",
      harness: "claude-code",
      provider: "anthropic",
      model: "claude-fable-5-1",
      effort: null,
      reported_model: null,
      health: "available",
    };
    c["execution"] = {
      worktree: "/Users/dn/dev/wt/f14-a",
      session: "ses-f14-a",
      visibility: "visible",
      attach_command: "/opt/homebrew/bin/tmux attach -t =ses-f14-a",
      started_at: startedAt,
    };
    (doc as Record<string, unknown>)["carriles"] = [c];
    (doc as Record<string, unknown>)["cola"] = [];
    return doc as ProgresoDoc;
  }

  it("pinta inicio y minutos transcurridos hasta lead.actualizado", () => {
    const doc = docConInicio("2026-09-27T10:05:00Z");
    doc.lead.actualizado = "2026-09-27T12:05:00Z"; // 120 min de tenencia
    const html = renderTablero(doc, derivar(doc, Date.parse("2026-09-27T12:05:00Z")));
    assert.match(html, /10:05:00/, "sin la hora de inicio");
    assert.match(html, /120 min/, "sin el transcurrido");
  });

  it("started_at ausente no pinta transcurrido inventado", () => {
    const doc = docConInicio("");
    const html = renderTablero(doc, derivar(doc, Date.parse("2026-09-27T12:05:00Z")));
    assert.ok(!html.includes("NaN"), "transcurrido con NaN");
  });
});

import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it } from "node:test";

import { type ProgresoDoc } from "./lib.ts";
import {
  PLAN_CACHE_MS,
  PLAN_CONCURRENCIA,
  PLAN_PRESUPUESTO_MS,
  _resetPlanCacheForTest,
  _setPlanExecForTest,
  cruzarPlan,
  estadoDeMarcador,
  extraerItems,
} from "./plan.ts";

function fixtureDoc(): ProgresoDoc {
  return JSON.parse(
    JSON.stringify({
      schema: "runbook-progress.v1",
      runbook: "docs/runbooks/autopilot-fase12.md",
      fase: "12",
      titulo: "Tablero de corrida",
      lead: {
        agente: "claude",
        inicio: "2026-09-19T04:00:00Z",
        actualizado: "2026-09-19T04:10:00Z",
      },
      atencion_requerida: { necesaria: false, motivo: null, desde: null },
      siguiente_paso: "Cruzar el plan.",
      carriles: [],
      cola: [],
      eventos: [],
      cierre: { at: null, telegram_message_id: null, resumen: null },
    }),
  ) as ProgresoDoc;
}

function contentsFile(md: string): string {
  return JSON.stringify({
    type: "file",
    encoding: "base64",
    content: Buffer.from(md, "utf8").toString("base64"),
  });
}

const OPENCLAW_PLANS = `| id | tarea | marca |
| --- | --- | --- |
| 12.1 | nucleo | cc:TODO |
| 12.0 | contrato | cc:完了 |
`;

const ORBIT_A = `| id | tarea | marca |
| --- | --- | --- |
| 11.3 | verify | cc:DONE |
`;

const ORBIT_B = `| id | tarea | marca |
| --- | --- | --- |
| 11.1 | wip | cc:WIP |
`;

beforeEach(() => {
  _resetPlanCacheForTest();
  _setPlanExecForTest(undefined);
});

afterEach(() => {
  _setPlanExecForTest(undefined);
});

describe("constantes ancladas (12.1)", () => {
  it("PLAN_PRESUPUESTO_MS === 8000, cache 60s, concurrencia 4", () => {
    assert.equal(PLAN_PRESUPUESTO_MS, 8000);
    assert.equal(PLAN_CACHE_MS, 60_000);
    assert.equal(PLAN_CONCURRENCIA, 4);
  });
});

describe("estadoDeMarcador", () => {
  it("el mapa literal y cc:FOO es unknown", () => {
    assert.equal(estadoDeMarcador("cc:TODO"), "pendiente");
    assert.equal(estadoDeMarcador("cc:WIP"), "implementando");
    assert.equal(estadoDeMarcador("cc:完了"), "mergeado");
    assert.equal(estadoDeMarcador("cc:DONE"), "mergeado");
    assert.equal(estadoDeMarcador("cc:FOO"), "unknown");
  });
});

describe("extraerItems", () => {
  it("toma el ultimo marcador de la fila y recorta por seccion", () => {
    const md = `# Intro
| 9.9 | fuera | cc:TODO |
## Fase 12
| 12.1 | de TODO a WIP | cc:TODO luego cc:WIP |
## Fase 13
| 13.1 | otra | cc:DONE |
`;
    const items = extraerItems(md, "Fase 12");
    assert.equal(items["12.1"]?.estado, "implementando");
    assert.equal(items["12.1"]?.marcador, "cc:WIP");
    assert.equal(items["9.9"], undefined);
    assert.equal(items["13.1"], undefined);
  });

  it("cc:FOO en tabla queda unknown", () => {
    const items = extraerItems("| 12.9 | x | cc:FOO |\n", null);
    assert.equal(items["12.9"]?.estado, "unknown");
    assert.equal(items["12.9"]?.marcador, "cc:FOO");
  });
});

describe("cruzarPlan", () => {
  it("openclaw Plans.md file: 12.1 pendiente, 12.0 mergeado, argv literal", async () => {
    const llamadas: Array<{ args: readonly string[]; opts: Record<string, unknown> }> = [];
    _setPlanExecForTest((_cmd, args, opts, cb) => {
      llamadas.push({ args: [...args], opts });
      setImmediate(() => cb(null, contentsFile(OPENCLAW_PLANS)));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(r?.kind, "cruzado");
    if (r?.kind !== "cruzado") return;
    assert.equal(r.rotulo, "plan");
    assert.equal(r.items["12.1"]?.estado, "pendiente");
    assert.equal(r.items["12.1"]?.marcador, "cc:TODO");
    assert.equal(r.items["12.0"]?.estado, "mergeado");
    assert.equal(r.items["12.0"]?.marcador, "cc:完了");
    assert.equal(llamadas.length, 1);
    assert.deepEqual(llamadas[0]?.args, ["api", "repos/gon0801/goncloud-openclaw/contents/Plans.md"]);
    assert.equal(llamadas[0]?.opts.shell, false);
    assert.equal(llamadas[0]?.opts.windowsHide, true);
    assert.equal(llamadas[0]?.opts.killSignal, "SIGKILL");
  });

  it("Orbit plans/ directory: cc:DONE es mergeado (candado del sinonimo)", async () => {
    const vistas: string[] = [];
    _setPlanExecForTest((_cmd, args, opts, cb) => {
      vistas.push(String(args[1] ?? ""));
      const ruta = String(args[1] ?? "");
      if (ruta.endsWith("/contents/plans")) {
        setImmediate(() =>
          cb(
            null,
            JSON.stringify([
              { type: "file", name: "a.md", path: "plans/a.md" },
              { type: "file", name: "b.md", path: "plans/b.md" },
            ]),
          ),
        );
        return { kill() {} };
      }
      if (ruta.endsWith("/contents/plans/a.md")) {
        setImmediate(() => cb(null, contentsFile(ORBIT_A)));
        return { kill() {} };
      }
      if (ruta.endsWith("/contents/plans/b.md")) {
        setImmediate(() => cb(null, contentsFile(ORBIT_B)));
        return { kill() {} };
      }
      setImmediate(() => cb(new Error("unexpected path"), ""));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-Orbit", ruta: "plans/", seccion: null };
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(r?.kind, "cruzado");
    if (r?.kind !== "cruzado") return;
    assert.equal(r.items["11.3"]?.estado, "mergeado");
    assert.equal(r.items["11.3"]?.marcador, "cc:DONE");
    assert.equal(r.items["11.1"]?.estado, "implementando");
    assert.equal(r.items["11.1"]?.marcador, "cc:WIP");
    assert.ok(
      vistas.some((v) => v.includes("contents/plans/a.md")),
      `faltó a.md: ${vistas.join(" | ")}`,
    );
    assert.ok(
      vistas.some((v) => v.includes("contents/plans/b.md")),
      `faltó b.md: ${vistas.join(" | ")}`,
    );
    assert.ok(
      vistas.some((v) => v === "repos/gon0801/goncloud-Orbit/contents/plans"),
      `el dir no se pidió sin slash: ${vistas.join(" | ")}`,
    );
  });

  it("sin bloque plan: undefined y cero exec", async () => {
    let n = 0;
    _setPlanExecForTest(() => {
      n += 1;
      throw new Error("no debió ejecutarse");
    });
    const doc = fixtureDoc();
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(r, undefined);
    assert.equal(n, 0);
  });

  it("plan: null: nulo, cero exec", async () => {
    let n = 0;
    _setPlanExecForTest(() => {
      n += 1;
      throw new Error("no debió ejecutarse");
    });
    const doc = fixtureDoc();
    doc.plan = null;
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.deepEqual(r, { kind: "nulo", rotulo: "plan: no declarado" });
    assert.equal(n, 0);
  });

  it("gh down / quota: sin-verificar, no lanza", async () => {
    _setPlanExecForTest((_c, _a, _o, cb) => {
      setImmediate(() => cb(new Error("HTTP 403 API rate limit exceeded"), ""));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.deepEqual(r, { kind: "sin-verificar", rotulo: "plan: sin verificar" });
  });

  it("gh hang: sin-verificar dentro del presupuesto, no lanza", async () => {
    _setPlanExecForTest(() => {
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const t0 = Date.now();
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" }, { presupuesto: 500 });
    const dur = Date.now() - t0;
    assert.deepEqual(r, { kind: "sin-verificar", rotulo: "plan: sin verificar" });
    assert.ok(dur < 2_000, `el hang duró ${dur} ms`);
  });

  it("ruta missing: Not Found / 404 → ruta-no-encontrada", async () => {
    _setPlanExecForTest((_c, _a, _o, cb) => {
      const err = Object.assign(new Error("Not Found"), { status: 404 });
      setImmediate(() => cb(err, ""));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.deepEqual(r, { kind: "ruta-no-encontrada", rotulo: "plan: ruta no encontrada" });
  });

  it("discrepancia: el plan manda, el doc no se muta", async () => {
    _setPlanExecForTest((_c, _a, _o, cb) => {
      setImmediate(() =>
        cb(null, contentsFile("| 12.1 | x | cc:完了 |\n| 12.2 | y | cc:DONE |\n")),
      );
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    doc.cola = [
      {
        id: "12.1",
        prs: [],
        estado: "pendiente",
        ventana: null,
        merge_commits: [],
        verificado: null,
        detenido_por: null,
      },
      {
        id: "12.2",
        prs: [],
        estado: "verificado",
        ventana: null,
        merge_commits: [],
        verificado: "ok",
        detenido_por: null,
      },
    ];
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(r?.kind, "cruzado");
    if (r?.kind !== "cruzado") return;
    assert.equal(r.items["12.1"]?.estado, "mergeado");
    assert.equal(r.items["12.1"]?.discrepa, true);
    assert.equal(r.items["12.2"]?.estado, "mergeado");
    assert.equal(r.items["12.2"]?.discrepa, false);
    assert.equal(doc.cola[0]?.estado, "pendiente");
    assert.equal(doc.cola[1]?.estado, "verificado");
  });

  it("repo o ruta envenenados: cero exec, sin-verificar", async () => {
    let n = 0;
    _setPlanExecForTest(() => {
      n += 1;
      throw new Error("no debió ejecutarse");
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "a/b; calc.exe", ruta: "Plans.md", seccion: null };
    const r1 = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.deepEqual(r1, { kind: "sin-verificar", rotulo: "plan: sin verificar" });
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "foo/../Plans.md", seccion: null };
    const r2 = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.deepEqual(r2, { kind: "sin-verificar", rotulo: "plan: sin verificar" });
    assert.equal(n, 0);
  });

  it("caché 60s: la segunda llamada no re-ejecuta y conserva el cruce", async () => {
    let n = 0;
    _setPlanExecForTest((_c, _a, _o, cb) => {
      n += 1;
      setImmediate(() => cb(null, contentsFile("| 12.1 | x | cc:TODO |\n")));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const a = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    const b = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(n, 1);
    assert.equal(a?.kind, "cruzado");
    assert.equal(b?.kind, "cruzado");
    if (a?.kind !== "cruzado" || b?.kind !== "cruzado") return;
    assert.equal(b.items["12.1"]?.estado, "pendiente");
    assert.equal(b.items["12.1"]?.marcador, a.items["12.1"]?.marcador);
  });

  it("caché también guarda el fallo 404", async () => {
    let n = 0;
    _setPlanExecForTest((_c, _a, _o, cb) => {
      n += 1;
      setImmediate(() => cb(Object.assign(new Error("Not Found"), { status: 404 }), ""));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const a = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    const b = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(n, 1);
    assert.deepEqual(a, { kind: "ruta-no-encontrada", rotulo: "plan: ruta no encontrada" });
    assert.deepEqual(b, { kind: "ruta-no-encontrada", rotulo: "plan: ruta no encontrada" });
  });

  it("sin cola, el carril que lista el ítem alimenta discrepa", async () => {
    _setPlanExecForTest((_c, _a, _o, cb) => {
      setImmediate(() => cb(null, contentsFile("| 12.1 | x | cc:完了 |\n")));
      return { kill() {} };
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    doc.cola = [];
    doc.carriles = [
      {
        id: "A",
        nombre: "Nucleo",
        repo: "gon0801/goncloud-openclaw",
        rama: null,
        tareas: ["12.1"],
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
      },
    ];
    const r = await cruzarPlan(doc, { ghPath: "/opt/gh.exe" });
    assert.equal(r?.kind, "cruzado");
    if (r?.kind !== "cruzado") return;
    assert.equal(r.items["12.1"]?.estado, "mergeado");
    assert.equal(r.items["12.1"]?.discrepa, true);
    assert.equal(doc.carriles[0]?.estado, "pendiente");
  });

  it("ghPath .cmd: cero exec, sin-verificar", async () => {
    let n = 0;
    _setPlanExecForTest(() => {
      n += 1;
      throw new Error("no debió ejecutarse");
    });
    const doc = fixtureDoc();
    doc.plan = { repo: "gon0801/goncloud-openclaw", ruta: "Plans.md", seccion: null };
    const r = await cruzarPlan(doc, { ghPath: "C:\\tools\\gh.cmd" });
    assert.deepEqual(r, { kind: "sin-verificar", rotulo: "plan: sin verificar" });
    assert.equal(n, 0);
  });
});

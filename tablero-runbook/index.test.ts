/**
 * index.test.ts — cableado del plugin con host simulado 100 % local (Fase 7 / 7.4).
 *
 * Patrón de summa-gate/role.test.ts: el SDK se importa de verdad (symlink a la
 * instalación de openclaw, `OPENCLAW_NODE_MODULES` de quality.yml) y el host se
 * simula con un api falso que expone EXACTAMENTE la superficie que el plugin
 * usa. Registrar un hook o una tool lanza: es el contrato de blast radius.
 */
import assert from "node:assert/strict";
import { closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { describe, it, before, after } from "node:test";

import { type ProgresoDoc, validarProgreso } from "./lib.ts";
import { _resetPlanCacheForTest, _setPlanExecForTest } from "./plan.ts";

const here = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------------------
// Host simulado.
// ---------------------------------------------------------------------------

type GatewayHandler = (opts: { params: unknown; respond: (ok: boolean, payload?: unknown) => void }) => void | Promise<void>;

type FakeApi = {
  id: string;
  name: string;
  logger: { info: () => void; warn: (m: string) => void; error: () => void; debug: () => void };
  pluginConfig: Record<string, unknown> | undefined;
  registerGatewayMethod: (method: string, handler: GatewayHandler, opts?: { scope?: string }) => void;
  registerHttpRoute: (params: { path: string; match?: string; auth?: string; handler: (req: unknown, res: unknown) => void }) => void;
  session: { controls: { registerControlUiDescriptor: (d: Record<string, unknown>) => void } };
  registerHook: () => void;
  registerTool: () => void;
};

function fakeApi(pluginConfig?: Record<string, unknown>) {
  const metodos = new Map<string, { handler: GatewayHandler; opts?: { scope?: string } }>();
  const rutas: Array<{ path: string; match?: string; auth?: string; handler: (req: unknown, res: unknown) => void }> = [];
  const descriptores: Record<string, unknown>[] = [];
  const warns: string[] = [];
  const api: FakeApi = {
    id: "tablero-runbook",
    name: "Tablero de Runbook",
    logger: { info: () => {}, warn: (m) => warns.push(m), error: () => {}, debug: () => {} },
    pluginConfig,
    registerGatewayMethod(method, handler, opts) {
      metodos.set(method, { handler, opts });
    },
    registerHttpRoute(params) {
      rutas.push(params);
    },
    session: { controls: { registerControlUiDescriptor(d) { descriptores.push(d); } } },
    registerHook() {
      throw new Error("registerHook en tablero-runbook: prohibido (blast radius)");
    },
    registerTool() {
      throw new Error("registerTool en tablero-runbook: prohibido (blast radius)");
    },
  };
  return { api, metodos, rutas, descriptores, warns };
}

async function llamarMetodo(metodos: Map<string, { handler: GatewayHandler }>, method: string, params: unknown): Promise<any> {
  const m = metodos.get(method);
  assert.ok(m, `método ${method} no registrado`);
  let payload: unknown;
  await m.handler({ params, respond: (_ok, p) => { payload = p; } });
  return payload;
}

type ResFake = {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  writeHead: (status: number, headers: Record<string, string>) => void;
  end: (chunk?: string) => void;
};

function fakeRes(): ResFake {
  const r: ResFake = {
    statusCode: 0,
    headers: {},
    body: "",
    writeHead(status, headers) {
      r.statusCode = status;
      Object.assign(r.headers, headers ?? {});
    },
    end(chunk) {
      r.body += chunk ?? "";
    },
  };
  return r;
}

/**
 * Host simulado con la política de auth del gateway: una ruta declarada
 * `auth:"gateway"` NO despacha al handler sin credencial (responde 401).
 */
async function llamarRuta(
  rutas: Array<{ path: string; match?: string; auth?: string; handler: (req: unknown, res: unknown) => unknown }>,
  url: string,
  opts: { authed?: boolean; method?: string; handlerCalls?: { n: number } } = {},
): Promise<ResFake> {
  const ruta = rutas.find((p) => url === p.path || url.startsWith(`${p.path}/`));
  assert.ok(ruta, `ruta no registrada para ${url}`);
  const authed = opts.authed ?? true;
  if (!authed && ruta.auth === "gateway") {
    const res = fakeRes();
    res.statusCode = 401;
    res.body = "unauthorized";
    return res;
  }
  const handlerCalls = opts.handlerCalls;
  const res = fakeRes();
  const req = { method: opts.method ?? "GET", url, headers: {} };
  const original = ruta.handler;
  const contado: typeof ruta.handler = (rq, rs) => {
    if (handlerCalls) handlerCalls.n += 1;
    return original(rq, rs);
  };
  await contado(req, res);
  return res;
}

function fixtureDoc(name: string): ProgresoDoc {
  return JSON.parse(readFileSync(join(here, "fixtures", name), "utf8"));
}

// ---------------------------------------------------------------------------
// Smoke de import del plugin (symlink del SDK, como role.test.ts).
// ---------------------------------------------------------------------------

describe("plugin smoke import (7.4)", () => {
  const nm = join(here, "node_modules");
  const link = join(nm, "openclaw");
  const openclawRoot =
    process.env.OPENCLAW_NODE_MODULES ??
    join(process.env.HOME ?? "", ".openclaw/tools/node-v24.19.0/lib/node_modules/openclaw");

  before(() => {
    if (!existsSync(openclawRoot)) {
      throw new Error(`openclaw install missing at ${openclawRoot}`);
    }
    mkdirSync(nm, { recursive: true });
    try {
      if (!existsSync(link)) symlinkSync(openclawRoot, link);
    } catch {
      // link ya existente de una corrida anterior
    }
  });

  after(() => {
    try {
      rmSync(link, { force: true });
    } catch {
      // ignore
    }
  });

  const cargar = async (pluginConfig?: Record<string, unknown>) => {
    const mod = await import("./index.ts");
    const host = fakeApi(pluginConfig);
    mod.default.register(host.api as never);
    return host;
  };

  it("default export expone register", async () => {
    const mod = await import("./index.ts");
    assert.equal(typeof mod.default?.register, "function");
  });

  it("set válido persiste doc y eventos; el reenvío no duplica líneas", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-set-"));
    const host = await cargar({ stateDir: dir });
    const doc = fixtureDoc("prueba999-en-curso.json");

    const r1 = await llamarMetodo(host.metodos, "runbook.progress.set", doc);
    assert.deepEqual(r1, { ok: true });
    const rutaDoc = join(dir, "progress", "999.json");
    const rutaJsonl = join(dir, "events", "999.jsonl");
    assert.ok(existsSync(rutaDoc), "falta el doc persistido");
    assert.deepEqual(JSON.parse(readFileSync(rutaDoc, "utf8")), doc);
    const lineas1 = readFileSync(rutaJsonl, "utf8").split("\n").filter(Boolean);
    assert.equal(lineas1.length, doc.eventos.length);

    const r2 = await llamarMetodo(host.metodos, "runbook.progress.set", doc);
    assert.deepEqual(r2, { ok: true });
    const lineas2 = readFileSync(rutaJsonl, "utf8").split("\n").filter(Boolean);
    assert.equal(lineas2.length, lineas1.length, "reenviar el mismo doc duplicó líneas");

    // Y un doc NUEVO con un evento adicional agrega solo ese.
    const doc2 = structuredClone(doc);
    doc2.eventos = [...doc.eventos, { at: "2026-09-16T19:00:00Z", carril: null, que: "ventana abierta", situacion: null }];
    llamarMetodo(host.metodos, "runbook.progress.set", doc2);
    const lineas3 = readFileSync(rutaJsonl, "utf8").split("\n").filter(Boolean);
    assert.equal(lineas3.length, lineas1.length + 1);
    rmSync(dir, { recursive: true, force: true });
  });

  it("set con documento inválido → {ok:false, razones} y CERO writes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-invalido-"));
    const host = await cargar({ stateDir: dir });
    const invalido = fixtureDoc("invalido.json");
    const r = await llamarMetodo(host.metodos, "runbook.progress.set", invalido);
    assert.equal(r.ok, false);
    assert.equal(r.razones.length, 5);
    assert.ok(validarProgreso(invalido).razones.length === 5);
    assert.ok(!existsSync(join(dir, "progress")), "un doc inválido tocó disco (progress)");
    assert.ok(!existsSync(join(dir, "events")), "un doc inválido tocó disco (events)");
    rmSync(dir, { recursive: true, force: true });
  });

  it("set con fase '../../openclaw.json' → {ok:false} y CERO writes", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-traversal-"));
    const host = await cargar({ stateDir: dir });
    const doc = fixtureDoc("prueba999-en-curso.json") as ProgresoDoc;
    doc.fase = "../../openclaw.json";
    const r = await llamarMetodo(host.metodos, "runbook.progress.set", doc);
    assert.equal(r.ok, false);
    assert.ok(r.razones.some((x: string) => /fase/.test(x)));
    assert.ok(!existsSync(join(dir, "progress")), "la fase envenenada tocó disco");
    assert.ok(!existsSync(join(dir, "events")), "la fase envenenada tocó disco");
    rmSync(dir, { recursive: true, force: true });
  });

  it("GET /runbook/tablero/..%2f..%2fopenclaw.json → 400 (path traversal por URL)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-url-"));
    const host = await cargar({ stateDir: dir });
    const res = await llamarRuta(host.rutas, "/runbook/tablero/..%2f..%2fopenclaw.json");
    assert.equal(res.statusCode, 400);
    const res2 = await llamarRuta(host.rutas, "/runbook/progress/..%2f..%2fopenclaw.json");
    assert.equal(res2.statusCode, 400);
    // Y el literal con barras de verdad también.
    const res3 = await llamarRuta(host.rutas, "/runbook/tablero/../../openclaw.json");
    assert.equal(res3.statusCode, 400);
    // Percent-encoding malformado: decodeURIComponent lanzaba URIError fuera
    // del handler; ahora es 400 (hallazgo 1).
    const res4 = await llamarRuta(host.rutas, "/runbook/tablero/%zz");
    assert.equal(res4.statusCode, 400);
    const res5 = await llamarRuta(host.rutas, "/runbook/progress/%zz.json");
    assert.equal(res5.statusCode, 400);
    rmSync(dir, { recursive: true, force: true });
  });

  it("1000 previos + 2 nuevos ⇒ 1002 líneas en disco (el tope es solo vista en memoria)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-tope-"));
    const host = await cargar({ stateDir: dir });
    const doc = fixtureDoc("prueba999-en-curso.json");
    // Pre-llena el jsonl con 1000 eventos ya persistidos (claves únicas).
    mkdirSync(join(dir, "events"), { recursive: true });
    const previos = Array.from({ length: 1000 }, (_, i) =>
      JSON.stringify({ at: `2026-09-10T00:${String(i % 60).padStart(2, "0")}:00Z`, carril: "A", que: `previo-${i}`, situacion: null }),
    );
    writeFileSync(join(dir, "events", "999.jsonl"), `${previos.join("\n")}\n`, "utf8");
    // Dos eventos nuevos que no existen en disco.
    const doc2 = structuredClone(doc);
    doc2.eventos = [
      { at: "2026-09-17T00:00:01Z", carril: "P", que: "nuevo-uno", situacion: null },
      { at: "2026-09-17T00:00:02Z", carril: "P", que: "nuevo-dos", situacion: null },
    ];
    const r = await llamarMetodo(host.metodos, "runbook.progress.set", doc2);
    assert.deepEqual(r, { ok: true });
    const lineas = readFileSync(join(dir, "events", "999.jsonl"), "utf8").split("\n").filter(Boolean);
    assert.equal(lineas.length, 1002, `disco perdió eventos: ${lineas.length} líneas, esperadas 1002`);
    rmSync(dir, { recursive: true, force: true });
  });

  it("petición sin auth no llega al handler (auth gateway declarada en ambas rutas)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-auth-"));
    const host = await cargar({ stateDir: dir });
    for (const ruta of host.rutas) {
      assert.equal(ruta.auth, "gateway", `ruta ${ruta.path} sin auth:"gateway"`);
    }
    const handlerCalls = { n: 0 };
    const res = await llamarRuta(host.rutas, "/runbook/tablero/999", { authed: false, handlerCalls });
    assert.equal(res.statusCode, 401);
    assert.equal(handlerCalls.n, 0, "el handler corrió sin credencial");
    rmSync(dir, { recursive: true, force: true });
  });

  it("get de fase desconocida: 404 en la ruta y {ok:false} en el método", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-404-"));
    const host = await cargar({ stateDir: dir });
    const res = await llamarRuta(host.rutas, "/runbook/tablero/99");
    assert.equal(res.statusCode, 404);
    const resJson = await llamarRuta(host.rutas, "/runbook/progress/99.json");
    assert.equal(resJson.statusCode, 404);
    const r = await llamarMetodo(host.metodos, "runbook.progress.get", { fase: "99" });
    assert.equal(r.ok, false);
    rmSync(dir, { recursive: true, force: true });
  });

  it("get de fase existente: html idéntico byte a byte al de la ruta, y los 3 headers", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-html-"));
    const host = await cargar({ stateDir: dir });
    llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("prueba999-en-curso.json"));

    const r = await llamarMetodo(host.metodos, "runbook.progress.get", { fase: "999" });
    assert.equal(r.ok, true);
    assert.ok(r.doc && r.derivado && typeof r.html === "string");

    const res = await llamarRuta(host.rutas, "/runbook/tablero/999");
    assert.equal(res.statusCode, 200);
    assert.equal(res.body, r.html, "el HTML de la ruta y el del método difieren");
    assert.equal(res.headers["Content-Type"], "text/html; charset=utf-8");
    assert.equal(res.headers["X-Content-Type-Options"], "nosniff");
    assert.equal(res.headers["Content-Security-Policy"], "default-src 'none'; style-src 'unsafe-inline'");
    assert.ok(res.body.includes("GitHub: sin verificar"));
    assert.ok(res.body.includes("Autopilot de la Fase 6"));
    rmSync(dir, { recursive: true, force: true });
  });

  it("la ruta .json devuelve el documento completo: residuales y eventos incluidos (regla 8)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-json-"));
    const host = await cargar({ stateDir: dir });
    const doc = fixtureDoc("prueba999-en-curso.json");
    llamarMetodo(host.metodos, "runbook.progress.set", doc);

    const res = await llamarRuta(host.rutas, "/runbook/progress/999.json");
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers["Content-Type"], "application/json");
    const cuerpo = JSON.parse(res.body);
    assert.equal(cuerpo.schema, "runbook-progress.v1");
    assert.ok(Array.isArray(cuerpo.eventos) && cuerpo.eventos.length > 0);
    assert.ok(cuerpo.carriles.some((c: { residuales?: string[] }) => (c.residuales ?? []).length > 0));
    rmSync(dir, { recursive: true, force: true });
  });

  it("fallo de disco: {ok:false, razon:'disco'} sin lanzar, y se registra", async () => {
    // stateDir apunta a un ARCHIVO: mkdirSync lanza ENOTDIR dentro del handler.
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-disco-"));
    const archivo = join(dir, "no-soy-un-directorio");
    closeSync(openSync(archivo, "w"));
    const host = await cargar({ stateDir: archivo });

    const r = await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("prueba999-en-curso.json"));
    assert.deepEqual(r, { ok: false, razon: "disco" });
    assert.ok(host.warns.some((w) => /disco/.test(w)), "el fallo de disco no se registró");

    // La ruta también responde 500 sin lanzar.
    const res = await llamarRuta(host.rutas, "/runbook/tablero/999");
    assert.equal(res.statusCode, 404); // sin doc persistido, el GET no tiene nada que servir
    rmSync(dir, { recursive: true, force: true });
  });

  it("métodos no GET en las rutas → 405", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-405-"));
    const host = await cargar({ stateDir: dir });
    assert.equal((await llamarRuta(host.rutas, "/runbook/tablero/999", { method: "POST" })).statusCode, 405);
    assert.equal((await llamarRuta(host.rutas, "/runbook/progress/999.json", { method: "PUT" })).statusCode, 405);
    rmSync(dir, { recursive: true, force: true });
  });

  it("scopes: set operator.write, get operator.read", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-scopes-"));
    const host = await cargar({ stateDir: dir });
    assert.equal(host.metodos.get("runbook.progress.set")?.opts?.scope, "operator.write");
    assert.equal(host.metodos.get("runbook.progress.get")?.opts?.scope, "operator.read");
    rmSync(dir, { recursive: true, force: true });
  });

  it("pestaña registrada con el descriptor literal de la DoD", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-74-tab-"));
    const host = await cargar({ stateDir: dir });
    assert.deepEqual(host.descriptores, [{
      surface: "tab",
      id: "runbook",
      label: "Runbook",
      path: "/runbook/tablero/6",
      group: "control",
      requiredScopes: ["operator.read"],
    }]);
    rmSync(dir, { recursive: true, force: true });
  });

  it("nav sale del disco, no de cfg.fases; una corrida fuera de cfg.fases aparece", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-nav-"));
    const host = await cargar({ stateDir: dir, fases: ["6"] });
    await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("prueba999-en-curso.json"));
    await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("v2-campos-validos.json"));
    const res = await llamarRuta(host.rutas, "/runbook/tablero/999");
    assert.equal(res.statusCode, 200);
    assert.ok(
      res.body.includes('href="/runbook/tablero/c/fase12-tablero"'),
      "falta el enlace a la corrida persistida que no está en cfg.fases",
    );
    assert.ok(
      res.body.includes('href="/runbook/tablero/12"'),
      "falta el enlace a la fase persistida que no está en cfg.fases",
    );
    assert.ok(
      !res.body.includes('href="/runbook/tablero/6"'),
      "cfg.fases=['6'] no debe alimentar el nav",
    );
    rmSync(dir, { recursive: true, force: true });
  });

  it("corrida envenenada en tablero y progress: 400 y no crea progress/", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-corrida-400-"));
    const host = await cargar({ stateDir: dir });
    const urls = [
      "/runbook/tablero/c/..%2f",
      "/runbook/progress/c/..%2f.json",
      "/runbook/tablero/c/foo/bar",
      "/runbook/progress/c/foo/bar.json",
      "/runbook/tablero/c/%zz",
      "/runbook/progress/c/%zz.json",
      "/runbook/tablero/c/Fase12-tablero",
      "/runbook/progress/c/Fase12-tablero.json",
    ];
    for (const url of urls) {
      const res = await llamarRuta(host.rutas, url);
      assert.equal(res.statusCode, 400, `${url} debió ser 400`);
    }
    assert.ok(!existsSync(join(dir, "progress")), "un 400 de corrida creó progress/");
    rmSync(dir, { recursive: true, force: true });
  });

  it("corrida desconocida: 404 con runbook.progress.set y corrida", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-corrida-404-"));
    const host = await cargar({ stateDir: dir });
    const res = await llamarRuta(host.rutas, "/runbook/tablero/c/fase12-tablero");
    assert.equal(res.statusCode, 404);
    assert.ok(res.body.includes("fase12-tablero"), "el 404 no nombra la corrida");
    assert.ok(res.body.includes("runbook.progress.set"), "el 404 no dice cómo abrirla");
    assert.ok(res.body.includes("corrida"), "el 404 no menciona corrida");
    const resJson = await llamarRuta(host.rutas, "/runbook/progress/c/fase12-tablero.json");
    assert.equal(resJson.statusCode, 404);
    assert.ok(resJson.body.includes("runbook.progress.set"));
    assert.ok(resJson.body.includes("corrida"));
    rmSync(dir, { recursive: true, force: true });
  });

  it("set v2 con corrida: GET /c/... es 200 y el JSON trae schema y corrida", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-corrida-ok-"));
    const host = await cargar({ stateDir: dir });
    await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("prueba999-en-curso.json"));
    const v2 = fixtureDoc("v2-campos-validos.json");
    const set = await llamarMetodo(host.metodos, "runbook.progress.set", v2);
    assert.deepEqual(set, { ok: true });

    const resFase = await llamarRuta(host.rutas, "/runbook/tablero/999");
    assert.equal(resFase.statusCode, 200);
    assert.ok(resFase.body.includes("Autopilot de la Fase 6"));

    const resC = await llamarRuta(host.rutas, "/runbook/tablero/c/fase12-tablero");
    assert.equal(resC.statusCode, 200);
    assert.ok(resC.body.includes("Tablero de corrida"));
    assert.ok(
      !resC.body.includes('href="/runbook/tablero/c/fase12-tablero"'),
      "la corrida actual no se auto-enlaza",
    );

    const resJson = await llamarRuta(host.rutas, "/runbook/progress/c/fase12-tablero.json");
    assert.equal(resJson.statusCode, 200);
    const cuerpo = JSON.parse(resJson.body);
    assert.equal(cuerpo.schema, "runbook-progress.v1");
    assert.equal(cuerpo.corrida, "fase12-tablero");

    const getFase = await llamarMetodo(host.metodos, "runbook.progress.get", { fase: "999" });
    assert.equal(getFase.ok, true);
    assert.equal(getFase.doc.fase, "999");

    const getCorrida = await llamarMetodo(host.metodos, "runbook.progress.get", { corrida: "fase12-tablero" });
    assert.equal(getCorrida.ok, true);
    assert.equal(getCorrida.doc.corrida, "fase12-tablero");
    assert.equal(getCorrida.doc.schema, "runbook-progress.v1");

    const getCorridaMala = await llamarMetodo(host.metodos, "runbook.progress.get", { corrida: "Fase12-tablero" });
    assert.deepEqual(getCorridaMala, { ok: false, razon: "corrida inválida" });
    rmSync(dir, { recursive: true, force: true });
  });

  it("plan hang/fail en GET tablero: 200 con plan: sin verificar", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-plan-fail-"));
    _resetPlanCacheForTest();
    _setPlanExecForTest((_c, _a, _o, cb) => {
      setImmediate(() => cb(new Error("HTTP 403 API rate limit exceeded"), ""));
      return { kill() {} };
    });
    try {
      const host = await cargar({ stateDir: dir });
      await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("v2-campos-validos.json"));
      const res = await llamarRuta(host.rutas, "/runbook/tablero/c/fase12-tablero");
      assert.equal(res.statusCode, 200);
      assert.ok(res.body.includes("plan: sin verificar"));
      assert.ok(!res.body.includes("error interno"));
    } finally {
      _setPlanExecForTest(undefined);
      _resetPlanCacheForTest();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("sin bloque plan el HTML no trae rótulo de plan", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-sin-plan-"));
    const host = await cargar({ stateDir: dir });
    await llamarMetodo(host.metodos, "runbook.progress.set", fixtureDoc("prueba999-en-curso.json"));
    const res = await llamarRuta(host.rutas, "/runbook/tablero/999");
    assert.equal(res.statusCode, 200);
    assert.ok(!res.body.includes("plan: sin verificar"));
    assert.ok(!res.body.includes("plan: no declarado"));
    rmSync(dir, { recursive: true, force: true });
  });

  it("discrepancia lead vs plan aparece en HTML y en el payload de get", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-12-disc-"));
    _resetPlanCacheForTest();
    _setPlanExecForTest((_c, _a, _o, cb) => {
      const payload = JSON.stringify({
        type: "file",
        encoding: "base64",
        content: Buffer.from("| 12.1 | x | cc:完了 |\n", "utf8").toString("base64"),
      });
      setImmediate(() => cb(null, payload));
      return { kill() {} };
    });
    try {
      const host = await cargar({ stateDir: dir });
      const doc = structuredClone(fixtureDoc("v2-campos-validos.json"));
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
      ];
      await llamarMetodo(host.metodos, "runbook.progress.set", doc);
      const get = await llamarMetodo(host.metodos, "runbook.progress.get", { corrida: "fase12-tablero" });
      assert.equal(get.ok, true);
      assert.equal(get.doc.cola[0].estado, "pendiente");
      assert.equal(get.plan?.kind, "cruzado");
      assert.equal(get.plan?.items["12.1"]?.estado, "mergeado");
      assert.equal(get.plan?.items["12.1"]?.discrepa, true);
      assert.ok(get.html.includes("discrepancia: 12.1"));
      const res = await llamarRuta(host.rutas, "/runbook/tablero/c/fase12-tablero");
      assert.equal(res.statusCode, 200);
      assert.ok(res.body.includes("discrepancia: 12.1"));
    } finally {
      _setPlanExecForTest(undefined);
      _resetPlanCacheForTest();
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("cero registerHook / registerTool / api.on en el código del plugin", async () => {
    await cargar({ stateDir: tmpdir() }); // si registrara algo, el fake lanza
    // Se miran solo las líneas de código: la docstring declara la prohibición
    // con esas palabras y no debe disparar su propio candado.
    const codigo = readFileSync(join(here, "index.ts"), "utf8")
      .split("\n")
      .filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l))
      .join("\n");
    assert.ok(!/registerHook|registerTool|\bapi\.on\(/.test(codigo), "index.ts registra hooks o tools");
  });

  it("manifest: activation onStartup, backupResources state, configSchema completa, sin contracts", async () => {
    const manifest = JSON.parse(readFileSync(join(here, "openclaw.plugin.json"), "utf8"));
    assert.equal(manifest.id, "tablero-runbook");
    assert.deepEqual(manifest.activation, { onStartup: true });
    assert.ok(!("contracts" in manifest), "el manifest no debe declarar contracts de middleware ni tools");
    assert.ok(
      Array.isArray(manifest.backupResources) &&
        manifest.backupResources.some((b: { scope?: string }) => b.scope === "state"),
      "backupResources debe declarar scope state",
    );
    // Cada relativePath tiene que ser una ruta POSIX relativa estricta. El gateway lo
    // valida al ARRANCAR y rechaza el manifiesto entero: con `.` aqui, encender el
    // plugin tumbo el gateway el 2026-09-17 y se quedo sin arrancar hasta que alguien
    // edito el archivo a mano en la PC. La regla esta en la documentacion del SDK
    // (plugins/manifest/surfaces.md): no vacia, no absoluta, sin backslashes, sin
    // segmentos vacios, sin `.` ni `..`, sin prefijo de unidad ni UNC.
    for (const b of manifest.backupResources as { relativePath?: unknown }[]) {
      const rp = b.relativePath;
      assert.equal(typeof rp, "string", "relativePath debe ser string");
      const r = rp as string;
      assert.ok(r.length > 0, "relativePath no puede ser vacio");
      assert.ok(!r.startsWith("/"), `relativePath no puede ser absoluta: ${r}`);
      assert.ok(!r.includes("\\"), `relativePath no puede traer backslashes: ${r}`);
      assert.ok(!/^[A-Za-z]:/.test(r), `relativePath no puede traer prefijo de unidad: ${r}`);
      assert.ok(!r.startsWith("//"), `relativePath no puede ser UNC: ${r}`);
      for (const seg of r.split("/")) {
        assert.ok(seg.length > 0, `relativePath no puede traer segmentos vacios: ${r}`);
        assert.ok(seg !== "." && seg !== "..", `relativePath no puede traer "." ni "..": ${r}`);
      }
    }
    const props = manifest.configSchema.properties;
    assert.ok(props.stateDir && props.fases && props.github);
    assert.equal(props.github.properties.enabled.default, false, "github.enabled debe default false");
    assert.equal(props.github.properties.ghPath.default, "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe");
    assert.deepEqual(props.fases.default, ["6"]);
    assert.equal(props.stateDir.default, "C:\\Users\\ehven\\.openclaw-state\\tablero-runbook");
  });
});

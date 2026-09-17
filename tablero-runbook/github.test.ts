/**
 * github.test.ts — cruce con GitHub con `gh` simulado (Fase 7 / 7.5).
 *
 * El gh falso es un script real con shebang y nombre terminado en `.exe`
 * (ejecutable en macOS/Linux igual): así se ejercita execFile de verdad, con
 * su timeout, su kill y su salida por stdout, sin tocar la red. Los tests de
 * "no se ejecuta nada" inyectan un exec espía por _setGhExecForTest.
 */
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { afterEach, before, beforeEach, describe, it } from "node:test";

import {
  GH_CACHE_MS,
  GH_CONCURRENCIA,
  GH_MAX_PRS,
  GH_PRESUPUESTO_MS,
  GH_SUBCOMANDO,
  _resetGhCacheForTest,
  _setGhExecForTest,
  cruzarGitHub,
  leerGithubConfig,
  prsACruzar,
} from "./github.ts";
import { type ProgresoDoc, renderTablero, derivar, clavePr } from "./lib.ts";

const here = dirname(fileURLToPath(import.meta.url));

function fixtureDoc(name: string): ProgresoDoc {
  return JSON.parse(readFileSync(join(here, "fixtures", name), "utf8"));
}

/** Un gh falso: script con shebang nombrado *.exe. `cuerpo` es JS de node. */
function ghFalso(dir: string, nombre: string, cuerpo: string): string {
  const ruta = join(dir, nombre);
  writeFileSync(ruta, `#!${process.execPath}\n${cuerpo}\n`, "utf8");
  chmodSync(ruta, 0o755);
  return ruta;
}

beforeEach(() => {
  _resetGhCacheForTest();
  _setGhExecForTest(undefined);
});

afterEach(() => {
  _setGhExecForTest(undefined);
});

describe("constantes y configuración (7.5)", () => {
  it("los presupuestos de la DoD están anclados", () => {
    assert.equal(GH_PRESUPUESTO_MS, 8_000, "presupuesto total 8 s por render");
    assert.equal(GH_MAX_PRS, 10, "máximo 10 PRs por render");
    assert.equal(GH_CONCURRENCIA, 4, "concurrencia ≤ 4");
    assert.equal(GH_CACHE_MS, 60_000, "caché 60 s por PR");
    assert.deepEqual([...GH_SUBCOMANDO], ["pr", "view"], "subcomando fijo pr view");
  });

  it("leerGithubConfig: apagado por defecto, ghPath por defecto absoluto", () => {
    assert.deepEqual(leerGithubConfig(undefined), {
      enabled: false,
      ghPath: "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe",
    });
    assert.deepEqual(leerGithubConfig({ github: { enabled: true } }), {
      enabled: true,
      ghPath: "C:\\Users\\ehven\\.openclaw\\tools\\bin\\gh.exe",
    });
    assert.deepEqual(
      leerGithubConfig({ github: { enabled: false, ghPath: "/opt/gh.exe" } }),
      { enabled: false, ghPath: "/opt/gh.exe" },
    );
  });

  it("prsACruzar: deduplica, valida la forma y aplica el tope de 10", () => {
    const doc = fixtureDoc("fase6-diez-prs.json");
    const lista = prsACruzar(doc);
    assert.equal(lista.length, 6, "seis PRs únicos en el fixture de diez referencias");
    // Tope: 25 PRs únicos → 10.
    const grande = fixtureDoc("fase6-en-curso.json");
    grande.carriles = Array.from({ length: 25 }, (_, i) => ({
      ...grande.carriles[0],
      id: `X${i}`,
      pr: 100 + i,
    }));
    assert.equal(prsACruzar(grande).length, GH_MAX_PRS);
    // Repo/pr inválidos ni entran a la lista.
    const veneno = fixtureDoc("fase6-en-curso.json");
    veneno.carriles[0].repo = "a/b; calc.exe";
    veneno.carriles[0].pr = 1;
    veneno.carriles[1].repo = "--template x";
    veneno.carriles[1].pr = 2;
    const lista2 = prsACruzar(veneno);
    assert.ok(!lista2.some((p) => p.repo.includes("calc") || p.repo.startsWith("--")));
  });
});

describe("cruzarGitHub con gh simulado (7.5)", () => {
  it("éxito: argv literal (pr view, -R repo, --json campos), shell:false, SIGKILL", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-ok-"));
    const gh = ghFalso(dir, "gh.exe", `
      const fs = require("fs");
      const argv = process.argv.slice(2).join("\\u0000");
      fs.appendFileSync(process.env.TABLERO_ARGV_LOG ?? "/tmp/tablero-argv.log", argv + "\\n");
      process.stdout.write(JSON.stringify({
        mergeable: true,
        mergeStateStatus: "CLEAN",
        statusCheckRollup: [{ name: "Quality", status: "SUCCESS", conclusion: "SUCCESS" }],
      }));
    `);
    const logArgv = join(dir, "argv.log");
    process.env.TABLERO_ARGV_LOG = logArgv;

    const llamadas: Array<{ args: readonly string[]; opts: Record<string, unknown> }> = [];
    _setGhExecForTest(((cmd, args, opts, cb) => {
      llamadas.push({ args, opts });
      return (execFile as unknown as (c: string, a: readonly string[], o: Record<string, unknown>, cb2: (e: Error | null, s: string) => void) => { kill: (s?: string) => void })(cmd, args, opts, cb);
    }) as never);

    try {
      const doc = fixtureDoc("fase6-diez-prs.json");
      const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: gh });
      assert.equal(Object.keys(mapa).length, 6);
      for (const v of Object.values(mapa)) {
        assert.ok(typeof v === "string" && v.includes("CLEAN"), `estado inesperado: ${v}`);
        assert.ok(v.includes("checks 1/1"));
      }
      // argv: subcomando fijo y campos exactos, sin nada más.
      const lineas = readFileSync(logArgv, "utf8").split("\n").filter(Boolean);
      assert.equal(lineas.length, 6);
      for (const linea of lineas) {
        const argv = linea.split("\u0000");
        assert.equal(argv[0], "pr");
        assert.equal(argv[1], "view");
        assert.ok(argv.includes("-R"));
        assert.ok(argv.includes("--json"));
        assert.ok(argv.includes("mergeable,mergeStateStatus,statusCheckRollup"));
        assert.ok(!argv.includes("merge"), "apareció un subcomando de merge");
      }
      // opts de ejecución: sin shell, kill por SIGKILL, timeout acotado al presupuesto.
      for (const { opts } of llamadas) {
        assert.equal(opts.shell, false);
        assert.equal(opts.killSignal, "SIGKILL");
        assert.ok(typeof opts.timeout === "number" && opts.timeout <= GH_PRESUPUESTO_MS);
      }
      // El render con el mapa pinta el rótulo "GitHub" (no "sin verificar").
      const html = renderTablero(doc, derivar(doc, Date.parse("2026-09-16T19:10:00Z")), mapa);
      assert.ok(html.includes('class="gh gh-ok">GitHub: CLEAN'));
    } finally {
      delete process.env.TABLERO_ARGV_LOG;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("timeout: la fila pinta 'GitHub: unknown' y el render responde dentro del presupuesto", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-timeout-"));
    const gh = ghFalso(dir, "gh.exe", "setTimeout(() => process.stdout.write('{}'), 30000);");
    try {
      const doc = fixtureDoc("fase6-en-curso.json");
      const inicio = Date.now();
      const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: gh }, { presupuesto: 500 });
      const duracion = Date.now() - inicio;
      assert.ok(duracion < 2_000, `el cruce duró ${duracion} ms: se pasó del presupuesto`);
      for (const [clave, valor] of Object.entries(mapa)) {
        assert.ok(clave && valor === null, `un timeout debe dejar null, llegó ${valor}`);
      }
      const html = renderTablero(doc, derivar(doc), mapa);
      assert.ok(html.includes("GitHub: unknown"));
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("kill REAL al vencer: el proceso simulado no sobrevive al presupuesto", { timeout: 15_000 }, async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-kill-"));
    const pidFile = join(dir, "gh.pid");
    const gh = ghFalso(dir, "gh.exe", `
      require("fs").writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
      setTimeout(() => {}, 30000);
    `);
    try {
      const doc = fixtureDoc("fase6-en-curso.json");
      await cruzarGitHub(doc, { enabled: true, ghPath: gh }, { presupuesto: 600 });
      assert.ok(existsSync(pidFile));
      const pid = Number(readFileSync(pidFile, "utf8"));
      let vivo = true;
      try {
        process.kill(pid, 0);
      } catch {
        vivo = false;
      }
      assert.equal(vivo, false, `el gh simulado (pid ${pid}) siguió vivo tras el presupuesto`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("fixture de diez PRs: seis llamadas, concurrencia ≤ 4, render < 8 s con constantes reales", { timeout: 15_000 }, async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-diez-"));
    const gh = ghFalso(dir, "gh.exe", `
      setTimeout(() => process.stdout.write(JSON.stringify({
        mergeable: true, mergeStateStatus: "CLEAN", statusCheckRollup: [],
      })), 150);
    `);
    let enVuelo = 0;
    let maxEnVuelo = 0;
    _setGhExecForTest(((cmd, args, opts, cb) => {
      enVuelo += 1;
      maxEnVuelo = Math.max(maxEnVuelo, enVuelo);
      const child = (execFile as unknown as (c: string, a: readonly string[], o: Record<string, unknown>, cb2: (e: Error | null, s: string) => void) => { kill: (s?: string) => void })(cmd, args, opts, (e, s) => {
        enVuelo -= 1;
        cb(e, s);
      });
      return child;
    }) as never);

    try {
      const doc = fixtureDoc("fase6-diez-prs.json");
      const inicio = Date.now();
      const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: gh });
      const duracion = Date.now() - inicio;
      assert.ok(duracion < GH_PRESUPUESTO_MS, `el render con 10 refs tardó ${duracion} ms`);
      assert.equal(Object.keys(mapa).length, 6);
      assert.ok(maxEnVuelo <= GH_CONCURRENCIA, `concurrencia máxima ${maxEnVuelo} > ${GH_CONCURRENCIA}`);
      assert.ok(maxEnVuelo > 1, "no hubo paralelismo; el pool no está agrupando");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("caché de 60 s: la segunda corrida no re-ejecuta gh para el mismo PR", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-cache-"));
    let ejecuciones = 0;
    _setGhExecForTest(((cmd, args, opts, cb) => {
      ejecuciones += 1;
      setImmediate(() => cb(null, JSON.stringify({ mergeable: true, mergeStateStatus: "CLEAN", statusCheckRollup: [] })));
      return { kill: () => {} };
    }) as never);
    try {
      const doc = fixtureDoc("fase6-en-curso.json"); // 5 PRs únicos: 15, 8, 5, 43, 45
      const primera = await cruzarGitHub(doc, { enabled: true, ghPath: "/opt/gh.exe" });
      assert.equal(ejecuciones, 5, "la primera corrida consulta cada PR único una vez");
      const segunda = await cruzarGitHub(doc, { enabled: true, ghPath: "/opt/gh.exe" });
      assert.equal(ejecuciones, 5, "la segunda corrida re-ejecutó gh: la caché no sirvió");
      assert.equal(Object.keys(segunda).length, 5);
      for (const [clave, valor] of Object.entries(primera)) {
        assert.equal(segunda[clave], valor, "la caché devolvió otro valor");
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("ghPath terminado en .cmd: RECHAZADO, no se ejecuta nada y las filas quedan unknown", async () => {
    let ejecuciones = 0;
    _setGhExecForTest((() => {
      ejecuciones += 1;
      throw new Error("no debió ejecutarse");
    }) as never);
    const doc = fixtureDoc("fase6-en-curso.json");
    const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: "C:\\tools\\gh.cmd" });
    assert.equal(ejecuciones, 0);
    for (const valor of Object.values(mapa)) assert.equal(valor, null);
    const html = renderTablero(doc, derivar(doc), mapa);
    assert.ok(html.includes("GitHub: unknown"));
  });

  it("repo envenenado ('a/b; calc.exe', '--template x'): no se ejecuta nada para él", async () => {
    const vistas: string[] = [];
    _setGhExecForTest(((cmd, args, opts, cb) => {
      vistas.push(args.join(" "));
      setImmediate(() => cb(null, JSON.stringify({ mergeable: true, mergeStateStatus: "CLEAN", statusCheckRollup: [] })));
      return { kill: () => {} };
    }) as never);
    const doc = fixtureDoc("fase6-en-curso.json");
    doc.carriles[0].repo = "a/b; calc.exe";
    doc.carriles[1].repo = "--template x";
    // La misma referencia válida del PR 8 vive en la cola: se envenena ahí
    // también, para que el test mida la validación y no la deduplicación.
    doc.cola[1].prs[0] = { repo: "a/b; calc.exe", pr: 8 };
    const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: "/opt/gh.exe" });
    assert.ok(!vistas.some((v) => v.includes("calc")), `se ejecutó argv envenenado: ${vistas}`);
    assert.ok(!vistas.some((v) => v.includes("--template")), `se ejecutó argv envenenado: ${vistas}`);
    // Los envenenados no se consultan ni se les inventa estado: ausentes del
    // mapa, que el render pinta como "GitHub: unknown".
    assert.ok(!(clavePr("a/b; calc.exe", 15) in mapa));
    assert.ok(!(clavePr("--template x", 8) in mapa));
    assert.equal(vistas.length, 3, "solo los tres PRs válidos restantes (5, 43, 45) se consultan");
  });

  it("fallo de gh (exit distinto de cero, stdout basura): null y la fila pinta unknown", async () => {
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-fallo-"));
    const gh = ghFalso(dir, "gh.exe", 'process.stderr.write("gh: token expirado"); process.exit(1);');
    try {
      const doc = fixtureDoc("fase6-en-curso.json");
      const mapa = await cruzarGitHub(doc, { enabled: true, ghPath: gh }, { presupuesto: 3_000 });
      assert.equal(Object.keys(mapa).length, 5);
      for (const v of Object.values(mapa)) assert.equal(v, null);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("github.enabled: false — nada se ejecuta (7.5, cableado en index)", () => {
  // Este archivo corre ANTES que index.test.ts (orden alfabético) y importa
  // index.ts, que importa el SDK: el symlink se prepara aquí también.
  before(() => {
    const nm = join(here, "node_modules");
    const link = join(nm, "openclaw");
    const openclawRoot =
      process.env.OPENCLAW_NODE_MODULES ??
      join(process.env.HOME ?? "", ".openclaw/tools/node-v24.19.0/lib/node_modules/openclaw");
    if (!existsSync(openclawRoot)) throw new Error(`openclaw install missing at ${openclawRoot}`);
    mkdirSync(nm, { recursive: true });
    try {
      if (!existsSync(link)) symlinkSync(openclawRoot, link);
    } catch {
      // ya existente
    }
  });

  it("con enabled:false el exec no corre y el tablero dice 'GitHub: sin verificar'", async () => {
    let ejecuciones = 0;
    _setGhExecForTest(((cmd: string, args: readonly string[], opts: Record<string, unknown>, cb: (e: Error | null, s: string) => void) => {
      ejecuciones += 1;
      setImmediate(() => cb(null, JSON.stringify({ mergeable: true, mergeStateStatus: "CLEAN", statusCheckRollup: [] })));
      return { kill: () => {} };
    }) as never);

    const mod = await import("./index.ts");
    const dir = mkdtempSync(join(tmpdir(), "tablero-75-off-"));
    try {
      const metodos = new Map<string, (o: { params: unknown; respond: (ok: boolean, p?: unknown) => void }) => unknown>();
      const api = {
        id: "t", name: "t",
        logger: { info() {}, warn() {}, error() {}, debug() {} },
        pluginConfig: { stateDir: dir, github: { enabled: false, ghPath: "/opt/gh.exe" } },
        registerGatewayMethod(m: string, h: (o: never) => unknown) { metodos.set(m, h as never); },
        registerHttpRoute() {},
        session: { controls: { registerControlUiDescriptor() {} } },
      };
      mod.default.register(api as never);
      await metodos.get("runbook.progress.set")({ params: fixtureDoc("fase6-en-curso.json"), respond: () => {} });

      let payload: any;
      await metodos.get("runbook.progress.get")({ params: { fase: "6" }, respond: (_k, p) => { payload = p; } });
      assert.equal(payload.ok, true);
      assert.ok(payload.html.includes("GitHub: sin verificar"));
      assert.ok(!payload.html.includes("GitHub: unknown"));
      assert.equal(ejecuciones, 0, "con enabled:false se ejecutó gh");

      // Y encendido con el mismo espía SÍ ejecuta: la bandera es la que manda.
      const metodos2 = new Map<string, (o: { params: unknown; respond: (ok: boolean, p?: unknown) => void }) => unknown>();
      mod.default.register({
        ...api,
        pluginConfig: { stateDir: dir, github: { enabled: true, ghPath: "/opt/gh.exe" } },
        registerGatewayMethod(m: string, h: (o: never) => unknown) { metodos2.set(m, h as never); },
      } as never);
      let payload2: any;
      await metodos2.get("runbook.progress.get")({ params: { fase: "6" }, respond: (_k, p) => { payload2 = p; } });
      assert.equal(payload2.ok, true);
      assert.ok(payload2.html.includes("GitHub: CLEAN"), "con enabled:true el estado vivo debe llegar al render");
      assert.ok(ejecuciones > 0, "con enabled:true el espía debió ver ejecuciones");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

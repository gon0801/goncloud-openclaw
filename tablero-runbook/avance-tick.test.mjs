// avance-tick.test.mjs: el tick sin modelo contra un openclaw falso (sin
// gateway, sin Telegram). El falso guarda el scratch en disco con su revision
// y anota cada llamada, asi se comprueba byte por byte que lo que no se
// confirmo no toco el scratch.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, describe, it } from "node:test";

const SCRIPT = fileURLToPath(new URL("./avance-tick.mjs", import.meta.url));

const FALSO = `
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const dir = process.env.OPENCLAW_FALSO;
const args = process.argv.slice(2);
const opt = (n) => { const i = args.indexOf(n); return i < 0 ? undefined : args[i + 1]; };
const leer = (f) => readFileSync(join(dir, f), "utf8");
const salir = (texto, rc = 0) => { process.stdout.write(texto); process.exit(rc); };
const entrada = opt("--file") === "-" ? readFileSync(0, "utf8") : undefined;
appendFileSync(join(dir, "llamadas.jsonl"), JSON.stringify({ args, entrada }) + "\\n");
const [a, b] = args;
if (a === "cron" && b === "list") salir("Config warning: algo\\n" + leer("jobs.json"));
if (a === "cron" && b === "scratch") {
  const sc = JSON.parse(leer("scratch.json"));
  if (entrada === undefined) {
    salir(JSON.stringify({ scratch: sc.content === null ? null : { content: sc.content }, currentRevision: sc.revision }));
  }
  if (Number(opt("--expected-revision")) !== sc.revision) salir("cron scratch changed concurrently", 1);
  writeFileSync(join(dir, "scratch.json"), JSON.stringify({ content: entrada, revision: sc.revision + 1 }));
  salir(JSON.stringify({ ok: true, currentRevision: sc.revision + 1 }));
}
if (a === "cron" && (b === "add" || b === "edit")) {
  const jobs = JSON.parse(leer("jobs.json"));
  const conPayload = opt("--command-argv") !== undefined && !process.env.FALSO_EDIT_SIN_PAYLOAD;
  const conAlerta = args.includes("--failure-alert") && !process.env.FALSO_EDIT_SIN_ALERTA;
  const toca = (j) => {
    const n = { ...j };
    if (conPayload) n.payload = { kind: "command", argv: JSON.parse(opt("--command-argv")) };
    if (conAlerta) n.failureAlert = { channel: opt("--failure-alert-channel"), to: opt("--failure-alert-to") };
    return n;
  };
  if (b === "add") jobs.jobs.push(toca({ id: "reloj-nuevo", name: opt("--name"), declarationKey: opt("--declaration-key") }));
  else jobs.jobs = jobs.jobs.map((j) => (j.id === args[2] ? toca(j) : j));
  writeFileSync(join(dir, "jobs.json"), JSON.stringify(jobs));
  salir("{}");
}
if (a === "cron" && b === "get") {
  const jobs = JSON.parse(leer("jobs.json"));
  const j = jobs.jobs.find((x) => x.id === args[2]);
  if (!j) salir("job desconocido", 1);
  salir(JSON.stringify({ job: j }));
}
if (a === "gateway" && b === "call") {
  if (!existsSync(join(dir, "decide.json"))) salir("gateway closed (1006)", 1);
  salir("{\\n" + leer("decide.json").trim().slice(1));
}
if (a === "message" && b === "send") {
  // 19.3-5-F4: rig para el camino de CAS en conflicto: otro tick mueve la
  // revision entre el envio confirmado y la escritura del scratch.
  if (process.env.FALSO_CAS_BUMP) {
    const sc = JSON.parse(leer("scratch.json"));
    writeFileSync(join(dir, "scratch.json"), JSON.stringify({ content: sc.content, revision: sc.revision + 1 }));
  }
  const envio = process.env.ENVIO ?? "ok";
  if (envio === "falla") salir(JSON.stringify({ ok: false, error: { message: "telegram 502" } }), 1);
  if (envio === "ok-false") salir(JSON.stringify({ ok: false, action: "send", error: { message: "rechazado" } }));
  if (envio === "sin-id") salir(JSON.stringify({ action: "send", channel: "telegram", handledBy: "core", payload: {} }));
  salir(JSON.stringify({ action: "send", channel: "telegram", handledBy: "core", messageId: "7601", payload: {} }));
}
salir("comando no esperado", 2);
`;

const PREVIO = {
  schema: "seguimiento-clock.v1",
  corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: 1790650000 },
  ultimoEstado: "fase:9|0/3",
  ultimoInmediato: null,
  messageId: 7550,
  trabajosActivos: ["fase:9"],
};
const TRAS_CONFIRMAR = {
  schema: "seguimiento-clock.v1",
  corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: 1790651800 },
  ultimoEstado: "fase:9|1/3",
  ultimoInmediato: null,
  trabajosActivos: ["fase:9"],
};
const SEND = { accion: "SEND", tipo: "periodico", mensaje: "[AVANZA] Fase 9, 1 de 3", estadoTrasConfirmar: TRAS_CONFIRMAR };
const JOBS = { jobs: [
  { id: "otro-1", name: "cuotas-proveedores", declarationKey: "cuotas" },
  { id: "reloj-1", name: "avance-tareas", declarationKey: "avance-tareas", payload: { kind: "systemEvent", text: "Aviso de avance" } },
] };

let dir;
afterEach(() => dir && rmSync(dir, { recursive: true, force: true }));

function escenario({ scratch = JSON.stringify(PREVIO), decide = SEND, jobs = JOBS } = {}) {
  dir = mkdtempSync(join(tmpdir(), "avance-tick-"));
  writeFileSync(join(dir, "openclaw-falso.mjs"), FALSO);
  writeFileSync(join(dir, "jobs.json"), JSON.stringify(jobs));
  writeFileSync(join(dir, "scratch.json"), JSON.stringify({ content: scratch, revision: 4 }));
  if (decide !== null) writeFileSync(join(dir, "decide.json"), JSON.stringify(decide));
  writeFileSync(join(dir, "llamadas.jsonl"), "");
}

const cli = () => join(dir, "openclaw-falso.mjs");
const argvDelJob = () => [process.execPath, SCRIPT, "tick", "--cli", cli(), "--canal", "telegram", "--destino", "6470689715"];

function correr(modo, env = {}, cliUsado = cli()) {
  const args = [SCRIPT, modo, "--cli", cliUsado, "--canal", "telegram", "--destino", "6470689715"];
  const r = spawnSync(process.execPath, args, {
    encoding: "utf8",
    env: { ...process.env, OPENCLAW_FALSO: dir, ...env },
  });
  return { rc: r.status, stdout: r.stdout, stderr: r.stderr };
}

const scratchCrudo = () => readFileSync(join(dir, "scratch.json"), "utf8");
const llamadas = () => readFileSync(join(dir, "llamadas.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
const envios = () => llamadas().filter((l) => l.args[0] === "message");
const decideParams = () => JSON.parse(llamadas().find((l) => l.args[0] === "gateway").args[4]);

describe("avance-tick tick", () => {
  it("NO_REPLY: no manda y deja el scratch intacto", () => {
    escenario({ decide: { accion: "NO_REPLY", estado: { ...PREVIO, trabajosActivos: [] } } });
    const antes = scratchCrudo();
    const r = correr("tick");
    assert.equal(r.rc, 0, r.stderr);
    assert.deepEqual(decideParams(), { modo: "tick", estado: PREVIO });
    assert.equal(envios().length, 0);
    assert.equal(scratchCrudo(), antes);
    assert.equal(r.stdout, '{"accion":"NO_REPLY","job":"reloj-1"}\n');
  });

  it("SEND confirmado: un envio al destino y el scratch completo con messageId", () => {
    escenario();
    const r = correr("tick");
    assert.equal(r.rc, 0, r.stderr);
    assert.deepEqual(envios().map((l) => l.args), [
      ["message", "send", "--channel", "telegram", "-t", "6470689715", "--json", "-m", "[AVANZA] Fase 9, 1 de 3"],
    ]);
    const sc = JSON.parse(scratchCrudo());
    assert.equal(sc.revision, 5);
    assert.deepEqual(JSON.parse(sc.content), {
      schema: "seguimiento-clock.v1",
      corte: { kind: "reporte-confirmado", ultimoReporteConfirmado: 1790651800 },
      ultimoEstado: "fase:9|1/3",
      ultimoInmediato: null,
      trabajosActivos: ["fase:9"],
      messageId: 7601,
    });
    assert.equal(r.stdout, '{"accion":"SEND","tipo":"periodico","messageId":7601,"job":"reloj-1"}\n');
  });

  for (const envio of ["falla", "ok-false", "sin-id"]) {
    it(`SEND sin confirmar (${envio}): sale con error y el scratch queda byte por byte`, () => {
      escenario();
      const antes = scratchCrudo();
      const r = correr("tick", { ENVIO: envio });
      assert.equal(r.rc, 1);
      assert.equal(envios().length, 1);
      assert.equal(scratchCrudo(), antes);
      assert.equal(llamadas().filter((l) => l.entrada !== undefined).length, 0);
    });
  }

  it("19.3-5-F4: CAS en conflicto: un solo envio, salida 1 y sin estado nuevo", () => {
    escenario();
    const r = correr("tick", { FALSO_CAS_BUMP: "1" });
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /scratch no se escribio/);
    assert.equal(envios().length, 1);
    assert.equal(JSON.parse(scratchCrudo()).content, JSON.stringify(PREVIO));
    assert.equal(llamadas().filter((l) => l.entrada !== undefined).length, 1);
  });

  it("decide caido: sale con error, no manda, scratch intacto", () => {
    escenario({ decide: null });
    const antes = scratchCrudo();
    const r = correr("tick");
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /runbook.progress.decide no contesto/);
    assert.equal(envios().length, 0);
    assert.equal(scratchCrudo(), antes);
  });

  it("decide rechaza el estado: sale con error, no manda, scratch intacto", () => {
    escenario({ scratch: '{"nota":"escrito a mano"}', decide: { ok: false, razon: "estado-invalido" } });
    const antes = scratchCrudo();
    const r = correr("tick");
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /estado-invalido/);
    assert.equal(envios().length, 0);
    assert.equal(scratchCrudo(), antes);
  });

  it("dos crons avance-tareas: no adivina cual, no llama a decide", () => {
    escenario({ jobs: { jobs: [...JOBS.jobs, { id: "reloj-2", declarationKey: "avance-tareas" }] } });
    const r = correr("tick");
    assert.equal(r.rc, 1);
    assert.equal(llamadas().filter((l) => l.args[0] !== "cron").length, 0);
  });
});

describe("avance-tick iniciar", () => {
  const INICIAL = {
    schema: "seguimiento-clock.v1",
    corte: { kind: "esperando-primer-reporte", inicioVentana: 1790650900 },
    ultimoEstado: "fase:9|0/3",
    ultimoInmediato: null,
    messageId: null,
    trabajosActivos: ["fase:9"],
  };
  const COMUN = ["--session", "isolated", "--no-deliver", "--timeout-seconds", "240", "--command-argv"];
  const mutaciones = () => llamadas().filter((l) => l.args[0] === "cron" && (l.args[1] === "add" || l.args[1] === "edit")).map((l) => l.args);

  it("sin reloj: crea el job de comando y siembra el corte", () => {
    escenario({ scratch: null, decide: { accion: "NO_REPLY", estado: INICIAL }, jobs: { jobs: [JOBS.jobs[0]] } });
    const r = correr("iniciar");
    assert.equal(r.rc, 0, r.stderr);
    assert.deepEqual(mutaciones()[0], [
      "cron", "add", "--name", "avance-tareas", "--declaration-key", "avance-tareas", "--every", "15m",
      ...COMUN, JSON.stringify(argvDelJob()), "--json",
    ]);
    assert.deepEqual(decideParams(), { modo: "iniciar", estado: null });
    assert.deepEqual(JSON.parse(JSON.parse(scratchCrudo()).content), INICIAL);
    assert.equal(r.stdout, '{"accion":"iniciado","job":"reloj-nuevo"}\n');
    const ed1 = llamadas().filter((l) => l.args[0] === "cron" && l.args[1] === "edit");
    assert.equal(ed1.length, 1);
    assert.ok(ed1[0].args.includes("--failure-alert") && ed1[0].args.includes("6470689715"));
  });

  it("reloj de turno de agente: lo edita en su id a comando y siembra el corte", () => {
    escenario({ scratch: null, decide: { accion: "NO_REPLY", estado: INICIAL } });
    const r = correr("iniciar");
    assert.equal(r.rc, 0, r.stderr);
    assert.deepEqual(mutaciones()[0], ["cron", "edit", "reloj-1", ...COMUN, JSON.stringify(argvDelJob())]);
    assert.ok(mutaciones()[1].includes("--failure-alert"));
    assert.deepEqual(JSON.parse(JSON.parse(scratchCrudo()).content), INICIAL);
    assert.equal(r.stdout, '{"accion":"iniciado","job":"reloj-1"}\n');
  });

  it("ya convertido y con corte valido: no muta el job, no llama a decide, no escribe", () => {
    escenario({ decide: { accion: "NO_REPLY", estado: INICIAL } });
    writeFileSync(join(dir, "jobs.json"), JSON.stringify({ jobs: [
      { id: "reloj-1", declarationKey: "avance-tareas", payload: { kind: "command", argv: argvDelJob() } },
    ] }));
    const antes = scratchCrudo();
    const r = correr("iniciar");
    assert.equal(r.rc, 0, r.stderr);
    assert.equal(r.stdout, '{"accion":"ya-iniciado","job":"reloj-1"}\n');
    assert.equal(mutaciones().length, 1);
    assert.ok(mutaciones()[0].includes("--failure-alert") && mutaciones()[0].includes("6470689715"));
    assert.equal(llamadas().filter((l) => l.args[0] === "gateway").length, 0);
    assert.equal(scratchCrudo(), antes);
  });

  it("19.3-5-F3: el alta que no deja el payload falla en el read-back", () => {
    escenario({ scratch: null, decide: { accion: "NO_REPLY", estado: INICIAL } });
    const r = correr("iniciar", { FALSO_EDIT_SIN_PAYLOAD: "1" });
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /sin el payload esperado/);
  });

  it("19.3-5-F5: sin bloque de alerta el iniciar falla", () => {
    escenario({ scratch: null, decide: { accion: "NO_REPLY", estado: INICIAL } });
    const r = correr("iniciar", { FALSO_EDIT_SIN_ALERTA: "1" });
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /sin la alerta de fallo/);
  });

  it("scratch malformado: no lo pisa", () => {
    escenario({ scratch: '{"nota":"escrito a mano"}', decide: { accion: "NO_REPLY", estado: INICIAL } });
    const antes = scratchCrudo();
    const r = correr("iniciar");
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /no se pisa/);
    assert.equal(scratchCrudo(), antes);
  });

  it("cli relativo: no toca nada", () => {
    escenario({ scratch: null });
    const r = correr("iniciar", {}, "openclaw-falso.mjs");
    assert.equal(r.rc, 1);
    assert.deepEqual(llamadas(), []);
  });

  it("19.3-5-F2: cli .cmd se rechaza con el mensaje que pide el .mjs", () => {
    escenario({ scratch: null });
    const r = correr("iniciar", {}, join(dir, "openclaw.cmd"));
    assert.equal(r.rc, 1);
    assert.match(r.stderr, /\.cmd.*shell|\.mjs/);
    assert.deepEqual(llamadas(), []);
  });
});

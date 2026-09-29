// avance-tick.mjs: el tick de `avance-tareas` como job de comando, sin modelo.
//
// Uso, siempre en el host del gateway y con el node del gateway:
//   node avance-tick.mjs iniciar --cli <openclaw> --canal <canal> --destino <destino>
//   node avance-tick.mjs tick    --cli <openclaw> --canal <canal> --destino <destino>
//
// `iniciar` deja exactamente un cron `avance-tareas` cuyo payload es este
// mismo script en modo tick (lo crea o lo convierte, conservando id, horario
// y scratch) y siembra el corte si el scratch esta vacio. Arma el argv del
// job en JS porque pasar JSON con comillas por PowerShell a un .cmd pierde
// las comillas. `tick` es lo que corre el cron cada 15 minutos.
//
// `--cli` es el CLI de openclaw: un .js/.mjs/.cjs se corre con este mismo
// node (en Windows un .cmd no se lanza sin shell); otra ruta se lanza directo.
//
// Contrato (docs/spec/seguimiento.v2.md, tablero-runbook/seguimiento-clock.ts):
// el scratch solo se escribe tras entrega confirmada (sin `ok:false`, con
// messageId) y con la revision que se leyo; cualquier otra salida lo deja
// byte por byte y el siguiente tick reintenta. NO_REPLY no escribe.
import { spawnSync } from "node:child_process";
import { isAbsolute } from "node:path";
import { fileURLToPath } from "node:url";

const DECLARACION = "avance-tareas";
const SCHEMA = "seguimiento-clock.v1";
const TOPE_MS = 60_000;

function fallar(motivo) {
  process.stderr.write(`avance-tick: ${motivo}\n`);
  process.exit(1);
}

function leerArgs(argv) {
  const [modo, ...resto] = argv;
  const opciones = {};
  for (let i = 0; i < resto.length; i += 2) {
    const clave = resto[i];
    const valor = resto[i + 1];
    if (!clave?.startsWith("--") || valor === undefined) fallar(`argumento invalido: ${clave}`);
    opciones[clave.slice(2)] = valor;
  }
  if (modo !== "tick" && modo !== "iniciar") fallar("modo desconocido (tick | iniciar)");
  for (const r of ["cli", "canal", "destino"]) if (!opciones[r]) fallar(`falta --${r}`);
  return { modo, ...opciones };
}

function openclaw(cli, args, input) {
  const [cmd, previos] = /\.[cm]?js$/i.test(cli) ? [process.execPath, [cli]] : [cli, []];
  const r = spawnSync(cmd, [...previos, ...args], {
    encoding: "utf8",
    timeout: TOPE_MS,
    windowsHide: true,
    maxBuffer: 16 * 1024 * 1024,
    ...(input === undefined ? {} : { input }),
  });
  return { ok: r.status === 0, salida: r.stdout ?? "" };
}

// El CLI puede anteponer avisos de config a la salida JSON: se parsea desde
// la primera linea que abre un objeto.
function objetoDe(salida) {
  const i = salida.search(/^\{/m);
  if (i < 0) return undefined;
  try {
    const v = JSON.parse(salida.slice(i));
    return v !== null && typeof v === "object" && !Array.isArray(v) ? v : undefined;
  } catch {
    return undefined;
  }
}

function relojes(cli) {
  const r = openclaw(cli, ["cron", "list", "--all", "--json"]);
  const d = r.ok ? objetoDe(r.salida) : undefined;
  const jobs = d?.jobs ?? d?.result?.jobs;
  if (!Array.isArray(jobs)) fallar("no pude leer la lista de crons");
  return jobs.filter((j) => j?.declarationKey === DECLARACION);
}

function unReloj(cli) {
  const reloj = relojes(cli);
  if (reloj.length !== 1 || typeof reloj[0].id !== "string") {
    fallar(`se esperaba un solo cron ${DECLARACION} y hay ${reloj.length}`);
  }
  return reloj[0];
}

function leerScratch(cli, id) {
  const r = openclaw(cli, ["cron", "scratch", id, "--json"]);
  const d = r.ok ? objetoDe(r.salida) : undefined;
  if (d === undefined || !Number.isInteger(d.currentRevision)) fallar("no pude leer el scratch");
  const contenido = typeof d.scratch?.content === "string" ? d.scratch.content : null;
  return { contenido, revision: d.currentRevision };
}

function escribirScratch(cli, id, revision, estado) {
  const r = openclaw(
    cli,
    ["cron", "scratch", id, "--file", "-", "--expected-revision", String(revision)],
    JSON.stringify(estado),
  );
  return r.ok;
}

function decidir(cli, params) {
  const r = openclaw(cli, [
    "gateway", "call", "runbook.progress.decide",
    "--params", JSON.stringify(params), "--json", "--timeout", "30000",
  ]);
  const d = r.ok ? objetoDe(r.salida) : undefined;
  if (d === undefined) fallar("runbook.progress.decide no contesto");
  if (d.ok === false) fallar(`runbook.progress.decide: ${d.razon ?? "sin razon"}`);
  return d;
}

// Telegram da ids enteros; el scratch los exige enteros positivos, asi que un
// id que no lo es cuenta como entrega sin confirmar.
function messageIdDe(salida) {
  const d = objetoDe(salida);
  if (d === undefined || d.ok === false) return null;
  const v = d.messageId;
  const n = typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v) ? Number(v) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? n : null;
}

function tick(a) {
  const { id } = unReloj(a.cli);
  const { contenido, revision } = leerScratch(a.cli, id);
  let estado;
  try {
    estado = contenido === null ? null : JSON.parse(contenido);
  } catch {
    fallar("el scratch no es JSON: estado-invalido");
  }
  const d = decidir(a.cli, { modo: "tick", estado });
  if (d.accion === "NO_REPLY") {
    process.stdout.write(`${JSON.stringify({ accion: "NO_REPLY", job: id })}\n`);
    return;
  }
  if (d.accion !== "SEND" || typeof d.mensaje !== "string" || typeof d.estadoTrasConfirmar !== "object" || d.estadoTrasConfirmar === null) {
    fallar("respuesta de decide sin forma conocida");
  }
  const envio = openclaw(a.cli, [
    "message", "send", "--channel", a.canal, "-t", a.destino, "--json", "-m", d.mensaje,
  ]);
  const messageId = envio.ok ? messageIdDe(envio.salida) : null;
  if (messageId === null) fallar(`envio ${d.tipo} sin confirmar; el scratch queda como estaba`);
  if (!escribirScratch(a.cli, id, revision, { ...d.estadoTrasConfirmar, messageId })) {
    fallar(`mensaje ${messageId} confirmado pero el scratch no se escribio; el siguiente tick lo repite`);
  }
  process.stdout.write(`${JSON.stringify({ accion: "SEND", tipo: d.tipo, messageId, job: id })}\n`);
}

function argvDelTick(a) {
  return [
    process.execPath, fileURLToPath(import.meta.url), "tick",
    "--cli", a.cli, "--canal", a.canal, "--destino", a.destino,
  ];
}

// Converge el job: sin reloj lo crea; con uno que no es este comando lo edita
// (cron edit conserva id, horario y scratch); si ya es este comando no lo toca.
function asegurarJob(a) {
  if (!isAbsolute(a.cli)) fallar("--cli debe ser una ruta absoluta: el job la usa desde otro cwd");
  const argv = argvDelTick(a);
  const previos = relojes(a.cli);
  if (previos.length > 1) fallar(`hay ${previos.length} crons ${DECLARACION}: no se adivina cual es el bueno`);
  const comun = [
    "--session", "isolated", "--no-deliver", "--timeout-seconds", "240",
    "--command-argv", JSON.stringify(argv),
  ];
  const previo = previos[0];
  let r = { ok: true };
  if (previo === undefined) {
    r = openclaw(a.cli, [
      "cron", "add", "--name", DECLARACION, "--declaration-key", DECLARACION, "--every", "15m", ...comun, "--json",
    ]);
  } else if (previo.payload?.kind !== "command" || JSON.stringify(previo.payload.argv) !== JSON.stringify(argv)) {
    r = openclaw(a.cli, ["cron", "edit", previo.id, ...comun]);
  }
  if (!r.ok) fallar(`no pude dejar ${DECLARACION} como job de comando`);
  return unReloj(a.cli).id;
}

// El corte solo se siembra sobre un scratch vacio: repetirlo sobre uno valido
// no hace nada, y uno malformado se deja para que alguien lo mire (reiniciarlo
// en silencio borraria la evidencia).
function iniciar(a) {
  const id = asegurarJob(a);
  const { contenido, revision } = leerScratch(a.cli, id);
  if (contenido !== null) {
    let previo;
    try {
      previo = JSON.parse(contenido);
    } catch {
      previo = undefined;
    }
    if (previo?.schema !== SCHEMA) fallar(`el scratch de ${id} no es ${SCHEMA}; no se pisa`);
    process.stdout.write(`${JSON.stringify({ accion: "ya-iniciado", job: id })}\n`);
    return;
  }
  const d = decidir(a.cli, { modo: "iniciar", estado: null });
  if (d.accion !== "NO_REPLY" || d.estado?.schema !== SCHEMA) fallar("iniciar no devolvio el estado inicial");
  if (!escribirScratch(a.cli, id, revision, d.estado)) fallar("no pude escribir el estado inicial");
  process.stdout.write(`${JSON.stringify({ accion: "iniciado", job: id })}\n`);
}

const args = leerArgs(process.argv.slice(2));
if (args.modo === "tick") tick(args);
else iniciar(args);

// Pruebas de jev-auto/index.js con `node --test`.
// El SDK de OpenClaw no esta en este repo: se sustituye
// "openclaw/plugin-sdk/plugin-entry" por un stub identidad
// (definePluginEntry devuelve la entrada tal cual) via un loader
// registrado antes de importar el plugin.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { register } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

const loader = `
export async function resolve(specifier, context, nextResolve) {
  if (specifier === "openclaw/plugin-sdk/plugin-entry") {
    return {
      url: "data:text/javascript,export%20const%20definePluginEntry%20%3D%20(entry)%20%3D%3E%20entry%3B",
      shortCircuit: true,
    };
  }
  return nextResolve(specifier, context);
}`;
register("data:text/javascript," + encodeURIComponent(loader));

const { cleanPrompt, rutaNorm, sinSecretos, soloLectura, default: plugin } = await import("./index.js");

test("cleanPrompt deja un mensaje plano tal cual", () => {
  assert.equal(cleanPrompt("Revisa las ventas de Mercado Libre de hoy"), "Revisa las ventas de Mercado Libre de hoy");
});

test("cleanPrompt quita el bloque de contexto json y se queda con el mensaje", () => {
  const raw = 'Sender: alguien\n```json\n{"sender":"x"}\n```\n\n¿Me ayudas con las ventas de hoy?';
  assert.equal(cleanPrompt(raw), "¿Me ayudas con las ventas de hoy?");
});

test("cleanPrompt quita el contexto interno de OpenClaw", () => {
  const raw = "<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>ruido<<<END_OPENCLAW_INTERNAL_CONTEXT>>>\n\nMensaje real de David, por favor";
  assert.equal(cleanPrompt(raw), "Mensaje real de David, por favor");
});

test("cleanPrompt sin texto devuelve cadena vacia", () => {
  assert.equal(cleanPrompt(""), "");
  assert.equal(cleanPrompt(undefined), "");
});

test("rutaNorm manda los agentes de CLI a cli", () => {
  for (const a of ["claude", "kimi", "codex", "opencode", "qwen", "cursor"]) {
    assert.equal(rutaNorm(a), "cli", a);
  }
});

test("rutaNorm deja igual a los demas agentes", () => {
  assert.equal(rutaNorm("meli"), "meli");
  assert.equal(rutaNorm("amazon"), "amazon");
  assert.equal(rutaNorm("main"), "main");
});

function makePlugin(evaluate, cfg = {}) {
  const dir = mkdtempSync(join(tmpdir(), "jev-auto-"));
  const handlers = new Map();
  const injections = [];
  plugin.register({
    pluginConfig: { logPath: join(dir, "log.jsonl"), decisionsPath: join(dir, "decisions.jsonl"), ...cfg },
    logger: { warn: () => {} },
    on: (name, fn) => handlers.set(name, fn),
    runtime: { decisions: { evaluate } },
    enqueueNextTurnInjection: async (x) => { injections.push(x); },
  });
  return { handlers, injections, dir, decisionsPath: join(dir, "decisions.jsonl") };
}

function handlerDeRuteo(evaluate) {
  return makePlugin(evaluate).handlers.get("before_prompt_build");
}

const leerDecisiones = async (decisionsPath, esperadas = 1) => {
  const tope = Date.now() + 2000;
  let lineas = [];
  for (;;) {
    try {
      lineas = readFileSync(decisionsPath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    } catch { lineas = []; }
    if (lineas.length >= esperadas || Date.now() >= tope) return lineas;
    await new Promise((r) => setTimeout(r, 10));
  }
};

const leerSombra = async (logPath, esperadas = 1) => {
  const tope = Date.now() + 2000;
  let lineas = [];
  for (;;) {
    try {
      lineas = readFileSync(logPath, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
    } catch { lineas = []; }
    if (lineas.length >= esperadas || Date.now() >= tope) return lineas;
    await new Promise((r) => setTimeout(r, 10));
  }
};

const leerSombraTexto = async (logPath) => {
  const tope = Date.now() + 2000;
  let texto = "";
  for (;;) {
    try { texto = readFileSync(logPath, "utf8"); } catch { texto = ""; }
    if (texto.length > 0 || Date.now() >= tope) return texto;
    await new Promise((r) => setTimeout(r, 10));
  }
};

const EVENTO = { currentUserMessage: "Necesito revisar las ventas de Mercado Libre de esta semana" };
const ctxDe = (runId) => ({
  agentId: "main",
  sessionKey: `agent:main:test-${runId}`,
  runId,
  trigger: "user",
  inputProvenance: { kind: "external_user" },
});

test("ja2: Jev ok sin answers.q no inyecta 'undefined (0)' y devuelve null", async () => {
  const handler = handlerDeRuteo(async () => ({ ok: true, status: "ok", result: { model: "jev", answers: {} } }));
  const r = await handler(EVENTO, ctxDe("ja2-sin-respuesta"));
  assert.equal(r, undefined);
});

test("ask: answers.q vacia no inyecta nada y marca respuesta_invalida (F7)", async () => {
  const fake = async () => ({
    ok: true,
    status: "ok",
    result: { model: "jev", answers: { q: {} } },
  });
  const { handlers, decisionsPath, dir } = makePlugin(fake);
  const r = await handlers.get("before_prompt_build")(EVENTO, ctxDe("respuesta-vacia"));
  assert.equal(r, undefined);
  const lines = await leerDecisiones(decisionsPath);
  assert.ok(
    lines.some((l) => l.status === "failure" && l.error === "respuesta_invalida"),
    JSON.stringify(lines),
  );
  const sombra = await leerSombra(join(dir, "log.jsonl"), 2);
  assert.ok(
    sombra.some((l) => l.kind === "ruteo" && l.ok === false),
    JSON.stringify(sombra),
  );
  const encargo = makePlugin(fake);
  const r2 = await encargo.handlers.get("before_prompt_build")(EVENTO, {
    ...ctxDe("respuesta-vacia-encargo"),
    agentId: "meli",
  });
  assert.equal(r2, undefined);
});

test("soloLectura acepta comandos de solo lectura evidentes", () => {
  for (const cmd of ["ls -la", "ls", "git status", "git log --oneline -5", "git diff", "cat jev-auto/index.js", "pwd", "gh pr list"]) {
    assert.equal(soloLectura(cmd), true, cmd);
  }
});

test("soloLectura acepta cadenas de solo lectura con pipes", () => {
  assert.equal(soloLectura("ls | grep foo"), true);
  assert.equal(soloLectura("cat a.txt | wc -l"), true);
});

test("soloLectura rechaza comandos que escriben o ejecutan", () => {
  for (const cmd of ["rm -rf /tmp/x", "rm archivo", "git push", "git commit -m x", "cat a; rm b", "npm install"]) {
    assert.equal(soloLectura(cmd), false, cmd);
  }
});

test("soloLectura rechaza redirecciones y sustituciones", () => {
  assert.equal(soloLectura("ls > salida.txt"), false);
  assert.equal(soloLectura("echo $(whoami)"), false);
  assert.equal(soloLectura("cat <(ls)"), false);
  assert.equal(soloLectura("ls `whoami`"), false);
});

test("soloLectura rechaza vacio y find con acciones destructivas", () => {
  assert.equal(soloLectura(""), false);
  assert.equal(soloLectura(undefined), false);
  assert.equal(soloLectura("find . -delete"), false);
  assert.equal(soloLectura("find . -name '*.js'"), true);
});

test("soloLectura rechaza comandos que ejecutan, escriben o cuelgan (F2)", () => {
  for (const cmd of [
    "env ls", "env rm -rf /tmp/x", "less jev-auto/index.js", "cat a.txt | less",
    "sort -o salida.txt datos.txt", "sort --output=salida.txt datos.txt", "ls | sort -o salida.txt",
    "git diff --output=salida.txt", "git log --output=salida.txt",
    "find . -fprint salida.txt", "find . -fls salida.txt", "find . -fprintf salida.txt %p",
    "find . -exec rm {} +", "find . -execdir rm {} +", "find . -ok rm {} +", "find . -okdir rm {} +",
    "jq --rawfile raw datos.txt . datos.json", "jq --slurpfile x datos.json .", "jq --argfile x datos.json .",
    "tail -f app.log", "tail --follow app.log", "tail -F app.log",
    "uniq entrada.txt salida.txt", "git branch -D main", "git branch -d vieja", "git branch nueva-rama",
    "date -s 20250101", "date -Rs20250101", "date -us 2025-01-01", "rg --pre cat foo",
  ]) {
    assert.equal(soloLectura(cmd), false, cmd);
  }
});

test("soloLectura sigue aceptando lecturas evidentes con banderas inocuas (F2)", () => {
  for (const cmd of [
    "grep -rn foo jev-auto/index.js", "grep -o foo datos.txt", "git branch", "git branch -a", "git branch --list",
    "uniq datos.txt", "sort datos.txt", "jq . datos.json", "tail -n 20 app.log", "date +%F", "date -u", "date -R", "date +%s",
    "ls -o", "find . -name '*.js'", "cat jev-auto/index.js | grep foo | wc -l",
  ]) {
    assert.equal(soloLectura(cmd), true, cmd);
  }
});

test("soloLectura rechaza banderas peligrosas entrecomilladas o escapadas (F2 r4)", () => {
  assert.equal(soloLectura('find . "-delete"'), false);
  assert.equal(soloLectura("find . \\-delete"), false);
  assert.equal(soloLectura('sort "-o" salida.txt datos.txt'), false);
  assert.equal(soloLectura("find . '-exec' rm {} ;"), false);
  assert.equal(soloLectura('grep "foo bar" a.txt'), true);
  assert.equal(soloLectura("find . -name '*.js'"), true);
  assert.equal(soloLectura("git log --oneline"), true);
});

test("configSchema declara los umbrales que el codigo lee de cfg (F3)", () => {
  const schema = JSON.parse(readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"));
  const props = schema.configSchema.properties;
  assert.deepEqual(
    { type: props.afirmaMin.type, def: props.afirmaMin.default },
    { type: "number", def: 0.7 },
  );
  assert.deepEqual(
    { type: props.evidenciaMax.type, def: props.evidenciaMax.default },
    { type: "number", def: 0.3 },
  );
  assert.deepEqual(
    { type: props.riesgoMin.type, def: props.riesgoMin.default },
    { type: "number", def: 0.7 },
  );
  assert.deepEqual(
    { type: props.vigilante.type, def: props.vigilante.default },
    { type: "boolean", def: false },
  );
});

test("sinSecretos tapa TOKEN=valor", () => {
  assert.equal(sinSecretos("TOKEN=x"), "TOKEN=***");
  assert.equal(sinSecretos("API_TOKEN=abc123 ls"), "API_TOKEN=*** ls");
  assert.equal(sinSecretos("MY_SECRET_KEY=hunter2"), "MY_SECRET_KEY=***");
});

test("sinSecretos tapa Bearer y flags de token", () => {
  assert.equal(sinSecretos("Authorization: Bearer abcdef123"), "Authorization: Bearer ***");
  assert.equal(sinSecretos("--token abc123"), "--token ***");
});

test("sinSecretos tapa credenciales de curl, mysql, sshpass y cabeceras (S1)", () => {
  for (const [cmd, secreto] of [
    ["curl -u admin:hunter2 https://example.com", "hunter2"],
    ["curl --user a:b https://example.com", "a:b"],
    ["curl --user=a:b https://example.com", "a:b"],
    ["mysql -pClaveSegura -e 'select 1'", "ClaveSegura"],
    ["mysql -uroot -pClaveSegura db", "ClaveSegura"],
    ["mysqldump -pClaveSegura db", "ClaveSegura"],
    ["mysql --password=ClaveSegura db", "ClaveSegura"],
    ["mysql --password ClaveSegura db", "ClaveSegura"],
    ["sshpass -p ClaveSegura ssh host", "ClaveSegura"],
    ["PGPASSWORD=ClaveSegura psql -c 'select 1'", "ClaveSegura"],
    ['curl -H "Authorization: Token ClaveSegura" https://example.com', "ClaveSegura"],
    ['curl -H "Cookie: session=ClaveSegura" https://example.com', "ClaveSegura"],
    ['curl -H "X-Api-Key: ClaveSegura" https://example.com', "ClaveSegura"],
    ['curl --header "Authorization: ClaveSegura" https://example.com', "ClaveSegura"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

test("sinSecretos tapa valores entrecomillados y cabeceras sensibles (F6)", () => {
  for (const [cmd, secreto] of [
    ["mysql -p'ClaveSegura1' -e 'select 1'", "ClaveSegura1"],
    ['mysql -p"ClaveSegura2" db', "ClaveSegura2"],
    ["curl -u admin:'hunter2x' https://example.com", "hunter2x"],
    ["curl -u 'admin:hunter2y' https://example.com", "hunter2y"],
    ['curl --user="admin:clave con espacios" https://example.com', "clave con espacios"],
    ["curl -H 'PRIVATE-TOKEN: secretoH1' https://example.com", "secretoH1"],
    ['curl -H "X-Gitlab-Token: secretoH2" https://example.com', "secretoH2"],
    ["curl --header 'X-Custom-Auth: secretoH3' https://example.com", "secretoH3"],
    ["sshpass -p'ClaveSegura3' ssh host", "ClaveSegura3"],
    ['sshpass -p "ClaveSegura4" ssh host', "ClaveSegura4"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

test("soloLectura rechaza el & suelto de fondo sin romper && (S2)", () => {
  assert.equal(soloLectura("ls &rm -rf /tmp/x"), false);
  assert.equal(soloLectura("cat a & git push --force"), false);
  assert.equal(soloLectura("ls & cat a.txt"), false);
  assert.equal(soloLectura("ls && cat a.txt"), true);
});

test("comandoRiesgo no manda ni guarda el secreto en claro (S1)", async () => {
  let estadoVisto;
  const { handlers, decisionsPath } = makePlugin(async (payload) => {
    estadoVisto = payload.state;
    return {
      ok: true,
      status: "ok",
      result: {
        model: "jev",
        answers: {
          tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
          borra: { probabilityTrue: 0.1 },
          git: { probabilityTrue: 0.1 },
          prod: { probabilityTrue: 0.1 },
          envia: { probabilityTrue: 0.1 },
        },
      },
    };
  });
  await handlers.get("before_tool_call")(
    { toolName: "exec", params: { command: "curl -u admin:hunter2 https://example.com --subir" } },
    ctxTool("sin-secreto"),
  );
  assert.ok(estadoVisto?.command, "Jev debio recibir el comando");
  assert.ok(!estadoVisto.command.includes("hunter2"), estadoVisto.command);
  const lineas = await leerDecisiones(decisionsPath, 5);
  assert.ok(lineas.length > 0, "la bitacora debio escribirse");
  assert.ok(!JSON.stringify(lineas).includes("hunter2"), JSON.stringify(lineas));
  assert.ok(lineas.every((l) => !String(l.cmdPreview ?? "").includes("hunter2")));
});

test("sinSecretos tapa cadenas largas tipo token y deja el resto igual", () => {
  assert.equal(sinSecretos("echo " + "A".repeat(40)), "echo ***");
  assert.equal(sinSecretos("ls -la"), "ls -la");
  assert.equal(sinSecretos("TOKEN=x"), "TOKEN=***");
});

test("con answers.q si inyecta la sugerencia", async () => {
  const handler = handlerDeRuteo(async () => ({
    ok: true,
    status: "ok",
    result: { model: "jev", answers: { q: { choice: "meli", probabilities: { meli: 0.91 } } } },
  }));
  const r = await handler(EVENTO, ctxDe("con-respuesta"));
  assert.deepEqual(r, { prependContext: "Jev sugiere: meli (0.91)" });
});

const ctxCierre = (id) => ({
  agentId: "main",
  sessionKey: `agent:main:cierre-${id}`,
  runId: `run-${id}`,
  inputProvenance: { kind: "inter_session", sourceTool: "subagent", sourceSessionKey: "agent:meli:subagent:1" },
});
const EVENTO_CIERRE = { currentUserMessage: "Ya quedo enviado el correo al cliente y desplegado el cambio pedido" };
const evaluateCierre = (afirma, evidencia) => async () => ({
  ok: true,
  status: "ok",
  result: {
    model: "jev",
    answers: {
      estado: { choice: "quedo", probabilities: { quedo: 0.91 } },
      afirma: { probabilityTrue: afirma },
      evidencia: { probabilityTrue: evidencia },
    },
  },
});

test("cierreEvidencia: afirma sin prueba inyecta cierre y aviso (F4)", async () => {
  const { handlers, decisionsPath } = makePlugin(evaluateCierre(0.95, 0.1));
  const r = await handlers.get("before_prompt_build")(EVENTO_CIERRE, ctxCierre("sin-prueba"));
  assert.deepEqual(r, {
    prependContext: "Jev cierre: quedo (0.91)\nJev: afirma algo hecho sin prueba visible; verifícalo antes de decírselo a David",
  });
  const lines = (await leerDecisiones(decisionsPath, 3)).filter((l) => l.kind === "cierre-evidencia");
  assert.equal(lines.length, 3);
  assert.equal(lines.find((l) => l.q === "afirma").status, "acted");
  assert.equal(lines.find((l) => l.q === "evidencia").status, "acted");
});

test("cierreEvidencia: con prueba o sin afirmacion no agrega el aviso (F4)", async () => {
  const conPrueba = makePlugin(evaluateCierre(0.95, 0.9));
  const r1 = await conPrueba.handlers.get("before_prompt_build")(EVENTO_CIERRE, ctxCierre("con-prueba"));
  assert.deepEqual(r1, { prependContext: "Jev cierre: quedo (0.91)" });

  const sinAfirmacion = makePlugin(evaluateCierre(0.4, 0.1));
  const r2 = await sinAfirmacion.handlers.get("before_prompt_build")(EVENTO_CIERRE, ctxCierre("sin-afirmacion"));
  assert.deepEqual(r2, { prependContext: "Jev cierre: quedo (0.91)" });
});

const ctxTool = (id) => ({ agentId: "meli", sessionKey: `agent:meli:tool-${id}`, runId: `run-${id}` });
const evaluateRiesgo = (answers) => async () => ({
  ok: true,
  status: "ok",
  result: { model: "jev", answers },
});

test("comandoRiesgo: comando destructivo inyecta aviso y bitacora acted/below (F4)", async () => {
  const { handlers, injections, decisionsPath } = makePlugin(evaluateRiesgo({
    tipo: { choice: "destructivo", probabilities: { destructivo: 0.92 } },
    borra: { probabilityTrue: 0.95 },
    git: { probabilityTrue: 0.1 },
    prod: { probabilityTrue: 0.1 },
    envia: { probabilityTrue: 0.1 },
  }));
  await handlers.get("before_tool_call")(
    { toolName: "exec", params: { command: "rm -rf /tmp/x" } },
    ctxTool("destructivo"),
  );
  assert.equal(injections.length, 1);
  assert.match(injections[0].text, /Jev: comando riesgoso \(destructivo, borra archivos\)/);
  const lines = (await leerDecisiones(decisionsPath, 5)).filter((l) => l.kind === "comando-riesgo");
  assert.equal(lines.find((l) => l.q === "borra").status, "acted");
  assert.equal(lines.find((l) => l.q === "git").status, "below_threshold");
});

test("comandoRiesgo: Jev dice solo-lectura no inyecta aviso (F4)", async () => {
  const { handlers, injections } = makePlugin(evaluateRiesgo({
    tipo: { choice: "solo-lectura", probabilities: { "solo-lectura": 0.9 } },
    borra: { probabilityTrue: 0.1 },
    git: { probabilityTrue: 0.1 },
    prod: { probabilityTrue: 0.1 },
    envia: { probabilityTrue: 0.1 },
  }));
  await handlers.get("before_tool_call")(
    { toolName: "exec", params: { command: "npm run algo-raro" } },
    ctxTool("seguro"),
  );
  assert.equal(injections.length, 0);
});

test("comandoRiesgo: comando de solo lectura evidente no consulta a Jev (F4)", async () => {
  let calls = 0;
  const { handlers, injections } = makePlugin(async () => { calls++; throw new Error("no debio consultar"); });
  await handlers.get("before_tool_call")(
    { toolName: "exec", params: { command: "ls -la" } },
    ctxTool("solo-lectura"),
  );
  assert.equal(calls, 0);
  assert.equal(injections.length, 0);
});

test("comandoRiesgo: probabilidad que redondea al umbral actua y bitacora acted (F5)", async () => {
  const { handlers, injections, decisionsPath } = makePlugin(evaluateRiesgo({
    tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
    borra: { probabilityTrue: 0.696 },
    git: { probabilityTrue: 0.1 },
    prod: { probabilityTrue: 0.1 },
    envia: { probabilityTrue: 0.1 },
  }));
  await handlers.get("before_tool_call")(
    { toolName: "exec", params: { command: "borrado-raro --todo" } },
    ctxTool("redondeo"),
  );
  assert.equal(injections.length, 1);
  assert.match(injections[0].text, /borra archivos/);
  const lines = (await leerDecisiones(decisionsPath, 5)).filter((l) => l.kind === "comando-riesgo");
  assert.equal(lines.find((l) => l.q === "borra").status, "acted");
});

test("soloLectura: git remote exacto, file fuera, rg/gh peligrosos (F2 cierre)", () => {
  for (const cmd of [
    "git remote -v remove origin", "git remote -v add x y", "git remote add x y", "git remote prune origin",
    "git remote set-url origin x", "git remote rename a b", "git remote -v extra", "git remote --verbose",
    "file datos.txt", "file -C magia", "rg -z foo", "rg --search-zip foo", "rg --pre-glob x foo",
    "gh pr checks 3 --watch", "gh pr view 3 --web", "gh run view 1 --watch",
  ]) assert.equal(soloLectura(cmd), false, cmd);
  for (const cmd of ["git remote -v", "git remote", "rg foo", "gh pr checks 3"]) {
    assert.equal(soloLectura(cmd), true, cmd);
  }
});

test("sinSecretos tapa JSON y redis-cli (F6 cierre)", () => {
  for (const [cmd, secreto] of [
    [`curl -d '{"password":"hunter2"}' https://example.com`, "hunter2"],
    [`curl -d "{'PASSWORD': 'hunter2'}" https://example.com`, "hunter2"],
    [`curl -d '{"api_key":"hunter2"}' https://example.com`, "hunter2"],
    ["redis-cli -a hunter2 ping", "hunter2"],
    ["redis-cli -a'hunter2' ping", "hunter2"],
    ['redis-cli -a "hunter2" ping', "hunter2"],
    ["redis-cli --pass hunter2 ping", "hunter2"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

test("comandoRiesgo no persiste texto del comando, solo hash (F6 cierre)", async () => {
  const cmd = "curl -d '{\"password\":\"hunter2\"}' https://example.com --subir-datos";
  const { handlers, decisionsPath, dir } = makePlugin(evaluateRiesgo({
    tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
    borra: { probabilityTrue: 0.1 }, git: { probabilityTrue: 0.1 },
    prod: { probabilityTrue: 0.1 }, envia: { probabilityTrue: 0.1 },
  }));
  await handlers.get("before_tool_call")({ toolName: "exec", params: { command: cmd } }, ctxTool("sin-texto"));
  const lineas = await leerDecisiones(decisionsPath, 5);
  assert.ok(lineas.every((l) => !("cmdPreview" in l)), JSON.stringify(lineas));
  assert.ok(lineas.every((l) => String(l.cmdHash ?? "").startsWith("sha256:")), JSON.stringify(lineas));
  assert.ok(!JSON.stringify(lineas).includes("hunter2") && !JSON.stringify(lineas).includes("--subir-datos"));
  const sombra = await leerSombraTexto(join(dir, "log.jsonl"));
  assert.ok(!sombra.includes("hunter2") && !sombra.includes("--subir-datos"), sombra);
  assert.ok(!sombra.includes("cmdPreview"), sombra);
});

test("ask: answers.q solo con score no inyecta undefined (F7 cierre)", async () => {
  const fake = async () => ({ ok: true, status: "ok", result: { model: "jev", answers: { q: { score: 0.9 } } } });
  const { handlers, decisionsPath, dir } = makePlugin(fake);
  const r = await handlers.get("before_prompt_build")(EVENTO, ctxDe("solo-score"));
  assert.equal(r, undefined);
  const lines = await leerDecisiones(decisionsPath);
  assert.ok(lines.some((l) => l.status === "failure" && l.error === "respuesta_invalida"), JSON.stringify(lines));
  const sombra = await leerSombra(join(dir, "log.jsonl"), 2);
  assert.ok(sombra.some((l) => l.kind === "ruteo" && l.ok === false), JSON.stringify(sombra));
});

test("ask: ok sin answers.q reporta 'sin respuesta', no 'ok' (F8)", async () => {
  const fake = async () => ({ ok: true, status: "ok", result: { model: "jev", answers: {} } });
  const { handlers, dir } = makePlugin(fake);
  const r = await handlers.get("before_prompt_build")(EVENTO, ctxDe("sin-respuesta-f8"));
  assert.equal(r, undefined);
  const sombra = await leerSombra(join(dir, "log.jsonl"), 2);
  assert.ok(sombra.some((l) => l.kind === "ruteo" && l.ok === false && l.error === "sin respuesta"), JSON.stringify(sombra));
});

test("herramienta no manda ni guarda el secreto en claro (F10 r4)", async () => {
  const estados = [];
  const fake = async (payload) => {
    estados.push(payload.state);
    if (payload.questions.q) {
      return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
    }
    return {
      ok: true,
      status: "ok",
      result: {
        model: "jev",
        answers: {
          tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
          borra: { probabilityTrue: 0.1 },
          git: { probabilityTrue: 0.1 },
          prod: { probabilityTrue: 0.1 },
          envia: { probabilityTrue: 0.1 },
        },
      },
    };
  };
  const { handlers, dir } = makePlugin(fake);
  const comando = 'mysql -pClaveSegura9 -e "select 1" --consulta-larga-de-prueba';
  await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctxTool("f10-r4"));
  await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctxTool("f10-r4"));
  const estadoHerramienta = estados.find((s) => typeof s?.message === "string" && s.message.includes("anterior:"));
  assert.ok(estadoHerramienta, "Jev debio recibir el estado de herramienta");
  assert.ok(!JSON.stringify(estadoHerramienta).includes("ClaveSegura9"), JSON.stringify(estadoHerramienta));
  assert.ok(!JSON.stringify(estados).includes("ClaveSegura9"), JSON.stringify(estados));
  const sombraTexto = await leerSombraTexto(join(dir, "log.jsonl"));
  assert.ok(sombraTexto.length > 0, "el log sombra debio escribirse");
  assert.ok(!sombraTexto.includes("ClaveSegura9"), sombraTexto);
});

test("F12: exec que solo difieren en ruta/sha larga no consultan a Jev por bucle", async () => {
  let consultasHerramienta = 0;
  const fake = async (payload) => {
    if (payload.questions.q) {
      consultasHerramienta++;
      return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
    }
    return {
      ok: true,
      status: "ok",
      result: {
        model: "jev",
        answers: {
          tipo: { choice: "solo-lectura", probabilities: { "solo-lectura": 0.9 } },
          borra: { probabilityTrue: 0.1 },
          git: { probabilityTrue: 0.1 },
          prod: { probabilityTrue: 0.1 },
          envia: { probabilityTrue: 0.1 },
        },
      },
    };
  };
  const pares = [
    ["cat /una/ruta/bastante/larga/para/la/prueba/archivo-a.txt", "cat /una/ruta/bastante/larga/para/la/prueba/archivo-b.txt"],
    [`git show ${"a".repeat(40)}`, `git show ${"b".repeat(40)}`],
  ];
  for (const [i, [c1, c2]] of pares.entries()) {
    const { handlers, injections } = makePlugin(fake);
    const ctx = ctxTool(`f12-distintos-${i}`);
    await handlers.get("before_tool_call")({ toolName: "exec", params: { command: c1 } }, ctx);
    await handlers.get("before_tool_call")({ toolName: "exec", params: { command: c2 } }, ctx);
    assert.equal(injections.length, 0, `${c1} vs ${c2}`);
  }
  assert.equal(consultasHerramienta, 0);
});

test("F12: exec identicos con secreto consultan a Jev sin filtrar el secreto", async () => {
  const estados = [];
  const fake = async (payload) => {
    estados.push(payload.state);
    if (payload.questions.q) {
      return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
    }
    return {
      ok: true,
      status: "ok",
      result: {
        model: "jev",
        answers: {
          tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
          borra: { probabilityTrue: 0.1 },
          git: { probabilityTrue: 0.1 },
          prod: { probabilityTrue: 0.1 },
          envia: { probabilityTrue: 0.1 },
        },
      },
    };
  };
  const { handlers, injections, dir } = makePlugin(fake);
  const comando = 'mysql -pClaveSegura9 -e "select 1" --consulta-larga-de-prueba';
  const ctx = ctxTool("f12-identicos");
  await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctx);
  await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctx);
  const estadoHerramienta = estados.find((s) => typeof s?.message === "string" && s.message.includes("anterior:"));
  assert.ok(estadoHerramienta, "Jev debio recibir el estado de herramienta");
  assert.equal(injections.length, 1);
  assert.ok(!JSON.stringify(estados).includes("ClaveSegura9"), JSON.stringify(estados));
  const sombraTexto = await leerSombraTexto(join(dir, "log.jsonl"));
  assert.ok(sombraTexto.length > 0, "el log sombra debio escribirse");
  assert.ok(!sombraTexto.includes("ClaveSegura9"), sombraTexto);
  assert.ok(!JSON.stringify([...globalThis.__jevAuto.lastCall.values()]).includes("ClaveSegura9"));
  assert.ok(!JSON.stringify([...globalThis.__jevAuto.asked.keys()]).includes("ClaveSegura9"));
});

test("soloLectura rechaza abreviaturas de opciones largas peligrosas (F2 r5)", () => {
  for (const cmd of [
    "sort --out=x datos.txt", "sort --out x datos.txt", "sort --comp=gzip datos.txt",
    "date --se=20250101", "tail --fol app.log", "git diff --outp=x",
  ]) {
    assert.equal(soloLectura(cmd), false, cmd);
  }
});

test("soloLectura acepta opciones largas inocuas y cortas (F2 r5)", () => {
  for (const cmd of ["git log --oneline", "sort -n datos.txt", "tail -n 5 app.log", "ls --all"]) {
    assert.equal(soloLectura(cmd), true, cmd);
  }
});

test("sinSecretos tapa cookie/proxy-user/-U y login -p (F13)", () => {
  for (const [cmd, secreto] of [
    ['curl -b "PHPSESSID=abc123F13" https://example.com', "abc123F13"],
    ["curl --cookie 'sid=abc123F13' https://example.com", "abc123F13"],
    ["curl -U userF13:passF13 https://example.com", "passF13"],
    ["curl --proxy-user userF13:passF13 https://example.com", "passF13"],
    ["docker login -p ClaveF13 registry.example.com", "ClaveF13"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
  const proxy = sinSecretos("curl --proxy-user userF13:passF13 https://example.com");
  assert.ok(proxy.includes("--proxy-user"), proxy);
  assert.ok(proxy.includes("***"), proxy);
  assert.ok(!proxy.includes("userF13"), proxy);
});

test("sinSecretos tapa -b/-U pegados, con espacio y entrecomillados (F13)", () => {
  for (const [cmd, secreto] of [
    ["curl -bPHPSESSID=pegadaF13 https://example.com", "pegadaF13"],
    ["curl -b PHPSESSID=pegadaF13 https://example.com", "pegadaF13"],
    ["curl -b 'PHPSESSID=pegadaF13' https://example.com", "pegadaF13"],
    ['curl -b "PHPSESSID=pegadaF13" https://example.com', "pegadaF13"],
    ["curl -UpegadoF13:claveF13 https://example.com", "claveF13"],
    ["curl -U pegadoF13:claveF13 https://example.com", "claveF13"],
    ["curl -U 'pegadoF13:claveF13' https://example.com", "claveF13"],
    ['curl -U "pegadoF13:claveF13" https://example.com', "claveF13"],
    ["podman login -p ClaveF13 registry.example.com", "ClaveF13"],
    ["helm login -p ClaveF13 registry.example.com", "ClaveF13"],
    ["nerdctl login -p ClaveF13 registry.example.com", "ClaveF13"],
    ["docker login -pClavePegadaF13 registry.example.com", "ClavePegadaF13"],
    ['docker login -p "ClaveF13" registry.example.com', "ClaveF13"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

test("sinSecretos: opciones largas user/cookie/session/login/credential tapan valor completo (F13)", () => {
  for (const [cmd, secreto] of [
    ["curl --cookie=sidF13=valorF13 https://example.com", "valorF13"],
    ['curl --session "sesion con espaciosF13" https://example.com', "espaciosF13"],
    ["curl --credential 'cred con espaciosF13' https://example.com", "espaciosF13"],
    ["tool --login usuarioF13 --otro 1", "usuarioF13"],
    ["tool --user=usuarioF13:claveF13", "claveF13"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

test("sinSecretos no tapa --password-stdin ni comandos sin secretos (F13)", () => {
  assert.equal(sinSecretos("docker login --password-stdin registry.example.com"), "docker login --password-stdin registry.example.com");
  assert.equal(sinSecretos("curl -s https://example.com/api"), "curl -s https://example.com/api");
});

test("sinSecretos no confunde banderas cortas dentro de otra palabra o bandera larga (F14)", () => {
  for (const [cmd, secreto] of [
    ["mysql -h db-prod -pClaveSegura db", "ClaveSegura"],
    ["mysql --port=3307 -pClaveSegura db", "ClaveSegura"],
    ["curl --upload-file f -u admin:hunter2 https://x", "hunter2"],
    ["redis-cli -h cache-app -a hunter2 ping", "hunter2"],
    ["mysqldump -h db-prod -pClaveSegura db", "ClaveSegura"],
    ["sshpass -o proxy-prod -p hunter2 ssh host", "hunter2"],
    ["docker login reg-prod -p ClaveF14 registry.example.com", "ClaveF14"],
    ["curl -H 'X-U: x' -U userF14:passF14 https://example.com", "passF14"],
  ]) {
    const limpio = sinSecretos(cmd);
    assert.ok(!limpio.includes(secreto), `${cmd} -> ${limpio}`);
    assert.ok(limpio.includes("***"), `${cmd} -> ${limpio}`);
  }
});

const PARAMS_LARGOS = { consulta: "listar las sesiones abiertas de esta prueba larga" };
const CTX_EXTERNO = { agentId: "main", sessionKey: "agent:main:main" };

async function dosSessionsList(toolCallId, ctx, extraEvent = {}) {
  let calls = 0;
  const { handlers, dir } = makePlugin(async () => {
    calls++;
    return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
  });
  const handler = handlers.get("before_tool_call");
  await handler({ toolName: "sessions_list", toolCallId: `${toolCallId}-1`, params: PARAMS_LARGOS, ...extraEvent }, ctx);
  await handler({ toolName: "sessions_list", toolCallId: `${toolCallId}-2`, params: PARAMS_LARGOS, ...extraEvent }, ctx);
  await new Promise((r) => setTimeout(r, 50));
  let texto = "";
  try { texto = readFileSync(join(dir, "log.jsonl"), "utf8"); } catch { texto = ""; }
  return { calls, texto, enLastCall: globalThis.__jevAuto.lastCall.has(ctx.sessionKey) };
}

test("a) invocacion externa http-: sessions_list repetida no consulta a Jev ni escribe en el registro", async () => {
  const r = await dosSessionsList("http-x", CTX_EXTERNO);
  assert.equal(r.calls, 0);
  assert.equal(r.texto, "");
  assert.equal(r.enLastCall, false);
});

test("b) invocacion externa rpc-: sessions_list repetida no consulta a Jev ni escribe en el registro", async () => {
  const r = await dosSessionsList("rpc-x", CTX_EXTERNO);
  assert.equal(r.calls, 0);
  assert.equal(r.texto, "");
  assert.equal(r.enLastCall, false);
});

test("c) llamadas identicas de un turno con runId si consultan a Jev por bucle", async () => {
  const r = await dosSessionsList("toolu_turno", { ...CTX_EXTERNO, runId: "run-turno" });
  assert.equal(r.calls, 1);
});

test("d) llamada sin runId con toolCallId toolu_ no se salta: se compara como hoy", async () => {
  const r = await dosSessionsList("toolu_abc", CTX_EXTERNO);
  assert.equal(r.calls, 1);
});

test("e) exec externo http- con comando riesgoso sigue pasando por comandoRiesgo", async () => {
  let calls = 0;
  const fakeRiesgo = evaluateRiesgo({
    tipo: { choice: "destructivo", probabilities: { destructivo: 0.92 } },
    borra: { probabilityTrue: 0.95 },
    git: { probabilityTrue: 0.1 },
    prod: { probabilityTrue: 0.1 },
    envia: { probabilityTrue: 0.1 },
  });
  const { handlers, injections } = makePlugin(async (payload) => { calls++; return fakeRiesgo(payload); });
  await handlers.get("before_tool_call")(
    { toolName: "exec", toolCallId: "http-x-1", params: { command: "rm -rf /tmp/x" } },
    CTX_EXTERNO,
  );
  assert.equal(calls, 1);
  assert.equal(injections.length, 1);
  assert.match(injections[0].text, /Jev: comando riesgoso/);
});

test("f) runId en ctx con toolCallId http- de turno si consulta a Jev", async () => {
  const r = await dosSessionsList("http-turno", { ...CTX_EXTERNO, runId: "run-turno" });
  assert.equal(r.calls, 1);
});

test("g) runId solo en el event con toolCallId rpc- de turno si consulta a Jev", async () => {
  const r = await dosSessionsList("rpc-turno", CTX_EXTERNO, { runId: "run-turno" });
  assert.equal(r.calls, 1);
});

async function dosExec(params1, params2, id) {
  const estados = [];
  let consultasHerramienta = 0;
  const fake = async (payload) => {
    estados.push(payload.state);
    if (payload.questions.q) {
      consultasHerramienta++;
      return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
    }
    return {
      ok: true,
      status: "ok",
      result: {
        model: "jev",
        answers: {
          tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
          borra: { probabilityTrue: 0.1 },
          git: { probabilityTrue: 0.1 },
          prod: { probabilityTrue: 0.1 },
          envia: { probabilityTrue: 0.1 },
        },
      },
    };
  };
  const { handlers, injections } = makePlugin(fake);
  const ctx = ctxTool(id);
  const handler = handlers.get("before_tool_call");
  await handler({ toolName: "exec", params: params1 }, ctx);
  await handler({ toolName: "exec", params: params2 }, ctx);
  return { consultasHerramienta, estados, injections };
}

test("title: dos exec de un turno identicos salvo title si consultan a Jev (1 vez)", async () => {
  const comando = "esperar-cambio --revisar-estado-largo";
  const r = await dosExec(
    { command: comando, title: "x (1)" },
    { command: comando, title: "x (2)" },
    "title-distinto",
  );
  assert.equal(r.consultasHerramienta, 1);
});

test("title: dos exec de un turno identicos salvo description si consultan a Jev (1 vez)", async () => {
  const comando = "esperar-cambio --revisar-estado-largo";
  const r = await dosExec(
    { command: comando, description: "descripcion uno larga" },
    { command: comando, description: "descripcion dos distinta" },
    "description-distinta",
  );
  assert.equal(r.consultasHerramienta, 1);
});

test("title: dos exec con command distinto y mismo title no consultan a Jev", async () => {
  const r = await dosExec(
    { command: "esperar-cambio --revisar-estado-uno", title: "x" },
    { command: "esperar-cambio --revisar-estado-dos", title: "x" },
    "command-distinto",
  );
  assert.equal(r.consultasHerramienta, 0);
});

test("title: el mensaje que recibe Jev no contiene el texto del title", async () => {
  const comando = "esperar-cambio --revisar-estado-largo";
  const r = await dosExec(
    { command: comando, title: "TituloCosmeticoUnico (1)" },
    { command: comando, title: "TituloCosmeticoUnico (2)" },
    "title-no-a-jev",
  );
  const estadoHerramienta = r.estados.find((s) => typeof s?.message === "string" && s.message.includes("anterior:"));
  assert.ok(estadoHerramienta, "Jev debio recibir el estado de herramienta");
  assert.ok(!JSON.stringify(estadoHerramienta).includes("TituloCosmeticoUnico"), JSON.stringify(estadoHerramienta));
  assert.ok(estadoHerramienta.message.includes(comando), estadoHerramienta.message);
});

test("herramienta: comillas en el comando no filtran el secreto a Jev ni al log (F15)", async () => {
  for (const [i, [comando, secreto]] of [
    ['mysql -p"ClaveSegura9" db', "ClaveSegura9"],
    ['curl -H "X-Api-Key: abc123secreto" https://x', "abc123secreto"],
  ].entries()) {
    const estados = [];
    const fake = async (payload) => {
      estados.push(payload.state);
      if (payload.questions.q) {
        return { ok: true, status: "ok", result: { model: "jev", answers: { q: { probabilityTrue: 0.95 } } } };
      }
      return {
        ok: true,
        status: "ok",
        result: {
          model: "jev",
          answers: {
            tipo: { choice: "reversible", probabilities: { reversible: 0.8 } },
            borra: { probabilityTrue: 0.1 },
            git: { probabilityTrue: 0.1 },
            prod: { probabilityTrue: 0.1 },
            envia: { probabilityTrue: 0.1 },
          },
        },
      };
    };
    const { handlers, dir } = makePlugin(fake);
    const ctx = ctxTool(`f15-${i}`);
    await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctx);
    await handlers.get("before_tool_call")({ toolName: "exec", params: { command: comando } }, ctx);
    const estadoHerramienta = estados.find((s) => typeof s?.message === "string" && s.message.includes("anterior:"));
    assert.ok(estadoHerramienta, "Jev debio recibir el estado de herramienta");
    assert.ok(!JSON.stringify(estados).includes(secreto), JSON.stringify(estados));
    const sombraTexto = await leerSombraTexto(join(dir, "log.jsonl"));
    assert.ok(sombraTexto.length > 0, "el log sombra debio escribirse");
    assert.ok(!sombraTexto.includes(secreto), sombraTexto);
  }
});

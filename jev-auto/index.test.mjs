// Pruebas de jev-auto/index.js con `node --test`.
// El SDK de OpenClaw no esta en este repo: se sustituye
// "openclaw/plugin-sdk/plugin-entry" por un stub identidad
// (definePluginEntry devuelve la entrada tal cual) via un loader
// registrado antes de importar el plugin.
import assert from "node:assert/strict";
import { register } from "node:module";
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

const { cleanPrompt, rutaNorm, default: plugin } = await import("./index.js");

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

function handlerDeRuteo(evaluate) {
  const handlers = new Map();
  plugin.register({
    pluginConfig: {},
    logger: { warn: () => {} },
    on: (name, fn) => handlers.set(name, fn),
    runtime: { decisions: { evaluate } },
  });
  return handlers.get("before_prompt_build");
}

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

test("con answers.q si inyecta la sugerencia", async () => {
  const handler = handlerDeRuteo(async () => ({
    ok: true,
    status: "ok",
    result: { model: "jev", answers: { q: { choice: "meli", probabilities: { meli: 0.91 } } } },
  }));
  const r = await handler(EVENTO, ctxDe("con-respuesta"));
  assert.deepEqual(r, { prependContext: "Jev sugiere: meli (0.91)" });
});

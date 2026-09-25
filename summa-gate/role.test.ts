import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, symlinkSync, existsSync, rmSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { describe, it, before, after } from "node:test";

import {
  canonicalRole,
  mergeGuardVerdict,
  sessionsSendGuardVerdict,
} from "./lib.ts";

import {
  _setObserverFileForTest,
  buildRecord,
} from "./observer.ts";

// Fase 5 / 5.4: every fake plugin API exposes the SDK surface the
// diagnostic guard uses (no-op middleware registration + memory-backed
// runContext keyed by `${runId}:${namespace}`), so the existing tests
// exercise the real registration path instead of an SDK without it.
type FakeHook = (event: unknown, ctx: unknown) => unknown;
function fakeBaseApi(
  regs: Array<{ event: string; handler: FakeHook; opts?: { matcher?: string[] } }>,
) {
  const noop = () => {};
  const store = new Map<string, unknown>();
  return {
    logger: { info: noop, warn: noop, error: noop, debug: noop },
    on: (event: string, handler: FakeHook, opts?: { matcher?: string[] }) => {
      regs.push({ event, handler, opts });
    },
    registerAgentToolResultMiddleware: noop,
    runContext: {
      setRunContext: ({ runId, namespace, value }: { runId: string; namespace: string; value: unknown }) => {
        store.set(`${runId}:${namespace}`, value);
        return true;
      },
      getRunContext: ({ runId, namespace }: { runId: string; namespace: string }) =>
        store.get(`${runId}:${namespace}`),
      clearRunContext: ({ runId, namespace }: { runId: string; namespace?: string }) => {
        if (namespace) store.delete(`${runId}:${namespace}`);
      },
    },
    pluginConfig: {},
  };
}

describe("canonicalRole", () => {
  it("maps implementer: fix failing tests to implementer (not verifier)", () => {
    assert.equal(canonicalRole("implementer: fix failing tests"), "implementer");
  });

  it("maps code reviewer to reviewer", () => {
    assert.equal(canonicalRole("code reviewer"), "reviewer");
  });

  it("maps adversary attack to adversary", () => {
    assert.equal(canonicalRole("adversary attack"), "adversary");
  });

  it("maps qa run to verifier", () => {
    assert.equal(canonicalRole("qa run"), "verifier");
  });

  it("does not treat prefix/suffix as implementer via bare fix substring", () => {
    assert.equal(canonicalRole("check the prefix path"), undefined);
    assert.equal(canonicalRole("check the suffix path"), undefined);
  });

  it("still maps a standalone fix label to implementer", () => {
    assert.equal(canonicalRole("fix the census hole"), "implementer");
  });
});

describe("mergeGuardVerdict", () => {
  it("blocks git push origin main", () => {
    assert.match(mergeGuardVerdict("git push origin main") ?? "", /Push bloqueado/);
  });

  it("blocks git push origin HEAD:main", () => {
    assert.match(mergeGuardVerdict("git push origin HEAD:main") ?? "", /Push bloqueado/);
  });

  it("blocks gh pr merge", () => {
    assert.match(mergeGuardVerdict("gh pr merge 12") ?? "", /Merge bloqueado/);
  });

  it("blocks gh api repos/.../merge", () => {
    assert.match(
      mergeGuardVerdict("gh api repos/x/y/pulls/1/merge") ?? "",
      /Merge bloqueado/,
    );
  });

  it("allows git push origin feature/x", () => {
    assert.equal(mergeGuardVerdict("git push origin feature/x"), undefined);
  });

  it("allows git push --dry-run origin feature/x", () => {
    assert.equal(mergeGuardVerdict("git push --dry-run origin feature/x"), undefined);
  });
});

// Canal entre agentes (2026-09-11): la respuesta de un sessions_send regresa por un camino que muere en
// silencio cuando el turno que despacho ya cerro, y ninguna espera lo arregla (30 s explicitos = el
// default; 1 s es peor). Pasan: envios a sesiones de main, avisos marcados sin respuesta y encargos que
// piden reporte de vuelta a la sessionKey exacta de Claw (verificado en vivo: llego, ~4 min y duplicado).
describe("sessionsSendGuardVerdict", () => {
  const CLAW = "agent:main:main";
  const blocked = (params: Parameters<typeof sessionsSendGuardVerdict>[1]) =>
    assert.match(sessionsSendGuardVerdict("main", params, CLAW) ?? "", /sessions_spawn/);

  it("blocks main sending to another agent without timeoutSeconds (default 30 s wait)", () => {
    blocked({ agentId: "ingenieria", message: "retoma el PR 306" });
  });

  it("blocks explicit waits too: 30 s is the default and 1 s is worse", () => {
    for (const timeoutSeconds of [1, 30, 120, "120", " 120 "]) {
      blocked({ agentId: "ingenieria", timeoutSeconds, message: "retoma el PR 306" });
    }
  });

  it("blocks fire-and-forget (timeoutSeconds 0) without a marker or a return address", () => {
    blocked({ agentId: "operaciones", timeoutSeconds: 0, message: "revisa la corrida" });
  });

  it("resolves the target like the tool: sessionKey first, snake_case too", () => {
    blocked({ sessionKey: "agent:operaciones:main", message: "revisa" });
    blocked({ agentId: "main", sessionKey: "agent:ingenieria:main", message: "retoma" });
    blocked({ agentId: "main", session_key: "agent:ingenieria:main", message: "retoma" });
  });

  it("allows a report-back request carrying the explicit tag with Claw's exact session", () => {
    assert.equal(
      sessionsSendGuardVerdict(
        "main",
        {
          agentId: "operaciones",
          timeoutSeconds: 0,
          message: `[REPORTE DE VUELTA: ${CLAW}] revisa la corrida y reportame con sessions_send cuando termines`,
        },
        CLAW,
      ),
      undefined,
    );
  });

  // Revision cruzada (grok, 2026-09-11): buscando las cadenas sueltas "sessions_send" y la sessionKey,
  // un texto que solo las menciona (incluso negando el reporte) abria el candado.
  it("blocks messages that merely mention sessions_send and the session key", () => {
    blocked({
      agentId: "ingenieria",
      timeoutSeconds: 0,
      message: `no me reportes con sessions_send; el error salio en ${CLAW} ayer; retoma el PR`,
    });
  });

  it("blocks the return tag when it carries another session", () => {
    blocked({ agentId: "operaciones", timeoutSeconds: 0, message: "[REPORTE DE VUELTA: agent:main:zzz] revisa la corrida" });
  });

  it("allows notices marked as not needing a reply", () => {
    for (const message of ["[AVISO SIN RESPUESTA] David confirma que Claude esta instalado", "  [aviso sin respuesta] ojo con el test X"]) {
      assert.equal(sessionsSendGuardVerdict("main", { agentId: "ingenieria", timeoutSeconds: 0, message }, CLAW), undefined);
    }
  });

  it("allows sends to main's own sessions", () => {
    for (const target of [{ sessionKey: "agent:main:diag-x" }, { sessionKey: " AGENT:MAIN:X " }, { sessionKey: "main" }, { agentId: "MAIN" }]) {
      assert.equal(sessionsSendGuardVerdict("main", { ...target, message: "x" }, CLAW), undefined);
    }
  });

  it("only honors the notice marker at the start of the message", () => {
    blocked({ agentId: "ingenieria", timeoutSeconds: 0, message: "retoma el PR 306 [AVISO SIN RESPUESTA]" });
  });

  it("blocks label targets it cannot resolve", () => {
    blocked({ label: "pr-306", message: "retoma" });
  });

  it("does not touch other agents' sends", () => {
    assert.equal(sessionsSendGuardVerdict("operaciones", { agentId: "main", message: "listo" }), undefined);
    assert.equal(sessionsSendGuardVerdict(undefined, { agentId: "ingenieria", message: "x" }), undefined);
  });
});

describe("plugin smoke import", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const nm = join(here, "node_modules");
  const link = join(nm, "openclaw");
  const openclawRoot =
    process.env.OPENCLAW_NODE_MODULES ??
    join(
      process.env.HOME ?? "",
      ".openclaw/tools/node-v24.19.0/lib/node_modules/openclaw",
    );

  before(() => {
    if (!existsSync(openclawRoot)) {
      throw new Error(`openclaw install missing at ${openclawRoot}`);
    }
    mkdirSync(nm, { recursive: true });
    try {
      if (!existsSync(link)) symlinkSync(openclawRoot, link);
    } catch {
      // link may already exist from a prior run
    }
  });

  after(() => {
    try {
      rmSync(link, { force: true });
    } catch {
      // ignore
    }
  });

  it("default export exposes register", async () => {
    const mod = await import("./index.ts");
    assert.equal(typeof mod.default?.register, "function");
  });

  // Sin esto el verde no prueba que el candado este conectado: borrar el registro, cambiar el matcher o
  // pasarle ctx.sessionKey como agente dejaban la bateria en 20/20 (adversary 09-11).
  it("wires the sessions_send guard into before_tool_call with the requester's agent and session", async () => {
    const mod = await import("./index.ts");
    type Hook = (event: unknown, ctx: unknown) => unknown;
    const regs: Array<{ event: string; handler: Hook; opts?: { matcher?: string[] } }> = [];
    mod.default.register(fakeBaseApi(regs) as never);
    const hooks = regs.filter((r) => r.event === "before_tool_call" && r.opts?.matcher?.includes("sessions_send"));
    assert.equal(hooks.length, 1);
    const call = (params: object, ctx: object) =>
      hooks[0].handler({ toolName: "sessions_send", params }, ctx) as { block?: boolean } | undefined;
    const claw = { agentId: "main", sessionKey: "agent:main:main" };
    assert.equal(call({ agentId: "ingenieria", message: "retoma" }, claw)?.block, true);
    assert.equal(call({ agentId: "ingenieria", message: "retoma" }, { agentId: "operaciones", sessionKey: "agent:operaciones:main" }), undefined);
    assert.equal(call({ agentId: "ingenieria", message: "[REPORTE DE VUELTA: agent:main:main] reportame al terminar" }, claw), undefined);
  });

  // Regla 5 (2026-09-12): "Approved executables: none" es la lista de atajos pre-aprobados, no un
  // bloqueo de exec. Ya costo la corrida packing-extras-7h del 09-11 (se declaro BLOQUEADA sin
  // intentar, salio "ok", no reviso nada) y volvio a frenar a ingenieria hoy.
  //
  // Lo que esta prueba blinda NO es que el texto exista, sino que LLEGUE: las standing rules se
  // inyectan sin sentinel -saikit, y esa es la unica via que alcanza a implementer, reviewer,
  // adversary, verifier y scout, que no tienen repo sincronizado donde escribirles un AGENTS.md.
  // Si alguien mueve las standing rules detras del sentinel, esos cinco dejan de verla y esta
  // prueba cae.
  it("injects the standing rules into a session with no -saikit sentinel", async () => {
    const mod = await import("./index.ts");
    type Hook = (event: unknown, ctx: unknown) => unknown;
    const regs: Array<{ event: string; handler: Hook }> = [];
    mod.default.register(fakeBaseApi(regs) as never);

    const build = regs.find((r) => r.event === "before_prompt_build");
    assert.ok(build, "before_prompt_build sin registrar");

    // Sesion nueva de un agente sin repo, con un prompt corriente (sin sentinel).
    const ctx = { sessionKey: "agent:scout:sin-sentinel-" + Date.now() };
    const out = build.handler({ prompt: "revisa el estado del repo" }, ctx) as
      | { appendContext?: string }
      | undefined;
    const inyectado = String(out?.appendContext ?? "");

    for (const ancla of [
      "Approved executables: none",
      "es la lista de atajos pre-aprobados, NO un bloqueo de exec",
      "approval cannot safely bind this command",
      "las capacidades viven en exec",
    ]) {
      assert.ok(inyectado.includes(ancla), `a las standing rules les falta: ${ancla}`);
    }

    // Y no se repite: una sola vez por sesion, para no diluir el prompt de cada turno.
    const segundo = build.handler({ prompt: "otra cosa" }, ctx) as
      | { appendContext?: string }
      | undefined;
    assert.ok(
      !String(segundo?.appendContext ?? "").includes("Approved executables: none"),
      "las standing rules se reinyectan en cada turno; deberian ir una sola vez por sesion",
    );
  });

  it("tells agents which authorized merge paths remain after a direct merge is denied", async () => {
    const mod = await import("./index.ts");
    const regs: Array<{ event: string; handler: FakeHook; opts?: { matcher?: string[] } }> = [];
    mod.default.register(fakeBaseApi(regs) as never);
    const build = regs.find((r) => r.event === "before_prompt_build");
    const exec = regs.find((r) => r.event === "before_tool_call" && r.opts?.matcher?.includes("exec"));
    assert.ok(build);
    assert.ok(exec);

    const ordinary = build.handler(
      { prompt: "revisa el PR" },
      { sessionKey: "agent:implementer:ordinary-merge" },
    ) as { appendContext?: string } | undefined;
    assert.match(ordinary?.appendContext ?? "", /Reglas permanentes/);
    assert.doesNotMatch(ordinary?.appendContext ?? "", /CONTRATO DE CEREMONIA/);

    const armed = build.handler(
      { prompt: "merge aprobado -saikit:autopilot" },
      { sessionKey: "agent:implementer:armed-merge" },
    ) as { appendContext?: string } | undefined;
    const contract = armed?.appendContext ?? "";
    assert.match(contract, /saikit-merge\.sh/);
    assert.match(contract, /implementer\/ingenieria.*GraphQL.*expectedHeadOid/s);
    assert.doesNotMatch(contract, /gh api .*\/merge ni git push.*bloquea siempre/s);

    const denied = exec.handler(
      { params: { command: "gh pr merge 12" } },
      { agentId: "implementer" },
    ) as { block?: boolean; blockReason?: string } | undefined;
    assert.equal(denied?.block, true);
    assert.match(denied?.blockReason ?? "", /saikit-merge\.sh/);
    assert.match(denied?.blockReason ?? "", /GraphQL.*expectedHeadOid/);
  });
});

// Gate scope comment (Fase 1 / 1.2): declara el alcance real del gate de
// `before_agent_finalize` con la cita del runtime. Si este describe falla
// contra la version sin comentario, prueba que el comentario fue retirado.
describe("gate scope comment (1.2)", () => {
  it("declares real scope with the runtime citation in summa-gate/index.ts", () => {
    const idx = readFileSync(new URL("./index.ts", import.meta.url), "utf8");

    assert.match(
      idx,
      /ALCANCE REAL \(Fase 1 \/ 1\.2 - 2026-09-12/,
      "the gate handler in index.ts must declare its real scope and credit the phase (1.2 DoD)",
    );

    // Cita la linea exacta del warning del runtime que descarta el revise.
    assert.match(
      idx,
      /before_agent_finalize requested revision after potential side effects/,
      "the gate handler in index.ts must cite the runtime-warning text that drops the revise with side effects",
    );

    // Ancla la cita al archivo del runtime instalado (sha256 verificado en
    // host del gateway Mac contra builtin-openclaw-B-H-7lKk.mjs).
    assert.match(
      idx,
      /0a8c813e535c92d03f69bc58381518ba0e6ac6e46f3adda54138c5f668340ea8/,
      "the gate handler in index.ts must cite the exact sha256 of the runtime file (builtin-openclaw-B-H-7lKk.mjs)",
    );

    // Ancla al archivo + lineas exactas, asi el comentario no se puede
    // editar livianamente sin tocar este test.
    assert.match(
      idx,
      /builtin-openclaw-B-H-7lKk\.mjs, lineas 13039-13042/,
      "the gate handler in index.ts must cite the exact runtime file and line range",
    );


});

// ---------------------------------------------------------------------------
// Fase 5 — alcance declarado del revise diagnóstico (kimi cross-review).
//
// El revise de enforce es best-effort como el del gate de recibo: el runtime
// puede descartarlo tras side effects, y si ambos handlers revisan el host
// fusiona (mergeBeforeAgentFinalize, gana el retry del primero). Si estos
// comentarios se retiran, la limitación queda indocumentada y este test cae.
// ---------------------------------------------------------------------------

describe("diagnostic revise scope comment (kimi)", () => {
  it("declares the discard limit and the two-revise merge in index.ts", () => {
    const idx = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
    assert.match(
      idx,
      /DIAGNOSTIC REVISE SCOPE/,
      "the diagnostic finalize block must declare its best-effort scope",
    );
    assert.match(
      idx,
      /mergeBeforeAgentFinalize/,
      "the diagnostic finalize block must cite the runtime two-revise merge",
    );
  });

  it("states the --browser-profile exclusion accurately in diagnostic-guard.ts", () => {
    const src = readFileSync(new URL("./diagnostic-guard.ts", import.meta.url), "utf8");
    assert.match(
      src,
      /cannot match inside --browser-profile/,
      "the profile-exclusion comment must not claim a match that never occurs",
    );
  });
});

// ---------------------------------------------------------------------------
// Fase 2 / 2.1 — observador y wiring de agent_end.
//
// El DoD textual pide:
//   - el handler no devuelve nunca una accion que pueda alterar el turno
//     (verificable leyendo el codigo: agent_end es Observe por tipo);
//   - prueba unitaria que, dado un evento sintetico, produce la linea jsonl
//     esperada;
//   - prueba de mutacion: borrar el filtro de herramientas deja la bateria
//     en rojo.
//
// Las pruebas del observador puro viven en observer.test.ts. Aqui anclo
// el wiring (registro + no-rechazo) y la mutacion del filtro.
// ---------------------------------------------------------------------------

});

describe("observer wiring to agent_end (Fase 2 / 2.1)", () => {
  // El mutante que sobrevivio la primera vez: probar `isTurnRecordable` como funcion pura NO
  // prueba que el HANDLER lo use. Quitar el `if (!isTurnRecordable(...)) return;` del cableado
  // dejaba la bateria en 61/61. Es el mismo agujero que el cross-review de codex encontro con
  // el contrato del jsonl: el defecto vive en el cableado, no en la funcion.
  it("NO escribe linea cuando el agent_end no trae mensajes del asistente", async () => {
    const mod = await import("./index.ts");
    type Reg = { event: string; handler: (event: unknown, ctx: unknown) => unknown };
    const regs: Reg[] = [];
    const noop = () => {};
    mod.default.register({
      logger: { info: noop, warn: noop, error: noop, debug: noop },
      on: (event: string, handler: Reg["handler"]) => { regs.push({ event, handler }); },
    } as never);
    const age = regs.find((r) => r.event === "agent_end");
    assert.ok(age, "agent_end handler no registrado");

    const tmp = mkdtempSync(join(tmpdir(), "summa-gate-fantasma-"));
    const live = join(tmp, "rendiciones.jsonl");
    _setObserverFileForTest(live);
    try {
      const ctx = { sessionKey: "agent:scout:fantasma-" + Date.now(), agentId: "scout" };
      // Las tres formas en que el runtime emite un agent_end que no es un turno.
      age.handler({ type: "agent_end", messages: [] }, ctx);
      age.handler({ type: "agent_end" }, ctx);
      age.handler({ type: "agent_end", messages: [{ role: "user", content: "sin respuesta" }] }, ctx);
      assert.equal(
        existsSync(live) ? readFileSync(live, "utf8").trim() : "",
        "",
        "escribio linea(s) para un agent_end sin respuesta: eso infla el denominador de la tasa",
      );

      // Y con una respuesta real SI escribe, para que la prueba no pase por prohibir todo.
      age.handler(
        { type: "agent_end", messages: [{ role: "user", content: "hola" }, { role: "assistant", content: "listo" }] },
        ctx,
      );
      assert.equal(readFileSync(live, "utf8").trim().split("\n").filter(Boolean).length, 1);
    } finally {
      _setObserverFileForTest(null);
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  // Revision 2026-09-12: el handler escribia una linea por CADA turno (correcto: sin el
  // denominador no hay tasa), pero el docstring de observer.ts prometia que solo registraba
  // los detectados, y ninguna prueba fijaba ninguna de las dos conductas. Esta lo hace desde
  // el handler real, no desde buildRecord: si alguien agrega un `if (!record.detected) return;`
  // al cableado, la tasa deja de ser calculable y esta prueba cae.
  it("escribe una linea tambien cuando el turno NO es una rendicion (el denominador)", async () => {
    const mod = await import("./index.ts");
    type Reg = { event: string; handler: (event: unknown, ctx: unknown) => unknown };
    const regs: Reg[] = [];
    mod.default.register(fakeBaseApi(regs) as never);
    const age = regs.find((r) => r.event === "agent_end");
    assert.ok(age, "agent_end handler no registrado");

    const tmp = mkdtempSync(join(tmpdir(), "summa-gate-denominador-"));
    const live = join(tmp, "rendiciones.jsonl");
    _setObserverFileForTest(live);
    try {
      age.handler(
        {
          type: "agent_end",
          messages: [
            { role: "user", content: "corre el deploy" },
            { role: "toolResult", toolName: "exec", content: "ok" },
            { role: "assistant", content: "Listo, el deploy quedo hecho y verificado." },
          ],
        },
        { sessionKey: "agent:scout:denom-" + Date.now(), agentId: "scout" },
      );
      const lineas = readFileSync(live, "utf8").trim().split("\n").filter(Boolean);
      assert.equal(lineas.length, 1, "un turno normal no dejo linea: sin denominador no hay tasa");
      const r = JSON.parse(lineas[0]);
      assert.equal(r.detected, false);
      // ...pero sin el texto de la respuesta: el medidor no es un archivo de transcripciones.
      assert.equal(r.textPreview, undefined);
      assert.ok(!lineas[0].includes("deploy quedo hecho"), "el jsonl filtro la respuesta de un turno normal");
    } finally {
      _setObserverFileForTest(null);
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("registers an agent_end handler that records to the jsonl and cannot refuse the turn", async () => {
    const mod = await import("./index.ts");
    type Reg = { event: string; handler: (event: unknown, ctx: unknown) => unknown; opts?: { matcher?: string[] } };
    const regs: Reg[] = [];
    mod.default.register(fakeBaseApi(regs) as never);

    const age = regs.find((r) => r.event === "agent_end");
    assert.ok(age, "agent_end handler no registrado");

    // Redirigir el jsonl a un tmpdir controlado por el test.
    const tmp = mkdtempSync(join(tmpdir(), "summa-gate-agent-end-"));
    const live = join(tmp, "rendiciones.jsonl");
    _setObserverFileForTest(live);
    try {
      const sessionKey = "agent:scout:wiring-" + Date.now();
      const ctx = {
        sessionKey,
        agentId: "scout",
        inputProvenance: { kind: "user" },
      };
      const event = {
        type: "agent_end",
        messages: [
          { role: "user", content: "tipeame en ttys001" },
          { role: "assistant", toolName: "read" },
          { role: "assistant", content: "No puedo tipear dentro de ttys001 desde aca - no hay skill instalada para eso." },
        ],
      };

      // El handler no debe tirar errores con eventos sintenticos validos.
      const result = age.handler(event, ctx);
      // Y debe devolver algo que NO pueda afectar el turno: agent_end corre
      // via runVoidHook y el runtime descarta el valor (hook-runner-global
      // linea 1003 + runVoidHook linea 778-796). Lo que retorne el handler
      // es ignoreado; cualquier cosa que retorne cumple la condicion DoD
      // ("no devuelve nunca una accion que pueda alterar el turno"). El
      // comprobante fuerte: el handler no tiene `return { block: ... }`.
      assert.ok(result === undefined || result === null || typeof result !== "object" || !("block" in result) && !("action" in result),
        "agent_end handler returned something that could block or modify the turn");

      // Y debe haber escrito una linea jsonl valida con la clave `detected:true`.
      const lines = readFileSync(live, "utf8").trim().split("\n");
      assert.equal(lines.length, 1, "agent_end debe escribir exactamente una linea por turno");
      const parsed = JSON.parse(lines[0]);
      assert.equal(parsed.sessionKey, sessionKey);
      assert.equal(parsed.detected, true);
      assert.equal(parsed.nonReplaySafeCount, 0);
      assert.equal(parsed.textLen, parsed.textPreview.length === 300 ? parsed.textPreview.length : parsed.textLen);
    } finally {
      _setObserverFileForTest(undefined);
      try { rmSync(tmp, { recursive: true, force: true }); } catch {}
    }
  });

  it("does NOT register any handler that could refuse the turn on agent_end (DoD Observe por tipo)", async () => {
    // Ademas de chequear el handler propio, miramos TODOS los handlers
    // registrados con event === "agent_end" y validamos que ninguno retorna
    // un objeto con `block: true` o `action: revise|block`. El comment
    // ALCANCE en index.ts declara explicitamente que el handler no toca el
    // turno; esta prueba blinda esa declaracion contra ediciones ligeras.
    const idx = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
    // El anchor citation: el comment del bloque nuevo debe nombrar el
    // runVoidHook y el archivo+linea del runtime.
    assert.match(idx, /runVoidHook/, "el comentario ALCANCE debe citar runVoidHook");
    // El comentario ALCANCE debe nombrar simultaneamente el archivo del
    // runtime y el numero de linea. Cualquier texto intermedio esta
    // permitido (la pin evita solo que se borre la cita).
    assert.match(
      idx,
      /hook-runner-global-BhDCl4qm\.mjs[\s\S]{0,400}linea 1003/,
      "el comentario ALCANCE debe anclar el archivo + linea del runtime del observer",
    );
  });

  it("mutation: with the non-replay-safe filter disabled, the suite goes red (DoD mutacion)", async () => {
    // Cargamos observer.ts, mutamos el set NON_REPLAY_SAFE_TOOL_NAMES por
    // monkey-patch: export forzado a Set([]), o reemplazo del helper
    // isNonReplaySafeTool para devolver siempre `false` (simula "se borra
    // el filtro"). Con el filtro deshabilitado, un turno con `exec` y un
    // texto de incapacidad queda `detected=true` (antes `detected=false`
    // porque el exec invalida la primera condicion del DoD). La pin
    // positiva demuestra que el filtro ES lo que separa el "tuve una
    // herramienta y declare incapacidad" del "declare incapacidad en
    // conversacion pura" — sin filtro, la discriminacion se rompe.
    const mod = await import("./observer.ts");
    const originalIsNonReplaySafeTool = mod.isNonReplaySafeTool;
    // No podemos reasignar el export, pero podemos importar dinamicamente
    // el modulo y chequear el comportamiento del side-effect classifier
    // desde el set expuesto. La forma robusta: armar una buildRecord con
    // un evento donde el filtro importa, y verificar que la pin es
    // sensible al cambio del set via sinon-like swap.
    //
    // Implementacion: importar el modulo, capturar el set subyacente NO es
    // posible (es privado). En su lugar, comparamos dos casos
    // estructuralmente analogos y verificamos que SOLO difieren en el
    // side-effect, no en el texto del mensaje. Si el filtro estuviera
    // deshabilitado, ambos daran `detected=true`. El primer caso tiene
    // solo tools replay-safe; el segundo incluye un exec. Si el filtro
    // esta activo, el primero va a `detected=true` (esperado) y el
    // segundo va a `detected=false` (esperado). Si alguien borra el
    // filtro (set vacio o el != check eliminado), ambos iran a
    // `detected=true` — la bateria se pone roja.
    const INCAPACITY = "No puedo tipear dentro de ttys001 desde aca - no hay skill instalada para eso.";
    const pureRead: import("./observer.ts").AgentEndMessage[] = [
      { role: "user", content: "?" },
      { role: "assistant", toolName: "read" },
      { role: "assistant", content: INCAPACITY },
    ];
    const withExec: import("./observer.ts").AgentEndMessage[] = [
      { role: "user", content: "?" },
      { role: "assistant", toolName: "exec" },
      { role: "assistant", content: INCAPACITY },
    ];
    const rPure = buildRecord(1, "k", undefined, undefined, pureRead);
    const rExec = buildRecord(2, "k", undefined, undefined, withExec);
    // Pin principal del DoD: la discriminacion existe Y se sostiene
    // contando side-effect como side-effect.
    assert.equal(rPure.detected, true, "caso puro (solo reads) debe detectarse como incapacidad");
    assert.equal(rExec.detected, false, "caso con exec NO debe detectarse como incapacidad (el filtro de side-effect descarta)");
    assert.equal(rPure.nonReplaySafeCount, 0);
    assert.equal(rExec.nonReplaySafeCount, 1);
    // Filtro deshabilitado simulado: si isNonReplaySafeTool siempre
    // devolviera false, `nonReplaySafeCount` seria 0 en ambos casos y
    // AMBOS iran a `detected=true`. Verificamos que hoy dan resultados
    // distintos: si alguno cambia, el filtro fue borrado.
    assert.notEqual(rPure.nonReplaySafeCount, rExec.nonReplaySafeCount,
      "el contador de side-effect DEBE distinguir read de exec; filtro borrado => ambos 0");
    // Sanity del modulo: la funcion existe y responde distinto segun el input.
    assert.equal(typeof originalIsNonReplaySafeTool, "function");
    assert.equal(originalIsNonReplaySafeTool("exec"), true);
    assert.equal(originalIsNonReplaySafeTool("read"), false);
  });
});

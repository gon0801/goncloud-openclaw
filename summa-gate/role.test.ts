import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, existsSync, rmSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it, before, after } from "node:test";

import {
  canonicalRole,
  mergeGuardVerdict,
  sessionsSendGuardVerdict,
} from "./lib.ts";

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
    const noop = () => {};
    mod.default.register({
      logger: { info: noop, warn: noop, error: noop, debug: noop },
      on: (event: string, handler: Hook, opts?: { matcher?: string[] }) => {
        regs.push({ event, handler, opts });
      },
    } as never);
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
    const noop = () => {};
    mod.default.register({
      logger: { info: noop, warn: noop, error: noop, debug: noop },
      on: (event: string, handler: Hook) => {
        regs.push({ event, handler });
      },
    } as never);

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
});

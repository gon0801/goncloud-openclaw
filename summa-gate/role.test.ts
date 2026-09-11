import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, existsSync, rmSync } from "node:fs";
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

  it("allows a report-back request addressed to Claw's exact session", () => {
    assert.equal(
      sessionsSendGuardVerdict(
        "main",
        {
          agentId: "operaciones",
          timeoutSeconds: 0,
          message: `revisa y cuando termines reportame con sessions_send a sessionKey ${CLAW}, timeoutSeconds 0`,
        },
        CLAW,
      ),
      undefined,
    );
  });

  it("blocks a return address that is not Claw's session or is only mentioned", () => {
    blocked({ agentId: "operaciones", timeoutSeconds: 0, message: "reportame con sessions_send a sessionKey agent:main:zzz" });
    blocked({ agentId: "ingenieria", timeoutSeconds: 0, message: "no me reportes; el error salio en agent:main:main ayer" });
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
    assert.equal(call({ agentId: "ingenieria", message: "reportame con sessions_send a sessionKey agent:main:main" }, claw), undefined);
  });
});

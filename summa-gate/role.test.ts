import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, existsSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, it, before, after } from "node:test";

import {
  blockedWithoutTryingVerdict,
  canonicalRole,
  mergeGuardVerdict,
  sessionsSendGuardVerdict,
} from "./lib.ts";

// Texto real del 2026-09-12: ingenieria se declaro incapaz sin correr un solo comando.
const INCAPAZ_REAL =
  "Techo funcional: no puedo tipear dentro de ttys001 desde aca - no hay skill instalada para eso.";
// Negativa legitima real del 2026-09-11: Claw se nego a reiniciar el gateway, y tenia razon.
const NEGATIVA_LEGITIMA =
  "Los reinicios del gateway son accion del propietario; no los ejecuto por mi cuenta aunque la ventana este limpia.";

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

  // Sin esto el verde no prueba nada: el candado tiene que correr ANTES del filtro de sesiones
  // armadas. La falla del 2026-09-12 fue en una sesion despachada, sin sentinel -saikit, o sea
  // sin estado en disco. Si el handler se moviera detras del `if (!state) return`, esta prueba
  // pasaria a devolver undefined y lo cacharia.
  it("blocks declared incapacity in a session that was never armed with -saikit", async () => {
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

    const finalize = regs.find((r) => r.event === "before_agent_finalize");
    const afterTool = regs.find((r) => r.event === "after_tool_call");
    assert.ok(finalize, "before_agent_finalize sin registrar");
    assert.ok(afterTool, "after_tool_call sin registrar");

    // Sesion nunca armada: no existe archivo de estado para esta clave.
    const virgen = { sessionKey: "agent:ingenieria:jamas-armada-" + Date.now() };
    const out = finalize.handler({ lastAssistantMessage: INCAPAZ_REAL }, virgen) as
      | { action?: string; reason?: string }
      | undefined;
    assert.equal(out?.action, "revise");
    assert.match(String(out?.reason), /sin haber corrido un solo comando/);

    // Y si en esa misma sesion SI hubo un exec, deja pasar la misma conclusion.
    afterTool.handler({ toolName: "exec", params: { command: "osascript -e 'x'" } }, virgen);
    assert.equal(finalize.handler({ lastAssistantMessage: INCAPAZ_REAL }, virgen), undefined);
  });
});

describe("blockedWithoutTryingVerdict", () => {
  it("blocks the real 2026-09-12 text when no exec ran", () => {
    assert.match(
      String(blockedWithoutTryingVerdict(INCAPAZ_REAL, 0)),
      /sin haber corrido un solo comando/,
    );
  });

  it("lets it through once a command was actually attempted", () => {
    assert.equal(blockedWithoutTryingVerdict(INCAPAZ_REAL, 1), undefined);
  });

  // El falso positivo que mas importa: una negativa por criterio NO es incapacidad tecnica.
  // Claw acerto el 2026-09-11 al negarse a reiniciar el gateway; bloquearlo seria un bug del candado.
  it("never blocks a refusal made on judgement, even with zero exec", () => {
    assert.equal(blockedWithoutTryingVerdict(NEGATIVA_LEGITIMA, 0), undefined);
  });

  it("never blocks a refusal grounded in a real permission error", () => {
    assert.equal(
      blockedWithoutTryingVerdict(
        "No pude abrir el archivo: approval cannot safely bind this command.",
        0,
      ),
      undefined,
    );
  });

  it("ignores answers that claim no incapacity at all", () => {
    assert.equal(blockedWithoutTryingVerdict("Listo, quedaron 3 archivos cambiados.", 0), undefined);
  });

  it("fails open on empty or non-string text", () => {
    assert.equal(blockedWithoutTryingVerdict("", 0), undefined);
    assert.equal(blockedWithoutTryingVerdict(undefined, 0), undefined);
  });

  // Discriminacion: los dos textos tienen que caer de lados distintos con el MISMO execCount 0.
  // Si un cambio futuro ensancha el patron de incapacidad hasta tragarse la negativa legitima,
  // esta prueba lo ve aunque las dos de arriba sigan verdes por separado.
  it("separates technical incapacity from a judgement refusal at the same zero-exec count", () => {
    const bloqueado = blockedWithoutTryingVerdict(INCAPAZ_REAL, 0);
    const permitido = blockedWithoutTryingVerdict(NEGATIVA_LEGITIMA, 0);
    assert.ok(bloqueado, "el texto de incapacidad deberia bloquearse");
    assert.equal(permitido, undefined, "la negativa por criterio no deberia bloquearse");
  });
});

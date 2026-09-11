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

// Canal entre agentes (2026-09-11): un sessions_send de Claw sin espera, o con la espera por defecto
// de 30 s, pierde la respuesta si el agente tarda mas (41 perdidas el 09-11; dos mas en el chat real
// despues de la regla escrita). El candado deja pasar spawn, esperas explicitas y envios que piden
// reporte de vuelta a una sesion de main.
describe("sessionsSendGuardVerdict", () => {
  it("blocks main sending to another agent without timeoutSeconds (default 30 s wait)", () => {
    assert.match(
      sessionsSendGuardVerdict("main", { agentId: "ingenieria", message: "retoma el PR 306" }) ?? "",
      /sessions_spawn/,
    );
  });

  it("blocks main fire-and-forget (timeoutSeconds 0) without a return address", () => {
    assert.match(
      sessionsSendGuardVerdict("main", { agentId: "operaciones", timeoutSeconds: 0, message: "revisa la corrida" }) ?? "",
      /sessions_spawn/,
    );
  });

  it("blocks by sessionKey target too", () => {
    assert.match(
      sessionsSendGuardVerdict("main", { sessionKey: "agent:operaciones:main", message: "revisa" }) ?? "",
      /sessions_spawn/,
    );
  });

  // Verificado en vivo el 09-11: operaciones reporto de vuelta a la sesion de main (tardo ~4 min por
  // una compactacion y el reporte llego duplicado, pero llego).
  it("allows fire-and-forget when the message asks to report back to a main session", () => {
    assert.equal(
      sessionsSendGuardVerdict("main", {
        agentId: "operaciones",
        timeoutSeconds: 0,
        message: "revisa y cuando termines reportame con sessions_send a sessionKey agent:main:main",
      }),
      undefined,
    );
  });

  it("allows an explicit wait", () => {
    assert.equal(
      sessionsSendGuardVerdict("main", { agentId: "operaciones", timeoutSeconds: 120, message: "cuantos crons?" }),
      undefined,
    );
  });

  it("allows sends to main's own sessions", () => {
    assert.equal(sessionsSendGuardVerdict("main", { sessionKey: "agent:main:diag-x", message: "x" }), undefined);
    assert.equal(sessionsSendGuardVerdict("main", { agentId: "main", message: "x" }), undefined);
  });

  it("does not touch other agents' sends", () => {
    assert.equal(sessionsSendGuardVerdict("operaciones", { agentId: "main", message: "listo" }), undefined);
    assert.equal(sessionsSendGuardVerdict(undefined, { agentId: "ingenieria", message: "x" }), undefined);
  });
});

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
});

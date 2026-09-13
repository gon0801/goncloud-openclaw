/**
 * diagnostic-guard finalize tests (Fase 5 / 5.5).
 *
 * Best-effort same-run revision without reply suppression: observe logs
 * and never revises; enforce revises at most once per run under the exact
 * conditions; everything else delivers the final normally. Zero
 * scheduling, zero suppression, zero cross-run continuation.
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, rmSync, symlinkSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

const NS = "summa-gate/diagnostic-guard/v1";
const EXPECTED_REASON =
  "A recognized first-path failure was converted into a task-level incapacity conclusion before three distinct diagnostic categories completed.";

before(() => {
  const here = dirname(fileURLToPath(import.meta.url));
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
    // link may already exist from a prior run
  }
});

after(() => {
  try {
    rmSync(join(dirname(fileURLToPath(import.meta.url)), "node_modules", "openclaw"), { force: true });
  } catch {
    // ignore
  }
});

type FinalizeHandler = (event: unknown, ctx: unknown) => Promise<unknown>;

function makeFakeApi(pluginConfig: unknown = {}) {
  const mwRegs: Array<{ handler: (event: unknown, ctx?: unknown) => Promise<unknown> }> = [];
  const onRegs: Array<{ event: string; handler: FinalizeHandler }> = [];
  const store = new Map<string, unknown>();
  const infos: string[] = [];
  const warns: string[] = [];
  const schedulerCalls: string[] = [];
  const noop = () => {};
  const api = {
    logger: {
      info: (m: string) => infos.push(String(m)),
      warn: (m: string) => warns.push(String(m)),
      error: noop,
      debug: noop,
    },
    on: (event: string, handler: FinalizeHandler) => {
      onRegs.push({ event, handler });
      return () => {};
    },
    registerAgentToolResultMiddleware: (handler: (event: unknown) => Promise<unknown>) => {
      mwRegs.push({ handler });
      return () => {};
    },
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
    // Scheduler-shaped spies the plugin must never touch.
    session: { workflow: { scheduleSessionTurn: (...a: unknown[]) => schedulerCalls.push(`schedule:${JSON.stringify(a).length}`) } },
    enqueueNextTurnInjection: (...a: unknown[]) => schedulerCalls.push(`enqueue:${JSON.stringify(a).length}`),
    pluginConfig,
  };
  return { api, mwRegs, onRegs, store, infos, warns, schedulerCalls };
}

async function registerWith(pluginConfig: unknown) {
  const fake = makeFakeApi(pluginConfig);
  const mod = await import("./index.ts");
  mod.default.register(fake.api as never);
  return fake;
}

function finalizers(fake: { onRegs: Array<{ event: string; handler: FinalizeHandler }> }) {
  return fake.onRegs.filter((r) => r.event === "before_agent_finalize").map((r) => r.handler);
}

/** The diagnostic finalizer is registered after the receipt gate. */
function diagnosticFinalizer(fake: { onRegs: Array<{ event: string; handler: FinalizeHandler }> }) {
  const all = finalizers(fake);
  assert.ok(all.length >= 2, "expected receipt + diagnostic finalize handlers");
  return all[all.length - 1];
}

async function seedGhIncident(
  fake: Awaited<ReturnType<typeof registerWith>>,
  runId: string,
) {
  const out = (await fake.mwRegs[0].handler(
    {
      toolCallId: `call-${runId}`,
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: true,
      result: { content: [{ type: "text", text: "gh: command not found" }] },
    },
    { runtime: "openclaw", runId },
  )) as { result: { content: unknown[] } };
  assert.equal(out.result.content.length, 2);
}

async function seedProbe(
  fake: Awaited<ReturnType<typeof registerWith>>,
  runId: string,
  command: string,
) {
  await fake.mwRegs[0].handler(
    {
      toolCallId: `probe-${command.length}-${runId}`,
      toolName: "exec",
      args: { command },
      result: { content: [{ type: "text", text: "FOUND" }] },
    },
    { runtime: "openclaw", runId },
  );
}

const INCAPACITY = "I cannot access GitHub in this run.";

describe("diagnostic finalize mode gating", () => {
  it("off registers no diagnostic hooks", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "off" } });
    assert.equal(fake.mwRegs.length, 0);
    assert.equal(finalizers(fake).length, 1);
  });

  it("observe never revises but logs symbolic telemetry", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "observe" } });
    const runId = `fin-observe-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const out = await diagnosticFinalizer(fake)(
      { runId, lastAssistantMessage: INCAPACITY },
      { sessionKey: "agent:main:main" },
    );
    assert.equal(out, undefined);
    const state = fake.store.get(`${runId}:${NS}`) as { revisionRequested: boolean };
    assert.equal(state.revisionRequested, false);
    assert.ok(
      fake.infos.some((l) => l.includes("diagnostic finalize") && l.includes("path_miss:gh_cli")),
      "observe must log the symbolic finalize decision",
    );
  });
});

describe("diagnostic finalize enforce revision", () => {
  it("revises exactly once with the exact contract payload", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-enforce-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    const out = (await finalize({ runId, lastAssistantMessage: INCAPACITY }, { sessionKey: "s" })) as {
      action: string;
      reason: string;
      retry: { instruction: string; idempotencyKey: string; maxAttempts: number };
    };
    assert.equal(out.action, "revise");
    assert.equal(out.reason, EXPECTED_REASON);
    assert.equal(out.retry.idempotencyKey, `summa-diagnostic:${runId}`);
    assert.equal(out.retry.maxAttempts, 1);
    assert.match(out.retry.instruction, /<diagnostic-contract incident="path_miss:gh_cli">/);
    const state = fake.store.get(`${runId}:${NS}`) as { revisionRequested: boolean };
    assert.equal(state.revisionRequested, true);
  });

  it("a second call for the same run does not revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-twice-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    const first = await finalize({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.ok(first && typeof first === "object" && (first as { action: string }).action === "revise");
    const second = await finalize({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(second, undefined);
  });

  it("two concurrent finals for the same run yield exactly one revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-race-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    const [a, b] = await Promise.all([
      finalize({ runId, lastAssistantMessage: INCAPACITY }, {}),
      finalize({ runId, lastAssistantMessage: INCAPACITY }, {}),
    ]);
    const revises = [a, b].filter(
      (o) => o && typeof o === "object" && (o as { action: string }).action === "revise",
    );
    assert.equal(revises.length, 1);
  });

  it("two concurrent finals in different runs are isolated", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const stamp = Date.now();
    const runA = `fin-iso-A-${stamp}`;
    const runB = `fin-iso-B-${stamp}`;
    await seedGhIncident(fake, runA);
    await seedGhIncident(fake, runB);
    const finalize = diagnosticFinalizer(fake);
    const [a, b] = await Promise.all([
      finalize({ runId: runA, lastAssistantMessage: INCAPACITY }, {}),
      finalize({ runId: runB, lastAssistantMessage: INCAPACITY }, {}),
    ]);
    const keyA = (a as { retry: { idempotencyKey: string } }).retry.idempotencyKey;
    const keyB = (b as { retry: { idempotencyKey: string } }).retry.idempotencyKey;
    assert.equal(keyA, `summa-diagnostic:${runA}`);
    assert.equal(keyB, `summa-diagnostic:${runB}`);
  });

  it("three completed categories never revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-done-${Date.now()}`;
    await seedGhIncident(fake, runId);
    await seedProbe(fake, runId, "which gh");
    await seedProbe(fake, runId, "Test-Path C:\\fake\\gh.exe");
    await seedProbe(fake, runId, "C:\\fake\\gh.exe --version");
    const out = await diagnosticFinalizer(fake)(
      { runId, lastAssistantMessage: INCAPACITY },
      {},
    );
    assert.equal(out, undefined);
  });

  it("missing or ambiguous runId never revises", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-amb-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    assert.equal(
      await finalize({ lastAssistantMessage: INCAPACITY }, { sessionKey: "agent:main:main" }),
      undefined,
    );
    assert.equal(
      await finalize({ runId, lastAssistantMessage: INCAPACITY }, { runId: "other-run" }),
      undefined,
    );
  });

  it("a failed state write delivers the final normally", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-writefail-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const realSet = fake.api.runContext.setRunContext;
    fake.api.runContext.setRunContext = () => {
      throw new Error("store down");
    };
    const out = await diagnosticFinalizer(fake)({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(out, undefined);
    fake.api.runContext.setRunContext = realSet;
  });

  it("a false setRunContext is a failed write: no revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-false-${Date.now()}`;
    await seedGhIncident(fake, runId);
    fake.api.runContext.setRunContext = () => false;
    const out = await diagnosticFinalizer(fake)({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(out, undefined);
  });

  it("corrupt stored state fails open: no revise, no crash", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-junk-${Date.now()}`;
    fake.store.set(`${runId}:${NS}`, {
      version: 1,
      incidentId: "path_miss:gh_cli",
      requiredCategories: ["executable_discovery", "known_install_location", "capability_verification"],
      completedCategories: ["not_a_category", 42],
      revisionRequested: false,
    });
    const out = await diagnosticFinalizer(fake)({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(out, undefined);
  });

  it("tampered required categories fail open: no revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-tamper-${Date.now()}`;
    fake.store.set(`${runId}:${NS}`, {
      version: 1,
      incidentId: "path_miss:gh_cli",
      requiredCategories: ["executable_discovery"],
      completedCategories: [],
      revisionRequested: false,
    });
    const out = await diagnosticFinalizer(fake)({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(out, undefined);
  });

  it("duplicated completed categories fail open: no revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-dup-${Date.now()}`;
    fake.store.set(`${runId}:${NS}`, {
      version: 1,
      incidentId: "path_miss:gh_cli",
      requiredCategories: ["executable_discovery", "known_install_location", "capability_verification"],
      completedCategories: ["executable_discovery", "executable_discovery", "executable_discovery"],
      revisionRequested: false,
    });
    const out = await diagnosticFinalizer(fake)({ runId, lastAssistantMessage: INCAPACITY }, {});
    assert.equal(out, undefined);
  });
});

describe("diagnostic finalize automation safety", () => {
  it("cron/heartbeat triggers create no run, cancel nothing, and repeat no action", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-cron-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    // SDK-real automation signal: ctx.trigger (mirrors bundled memory-core).
    // inputProvenance.kind can never be cron/heartbeat per the SDK type.
    for (const trigger of ["cron", "heartbeat"]) {
      const out = await finalize(
        { runId, lastAssistantMessage: INCAPACITY },
        { trigger },
      );
      assert.equal(out, undefined, `trigger=${trigger} must not revise`);
    }
    assert.equal(fake.schedulerCalls.length, 0);
    const state = fake.store.get(`${runId}:${NS}`) as { revisionRequested: boolean };
    assert.equal(state.revisionRequested, false);
  });

  it("registers no terminal-payload handler and schedules nothing", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const events = fake.onRegs.map((r) => r.event);
    assert.ok(!events.includes("reply_payload_sending"));
    assert.equal(fake.schedulerCalls.length, 0);
    const src = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
    for (const forbidden of [
      "scheduleSessionTurn",
      "enqueueNextTurnInjection",
      "reply_payload_sending",
      "resolve_exec_env",
      "SUMMA_DIAGNOSTIC_CONTINUATION",
    ]) {
      assert.ok(!src.includes(forbidden), `production must not reference ${forbidden}`);
    }
  });

  it("never cancels: every finalize outcome is undefined or a same-run revise", async () => {
    const fake = await registerWith({ diagnosticGuard: { mode: "enforce" } });
    const runId = `fin-nocancel-${Date.now()}`;
    await seedGhIncident(fake, runId);
    const finalize = diagnosticFinalizer(fake);
    const outcomes: unknown[] = [
      await finalize({ runId, lastAssistantMessage: INCAPACITY }, {}),
      await finalize({ runId, lastAssistantMessage: "The first method failed; I will inspect another path." }, {}),
      await finalize({ runId: "nope", lastAssistantMessage: INCAPACITY }, {}),
    ];
    for (const o of outcomes) {
      if (o === undefined) continue;
      assert.equal((o as { action: string }).action, "revise");
      const flat = JSON.stringify(o);
      assert.ok(!("block" in (o as object)));
      assert.ok(!("terminate" in (o as object)));
      assert.ok(!flat.includes('"action":"cancel"'));
      assert.ok(!flat.includes('"action":"block"'));
    }
  });

  it("a diagnostic registration failure keeps the receipt gate working", async () => {
    const fake = makeFakeApi({ diagnosticGuard: { mode: "enforce" } });
    fake.api.registerAgentToolResultMiddleware = () => {
      throw new Error("mw down");
    };
    const mod = await import("./index.ts");
    mod.default.register(fake.api as never);
    const gates = fake.onRegs.filter((r) => r.event === "before_agent_finalize");
    assert.equal(gates.length, 2);
    // Arm a ceremony session through the real prompt builder, then prove
    // the receipt gate still rejects a final without the receipt block.
    // The on-disk session file is removed afterwards.
    const { homedir } = await import("node:os");
    const { join: joinPath } = await import("node:path");
    const { rmSync: rmState } = await import("node:fs");
    const build = fake.onRegs.find((r) => r.event === "before_prompt_build")!.handler;
    const sessionKey = `agent:main:receipt-survives-${Date.now()}`;
    await build({ prompt: "tarea -saikit:fast" }, { sessionKey });
    try {
      const outs = await Promise.all(
        gates.map((g) =>
          g.handler({ lastAssistantMessage: "hola sin recibo" }, { sessionKey }),
        ),
      );
      assert.ok(
        outs.some(
          (o) => o && typeof o === "object" && JSON.stringify(o).includes("SUMMONAIKIT HARNESS RECEIPT"),
        ),
        "receipt gate must survive diagnostic registration failure",
      );
    } finally {
      rmState(joinPath(homedir(), ".openclaw", "summa-gate", "state", `${sessionKey}.json`), { force: true });
    }
  });
});

/**
 * diagnostic-guard middleware tests (Fase 5 / 5.4, review fixes round).
 *
 * The handler follows the real SDK signature
 * (agent-harness-runtime-CZb40n5o.d.ts:14254-14274):
 *   (event: { toolCallId, toolName, args, isError?, result }, ctx: { runtime, runId?, ... })
 * runId comes ONLY from ctx. An event-carried runId is ignored (spoof pin).
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, rmSync, symlinkSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

const NS = "summa-gate/diagnostic-guard/v1";

before(() => {
  // Same smoke-link as role.test.ts: the plugin imports the openclaw SDK,
  // which lives outside the repo. Link it into ./node_modules first.
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

type MwReg = { handler: (event: unknown, ctx?: unknown) => unknown; opts?: unknown };
type OnReg = { event: string; handler: (event: unknown, ctx: unknown) => unknown; opts?: unknown };

function makeFakeApi(pluginConfig: unknown = {}) {
  const mwRegs: MwReg[] = [];
  const onRegs: OnReg[] = [];
  const store = new Map<string, unknown>();
  const infos: string[] = [];
  const warns: string[] = [];
  const noop = () => {};
  const api = {
    logger: {
      info: (m: string) => infos.push(String(m)),
      warn: (m: string) => warns.push(String(m)),
      error: noop,
      debug: noop,
    },
    on: (event: string, handler: OnReg["handler"], opts?: OnReg["opts"]) => {
      onRegs.push({ event, handler, opts });
      return () => {};
    },
    registerAgentToolResultMiddleware: (handler: MwReg["handler"], opts?: MwReg["opts"]) => {
      mwRegs.push({ handler, opts });
      return () => {};
    },
    runContext: {
      setRunContext: ({ runId, namespace, value }: { runId: string; namespace: string; value: unknown }) => {
        store.set(`${runId}:${namespace}`, value);
        return true;
      },
      getRunContext: ({ runId, namespace }: { runId: string; namespace: string }) => {
        return store.get(`${runId}:${namespace}`);
      },
      clearRunContext: ({ runId, namespace }: { runId: string; namespace?: string }) => {
        if (namespace) store.delete(`${runId}:${namespace}`);
        else for (const k of [...store.keys()]) if (k.startsWith(`${runId}:`)) store.delete(k);
      },
    },
    pluginConfig,
  };
  return { api, mwRegs, onRegs, store, infos, warns };
}

async function registerWith(pluginConfig: unknown = {}) {
  const fake = makeFakeApi(pluginConfig);
  const mod = await import("./index.ts");
  mod.default.register(fake.api as never);
  return { ...fake, mod };
}

type MwHandler = (event: unknown, ctx?: unknown) => Promise<unknown>;

/** SDK-shaped tool-result call: runId lives in ctx, never in event. */
function ghErrorCall(runId: string, extraResult: Record<string, unknown> = {}) {
  return {
    event: {
      toolCallId: `call-${runId}`,
      toolName: "exec",
      args: { command: "gh pr list" },
      isError: true,
      result: {
        content: [
          { type: "text", text: "bash: gh: command not found" },
          { type: "image", mimeType: "image/png", data: "ZmFr" },
        ],
        details: { exitCode: 127 },
        progress: { done: false },
        terminate: false,
        futureField: { whatever: 1 },
        ...extraResult,
      },
    },
    ctx: { runtime: "openclaw", runId, agentId: "main", sessionKey: "agent:main:main" },
  };
}

describe("diagnostic middleware registration", () => {
  it("registers for openclaw and codex runtimes under the exact namespace", async () => {
    const { mwRegs, store } = await registerWith({});
    assert.equal(mwRegs.length, 1);
    assert.deepEqual((mwRegs[0].opts as { runtimes: string[] }).runtimes, ["openclaw", "codex"]);
    void store;
  });

  it("declares the middleware contract and diagnosticGuard schema in the manifest", () => {
    const manifest = JSON.parse(readFileSync(new URL("./openclaw.plugin.json", import.meta.url), "utf8"));
    assert.deepEqual(manifest.contracts.agentToolResultMiddleware, ["openclaw", "codex"]);
    const schema = manifest.configSchema.properties.diagnosticGuard;
    assert.deepEqual(schema.additionalProperties, false);
    assert.deepEqual(schema.properties.mode.enum, ["off", "observe", "enforce"]);
    assert.deepEqual(schema.properties.requiredProbeCategories.minimum, 3);
    assert.deepEqual(schema.properties.requiredProbeCategories.maximum, 3);
    assert.deepEqual(schema.properties.maxRevisionAttempts.minimum, 1);
    assert.deepEqual(schema.properties.maxRevisionAttempts.maximum, 1);
    assert.ok(!Array.isArray(manifest.configSchema.required) || !manifest.configSchema.required.includes("diagnosticGuard"));
  });

  it("does not register the middleware when mode is off", async () => {
    const { mwRegs } = await registerWith({ diagnosticGuard: { mode: "off" } });
    assert.equal(mwRegs.length, 0);
  });
});

describe("diagnostic middleware runId source (SDK signature)", () => {
  it("reads runId from ctx, the only SDK-carried source", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event, ctx } = ghErrorCall("run-ctx-1");
    // The SDK event carries no runId at all.
    assert.ok(!("runId" in (event as object)));
    const out = (await handler(event, ctx)) as { result: { content: unknown[] } };
    assert.equal(out.result.content.length, 3);
    assert.ok(store.has(`run-ctx-1:${NS}`));
  });

  it("ignores an event-carried runId (spoof pin): ctx wins", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event, ctx } = ghErrorCall("run-real-1");
    const spoofed = { ...(event as object), runId: "run-evil-1" };
    const out = (await handler(spoofed, ctx)) as { result: { content: unknown[] } };
    assert.equal(out.result.content.length, 3);
    assert.ok(store.has(`run-real-1:${NS}`));
    assert.ok(!store.has(`run-evil-1:${NS}`));
  });

  it("fails open with no ctx runId even when sessionKey is present", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event } = ghErrorCall("run-norun-1");
    const out = await handler(event, { runtime: "openclaw", sessionKey: "agent:main:main" });
    assert.equal(out, undefined);
    assert.equal(store.size, 0);
  });

  it("fails open with no ctx at all", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event } = ghErrorCall("run-noctx-1");
    assert.equal(await handler(event), undefined);
    assert.equal(await handler(event, undefined), undefined);
    assert.equal(store.size, 0);
  });
});

describe("diagnostic middleware preservation", () => {
  it("appends exactly one text block and preserves everything else", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event, ctx } = ghErrorCall("run-preserve-1");
    const beforeContent = (event.result as { content: unknown[] }).content.length;
    const out = (await handler(event, ctx)) as {
      result: {
        content: Array<{ type: string; text?: string }>;
        details: unknown;
        progress: unknown;
        terminate: unknown;
        futureField: unknown;
      };
    };
    assert.ok(out && typeof out === "object" && "result" in out);
    assert.equal(out.result.content.length, beforeContent + 1);
    // Original items untouched and in order.
    assert.deepEqual(out.result.content[0], { type: "text", text: "bash: gh: command not found" });
    assert.deepEqual(out.result.content[1], { type: "image", mimeType: "image/png", data: "ZmFr" });
    const appended = out.result.content[out.result.content.length - 1];
    assert.equal(appended.type, "text");
    assert.match(String(appended.text), /<diagnostic-contract incident="path_miss:gh_cli">/);
    assert.deepEqual(out.result.details, { exitCode: 127 });
    assert.deepEqual(out.result.progress, { done: false });
    assert.equal(out.result.terminate, false);
    assert.deepEqual(out.result.futureField, { whatever: 1 });
    // Input not mutated.
    assert.equal((event.result as { content: unknown[] }).content.length, beforeContent);
    // State keyed by exact runId + namespace.
    assert.ok(store.has(`run-preserve-1:${NS}`));
  });

  it("returns undefined for an unknown error (fail-open)", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const out = await handler(
      {
        toolCallId: "c-1",
        toolName: "exec",
        args: { command: "qqqzz --help" },
        isError: true,
        result: { content: [{ type: "text", text: "qqqzz: command not found" }] },
      },
      { runtime: "openclaw", runId: "run-unknown-1" },
    );
    assert.equal(out, undefined);
    assert.equal(store.size, 0);
  });

  it("guides codex-runtime results the same way (host may observe without re-injection)", async () => {
    const { mwRegs } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const { event } = ghErrorCall("run-codex-1");
    const out = (await handler(event, { runtime: "codex", runId: "run-codex-1" })) as {
      result: { content: Array<{ type: string }> };
    };
    assert.equal(out.result.content.length, 3);
  });

  it("logs only symbolic telemetry, never observed content", async () => {
    const { mwRegs, infos } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const canary = "canary-mw-4d2a";
    await handler(
      {
        toolCallId: "c-canary",
        toolName: "exec",
        args: { command: `gh auth --with-token ${canary}` },
        isError: true,
        result: { content: [{ type: "text", text: `gh: command not found (${canary})` }] },
      },
      { runtime: "openclaw", runId: "run-canary-1" },
    );
    assert.ok(!infos.some((line) => line.includes(canary)), "telemetry leaked observed content");
    assert.ok(infos.some((line) => line.includes("path_miss:gh_cli")), "telemetry must name the incident");
  });

  it("rebuilds fresh state over corrupt stored state instead of crashing", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const runId = `run-corrupt-${Date.now()}`;
    store.set(`${runId}:${NS}`, {
      version: 1,
      incidentId: "path_miss:gh_cli",
      requiredCategories: ["executable_discovery"],
      completedCategories: ["not_a_category"],
      revisionRequested: "yes",
    });
    const { event, ctx } = ghErrorCall(runId);
    const out = (await handler(event, ctx)) as { result: { content: unknown[] } };
    assert.equal(out.result.content.length, 3);
    const state = store.get(`${runId}:${NS}`) as { completedCategories: string[] };
    assert.deepEqual(state.completedCategories, []);
  });
});

describe("diagnostic per-run state", () => {
  it("does not lose categories on two concurrent updates of the same run", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const runId = `run-concurrent-${Date.now()}`;
    const seed = ghErrorCall(runId);
    await handler(seed.event, seed.ctx);
    const ctx = { runtime: "openclaw", runId };
    const p1 = handler(
      {
        toolCallId: "c-a",
        toolName: "exec",
        args: { command: "which gh" },
        result: { content: [{ type: "text", text: "FOUND" }] },
      },
      ctx,
    );
    const p2 = handler(
      {
        toolCallId: "c-b",
        toolName: "exec",
        args: { command: "Test-Path C:\\fake\\gh.exe" },
        result: { content: [{ type: "text", text: "FOUND" }] },
      },
      ctx,
    );
    await Promise.all([p1, p2]);
    const state = store.get(`${runId}:${NS}`) as { completedCategories: string[] };
    assert.deepEqual([...state.completedCategories].sort(), ["executable_discovery", "known_install_location"]);
  });

  it("isolates two runIds in the same session", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const stamp = Date.now();
    const seedA = ghErrorCall(`run-A-${stamp}`);
    await handler(seedA.event, seedA.ctx);
    await handler(
      {
        toolCallId: "c-b",
        toolName: "exec",
        args: { command: "openclaw browser --profile claw tabs --json" },
        isError: true,
        result: {
          content: [
            {
              type: "text",
              text: "gateway browser.request requires credentials before opening a websocket Config: C:\\x\\.openclaw-claw\\openclaw.json",
            },
          ],
        },
      },
      { runtime: "openclaw", runId: `run-B-${stamp}`, sessionKey: "agent:main:main" },
    );
    const a = store.get(`run-A-${stamp}:${NS}`) as { incidentId: string };
    const b = store.get(`run-B-${stamp}:${NS}`) as { incidentId: string };
    assert.equal(a.incidentId, "path_miss:gh_cli");
    assert.equal(b.incidentId, "wrong_profile:browser_claw");
  });

  it("keeps the queue alive after a rejected update", async () => {
    const fake = makeFakeApi({});
    const mod = await import("./index.ts");
    mod.default.register(fake.api as never);
    const handler = fake.mwRegs[0].handler as MwHandler;
    const runId = `run-poison-${Date.now()}`;
    const ctx = { runtime: "openclaw", runId };
    const realSet = fake.api.runContext.setRunContext;
    let failOnce = true;
    fake.api.runContext.setRunContext = ((args: { runId: string; namespace: string; value: unknown }) => {
      if (failOnce) {
        failOnce = false;
        throw new Error("boom-transient-store");
      }
      return realSet(args);
    }) as typeof realSet;
    // First update fails to persist but still guides and does not break the queue.
    // (A lost write means the run has no tracked incident yet; the next
    // recognized incident re-establishes it — fail-open, never mixed state.)
    const seed = ghErrorCall(runId);
    const first = (await handler(seed.event, seed.ctx)) as { result: { content: unknown[] } };
    assert.equal(first.result.content.length, 3);
    const reestablished = (await handler(seed.event, seed.ctx)) as { result: { content: unknown[] } };
    assert.equal(reestablished.result.content.length, 3);
    const second = (await handler(
      {
        toolCallId: "c-p",
        toolName: "exec",
        args: { command: "which gh" },
        result: { content: [{ type: "text", text: "FOUND" }] },
      },
      ctx,
    )) as { result: { content: unknown[] } };
    assert.equal(second.result.content.length, 2);
    const state = fake.store.get(`${runId}:${NS}`) as { completedCategories: string[] };
    assert.deepEqual(state.completedCategories, ["executable_discovery"]);
  });

  it("treats a false setRunContext as a failed write: warns, still guides", async () => {
    const fake = makeFakeApi({});
    const mod = await import("./index.ts");
    mod.default.register(fake.api as never);
    const handler = fake.mwRegs[0].handler as MwHandler;
    fake.api.runContext.setRunContext = () => false;
    const runId = `run-false-${Date.now()}`;
    const seed = ghErrorCall(runId);
    const out = (await handler(seed.event, seed.ctx)) as { result: { content: unknown[] } };
    assert.equal(out.result.content.length, 3);
    assert.ok(fake.warns.some((w) => w.includes("state write failed")));
    assert.equal(fake.store.size, 0);
  });

  it("fails open on a primitive result instead of spreading it (corruption pin)", async () => {
    const { mwRegs, store } = await registerWith({});
    const handler = mwRegs[0].handler as MwHandler;
    const runId = `run-prim-${Date.now()}`;
    const seed = ghErrorCall(runId);
    await handler(seed.event, seed.ctx);
    const out = await handler(
      {
        toolCallId: "c-prim",
        toolName: "exec",
        args: { command: "which gh" },
        result: "FOUND",
      },
      { runtime: "openclaw", runId },
    );
    assert.equal(out, undefined);
    const state = store.get(`${runId}:${NS}`) as { completedCategories: string[] };
    assert.deepEqual(state.completedCategories, []);
  });
});

describe("diagnostic registration failure isolation", () => {
  it("keeps merge guard, adversary confinement and sessions_send when middleware registration throws", async () => {
    const fake = makeFakeApi({});
    const secretMessage = "secret-boom-marker-zz9";
    fake.api.registerAgentToolResultMiddleware = () => {
      throw new Error(secretMessage);
    };
    const mod = await import("./index.ts");
    mod.default.register(fake.api as never);
    const beforeTool = fake.onRegs.filter((r) => r.event === "before_tool_call");
    const hasExecMatcher = beforeTool.some((r) =>
      (r.opts as { matcher?: string[] } | undefined)?.matcher?.includes("exec"),
    );
    const hasSessionsSend = beforeTool.some((r) =>
      (r.opts as { matcher?: string[] } | undefined)?.matcher?.includes("sessions_send"),
    );
    const hasAdversary = beforeTool.some((r) => r.opts === undefined);
    assert.ok(hasExecMatcher, "merge guard registration lost");
    assert.ok(hasSessionsSend, "sessions_send guard registration lost");
    assert.ok(hasAdversary, "adversary confinement registration lost");
    // Merge guard still blocks.
    const mergeHook = beforeTool.find((r) =>
      (r.opts as { matcher?: string[] } | undefined)?.matcher?.includes("exec"),
    )!;
    const blocked = mergeHook.handler({ toolName: "exec", params: { command: "gh pr merge 12" } }, {}) as
      | { block?: boolean }
      | undefined;
    assert.equal(blocked?.block, true);
    // The catch logs only the fixed text plus the error class.
    assert.ok(fake.warns.some((w) => /summa-gate diagnostic: registration failed \(\w+\)/.test(w)));
    assert.ok(!fake.warns.some((w) => w.includes(secretMessage)), "registration catch leaked the error message");
  });
});

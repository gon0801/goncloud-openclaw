/**
 * Wiring test (cross-review r2, grok): merge-guard.test.ts solo ejercita mergeGuardVerdict
 * pura; nada probaba que el before_tool_call del plugin pase ctx.agentId. Patron copiado de
 * diagnostic-guard-middleware.test.ts (fake api + import de index.ts + smoke-link del SDK).
 *
 * Limite declarado: es wiring a nivel de registro del plugin (la misma tecnica del repo),
 * no contra el runtime real de OpenClaw; el SDK se stubbea igual que en el resto de tests.
 */
import assert from "node:assert/strict";
import { existsSync, mkdirSync, rmSync, symlinkSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";

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

type OnReg = { event: string; handler: (event: unknown, ctx: unknown) => unknown; opts?: unknown };

function makeFakeApi() {
  const onRegs: OnReg[] = [];
  const noop = () => {};
  const api = {
    logger: { info: noop, warn: noop, error: noop, debug: noop },
    on: (event: string, handler: OnReg["handler"], opts?: OnReg["opts"]) => {
      onRegs.push({ event, handler, opts });
      return () => {};
    },
    registerAgentToolResultMiddleware: () => () => {},
    runContext: {
      setRunContext: () => true,
      getRunContext: () => undefined,
      clearRunContext: () => {},
    },
    pluginConfig: {},
  };
  return { api, onRegs };
}

describe("merge-guard wiring (cross-review r2)", () => {
  it("no registra un hook exec que bloquee merge o deploy", async () => {
    const fake = makeFakeApi();
    const mod = await import("./index.ts");
    mod.default.register(fake.api as never);
    const commands = [
      "gh pr merge 157 --squash", "gh api repos/o/r/pulls/157/merge -X PUT",
      "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:PR_1}) { clientMutationId } }'",
      "git push origin main", "ssh gonserver bash deploy.sh",
    ];
    for (const agentId of ["main", "implementer", "ingenieria", "reviewer", "verifier", "adversary", "operaciones", "scout", undefined]) {
      for (const command of commands) {
        for (const reg of fake.onRegs.filter(r => r.event === "before_tool_call")) {
          const matcher = (reg.opts as { matcher?: string[] } | undefined)?.matcher;
          if (matcher && !matcher.includes("exec")) continue;
          const result = reg.handler({ toolName: "exec", params: { command } }, { agentId }) as { block?: boolean } | undefined;
          assert.notEqual(result?.block, true, `${agentId}: ${command}`);
        }
      }
    }
  });
});

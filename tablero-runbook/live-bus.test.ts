/**
 * live-bus.test.ts — syncProgress es fire-and-forget y opcional.
 */
import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import {
  DEFAULT_LIVE_BUS_URL,
  LIVE_BUS_TIMEOUT_MS,
  _setFetchForTest,
  syncProgress,
} from "./live-bus.ts";

const ENV_URL = "LIVE_BUS_URL";
const ENV_TOKEN = "LIVE_WRITE_TOKEN";

const prevUrl = process.env[ENV_URL];
const prevToken = process.env[ENV_TOKEN];

afterEach(() => {
  _setFetchForTest(undefined);
  if (prevUrl === undefined) delete process.env[ENV_URL];
  else process.env[ENV_URL] = prevUrl;
  if (prevToken === undefined) delete process.env[ENV_TOKEN];
  else process.env[ENV_TOKEN] = prevToken;
});

describe("syncProgress", () => {
  it("no-op sin LIVE_WRITE_TOKEN (fetch no se llama)", () => {
    delete process.env[ENV_TOKEN];
    process.env[ENV_URL] = "http://example.test:9";
    let llamadas = 0;
    _setFetchForTest(async () => {
      llamadas += 1;
      return new Response(null, { status: 204 });
    });
    syncProgress("12");
    assert.equal(llamadas, 0);
  });

  it("POST al path /sync/progress/<fase> con Bearer y timeout", async () => {
    process.env[ENV_TOKEN] = "tok-de-prueba";
    delete process.env[ENV_URL];
    const vistos: Array<{ input: string; init: RequestInit | undefined }> = [];
    let liberar!: (r: Response) => void;
    const puerta = new Promise<Response>((resolve) => {
      liberar = resolve;
    });
    _setFetchForTest((input, init) => {
      vistos.push({ input: String(input), init });
      return puerta;
    });

    syncProgress("12.1");
    // microtask: el fetch ya se disparó (fire-and-forget)
    await Promise.resolve();
    assert.equal(vistos.length, 1);
    assert.equal(vistos[0]!.input, `${DEFAULT_LIVE_BUS_URL}/sync/progress/12.1`);
    assert.equal(vistos[0]!.init?.method, "POST");
    const headers = vistos[0]!.init?.headers as Record<string, string>;
    assert.equal(headers["Authorization"], "Bearer tok-de-prueba");
    assert.ok(vistos[0]!.init?.signal instanceof AbortSignal);
    assert.equal(LIVE_BUS_TIMEOUT_MS, 2_000);
    liberar(new Response(null, { status: 204 }));
  });

  it("respeta LIVE_BUS_URL sin slash final duplicado", async () => {
    process.env[ENV_TOKEN] = "t";
    process.env[ENV_URL] = "http://100.127.167.103:8787/";
    const vistos: string[] = [];
    _setFetchForTest(async (input) => {
      vistos.push(String(input));
      return new Response(null, { status: 204 });
    });
    syncProgress("6");
    await Promise.resolve();
    assert.deepEqual(vistos, ["http://100.127.167.103:8787/sync/progress/6"]);
  });

  it("un fetch que rechaza no lanza al caller", async () => {
    process.env[ENV_TOKEN] = "t";
    process.env[ENV_URL] = "http://127.0.0.1:1";
    _setFetchForTest(async () => {
      throw new Error("red caída");
    });
    assert.doesNotThrow(() => syncProgress("6"));
    await Promise.resolve();
    await Promise.resolve();
  });
});

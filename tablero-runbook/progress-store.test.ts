import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { ProgresoDoc } from "./contrato.ts";
import { isManagedPhase, isManagedProgress, readManagedPhase, readManagedProgress, readProgressEvents, submitProgressEvent, withLegacyProgressLock } from "./progress-store.ts";

const common = { corrida: "run-a", at: "2026-09-30T12:00:00Z" };
const doc = (): ProgresoDoc => ({ ...JSON.parse(readFileSync(new URL("./fixtures/v2-campos-validos.json", import.meta.url), "utf8")), corrida: "run-a" });
const temp = (fn: (dir: string) => void) => { const dir = mkdtempSync(join(tmpdir(), "progress-store-")); try { fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); } };

describe("durable managed progress", () => {
  it("deduplicates one ID and rejects reuse with changed content", () => temp((dir) => {
    const open = { ...common, kind: "run.opened", id: "open", doc: doc(), roundBudget: { C: 2 } };
    const first = submitProgressEvent(dir, open);
    assert.equal(first.ok, true);
    if (!first.ok) return;
    assert.equal(first.revision, 1);
    const second = submitProgressEvent(dir, { ...open, expectedRevision: 99 });
    assert.deepEqual({ ok: second.ok, duplicate: second.ok && second.duplicate, revision: second.revision }, { ok: true, duplicate: true, revision: 1 });
    const conflict = submitProgressEvent(dir, { ...open, roundBudget: { C: 3 } });
    assert.equal(conflict.ok, false);
    assert.equal(readProgressEvents(dir, "run-a", 0, 10).events.length, 1);
  }));

  it("replays an event after projection loss and repairs phase copy", () => temp((dir) => {
    const open = submitProgressEvent(dir, { ...common, kind: "run.opened", id: "open", doc: doc(), roundBudget: { C: 2 }, phaseAlias: true });
    assert.equal(open.ok, true);
    assert.equal(isManagedProgress(dir, "run-a"), true);
    assert.equal(isManagedPhase(dir, "12"), true);
    unlinkSync(join(dir, "progress", "c", "run-a.json"));
    writeFileSync(join(dir, "progress", "12.json"), "broken");
    const repaired = readManagedProgress(dir, "run-a");
    assert.equal(repaired?.corrida, "run-a");
    assert.equal(readManagedPhase(dir, "12")?.corrida, "run-a");
    assert.equal(JSON.parse(readFileSync(join(dir, "progress", "12.json"), "utf8")).schema, "runbook-progress.v1");
  }));

  it("keeps independent runs and rejects competing ownership of a phase", () => temp((dir) => {
    assert.equal(submitProgressEvent(dir, { ...common, kind: "run.opened", id: "open-a", doc: doc(), roundBudget: {}, phaseAlias: true }).ok, true);
    const other = { ...common, corrida: "run-b", id: "open-b", kind: "run.opened", doc: { ...doc(), corrida: "run-b" }, roundBudget: {}, phaseAlias: true };
    assert.equal(submitProgressEvent(dir, other).ok, false);
    const { phaseAlias: _unused, ...withoutAlias } = other;
    assert.equal(submitProgressEvent(dir, withoutAlias).ok, true);
    assert.equal(readManagedPhase(dir, "12")?.corrida, "run-a");
    assert.equal(readManagedProgress(dir, "run-b")?.corrida, "run-b");
  }));

  it("imports an unchanged legacy run only with explicit importLegacy", () => temp((dir) => {
    const initial = doc();
    mkdirSync(join(dir, "progress", "c"), { recursive: true });
    writeFileSync(join(dir, "progress", "c", "run-a.json"), JSON.stringify(initial));
    const opening = { ...common, kind: "run.opened", id: "import", doc: initial, roundBudget: { C: 2 } };
    assert.equal(submitProgressEvent(dir, opening).ok, false);
    assert.equal(submitProgressEvent(dir, { ...opening, phaseAlias: true }).ok, false);
    const result = submitProgressEvent(dir, { ...opening, importLegacy: true });
    assert.equal(result.ok, true);
    assert.equal(readManagedProgress(dir, "run-a")?.corrida, "run-a");
  }));

  it("refuses import when the legacy projection changed after the client read it", () => temp((dir) => {
    const initial = doc();
    mkdirSync(join(dir, "progress", "c"), { recursive: true });
    writeFileSync(join(dir, "progress", "c", "run-a.json"), JSON.stringify({ ...initial, titulo: "A newer title" }));
    const result = submitProgressEvent(dir, { ...common, kind: "run.opened", id: "import", doc: initial, roundBudget: {}, importLegacy: true });
    assert.equal(result.ok, false);
    assert.equal(isManagedProgress(dir, "run-a"), false);
    assert.equal(JSON.parse(readFileSync(join(dir, "progress", "c", "run-a.json"), "utf8")).titulo, "A newer title");
  }));

  it("does not replace an existing legacy phase with a different run", () => temp((dir) => {
    const initial = doc();
    mkdirSync(join(dir, "progress"), { recursive: true });
    writeFileSync(join(dir, "progress", "12.json"), JSON.stringify(initial));
    const replacement = { ...initial, corrida: "run-b", titulo: "Different run" };
    const result = submitProgressEvent(dir, {
      kind: "run.opened", id: "replace", corrida: "run-b", at: common.at,
      doc: replacement, roundBudget: {}, phaseAlias: true,
    });
    assert.equal(result.ok, false);
    assert.equal(isManagedPhase(dir, "12"), false);
    assert.equal(JSON.parse(readFileSync(join(dir, "progress", "12.json"), "utf8")).corrida, "run-a");
  }));

  it("replay preserves the newest worker after an unrelated delayed status", () => temp((dir) => {
    const initial: ProgresoDoc = JSON.parse(readFileSync(new URL("./fixtures/v2-native-workers.json", import.meta.url), "utf8"));
    const corrida = initial.corrida!;
    const carril = initial.carriles[0].id;
    const newer = initial.carriles[1].worker!;
    const older = initial.carriles[0].worker!;
    assert.equal(submitProgressEvent(dir, { kind: "run.opened", id: "open", corrida, at: "2026-09-30T12:00:00Z", doc: initial, roundBudget: {} }).ok, true);
    assert.equal(submitProgressEvent(dir, { kind: "part.worker", id: "new", corrida, at: "2026-09-30T12:02:00.500Z", expectedRevision: 1, carril, worker: newer, note: "new worker" }).ok, true);
    assert.equal(submitProgressEvent(dir, { kind: "part.status", id: "delayed", corrida, at: "2026-09-30T12:00:00Z", expectedRevision: 2, carril, estado: "implementando", que: "delayed status" }).ok, true);
    const stale = submitProgressEvent(dir, { kind: "part.worker", id: "old", corrida, at: "2026-09-30T12:02:00Z", expectedRevision: 3, carril, worker: older, note: "old worker" });
    assert.equal(stale.ok, false);
    assert.equal(readManagedProgress(dir, corrida)?.carriles[0].worker?.id, newer.id);
    assert.equal(readManagedProgress(dir, corrida)?.lead.actualizado, "2026-09-30T12:02:00.500Z");
  }));

  it("accepts two native worker generations in one second and replays the successor", () => temp((dir) => {
    const initial: ProgresoDoc = JSON.parse(readFileSync(new URL("./fixtures/v2-native-workers.json", import.meta.url), "utf8"));
    const corrida = initial.corrida!;
    const carril = initial.carriles[0].id;
    const at = "2026-09-30T12:02:00Z";
    assert.equal(submitProgressEvent(dir, { kind: "run.opened", id: "open", corrida, at, doc: initial, roundBudget: {} }).ok, true);
    assert.equal(submitProgressEvent(dir, { kind: "part.worker", id: "first", corrida, at, expectedRevision: 1, carril, worker: initial.carriles[1].worker, note: "first", source: "native", generation: 1 }).ok, true);
    assert.equal(submitProgressEvent(dir, { kind: "part.worker", id: "successor", corrida, at, expectedRevision: 2, carril, worker: initial.carriles[2].worker, note: "successor", source: "native", generation: 2 }).ok, true);
    assert.equal(submitProgressEvent(dir, { kind: "part.worker", id: "late-first", corrida, at, expectedRevision: 3, carril, worker: initial.carriles[1].worker, note: "stale", source: "native", generation: 1 }).ok, false);
    assert.equal(readManagedProgress(dir, corrida)?.carriles[0].worker?.id, initial.carriles[2].worker?.id);
  }));

  it("reports current revision on stale commands and paginates committed events", () => temp((dir) => {
    submitProgressEvent(dir, { ...common, kind: "run.opened", id: "open", doc: doc(), roundBudget: { C: 2 } });
    const change = { ...common, kind: "attention.changed", id: "attention", expectedRevision: 1, necesaria: true, motivo: "Revisar" };
    assert.equal(submitProgressEvent(dir, change).ok, true);
    const stale = submitProgressEvent(dir, { ...change, id: "other", expectedRevision: 1 });
    assert.deepEqual({ ok: stale.ok, revision: stale.revision }, { ok: false, revision: 2 });
    const page = readProgressEvents(dir, "run-a", 1, 1);
    assert.equal(page.events[0].command.id, "attention");
    assert.equal(page.next, 2);
  }));

  it("recovers phase ownership from the committed log if the pointer was lost", () => temp((dir) => {
    submitProgressEvent(dir, { ...common, kind: "run.opened", id: "open", doc: doc(), roundBudget: {}, phaseAlias: true });
    unlinkSync(join(dir, "progress", "phase-owners", "12.json"));
    assert.equal(readManagedPhase(dir, "12")?.corrida, "run-a");
    assert.equal(isManagedPhase(dir, "12"), true);
  }));

  it("uses distinct locks when a run ID looks like the phase lock name", () => temp((dir) => {
    const aliasDoc = { ...doc(), corrida: "phase-12" };
    const result = submitProgressEvent(dir, { kind: "run.opened", id: "open", corrida: "phase-12", at: common.at, doc: aliasDoc, roundBudget: {}, phaseAlias: true });
    assert.equal(result.ok, true);
    assert.equal(readManagedPhase(dir, "12")?.corrida, "phase-12");
  }));

  it("waits for a legacy writer before importing its run projection", async () => {
    const dir = mkdtempSync(join(tmpdir(), "progress-store-"));
    try {
      const initial = doc();
      mkdirSync(join(dir, "progress", "c"), { recursive: true });
      writeFileSync(join(dir, "progress", "c", "run-a.json"), JSON.stringify(initial));
      const changed = { ...initial, titulo: "Updated by legacy set" };
      const code = `import { withLegacyProgressLock } from ${JSON.stringify(new URL("./progress-store.ts", import.meta.url).href)}; import { writeFileSync } from "node:fs"; withLegacyProgressLock(process.argv[1], "12", "run-a", () => { process.stdout.write("locked\\n"); Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100); writeFileSync(process.argv[2], process.argv[3]); });`;
      const child = spawn(process.execPath, ["--input-type=module", "-e", code, dir, join(dir, "progress", "c", "run-a.json"), JSON.stringify(changed)], { stdio: ["ignore", "pipe", "pipe"] });
      const closed = once(child, "close");
      await once(child.stdout, "data");
      const imported = submitProgressEvent(dir, { ...common, kind: "run.opened", id: "import", doc: initial, roundBudget: {}, importLegacy: true });
      assert.equal(imported.ok, false);
      assert.equal(isManagedProgress(dir, "run-a"), false);
      assert.equal(JSON.parse(readFileSync(join(dir, "progress", "c", "run-a.json"), "utf8")).titulo, "Updated by legacy set");
      await closed;
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });

  it("rejects invalid keys before entering the legacy write callback", () => temp((dir) => {
    let called = false;
    assert.throws(() => withLegacyProgressLock(dir, "../12", "run-a", () => { called = true; }), /fase/);
    assert.throws(() => withLegacyProgressLock(dir, "12", "../run", () => { called = true; }), /corrida/);
    assert.equal(called, false);
  }));

  it("serializes two processes writing one revision", async () => {
    const dir = mkdtempSync(join(tmpdir(), "progress-store-"));
    try {
      submitProgressEvent(dir, { ...common, kind: "run.opened", id: "open", doc: doc(), roundBudget: {} });
      const worker = (eventId: string): Promise<unknown> => new Promise((resolve, reject) => {
        const command = { ...common, kind: "attention.changed", id: eventId, expectedRevision: 1, necesaria: true, motivo: eventId };
        const code = `import { submitProgressEvent } from ${JSON.stringify(new URL("./progress-store.ts", import.meta.url).href)}; process.stdout.write(JSON.stringify(submitProgressEvent(process.argv[1], JSON.parse(process.argv[2]))));`;
        const child = spawn(process.execPath, ["--input-type=module", "-e", code, dir, JSON.stringify(command)], { stdio: ["ignore", "pipe", "pipe"] });
        let output = "";
        let errors = "";
        child.stdout.on("data", (chunk) => { output += chunk; });
        child.stderr.on("data", (chunk) => { errors += chunk; });
        child.on("error", reject);
        child.on("close", (status) => status === 0 ? resolve(JSON.parse(output)) : reject(new Error(errors)));
      });
      const results = await Promise.all([worker("first"), worker("second")]);
      assert.deepEqual(results.map((result) => (result as { ok: boolean }).ok).sort(), [false, true]);
      assert.equal(readProgressEvents(dir, "run-a", 0, 10).revision, 2);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});

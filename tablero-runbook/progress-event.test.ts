import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";
import type { ProgresoDoc } from "./contrato.ts";
import { applyProgressCommand, validateProgressCommand } from "./progress-event.ts";

const fixture = (): ProgresoDoc => JSON.parse(readFileSync(new URL("./fixtures/v2-campos-validos.json", import.meta.url), "utf8"));
const A = "a".repeat(40);
const B = "b".repeat(40);
const E = { ref: "evidence/ready.json", sha: "c".repeat(64) };
const common = { corrida: "fase12-tablero", at: "2026-09-30T12:00:00Z" };

describe("progress event projection", () => {
  it("opens a run and estimates queue progress from closed review rounds", () => {
    const doc = fixture();
    doc.carriles[0].ronda = undefined;
    doc.cola[0].avance = undefined;
    let state = applyProgressCommand(undefined, validateProgressCommand({ ...common, kind: "run.opened", id: "open", doc, roundBudget: { C: 2 } }));
    assert.equal(state.doc.cola[0].avance, 0);
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.started", id: "start1", expectedRevision: 1, carril: "C", intento: "attempt-a", ronda: 1, baseSha: A }));
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.ready", id: "ready1", expectedRevision: 2, carril: "C", intento: "attempt-a", ronda: 1, sha: B, evidence: E }));
    assert.equal(state.doc.cola[0].avance, 0);
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.verdict", id: "verdict1", expectedRevision: 3, carril: "C", intento: "attempt-a", ronda: 1, sha: B, verdict: "cambios", evidence: E }));
    assert.equal(state.doc.cola[0].avance, 50);
    assert.equal(state.doc.carriles[0].ronda, 1);
  });

  it("rejects a verdict for a different SHA or attempt", () => {
    let state = applyProgressCommand(undefined, validateProgressCommand({ ...common, kind: "run.opened", id: "open", doc: fixture(), roundBudget: { C: 2 } }));
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.started", id: "s", expectedRevision: 1, carril: "C", intento: "one", ronda: 1, baseSha: A }));
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.ready", id: "r", expectedRevision: 2, carril: "C", intento: "one", ronda: 1, sha: B, evidence: E }));
    assert.throws(() => applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.verdict", id: "v", expectedRevision: 3, carril: "C", intento: "one", ronda: 1, sha: A, verdict: "aprobado", evidence: E })), /SHA/);
    assert.throws(() => applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.verdict", id: "v2", expectedRevision: 3, carril: "C", intento: "other", ronda: 1, sha: B, verdict: "aprobado", evidence: E })), /intento/);
  });

  it("moves a pending part into progress when its first round starts", () => {
    const doc = fixture();
    doc.carriles[0].estado = "pendiente";
    let state = applyProgressCommand(undefined, validateProgressCommand({ ...common, kind: "run.opened", id: "open", doc, roundBudget: { C: 2 } }));
    state = applyProgressCommand(state, validateProgressCommand({ ...common, kind: "round.started", id: "start", expectedRevision: 1, carril: "C", intento: "one", ronda: 1, baseSha: A }));
    assert.equal(state.doc.carriles[0].estado, "implementando");
  });

  it("rejects an older worker update and keeps the lead timestamp monotonic", () => {
    for (const scenario of ["fractional-time", "intervening-status"] as const) {
      const doc: ProgresoDoc = JSON.parse(readFileSync(new URL("./fixtures/v2-native-workers.json", import.meta.url), "utf8"));
      const corrida = doc.corrida!;
      const lane = doc.carriles[0].id;
      const newer = doc.carriles[1].worker!;
      const older = doc.carriles[0].worker!;
      const newerAt = scenario === "fractional-time" ? "2026-09-30T12:02:00.500Z" : "2026-09-30T12:02:00Z";
      const olderAt = scenario === "fractional-time" ? "2026-09-30T12:02:00Z" : "2026-09-30T12:01:00Z";
      let state = applyProgressCommand(undefined, validateProgressCommand({ kind: "run.opened", id: "open", corrida, at: "2026-09-30T12:00:00Z", doc, roundBudget: {} }));
      state = applyProgressCommand(state, validateProgressCommand({ kind: "part.worker", id: "new", corrida, at: newerAt, expectedRevision: 1, carril: lane, worker: newer, note: "new worker" }));
      if (scenario === "intervening-status") {
        state = applyProgressCommand(state, validateProgressCommand({ kind: "part.status", id: "status", corrida, at: "2026-09-30T12:00:00Z", expectedRevision: 2, carril: lane, estado: "implementando", que: "delayed status" }));
      }
      assert.throws(() => applyProgressCommand(state, validateProgressCommand({ kind: "part.worker", id: "old", corrida, at: olderAt, expectedRevision: state.revision, carril: lane, worker: older, note: "old worker" })), /worker anterior/, scenario);
      assert.equal(state.doc.carriles[0].worker?.id, newer.id);
      assert.equal(state.doc.lead.actualizado, newerAt);
    }
  });

  it("accepts a later worker tenure within the same second and rejects the old tenure", () => {
    const doc: ProgresoDoc = JSON.parse(readFileSync(new URL("./fixtures/v2-native-workers.json", import.meta.url), "utf8"));
    const corrida = doc.corrida!;
    const carril = doc.carriles[0].id;
    const at = "2026-09-30T12:02:00Z";
    let state = applyProgressCommand(undefined, validateProgressCommand({ kind: "run.opened", id: "open", corrida, at, doc, roundBudget: {} }));
    state = applyProgressCommand(state, validateProgressCommand({ kind: "part.worker", id: "first", corrida, at, expectedRevision: 1, carril, worker: doc.carriles[1].worker, note: "first", source: "native", generation: 1 }));
    state = applyProgressCommand(state, validateProgressCommand({ kind: "part.worker", id: "successor", corrida, at, expectedRevision: 2, carril, worker: doc.carriles[2].worker, note: "successor", source: "native", generation: 2 }));
    assert.equal(state.doc.carriles[0].worker?.id, doc.carriles[2].worker?.id);
    assert.throws(() => applyProgressCommand(state, validateProgressCommand({ kind: "part.worker", id: "late-first", corrida, at, expectedRevision: 3, carril, worker: doc.carriles[1].worker, note: "stale", source: "native", generation: 1 })), /worker anterior/);
  });

  it("rejects malformed identifiers, evidence and stale revisions", () => {
    assert.throws(() => validateProgressCommand({ ...common, kind: "round.ready", id: "../bad", carril: "C", intento: "one", ronda: 1, sha: B, evidence: E }), /id/);
    assert.throws(() => validateProgressCommand({ ...common, kind: "round.ready", id: "ok", carril: "C", intento: "one", ronda: 1, sha: B, evidence: { ref: "../escape", sha: E.sha } }), /evidence/);
    const state = applyProgressCommand(undefined, validateProgressCommand({ ...common, kind: "run.opened", id: "open", doc: fixture(), roundBudget: { C: 2 } }));
    assert.throws(() => applyProgressCommand(state, validateProgressCommand({ ...common, kind: "attention.changed", id: "attention", expectedRevision: 0, necesaria: true, motivo: "Revisar" })), /revision/);
  });
});

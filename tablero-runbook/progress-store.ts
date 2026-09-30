import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync, writeSync, fsyncSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { CORRIDA_RE, FASE_RE, validarProgreso } from "./contrato.ts";
import type { ProgresoDoc } from "./contrato.ts";
import { applyProgressCommand, validateProgressCommand } from "./progress-event.ts";
import type { ProgressCommand, ProgressState } from "./progress-event.ts";

export type StoredProgressEvent = { revision: number; command: ProgressCommand };
type EventLog = { schema: "runbook-progress-events.v1"; corrida: string; events: StoredProgressEvent[] };
type Result = { ok: true; revision: number; duplicate: boolean; doc: ProgresoDoc } | { ok: false; reason: string; revision?: number };
const LOG_SCHEMA = "runbook-progress-events.v1";
const MAX_EVENTS = 10_000;
const pause = new Int32Array(new SharedArrayBuffer(4));

const logPath = (dir: string, corrida: string) => join(dir, "progress", "e", `${corrida}.json`);
const docPath = (dir: string, corrida: string) => join(dir, "progress", "c", `${corrida}.json`);
const ownerPath = (dir: string, fase: string) => join(dir, "progress", "phase-owners", `${fase}.json`);
const phasePath = (dir: string, fase: string) => join(dir, "progress", `${fase}.json`);
const phaseLockPath = (dir: string, fase: string) => join(dir, "progress", "locks", "f", `${fase}.lock`);
const runLockPath = (dir: string, corrida: string) => join(dir, "progress", "locks", "c", `${corrida}.lock`);
const validateCorrida = (corrida: string): void => { if (!CORRIDA_RE.test(corrida)) throw new Error("corrida inválida"); };

function atomicJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
  const descriptor = openSync(temporary, "wx", 0o600);
  try {
    writeSync(descriptor, `${JSON.stringify(value, null, 2)}\n`);
    fsyncSync(descriptor);
  } finally { closeSync(descriptor); }
  try {
    renameSync(temporary, path);
    if (process.platform !== "win32") {
      const parent = openSync(dirname(path), "r");
      try { fsyncSync(parent); } finally { closeSync(parent); }
    }
  } catch (error) {
    rmSync(temporary, { force: true });
    throw error;
  }
}

function withLock<T>(path: string, action: () => T): T {
  mkdirSync(dirname(path), { recursive: true });
  const deadline = Date.now() + 10_000;
  while (true) {
    try {
      mkdirSync(path);
      break;
    } catch (error) {
      if (!existsSync(path)) throw error;
      let stale = false;
      try {
        const pid = Number(readFileSync(join(path, "owner"), "utf8"));
        if (Number.isSafeInteger(pid) && pid > 0) {
          try { process.kill(pid, 0); } catch (e) { if (e && typeof e === "object" && "code" in e && e.code === "ESRCH") stale = true; }
        } else if (Date.now() - statSync(path).mtimeMs > 30_000) stale = true;
      } catch { if (Date.now() - statSync(path).mtimeMs > 30_000) stale = true; }
      if (stale) { rmSync(path, { recursive: true, force: true }); continue; }
      if (Date.now() >= deadline) throw new Error("progress lock timeout");
      Atomics.wait(pause, 0, 0, 20);
    }
  }
  try { writeFileSync(join(path, "owner"), String(process.pid)); }
  catch (error) { rmSync(path, { recursive: true, force: true }); throw error; }
  try { return action(); } finally { rmSync(path, { recursive: true, force: true }); }
}

function readLog(dir: string, corrida: string): EventLog | undefined {
  const path = logPath(dir, corrida);
  if (!existsSync(path)) return undefined;
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!raw || typeof raw !== "object" || Array.isArray(raw) || !("schema" in raw) || raw.schema !== LOG_SCHEMA || !("corrida" in raw) || raw.corrida !== corrida || !("events" in raw) || !Array.isArray(raw.events)) throw new Error("registro de eventos inválido");
  const events: StoredProgressEvent[] = [];
  for (const row of raw.events) {
    if (!row || typeof row !== "object" || Array.isArray(row) || !("revision" in row) || row.revision !== events.length + 1 || !("command" in row)) throw new Error("secuencia de eventos inválida");
    events.push({ revision: row.revision, command: validateProgressCommand(row.command) });
  }
  return { schema: LOG_SCHEMA, corrida, events };
}

function replay(log: EventLog): ProgressState {
  let state: ProgressState | undefined;
  for (const row of log.events) state = applyProgressCommand(state, row.command);
  if (!state) throw new Error("registro de eventos vacío");
  return state;
}

function sameContent(left: ProgressCommand, right: ProgressCommand): boolean {
  const strip = (command: ProgressCommand) => { const copy: Record<string, unknown> = structuredClone(command) as unknown as Record<string, unknown>; delete copy.expectedRevision; return copy; };
  return canonical(strip(left)) === canonical(strip(right));
}

function canonical(value: unknown): string {
  return JSON.stringify(value, (_, item: unknown) => item && typeof item === "object" && !Array.isArray(item) ? Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b))) : item);
}

function digest(value: unknown): string { return createHash("sha256").update(canonical(value)).digest("hex"); }

function owner(dir: string, fase: string): string | undefined {
  const path = ownerPath(dir, fase);
  if (existsSync(path)) {
    const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
    if (!raw || typeof raw !== "object" || Array.isArray(raw) || !("corrida" in raw) || typeof raw.corrida !== "string" || !CORRIDA_RE.test(raw.corrida)) throw new Error("phase owner inválido");
    if (existsSync(logPath(dir, raw.corrida))) return raw.corrida;
  }
  const directory = join(dir, "progress", "e");
  if (!existsSync(directory)) return undefined;
  for (const file of readdirSync(directory)) {
    if (!file.endsWith(".json")) continue;
    const corrida = file.slice(0, -5);
    if (!CORRIDA_RE.test(corrida)) continue;
    const opened = readLog(dir, corrida)?.events[0]?.command;
    if (opened?.kind === "run.opened" && opened.phaseAlias && opened.doc.fase === fase) {
      atomicJson(path, { corrida });
      return corrida;
    }
  }
  return undefined;
}

function repair(dir: string, state: ProgressState, phaseAlias: boolean): void {
  const path = docPath(dir, state.doc.corrida!);
  const expected = `${JSON.stringify(state.doc, null, 2)}\n`;
  if (!existsSync(path) || readFileSync(path, "utf8") !== expected) atomicJson(path, state.doc);
  if (phaseAlias && owner(dir, state.doc.fase) === state.doc.corrida) {
    const alias = phasePath(dir, state.doc.fase);
    if (!existsSync(alias) || readFileSync(alias, "utf8") !== expected) atomicJson(alias, state.doc);
  }
}

export function submitProgressEvent(stateDir: string, raw: unknown): Result {
  let command: ProgressCommand;
  try { command = validateProgressCommand(raw); } catch (error) { return { ok: false, reason: String(error instanceof Error ? error.message : error) }; }
  const execute = (): Result => withLock(runLockPath(stateDir, command.corrida), () => {
    try {
      const log = readLog(stateDir, command.corrida);
      const duplicate = log?.events.find((row) => row.command.id === command.id);
      if (duplicate) {
        if (!sameContent(duplicate.command, command)) return { ok: false, reason: "event id conflict", revision: log!.events.length };
        const state = replay(log!);
        const opened = log!.events[0].command;
        repair(stateDir, state, opened.kind === "run.opened" && Boolean(opened.phaseAlias));
        return { ok: true, revision: duplicate.revision, duplicate: true, doc: state.doc };
      }
      const prior = log ? replay(log) : undefined;
      if (command.kind !== "run.opened" && command.expectedRevision !== prior?.revision) return { ok: false, reason: "revision conflict", revision: prior?.revision ?? 0 };
      if (command.kind === "run.opened" && prior) return { ok: false, reason: "corrida ya existe", revision: prior.revision };
      if (command.kind === "run.opened") {
        const legacyPath = docPath(stateDir, command.corrida);
        const hasLegacy = existsSync(legacyPath);
        if (hasLegacy !== Boolean(command.importLegacy)) return { ok: false, reason: hasLegacy ? "corrida legacy requiere importLegacy" : "corrida legacy no existe" };
        if (hasLegacy) {
          const legacy: unknown = JSON.parse(readFileSync(legacyPath, "utf8"));
          const verdict = validarProgreso(legacy);
          if (!verdict.ok || digest(legacy) !== digest(command.doc)) return { ok: false, reason: "legacy projection changed or invalid" };
        }
      }
      if (command.kind === "run.opened" && command.phaseAlias) {
        const current = owner(stateDir, command.doc.fase);
        if (current && current !== command.corrida) return { ok: false, reason: "fase ya tiene corrida administrada" };
        const existingPhase = phasePath(stateDir, command.doc.fase);
        if (!current && existsSync(existingPhase)) {
          const legacy: unknown = JSON.parse(readFileSync(existingPhase, "utf8"));
          if (!command.importLegacy || digest(legacy) !== digest(command.doc)) {
            return { ok: false, reason: "fase legacy requiere importLegacy sin cambios" };
          }
        }
      }
      const next = applyProgressCommand(prior, command);
      if ((log?.events.length ?? 0) >= MAX_EVENTS) return { ok: false, reason: "event log limit reached", revision: prior?.revision };
      const nextLog: EventLog = { schema: LOG_SCHEMA, corrida: command.corrida, events: [...(log?.events ?? []), { revision: next.revision, command }] };
      atomicJson(logPath(stateDir, command.corrida), nextLog);
      if (command.kind === "run.opened" && command.phaseAlias) atomicJson(ownerPath(stateDir, command.doc.fase), { corrida: command.corrida });
      const opened = command.kind === "run.opened" ? command : log!.events[0].command;
      repair(stateDir, next, opened.kind === "run.opened" && Boolean(opened.phaseAlias));
      return { ok: true, revision: next.revision, duplicate: false, doc: next.doc };
    } catch (error) { return { ok: false, reason: String(error instanceof Error ? error.message : error) }; }
  });
  try {
    if (command.kind === "run.opened" && command.phaseAlias) return withLock(phaseLockPath(stateDir, command.doc.fase), execute);
    return execute();
  } catch (error) { return { ok: false, reason: String(error instanceof Error ? error.message : error) }; }
}

export function isManagedProgress(stateDir: string, corrida: string): boolean { validateCorrida(corrida); return existsSync(logPath(stateDir, corrida)); }
export function isManagedPhase(stateDir: string, fase: string): boolean { if (!FASE_RE.test(fase)) throw new Error("fase inválida"); return owner(stateDir, fase) !== undefined; }
export function withLegacyProgressLock<T>(stateDir: string, fase: string, corrida: string | undefined, fn: () => T): T {
  if (!FASE_RE.test(fase)) throw new Error("fase inválida");
  if (corrida !== undefined) validateCorrida(corrida);
  return withLock(phaseLockPath(stateDir, fase), () => corrida === undefined ? fn() : withLock(runLockPath(stateDir, corrida), fn));
}
export function readManagedSnapshot(stateDir: string, corrida: string): { doc: ProgresoDoc; revision: number } | undefined {
  validateCorrida(corrida);
  return withLock(runLockPath(stateDir, corrida), () => {
    const log = readLog(stateDir, corrida);
    if (!log) return undefined;
    const state = replay(log);
    const opened = log.events[0].command;
    repair(stateDir, state, opened.kind === "run.opened" && Boolean(opened.phaseAlias));
    return { doc: state.doc, revision: state.revision };
  });
}
export function readManagedProgress(stateDir: string, corrida: string): ProgresoDoc | undefined { return readManagedSnapshot(stateDir, corrida)?.doc; }
export function readManagedRevision(stateDir: string, corrida: string): number | undefined { validateCorrida(corrida); return readLog(stateDir, corrida)?.events.length; }
export function readManagedPhaseSnapshot(stateDir: string, fase: string): { doc: ProgresoDoc; revision: number } | undefined {
  if (!FASE_RE.test(fase)) throw new Error("fase inválida");
  const corrida = owner(stateDir, fase);
  return corrida ? readManagedSnapshot(stateDir, corrida) : undefined;
}
export function readManagedPhase(stateDir: string, fase: string): ProgresoDoc | undefined {
  return readManagedPhaseSnapshot(stateDir, fase)?.doc;
}
export function readProgressEvents(stateDir: string, corrida: string, after = 0, limit = 100): { events: StoredProgressEvent[]; revision: number; next: number } {
  validateCorrida(corrida);
  if (!Number.isSafeInteger(after) || after < 0 || !Number.isSafeInteger(limit) || limit < 1 || limit > 500) throw new Error("paginación inválida");
  const log = readLog(stateDir, corrida);
  const events = (log?.events ?? []).filter((row) => row.revision > after).slice(0, limit);
  return { events, revision: log?.events.length ?? 0, next: events.at(-1)?.revision ?? after };
}

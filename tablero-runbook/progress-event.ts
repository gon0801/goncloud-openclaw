import { CARRIL_ESTADOS, CORRIDA_RE, SHA_RE, TEXTO_MAX, validarProgreso } from "./contrato.ts";
import type { Carril, ColaItem, ProgresoDoc, WorkerBloque } from "./contrato.ts";

const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const HASH_RE = /^[0-9a-f]{64}$/;
const REF_RE = /^evidence\/[A-Za-z0-9][A-Za-z0-9._/-]{0,180}$/;
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;
const text = (v: unknown, max = TEXTO_MAX): v is string => typeof v === "string" && v.length > 0 && v.length <= max && !/[\u0000-\u001f\u007f]/.test(v);
const record = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const positive = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v > 0;
const id = (v: unknown): v is string => typeof v === "string" && ID_RE.test(v);
const evidenceValid = (v: unknown): v is Evidence => record(v) && typeof v.ref === "string" && REF_RE.test(v.ref) && !v.ref.split("/").includes("..") && typeof v.sha === "string" && HASH_RE.test(v.sha);
const laterAt = (left: string, right: string): string => Date.parse(left) >= Date.parse(right) ? left : right;

export type Evidence = { ref: string; sha: string };
type Base = { id: string; corrida: string; at: string; expectedRevision?: number; source?: string };
export type ProgressCommand =
  | (Base & { kind: "run.opened"; doc: ProgresoDoc; roundBudget: Record<string, number>; phaseAlias?: true; importLegacy?: true })
  | (Base & { kind: "round.started"; carril: string; intento: string; ronda: number; baseSha: string })
  | (Base & { kind: "round.ready"; carril: string; intento: string; ronda: number; sha: string; evidence: Evidence })
  | (Base & { kind: "round.verdict"; carril: string; intento: string; ronda: number; sha: string; verdict: "aprobado" | "cambios"; evidence: Evidence })
  | (Base & { kind: "part.added"; carril: Carril; queueItem?: ColaItem; roundBudget?: number })
  | (Base & { kind: "part.status"; carril: string; estado: string; que?: string; pr?: number | null; nextStep?: string; evidence?: Evidence })
  | (Base & { kind: "part.worker"; carril: string; worker: WorkerBloque; note: string; generation?: number })
  | (Base & { kind: "attention.changed"; necesaria: boolean; motivo: string | null })
  | (Base & { kind: "run.closed"; resumen: string });

export type Round = { carril: string; intento: string; ronda: number; baseSha: string; readySha?: string; verdict?: "aprobado" | "cambios" };
export type ProgressState = { doc: ProgresoDoc; revision: number; roundBudget: Record<string, number>; rounds: Round[]; workerLastAt: Record<string, string>; workerGeneration: Record<string, number> };

export function validateProgressCommand(raw: unknown): ProgressCommand {
  if (!record(raw)) throw new Error("event must be an object");
  if (!id(raw.id)) throw new Error("id inválido");
  if (typeof raw.corrida !== "string" || !CORRIDA_RE.test(raw.corrida)) throw new Error("corrida inválida");
  if (typeof raw.at !== "string" || !ISO_RE.test(raw.at) || !Number.isFinite(Date.parse(raw.at))) throw new Error("at inválido");
  if (raw.expectedRevision !== undefined && (!Number.isSafeInteger(raw.expectedRevision) || Number(raw.expectedRevision) < 0)) throw new Error("expectedRevision inválida");
  if (raw.source !== undefined && !text(raw.source, 100)) throw new Error("source inválido");
  switch (raw.kind) {
    case "run.opened": {
      if (raw.phaseAlias !== undefined && raw.phaseAlias !== true) throw new Error("phaseAlias inválido");
      if (raw.importLegacy !== undefined && raw.importLegacy !== true) throw new Error("importLegacy inválido");
      const verdict = validarProgreso(raw.doc);
      if (!verdict.ok) throw new Error(`doc inválido: ${verdict.razones.join("; ")}`);
      const doc = raw.doc as ProgresoDoc;
      if (doc.corrida !== raw.corrida) throw new Error("doc.corrida no coincide");
      if (!record(raw.roundBudget)) throw new Error("roundBudget inválido");
      for (const [part, budget] of Object.entries(raw.roundBudget)) {
        if (!id(part) || !doc.carriles.some((c) => c.id === part) || !positive(budget)) throw new Error("roundBudget inválido");
      }
      return raw as ProgressCommand;
    }
    case "round.started":
    case "round.ready":
    case "round.verdict":
      if (!id(raw.carril) || !id(raw.intento) || !positive(raw.ronda)) throw new Error("carril, intento o ronda inválido");
      if (raw.kind === "round.started") {
        if (typeof raw.baseSha !== "string" || !SHA_RE.test(raw.baseSha)) throw new Error("baseSha inválido");
      } else {
        if (typeof raw.sha !== "string" || !SHA_RE.test(raw.sha)) throw new Error("SHA inválido");
        if (!evidenceValid(raw.evidence)) throw new Error("evidence inválida");
      }
      if (raw.kind === "round.verdict" && raw.verdict !== "aprobado" && raw.verdict !== "cambios") throw new Error("verdict inválido");
      return raw as ProgressCommand;
    case "part.added": {
      if (!record(raw.carril) || !id(raw.carril.id)) throw new Error("carril inválido");
      if (raw.queueItem !== undefined && (!record(raw.queueItem) || !id(raw.queueItem.id))) throw new Error("queueItem inválido");
      if (raw.roundBudget !== undefined && !positive(raw.roundBudget)) throw new Error("roundBudget inválido");
      return raw as ProgressCommand;
    }
    case "part.status":
      if (!id(raw.carril) || !(CARRIL_ESTADOS as readonly string[]).includes(String(raw.estado))) throw new Error("carril o estado inválido");
      if (raw.que !== undefined && !text(raw.que)) throw new Error("que inválido");
      if (raw.pr !== undefined && raw.pr !== null && (!positive(raw.pr) || raw.pr >= 10_000_000)) throw new Error("pr inválido");
      if (raw.nextStep !== undefined && !text(raw.nextStep, 160)) throw new Error("nextStep inválido");
      if (raw.evidence !== undefined && !evidenceValid(raw.evidence)) throw new Error("evidence inválida");
      if (raw.estado === "mergeado" && raw.source !== "manual" && !evidenceValid(raw.evidence)) throw new Error("evidence obligatoria para mergeado");
      return raw as ProgressCommand;
    case "part.worker":
      if (!id(raw.carril) || !record(raw.worker) || !text(raw.note)) throw new Error("worker inválido");
      if (raw.generation !== undefined && (!Number.isSafeInteger(raw.generation) || Number(raw.generation) < 0)) throw new Error("generation inválida");
      if (raw.source === "native" && raw.generation === undefined) throw new Error("generation obligatoria para worker nativo");
      return raw as ProgressCommand;
    case "attention.changed":
      if (typeof raw.necesaria !== "boolean" || (raw.necesaria && !text(raw.motivo)) || (!raw.necesaria && raw.motivo !== null)) throw new Error("atención inválida");
      return raw as ProgressCommand;
    case "run.closed":
      if (!text(raw.resumen)) throw new Error("resumen inválido");
      return raw as ProgressCommand;
    default:
      throw new Error("kind inválido");
  }
}

function updateQueue(state: ProgressState): void {
  for (const item of state.doc.cola) {
    const parts = state.doc.carriles.filter((part) => part.tareas.includes(item.id));
    if (!parts.length) continue;
    const values = parts.map((part) => {
      if (part.estado === "mergeado") return 100;
      const budget = state.roundBudget[part.id];
      if (!budget) return undefined;
      const closed = state.rounds.filter((round) => round.carril === part.id && round.verdict).length;
      return Math.min(99, Math.round((closed / budget) * 100));
    });
    item.avance = values.some((value) => value === undefined) ? undefined : Math.round((values as number[]).reduce((sum, value) => sum + value, 0) / values.length);
  }
}

export function applyProgressCommand(previous: ProgressState | undefined, command: ProgressCommand): ProgressState {
  if (command.kind === "run.opened") {
    if (previous) throw new Error("corrida ya abierta");
    const workerLastAt = Object.fromEntries(command.doc.carriles
      .filter((part) => part.worker)
      .map((part) => [part.id, laterAt(part.ultimo_evento?.at ?? command.doc.lead.actualizado, command.doc.lead.actualizado)]));
    const state: ProgressState = { doc: structuredClone(command.doc), revision: 1, roundBudget: structuredClone(command.roundBudget), rounds: [], workerLastAt, workerGeneration: {} };
    updateQueue(state);
    return state;
  }
  if (!previous) throw new Error("corrida no abierta");
  if (previous.doc.corrida !== command.corrida) throw new Error("corrida no coincide");
  if (command.expectedRevision !== previous.revision) throw new Error(`revision conflict: actual ${previous.revision}`);
  if (previous.doc.cierre.at !== null) throw new Error("corrida cerrada");
  const state = structuredClone(previous);
  const part = "carril" in command && typeof command.carril === "string" ? state.doc.carriles.find((entry) => entry.id === command.carril) : undefined;
  if ((command.kind.startsWith("round.") || command.kind === "part.status" || command.kind === "part.worker") && !part) throw new Error("carril desconocido");
  switch (command.kind) {
    case "round.started": {
      if (part!.estado === "mergeado" || part!.estado === "omitido") throw new Error("carril terminado");
      const last = state.rounds.filter((round) => round.carril === command.carril).at(-1);
      if (last && (!last.verdict || command.ronda !== (last.intento === command.intento ? last.ronda + 1 : 1))) throw new Error("ronda fuera de orden");
      if (!last && command.ronda !== 1) throw new Error("ronda fuera de orden");
      state.rounds.push({ carril: command.carril, intento: command.intento, ronda: command.ronda, baseSha: command.baseSha });
      part!.ronda = command.ronda;
      part!.estado = "implementando";
      break;
    }
    case "round.ready":
    case "round.verdict": {
      const round = state.rounds.filter((entry) => entry.carril === command.carril).at(-1);
      if (!round || round.ronda !== command.ronda) throw new Error("ronda fuera de orden");
      if (round.intento !== command.intento) throw new Error("intento no coincide");
      if (command.kind === "round.ready") {
        if (round.readySha || round.verdict) throw new Error("LISTO duplicado o fuera de orden");
        round.readySha = command.sha;
        part!.head = command.sha;
        part!.estado = "revision-cruzada";
      } else {
        if (!round.readySha || round.verdict) throw new Error("veredicto fuera de orden");
        if (round.readySha !== command.sha) throw new Error("SHA revisado no coincide con LISTO");
        round.verdict = command.verdict;
        part!.estado = command.verdict === "aprobado" ? "auditoria-lead" : "implementando";
      }
      break;
    }
    case "part.added":
      if (state.doc.carriles.some((entry) => entry.id === command.carril.id)) throw new Error("carril duplicado");
      state.doc.carriles.push(structuredClone(command.carril));
      if (command.carril.worker) state.workerLastAt[command.carril.id] = laterAt(command.carril.ultimo_evento?.at ?? command.at, command.at);
      if (command.roundBudget) state.roundBudget[command.carril.id] = command.roundBudget;
      if (command.queueItem) {
        if (state.doc.cola.some((item) => item.id === command.queueItem!.id)) throw new Error("queueItem duplicado");
        state.doc.cola.push(structuredClone(command.queueItem));
      }
      break;
    case "part.status":
      part!.estado = command.estado;
      part!.detenido_por = command.estado === "atorado" ? command.que ?? "Atorado" : null;
      if (command.pr !== undefined) part!.pr = command.pr;
      if (command.nextStep) state.doc.siguiente_paso = command.nextStep;
      if (command.que) part!.ultimo_evento = { at: command.at, que: command.que };
      if (command.estado === "mergeado") {
        const round = state.rounds.filter((entry) => entry.carril === command.carril).at(-1);
        if (command.source !== "manual" && (!round || round.verdict !== "aprobado")) throw new Error("mergeado requiere veredicto aprobado");
      }
      break;
    case "part.worker":
      if (command.generation !== undefined) {
        const priorGeneration = state.workerGeneration[part!.id];
        if (priorGeneration !== undefined && command.generation <= priorGeneration) throw new Error("worker anterior al estado del carril");
        if (priorGeneration === undefined && state.workerLastAt[part!.id] !== undefined && Date.parse(command.at) < Date.parse(state.workerLastAt[part!.id])) throw new Error("worker anterior al estado del carril");
        state.workerGeneration[part!.id] = command.generation;
      } else if (state.workerGeneration[part!.id] !== undefined || state.workerLastAt[part!.id] !== undefined && Date.parse(command.at) <= Date.parse(state.workerLastAt[part!.id])) {
        throw new Error("worker anterior al estado del carril");
      }
      part!.worker = structuredClone(command.worker);
      part!.ultimo_evento = { at: command.at, que: command.note };
      state.workerLastAt[part!.id] = laterAt(state.workerLastAt[part!.id] ?? command.at, command.at);
      break;
    case "attention.changed":
      state.doc.atencion_requerida = { necesaria: command.necesaria, motivo: command.motivo, desde: command.necesaria ? command.at : null };
      break;
    case "run.closed":
      state.doc.cierre = { ...state.doc.cierre, at: command.at, resumen: command.resumen };
      state.doc.atencion_requerida = { necesaria: false, motivo: null, desde: null };
      break;
  }
  state.revision++;
  if (Date.parse(state.doc.lead.actualizado) < Date.parse(command.at)) state.doc.lead.actualizado = command.at;
  state.doc.eventos.push({ at: command.at, carril: typeof command.carril === "string" ? command.carril : null, que: command.kind === "part.status" ? command.que ?? command.kind : command.kind, situacion: "evidence" in command && command.evidence ? command.evidence.ref : command.kind === "part.status" && command.estado === "mergeado" && command.source === "manual" ? "manual; sin evidencia de entrega" : null });
  if (state.doc.eventos.length > 100) state.doc.eventos.splice(0, state.doc.eventos.length - 100);
  updateQueue(state);
  const verdict = validarProgreso(state.doc);
  if (!verdict.ok) throw new Error(`proyección inválida: ${verdict.razones.join("; ")}`);
  return state;
}

#!/usr/bin/env node
/**
 * backfill-rendiciones — corre el detector del observer (summa-gate/observer.ts
 * via buildRecord) sobre el historico de sesiones del gateway, sin esperar
 * el periodo de 14 dias del plan original.
 *
 * Por que existe:
 *   La tarea 2.2 del Plans.md media la tasa base de rendiciones sobre el
 *   jsonl que 2.1 va llenando "durante 14 dias". David pidio (2026-09-12)
 *   correrla HOY con el mismo detector sobre el historico que ya existe:
 *   buildRecord es una funcion PURA sobre los mensajes de un turno, asi
 *   que el numero retroactivo ES el numero que se iba a tener en 14 dias.
 *
 * Que hace:
 *   1. Para cada agente de AGENTS, llama `openclaw gateway call sessions.list
 *      --params '{"limit":N,"agentId":"<agente>"}'` paginando hasta agotar.
 *   2. Para cada sessionKey, llama `chat.history --params
 *      '{"sessionKey":"<key>","limit":N,"offset":M}'` paginando hasta traer
 *      los `totalMessages`. Si la suma de mensajes traidos difiere de
 *      totalMessages, la sesion queda marcada como `incomplete=true` (no
 *      se cuenta como "cero rendiciones").
 *   3. Segmenta los messages en TURNOS: un turno va del mensaje `user` N
 *      hasta el mensaje `user` N+1 (o hasta el fin de la sesion). Esta es
 *      la unidad que el runtime de agent_end le pasaria al observer hook
 *      en vivo: el agente emite su respuesta sobre la peticion N, y
 *      hasta que llegue la N+1 son todos mensajes "del mismo turno".
 *   4. Para cada turno, llama `buildRecord(ts, sessionKey, agent, kind,
 *      messages_adapted)` con el adaptador de agent-history-adapter.ts.
 *      Esto reusa el MISMO detector que el agent_end hook usa en vivo.
 *   5. Escribe una linea jsonl por record con el campo extra
 *      `backfill_meta = {agent, totalMessages, returnedMessages,
 *      incomplete, turnIndex, sessionCreatedAt, sessionUpdatedAt}`.
 *
 * Que NO hace:
 *   - No re-implementa el detector. La unica fuente de verdad para el
 *     veredicto es buildRecord importado del plugin.
 *   - No confunde unknown con 0: sesiones cuya paginacion no cerro
 *     (incomplete=true) se reportan aparte.
 *   - No vive en /tmp: el jsonl y el summary van al repo
 *     (docs/evidence/... por default), asi sobreviven a reinicios.
 *
 * Como se corre (desde la raiz del repo):
 *   # corrida limpia (sobre-escribe):
 *   node summa-gate/backfill-rendiciones.mjs --start
 *   # reanudar desde donde se corto la corrida anterior:
 *   node summa-gate/backfill-rendiciones.mjs --resume
 *   # procesar solo main (util para smoke):
 *   node summa-gate/backfill-rendiciones.mjs --start --agents main
 */

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const { buildRecord } = await import(pathToFileURL(join(repo, "summa-gate/observer.ts")).href);
const { adaptHistoryMessages } = await import(pathToFileURL(join(repo, "summa-gate/agent-history-adapter.ts")).href);

function parseArgs(argv) {
  const out = {
    agents: null,
    out: join(repo, "docs/evidence/backfill-rendiciones.jsonl"),
    limit: 80,
    resume: false,
    start: false,
    quiet: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--agents") out.agents = argv[++i].split(",").map((s) => s.trim()).filter(Boolean);
    else if (a === "--out") out.out = argv[++i];
    else if (a === "--limit") out.limit = parseInt(argv[++i], 10);
    else if (a === "--resume") out.resume = true;
    else if (a === "--start") out.start = true;
    else if (a === "--quiet") out.quiet = true;
    else if (a === "--exclude-rule") out.excludeRule = argv[++i];
    else if (a === "--include-test-prompts") out.excludeRule = "";
  }
  if (typeof out.excludeRule !== "string") {
    // Default exclusion: the operator's smoke-test turns that fed the
    // observer a known refusal phrase to verify wiring. They are not
    // production data; if you want to include them, pass
    // --include-test-prompts (sets the regex to "") or override with
    // --exclude-rule <regex>.
    out.excludeRule = "^agent:scout:smoke-observador-";
  }
  if (!out.agents || out.agents.length === 0) {
    out.agents = ["main", "ingenieria", "operaciones", "verifier", "implementer", "scout", "reviewer", "adversary"];
  }
  return out;
}

const ARGS = parseArgs(process.argv);
const LIMIT_SESSIONS = 50;
const LIMIT_HISTORY = Number.isFinite(ARGS.limit) && ARGS.limit > 0 ? ARGS.limit : 80;
const SUMMARY_FILE = ARGS.out + ".summary.json";

function callGateway(method, params) {
  const stdout = execFileSync("openclaw", ["gateway", "call", method, "--params", JSON.stringify(params), "--json"], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
  return JSON.parse(stdout);
}

function listSessionsForAgent(agentId) {
  const seen = new Set();
  const out = [];
  let offset = 0;
  let totalCount = null;
  let safety = 0;
  while (safety++ < 1000) {
    const r = callGateway("sessions.list", { limit: LIMIT_SESSIONS, offset, agentId });
    if (totalCount === null) totalCount = r.totalCount;
    for (const s of r.sessions ?? []) {
      const k = s.key;
      if (!k || seen.has(k)) continue;
      seen.add(k);
      out.push({ key: k, createdAt: s.createdAt, updatedAt: s.updatedAt });
    }
    if (!(r.hasMore && r.nextOffset !== undefined && r.nextOffset !== offset)) break;
    if (typeof r.nextOffset !== "number") break;
    offset = r.nextOffset;
    if (totalCount !== null && seen.size >= totalCount) break;
  }
  return { sessions: out, totalCount };
}

function fetchHistory(sessionKey, log) {
  const all = [];
  let offset = 0;
  let totalMessages = null;
  let incomplete = false;
  let pages = 0;
  const MAX_PAGES = 500;
  while (pages < MAX_PAGES) {
    let r;
    try {
      r = callGateway("chat.history", { sessionKey, limit: LIMIT_HISTORY, offset });
    } catch (err) {
      if (log) log(sessionKey, `history error: ${err.message}`);
      incomplete = true;
      break;
    }
    if (totalMessages === null) totalMessages = r.totalMessages;
    const batch = r.messages ?? [];
    all.push(...batch);
    pages += 1;
    if (!(r.hasMore && r.nextOffset !== undefined && r.nextOffset !== offset)) break;
    if (typeof r.nextOffset !== "number" || r.nextOffset === offset) break;
    offset = r.nextOffset;
  }
  if (totalMessages !== null && all.length < totalMessages) incomplete = true;
  return { messages: all, totalMessages, returnedMessages: all.length, incomplete };
}

function lastTsMs(messages) {
  // Devuelve el timestamp (ms epoch, o el mayor posible interpretable) del
  // ultimo mensaje del turno. El runtime de chat.history guarda `timestamp`
  // como: ms epoch para user messages (1789xxxxxxxxxxx) y unix-seconds *1000
  // para assistant/toolResult/system. Para universes coherentes dentro de un
  // mismo turno, normalizamos a ms: si un timestamp esta en segundos
  // (<= 1e11), lo multiplicamos por 1000.
  let best = null;
  for (const m of messages) {
    const t = m?.timestamp;
    if (typeof t !== "number" || !Number.isFinite(t) || t <= 0) continue;
    const ms = t < 1e12 ? t * 1000 : t;
    if (best === null || ms > best) best = ms;
  }
  return best;
}

function segmentTurns(messages) {
  const turns = [];
  let current = null;
  let turnIndex = 0;
  for (const m of messages) {
    const role = typeof m?.role === "string" ? m.role : "";
    if (role === "user") {
      if (current) turns.push(current);
      current = { messages: [m], userText: extractUserText(m), index: turnIndex++, orphan: false };
      continue;
    }
    if (!current) {
      current = { messages: [m], userText: null, index: turnIndex++, orphan: true };
      continue;
    }
    current.messages.push(m);
  }
  if (current) turns.push(current);
  for (const t of turns) t.turnTs = lastTsMs(t.messages) ?? null;
  return turns;
}

function extractUserText(m) {
  const c = m?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) {
    let s = "";
    for (const p of c) {
      if (p && typeof p === "object" && typeof p.text === "string") s += p.text;
    }
    return s;
  }
  return "";
}

function detectProvenanceKind(messages) {
  for (const m of messages) {
    const op = m?.__openclaw;
    if (op && typeof op === "object" && op.transport && typeof op.transport === "object") {
      return op.transport.channel || "channel";
    }
  }
  return undefined;
}

function loadProgress() {
  if (!existsSync(ARGS.out)) return { doneSessions: new Set(), agentDone: new Set() };
  const txt = readFileSync(ARGS.out, "utf8");
  const set = new Set();
  for (const line of txt.split(/\r?\n/)) {
    if (!line) continue;
    try {
      const r = JSON.parse(line);
      const k = `${r.backfill_meta?.agent}|${r.sessionKey}|${r.backfill_meta?.turnIndex}`;
      set.add(k);
    } catch { /* skip malformed */ }
  }
  return { doneSessions: set, agentDone: new Set() };
}

function loadSummaryAgent() {
  if (!existsSync(SUMMARY_FILE)) return {};
  try { return JSON.parse(readFileSync(SUMMARY_FILE, "utf8")).summary || {}; } catch { return {}; }
}

function log(msg) { if (!ARGS.quiet) process.stdout.write(msg + "\n"); }

async function main() {
  mkdirSync(dirname(ARGS.out), { recursive: true });
  const progress = ARGS.resume ? loadProgress() : { doneSessions: new Set(), agentDone: new Set() };
  const summary = ARGS.resume ? loadSummaryAgent() : {};

  // en --start o primera corrida truncamos el jsonl
  if (!ARGS.resume) {
    writeFileSync(ARGS.out, "", { encoding: "utf8", flag: "w" });
    writeFileSync(SUMMARY_FILE, "", { encoding: "utf8", flag: "w" });
  }

  function appendLine(line) {
    writeFileSync(ARGS.out, line + "\n", { encoding: "utf8", flag: "a" });
  }
  function appendSummary(agent, payload) {
    summary[agent] = { ...(summary[agent] || {}), ...payload };
    writeFileSync(SUMMARY_FILE, JSON.stringify({
      ranAt: new Date().toISOString(),
      agents: ARGS.agents,
      historyLimit: LIMIT_HISTORY,
      sessionsLimit: LIMIT_SESSIONS,
      outFile: ARGS.out,
      summary,
    }, null, 2) + "\n", "utf8");
  }

  for (const agent of ARGS.agents) {
    if (progress.agentDone.has(agent)) { log(`[${agent}] ya estaba terminado, skip`); continue; }
    log(`[${agent}] listando sesiones...`);
    let sessions;
    try {
      const r = listSessionsForAgent(agent);
      sessions = r.sessions;
      log(`[${agent}] totalCount=${r.totalCount} recuperadas=${sessions.length}`);
    } catch (err) {
      log(`[${agent}] ERROR al listar: ${err.message}`);
      appendSummary(agent, { error: err.message });
      continue;
    }
    let detectedRecords = 0;
    let turns = 0;
    let incompleteSessions = 0;
    let excludedSessions = 0;
    let excludedTurns = 0;
    let processed = 0;
    let excludedDetected = 0;
    const perDay = {};
    for (const s of sessions) {
      processed += 1;
      if (ARGS.excludeRule && new RegExp(ARGS.excludeRule).test(s.key)) {
        excludedSessions += 1;
        log(`[${agent}] ${s.key} skipped by exclude-rule ${ARGS.excludeRule}`);
        continue;
      }
      let hist;
      try {
        hist = fetchHistory(s.key, (k, m) => log(`[${agent}] ${k} ${m}`));
      } catch (err) {
        log(`[${agent}] ${s.key} error: ${err.message}`);
        incompleteSessions += 1;
        continue;
      }
      if (hist.incomplete) incompleteSessions += 1;
      const segs = segmentTurns(hist.messages);
      turns += segs.length;
      const kind = detectProvenanceKind(hist.messages);
      for (const t of segs) {
        const k = `${agent}|${s.key}|${t.index}`;
        if (progress.doneSessions.has(k)) continue;
        // ts del registro = timestamp del ultimo mensaje del turno (ms epoch).
        // Antes tomabamos Date.now() del backfill, lo cual colapsaba 8 dias
        // de historia en una sola ventana de corrida: lector externo del
        // jsonl no podia derivar la tasa por dia del ts. El backfill_meta.runTs
        // guarda el momento de la corrida por separado, asi que la cronologia
        // del turno y la ventana del run no se mezclan.
        const runTs = Date.now();
        // Para turnos al final de sesion sin timestamp del lado user, usamos
        // el ultimo timestamp del mensaje (ms epoch) que aparece en el
        // messages array. El segmenter ya lo calculo.
        const tsRecord = t.turnTs
          ?? (s.updatedAt ? (s.updatedAt < 1e12 ? s.updatedAt * 1000 : s.updatedAt) : runTs);
        const adapted = adaptHistoryMessages(t.messages);
        const record = buildRecord(tsRecord, s.key, agent, kind, adapted);
        const excluded = ARGS.excludeRule && new RegExp(ARGS.excludeRule).test(s.key);
        const line = {
          ...record,
          backfill_meta: {
            agent,
            sessionKey: s.key,
            totalMessages: hist.totalMessages,
            returnedMessages: hist.returnedMessages,
            incomplete: hist.incomplete,
            turnIndex: t.index,
            orphan: !!t.orphan,
            excludedByRule: excluded ? ARGS.excludeRule : null,
            sessionCreatedAt: s.createdAt,
            sessionUpdatedAt: s.updatedAt,
            turnTs: t.turnTs,
            runTs,
            turnDay: new Date(tsRecord).toISOString().slice(0, 10),
            userTextLen: t.userText ? t.userText.length : 0,
            // Cross-review de qwen (2026-09-12): esto escribia los primeros 120 caracteres del PROMPT
            // DEL USUARIO a docs/evidence/backfill-rendiciones.jsonl, que SI se versiona — 201 prompts
            // de 8 agentes quedaron en GitHub. Es la misma fuga que se quito del observador en vivo,
            // cometida en el archivo de evidencia. El largo alcanza para el analisis; el texto no hace
            // falta y es re-derivable corriendo el backfill contra el historico del gateway.
            userTextPreview: null,
            userTextRedactado: true,
          },
        };
        appendLine(JSON.stringify(line));
        progress.doneSessions.add(k);
        if (record.detected && !excluded) {
          detectedRecords += 1;
          // perDay se cuenta por el ts real del turno, no por sessionUpdatedAt
          // ni por runTs. Asi el jsonl soporta la "tasa por dia" del DoD.
          const day = new Date(tsRecord).toISOString().slice(0, 10);
          perDay[day] = (perDay[day] || 0) + 1;
        }
      }
      if (processed % 5 === 0) {
        appendSummary(agent, {
          totalSessions: sessions.length,
          processed,
          totalTurns: turns,
          detectedRecords,
          incompleteSessions,
          perDay,
        });
      }
      if (processed % 10 === 0) log(`[${agent}] ${processed}/${sessions.length} processed, turns=${turns} detected=${detectedRecords}`);
    }
    progress.agentDone.add(agent);
    appendSummary(agent, {
      totalSessions: sessions.length,
      processed,
      totalTurns: turns,
      detectedRecords,
      incompleteSessions,
      excludedSessions,
      excludedTurns,
      perDay,
      excludeRule: ARGS.excludeRule || null,
      finished: true,
    });
    log(`[${agent}] DONE turns=${turns} detected=${detectedRecords} incomplete=${incompleteSessions} excluded=${excludedSessions}`);
  }
  log("\n=== RESUMEN ===");
  for (const a of ARGS.agents) {
    const r = summary[a] || {};
    log(`  ${a}: ` + JSON.stringify({
      total: r.totalSessions || 0,
      turns: r.totalTurns || 0,
      detected: r.detectedRecords || 0,
      incomplete: r.incompleteSessions || 0,
      excluded: r.excludedSessions || 0,
      excludeRule: r.excludeRule || null,
      perDayDays: Object.keys(r.perDay || {}).length,
    }));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});

// jev-auto: Jev sugiere ruteo y cierre de ayudantes en main, y modo de encargo, cierre de turno
// y aviso de bucles de espera en los demas agentes.
// Fail-open: si Jev falla o pasa del timeout, el turno sigue sin sugerencia.
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { appendFile } from "node:fs/promises";
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { dirname, join } from "node:path";

const ROSTER = {
  amazon: "Amazon MX y US, Seller Central, Seller Flex (envios, recolecciones, flex), ordenes, guias, devoluciones, reembolsos, inventario FBA, censo de ordenes no personalizadas",
  pers: "Censo de ordenes Amazon personalizadas nuevas (grabado, nombres, arras personalizadas)",
  meli: "Mercado Libre, MeLi, ML: preguntas de compradores, mensajes, ventas, envios Full/Flex de Mercado Libre y corte",
  mail: "Correo, Gmail, email: leer, buscar, resumir y enviar correos, respuestas de proveedores, revisa mi bandeja, qué hay importante, leer o resumir el correo",
  limpia: "Barrer promos, newsletters y ruido en Gmail: SOLO borrar o archivar promos y newsletters, nunca leer ni resumir el correo",
  odoo: "Odoo: cajas, inventario y operaciones de pedidos NH-PERS/PERS",
  arras: "Investigacion de mercado de arras de boda",
  gonserver: "SSH a goncloud/gonserver: proyectos, estado, servicios, docker y logs del servidor",
  ingenieria: "Diagnostico, errores, bridge, fixes, deploy, OpenClaw, plugins y cambio de estado de maquinas",
  implementer: "Cambios de codigo en repos que terminan en un PR; agregar o cambiar algo en una app o sitio: un botón, una pantalla, un filtro, una función (p. ej. la app de fotos, Orbit)",
  cli: "Por CLI: que lo haga un agente de terminal en la Mini (Claude Code, Kimi, Codex, OpenCode, Qwen, Cursor): 'por CLI', 'con claude', 'con kimi', 'en la terminal'",
  main: "Charla, preguntas sobre el asistente o jev, estado de trabajos, screenshots de la Mac, coordinacion y decisiones",
};

const CLI_AGENTS = ["claude", "codex", "kimi", "opencode", "qwen", "cursor"];
export const rutaNorm = (a) => (CLI_AGENTS.includes(a) ? "cli" : a);

const CLOSE = {
  quedo: "El ayudante completo la tarea y entrego el resultado pedido",
  corregir: "El ayudante entrego algo incompleto, incorrecto o que hay que rehacer",
  bloqueado: "El ayudante no pudo avanzar: falta permiso, credencial, dato o hubo un error",
};

// Encargo de un agente que no es main: como conviene arrancar.
const MODO = {
  directo: "El encargo es claro y tiene lo necesario: hacerlo directo",
  investigar: "Falta contexto del estado actual: leer, buscar o revisar primero y luego actuar",
  aclarar: "El encargo es ambiguo o le falta un dato que solo da quien lo pidio: pedir aclaracion",
};
const TIPO = {
  codigo: "Cambios de codigo, PR, pruebas o despliegue",
  diagnostico: "Diagnostico de fallas, logs, estado de maquinas o servicios",
  operacion: "Operacion de negocio: ordenes, envios, Odoo, marketplaces",
  comunicacion: "Leer, resumir o redactar correos y mensajes",
  investigacion: "Buscar informacion, comparar opciones o investigar un tema",
  consulta: "Pregunta corta que se responde con lo que ya se sabe",
};
// Cierre de turno de un agente que no es main.
const TURNO = {
  quedo: "El agente termino y entrego el resultado pedido",
  seguir: "El agente avanzo pero le queda trabajo que puede hacer por su cuenta",
  bloqueado: "El agente no puede avanzar: falta permiso, credencial, dato, decision de alguien o hubo un error",
};
const MIN_LEN = 15;
const MAX_EJEMPLOS = 15;

// Con claude-cli event.prompt trae envoltorios (contexto interno, metadatos ```json, historial, "System:").
// Se queda solo con el mensaje actual: lo que sigue al ultimo bloque de contexto.
const CTX_PREFIX = /^(Conversation info|Sender \(|Conversation context \(chronological|Chat history since last reply|Recent chat history|Room context:|Replied message|Reply chain|System:|\[OpenClaw room event\]|OpenClaw runtime context|Untrusted context)/i;
export function cleanPrompt(raw) {
  let s = String(raw ?? "").replace(/\r\n/g, "\n");
  s = s.replace(/<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>[\s\S]*?<<<END_OPENCLAW_INTERNAL_CONTEXT>>>/g, "\n\n");
  s = s.replace(/^[^\n]*:[ \t]*\n```[a-z]*\n[\s\S]*?\n```[ \t]*$/gim, "\n\n[[ctx]]\n\n");
  s = s.replace(/```json\n[\s\S]*?\n```/g, "\n\n[[ctx]]\n\n");
  const blocks = s.split(/\n{2,}/).map((b) => b.trim()).filter(Boolean);
  let start = 0;
  blocks.forEach((b, i) => { if (b === "[[ctx]]" || CTX_PREFIX.test(b)) start = i + 1; });
  let out = blocks.slice(start).join("\n\n").replace(/^\[(Mon|Tue|Wed|Thu|Fri|Sat|Sun) [^\]]{6,40}\]\s*/, "").trim();
  return out || String(raw ?? "").trim();
}

// Comandos de shell que se clasifican antes de correr.
const EXEC_TOOLS = new Set(["exec", "bash", "Bash", "shell"]);
// Solo lectura evidente: no se consulta. Cada tramo (separado por | ; && ||) debe empezar con uno de estos,
// sin redirecciones ni sustituciones. Ante la duda, se consulta.
// Fuera de la lista: env (ejecuta el comando que le sigue) y less (puede ejecutar y cuelga esperando teclas).
const RO_CMDS = /^(ls|cat|head|tail|grep|rg|wc|pwd|echo|which|whoami|date|stat|du|df|ps|uname|id|jq|sort|uniq|cut|tr|diff|find|git (status|log|diff|show|branch|remote|rev-parse|blame)|openclaw (cron list|status)|gh (pr|run) (view|list|checks))(\s|$)/;
// Banderas que escriben, ejecutan o leen archivos extra pase lo que pase el comando: nunca es solo lectura.
const WRITE_FLAGS = /^(--output(?:=.*)?|-fprint0?|-fprintf|-fls|-execdir|-exec|-okdir|-ok|-delete|--rawfile(?:=.*)?|--slurpfile(?:=.*)?|--argfile(?:=.*)?|--pre(?:=.*)?|--compress-program(?:=.*)?|--ext-diff|--textconv|--hostname-bin(?:=.*)?)$/;
// Chequeos por comando sobre los argumentos de un tramo ya aceptado por RO_CMDS.
function tramoSeguro(tokens) {
  const [cmd, sub] = tokens;
  if (tokens.some((t) => WRITE_FLAGS.test(t))) return false;
  if (cmd === "tail" && tokens.some((t) => /^--follow(?:=.*)?$/.test(t) || /^-[^-]*[fF]/.test(t))) return false;
  if (cmd === "sort" && tokens.some((t) => t === "-o" || /^-[^-]*o/.test(t) && !t.startsWith("--") || t.startsWith("--output"))) return false;
  if (cmd === "date") {
    if (tokens.some((t) => t === "-s" || t.startsWith("--set") || /^-[a-z]*s/.test(t))) return false;
    for (let i = 1; i < tokens.length; i++) {
      const t = tokens[i];
      if (t.startsWith("-") || t.startsWith("+") || t.startsWith("--")) continue;
      if (["-d", "--date", "-r", "--reference"].includes(tokens[i - 1])) continue;
      return false;
    }
  }
  if (cmd === "uniq") {
    let files = 0;
    for (let i = 1; i < tokens.length; i++) {
      const t = tokens[i];
      if (["-f", "-s", "-w"].includes(t)) { i++; continue; }
      if (t.startsWith("-")) continue;
      files++;
    }
    if (files >= 2) return false;
  }
  if (cmd === "git" && sub === "remote") {
    return tokens.length === 2 || (tokens.length === 3 && tokens[2] === "-v");
  }
  if (cmd === "rg" && tokens.some((t) => t === "-z" || /^-[^-]*z/.test(t) && !t.startsWith("--") || t.startsWith("--search-zip") || t.startsWith("--pre-glob"))) return false;
  if (cmd === "gh" && tokens.some((t) => t === "--watch" || t === "--web" || t.startsWith("--watch=") || t.startsWith("--web="))) return false;
  if (cmd === "git" && sub === "branch") {
    const rest = tokens.slice(2);
    const SAFE = new Set(["-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "-l", "--list", "--show-current", "-q", "--quiet"]);
    if (rest.includes("--list") || rest.includes("-l") || rest.includes("--show-current")) return rest.every((t) => SAFE.has(t) || t.startsWith("--column") || t.startsWith("--format") || !t.startsWith("-"));
    return rest.every((t) => SAFE.has(t));
  }
  return true;
}
export function soloLectura(cmd) {
  const s = String(cmd ?? "").trim();
  if (!s || /[>`]|\$\(|<\(|\n/.test(s)) return false;
  if (/(?<!&)&(?!&)/.test(s)) return false;
  return s.split(/\|\||&&|[|;]/).map((p) => p.trim().replace(/^cd\s+\S+$/, "")).every((p) => {
    if (!p) return true;
    if (!RO_CMDS.test(p)) return false;
    const tokens = p.split(/\s+/).filter(Boolean).map((t) => t.replace(/['"\\]/g, ""));
    return tramoSeguro(tokens);
  });
}
// Tapa argumentos con pinta de secreto: VAR=valor de claves, flags de token/clave, Bearer, cadenas largas tipo token.
// Tambien las formas sin palabra "token/clave": curl -u/--user usuario:clave, -p pegado de
// mysql/mysqldump/psql, sshpass -p, y cabeceras Authorization/Cookie/X-Api-Key via -H/--header.
const HEADER_SENSIBLE = /(token|auth|key|secret|cookie|session|password)/i;
export function sinSecretos(cmd) {
  return String(cmd ?? "")
    .replace(/((?:"|')(?:password|passwd|pass|pwd|token|secret|api_key|apikey|access_token|auth)(?:"|')\s*:\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)/gi, "$1***")
    .replace(/(\bredis-cli\b[^|;&\n]*?)(-a\s+|-a|--pass(?:=|\s+))("[^"]*"|'[^']*'|[^\s"']+)/g, "$1$2***")
    .replace(/\b([A-Z0-9_]*(TOKEN|KEY|SECRET|PASS(WORD)?|AUTH)[A-Z0-9_]*)=\S+/gi, "$1=***")
    .replace(/(--?[\w-]*(token|key|secret|pass(word)?|auth)[\w-]*[=\s]+)\S+/gi, "$1***")
    .replace(/((?:-H|--header)(?:=|\s+))(["'])([^"']*)(\2)/g, (m, p, q, inner) => {
      const i = inner.indexOf(":");
      if (i < 0 || !HEADER_SENSIBLE.test(inner.slice(0, i))) return m;
      return `${p}${q}${inner.slice(0, i).trim()}: ***${q}`;
    })
    .replace(/((?:-H|--header)(?:=|\s+))([A-Za-z0-9_-]+)(\s*:\s*)\S+/g, (m, p, name, colon) =>
      HEADER_SENSIBLE.test(name) ? `${p}${name}${colon}***` : m)
    .replace(/(\bcurl\b[^|;&\n]*?)(--user(?:=|\s+)|-u\s+|-u)("[^"]*"|'[^']*'|[^\s"']*(?:"[^"]*"|'[^']*')[^\s"']*|[^\s"']+)/g, "$1$2***")
    .replace(/(\b(?:mysql|mysqldump|mariadb-dump|psql)\b[^|;&\n]*?)(-p)("[^"]*"|'[^']*'|[^\s"'-][^\s"']*)/g, "$1$2***")
    .replace(/(\b(?:mysql|mysqldump|mariadb-dump|psql)\b[^|;&\n]*?)(-p\s+)("[^"]*"|'[^']*')/g, "$1$2***")
    .replace(/(\bsshpass\b[^|;&\n]*?)(-p\s+|-p)("[^"]*"|'[^']*'|[^\s"']+)/g, "$1$2***")
    .replace(/\b(Bearer|Basic)\s+\S+/gi, "$1 ***")
    .replace(/(\/\/[^\s:/@]+:)[^\s@]+@/g, "$1***@")
    .replace(/\b[A-Za-z0-9_\-+/=]{32,}\b/g, "***");
}

const top = (a) => {
  if (a?.type === "boolean" || typeof a?.probabilityTrue === "number") {
    const p = Number(a.probabilityTrue ?? 0);
    return { label: p >= 0.5 ? "si" : "no", conf: Number(Math.max(p, 1 - p).toFixed(2)), pTrue: Number(p.toFixed(2)) };
  }
  const p = a?.probabilities ?? {};
  return { label: a?.choice, conf: Number((p[a?.choice] ?? 0).toFixed(2)) };
};
const agentOf = (k) => (typeof k === "string" && k.startsWith("agent:") ? k.split(":")[1] : undefined);
const lastAssistantText = (messages) => {
  for (let i = (messages?.length ?? 0) - 1; i >= 0; i--) {
    const m = messages[i];
    if (m?.role !== "assistant") continue;
    const c = m.content;
    const t = typeof c === "string" ? c : Array.isArray(c) ? c.filter((b) => b?.type === "text").map((b) => b.text).join("\n") : "";
    if (t.trim()) return t.trim();
  }
  return "";
};

export default definePluginEntry({
  id: "jev-auto",
  name: "Jev auto",
  description: "Ruteo y cierre de ayudantes con Jev",
  register(api) {
    const cfg = api.pluginConfig ?? {};
    const AGENT = cfg.agentId ?? "main";
    const TIMEOUT = cfg.timeoutMs ?? 2000;
    const LOG = cfg.logPath ?? "/Users/gon/.openclaw/workspace/jev-sombra/decisiones.jsonl";

    // Registro sombra: nunca guarda texto del mensaje; `input` se reemplaza por su hash.
    const log = ({ input, ...rec }) =>
      appendFile(LOG, JSON.stringify({ ts: new Date().toISOString(), ...rec,
        ...(input !== undefined ? { inputHash: "sha256:" + createHash("sha256").update(String(input)).digest("hex") } : {}) }) + "\n").catch((e) =>
        api.logger.warn(`jev-auto: no pude escribir registro: ${e}`),
      );

    // Bitacora de decisiones: una linea por consulta real a Jev. Sin texto de entrada (solo hash) ni claves.
    // Fire-and-forget: si escribir falla se ignora; nunca frena el turno.
    const DECISIONS = cfg.decisionsPath ?? "/Users/gon/.openclaw/jev-auto/decisions.jsonl";
    // Umbral que el codigo aplica de verdad por tipo de consulta; null = la sugerencia se usa siempre.
    const THRESHOLD = { turno: 0.8, herramienta: 0.9, vigilante: 0.8 };
    const bitacora = (kind, state, question, rec) => {
      try {
        const threshold = rec.threshold !== undefined ? rec.threshold : THRESHOLD[kind] ?? null;
        const ans = rec.answer;
        // boolean: la accion se decide con probabilityTrue; choice: con la probabilidad de la opcion elegida.
        // El codigo actua con el valor redondeado de top() (2 decimales): la bitacora compara ese mismo valor.
        const rawScore = typeof ans?.probabilityTrue === "number" ? ans.probabilityTrue : ans?.probabilities?.[ans?.choice];
        const score = typeof rawScore === "number" ? Number(rawScore.toFixed(2)) : rawScore;
        // rec.below=true: el umbral es un tope (p <= threshold), no un piso.
        const passes = typeof score === "number" && (rec.below ? score <= threshold : score >= threshold);
        const line = {
          ts: new Date().toISOString(), id: randomUUID(), kind, ...(rec.q ? { q: rec.q } : {}), agentId: rec.agentId,
          type: ans?.type ?? question?.type ?? null, model: rec.model ?? null,
          options: question?.criteria ? Object.keys(question.criteria) : null,
          answer: ans ? (ans.choice ?? (typeof ans.probabilityTrue === "number" ? (ans.probabilityTrue >= 0.5) : null)) : null,
          probabilities: ans?.probabilities ?? null, probabilityTrue: ans?.probabilityTrue ?? null,
          confidence: ans?.confidence ?? null, threshold, ...(rec.below ? { thresholdDir: "<=" } : {}), ms: rec.ms,
          status: rec.error ? "failure" : threshold == null ? "acted" : passes ? "acted" : "below_threshold",
          error: rec.error ?? null,
          inputHash: "sha256:" + createHash("sha256").update(JSON.stringify(state ?? null)).digest("hex"),
          ...(rec.extra ?? {}),
          outcome: null,
        };
        appendFile(DECISIONS, JSON.stringify(line) + "\n").catch(() => {});
      } catch {}
    };

    // Misma pregunta, misma sesion y mismo turno: se reusa la respuesta en vez de volver a pagarla.
    const asked = new Map();
    const DEDUP_MS = 10 * 60_000;

    async function ask(kind, state, question, ctx) {
      const agentId = ctx.agentId ?? agentOf(ctx.sessionKey);
      const dkey = `${kind}|${ctx.sessionKey}|${ctx.runId ?? ""}|${JSON.stringify(state)}`;
      const now = Date.now();
      for (const [k, v] of asked) if (now - v.at > DEDUP_MS) asked.delete(k);
      const prev = asked.get(dkey);
      if (prev) {
        log({ kind, agentId, sessionKey: ctx.sessionKey, ok: true, skipped: "repetida" });
        return prev.p;
      }
      const p = askOnce(kind, state, question, ctx, agentId);
      asked.set(dkey, { at: now, p });
      return p;
    }

    async function askOnce(kind, state, question, ctx, agentId) {
      const ac = new AbortController();
      const t0 = Date.now();
      let timer;
      try {
        const outcome = await Promise.race([
          api.runtime.decisions.evaluate(
            { state, questions: { q: question } },
            { agentId: AGENT, purpose: `jev-auto.${kind}`, rubricVersion: "1", timeoutMs: TIMEOUT, signal: ac.signal },
          ),
          new Promise((_, rej) => { timer = setTimeout(() => { ac.abort(); rej(new Error("timeout")); }, TIMEOUT); }),
        ]);
        const ms = Date.now() - t0;
        const ans = outcome?.result?.answers?.q;
        if (!ans) {
          const error = outcome?.ok === true || outcome?.status === "ok" ? "sin respuesta" : outcome?.reason ?? outcome?.status ?? outcome?.error ?? "sin respuesta";
          log({ kind, agentId, sessionKey: ctx.sessionKey, ok: false, ms, error });
          bitacora(kind, state, question, { agentId, ms, model: outcome?.result?.model, error: String(error) });
          return null;
        }
        const r = top(ans);
        if (r.label === undefined || r.label === null) {
          log({ kind, agentId, sessionKey: ctx.sessionKey, ok: false, ms, error: "respuesta_invalida" });
          bitacora(kind, state, question, { agentId, ms, model: outcome?.result?.model, answer: ans, error: "respuesta_invalida" });
          return null;
        }
        bitacora(kind, state, question, { agentId, ms, model: outcome?.result?.model, answer: ans });
        log({ kind, agentId, sessionKey: ctx.sessionKey, ok: true, ms, decision: r.label, confidence: r.conf, pTrue: r.pTrue,
          probabilities: ans?.probabilities, model: outcome?.result?.model, input: String(state.message ?? "").slice(0, 300) });
        return r;
      } catch (e) {
        const ms = Date.now() - t0;
        log({ kind, agentId, sessionKey: ctx.sessionKey, ok: false, ms, error: String(e?.message ?? e) });
        bitacora(kind, state, question, { agentId, ms, error: String(e?.message ?? e) });
        return null;
      } finally {
        clearTimeout(timer);
      }
    }

    // Cierre de ayudante: una sola consulta con tres preguntas (estado, afirma algo hecho, trae prueba).
    // Jev recibe solo el texto del reporte recortado. Booleans sin confianza: umbrales propios.
    const AFIRMA_MIN = cfg.afirmaMin ?? 0.7, EVIDENCIA_MAX = cfg.evidenciaMax ?? 0.3;
    const EVIDENCIA_AVISO = "Jev: afirma algo hecho sin prueba visible; verifícalo antes de decírselo a David";
    async function cierreEvidencia(text, ctx) {
      const agentId = ctx.agentId ?? agentOf(ctx.sessionKey);
      const state = { message: text.slice(0, 6000) };
      const questions = {
        estado: { type: "choice", instructions: "Este es el reporte final de un agente ayudante. ¿Quedo, hay que corregir o esta bloqueado?", criteria: CLOSE },
        afirma: { type: "boolean", instructions: "¿El reporte afirma que algo se envió, se desplegó o quedó hecho?" },
        evidencia: { type: "boolean", instructions: "¿El reporte trae evidencia concreta de eso (id de mensaje, ok:true, resultado de prueba, salida de un comando)?" },
      };
      const dkey = `cierre-evidencia|${ctx.sessionKey}|${ctx.runId ?? ""}|${JSON.stringify(state)}`;
      const prev = asked.get(dkey);
      if (prev) return prev.p;
      const p = (async () => {
        const ac = new AbortController();
        const t0 = Date.now();
        let timer;
        const fail = (error, ms, model) => {
          log({ kind: "cierre-evidencia", agentId, sessionKey: ctx.sessionKey, ok: false, ms, error });
          for (const q of Object.keys(questions)) bitacora("cierre-evidencia", state, questions[q], { q, agentId, ms, model, error: String(error) });
          return null;
        };
        try {
          const outcome = await Promise.race([
            api.runtime.decisions.evaluate(
              { state, questions },
              { agentId: AGENT, purpose: "jev-auto.cierre-evidencia", rubricVersion: "1", timeoutMs: TIMEOUT, signal: ac.signal },
            ),
            new Promise((_, rej) => { timer = setTimeout(() => { ac.abort(); rej(new Error("timeout")); }, TIMEOUT); }),
          ]);
          const ms = Date.now() - t0;
          const A = outcome?.result?.answers ?? {};
          const model = outcome?.result?.model;
          if (!outcome?.ok && outcome?.status !== "ok" && !A.estado) return fail(outcome?.reason ?? outcome?.status ?? outcome?.error ?? "sin respuesta", ms, model);
          const valid = (a) => a && (a.choice !== undefined || typeof a.probabilityTrue === "number");
          const meta = { estado: { threshold: null }, afirma: { threshold: AFIRMA_MIN }, evidencia: { threshold: EVIDENCIA_MAX, below: true } };
          for (const q of Object.keys(questions))
            bitacora("cierre-evidencia", state, questions[q], { q, agentId, ms, model, answer: A[q], ...meta[q], error: valid(A[q]) ? undefined : "respuesta_invalida" });
          const estado = valid(A.estado) && A.estado.choice !== undefined ? top(A.estado) : null;
          const pA = A.afirma?.probabilityTrue, pE = A.evidencia?.probabilityTrue;
          const sinPrueba = typeof pA === "number" && typeof pE === "number" && Number(pA.toFixed(2)) >= AFIRMA_MIN && Number(pE.toFixed(2)) <= EVIDENCIA_MAX;
          log({ kind: "cierre-evidencia", agentId, sessionKey: ctx.sessionKey, ok: true, ms, decision: estado?.label, confidence: estado?.conf,
            pAfirma: pA ?? null, pEvidencia: pE ?? null, sinPrueba, model, input: state.message.slice(0, 300) });
          return { estado, sinPrueba, pAfirma: pA, pEvidencia: pE };
        } catch (e) {
          return fail(e?.message ?? e, Date.now() - t0);
        } finally {
          clearTimeout(timer);
        }
      })();
      asked.set(dkey, { at: Date.now(), p });
      return p;
    }

    // Comando riesgoso: antes de exec, una consulta con cinco preguntas. Solo avisa; nunca bloquea ni da permiso.
    // Jev recibe solo el comando (con secretos tapados) y el host. Si falla o tarda, el comando sigue.
    const RIESGO_MIN = cfg.riesgoMin ?? 0.7;
    const RIESGO_Q = {
      tipo: { type: "choice", instructions: "Comando de shell que un agente va a correr. ¿Que efecto tiene?", criteria: {
        "solo-lectura": "Solo lee o muestra informacion; no cambia nada",
        reversible: "Cambia algo, pero se puede deshacer facil",
        destructivo: "Borra, sobrescribe o cambia algo dificil de deshacer",
      } },
      borra: { type: "boolean", instructions: "¿El comando borra archivos o directorios?" },
      git: { type: "boolean", instructions: "¿El comando reescribe historial de git o fuerza un push (push --force, reset --hard, rebase, filter-branch)?" },
      prod: { type: "boolean", instructions: "¿El comando toca produccion (ssh a gonserver/goncloud, docker, systemctl, deploy)?" },
      envia: { type: "boolean", instructions: "¿El comando envia algo fuera de la maquina (correo, mensajes, publicar)?" },
    };
    const MOTIVO = { borra: "borra archivos", git: "reescribe git o fuerza push", prod: "toca produccion", envia: "envia algo fuera" };
    const comandoRiesgo = async (command, host, ctx) => {
      if (soloLectura(command)) return null;
      const agentId = ctx.agentId;
      const clean = sinSecretos(command);
      const state = { command: clean.slice(0, 2000), ...(host ? { host: host.slice(0, 100) } : {}) };
      const extra = { cmdHash: "sha256:" + createHash("sha256").update(command).digest("hex") };
      const ac = new AbortController();
      const t0 = Date.now();
      let timer;
      try {
        const outcome = await Promise.race([
          api.runtime.decisions.evaluate(
            { state, questions: RIESGO_Q },
            { agentId: AGENT, purpose: "jev-auto.comando-riesgo", rubricVersion: "1", timeoutMs: TIMEOUT, signal: ac.signal },
          ),
          new Promise((_, rej) => { timer = setTimeout(() => { ac.abort(); rej(new Error("timeout")); }, TIMEOUT); }),
        ]);
        const ms = Date.now() - t0;
        const A = outcome?.result?.answers ?? {};
        const model = outcome?.result?.model;
        if (!outcome?.ok && outcome?.status !== "ok" && !A.tipo) throw Object.assign(new Error(String(outcome?.reason ?? outcome?.status ?? outcome?.error ?? "sin respuesta")), { ms, model });
        const valid = (a) => a && (a.choice !== undefined || typeof a.probabilityTrue === "number");
        for (const q of Object.keys(RIESGO_Q))
          bitacora("comando-riesgo", state, RIESGO_Q[q], { q, agentId, ms, model, answer: A[q], extra,
            threshold: q === "tipo" ? null : RIESGO_MIN, error: valid(A[q]) ? undefined : "respuesta_invalida" });
        const motivos = [];
        if (A.tipo?.choice === "destructivo") motivos.push("destructivo");
        for (const q of Object.keys(MOTIVO)) if (typeof A[q]?.probabilityTrue === "number" && Number(A[q].probabilityTrue.toFixed(2)) >= RIESGO_MIN) motivos.push(MOTIVO[q]);
        log({ kind: "comando-riesgo", agentId, sessionKey: ctx.sessionKey, ok: true, ms, decision: A.tipo?.choice, motivos, model, cmdHash: extra.cmdHash });
        if (!motivos.length) return null;
        const text = `Jev: comando riesgoso (${motivos.join(", ")}); confirma con David si no estaba autorizado`;
        try {
          const enq = api.session?.workflow?.enqueueNextTurnInjection ?? api.enqueueNextTurnInjection;
          if (typeof enq !== "function") throw new Error("enqueueNextTurnInjection no disponible");
          await enq({ sessionKey: ctx.sessionKey, agentId, text, idempotencyKey: `jev-riesgo:${extra.cmdHash}`, ttlMs: 30 * MIN });
        } catch (e) {
          log({ kind: "comando-riesgo", agentId, sessionKey: ctx.sessionKey, ok: false, error: `inyeccion: ${e?.message ?? e}` });
        }
        return text;
      } catch (e) {
        const ms = e?.ms ?? Date.now() - t0;
        log({ kind: "comando-riesgo", agentId, sessionKey: ctx.sessionKey, ok: false, ms, error: String(e?.message ?? e), cmdHash: extra.cmdHash });
        for (const q of Object.keys(RIESGO_Q)) bitacora("comando-riesgo", state, RIESGO_Q[q], { q, agentId, ms, model: e?.model, extra, threshold: q === "tipo" ? null : RIESGO_MIN, error: String(e?.message ?? e) });
        return null;
      } finally {
        clearTimeout(timer);
      }
    };

    api.on("before_prompt_build", async (event, ctx) => {
      const text = cleanPrompt(event.currentUserMessage ?? event.prompt ?? "");
      log({ kind: "hook", hook: "before_prompt_build", agentId: ctx.agentId, sessionKey: ctx.sessionKey,
        trigger: ctx.trigger, prov: ctx.inputProvenance?.kind, hasCurrent: event.currentUserMessage !== undefined, rawLen: String(event.currentUserMessage ?? event.prompt ?? "").length,
        len: text.length, input: text.slice(0, 200) });
      if (text.length < MIN_LEN) return;
      if (ctx.agentId !== AGENT) {
        if (ctx.trigger === "heartbeat") return;
        const state = { message: text.slice(0, 4000) };
        const [tipo, modo] = await Promise.all([
          ask("encargo.tipo", state, { type: "choice", instructions: "¿Que tipo de trabajo pide este encargo?", criteria: TIPO }, ctx),
          ask("encargo.modo", state, { type: "choice", instructions: `Encargo para el agente ${ctx.agentId}. ¿Como conviene arrancar?`, criteria: MODO }, ctx),
        ]);
        if (!modo) return;
        return { prependContext: `Jev sugiere: ${tipo ? `${tipo.label}, ` : ""}modo ${modo.label} (${modo.conf})` };
      }
      const prov = ctx.inputProvenance;
      const fromHelper = prov?.kind === "inter_session" && /subagent/.test(prov?.sourceTool ?? "");
      if (fromHelper) {
        // El resultado del ayudante ya llego a main: deja de vigilarlo.
        const src = prov?.sourceSessionKey ?? prov?.sourceSession ?? /sourceSession=(\S+)/.exec(text)?.[1];
        if (src) terminar(src, "reportado_a_main");
        const res = await cierreEvidencia(text, ctx);
        if (!res?.estado) return;
        const lines = [`Jev cierre: ${res.estado.label} (${res.estado.conf})`];
        if (res.sinPrueba) lines.push(EVIDENCIA_AVISO);
        return { prependContext: lines.join("\n") };
      }
      const isUser = prov ? prov.kind === "external_user" : ctx.trigger === "user";
      if (!isUser) return;
      const r = await ask("ruteo", { message: text.slice(0, 4000) }, {
        type: "choice",
        instructions: rutaInstructions(),
        criteria: ROSTER,
      }, ctx);
      if (r?.label && ctx.sessionKey) turnos.set(ctx.sessionKey, { texto: text.slice(0, 300), sugerido: r.label, runId: ctx.runId, spawned: [] });
      if (r) return { prependContext: `Jev sugiere: ${r.label} (${r.conf})` };
    });

    // ---- Correcciones: Jev sugirio X y main despacho a Y (o lo resolvio el mismo) ----
    const CORR = join(dirname(LOG), "correcciones.jsonl");
    let correcciones = [];
    try {
      correcciones = readFileSync(CORR, "utf8").split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean).slice(-MAX_EJEMPLOS);
    } catch {}
    const turnos = new Map(); // sessionKey de main -> sugerencia del turno y agentes despachados
    function rutaInstructions() {
      const base = "¿Que agente del equipo debe atender este mensaje de David?";
      const ej = correcciones.slice(-MAX_EJEMPLOS);
      if (!ej.length) return base;
      return `${base}\nCorrecciones anteriores de David (texto → agente correcto):\n${ej.map((c) => `- "${String(c.texto).slice(0, 160)}" → ${rutaNorm(c.correcto)}`).join("\n")}`;
    }
    function registrarCorreccion(c) {
      const rec = { texto: c.texto, sugerido: c.sugerido, correcto: c.correcto, ts: new Date().toISOString() };
      correcciones.push(rec);
      if (correcciones.length > MAX_EJEMPLOS) correcciones = correcciones.slice(-MAX_EJEMPLOS);
      log({ kind: "correccion", agentId: AGENT, sessionKey: c.sessionKey, sugerido: c.sugerido, correcto: c.correcto });
      return appendFile(CORR, JSON.stringify(rec) + "\n").catch(() => {});
    }
    function cerrarTurno(sessionKey, runId) {
      const t = turnos.get(sessionKey);
      if (!t) return;
      if (t.runId && runId && t.runId !== runId) return;
      turnos.delete(sessionKey);
      if (t.spawned.includes(t.sugerido)) return;
      const correcto = t.spawned[0] ?? "main";
      if (correcto !== t.sugerido) return registrarCorreccion({ ...t, correcto, sessionKey });
    }

    api.on("subagent_ended", (event) => {
      log({ kind: "subagent_ended", agentId: agentOf(event.targetSessionKey), sessionKey: event.targetSessionKey, outcome: event.outcome, reason: event.reason, error: event.error });
      if (event.targetSessionKey) terminar(event.targetSessionKey, "subagent_ended");
    });

    // ---- Vigilante: trabajos atorados o abandonados -> aviso a David por Telegram ----
    const DAVID = cfg.notifyTo ?? "6470689715";
    const EVERY = cfg.vigilanteIntervalMs ?? 5 * 60_000;
    const MIN = 60_000;
    const STATE = join(dirname(LOG), "vigilante-estado.json");
    const PROMISE_RE = /\bte (aviso|escribo|digo|confirmo|reporto|mando)\b|\bavis(o|are) (cuando|en cuanto)|\ben cuanto (termine|quede|acabe|tenga)/i;
    const ENG_RE = /^agent:(ingenieria|implementer):/;
    const STATUS = {
      normal: "El trabajo avanza o es razonable que siga en curso; no hace falta avisar",
      atorado: "El trabajo sigue abierto pero sin avance reciente; parece trabado esperando algo o en un error",
      abandonado: "Nadie lo esta atendiendo: un mensaje sin respuesta, una promesa olvidada o un ayudante que dejo de reportar",
    };

    // subs: ayudantes abiertos; main: mensaje de David sin contestar y promesa de aviso; sent: ultimo aviso por trabajo.
    // terminados: sesiones cerradas (no se vuelven a registrar ni avisar).
    // El estado es uno por proceso: register() corre varias veces y cada copia propia pisaba el archivo con datos viejos.
    const vigStore = (globalThis.__jevVigStore ??= {});
    if (!vigStore[STATE]) {
      let v = { subs: {}, bloqueados: {}, terminados: {}, main: { pendingSince: null, pendingText: "", promise: null }, sent: {} };
      try { v = { ...v, ...JSON.parse(readFileSync(STATE, "utf8")) }; } catch {}
      v.subs ??= {}; v.bloqueados ??= {}; v.terminados ??= {}; v.sent ??= {};
      vigStore[STATE] = v;
    }
    const vig = vigStore[STATE];
    // Sincrono y atomico: varias writeFile en paralelo intercalaban bytes y dejaban JSON corrupto.
    const saveVig = () => { try { writeFileSync(STATE + ".tmp", JSON.stringify(vig)); renameSync(STATE + ".tmp", STATE); } catch {} };
    function terminar(key, motivo) {
      const habia = Boolean(vig.subs[key] || vig.bloqueados[key]);
      delete vig.subs[key];
      delete vig.bloqueados[key];
      vig.terminados[key] = Date.now();
      for (const [k, t] of Object.entries(vig.terminados)) if (Date.now() - t > 24 * 60 * MIN) delete vig.terminados[k];
      saveVig();
      if (habia) log({ kind: "vigilante", agentId: AGENT, fase: "limpieza", sessionKey: key, motivo });
    }
    // Pregunta a la API de sesiones si la sesion ya cerro. true = cerrada; false = activa o sin dato.
    function sesionCerrada(key) {
      try {
        const e = api.runtime.agent.session.getSessionEntry({ agentId: key.split(":")[1], sessionKey: key });
        if (!e) return false;
        if (e.endedAt) return true;
        return /done|complete|ended|fail|error|kill|timeout|abort|cancel/i.test(String(e.status ?? ""));
      } catch { return false; }
    }

    const isMain = (k) => typeof k === "string" && k.startsWith(`agent:${AGENT}:`) && !k.includes(":subagent:");
    const fromDavid = (e, c) => [e?.from, e?.senderId, c?.senderId, c?.conversationId].some((v) => String(v ?? "").includes(DAVID));

    api.on("subagent_spawned", (event) => {
      const key = event.childSessionKey;
      if (!key) return;
      delete vig.terminados[key];
      vig.subs[key] = { label: event.label ?? event.agentId ?? key, agentId: event.agentId, startedAt: Date.now() };
      saveVig();
    });

    api.on("message_received", (event, ctx) => {
      if (!fromDavid(event, ctx) && !isMain(ctx?.sessionKey)) return;
      if (!vig.main.pendingSince) vig.main.pendingSince = Date.now();
      vig.main.pendingText = String(event.content ?? "").slice(0, 200);
      saveVig();
    });

    api.on("message_sent", (event, ctx) => {
      if (event.success === false) return;
      if (!isMain(ctx?.sessionKey) && !String(event.to ?? "").includes(DAVID)) return;
      const text = String(event.content ?? "");
      vig.main.pendingSince = null;
      // Una respuesta posterior a la promesa cuenta como cumplida; si trae otra promesa, esa la reemplaza.
      vig.main.promise = PROMISE_RE.test(text) ? { at: Date.now(), text: text.slice(0, 200) } : null;
      saveVig();
    });

    // ---- Cierre de turno de agentes que no son main: quedo / seguir / bloqueado ----
    api.on("agent_end", async (event, ctx) => {
      const sessionKey = ctx?.sessionKey;
      const agentId = ctx?.agentId ?? agentOf(sessionKey);
      if (sessionKey && turnos.has(sessionKey)) await cerrarTurno(sessionKey, ctx?.runId ?? event?.runId);
      if (!agentId || agentId === AGENT || ctx?.trigger === "heartbeat") return;
      const text = lastAssistantText(event?.messages);
      if (text.length < MIN_LEN) return;
      const r = await ask("turno", { message: text.slice(-4000) }, {
        type: "choice",
        instructions: `Ultimo mensaje del agente ${agentId} al cerrar su turno. ¿Quedo, debe seguir o esta bloqueado?`,
        criteria: TURNO,
      }, { ...ctx, agentId, sessionKey, runId: ctx?.runId ?? event?.runId });
      if (!sessionKey) return;
      if (r?.label === "bloqueado" && r.conf >= 0.8 && !vig.terminados[sessionKey]) {
        vig.bloqueados[sessionKey] = { agentId, at: Date.now(), conf: r.conf, text: text.slice(-300) };
        saveVig();
        log({ kind: "turno", agentId, sessionKey, accion: "registrado_para_vigilante" });
      } else if (r && vig.bloqueados[sessionKey]) {
        delete vig.bloqueados[sessionKey];
        saveVig();
      }
    });

    // ---- Herramientas: ¿esta llamada repite la anterior? (bucles de espera). Solo advierte, nunca bloquea ----
    const lastCall = new Map();
    api.on("before_tool_call", async (event, ctx) => {
      const sessionKey = ctx?.sessionKey;
      const agentId = ctx?.agentId ?? agentOf(sessionKey);
      if (!sessionKey) return;
      const t = turnos.get(sessionKey);
      if (t && event.toolName === "sessions_spawn" && (!t.runId || !(ctx?.runId ?? event?.runId) || t.runId === (ctx?.runId ?? event?.runId))) {
        t.spawned.push(rutaNorm(String(event.params?.agentId ?? agentId ?? AGENT)));
      }
      if (EXEC_TOOLS.has(event.toolName) && typeof event.params?.command === "string") {
        const host = event.params.host ?? event.params.node;
        await comandoRiesgo(event.params.command, host ? String(host) : undefined, { ...ctx, agentId, sessionKey, runId: ctx?.runId ?? event?.runId });
      }
      const cur = { tool: event.toolName, params: sinSecretos(JSON.stringify(event.params ?? {})).slice(0, 1500) };
      const prev = lastCall.get(sessionKey);
      lastCall.set(sessionKey, cur);
      if (lastCall.size > 500) lastCall.delete(lastCall.keys().next().value);
      // Filtro barato por codigo: otra herramienta o una llamada corta no se consultan.
      if (!prev || prev.tool !== cur.tool || cur.params.length < MIN_LEN) return;
      const r = await ask("herramienta", { message: `anterior: ${prev.tool} ${prev.params}\nactual: ${cur.tool} ${cur.params}` }, {
        type: "boolean",
        instructions: "¿La llamada actual repite la anterior solo para esperar a que algo cambie (bucle de espera: sleep, volver a mirar el mismo estado, el mismo ls/cat/checks)?",
      }, { ...ctx, agentId, sessionKey, runId: ctx?.runId ?? event?.runId });
      if (!(r?.pTrue >= 0.9)) return;
      const text = `Jev advierte: tu llamada a ${cur.tool} repite la anterior (${r.pTrue}). No esperes en bucle: si lo que esperas no esta listo, cierra con PENDIENTE.`;
      log({ kind: "herramienta", agentId, sessionKey, accion: "advertencia", tool: cur.tool });
      try {
        const enq = api.session?.workflow?.enqueueNextTurnInjection ?? api.enqueueNextTurnInjection;
        if (typeof enq !== "function") throw new Error("enqueueNextTurnInjection no disponible");
        await enq({ sessionKey, agentId, text, idempotencyKey: `jev-bucle:${cur.tool}`, ttlMs: 30 * MIN });
      } catch (e) {
        log({ kind: "herramienta", agentId, sessionKey, ok: false, error: `inyeccion: ${e?.message ?? e}` });
      }
    });

    async function lastProgress(key, fallback) {
      try {
        const { messages } = await api.runtime.subagent.getSessionMessages({ sessionKey: key, limit: 1 });
        const m = messages?.at?.(-1);
        const ts = Date.parse(m?.timestamp ?? m?.createdAt ?? "") || Number(m?.ts ?? m?.timestamp) || 0;
        if (ts) return ts;
      } catch {}
      try {
        const agentId = key.split(":")[1];
        const e = api.runtime.agent.session.getSessionEntry({ agentId, sessionKey: key });
        if (e?.updatedAt) return Number(e.updatedAt);
      } catch {}
      return fallback;
    }

    const human = (ms) => {
      const m = Math.round(ms / MIN);
      return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
    };

    function quietNow(now) {
      const h = Number(new Intl.DateTimeFormat("en-US", { timeZone: "America/Vancouver", hour: "numeric", hourCycle: "h23" }).format(now));
      return h >= 23 || h < 8;
    }

    async function collect(now) {
      const out = [];
      for (const [key, s] of Object.entries(vig.subs)) {
        if (vig.terminados[key] || sesionCerrada(key)) { terminar(key, "sesion_cerrada"); continue; }
        const last = await lastProgress(key, s.startedAt);
        const open = now - s.startedAt, idle = now - last;
        if (idle < 10 * MIN) continue; // con avance reciente no hay nada que revisar
        out.push({ id: key, what: `el ayudante "${s.label}"`, open, idle, eng: ENG_RE.test(key),
          message: `Ayudante ${s.label} (${key}) abierto desde hace ${human(open)}; ultimo avance hace ${human(idle)}.` });
      }
      for (const [key, b] of Object.entries(vig.bloqueados ?? {})) {
        if (now - b.at > 24 * 60 * MIN) { delete vig.bloqueados[key]; continue; }
        if (vig.terminados[key] || sesionCerrada(key)) { terminar(key, "sesion_cerrada"); continue; }
        out.push({ id: `bloqueado:${key}`, what: `el agente ${b.agentId}`, open: now - b.at, idle: now - b.at, eng: ENG_RE.test(key),
          pre: { label: "atorado", conf: b.conf },
          message: `El agente ${b.agentId} (${key}) cerro su turno bloqueado. Ultimo mensaje: "${b.text}"` });
      }
      const p = vig.main.pendingSince;
      if (p && now - p > 10 * MIN) {
        out.push({ id: "main:sin-respuesta", what: "tu ultimo mensaje", open: now - p, idle: now - p,
          message: `David escribio hace ${human(now - p)} y main no le ha contestado. Mensaje: "${vig.main.pendingText}"` });
      }
      const pr = vig.main.promise;
      if (pr && now - pr.at > 30 * MIN) {
        out.push({ id: "main:promesa", what: "un aviso que te prometi", open: now - pr.at, idle: now - pr.at,
          message: `Main prometio avisar hace ${human(now - pr.at)} y no ha vuelto a escribir. Promesa: "${pr.text}"` });
      }
      return out;
    }

    async function notify(text) {
      const send = (await api.runtime.channel.outbound.loadAdapter("telegram"))?.sendText;
      if (!send) throw new Error("adaptador de telegram no disponible");
      await send({ cfg: api.config, to: DAVID, text });
    }

    async function tick(now = Date.now()) {
      let cands;
      try { cands = await collect(now); } catch (e) {
        log({ kind: "vigilante", agentId: AGENT, fase: "revision", ok: false, error: String(e?.message ?? e) });
        return;
      }
      const quiet = quietNow(now) && !Object.keys(vig.subs).some((k) => ENG_RE.test(k));
      log({ kind: "vigilante", agentId: AGENT, fase: "revision", abiertos: Object.keys(vig.subs).length, candidatos: cands.map((c) => c.id), silencio: quiet });
      for (const c of cands) {
        const r = c.pre ?? await ask("vigilante", { message: c.message }, {
          type: "choice",
          instructions: "Revision periodica del equipo de agentes de David. ¿Este trabajo va normal, esta atorado o esta abandonado?",
          criteria: STATUS,
        }, { sessionKey: c.id, agentId: AGENT });
        let accion;
        if (!r) accion = "sin_jev";
        else if (r.label === "normal" || r.conf < 0.8) accion = "nada";
        else if (quiet) accion = "silencio";
        else if (now - (vig.sent[c.id] ?? 0) < 30 * MIN) accion = "repetido";
        else {
          const pasa = c.pre ? "cerro su turno bloqueado (Jev)" : r.label === "abandonado" ? "parece que nadie lo esta atendiendo" : "parece trabado, sin avances";
          const text = `Ojo: ${c.what} lleva ${human(c.open)} abierto y ${pasa} (ultimo movimiento hace ${human(c.idle)}).`;
          try { await notify(text); vig.sent[c.id] = now; saveVig(); accion = "avisado"; }
          catch (e) { accion = `fallo_envio: ${e?.message ?? e}`; }
        }
        log({ kind: "vigilante", agentId: AGENT, fase: "accion", sessionKey: c.id, decision: r?.label, confidence: r?.conf, accion });
      }
    }

    if (globalThis.__jevVigilante?.timer) clearInterval(globalThis.__jevVigilante.timer);
    // Vigilante APAGADO por decisión de David (2026-10-19): nada de vigilantes. Solo corre con
    // plugins.entries.jev-auto.config.vigilante = true.
    const timer = cfg.vigilante === true ? setInterval(() => { tick().catch(() => {}); }, EVERY) : null;
    timer?.unref?.();
    globalThis.__jevVigilante = { timer, tick, state: () => vig };
    globalThis.__jevAuto = { asked, lastCall, turnos, correcciones: () => correcciones, rutaInstructions };
  },
});

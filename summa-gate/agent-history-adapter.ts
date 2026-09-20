/**
 * agent-history-adapter — pasa la forma de `openclaw gateway call
 * chat.history` a la forma que `buildRecord` espera.
 *
 * Por que existe:
 *   El observer de summa-gate (Fase 2 / 2.1, PR #22) corre EN VIVO dentro
 *   del runtime del gateway. El evento `agent_end` le llega con
 *   `event.messages` ya en la forma que el detector recorre
 *   (`toolNamesFromMessages` mira `m.toolName` o `m.name` a nivel
 *   superior del mensaje; `lastAssistantText` mira `m.content` como
 *   string o como array de parts `{type:"text", text}`).
 *
 *   En el historico de `chat.history`:
 *     - los mensajes `toolResult` SI traen `toolName` al nivel superior
 *       (cita: el operador lo probo y verifico que es asi);
 *     - los mensajes `assistant` traen `content` como array de parts
 *       con `{type:"thinking"}`, `{type:"text", text}` y
 *       `{type:"toolCall", name, arguments}`. La parte `toolCall` es
 *       donde el agente PIDE una herramienta: el observer EN VIVO
 *       recibe ese mismo input, porque el runtime no lo re-proyecta.
 *
 *   Por eso este adaptador expande cada mensaje `assistant` con parts
 *   `toolCall` a una serie de mensajes pseudo-`toolName`-bearing que
 *   `toolNamesFromMessages` SI reconoce, y deja el resto intacto. Asi,
 *   `buildRecord` recibe un input con la misma firma semantica que el
 *   agent_end hook le pasaria en produccion: el conteo de herramientas
 *   no-replay-safe y el ultimo texto del assistant se toman del mismo
 *   lado que en el vivo.
 *
 *   La expansion es PERDIDA: cualquier otra informacion que el observer
 *   EN VIVO hubiera visto (p. ej. metadata de `__openclaw.turnBoundary`,
 *   contadores de usage, responseId) no se simula. Para esta tarea
 *   (2.2) eso no afecta nada: el detector solo mira `toolName`, `name`,
 *   `role` y `content[*].text`. Esta auditoria esta escrita en
 *   docs/evidence/tasa-base-rendiciones.md como evidencia del contrato
 *   "el backfill usa el mismo detector que va a correr en produccion".
 */

export type RawHistoryMessage = {
  role?: unknown;
  content?: unknown;
  toolName?: unknown;
  name?: unknown;
  toolCallId?: unknown;
  __openclaw?: unknown;
  timestamp?: unknown;
};

export type ObserverInputMessage = {
  role?: unknown;
  content?: unknown;
  toolName?: unknown;
  name?: unknown;
};

/**
 * Adapta una lista de mensajes crudos de `chat.history` a la forma que
 * `buildRecord` espera. El adaptador:
 *
 *   - mantiene los mensajes `user`, `toolResult`, `system` tal cual
 *     (sus tools viven a nivel superior ya);
 *   - para `assistant`, extrae cada part `toolCall` y la emite como un
 *     mensaje proxy con `{role:"assistant", toolName:<p.name>}` para
 *     que `toolNamesFromMessages` la cuente. El mensaje assistant
 *     original se conserva ademas, para que `lastAssistantText` siga
 *     encontrando el texto final (incluyendo su firma de `text` part).
 *
 * El orden del array importa: el observer cuenta tools en orden de
 * aparicion y eso solo afecta a `nonReplaySafeCount` (un entero); no
 * al veredicto, que es binario y solo mira si `nonReplaySafeCount === 0`.
 */
export function adaptHistoryMessages(
  raw: RawHistoryMessage[],
): ObserverInputMessage[] {
  const out: ObserverInputMessage[] = [];
  for (const m of raw) {
    if (!m || typeof m !== "object") continue;
    const role = typeof m.role === "string" ? m.role : "";
    out.push({ role: m.role, content: m.content, toolName: m.toolName, name: m.name });
    if (role !== "assistant") continue;
    const content = m.content;
    if (!Array.isArray(content)) continue;
    for (const part of content) {
      if (!part || typeof part !== "object") continue;
      const t = (part as { type?: unknown }).type;
      if (t !== "toolCall" && t !== "tool_call") continue;
      const nm = (part as { name?: unknown }).name;
      if (typeof nm !== "string" || nm.length === 0) continue;
      // emitimos un proxy: el observer leera `m.toolName` o `m.name`, asi
      // que basta con setear uno de los dos campos top-level.
      out.push({ role: "assistant", toolName: nm });
    }
  }
  return out;
}

/**
 * Funciones puras de summa-gate (exportadas para tests sin cargar el plugin).
 */

import { isAbsolute, resolve, sep } from "node:path";

export type Role = "implementer" | "verifier" | "reviewer" | "adversary";

// FRONTERA POR LOOKAHEAD, NO POR ENUM DE TERMINADORES. Enumerar los caracteres que "cortan"
// fallo tres veces seguidas en esta misma rama: r2 agrego ? y #, r3 (hallazgo 1) agrego ; & |,
// y el turno de cierre (2026-09-16) encontro que seguian faltando >, >>, < y ) — el terminador
// PEGADO (`.../pulls/45/merge>/tmp/resp.json`, `...merge>>/tmp/x`, `(gh api .../merge)`) esquivaba
// el guard y el merge SE EJECUTABA. `merge>/tmp/resp.json` es bash ordinario, no una tecnica de
// evasion: es lo que escribe cualquiera que quiera guardar la respuesta de la API en un archivo.
// La condicion correcta no es "sigue uno de estos caracteres" sino "la palabra NO continua", que
// es justo lo que expresa (?![A-Za-z0-9_]). Con eso cierran de una sola vez >, >>, <, ), }, , y
// cualquier metacaracter futuro, y el enum deja de ser una lista que hay que parchear.
//
// Alcance declarado de la frontera (decision del lead, re-review r6): el `-` SI cuenta como
// continuacion de palabra — (?![A-Za-z0-9_-]) —, asi que un NOMBRE DE RAMA que lleve el segmento
// (la rama de este mismo PR: `fase6/` + la palabra + `-guard`) ya NO matchea. Antes si, y como la
// rama de `gh api` no exige localidad eso bloqueaba lecturas de CI por rama y el borrado de ref de
// la limpieza del cierre —el comando textual esta en la skill git-commit-push, no se repite aca—
// mientras la rama hermana de reversa pasaba: dos ramas hermanas con comportamiento distinto.
// A cambio los sufijos reales quedan ENUMERADOS: merges? | auto-merge | merge-async | merge-upstream.
// /merge-upstream (sync de fork — no aterriza este PR en main) conserva el bloqueo fail-closed
// declarado en el turno de cierre, ahora por enumeracion y no por la frontera: falso positivo
// aceptado a proposito, el costo de este lado es pedirle al operador un comando poco frecuente y
// el del otro lado es un merge sin orden.
// LIMITE LEXICO, declarado: una ruta con un sufijo /merge-<otro> que GitHub agregue en el futuro
// queda FUERA del alcance hasta que se la agregue a las dos alternaciones. Es el precio de dejar
// de morder nombres de rama, y se paga del lado que no ejecuta merges hoy.
// El pasteo de terminadores sigue cubierto: >, >>, <, ), }, `,` y cualquier metacaracter no son
// ni palabra ni guion, asi que la frontera los corta igual que antes (tienen prueba propia).
// /update-branch no lleva ruta de merge y sigue pasando (tiene control negativo en la bateria).
// Segundo falso positivo, costo directo de este fix y tambien declarado: la rama de `gh api` no
// exige localidad — cualquier token /merge… del texto cuenta, sea el endpoint o el destino de un
// redirect (`gh api …/pulls/45 > /tmp/merge.txt` bloquea, con espacio o pegado). Antes ese destino
// se salvaba solo porque `.` no estaba en el enum. Es la misma ambiguedad lexica que hacia posible
// el bypass (no se distingue endpoint de destino), resuelta del lado seguro: se pide un destino que
// no lleve /merge en la ruta. Tiene prueba propia. La rama de host SI exige localidad, porque
// [^\s'"]* no cruza el espacio: ahi solo cuenta la URL contigua.
// FRONTERA IZQUIERDA (r7, hallazgo del reviewer del sello): la regla exigia que `gh`, `pr` y el
// verbo fueran CONTIGUOS, y cobra acepta los flags ANTES del subcomando — los remueve al resolver
// la hoja, verificado contra el binario real solo con --help (`gh pr -R o/r view --help` y
// `gh pr --repo=o/r view --help` resuelven view). Con un flag interpuesto, la UNICA regla
// incondicional del guard —la que impide que main/reviewer/adversary aterricen un PR sin la orden
// del dueño— quedaba abierta para TODOS los agentes, allowlist incluida. No es una tecnica de
// evasion: `-R`/`--repo` es el estilo que el propio repo usa en sus comandos de lectura, asi que
// la forma esquivada era mas probable que la contigua. Tampoco es un bypass INHERENTE (el texto
// del comando lleva la orden completa y visible: es corregible lexicamente, y se corrige aca).
// Fix: entre `gh` y `pr`, y entre `pr` y el verbo, se toleran cero o mas tokens de flag.
// GH_FLAG_TOKEN cubre las CUATRO formas del flag CON VALOR que acepta pflag/cobra: separada por
// espacio (`-R o/r`, `--repo o/r`), pegada con `=` (`-R=o/r`, `--repo=o/r`) y —desde r8— el
// shorthand con el valor PEGADO SIN `=` (`-Ro/r`), la forma de una sola pieza. r7 enumero tres y
// la clase tenia cuatro: la pegada era la UNICA que seguia pasando, asi que la bateria verde no
// discriminaba el hueco y la regla incondicional seguia abierta para TODOS los agentes con un
// caracter menos (hallazgo 1 del reviewer del sello, verificado contra el binario solo con --help:
// `gh pr -Rowner/repo view --help` resuelve view en gh 2.98.0).
// POR QUE QUEDA CUBIERTA LA CUARTA FORMA: el nombre del flag ya no se lee con un rango de
// caracteres de nombre (`[A-Za-z0-9-]*`), que cortaba en la `o` de `-Ro/r` —el `/` no continuaba—
// y dejaba al token exigiendo un `\s+` que nunca llegaba, colapsando la alternativa a cero flags.
// Ahora el token absorbe el resto de la PIEZA con `\S*`, sea `=o/r`, `o/r` o nada: las cuatro
// formas entran por el mismo camino y la de `=` deja de necesitar rama propia.
// POR QUE NINGUN SUBCOMANDO CONOCIDO QUEDA COMIBLE: `\S*` no cruza el espacio, asi que la parte
// pegada no puede tragarse una pieza separada — `pr` y el verbo real (view/checks/list/…) quedan
// intactos en su posicion, y por eso `gh pr -Ro/r view 45` sigue PASANDO (prueba propia). La unica
// via por la que un token se come la pieza siguiente sigue siendo el valor separado, y esa via
// conserva su exclusion:
// El valor separado NO puede ser `pr`, el verbo, ni un subcomando conocido: sin esa exclusion
// `--repo o/r` podria tragarse el subcomando REAL (`gh pr -R o/r view 45` -> el valor se come
// `view`) y correr la frontera hasta un `merge` que fuera dato, convirtiendo una consulta en un
// bloqueo. Con la exclusion, view/checks/ready/list siguen sin matchear como verbo (prueba propia).
// El valor tampoco puede empezar con `-`, asi que un flag nunca se traga otro flag: por eso el
// bucle no es ambiguo (cada iteracion consume 1 o 2 tokens y la alternativa muere en el `\s+`
// siguiente) y no hay backtracking exponencial. El `\S*` de r8 tampoco lo vuelve ambiguo: solo
// retrocede DENTRO de la pieza y el `\s+` que sigue unicamente casa al final de la pieza, asi que
// el corte de cada token sigue siendo unico (medido en r8 sobre este mismo shape: 0.16 ms con
// 2000 tokens separados, 0.08 ms con 2000 tokens pegados y 0.06 ms con una sola pieza de 20k
// caracteres — el crecimiento es lineal, no explota).
// La frontera DERECHA sigue siendo el lookahead de arriba, intacta.
// r9 (hallazgo del reviewer del sello sobre 5c49b27): la frontera izquierda estaba enseñada SOLO
// a GH_PR_MERGE_RE. GH_API_RE seguia exigiendo `gh` y `api` CONTIGUOS, y es el que gatilla las DOS
// reglas de merge con allowlist (ruta REST /merge… y mutacion GraphQL cuando el cliente es
// `gh api`), asi que main/reviewer/adversary y el agentId ausente aterrizaban el PR con un flag
// interpuesto. Misma clase ya declarada cerrada, una rama mas alla: se cierra igual, con el mismo
// shape. Verificado contra el binario solo con lecturas: `gh -X GET api rate_limit` devuelve 5000
// y `gh --method POST api rate_limit` devuelve un 404 DEL SERVIDOR, o sea el metodo puesto antes
// del subcomando viaja en la request (ese camino con PUT es el merge).
// `api` y `graphql` entran en la lista de exclusion del valor separado por las dos direcciones que
// esa lista cuida: que un flag booleano no se trague la pieza `api` (`gh --verbose api …` tiene que
// seguir matcheando) y que un valor de flag no se coma un subcomando real.
// r9, pieza quinta: no es una quinta forma de attach, es la SEPARADA con el valor entrecomillado
// que lleva un espacio adentro (`-H 'Accept: application/vnd.github+json'`). `\S*` no cruza el
// espacio, asi que esa pieza cortaba el bucle de tokens y dejaba pasar el merge igual; cobra la
// ejecuta (stripFlags se salta el flag y su valor para resolver la hoja). Se cierra aca en vez de
// declarar cubierta una frontera que no lo estaria. Las tres alternativas del valor son DISJUNTAS
// por el primer caracter (`'`, `"`, resto), asi que cada token sigue teniendo UN solo corte
// posible: sin esa disyuncion el bucle tendria dos caminos del mismo largo por token y el
// backtracking creceria exponencial con el numero de flags.
const GH_PR_SUBCOMANDOS =
  "pr|merge|view|checks|checkout|ready|list|status|diff|edit|comment|close|reopen|create|lock|unlock|review|update-branch|api|graphql";
const GH_FLAG_VALOR = `(?:'[^']*'|"[^"]*"|[^-'"\\s]\\S*)`;
const GH_FLAG_TOKEN = `-{1,2}[A-Za-z]\\S*(?:\\s+(?!(?:${GH_PR_SUBCOMANDOS})(?![A-Za-z0-9-]))${GH_FLAG_VALOR})?`;
const GH_PR_MERGE_RE = new RegExp(
  `(?:^|[^A-Za-z0-9])gh\\s+(?:${GH_FLAG_TOKEN}\\s+)*pr\\s+(?:${GH_FLAG_TOKEN}\\s+)*merge(?![A-Za-z0-9_])`,
);
const GH_API_RE = new RegExp(
  `(?:^|[^A-Za-z0-9])gh\\s+(?:${GH_FLAG_TOKEN}\\s+)*api(?![A-Za-z0-9_])`,
);
// r3 (hallazgo 4): la ruta /auto-merge entra en la misma clase (el `/` va antes de `auto`, asi
// que necesita alternativa propia). turno de cola (re-review 2026-09-16, hallazgo 1):
// /merge-async (PUT, PRs apilados) entra en la misma clase, en gh api y en la ruta de host
// (curl a api.github.com). re-review r6: con el guion como continuacion de palabra la alternacion
// dejo de ser decorativa — cada sufijo con guion bloquea SOLO si esta enumerado aca, y el limite
// de esa lista esta declarado arriba.
const GH_API_MERGE_PATH_RE = /\/(?:merges?|auto-merge|merge-async|merge-upstream)(?![A-Za-z0-9_-])/;
const GIT_PUSH_RE = /(?:^|[^A-Za-z0-9])git\s+push\b/;
const GIT_PUSH_PROTECTED_RE =
  /push\s+.*(\sorigin\s+[+:]?(master|main)|\sHEAD:(master|main)|refs\/heads\/(master|main)|[A-Za-z0-9._/-]+:(master|main)|\s[+:]?(master|main))(\s|$)/;

/**
 * Allowlist de agentes que pueden ejecutar la orden de merge del dueño (Fase 6, 6.5c, decisión D1:
 * la orden la ejecuta implementer o ingenieria; main no toca el merge).
 */
const MERGE_AGENT_ALLOWLIST = new Set(["implementer", "ingenieria"]);

// 6.5c: mutación GraphQL de merge (gh api graphql -f query=mutation … mergePullRequest(…) y llamadas a
// api.github.com con path de merge. // la rama REST via gh api comparte la allowlist con el path de host: mismo endpoint, un solo trato sin importar el cliente (cross-review r1);
// el host explícito cubre curl/plain-URL.
// turno de cierre (2026-09-16, hallazgo MEDIA): la mutación también se consulta por HOST
// (api.github.com/graphql), no solo cuando matchea el cliente `gh api`. Antes, un curl directo
// al endpoint graphql pasaba entero, y la excusa "curl con token requeriría secret-read" no
// aplicaba: `gh auth token` entrega el token desde un exec común. Asimetría cerrada — curl
// queda cubierto en las DOS ramas: REST por path de host, GraphQL por host + nombre de mutación.
//
// ALCANCE DECLARADO. El guard es léxico sobre exec, así que quedan dos bypass INHERENTES
// (límite del diseño, no defectos pendientes):
//   (1) indirección de shell — variables, aliases, eval, base64: el texto del comando no lleva
//       la orden de merge, así que ninguna regex léxica la ve;
//   (2) query=@archivo — la mutación vive en el archivo, no en el comando (tiene prueba propia).
// Ya NO es bypass, desde este turno: curl con token contra /graphql (cubierto por host).
// Ya NO es bypass, desde r7 (rama `pr`), cerrado del todo en r8 (la cuarta forma) y extendido en
// r9 a la rama `api`: el FLAG INTERPUESTO antes del subcomando, en sus CUATRO formas — valor
// separado (`-R o/r`, `--repo o/r`), valor pegado con `=` (`-R=o/r`, `--repo=o/r`) y valor pegado
// SIN `=` (`-Ro/r`, la forma de una sola pieza) — mas la forma separada con el valor
// ENTRECOMILLADO que lleva un espacio adentro (`-H 'Accept: application/vnd.github+json'`), que no
// es una quinta forma de attach sino la separada con una pieza que `\S*` no podia cruzar.
// Mientras quedó una forma o una RAMA abierta esta declaración fue falsa tres veces seguidas: r7
// enumeró tres formas con la cuarta pasando; r8 cerró la cuarta pero solo en `gh pr <verbo>` y
// escribió "la frontera izquierda queda cubierta" mientras `gh api` —el que gatilla las DOS reglas
// de merge con allowlist— seguía exigiendo contigüidad; el reviewer del sello encontró las dos.
// Ninguna de esas formas entra en las dos clases inherentes —el texto del comando lleva la orden
// completa y visible, o sea es corregible léxicamente— así que se cerraron en el código en vez de
// re-escribir el conteo. AHORA SÍ son DOS, y la frontera izquierda queda cubierta en las DOS ramas
// del cliente (`gh pr <verbo>` y `gh api`, REST y GraphQL) con prueba propia: las cuatro formas más
// la entrecomillada, para main, reviewer y agentId ausente, con la allowlist (implementer/
// ingenieria) verificada como PASA en la rama de allowlist para que cerrar la frontera no la
// convierta en bloqueo, y con las lecturas (`api rate_limit` con `-X GET`/`--method GET`, `api`
// leyendo un PR con `-H`/`--header`, `pr view`/`pr checks` también con el valor pegado) como
// controles negativos.
// Tampoco lo es el encadenado sin espacio (r3 hallazgo 1) ni el terminador pegado (turno de
// cierre): la frontera por lookahead de arriba los corta a los dos, así que la promesa del
// mensaje "(también encadenado con &&/;)" es verdadera.
// La copia de esta declaración en la skill saikit-cierre-pr se alinea en este mismo SHA (r9: las
// dos ramas del cliente), como se alineó en a679c5a y en r8: el texto y la regex tienen que decir
// lo mismo.
// cross-review r2 (grok): ademas de mergePullRequest se bloquean las mutaciones hermanas:
// mergeBranch (equivale a POST /merges) y enablePullRequestAutoMerge (abre el mismo merge sin orden).
// r3 (hallazgo 3): word-boundary puro, sin exigir `(` — un comentario GraphQL pegado al
// nombre (`mergePullRequest#c`) cortaba el matching. Falso positivo aceptado y declarado:
// mencionar el nombre (p.ej. en un mensaje sobre la mutacion) ya blockea fuera de allowlist.
const GRAPHQL_MERGE_RE = /\b(?:mergePullRequest|mergeBranch|enablePullRequestAutoMerge)\b/;
// La misma alternacion enumerada y la misma frontera que la rama de `gh api` (re-review r6): un
// solo trato por endpoint, sin importar el cliente. Si se agrega un sufijo, va en las DOS.
const GITHUB_HOST_MERGE_RE = /api\.github\.com\/[^\s'"]*\/(?:merges?|auto-merge|merge-async|merge-upstream)(?![A-Za-z0-9_-])/;
// turno de cierre (2026-09-16, hallazgo MEDIA): el endpoint GraphQL por host, para que la
// mutación de merge se evalúe también cuando el cliente es curl y no `gh api`.
const GITHUB_HOST_GRAPHQL_RE = /api\.github\.com\/graphql(?![A-Za-z0-9_])/;

// r3 (hallazgo 2): nucleo del veredicto; mergeGuardVerdict lo corre sobre el comando
// original y sobre una copia sin comillas (wrapper mas abajo).
function mergeGuardCoreVerdict(command: string, allowlisted: boolean): string | undefined {
  if (GH_PR_MERGE_RE.test(command)) {
    return "Merge bloqueado por summa-gate: `gh pr merge` está prohibido desde el agente (también encadenado con &&/;). El merge lo hace el operador o el flujo autorizado del repo.";
  }
  const restMerge = GH_API_RE.test(command) && GH_API_MERGE_PATH_RE.test(command);
  // El cliente de la mutación puede ser `gh api` o un curl al host: el endpoint es el mismo,
  // así que el trato es el mismo (turno de cierre, hallazgo MEDIA).
  const graphqlMerge =
    (GH_API_RE.test(command) || GITHUB_HOST_GRAPHQL_RE.test(command)) &&
    GRAPHQL_MERGE_RE.test(command);
  const hostMerge = GITHUB_HOST_MERGE_RE.test(command);
  // El bypass de la allowlist aplica SOLO a la regla de merge que coincidio: el resto de
  // las reglas se sigue evaluando (comando encadenado de agente allowlisted: la mutacion
  // pasa, el push a rama protegida sigue bloqueado - cross-review r1, no retornar temprano).
  if ((graphqlMerge || hostMerge) && !allowlisted) {
    return (
      "Merge bloqueado por summa-gate: la mutación GraphQL de merge y las rutas de merge de api.github.com están prohibidas desde el agente salvo para implementer/ingenieria con la orden del dueño citada en el brief (6.5b)."
    );
  }
  if (restMerge && !allowlisted) {
    return "Merge bloqueado por summa-gate: `gh api …/merge` está prohibido desde el agente. El merge lo hace el operador o el flujo autorizado del repo.";
  }
  if (GIT_PUSH_RE.test(command) && GIT_PUSH_PROTECTED_RE.test(command)) {
    return "Push bloqueado por summa-gate: `git push` a master/main está prohibido desde el agente (incluye origin master, +master, HEAD:main, refs/heads/main y delete-ref :main).";
  }
  return undefined;
}

export function mergeGuardVerdict(command: string, agentId?: string): string | undefined {
  // Normalizacion del agentId (trim + lowercase), como en el resto del modulo:
  // "Implementer" o " implementer " se comportan igual que "implementer" (cross-review r1).
  const allowlisted =
    agentId !== undefined && MERGE_AGENT_ALLOWLIST.has(agentId.trim().toLowerCase());
  // r3 (hallazgo 2): token entrecomillado — la comilla en la posicion del token
  // (`'gh' api ...`) cortaba la frontera del cliente. El matching corre sobre el comando
  // original Y sobre una copia sin comillas simples/dobles; fail-closed: los falsos
  // positivos bloquean, los falsos negativos son lo prohibido. No alcanza los DOS bypass
  // INHERENTES del guard lexico, declarados arriba y en saikit-cierre-pr: la indireccion
  // de shell (variables, aliases, eval, base64) y query=@archivo. curl con token contra
  // /graphql ya NO es bypass: quedo cubierto por host (ver la declaracion larga de arriba).
  return (
    mergeGuardCoreVerdict(command, allowlisted) ??
    mergeGuardCoreVerdict(command.replace(/['"\\`]/g, ""), allowlisted)
  );
}

// Canal entre agentes (2026-09-11): la respuesta de un sessions_send regresa por un camino que muere en
// silencio cuando el turno que despacho ya cerro, y ninguna espera lo arregla (30 s explicitos = el
// default; el agente puede tardar mas que cualquier espera). Por eso las esperas no abren el candado.
// Pasan: envios a sesiones de main, avisos marcados que no esperan respuesta y encargos que llevan la
// etiqueta exacta de reporte de vuelta con la sessionKey de quien despacha (verificado en vivo el 09-11).
// La etiqueta es literal a proposito: buscar "sessions_send" y la sessionKey sueltas dejaba pasar un
// texto que solo las mencionaba, incluso negando el reporte (revision cruzada grok, 09-11).
export const SEND_NOTICE_MARKER = "[AVISO SIN RESPUESTA]";
export const SEND_RETURN_TAG = "[REPORTE DE VUELTA:";

export type SessionsSendParams = {
  agentId?: unknown;
  sessionKey?: unknown;
  session_key?: unknown;
  label?: unknown;
  timeoutSeconds?: unknown;
  message?: unknown;
};

function normalized(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim().toLowerCase() : undefined;
}

/** Destino como lo resuelve la herramienta: sessionKey (o session_key), luego label, luego agentId. */
function sendTargetsMain(params: SessionsSendParams): boolean {
  const key = normalized(params.sessionKey) ?? normalized(params.session_key);
  if (key) return key === "main" || key.startsWith("agent:main:");
  if (normalized(params.label)) return false;
  return normalized(params.agentId) === "main";
}

export function sessionsSendGuardVerdict(
  requesterAgentId: string | undefined,
  params: SessionsSendParams,
  requesterSessionKey?: string,
): string | undefined {
  if (normalized(requesterAgentId) !== "main") return undefined;
  if (sendTargetsMain(params)) return undefined;
  const message = typeof params.message === "string" ? params.message : "";
  if (message.trimStart().toUpperCase().startsWith(SEND_NOTICE_MARKER)) return undefined;
  if (requesterSessionKey) {
    const expectedTag = `${SEND_RETURN_TAG} ${requesterSessionKey}]`.toUpperCase();
    if (message.toUpperCase().includes(expectedTag)) return undefined;
  }
  const returnKey = requesterSessionKey ?? "agent:main:main";
  return (
    "Envio bloqueado por summa-gate: la respuesta de un sessions_send de Claw a otro agente se pierde si el agente tarda " +
    "mas que la espera, y ninguna espera lo evita (2026-09-11: 41 respuestas perdidas). Usa una de estas: " +
    "(1) tarea o pregunta: sessions_spawn agentId=<agente> mode=run con todo el contexto en task; el resultado te llega solo como turno nuevo. " +
    `(2) seguir un trabajo en la sesion del agente: empieza el mensaje con la etiqueta exacta "${SEND_RETURN_TAG} ${returnKey}]" y pidele ahi que te reporte con sessions_send al terminar (timeoutSeconds 0); mencionar sessions_send en el texto no abre nada. ` +
    `(3) aviso que no necesita respuesta: empieza el mensaje con ${SEND_NOTICE_MARKER}.`
  );
}

const DOC_RE = /\.(md|mdx|markdown|rst|txt|adoc|org)$/i;
const LOCKFILE_RE =
  /(^|[/\\])(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|cargo\.lock|poetry\.lock|composer\.lock|gemfile\.lock|go\.sum|pubspec\.lock)$/i;

export function isDocOrLock(path: string): boolean {
  return DOC_RE.test(path) || LOCKFILE_RE.test(path);
}

export function labelRegex(label: string): RegExp {
  return new RegExp(`(^|\\n)[ \\t]*${label}:`);
}

const ADVERSARY_ZONE_RE = /(?:^|[/\\])\.saikit[/\\](findings|scratch)(?:[/\\]|$)/;
const ABSOLUTE_PATH_RE = /^(?:[A-Za-z]:[\\/]|[\\/]|~)/;
const REDIRECT_RE = /(?:^|[\s;|&])(?:\d?>>?|\btee)\s*("([^"]*)"|'([^']*)'|(\S+))/g;
const REDIRECT_ALLOWLIST = new Set(["/dev/null", "/dev/stdout", "/dev/stderr", "NUL"]);

export function adversaryPathAllowed(target: string, workspaceDir?: string): boolean {
  if (ADVERSARY_ZONE_RE.test(target)) return true;
  if (workspaceDir) {
    try {
      const abs = isAbsolute(target) ? resolve(target) : resolve(workspaceDir, target);
      const root = resolve(workspaceDir);
      if (abs === root || abs.startsWith(root + sep)) return true;
    } catch {
      // fallthrough: fail-open más abajo
    }
    return false;
  }
  return !ABSOLUTE_PATH_RE.test(target);
}

export function redirectTargets(command: string): string[] {
  const targets: string[] = [];
  for (const match of command.matchAll(REDIRECT_RE)) {
    const target = match[2] ?? match[3] ?? match[4];
    if (target && !REDIRECT_ALLOWLIST.has(target)) targets.push(target);
  }
  return targets;
}

/**
 * Map label/agent text to a pipeline role.
 * implementer/engineer/fix must be checked before verif|test|qa so labels like
 * "implementer: fix failing tests" classify as implementer, not verifier.
 * Word boundaries keep substrings like "prefix" / "fixture" from matching "fix".
 */
export function canonicalRole(text: string): Role | undefined {
  const t = text.toLowerCase();
  if (/\badversar(?:y|ial)?\b|\bcritic\b/.test(t)) return "adversary";
  if (/\breview(?:er|s|ing)?\b|\baudit(?:or|s|ing)?\b/.test(t)) return "reviewer";
  if (
    /\bimplement(?:er|ers|ation|ing)?\b|\bengineer(?:s|ing)?\b|\bcoder(?:s)?\b|\bfix(?:es|ing|ed)?\b/.test(
      t,
    )
  ) {
    return "implementer";
  }
  if (/\bverif(?:y|ies|ied|ying|ier|ication)?\b|\btests?\b|\bqa\b/.test(t)) {
    return "verifier";
  }
  return undefined;
}

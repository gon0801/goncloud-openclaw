#!/bin/bash
# 13.3 (Fase 13): la skill verify deja de mentir — candado de comportamiento.
#
# El feature map (docs/agent-skills/verify/features/) cita "la cadena exacta
# que prueba que el guard disparó", pero hasta esta tarea nada comparaba esas
# citas contra el plugin: cinco frases eran falsas (dos citas parciales, una
# cita con palabras que el guard no dice, y dos cadenas reales que el mapa ni
# listaba: la mutación GraphQL de merge y la tercera cadena de adversary por
# cd + destino relativo). Un mapa que se edita a mano y nadie verifica es la
# misma trampa que un conteo que nadie recalcula.
#
# Este test afirma tres cosas:
#  (a) COMPORTAMIENTO: registra el plugin real contra el host falso con la
#      forma EXACTA de fakeBaseApi (summa-gate/role.test.ts:24-48: logger, on,
#      registerAgentToolResultMiddleware, pluginConfig: {} al tope y
#      runContext { setRunContext, getRunContext, clearRunContext } anidado
#      bajo `runContext`, NO bajo `runtime` — anidado bajo runtime el registro
#      "funciona" y el hook que uno quería simplemente no queda en la lista),
#      dispara una batería con un caso por cadena que cada guard puede emitir,
#      y compara contra el blockReason REAL truncando ambos lados en el primer
#      placeholder (<…> o "Destino:"). La comparación es por IGUALDAD del
#      tramo determinista, en las dos direcciones: cada cadena real tiene que
#      estar citada exactamente (una cita parcial como "match the opening"
#      miente por omisión), y cada cita tiene que corresponder a una cadena
#      real (una cita inventada miente por comisión). Declara cuántas cadenas
#      comparó y falla si comparó cero.
#  (b) CONTEOS: SKILL.md enumera los guards en vez de contarlos ("eight
#      hooks" ya fue falso una vez y nadie lo supo). La lista tiene que ser
#      EXACTAMENTE la de los comentarios `// -- N.` de summa-gate/index.ts, y
#      un dígito o numeral inglés pegado a "hooks" es rojo.
#  (c) RUTAS: las rutas relativas al repo que SKILL.md cita con backticks se
#      resuelven contra el checkout. Las absolutas de host (C:\Users\ehven\…,
#      $HOME/.openclaw/…, ~/…) y el symlink .claude/skills/verify se excluyen
#      con la razón escrita acá: la batería corre en ubuntu-latest (CI) y esas
#      rutas no existen ahí. Una cita absoluta POSIX que no exista en la
#      máquina que corre la batería es roja: citá la ruta relativa al repo.
#
# Uso: bash scripts/tests/test-skill-verify.sh
set -u
cd "$(dirname "$0")/../.." || exit 1

# --- node >= 22: el programa embebido importa .ts (type stripping nativo) ---
elegir_node() {
  local c v
  for c in "$(command -v node 2>/dev/null)" \
           "$HOME/.openclaw/tools/node-v24.19.0/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    v=$("$c" --version 2>/dev/null | sed 's/^v//;s/\..*//')
    [ -n "$v" ] && [ "$v" -ge 22 ] 2>/dev/null && { echo "$c"; return 0; }
  done
  return 1
}
NODE=$(elegir_node) || { echo "FAIL: no hay un node >= 22 disponible"; exit 1; }

# --- symlink de openclaw: las cuatro líneas de la propia skill (Drive) ------
# role.test.ts borra summa-gate/node_modules/openclaw en su teardown, así que
# esto se re-crea en CADA corrida (idempotente), igual que exige SKILL.md.
# OPENCLAW_NODE_MODULES primero: en CI (ubuntu-latest) la batería lo exporta
# apuntando al node_modules del workspace, no a $HOME.
OC="${OPENCLAW_NODE_MODULES:-$HOME/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw}"
test -d "$OC" || { echo "FAIL: no hay instalacion de openclaw en $OC"; exit 1; }

# r1: si el enlace preexistía (before de role.test.ts, setup de CI, drive
# manual), se respalda con mv y se devuelve IGUAL al terminar; si no existía,
# no queda nada. El trap anterior lo borraba siempre: destruía estado ajeno.
LINK=summa-gate/node_modules/openclaw
RESPALDO=$(mktemp -d)/openclaw.respaldo
PREEXISTIA=0
if [ -e "$LINK" ] || [ -L "$LINK" ]; then
  PREEXISTIA=1
  mv "$LINK" "$RESPALDO" || { echo "FAIL: no se pudo respaldar $LINK"; exit 1; }
fi
( cd summa-gate && mkdir -p node_modules && { [ -e node_modules/openclaw ] || ln -s "$OC" node_modules/openclaw; } ) \
  || { echo "FAIL: no se pudo crear el symlink summa-gate/node_modules/openclaw"; exit 1; }
restaurar_enlace() {
  rm -f "$LINK"
  if [ "$PREEXISTIA" -eq 1 ]; then
    mv "$RESPALDO" "$LINK"
  fi
  rmdir "$(dirname "$RESPALDO")" 2>/dev/null || true
}
trap restaurar_enlace EXIT

# --- HOME en caja de arena ---------------------------------------------------
# La batería de (a) arma una sesión con el sentinel para disparar el gate de
# cierre, y ese armado persiste estado en ~/.openclaw/summa-gate/state. Correr
# la batería no puede ensuciar el HOME de la máquina que la corre. OC ya quedó
# resuelto a ruta absoluta, y el import del plugin pasa por el symlink, no por
# $HOME.
SB=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }

HOME="$SB" REPO_ROOT="$PWD" OPENCLAW_NODE_MODULES="$OC" "$NODE" --input-type=module - <<'PROGRAMA'
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = process.env.REPO_ROOT;
const SKILL_DIR = join(ROOT, "docs", "agent-skills", "verify");
const FEATS = join(SKILL_DIR, "features");

let fallas = 0;
const fail = (msg) => { console.log("FAIL " + msg); fallas += 1; };

// ===========================================================================
// (a) frases citadas vs blockReason reales
// ===========================================================================
// Host falso con la forma de fakeBaseApi (role.test.ts:24-48). Los campos que
// el plugin lee van AL TOPE del objeto api; runContext anidado bajo `runContext`.
const regs = [];
const noop = () => {};
const store = new Map();
const api = {
  logger: { info: noop, warn: noop, error: noop, debug: noop },
  on: (event, handler, opts) => regs.push({ event, handler, opts }),
  registerAgentToolResultMiddleware: noop,
  runContext: {
    setRunContext: ({ runId, namespace, value }) => { store.set(`${runId}:${namespace}`, value); return true; },
    getRunContext: ({ runId, namespace }) => store.get(`${runId}:${namespace}`),
    clearRunContext: ({ runId, namespace }) => { if (namespace) store.delete(`${runId}:${namespace}`); },
  },
  pluginConfig: {},
};
const plugin = await import(pathToFileURL(join(ROOT, "summa-gate", "index.ts")).href);
plugin.default.register(api);

const hookCon = (event) => regs.find((r) => r.event === event && !r.opts?.matcher);
const hookDe = (event, tool) => regs.find((r) => r.event === event && r.opts?.matcher?.includes(tool));

// Batería: un disparo por cadena que los guards pueden emitir. Si un caso no
// bloquea, el caso mismo es el fallo (el mapa no puede citar lo que no ocurre).
const main = { agentId: "main", sessionKey: "agent:main:main" };
const adversary = { agentId: "adversary", sessionKey: "agent:adversary:verify" };
const execHook = hookDe("before_tool_call", "exec");
const adversaryHook = hookCon("before_tool_call");
const sendHook = hookDe("before_tool_call", "sessions_send");

const reales = [];
function disparar(label, hookRef, event, ctx) {
  if (typeof hookRef !== "object" || hookRef === undefined) {
    reales.push({ label, reason: null });
    return;
  }
  const r = hookRef.handler(event, ctx);
  reales.push({ label, reason: r && r.block ? r.blockReason : null });
}

disparar("merge-guard subcomando CLI", execHook,
  { toolName: "exec", params: { command: "gh pr merge 12 -R o/r --squash" } }, main);
disparar("merge-guard mutación GraphQL", execHook,
  { toolName: "exec", params: { command: "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:PR_1}) { clientMutationId } }'" } }, main);
disparar("merge-guard ruta REST de merge", execHook,
  { toolName: "exec", params: { command: "gh api repos/o/r/pulls/1/merge -X PUT" } }, main);
disparar("merge-guard push a protegida", execHook,
  { toolName: "exec", params: { command: "git push origin main" } }, main);
disparar("confinamiento adversary escritura", adversaryHook,
  { toolName: "write", params: { file_path: "/tmp/fuera-de-zona.txt" } }, adversary);
disparar("confinamiento adversary redirección", adversaryHook,
  { toolName: "exec", params: { command: "printf x > /tmp/fuera.txt" } }, adversary);
disparar("confinamiento adversary cd + relativo", adversaryHook,
  { toolName: "exec", params: { command: "cd /tmp && printf x > fuera.txt" } }, adversary);
disparar("canal entre agentes", sendHook,
  { toolName: "sessions_send", params: { agentId: "ingenieria", message: "retoma el PR" } }, main);
{
  // Gate de cierre: arma la sesión con el sentinel y cerrá sin recibo.
  const sk = `agent:verify:test-skill-verify-${Date.now()}`;
  const build = regs.find((r) => r.event === "before_prompt_build");
  build.handler({ prompt: "hacé la tarea -saikit" }, { sessionKey: sk });
  const finalize = regs.find((r) => r.event === "before_agent_finalize");
  const r = finalize.handler({ lastAssistantMessage: "listo, terminé" }, { sessionKey: sk });
  reales.push({ label: "cierre con evidencia", reason: r && r.action === "revise" ? r.reason : null });
}

for (const { label, reason } of reales) {
  if (reason === null) fail(`(a) batería: el caso "${label}" no bloqueó; el mapa no puede citar una cadena que el guard no emite`);
}

// Frases citadas: cada fence bajo un título "## Expected output" de features/*.md.
const citas = [];
for (const f of readdirSync(FEATS).sort()) {
  if (!f.endsWith(".md")) continue;
  const lines = readFileSync(join(FEATS, f), "utf8").split("\n");
  let enSeccion = false, enFence = false, buf = [];
  for (const line of lines) {
    if (/^##\s/.test(line)) {
      if (enFence && buf.length) { citas.push({ file: f, texto: buf.join("\n") }); buf = []; }
      enSeccion = /^##\s+Expected output/.test(line);
      enFence = false;
      continue;
    }
    if (!enSeccion) continue;
    if (!enFence && line.trim() === "```") { enFence = true; buf = []; continue; }
    if (enFence) {
      if (line.trim() === "```") { citas.push({ file: f, texto: buf.join("\n") }); buf = []; enFence = false; }
      else buf.push(line);
    }
  }
}

// Truncado en el primer placeholder: <…> o "Destino:" (el tramo que sigue es
// dinámico: la ruta rechazada, el rol esperado). Lo determinista es lo citable.
function truncar(s) {
  const iPh = s.search(/<[^<>\n]{1,60}>/);
  const iDest = s.indexOf("Destino:");
  let i = -1;
  if (iPh !== -1 && iDest !== -1) i = Math.min(iPh, iDest);
  else if (iPh !== -1) i = iPh;
  else if (iDest !== -1) i = iDest;
  return i === -1 ? s : s.slice(0, i).replace(/\s+$/, "");
}

console.log(`(a) comparadas: ${citas.length} cadena(s) citada(s) contra ${reales.length} blockReason real(es)`);
if (citas.length === 0) fail("(a) el mapa no cita ninguna cadena: no hay nada que verificar y el candado sería decorativo");

function prefijoComun(a, b) {
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i += 1;
  return i;
}

// Dirección mapa->cita: cada cadena real debe estar citada EXACTAMENTE (en el
// tramo determinista). Una cita parcial o con palabras de más deja esta rama
// en rojo, que es lo que cazaba "match the opening".
const sinCita = [];
for (const { label, reason } of reales) {
  if (reason === null) continue;
  const citada = citas.some((c) => truncar(c.texto) === truncar(reason));
  if (!citada) sinCita.push({ label, reason });
}
for (const { label, reason } of sinCita) {
  fail(`(a) mapa incompleto o cita inexacta: el guard "${label}" emite una cadena que features/ no cita exactamente → ${JSON.stringify(truncar(reason).slice(0, 90))}...`);
}

// Dirección cita->mapa: cada cita debe corresponder a una cadena real. Se
// suprime la cita que comparte >=25 bytes de prefijo con una cadena real ya
// reportada como sin cita: es el MISMO defecto (la cita intentó esa cadena y
// le erró), no dos frases falsas distintas.
const sinCadena = [];
for (const c of citas) {
  const t = truncar(c.texto);
  const matchea = reales.some(({ reason }) => reason !== null && truncar(reason) === t);
  if (matchea) continue;
  const esElMismoDefecto = sinCita.some(({ reason }) => reason !== null && prefijoComun(t, truncar(reason)) >= 25);
  if (!esElMismoDefecto) sinCadena.push(c);
}
for (const c of sinCadena) {
  fail(`(a) cita sin guard: ${c.file} cita una cadena que ningún guard emite → ${JSON.stringify(truncar(c.texto).slice(0, 90))}...`);
}

// ===========================================================================
// (b) lista de guards de SKILL.md == comentarios `// -- N.` de index.ts
// ===========================================================================
const idx = readFileSync(join(ROOT, "summa-gate", "index.ts"), "utf8");
const delIndex = [];
for (const m of idx.matchAll(/^[ \t]*\/\/ -- (\d+(?:\/\d+)?)\. (.+)$/gm)) {
  // "Merge-guard (siempre activo) ---" → "Merge-guard"; el paréntesis y los
  // guiones de subrayado son decoración del comentario, no el nombre.
  const nombre = m[2].replace(/\s*-+\s*$/, "").split(/\s+\(|:/)[0].trim();
  delIndex.push(nombre);
}

const skill = readFileSync(join(SKILL_DIR, "SKILL.md"), "utf8");
const seccion = skill.match(/^## Guards\n([\s\S]*?)(?=^## )/m);
const deSkill = seccion ? [...seccion[1].matchAll(/^- (.+)$/gm)].map((m) => m[1].trim()) : [];

console.log(`(b) guards: SKILL.md lista ${deSkill.length}, index.ts declara ${delIndex.length}`);
if (!seccion) fail("(b) SKILL.md no tiene la sección ## Guards que enumera los guards");
if (delIndex.length === 0) fail("(b) index.ts no tiene comentarios // -- N.; el parser se rompió");
const setIndex = new Set(delIndex), setSkill = new Set(deSkill);
for (const n of delIndex) if (!setSkill.has(n)) fail(`(b) el guard "${n}" (// -- N. de index.ts) falta en la lista de SKILL.md`);
for (const n of deSkill) if (!setIndex.has(n)) fail(`(b) SKILL.md lista el guard "${n}" que ningún // -- N. de index.ts declara`);
if (delIndex.length !== deSkill.length && setIndex.size === setSkill.size) {
  fail("(b) la lista de SKILL.md y los // -- N. de index.ts difieren en cantidad");
}

// Prohibido el conteo pegado a "hooks": "eight hooks" ya fue falso una vez.
const numeral = skill.match(/(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+hooks/i);
if (numeral) fail(`(b) SKILL.md cuenta hooks ("${numeral[0]}"): los conteos se pudren; la lista de arriba es el candado`);

// ===========================================================================
// (c) rutas citadas con backticks en SKILL.md (prosa; los fences son comandos)
// ===========================================================================
const lineasProsa = [];
let enFence = false;
for (const line of skill.split("\n")) {
  if (line.trim().startsWith("```")) { enFence = !enFence; continue; }
  if (!enFence) lineasProsa.push(line);
}
const spans = [...lineasProsa.join("\n").matchAll(/`([^`\n]+)`/g)].map((m) => m[1])
  .filter((s) => !/\s/.test(s)) // con espacio es un comando, no una ruta
  .filter((s) => /[\\/]/.test(s) || /^[.~$]/.test(s) || /^[A-Za-z]:[\\/]/.test(s) || s.startsWith("/"));

// Citas que parecen rutas y no lo son: cada una con su razón escrita.
const NO_RUTAS = new Map([
  ["America/New_York", "zona horaria, no ruta"],
  ["origin/main", "ref de git, no ruta"],
  ["${runId}:${namespace}", "plantilla de clave de runContext, no ruta"],
  ["/maintain-verification-skill", "comando de skill, no ruta del filesystem"],
]);

// Exclusiones con la razón escrita: la batería corre en ubuntu-latest y estas
// rutas viven en otras máquinas (host gateway Windows, instalación local del
// host) o son locales de cada máquina (symlink gitignored que la skill misma
// enseña a recrear). Excluirlas no es pasarles la mano: es declarar que no se
// pueden resolver donde la batería corre.
const EXCLUIDAS = [
  { prueba: (p) => /^[A-Za-z]:[\\/]/.test(p), razon: "ruta del host gateway (Windows); la batería corre en ubuntu-latest" },
  { prueba: (p) => p.startsWith("$HOME/") || p === "~" || p.startsWith("~/"), razon: "instalación local del host; no existe en ubuntu-latest" },
  { prueba: (p) => p === ".claude" || p.startsWith(".claude/"), razon: "symlink machine-local bajo .claude/ (gitignored); la skill trae la receta para recrearlo" },
];

let resueltas = 0;
for (const span of spans) {
  if (NO_RUTAS.has(span)) continue;
  const excl = EXCLUIDAS.find((e) => e.prueba(span));
  if (excl) { console.log(`(c) excluida \`${span}\`: ${excl.razon}`); continue; }
  // Plantilla con placeholder: lo determinista es el DIRECTORIO del prefijo
  // (docs/evidence/verify-<fecha>.md → docs/evidence/), no el tramo de nombre
  // que ya lleva la plantilla pegada.
  const sinPh = span.split("<")[0];
  const estatica = span.includes("<") ? (sinPh.lastIndexOf("/") >= 0 ? sinPh.slice(0, sinPh.lastIndexOf("/") + 1) : sinPh) : span;
  if (!estatica) { fail(`(c) la cita \`${span}\` es solo placeholder`); continue; }
  if (span.startsWith("/")) {
    // Absoluta POSIX: citada como ruta del filesystem se resuelve al pie de la
    // letra. En ubuntu-latest (CI) /Users/dn/... no existe: si la skill citara
    // una, este candado la pone roja allá. Citá la ruta relativa al repo.
    if (existsSync(estatica) || (estatica.endsWith("/") && existsSync(estatica.slice(0, -1)))) { resueltas += 1; continue; }
    fail(`(c) la cita absoluta \`${span}\` no existe en esta máquina (la batería corre en ubuntu-latest: citá la ruta relativa al repo)`);
    continue;
  }
  if (existsSync(join(ROOT, estatica)) || existsSync(join(SKILL_DIR, estatica))) { resueltas += 1; continue; }
  // relativa a la skill (p.ej. `features/`), no al raíz del repo
  fail(`(c) SKILL.md cita \`${span}\` y no existe ni contra la raíz del repo ni contra docs/agent-skills/verify/`);
}
console.log(`(c) resueltas: ${resueltas} ruta(s) relativa(s) al repo citada(s) con backticks`);
if (resueltas === 0) fail("(c) no se resolvió ninguna ruta relativa: el candado de rutas no estaría verificando nada");

// ===========================================================================
if (fallas > 0) {
  console.log(`ROJO: ${fallas} problema(s) con la skill verify`);
  process.exit(1);
}
console.log("TODO VERDE: la skill verify dice lo que el plugin hace");
PROGRAMA
rc=$?

rm -rf "$SB"
exit $rc

#!/usr/bin/env node
// Re-deriva la columna `verdict_2_1` de docs/evidence/corpus-rendiciones.tsv a partir
// del detector vivo (buildRecord en observer.ts) y falla si alguna fila no coincide.
//
// Por que existe: el corpus solo vale si un tercero puede reproducirlo. La version
// original del PR #23 apuntaba a `/tmp/render-corpus-tsv.ts`, que se borra con el
// reinicio — el mismo problema que el propio discrepancy.md le reprocha a `probe.mjs`
// ("los 15 faltantes no son reconstruibles sin probe.mjs"). Esto cierra ese hueco con
// las dos piezas que SI viven en el repo: el TSV y el detector.
//
// Uso: node summa-gate/verify-corpus.mjs   (desde la raiz del repo)
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const { buildRecord } = await import(join(repo, "summa-gate/observer.ts"));

const lines = readFileSync(join(repo, "docs/evidence/corpus-rendiciones.tsv"), "utf8").trim().split("\n");
const head = lines[0].split("\t");
const iTexto = head.indexOf("verbatim");
const iEsperado = head.indexOf("expected_label");
const iVeredicto = head.indexOf("verdict_2_1");
if (iTexto < 0 || iEsperado < 0 || iVeredicto < 0) {
  console.error("El TSV no tiene las columnas verbatim / expected_label / verdict_2_1");
  process.exit(1);
}

let coinciden = 0;
const fallos = [];
let tp = 0, fn = 0, fp = 0, tn = 0;

for (const linea of lines.slice(1)) {
  const col = linea.split("\t");
  const texto = col[iTexto];
  const detectado = buildRecord(0, "s", "a", "k", [{ role: "assistant", content: texto }]).detected;
  const recomputado = detectado ? "detected" : "missed";
  if (col[iVeredicto].trim() === recomputado) coinciden += 1;
  else fallos.push(`  declarado=${col[iVeredicto]} recomputado=${recomputado} :: ${texto.slice(0, 60)}`);

  const debeDetectarse = col[iEsperado].startsWith("should-detect");
  if (debeDetectarse && detectado) tp += 1;
  else if (debeDetectarse && !detectado) fn += 1;
  else if (!debeDetectarse && detectado) fp += 1;
  else tn += 1;
}

const total = lines.length - 1;
console.log(`filas: ${total} | veredicto declarado == recomputado: ${coinciden}`);
console.log(`DEBEN detectarse: ${tp + fn} -> atrapados ${tp}, escapados ${fn}`);
console.log(`LEGITIMOS:        ${fp + tn} -> sobre-marcados ${fp}, bien ignorados ${tn}`);
if (fallos.length) {
  console.error(`\n${fallos.length} fila(s) no reproducen su veredicto:`);
  for (const f of fallos) console.error(f);
  process.exit(1);
}

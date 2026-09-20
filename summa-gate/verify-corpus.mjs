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

/** Piso de filas: el corpus tiene 22 hoy. Menos que esto es un TSV roto o truncado. */
const MIN_FILAS = 20;
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

// Cross-review de qwen (2026-09-12, hallazgo alto): este candado pasaba por vacio con un TSV
// de solo header (filas 0 -> exit 0), y ademas solo comprobaba AUTO-CONSISTENCIA: el unico
// exit(1) comparaba `verdict_2_1` (la columna declarada) contra lo recomputado, asi que si el
// detector se degradaba bastaba reescribir esa columna para volver al verde. `expected_label`
// se leia y solo se imprimia.
if (total < MIN_FILAS) {
  console.error(`El TSV tiene ${total} fila(s) de datos; se esperan al menos ${MIN_FILAS}.`);
  console.error("Un candado que valida un corpus vacio no es un candado.");
  process.exit(1);
}

console.log(`filas: ${total} | veredicto declarado == recomputado: ${coinciden}`);
console.log(`DEBEN detectarse: ${tp + fn} -> atrapados ${tp}, escapados ${fn}`);
console.log(`LEGITIMOS:        ${fp + tn} -> sobre-marcados ${fp}, bien ignorados ${tn}`);
if (fallos.length) {
  console.error(`\n${fallos.length} fila(s) no reproducen su veredicto:`);
  for (const f of fallos) console.error(f);
  process.exit(1);
}

// CORRECTITUD, no solo auto-consistencia: el detector no puede perder RECALL. Hoy atrapa
// 16 de 16 de las que deben detectarse; si alguien aprieta el regex y empieza a dejar pasar
// rendiciones reales, esto cae. La precision es otra cosa: el sobre-marcado (5 de 6 legitimos)
// esta elegido a proposito y declarado en Plans.md 2.1, asi que se informa y no rompe.
if (fn > 0) {
  console.error(`\n${fn} fila(s) etiquetadas should-detect que el detector NO atrapa.`);
  console.error("Eso es una regresion de recall: el medidor deja de ver rendiciones reales.");
  process.exit(1);
}

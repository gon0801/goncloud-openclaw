#!/usr/bin/env node
// Lee ~/.openclaw/summa-gate/rendiciones.jsonl (o el que se le pase) y reporta la tasa REAL,
// colapsando las multiples emisiones de `agent_end` de un mismo turno.
//
// Por que existe: `agent_end` se emite varias veces por turno de usuario (medido en vivo: 2,
// una tras el toolCall y una al cerrar). Contar lineas crudas infla el denominador ~1,7x y la
// tasa se lee mas baja de lo que es. Tres intentos de filtrar eso EN EL MOMENTO DE ESCRIBIR
// fallaron, los tres verificados en produccion: el observador no tiene, en el hot path, la
// informacion para saber si el turno cerro. Aca si estan todos los datos.
//
// Este es el script que hay que usar para leer la tasa en la tarea 2.2, no `wc -l`.
//
// Uso:
//   node summa-gate/leer-rendiciones.mjs [ruta-al-jsonl]
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const aqui = dirname(fileURLToPath(import.meta.url));
const { collapseTurns } = await import(pathToFileURL(join(aqui, "observer.ts")).href);

const ruta = process.argv[2] ?? join(homedir(), ".openclaw", "summa-gate", "rendiciones.jsonl");

let crudo;
try {
  crudo = readFileSync(ruta, "utf8");
} catch (err) {
  console.error(`No se pudo leer ${ruta}: ${err.code ?? err.message}`);
  process.exit(1);
}

const lineas = crudo.split("\n").filter((l) => l.trim());
const registros = [];
let ilegibles = 0;
for (const l of lineas) {
  try {
    registros.push(JSON.parse(l));
  } catch {
    ilegibles += 1;
  }
}

const turnos = collapseTurns(registros);
const detectadas = turnos.filter((r) => r.detected);
const sinClave = registros.filter((r) => typeof r.turnKey !== "string").length;

// Por agente, y por dia usando el ts del registro.
const porAgente = new Map();
const porDia = new Map();
for (const r of turnos) {
  const a = r.agent ?? "(sin agente)";
  const e = porAgente.get(a) ?? { turnos: 0, detectadas: 0 };
  e.turnos += 1;
  if (r.detected) e.detectadas += 1;
  porAgente.set(a, e);
  if (typeof r.ts === "number" && r.ts > 0) {
    const dia = new Date(r.ts).toISOString().slice(0, 10);
    porDia.set(dia, (porDia.get(dia) ?? 0) + (r.detected ? 1 : 0));
  }
}

console.log(`archivo: ${ruta}`);
console.log(`lineas crudas: ${lineas.length}${ilegibles ? ` (${ilegibles} ilegibles)` : ""}`);
console.log(`turnos reales (colapsados): ${turnos.length}`);
console.log(`detecciones: ${detectadas.length}`);
if (turnos.length > 0) {
  const inflacion = (lineas.length / turnos.length).toFixed(2);
  console.log(`inflacion de lineas por turno: ${inflacion}x`);
}
if (sinClave > 0) {
  console.log(`registros sin turnKey (anteriores al cambio, no agrupables): ${sinClave}`);
}

console.log("\npor agente:");
for (const [a, e] of [...porAgente.entries()].sort((x, y) => y[1].turnos - x[1].turnos)) {
  console.log(`  ${a.padEnd(12)} turnos=${String(e.turnos).padStart(4)}  detectadas=${e.detectadas}`);
}

if (porDia.size > 0) {
  console.log("\ndetecciones por dia:");
  for (const [d, n] of [...porDia.entries()].sort()) console.log(`  ${d}  ${n}`);
}

console.log(
  "\nRecordatorio para 2.2: el conteo crudo NO es la metrica. De las detecciones, la mayoria",
);
console.log(
  "son negativas legitimas (medido: el detector sobre-marca 5 de 6). Hay que revisarlas a mano.",
);

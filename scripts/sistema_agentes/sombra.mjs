#!/usr/bin/env node
// La sombra del controlador de SUA-02 (diseño, 4.9): con los hechos que había antes de la decisión
// de main, ¿qué habría propuesto decideLooseTask para cada encargo suelto? No escribe en R, no
// despierta a nadie y no despacha: lee un extracto de solo lectura y escribe una tabla.
//
// Uso: node --import <R>/scripts/tsx.mjs scripts/sistema_agentes/sombra.mjs \
//        --r <R> --extracto <extracto.json> [--salida <SUA-02-sombra.md>]
// Sin --salida imprime el JSON de las filas y el resumen.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

/** Cuándo decidió main: la hora de su resolve o de su cancelación, o null si no decidió. */
function decisionDeMain(tarea) {
  if (tarea.handling) {
    return { kind: tarea.handling.decision, at: tarea.handling.at };
  }
  if (tarea.cancellation) {
    return { kind: "cancel", at: tarea.cancellation.at };
  }
  return null;
}

/** Los hechos de la tarea anteriores a la decisión de main, en la forma de decideLooseTask. */
export function hechosAntes(tarea, decision) {
  const antes = (at) => decision === null || at < decision.at;
  const result =
    tarea.result === null
      ? null
      : tarea.result.kind === "produced"
        ? {
            kind: "produced",
            resultContract: tarea.resultContract,
            verdict: tarea.result.verdict,
            artifactRef: "",
          }
        : { kind: tarea.result.kind };
  return {
    // El extracto no trae la hora del resultado: un resultado es anterior a la decisión que lo
    // consumió, y una cancelación no consume ninguno.
    result: decision === null || decision.kind !== "cancel" ? result : null,
    incidents: tarea.incidents
      .filter((incident) => antes(incident.at))
      .map((incident) => ({ kind: incident.kind, episodeId: incident.episodeId ?? "", evidenceRef: "" })),
  };
}

/** La tabla de coincidencias de 4.9: la propuesta de la sombra frente a lo que hizo main. */
export function coincide(propuesta, decision) {
  if (decision === null) {
    return null;
  }
  switch (propuesta.kind) {
    case "verificar-y-aceptar":
      return decision.kind === "complete";
    case "corregir":
      return decision.kind === "continue";
    case "reintentar":
      return decision.kind === "cancel";
    case "excepcion":
      return decision.kind === "cancel";
    case "esperar":
      return false;
  }
  throw new Error(`propuesta desconocida: ${propuesta.kind}`);
}

export function sombra(extracto, decideLooseTask) {
  const filas = extracto.tasks.map((tarea) => {
    const decision = decisionDeMain(tarea);
    const propuesta = decideLooseTask(hechosAntes(tarea, decision));
    return {
      taskId: tarea.taskId,
      resultContract: tarea.resultContract,
      propuesta: propuesta.kind === "excepcion" ? `excepcion:${propuesta.type}` : propuesta.kind,
      main: decision === null ? null : decision.kind,
      coincide: coincide(propuesta, decision),
    };
  });
  return {
    filas,
    resumen: {
      tareas: filas.length,
      coinciden: filas.filter((fila) => fila.coincide === true).length,
      noCoinciden: filas.filter((fila) => fila.coincide === false).length,
      sinDecision: filas.filter((fila) => fila.coincide === null).length,
    },
  };
}

const MAIN = { complete: "resolve complete", continue: "resolve continue", cancel: "cancel" };

export function tabla(calculo, fuente) {
  const { filas, resumen } = calculo;
  const lineas = [
    "# SUA-02, la sombra del controlador",
    "",
    "Generado por `scripts/sistema_agentes/sombra.mjs`. No editar a mano.",
    "",
    `Extracto: \`${fuente.ruta}\`, sha256 \`${fuente.sha256}\`, ${resumen.tareas} tareas sueltas de \`main\`.`,
    `Regla: \`decideLooseTask\` de R \`${fuente.rSha}\`, con los hechos anteriores a la decisión de \`main\`.`,
    "",
    "| Tareas | Coinciden | No coinciden | Sin decisión de main |",
    "|---|---|---|---|",
    `| ${resumen.tareas} | ${resumen.coinciden} | ${resumen.noCoinciden} | ${resumen.sinDecision} |`,
    "",
    "| Tarea | Contrato | Propuesta de la sombra | Hizo main | Coincide |",
    "|---|---|---|---|---|",
    ...filas.map(
      (fila) =>
        `| \`${fila.taskId}\` | ${fila.resultContract} | ${fila.propuesta} | ${
          fila.main === null ? "nada" : MAIN[fila.main]
        } | ${fila.coincide === null ? "sin decisión" : fila.coincide ? "sí" : "no"} |`,
    ),
    "",
  ];
  return lineas.join("\n");
}

function argumento(nombre) {
  const at = process.argv.indexOf(`--${nombre}`);
  return at === -1 ? undefined : process.argv[at + 1];
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const r = argumento("r");
  const ruta = argumento("extracto");
  if (!r || !ruta) {
    throw new Error("sombra.mjs necesita --r <checkout de R> y --extracto <archivo>");
  }
  const { decideLooseTask } = await import(
    pathToFileURL(path.join(r, "src/agents/tasks/managed-root.decide.ts")).href
  );
  const bytes = readFileSync(ruta);
  const calculo = sombra(JSON.parse(bytes.toString("utf8")), decideLooseTask);
  const salida = argumento("salida");
  if (!salida) {
    process.stdout.write(`${JSON.stringify(calculo)}\n`);
  } else {
    const rSha = argumento("r-sha") ?? "desconocido";
    writeFileSync(
      salida,
      tabla(calculo, {
        ruta: argumento("ruta-citada") ?? ruta,
        sha256: createHash("sha256").update(bytes).digest("hex"),
        rSha,
      }),
    );
  }
}

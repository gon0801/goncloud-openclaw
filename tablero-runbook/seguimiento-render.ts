/**
 * tablero-runbook/seguimiento-render.ts — reporte consolidado de 30 minutos
 * (`seguimiento.v2`).
 *
 * Puro, sin I/O: del resumen objetivo (Task 1) al texto para el propietario.
 * Un solo mensaje aunque haya varias fases. `seguimiento.v1` queda solo para
 * avisos inmediatos de cuatro líneas y registros viejos.
 *
 * Lo que imprime sale de lo que recibe: cada carril no omitido del insumo
 * aparece con su fracción auditable. Elegir qué carriles entran al corte es
 * trabajo de quien arma el insumo (el reloj de la Task 3), no del renderer.
 * Los carriles `omitido` (trabajo cancelado) nunca se imprimen.
 */
import type { ConteoObjetivo, ResumenSeguimiento } from "./seguimiento.ts";

export type EntradaSeguimientoV2 = {
  fases: ResumenSeguimiento[];
  tareasSueltas: Array<{
    nombre: string;
    progreso: ConteoObjetivo;
    actividad: { detalle: string; iniciadaEn: string; ultimaEvidencia: string };
  }>;
  ahora: number;
  cambio: string;
  siguiente: string;
  necesita: string;
};

type BloqueContable = {
  nombre: string;
  progreso: ConteoObjetivo;
  detalle: string;
};

function fraccion(p: ConteoObjetivo): string {
  if (p.kind === "desconocido") return "desconocido";
  return `${p.porcentaje}% (${p.completadas}/${p.total})`;
}

function bloqueContable(b: BloqueContable): string {
  return `${b.nombre} — ${fraccion(b.progreso)}\n${b.detalle}`;
}

function esTerminal(estado: string): boolean {
  return estado === "mergeado" || estado === "omitido" || estado === "revertido";
}

function actividadEnCurso(input: EntradaSeguimientoV2): { iniciadaEn: string; ultimaEvidencia: string } {
  for (const fase of input.fases) {
    const actual = fase.carriles.find((c) => c.estado !== "omitido" && !esTerminal(c.estado))
      ?? fase.carriles.find((c) => c.estado !== "omitido");
    if (actual !== undefined) return actual.actividad;
  }
  const suelta = input.tareasSueltas[0];
  if (suelta !== undefined) return suelta.actividad;
  throw new Error("renderSeguimientoV2: sin carriles ni tareas para describir la ventana sin cambios");
}

function textoCambio(input: EntradaSeguimientoV2): string {
  if (input.cambio !== "") return input.cambio;
  // Ventana sin cambios: el reporte de 30 minutos sale igual porque confirma
  // que el trabajo continúa. Dice el tiempo en la unidad actual y la última
  // evidencia; nunca "nada nuevo".
  const act = actividadEnCurso(input);
  const inicioMs = Date.parse(act.iniciadaEn);
  if (Number.isNaN(inicioMs)) {
    throw new Error(`renderSeguimientoV2: iniciadaEn inválida (${act.iniciadaEn})`);
  }
  const minutos = Math.max(0, Math.floor((input.ahora - inicioMs) / 60000));
  return `El trabajo sigue en curso: ${minutos} minutos en la unidad actual; última evidencia: ${act.ultimaEvidencia}.`;
}

export function renderSeguimientoV2(input: EntradaSeguimientoV2): string {
  if (!Number.isFinite(input.ahora) || input.ahora < 0) {
    throw new Error("renderSeguimientoV2: ahora inválida");
  }
  if (input.fases.length === 0 && input.tareasSueltas.length === 0) {
    throw new Error("renderSeguimientoV2: sin fases ni tareas sueltas");
  }
  const partes: string[] = [];
  for (const fase of input.fases) {
    const p = fase.progreso;
    const encabezado = p.kind === "desconocido"
      ? `[AVANZA] Fase ${fase.fase} — desconocido`
      : `[AVANZA] Fase ${fase.fase} — ${p.porcentaje}% (${p.completadas}/${p.total} tareas)`;
    partes.push(encabezado);
    for (const c of fase.carriles) {
      if (c.estado === "omitido") continue;
      partes.push(bloqueContable({ nombre: c.nombre, progreso: c.progreso, detalle: c.actividad.detalle }));
    }
  }
  for (const s of input.tareasSueltas) {
    partes.push(bloqueContable({ nombre: s.nombre, progreso: s.progreso, detalle: s.actividad.detalle }));
  }
  partes.push(`Que cambió:\n${textoCambio(input)}`);
  partes.push(`Que sigue:\n${input.siguiente}`);
  partes.push(`Que necesito de ti:\n${input.necesita}`);
  return `${partes.join("\n\n")}\n`;
}

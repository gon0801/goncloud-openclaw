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

export type TareaSuelta = {
  nombre: string;
  progreso: ConteoObjetivo;
  actividad: { detalle: string; iniciadaEn: string; ultimaEvidencia: string };
};

/**
 * Límite de lenguaje para el propietario (`seguimiento.v2`): sin rutas,
 * ramas, hashes, números de PR, flags, siglas técnicas, nombres de archivo,
 * comandos ni acentos graves. Devuelve el texto intacto cuando cumple, o
 * `null` cuando trae algo técnico: quien interpola usa entonces una
 * descripción segura derivada del estado, nunca el texto crudo ni prosa
 * inventada. Los acentos y el lenguaje natural válido pasan siempre.
 */
const JERGA_RE = new RegExp(
  "`"
  + "|\\\\[\\w.~$-]"
  + "|(^|[\\s(>\"'])--[A-Za-z]"
  + "|#\\d"
  + "|(^|[\\s(>\"'])(\\/[\\w.~_-]+|~\\/|\\.\\.?\\/)"
  + "|(?<=[\\s(>\"'^]|^)(?=[\\w.~_-]*[A-Za-z])[\\w.~_-]+\\/[\\w.~_-]+"
  + "|\\b[\\w-]+\\.(ts|js|tsx|jsx|mjs|cjs|json|md|markdown|sh|bash|ps1|psm1|py|rb|go|rs|java|kt|yml|yaml|toml|ini|cfg|conf|txt|log|csv|tsv)\\b"
  + "|\\b(commit\\w*|merg\\w*|rebase\\w*|push\\w*|pull request|prs?|worktrees?|branches?|ramas?|repos?|ci|hooks?|scripts?)\\b"
  + "|\\b(git|npm|node|openclaw|tmux|cron|docker|kubectl|gh|psql|ssh|curl|bash|pwsh)\\b"
  + "|\\b(RPC|JSON|API|SHA|CLI|TDD|URL|SDK)\\b",
  "i",
);

function traeSha(s: string): boolean {
  const re = /\b[0-9a-fA-F]{7,64}\b/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    if (/[0-9]/.test(m[0]) && /[a-fA-F]/.test(m[0])) return true;
  }
  return false;
}

export function sanearTextoPropietario(s: string): string | null {
  if (typeof s !== "string" || s.length === 0) return null;
  if (JERGA_RE.test(s)) return null;
  // Un hexadecimal largo con solo dígitos o solo letras no es un hash
  // ("1234567", "acabada" pasan); con letra Y dígito sí ("abcdef1").
  if (traeSha(s)) return null;
  return s;
}

const ETIQUETAS_V1 = ["AVANZA", "DETENIDA", "NECESITO TU RESPUESTA", "CERRADA"] as const;

export type EtiquetaV1 = (typeof ETIQUETAS_V1)[number];

function sinSaltoFinal(texto: string): string[] {
  const partes = texto.split("\n");
  if (partes.length > 1 && partes[partes.length - 1] === "") partes.pop();
  return partes;
}

/**
 * Equivalente TypeScript del validador compartido de `seguimiento.v1`
 * (`mensaje_valido` en `scripts/mac/corrida/lib.sh`): cuatro líneas, etiqueta
 * cerrada, avance `N de M partes` o `avance desconocido` (extensión mínima
 * para conteos que no se pueden expresar honestamente), prefijos `Que`
 * con contenido, reglas de `Comando: ` y la misma jerga del límite de
 * lenguaje. Devuelve la etiqueta cuando todo cuadra.
 */
export function validarMensajeV1(texto: string): { ok: true; etiqueta: EtiquetaV1 } | { ok: false } {
  if (typeof texto !== "string") return { ok: false };
  const lineas = sinSaltoFinal(texto);
  if (lineas.length !== 4) return { ok: false };
  const [l1raw, l2, l3, l4raw] = lineas as [string, string, string, string];
  const primera = l1raw.startsWith("[SIMULACRO] ") ? l1raw.slice("[SIMULACRO] ".length) : l1raw;
  const m = /^\[(AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] /.exec(primera);
  if (m === null) return { ok: false };
  const etiqueta = m[1] as EtiquetaV1;
  const resto = primera.slice(m[0].length);
  if (resto === "") return { ok: false };
  if (etiqueta !== "CERRADA" && !(/[0-9]+ de [0-9]+ partes/.test(resto) || /avance desconocido/.test(resto))) {
    return { ok: false };
  }
  if (!/^Que cambio: .+/.test(l2)) return { ok: false };
  if (!/^Que sigue: .+/.test(l3)) return { ok: false };
  if (!/^Que necesito de ti: .+/.test(l4raw)) return { ok: false };
  if (/Comando: /.test(l1raw) || /Comando: /.test(l2) || /Comando: /.test(l3)) return { ok: false };
  const marcas4 = l4raw.match(/Comando: /g) ?? [];
  let cuarta = l4raw;
  if (etiqueta === "NECESITO TU RESPUESTA") {
    if (marcas4.length > 1) return { ok: false };
    if (marcas4.length === 1) {
      const seg = l4raw.slice(l4raw.lastIndexOf("Comando: ") + "Comando: ".length);
      if (seg === "" || seg.length > 200) return { ok: false };
      cuarta = l4raw.slice(0, l4raw.lastIndexOf("Comando: "));
    }
  } else if (marcas4.length > 0) {
    return { ok: false };
  }
  const cuerpo4 = cuarta.replace(/^Que necesito de ti: /, "").replace(/\s+$/, "");
  if (cuerpo4 === "") return { ok: false };
  const entero = [primera, l2, l3, cuarta].join("\n");
  if (sanearTextoPropietario(entero) === null) return { ok: false };
  return { ok: true, etiqueta };
}

/** Atajo booleano sobre `validarMensajeV1`. */
export function esMensajeV1Valido(texto: string): boolean {
  return validarMensajeV1(texto).ok;
}

export type EntradaSeguimientoV2 = {
  fases: ResumenSeguimiento[];
  tareasSueltas: TareaSuelta[];
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

function nombreSano(nombre: string, id: string, indice: number, clase: string): string {
  return sanearTextoPropietario(nombre)
    ?? (sanearTextoPropietario(id) ? `${clase} ${id}` : `${clase} ${indice + 1}`);
}

function estadoSano(estado: string): string {
  return sanearTextoPropietario(estado) ?? "seguimiento";
}

function esTerminal(estado: string): boolean {
  return estado === "mergeado" || estado === "omitido" || estado === "revertido";
}

type ActividadViva = {
  detalle: string;
  iniciadaEn: string;
  ultimaEvidencia: string;
  estado: string | null;
};

function actividadEnCurso(input: EntradaSeguimientoV2): ActividadViva {
  for (const fase of input.fases) {
    const actual = fase.carriles.find((c) => c.estado !== "omitido" && !esTerminal(c.estado))
      ?? fase.carriles.find((c) => c.estado !== "omitido");
    if (actual !== undefined) {
      return { ...actual.actividad, estado: actual.estado };
    }
  }
  const suelta = input.tareasSueltas[0];
  if (suelta !== undefined) return { ...suelta.actividad, estado: null };
  throw new Error("renderSeguimientoV2: sin carriles ni tareas para describir la ventana sin cambios");
}

function evidenciaSana(act: ActividadViva): string {
  return sanearTextoPropietario(act.ultimaEvidencia)
    ?? sanearTextoPropietario(act.detalle)
    ?? (act.estado === null ? "en seguimiento" : `en ${estadoSano(act.estado)}`);
}

function textoCambio(input: EntradaSeguimientoV2): string {
  const cambioSano = input.cambio === "" ? "" : sanearTextoPropietario(input.cambio);
  if (cambioSano !== null && cambioSano !== "") return cambioSano;
  // Ventana sin cambios: el reporte de 30 minutos sale igual porque confirma
  // que el trabajo continúa. Dice el tiempo en la unidad actual y la última
  // evidencia; nunca "nada nuevo".
  const act = actividadEnCurso(input);
  const inicioMs = Date.parse(act.iniciadaEn);
  if (Number.isNaN(inicioMs)) {
    throw new Error(`renderSeguimientoV2: iniciadaEn inválida (${act.iniciadaEn})`);
  }
  const minutos = Math.max(0, Math.floor((input.ahora - inicioMs) / 60000));
  return `El trabajo sigue en curso: ${minutos} minutos en la unidad actual; última evidencia: ${evidenciaSana(act)}.`;
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
    fase.carriles.filter((c) => c.estado !== "omitido").forEach((c, i) => {
      partes.push(bloqueContable({
        nombre: nombreSano(c.nombre, c.id, i, "Carril"),
        progreso: c.progreso,
        detalle: sanearTextoPropietario(c.actividad.detalle) ?? `En ${estadoSano(c.estado)}.`,
      }));
    });
  }
  input.tareasSueltas.forEach((s, i) => {
    partes.push(bloqueContable({
      nombre: nombreSano(s.nombre, "", i, "Tarea"),
      progreso: s.progreso,
      detalle: sanearTextoPropietario(s.actividad.detalle) ?? "En seguimiento.",
    }));
  });
  partes.push(`Que cambió:\n${textoCambio(input)}`);
  partes.push(`Que sigue:\n${sanearTextoPropietario(input.siguiente) ?? "Continuar con el trabajo en curso."}`);
  partes.push(`Que necesito de ti:\n${sanearTextoPropietario(input.necesita) ?? "Hay una respuesta pendiente de tu parte."}`);
  return `${partes.join("\n\n")}\n`;
}

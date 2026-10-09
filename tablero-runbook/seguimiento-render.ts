/**
 * tablero-runbook/seguimiento-render.ts — corte de avance para el propietario
 * (`seguimiento.v2`).
 *
 * Puro, sin I/O: del resumen objetivo al texto que lee alguien que no
 * programa. Un solo mensaje aunque haya varios trabajos: una línea de
 * novedad, dos líneas por trabajo y una de cierre. Las partes terminadas y las
 * pendientes no se listan una por una; las `omitido` nunca aparecen.
 * `seguimiento.v1` queda para los avisos inmediatos de cuatro líneas.
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
// `\b` de JS solo conoce `[A-Za-z0-9_]`: pegado a una palabra acentuada
// ("práctica") corta el límite de la palabra JUSTO tras la parte ASCII y
// "pr" (de `prs?`) queda "de palabra completa" por accidente, aunque la
// palabra real sea otra. Estas tres listas van con un límite consciente de
// Unicode (`(?<![\p{L}\p{N}_])`/`(?![\p{L}\p{N}_])`, con la bandera "u") para
// no tumbar prosa en español con acentos — medido 2026-09-25 con "práctica".
function limiteUnicode(alternativas: string): string {
  return `(?<![\\p{L}\\p{N}_])(?:${alternativas})(?![\\p{L}\\p{N}_])`;
}

const JERGA_RE = new RegExp(
  "`"
  + "|\\\\[\\w.~$-]"
  + "|(^|[\\s(>\"'])--[A-Za-z]"
  + "|#\\d"
  + "|(^|[\\s(>\"'])(\\/[\\w.~_-]+|~\\/|\\.\\.?\\/)"
  + "|(?<=[\\s(>\"'^]|^)(?=[\\w.~_-]*[A-Za-z])[\\w.~_-]+\\/[\\w.~_-]+"
  + "|\\b[\\w-]+\\.(ts|js|tsx|jsx|mjs|cjs|json|md|markdown|sh|bash|ps1|psm1|py|rb|go|rs|java|kt|yml|yaml|toml|ini|cfg|conf|txt|log|csv|tsv)\\b"
  + "|" + limiteUnicode("commit\\w*|merg\\w*|rebase\\w*|push\\w*|pull request|prs?|worktrees?|branches?|ramas?|repos?|ci|hooks?|scripts?")
  + "|" + limiteUnicode("git|npm|node|openclaw|tmux|cron|docker|kubectl|gh|psql|ssh|curl|bash|pwsh")
  + "|" + limiteUnicode("RPC|JSON|API|SHA|CLI|TDD|URL|SDK"),
  "iu",
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
  // Saltos y controles rompen la forma de líneas del mensaje v1: son texto
  // no apto y quien interpola cae a la frase segura.
  if (/[\u0000-\u001F\u007F\u2028\u2029]/.test(s)) return null;
  if (JERGA_RE.test(s)) return null;
  // Un hexadecimal largo con solo dígitos o solo letras no es un hash
  // ("1234567", "acabada" pasan); con letra Y dígito sí ("abcdef1").
  if (traeSha(s)) return null;
  return s;
}

const ETIQUETAS_V1 = ["ABIERTA", "AVANZA", "DETENIDA", "NECESITO TU RESPUESTA", "CERRADA"] as const;

export type EtiquetaV1 = (typeof ETIQUETAS_V1)[number];

function sinSaltoFinal(texto: string): string[] {
  const partes = texto.split("\n");
  if (partes.length > 1 && partes[partes.length - 1] === "") partes.pop();
  return partes;
}

// Prefijos que puede traer la línea 1, antes de `[ETIQUETA]`: `▶️ ` en una
// corrida real, `🧪 PRÁCTICA — no contestes ` en una de práctica, y el
// `[SIMULACRO] ` histórico (mensajes viejos ya grabados).
const PREFIJOS_LINEA1 = ["🧪 PRÁCTICA — no contestes ", "▶️ ", "🟢 ", "🟠 ", "🔴 ", "✅ ", "[SIMULACRO] "];

function quitarPrefijoLinea1(linea: string): string {
  // v2: la linea 1 puede traer MAS DE UN prefijo (el de corrida y el emoji de
  // estado, p. ej. "▶️ 🔴 [DETENIDA]"): se quitan todos, uno por vuelta.
  let restante = linea;
  let quito = true;
  while (quito) {
    quito = false;
    for (const p of PREFIJOS_LINEA1) {
      if (restante.startsWith(p)) {
        restante = restante.slice(p.length);
        quito = true;
        break;
      }
    }
  }
  return restante;
}

// Marcadores que `validarMensajeV1` lee como estructura del mensaje. Un nombre
// de trabajo que trae alguno cae a su id (mismo guardia que
// `corrida_encabezado` en lib.sh): si no, el mensaje entero sale inválido.
const COMANDO = "Comando: ";
const CAMBIO = "(Que cambio|Qué cambió): ";
const SIGUE = "(Que sigue|Qué sigue): ";
const NECESITO = "(Que necesito de ti|Qué necesito de ti): ";
const MARCADOR_RESERVADO_RE = new RegExp([COMANDO, CAMBIO, SIGUE, NECESITO].join("|"));

/** Texto de un documento que, interpolado en un v1, se leería como estructura. */
export function tieneMarcadorReservado(s: string): boolean {
  return MARCADOR_RESERVADO_RE.test(s);
}

/**
 * Equivalente TypeScript del validador compartido de `seguimiento.v1`
 * (`mensaje_valido` en `scripts/mac/corrida/lib.sh`): cuatro líneas, etiqueta
 * cerrada (incluida `ABIERTA`), avance `N de M partes` o `avance
 * desconocido` (extensión mínima para conteos que no se pueden expresar
 * honestamente; `CERRADA` y `ABIERTA` no lo exigen — `ABIERTA` puede no
 * saber todavía cuántas partes tiene), prefijos `Que`/`Qué` con contenido,
 * reglas de `Comando: ` y la misma jerga del límite de lenguaje — aplicada
 * solo al cuerpo (líneas 2 a 4): la línea 1 trae el nombre de la corrida, un
 * dato que quien manda el mensaje no controla, y ya se saneó antes
 * (`corrida_encabezado`). Devuelve la etiqueta cuando todo cuadra.
 */
export function validarMensajeV1(texto: string): { ok: true; etiqueta: EtiquetaV1 } | { ok: false } {
  if (typeof texto !== "string") return { ok: false };
  // v2 (2026-09-25): el mensaje legible lleva lineas vacias entre bloques;
  // no cuentan para la forma. Un v1 de 4 lineas pegadas sigue siendo valido.
  const lineas = sinSaltoFinal(texto).filter((l: string) => l.trim() !== "");
  if (lineas.length !== 4) return { ok: false };
  const [l1raw, l2, l3, l4raw] = lineas as [string, string, string, string];
  const primera = quitarPrefijoLinea1(l1raw);
  const m = /^\[(ABIERTA|AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] /.exec(primera);
  if (m === null) return { ok: false };
  const etiqueta = m[1] as EtiquetaV1;
  const resto = primera.slice(m[0].length);
  if (resto === "") return { ok: false };
  if (
    etiqueta !== "CERRADA" && etiqueta !== "ABIERTA"
    && !(/[0-9]+ de [0-9]+ partes/.test(resto) || /avance desconocido/.test(resto))
  ) {
    return { ok: false };
  }
  if (!new RegExp(`^${CAMBIO}.+`).test(l2)) return { ok: false };
  if (!new RegExp(`^${SIGUE}.+`).test(l3)) return { ok: false };
  if (!new RegExp(`^${NECESITO}.+`).test(l4raw)) return { ok: false };
  if ([l1raw, l2, l3].some((l) => l.includes(COMANDO))) return { ok: false };
  const marcas4 = l4raw.match(new RegExp(COMANDO, "g")) ?? [];
  let cuarta = l4raw;
  if (etiqueta === "NECESITO TU RESPUESTA") {
    if (marcas4.length > 1) return { ok: false };
    if (marcas4.length === 1) {
      const seg = l4raw.slice(l4raw.lastIndexOf(COMANDO) + COMANDO.length);
      if (seg === "" || seg.length > 200) return { ok: false };
      cuarta = l4raw.slice(0, l4raw.lastIndexOf(COMANDO));
    }
  } else if (marcas4.length > 0) {
    return { ok: false };
  }
  const cuerpo4 = cuarta.replace(new RegExp(`^${NECESITO}`), "").replace(/\s+$/, "");
  if (cuerpo4 === "") return { ok: false };
  // El límite de lenguaje se aplica solo al cuerpo (líneas 2 a 4): la línea 1
  // (`primera`) trae el nombre de la corrida y queda fuera, igual que en
  // `mensaje_valido` de lib.sh.
  if ([l2, l3, cuarta].some((linea) => sanearTextoPropietario(linea) === null)) {
    return { ok: false };
  }
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
  /**
   * Frases fijas que arma el reloj a partir de conteos y estados (nunca texto
   * libre de un agente). Vacío en un latido sin novedad.
   */
  novedades: string[];
  /** `nada`, o el motivo de la atención pendiente. */
  necesita: string;
};

type NombrableTrabajo = Pick<ResumenSeguimiento, "trabajoId" | "fase" | "titulo">;

function tituloApto(titulo: string): string | null {
  const t = sanearTextoPropietario(titulo);
  return t !== null && !tieneMarcadorReservado(t) ? t : null;
}

/**
 * Nombre de un trabajo en la línea 1 (encabezado), exenta del límite de
 * lenguaje igual que en `corrida_encabezado` de lib.sh: una fase por su
 * número; una corrida por su título, o por su id si el título trae jerga o
 * un marcador reservado.
 */
export function nombreEncabezado(r: NombrableTrabajo): string {
  if (!r.trabajoId.startsWith("corrida:")) return `Fase ${r.fase}`;
  return tituloApto(r.titulo) ?? r.trabajoId.slice("corrida:".length);
}

/**
 * Nombre de un trabajo dentro del cuerpo, que sí pasa el límite de lenguaje:
 * el título, o `Trabajo <id>`, o una frase fija si el id también trae jerga.
 */
export function nombreCuerpo(r: NombrableTrabajo): string {
  if (!r.trabajoId.startsWith("corrida:")) return `Fase ${r.fase}`;
  const id = r.trabajoId.slice("corrida:".length);
  return tituloApto(r.titulo) ?? (sanearTextoPropietario(id) !== null ? `Trabajo ${id}` : "Trabajo en curso");
}

function esTerminal(estado: string): boolean {
  return estado === "mergeado" || estado === "omitido" || estado === "revertido";
}

/** Primera línea de un latido: el corte sale sin que nada haya cambiado. */
export const SIN_NOVEDAD = "Sin novedad: todo sigue en curso.";

function conteo(p: ConteoObjetivo, unidad: string): string {
  return p.kind === "desconocido" ? "avance desconocido" : `${p.completadas} de ${p.total} ${unidad}`;
}

// Código inicial de una parte ("B4 ", "IN ", "S.1 ", "C3a "): le sirve a quien
// lleva el plan, no al propietario. Pide un dígito o dos mayúsculas para no
// comerse un artículo ("El cierre", "La entrega").
const CODIGO_PARTE_RE = /^(?:[A-Z]{1,3}\d+[a-z]?|[A-Z]\.\d+|[A-Z]{2,3})\s+(?=\S)/;

/** Nombre de una parte para el propietario: sin su código, o `la parte k`. */
function nombreParte(nombre: string, posicion: number): string {
  const limpio = sanearTextoPropietario(nombre.replace(CODIGO_PARTE_RE, ""));
  return limpio !== null && !tieneMarcadorReservado(limpio) ? limpio : `la parte ${posicion}`;
}

/** Tiempo desde el último movimiento, en la unidad más grande que lo dice entero. */
function haceCuanto(desde: string, ahora: number): string | null {
  const ms = Date.parse(desde);
  if (!Number.isFinite(ms)) return null;
  const minutos = Math.floor((ahora - ms) / 60000);
  if (minutos < 1) return null;
  if (minutos < 60) return minutos === 1 ? "1 minuto" : `${minutos} minutos`;
  const horas = Math.floor(minutos / 60);
  if (horas < 48) return horas === 1 ? "1 hora" : `${horas} horas`;
  return `${Math.floor(horas / 24)} días`;
}

function enumerar(nombres: string[]): string {
  if (nombres.length <= 1) return nombres.join("");
  const ultimo = nombres[nombres.length - 1];
  return `${nombres.slice(0, -1).join(", ")} ${/^h?i(?!e)/i.test(ultimo) ? "e" : "y"} ${ultimo}`;
}

/**
 * Segunda línea de un trabajo: qué se está haciendo y qué está atorado. Las
 * partes terminadas y las pendientes no se listan: ya las cuenta la fracción.
 */
function lineaActividad(fase: ResumenSeguimiento, ahora: number): string | null {
  const partes = fase.carriles.filter((c) => c.estado !== "omitido");
  if (partes.length === 0) return null;
  const nombradas = partes.map((c, i) => ({ c, nombre: nombreParte(c.nombre, i + 1) }));
  const atoradas = nombradas.filter((x) => x.c.estado === "atorado");
  const pendientes = nombradas.filter((x) => x.c.estado === "pendiente");
  const enCurso = nombradas.filter((x) => !esTerminal(x.c.estado) && x.c.estado !== "atorado" && x.c.estado !== "pendiente");
  const frases: string[] = [];
  if (enCurso.length > 0) {
    const hace = enCurso.length === 1 ? haceCuanto(enCurso[0].c.actividad.iniciadaEn, ahora) : null;
    frases.push(`Ahora: ${enumerar(enCurso.map((x) => x.nombre))}${hace !== null ? ` (último movimiento hace ${hace})` : ""}.`);
  } else if (pendientes.length > 0) {
    frases.push(`Sigue: ${pendientes[0].nombre}.`);
  } else if (atoradas.length === 0 && partes.every((c) => c.estado === "mergeado")) {
    frases.push(`Todas las ${fase.unidad} terminadas; falta cerrarlo.`);
  }
  if (atoradas.length > 0) {
    frases.push(`${atoradas.length === 1 ? "Atorada" : "Atoradas"}: ${enumerar(atoradas.map((x) => x.nombre))}.`);
  }
  return frases.length > 0 ? frases.join(" ") : null;
}

function lineaNecesita(necesita: string): string {
  if (necesita.replace(/\.$/, "") === "nada") return "No necesito nada de ti.";
  const motivo = tieneMarcadorReservado(necesita) ? null : sanearTextoPropietario(necesita);
  if (motivo === null) return "Necesito de ti: Tienes una decisión pendiente.";
  return `Necesito de ti: ${/[.?!]$/.test(motivo) ? motivo : `${motivo}.`}`;
}

/**
 * Corte de avance para el propietario. Una línea de novedad, dos líneas por
 * trabajo y una de cierre: lo que alguien que no programa necesita para saber
 * si va bien, qué se está haciendo y si le toca hacer algo.
 */
export function renderSeguimientoV2(input: EntradaSeguimientoV2): string {
  if (!Number.isFinite(input.ahora) || input.ahora < 0) {
    throw new Error("renderSeguimientoV2: ahora inválida");
  }
  if (input.fases.length === 0 && input.tareasSueltas.length === 0) {
    throw new Error("renderSeguimientoV2: sin fases ni tareas sueltas");
  }
  const novedades = input.novedades.filter((n) => sanearTextoPropietario(n) !== null);
  const lineas: string[] = [novedades.length > 0 ? novedades.join(" ") : SIN_NOVEDAD];
  for (const fase of input.fases) {
    lineas.push(`${nombreEncabezado(fase)}: ${conteo(fase.progreso, fase.unidad)}.`);
    const actividad = lineaActividad(fase, input.ahora);
    if (actividad !== null) lineas.push(actividad);
  }
  input.tareasSueltas.forEach((s, i) => {
    const avance = s.progreso.kind === "desconocido" ? "avance desconocido" : `${s.progreso.completadas} de ${s.progreso.total}`;
    lineas.push(`${sanearTextoPropietario(s.nombre) ?? `Tarea ${i + 1}`}: ${avance}.`);
  });
  lineas.push(lineaNecesita(input.necesita));
  return `${lineas.join("\n")}\n`;
}

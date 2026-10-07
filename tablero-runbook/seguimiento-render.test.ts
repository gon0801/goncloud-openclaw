/**
 * seguimiento-render.test.ts — corte de avance para el propietario (`seguimiento.v2`).
 *
 * El ejemplo aprobado y el caso real del 2026-10-07 se afirman byte por byte:
 * acentos, puntuación y el salto final. Lenguaje para el propietario: sin rutas, SHAs,
 * PRs, flags ni acentos graves.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  type ConteoObjetivo,
  type ResumenCarril,
  type ResumenSeguimiento,
} from "./seguimiento.ts";
import {
  type EntradaSeguimientoV2,
  esMensajeV1Valido,
  renderSeguimientoV2,
  sanearTextoPropietario,
  validarMensajeV1,
} from "./seguimiento-render.ts";

function carril(
  id: string,
  nombre: string,
  estado: string,
  progreso: ConteoObjetivo,
  detalle: string,
): ResumenCarril {
  return {
    id,
    nombre,
    estado,
    progreso,
    actividad: {
      detalle,
      iniciadaEn: "2026-09-19T10:20:00Z",
      ultimaEvidencia: "última evidencia observada",
    },
  };
}

function fase14(): ResumenSeguimiento {
  return {
    trabajoId: "fase:14",
    fase: "14",
    titulo: "Fase 14",
    unidad: "tareas",
    progreso: { kind: "conocido", completadas: 6, total: 13, porcentaje: 46 },
    carriles: [
      carril("M", "Implementación", "implementando",
        { kind: "conocido", completadas: 3, total: 4, porcentaje: 75 },
        "Muse está corrigiendo el último caso del vigilante."),
      carril("R", "Revisión", "revision-cruzada",
        { kind: "conocido", completadas: 1, total: 3, porcentaje: 33 },
        "La primera revisión terminó; faltan la revisión cruzada y CodeRabbit."),
      carril("C", "Cierre", "pendiente",
        { kind: "conocido", completadas: 0, total: 2, porcentaje: 0 },
        "Todavía no comienza."),
    ],
    siguientePaso: "Terminar la corrección y comenzar la revisión.",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: "2026-09-19T10:30:00Z",
  };
}

function entradaEjemplo(): EntradaSeguimientoV2 {
  return {
    fases: [fase14()],
    tareasSueltas: [],
    ahora: Date.parse("2026-09-19T11:00:00Z"),
    novedades: ["Fase 14 terminó una tarea."],
    necesita: "nada",
  };
}

const EJEMPLO_APROBADO = `Fase 14 terminó una tarea.
Fase 14: 6 de 13 tareas.
Ahora: Implementación y Revisión.
No necesito nada de ti.
`;

const HECHO: ConteoObjetivo = { kind: "conocido", completadas: 1, total: 1, porcentaje: 100 };
const SIN_HACER: ConteoObjetivo = { kind: "conocido", completadas: 0, total: 1, porcentaje: 0 };

function parte(id: string, nombre: string, estado: string, iniciadaEn = "2026-10-07T16:17:00Z"): ResumenCarril {
  return {
    id,
    nombre,
    estado,
    progreso: estado === "mergeado" ? HECHO : SIN_HACER,
    // Texto libre de agentes, con jerga a propósito: nada de esto puede salir.
    actividad: { detalle: estado, iniciadaEn, ultimaEvidencia: "B4-23-r1 entregado por opencode, en curso" },
  };
}

function corrida(id: string, titulo: string, carriles: ResumenCarril[], over: Partial<ResumenSeguimiento> = {}): ResumenSeguimiento {
  const hechas = carriles.filter((c) => c.estado === "mergeado").length;
  const total = carriles.filter((c) => c.estado !== "omitido").length;
  return {
    trabajoId: `corrida:${id}`,
    fase: "0",
    titulo,
    unidad: "partes",
    progreso: { kind: "conocido", completadas: hechas, total, porcentaje: total === 0 ? 0 : Math.round((100 * hechas) / total) },
    carriles,
    siguientePaso: "esperar LISTO-B4-23-r1",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: "2026-10-07T16:21:50Z",
    ...over,
  };
}

/** El corte que recibió el propietario el 2026-10-07: más de 60 líneas con jerga. */
function casoReal(): EntradaSeguimientoV2 {
  return {
    fases: [
      corrida("encargos", "Encargos durables de agentes", [
        parte("p1", "Revisión de lo hecho", "mergeado"),
        parte("p2", "B1 encargos y consumo", "mergeado"),
        parte("p3", "B2 presupuesto y recuperación", "mergeado"),
        parte("p4", "B3 CLI y recursos", "mergeado"),
        parte("p5", "B4 integración y matriz", "implementando"),
        parte("p6", "B5 adopción preparada", "atorado"),
      ]),
      corrida("revisor-correcciones", "Revisor de PRs: correcciones T01-T15", [
        parte("p1", "K0 plan versionado", "mergeado"),
        parte("p2", "R0 rutas y contexto", "mergeado"),
        parte("p3", "S0 codec schema 3", "mergeado"),
        parte("p4", "S1 capacidad", "mergeado"),
        parte("p5", "F1 identidad cableada", "mergeado"),
        parte("p6", "U0 solicitudes y publicación", "mergeado"),
        parte("p7", "U1 comandos", "mergeado"),
        parte("p8", "UW workflows", "mergeado"),
        parte("p9", "IN instalador", "implementando", "2026-10-07T15:05:00Z"),
        parte("p10", "E2 evaluación", "pendiente"),
        parte("p11", "D0 delta real", "pendiente"),
        parte("p12", "C0 contexto selectivo", "pendiente"),
        parte("p13", "Cierre", "pendiente"),
      ], { siguientePaso: "IN" }),
    ],
    tareasSueltas: [],
    ahora: Date.parse("2026-10-07T17:07:00Z"),
    novedades: [],
    necesita: "nada",
  };
}

const CASO_REAL_ESPERADO = `Sin novedad: todo sigue en curso.
Encargos durables de agentes: 4 de 6 partes.
Ahora: integración y matriz (último movimiento hace 50 minutos). Atorada: adopción preparada.
revisor-correcciones: 8 de 13 partes.
Ahora: instalador (último movimiento hace 2 horas).
No necesito nada de ti.
`;

function unaParte(estado: string, iniciadaEn: string, ahora: string): string {
  return renderSeguimientoV2({
    ...casoReal(),
    fases: [corrida("migrar-correo", "Migrar el correo", [parte("p1", "Exportar buzones", estado, iniciadaEn)])],
    ahora: Date.parse(ahora),
  });
}

describe("renderSeguimientoV2", () => {
  it("renders the approved example byte for byte", () => {
    assert.equal(renderSeguimientoV2(entradaEjemplo()), EJEMPLO_APROBADO);
  });

  it("renders the real 60-line case in six plain lines, byte for byte", () => {
    assert.equal(renderSeguimientoV2(casoReal()), CASO_REAL_ESPERADO);
  });

  it("never exceeds one news line, two lines per job and one closing line, with no blank lines", () => {
    const lineas = renderSeguimientoV2(casoReal()).split("\n");
    assert.equal(lineas.pop(), "");
    assert.ok(lineas.length <= 1 + 2 * 2 + 1, `demasiadas líneas: ${lineas.length}`);
    assert.ok(lineas.every((l) => l.trim() !== ""));
  });

  it("never lists finished or pending parts one by one, nor tags, percentages or agent free text", () => {
    const text = renderSeguimientoV2(casoReal());
    for (const prohibido of [
      "Revisión de lo hecho", "encargos y consumo", "plan versionado", "evaluación", "contexto selectivo",
      "[AVANZA]", "%", "Que cambió", "Que sigue", "LISTO", "B4-23", "opencode", "evidencia", "En seguimiento",
    ]) {
      assert.ok(!text.includes(prohibido), `no debe salir: ${prohibido}`);
    }
  });

  it("strips the leading code of a part and keeps names that only look like one", () => {
    const text = renderSeguimientoV2({
      ...casoReal(),
      fases: [corrida("x", "Trabajo", [
        parte("p1", "S.1 acta de listado", "implementando"),
        parte("p2", "C3a heredados código", "implementando"),
        parte("p3", "El cierre", "implementando"),
        parte("p4", "Revisión de lo hecho", "atorado"),
      ])],
    });
    assert.match(text, /Ahora: acta de listado, heredados código y El cierre\./);
    assert.match(text, /Atorada: Revisión de lo hecho\./);
  });

  it("a part whose name is not owner language is named by its position among the non-omitted parts", () => {
    const text = renderSeguimientoV2({
      ...casoReal(),
      fases: [corrida("x", "Trabajo", [
        parte("p1", "Viejo", "omitido"),
        parte("p2", "Exportar", "mergeado"),
        parte("p3", "B3 CLI y recursos", "implementando"),
      ])],
    });
    assert.match(text, /Ahora: la parte 2 /);
    assert.doesNotMatch(text, /CLI/);
    assert.doesNotMatch(text, /Viejo/);
  });

  it("says how long ago the only part in progress last moved, in whole minutes, hours or days", () => {
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-07T10:01:30Z"), /\(último movimiento hace 1 minuto\)/);
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-07T10:59:00Z"), /\(último movimiento hace 59 minutos\)/);
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-07T11:10:00Z"), /\(último movimiento hace 1 hora\)/);
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-09T09:59:00Z"), /\(último movimiento hace 47 horas\)/);
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-10T10:00:00Z"), /\(último movimiento hace 3 días\)/);
  });

  it("omits the elapsed time when it is under a minute or the date is unreadable", () => {
    assert.match(unaParte("implementando", "2026-10-07T10:00:00Z", "2026-10-07T10:00:20Z"), /\nAhora: Exportar buzones\.\n/);
    assert.match(unaParte("implementando", "no-es-fecha", "2026-10-07T10:00:20Z"), /\nAhora: Exportar buzones\.\n/);
  });

  it("with nothing in progress names the next pending part; with everything done says it is waiting to be closed", () => {
    assert.match(unaParte("pendiente", "2026-10-07T10:00:00Z", "2026-10-07T11:00:00Z"), /\nSigue: Exportar buzones\.\n/);
    assert.match(unaParte("mergeado", "2026-10-07T10:00:00Z", "2026-10-07T11:00:00Z"), /\nTodas las partes terminadas; falta cerrarlo\.\n/);
  });

  it("with several pending parts names only the next one", () => {
    const text = renderSeguimientoV2({
      ...casoReal(),
      fases: [corrida("x", "Trabajo", [parte("p1", "Exportar", "mergeado"), parte("p2", "Importar", "pendiente"), parte("p3", "Cambiar", "pendiente")])],
    });
    assert.match(text, /\nSigue: Importar\.\n/);
    assert.ok(!text.includes("Cambiar"), text);
  });

  it("names several stuck parts together", () => {
    const text = renderSeguimientoV2({
      ...casoReal(),
      fases: [corrida("x", "Trabajo", [parte("p1", "Exportar", "atorado"), parte("p2", "Importar", "atorado"), parte("p3", "Cambiar", "pendiente")])],
    });
    assert.match(text, /\nSigue: Cambiar\. Atoradas: Exportar e Importar\.\n/);
  });

  it("renders unknown plans as desconocido, never as zero", () => {
    const desconocida: ResumenSeguimiento = {
      ...fase14(),
      progreso: { kind: "desconocido", motivo: "plan-sin-verificar" },
    };
    const text = renderSeguimientoV2({ ...entradaEjemplo(), fases: [desconocida] });
    assert.match(text, /\nFase 14: avance desconocido\.\n/);
    assert.doesNotMatch(text, /0 de/);
  });

  it("a job with no readable parts gets its count line only", () => {
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      fases: [{ ...fase14(), carriles: [], progreso: { kind: "desconocido", motivo: "unidad-desconocida" } }],
      novedades: [],
    });
    assert.equal(text, "Sin novedad: todo sigue en curso.\nFase 14: avance desconocido.\nNo necesito nada de ti.\n");
  });

  it("a corrida is headed by its title and counts parts; a real phase keeps Fase N and its own unit", () => {
    const text = renderSeguimientoV2({ ...casoReal(), fases: [casoReal().fases[0]!, fase14()] });
    assert.match(text, /\nEncargos durables de agentes: 4 de 6 partes\.\n/);
    assert.match(text, /\nFase 14: 6 de 13 tareas\.\n/);
    assert.doesNotMatch(text, /Fase 0/);
  });

  it("a corrida whose title is not owner language is headed by its id, like corrida_encabezado", () => {
    assert.match(renderSeguimientoV2(casoReal()), /\nrevisor-correcciones: 8 de 13 partes\.\n/);
  });

  it("renders standalone tasks after the jobs", () => {
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      tareasSueltas: [{
        nombre: "Actualizar la guía de operación",
        progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
        actividad: { detalle: "Se redacta la segunda sección.", iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: "ok" },
      }],
    });
    assert.match(text, /\nAhora: Implementación y Revisión\.\nActualizar la guía de operación: 1 de 2\.\nNo necesito nada de ti\.\n$/);
  });

  it("closes with the attention reason when one is pending, or a safe phrase when it is not owner language", () => {
    assert.match(
      renderSeguimientoV2({ ...entradaEjemplo(), necesita: "Falta tu visto bueno para publicar" }),
      /\nNecesito de ti: Falta tu visto bueno para publicar\.\n$/,
    );
    assert.match(
      renderSeguimientoV2({ ...entradaEjemplo(), necesita: "mira foo.ts y corre git status" }),
      /\nNecesito de ti: Tienes una decisión pendiente\.\n$/,
    );
    assert.match(renderSeguimientoV2({ ...entradaEjemplo(), necesita: "nada." }), /\nNo necesito nada de ti\.\n$/);
  });

  it("rejects empty input and an invalid now", () => {
    assert.throws(() => renderSeguimientoV2({ ...entradaEjemplo(), fases: [], tareasSueltas: [] }), /sin fases ni tareas sueltas/);
    assert.throws(() => renderSeguimientoV2({ ...entradaEjemplo(), ahora: Number.NaN }), /ahora inválida/);
  });
});

describe("sanearTextoPropietario", () => {
  it("keeps valid owner prose with accents untouched", () => {
    for (const limpio of [
      "Muse está corrigiendo el último caso del vigilante.",
      "La primera revisión terminó; faltan la revisión cruzada y CodeRabbit.",
      "Se completó la detección de sesiones terminadas.",
      "Fase 14 avanzó de 1/4 a 2/4.",
      "46% (6/13 tareas)",
      "No pude leer el avance de Fase 14 (archivo ilegible); no retiro el seguimiento hasta verificarlo.",
      "Necesito tu respuesta para Fase 14: Elegir A o B.",
      "El trabajo sigue en curso: 45 minutos en la unidad actual.",
      "nada.",
      "¿Sigo por A o por B?",
    ]) {
      assert.equal(sanearTextoPropietario(limpio), limpio, `texto limpio rechazado: ${limpio}`);
    }
  });

  it("rejects every forbidden class from the v2 contract", () => {
    for (const sucio of [
      "Revisando /tmp/x en commit abcdef1",
      "mira foo.ts para el detalle",
      "en la rama feat/watchdog",
      "quedo en abcdef1",
      "cierra PR #104",
      "corre con --force",
      "di `comando`",
      "con CI en verde",
      "se mergeo el cambio",
      "ya quedo committed",
      "ruta C:\\Users\\dn\\x",
      "lote 1234567 y hash abcdef1",
      "haz push del repo",
      "tras el rebase",
      "el hook avisa",
      "corre el script",
      "Ejecutar git status y npm test",
      "El RPC usa JSON por API",
      "Revisar SHA antes de continuar",
      "Claude trabaja en tmux",
      "corre node --test",
      "mira openclaw cron list",
      "pasa el TDD",
      "pide la CLI",
    ]) {
      assert.equal(sanearTextoPropietario(sucio), null, `texto sucio aceptado: ${sucio}`);
    }
  });

  it("rejects line breaks and control characters that would break the v1 line form", () => {
    for (const roto of [
      "Elegir\nA o B",
      "Elegir\rA o B",
      "con\ttabulado",
      "Elegir A o B\u0007",
      "con separador\u2028de linea",
    ]) {
      assert.equal(sanearTextoPropietario(roto), null, `control aceptado: ${JSON.stringify(roto)}`);
    }
  });

  it("never leaks technical text through any interpolated field", () => {
    const sucio = "Revisando /tmp/x en commit abcdef1, PR #104 con --force";
    const text = renderSeguimientoV2({
      fases: [{
        ...fase14(),
        siguientePaso: sucio,
        atencionRequerida: { necesaria: true, motivo: sucio },
        carriles: [
          { ...fase14().carriles[0]!, nombre: "Mira foo.ts", actividad: { detalle: sucio, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: sucio } },
        ],
      }],
      tareasSueltas: [{
        nombre: "suelta feat/watchdog",
        progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
        actividad: { detalle: sucio, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: sucio },
      }],
      ahora: Date.parse("2026-09-19T11:00:00Z"),
      novedades: [sucio],
      necesita: sucio,
    });
    for (const prohibido of ["/tmp/x", "foo.ts", "feat/watchdog", "abcdef1", "PR #104", "--force", "commit"]) {
      assert.ok(!text.includes(prohibido), `fuga tecnica: ${prohibido}`);
    }
    assert.equal(
      text,
      "Sin novedad: todo sigue en curso.\nFase 14: 6 de 13 tareas.\nAhora: la parte 1 (último movimiento hace 40 minutos).\nTarea 1: 1 de 2.\nNecesito de ti: Tienes una decisión pendiente.\n",
    );
  });
});

describe("esMensajeV1Valido", () => {
  const V1_OK = [
    "[AVANZA] Corrida, 2 de 5 partes terminadas\nQue cambio: queda lista\nQue sigue: sigue igual\nQue necesito de ti: nada.",
    "[DETENIDA] Corrida, 1 de 2 partes terminadas\nQue cambio: algo material\nQue sigue: sigue igual\nQue necesito de ti: nada.",
    "[NECESITO TU RESPUESTA] Corrida, avance desconocido\nQue cambio: la fase espera\nQue sigue: sigue igual\nQue necesito de ti: responde si o no.",
    "[CERRADA] Corrida, cierre en palabras\nQue cambio: x\nQue sigue: y\nQue necesito de ti: nada.",
    "[SIMULACRO] [AVANZA] Corrida, 2 de 5 partes terminadas\nQue cambio: queda lista\nQue sigue: sigue igual\nQue necesito de ti: nada.",
    // Lo que emite corrida_mensaje ahora: nombre + hora, prefijo real, etiqueta ABIERTA
    // (sin avance: no se sabe todavía cuántas partes tiene) y prefijos con acento.
    "▶️ [ABIERTA] Fase 9: cierre de corridas autónomas (abrió 09:00)\nQué cambió: Arrancó la corrida.\nQué sigue: Se irá viendo cuántas partes tiene conforme avance.\nQué necesito de ti: nada",
    // Un título de runbook con jerga en la línea 1 (CI) NO tumba el mensaje: la
    // jerga solo se revisa en el cuerpo (regresión del bloqueante 2026-09-25).
    "▶️ [AVANZA] Autopilot de la Fase 15 — CI completa (abrió 09:00), 2 de 5 partes terminadas\nQué cambió: sigue igual\nQué sigue: sigue igual\nQué necesito de ti: nada.",
    // Corrida de práctica: prefijo nuevo, y NECESITO TU RESPUESTA sin Comando: ni pregunta real.
    "🧪 PRÁCTICA — no contestes [NECESITO TU RESPUESTA] Fase 9 (abrió 09:00), 0 de 3 partes terminadas\nQué cambió: Una parte de la prueba llegó a una pregunta de práctica.\nQué sigue: Esa parte no avanza hasta tener la respuesta; el resto sigue como estaba.\nQué necesito de ti: nada: es una prueba, se resuelve sola",
    // Negritas de 14.12: el validador tolera el mensaje con las negritas del
    // contrato (avance y cambio en **; en DETENIDA el necesito sin).
    "🧪 PRÁCTICA — no contestes 🔴 [DETENIDA] Fase 9 (abrió 09:00), **1 de 2 partes terminadas**\nQué cambió: **hubo un percance**\nQué sigue: se retoma\nQué necesito de ti: nada",
  ];
  const V1_MAL = [
    "[ETIQUETA-RARA] Corrida, 1 de 2 partes terminadas\nQue cambio: x\nQue sigue: y\nQue necesito de ti: z.",
    "[AVANZA] Corrida, 1 de 2 partes terminadas\nQue cambio: x\nQue sigue: y",
    "[AVANZA] Fase 9\nQue cambio: x\nQue sigue: y\nQue necesito de ti: z.",
    "[AVANZA] Corrida, 1 de 2 partes terminadas\nQue cambio: \nQue sigue: y\nQue necesito de ti: z.",
    "[AVANZA] Corrida, 1 de 2 partes terminadas\nQue cambio: mira /tmp/x\nQue sigue: y\nQue necesito de ti: z.",
    "[NECESITO TU RESPUESTA] Corrida, 1 de 2 partes terminadas\nQue cambio: x\nQue sigue: y\nQue necesito de ti: z; Comando: ~/bin/corrida.sh responder --sesion s --si\nQue necesito de ti: otra.",
    "[AVANZA] Corrida, 1 de 2 partes terminadas\nQue cambio: x\nQue sigue: y\nQue necesito de ti: z; Comando: ~/bin/x --si",
  ];

  it("accepts valid v1 messages including unknown advance", () => {
    for (const texto of V1_OK) {
      assert.equal(esMensajeV1Valido(texto), true, `v1 válido rechazado: ${texto.slice(0, 40)}`);
    }
  });

  it("rejects malformed v1 messages like the shared validator", () => {
    for (const texto of V1_MAL) {
      assert.equal(esMensajeV1Valido(texto), false, `v1 inválido aceptado: ${texto.slice(0, 40)}`);
    }
  });

  it("validarMensajeV1 keeps accepting a valid four-line message line by line", () => {
    const texto = "[NECESITO TU RESPUESTA] Corrida, 1 de 4 partes terminadas\n"
      + "Que cambio: La fase 14 llegó a una decisión que no está preaprobada.\n"
      + "Que sigue: El trabajo espera tu respuesta antes de continuar.\n"
      + "Que necesito de ti: Elegir A o B.";
    assert.deepEqual(validarMensajeV1(texto), { ok: true, etiqueta: "NECESITO TU RESPUESTA" });
  });
});

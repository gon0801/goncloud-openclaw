/**
 * seguimiento-render.test.ts — reporte consolidado de 30 minutos (`seguimiento.v2`).
 *
 * TDD rojo-primero: este archivo se escribió ANTES de `seguimiento-render.ts`.
 * El ejemplo aprobado se afirma byte por byte: acentos, líneas en blanco,
 * puntuación y el salto final. Lenguaje para el propietario: sin rutas, SHAs,
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
    cambio: "Se completó la detección de sesiones terminadas.",
    siguiente: "Terminar la corrección y comenzar la revisión.",
    necesita: "nada.",
  };
}

const EJEMPLO_APROBADO = `[AVANZA] Fase 14 — 46% (6/13 tareas)

Implementación — 75% (3/4)
Muse está corrigiendo el último caso del vigilante.

Revisión — 33% (1/3)
La primera revisión terminó; faltan la revisión cruzada y CodeRabbit.

Cierre — 0% (0/2)
Todavía no comienza.

Que cambió:
Se completó la detección de sesiones terminadas.

Que sigue:
Terminar la corrección y comenzar la revisión.

Que necesito de ti:
nada.
`;

describe("renderSeguimientoV2", () => {
  it("renders the approved example byte for byte", () => {
    assert.equal(renderSeguimientoV2(entradaEjemplo()), EJEMPLO_APROBADO);
  });

  it("renders two phases in a single message with one question block", () => {
    const segunda: ResumenSeguimiento = {
      trabajoId: "fase:15",
      fase: "15",
      titulo: "Fase 15",
      progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
      carriles: [
        carril("A", "Trabajo", "implementando",
          { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
          "Avance en curso."),
      ],
      siguientePaso: "Cerrar el pendiente.",
      atencionRequerida: { necesaria: false, motivo: null },
      actualizado: "2026-09-19T10:30:00Z",
    };
    const text = renderSeguimientoV2({ ...entradaEjemplo(), fases: [fase14(), segunda] });
    assert.match(text, /\[AVANZA\] Fase 14 — 46% \(6\/13 tareas\)/);
    assert.match(text, /\[AVANZA\] Fase 15 — 50% \(1\/2 tareas\)/);
    assert.equal(text.match(/Que cambió:/g)?.length, 1);
    assert.equal(text.match(/Que sigue:/g)?.length, 1);
    assert.equal(text.match(/Que necesito de ti:/g)?.length, 1);
    assert.ok(text.endsWith("\n"));
  });

  it("renders 0% and 100% with auditable fractions", () => {
    const vacia: ResumenSeguimiento = {
      ...fase14(),
      progreso: { kind: "conocido", completadas: 0, total: 2, porcentaje: 0 },
      carriles: [
        carril("C", "Cierre", "pendiente",
          { kind: "conocido", completadas: 0, total: 2, porcentaje: 0 },
          "Todavía no comienza."),
      ],
    };
    const llena: ResumenSeguimiento = {
      ...fase14(),
      progreso: { kind: "conocido", completadas: 2, total: 2, porcentaje: 100 },
      carriles: [
        carril("C", "Cierre", "mergeado",
          { kind: "conocido", completadas: 2, total: 2, porcentaje: 100 },
          "Cierre entregado."),
      ],
    };
    const text = renderSeguimientoV2({ ...entradaEjemplo(), fases: [vacia, llena] });
    assert.match(text, /Fase 14 — 0% \(0\/2 tareas\)/);
    assert.match(text, /100% \(2\/2 tareas\)/);
  });

  it("renders unknown plans as desconocido, never as zero", () => {
    const desconocida: ResumenSeguimiento = {
      ...fase14(),
      progreso: { kind: "desconocido", motivo: "plan-sin-verificar" },
      carriles: [
        carril("M", "Implementación", "implementando",
          { kind: "desconocido", motivo: "plan-sin-verificar" },
          "Muse está corrigiendo el último caso del vigilante."),
      ],
    };
    const text = renderSeguimientoV2({ ...entradaEjemplo(), fases: [desconocida] });
    assert.match(text, /Fase 14 — desconocido/);
    assert.match(text, /Implementación — desconocido/);
    assert.doesNotMatch(text, /0%/);
  });

  it("emits owner language without paths, SHAs, PR numbers, flags or backticks", () => {
    const text = renderSeguimientoV2(entradaEjemplo());
    assert.doesNotMatch(text, /`/);
    assert.doesNotMatch(text, /--\w/);
    assert.doesNotMatch(text, /#\d/);
    assert.doesNotMatch(text, /\b[0-9a-f]{7,64}\b/);
  });

  it("with no change in the window says work continues with elapsed minutes and evidence", () => {
    const ahora = Date.parse("2026-09-19T11:05:00Z");
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      ahora,
      cambio: "",
      fases: [{
        ...fase14(),
        carriles: [
          {
            ...fase14().carriles[0],
            actividad: {
              detalle: "Muse está corrigiendo el último caso del vigilante.",
              iniciadaEn: "2026-09-19T10:20:00Z",
              ultimaEvidencia: "el caso del vigilante quedó en verde local",
            },
          },
        ],
      }],
    });
    assert.match(text, /sigue en curso/);
    assert.match(text, /45 minutos/);
    assert.match(text, /el caso del vigilante quedó en verde local/);
    assert.doesNotMatch(text, /nada nuevo/i);
  });

  it("with only a carril-less conservative phase and no change renders the safe continuity phrase", () => {
    const conservadora: ResumenSeguimiento = {
      trabajoId: "fase:14",
      fase: "14",
      titulo: "Fase 14",
      progreso: { kind: "desconocido", motivo: "plan-sin-verificar" },
      carriles: [],
      siguientePaso: "",
      atencionRequerida: { necesaria: false, motivo: null },
      actualizado: "2026-09-19T10:30:00Z",
    };
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      cambio: "",
      fases: [conservadora],
    });
    assert.match(text, /Fase 14 — desconocido/);
    assert.match(text, /Que cambió:\nEl trabajo sigue bajo seguimiento: sin lectura nueva del avance en esta ventana\./);
    assert.doesNotMatch(text, /minutos en la unidad actual/);
    assert.doesNotMatch(text, /última evidencia/);
  });

  it("renders standalone tasks after the phases", () => {
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      tareasSueltas: [{
        nombre: "Migración del reloj",
        progreso: { kind: "conocido", completadas: 1, total: 4, porcentaje: 25 },
        actividad: {
          detalle: "En curso sin bloqueo.",
          iniciadaEn: "2026-09-19T10:00:00Z",
          ultimaEvidencia: "evidencia",
        },
      }],
    });
    assert.match(text, /Migración del reloj — 25% \(1\/4\)/);
  });

  it("never renders omitted lanes", () => {
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      fases: [{
        ...fase14(),
        carriles: [
          ...fase14().carriles,
          carril("O", "Superficie vieja", "omitido",
            { kind: "conocido", completadas: 0, total: 1, porcentaje: 0 },
            "Cancelado por el lead."),
        ],
      }],
    });
    assert.doesNotMatch(text, /Superficie vieja/);
  });

  it("rejects empty input and invalid timestamps", () => {
    assert.throws(() => renderSeguimientoV2({ ...entradaEjemplo(), fases: [], tareasSueltas: [] }));
    assert.throws(() => renderSeguimientoV2({ ...entradaEjemplo(), ahora: Number.NaN }));
    assert.throws(() => renderSeguimientoV2({
      ...entradaEjemplo(),
      cambio: "",
      ahora: Date.parse("2026-09-19T11:05:00Z"),
      fases: [{
        ...fase14(),
        carriles: [{
          ...fase14().carriles[0],
          actividad: {
            detalle: "x",
            iniciadaEn: "no-es-una-fecha",
            ultimaEvidencia: "y",
          },
        }],
      }],
    }));
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
    const entrada: EntradaSeguimientoV2 = {
      fases: [{
        ...fase14(),
        carriles: [
          { ...fase14().carriles[0], nombre: "Mira foo.ts", actividad: { detalle: sucio, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: sucio } },
        ],
      }],
      tareasSueltas: [{
        nombre: "suelta feat/watchdog",
        progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 },
        actividad: { detalle: sucio, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: sucio },
      }],
      ahora: Date.parse("2026-09-19T11:00:00Z"),
      cambio: sucio,
      siguiente: sucio,
      necesita: sucio,
    };
    const text = renderSeguimientoV2(entrada);
    for (const prohibido of ["/tmp/x", "foo.ts", "feat/watchdog", "abcdef1", "PR #104", "--force", "`comando`", "commit"]) {
      assert.doesNotMatch(text, new RegExp(prohibido.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), `fuga tecnica: ${prohibido}`);
    }
    assert.match(text, /Que cambió:/);
    assert.match(text, /Que sigue:/);
    assert.match(text, /Que necesito de ti:/);
  });

  it("falls back to state-derived descriptions without inventing progress", () => {
    const text = renderSeguimientoV2({
      ...entradaEjemplo(),
      fases: [{
        ...fase14(),
        carriles: [
          { ...fase14().carriles[0], actividad: { detalle: "mira /tmp/x", iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: "ok" } },
        ],
      }],
      cambio: "cierra PR #104",
      siguiente: "corre --force",
      necesita: "mira foo.ts",
    });
    assert.doesNotMatch(text, /\/tmp\/x/);
    assert.doesNotMatch(text, /PR #104/);
    assert.doesNotMatch(text, /--force/);
    assert.doesNotMatch(text, /foo\.ts/);
    assert.match(text, /En implementando\./);
  });

  it("rejects technical text in every interpolated field independently", () => {
    const tecnico = "Ejecutar git status y npm test";
    const base = entradaEjemplo();
    const variantes: Array<[string, EntradaSeguimientoV2]> = [
      ["detalle", { ...base, fases: [{ ...fase14(), carriles: [{ ...fase14().carriles[0], actividad: { detalle: tecnico, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: "ok" } }] }] }],
      ["suelta", { ...base, tareasSueltas: [{ nombre: tecnico, progreso: { kind: "conocido", completadas: 1, total: 2, porcentaje: 50 }, actividad: { detalle: tecnico, iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: tecnico } }] }],
      ["cambio", { ...base, cambio: tecnico }],
      ["siguiente", { ...base, siguiente: tecnico }],
      ["necesita", { ...base, necesita: tecnico }],
      ["evidencia", { ...base, cambio: "", fases: [{ ...fase14(), carriles: [{ ...fase14().carriles[0], actividad: { detalle: "ok", iniciadaEn: "2026-09-19T10:20:00Z", ultimaEvidencia: tecnico } }] }] }],
    ];
    for (const [campo, entrada] of variantes) {
      const text = renderSeguimientoV2(entrada);
      assert.doesNotMatch(text, /git status/, `fuga por ${campo}`);
      assert.doesNotMatch(text, /npm test/, `fuga por ${campo}`);
    }
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

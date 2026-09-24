// Doble de "gateway call runbook.progress.decide" para --ensayo (9.9, pieza
// c): en vez de fabricar una respuesta cualquiera, corre el MODULO PURO real
// (tablero-runbook/seguimiento-clock.ts, decidirSeguimiento) con el estado
// sintetico que el arnes arma para los casos 4 y 7. Nunca toca disco ni red:
// decidirSeguimiento no hace ninguna de las dos.
//
// Entrada por stdin: {"modo":"tick","ahora":<epoch>,"estado":<EstadoSeguimiento>,
// "inmediato":<EventoInmediato|null>}. Salida por stdout: el JSON de
// DecisionSeguimiento (accion NO_REPLY o SEND).
//
// "activas" siempre trae un resumen sintetico (no hay un runbook real detras
// en --ensayo): sin el, la rama "periodico" (caso 7) nunca se alcanzaria
// (decidirSeguimiento sale NO_REPLY de inmediato si activas y sueltas estan
// vacias) y la rama "inmediato" (caso 4) no lo necesita, asi que no le hace
// dano tenerlo tambien ahi.
import { decidirSeguimiento } from "../../../../tablero-runbook/seguimiento-clock.ts";

let raw = "";
for await (const chunk of process.stdin) raw += chunk;

let req;
try {
  req = JSON.parse(raw);
} catch {
  process.stderr.write("decide-puro: stdin no es JSON valido\n");
  process.exit(1);
}

const ahora = Number.isFinite(req.ahora) ? req.ahora : Math.floor(Date.now() / 1000);
const activas = [
  {
    trabajoId: "corrida:sim9-fixture",
    fase: "9",
    titulo: "Simulacro 9.9",
    progreso: { kind: "conocido", completadas: 0, total: 1, porcentaje: 0 },
    carriles: [],
    siguientePaso: "corriendo el simulacro",
    atencionRequerida: { necesaria: false, motivo: null },
    actualizado: new Date(ahora * 1000).toISOString(),
  },
];

try {
  const r = decidirSeguimiento({
    ahora,
    previo: req.estado,
    activas,
    sueltas: [],
    inmediato: req.inmediato ?? null,
    problemas: [],
  });
  process.stdout.write(JSON.stringify(r));
} catch (err) {
  process.stderr.write(`decide-puro: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
}

# corrida-aviso.v1 — aviso de corrida con pendiente durable

Fecha: 2026-09-29 (19.1 B2). Estado: activo en el código desde el merge;
sin instalar en el host (la instalación y sus veinte transiciones son 19.2).
Extiende [corrida.v2.md](corrida.v2.md) sin tocar su validador. Fuente de
verdad del aviso: el almacenamiento de la propia corrida. No hay servicio,
cron ni aplicación nuevos: emiten el vigilante y el hook existentes, decide
el director existente (`reconciliar`), y el reloj de reintento es el tick
del vigilante.

## Forma

Un JSON por aviso en `$CORRIDA_STATE/<corrida>/avisos/<id>.json`:

| Campo | Qué es |
|---|---|
| `schema` | Siempre `corrida-aviso.v1` |
| `id` | `<corrida>-<sesion>-<tipo>-<sha1 de 10 de la llave>`; la misma señal con la misma llave produce el mismo id (dedupe por identidad) |
| `corrida`, `sesion`, `rol`, `cli` | Identidad de la ejecución; `rol` y `cli` los llena `emitir` desde el registro, nunca el emisor |
| `tipo` | `fin-turno` (quietud o Stop), `aprobacion` (diálogo en pantalla), `cierre` (proceso terminado) |
| `creado` | Época en ms |
| `detalle` | Referencia de hasta 200 caracteres; sin transcripts, pantallas ni texto libre de instrucciones |

La **llave** la aporta el adaptador y es la identidad del episodio: el
vigía usa el hash de las líneas que casan `APPROVAL_RE` (no la cola
completa: el repintado del TUI la cambia y rompería el dedupe), el hash de
pantalla para quietud, y el hook Stop el mtime del transcript. El tratado
vive en `avisos/tratados/<id>.json` con `atendido` (ms) o `descartado`
(motivo). El reclamo es el rename al director `tratados/`: atómico, dos
consumidores concurrentes no duplican.

## Ruta

1. **Emitir** (`corrida.sh avisos emitir <corrida> <sesion> <tipo> --llave <cadena>`):
   bajo lock del registro valida corrida abierta y sesión registrada (una
   sesión ajena o una corrida cerrada no emiten), deduplica por id, escribe
   el pendiente y despierta al dueño. El pendiente existe ANTES del
   despertar: si el despertar no aterriza, el aviso no se pierde.
2. **Despertar**: send-keys a la sesión lead registrada de la corrida —
   `corrida.sh avisos atender <corrida>` — solo si su panel no muestra
   diálogo de aprobación (dueño ocupado: el pendiente espera). El vigilante
   reintenta una vez por tick, con tope de 5 corridas y pendientes de más de
   30 s (`avisos despertar`): el tick existente es el único reloj de
   reintento. La señal entregada por la ruta de avisos sigue anotándose en
   `eventos.jsonl` del vigilante (el diario local que un vigía lee sin pasar
   por el gateway): pendiente durable y diario no se excluyen.
3. **Atender** (`corrida.sh avisos atender <corrida>`): lo corre el dueño
   (lead de la corrida), nunca un hook ni el vigilante en paralelo. Reclama
   los pendientes por rename, revalida bajo lock (corrida abierta, sesiones
   aún registradas: un aviso tardío o de sesión retirada queda descartado
   con motivo), marca atendidos y corre UNA vez `reconciliar <corrida>`,
   que revalida intento, evidencia y permisos y registra la reserva antes
   de lanzar al siguiente trabajador. Un aviso repetido y un tick
   simultáneo convergen en el mismo resultado: el id deduplica y el
   reconciliar es el único lanzador.
4. **Reversa**: `CORRIDA_AVISOS=0` deja emitir/atender/despertar en no-op y
   el vigilante y el hook vuelven a la ruta de eventos de siempre
   (`agent:main:sim9-<id>` o `agent:main:vigia-mac`), con un solo vigilante.

## Quién es el dueño (cierre del hueco 19.6)

El dueño del aviso es la sesión **lead registrada de la corrida**, que vive
en el host de las CLI: la ruta de despertar es local (send-keys de tmux),
probada en las suites con dobles. El agente del gateway (`agent:main:*`)
queda como notificado, no como decisor: sus `exec` no alcanzan el host de
las CLI (medido en 19.0-r2). La limitación de r2 queda así cerrada por
diseño: la decisión y el lanzamiento ocurren donde están las manos.

## Descartes y límites escritos

- `acceptEdits` de claude no cubre terminal: se descarta ampliarlo en este
  bloque. Es política de permisos del registro (decisión de David), no parte
  de la ruta de avisos; ningún aviso ejecuta terminal. Si un encargo exige
  terminal en un worker claude, la señal de aprobación seguirá el camino de
  `aprobacion` ya cubierto.
- El aviso no certifica éxito ni concede permisos: acredita la señal. La
  validez de la entrega la revalida el director con el intento vigente.
- Un aviso lleva identificadores, no pantallas: los textos de panel que el
  vigilante adjunta hoy en sus eventos quedan en el log del vigilante,
  fuera del pendiente.

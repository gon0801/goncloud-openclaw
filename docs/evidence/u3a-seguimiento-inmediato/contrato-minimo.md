# Contrato mínimo del aviso y decisión de la fusión cli-eventos (19.0)

Fecha: 2026-09-29. Para decisión de David. Completa a
`inventario-y-senales.md` y `transiciones-base.md` del mismo directorio.

## La medición que sostiene la decisión

Lo instalado al cerrar U3 ya resuelve tres cosas que cli-eventos pedía, y lo
medido el 2026-09-29 lo muestra con la ruta real corriendo:

- La vigilancia sin novedades ya no consume modelos: el vigía observa, el
  latido es un job del propio vigilante y el reloj global del director es
  `avance-tick.mjs`, un job de comando sin modelo (PR #211).
- Los eventos de máquina ya salen del Telegram de David hacia
  `agent:main:vigia-mac`, con recordatorios cada 60 min (PR #214). En la
  medición, el hook Stop de claude disparó hacia allí y su envío fue
  recibido por el doble, con coste de modelo cero (prueba de disparo, no de
  entrega real).
- El relevo de una sesión caída ya corre sin modelo, con marca atómica
  anti-duplicado (PR #212): sesión viva de nuevo en 0.54-2.09 s locales y
  primera actividad del sucesor en 1.05-2.61 s; la continuación con
  `resume` medida por U3 en 38 s punta a punta (práctica 14.13).

Lo que sigue sin resolver, por lo medido:

1. Solo claude tiene señal inmediata cableada (hook Stop), y avisa a un
   canal sin identidad de corrida (`vigia-mac`, texto libre, sin
   `sim9-<id>`). En la corrida de grok, además, un claude delegado dentro
   del árbol del worker disparó ese hook como si fuera el fin del
   trabajador: el aviso tampoco distingue quién entrega.
2. Las demás CLI dependen de la quietud: hasta `QUIET_SECS=900` s más tick.
3. Ningún aviso lleva identidad de encargo: ni corrida/carril/ejecución ni
   generación. Un nombre de sesión reutilizado no identifica la ejecución, y
   el destino no puede validarse contra el registro.
4. El aviso se declara entregado al aceptarlo el gateway; no hay pendiente
   durable antes de enviar. La deduplicación de aprobaciones existe pero su
   clave es la suma del texto visible de las últimas 15 líneas
   (`tmux-activity-watch.sh:473-481`): el repintado del TUI la rompe y
   produce un aviso por tick mientras el diálogo persista, sin acotarse por
   episodio.
5. El pendiente no se conserva hasta que el dueño lo trata: si el gateway
   acepta y pierde la respuesta, el aviso se perdió.

## Opción elegida (se defiende, y se corrige en un punto)

**Se conserva** `agent:main:vigia-mac` como canal de transporte de eventos de
máquina. Lo instalado en #214 queda; la quietud ya cuesta cero modelos.
`vigia-mac` no decide ni abre sesión para observar.

**Se adopta** de cli-eventos solo lo que falta, sin plugin de gateway, sin
`pumpPending`, sin transporte SSH nuevo y sin tocar crons (el DoD de 19.1
prohíbe nuevo servicio, cron o aplicación):

- Identidad de encargo en cada aviso: corrida, carril, ejecución, generación
  e instancia de terminal. El hook de claude y cada adaptador la añaden; el
  texto libre queda como pista, no como identidad.
- Pendiente durable antes de enviar: el aviso se escribe en el almacenamiento
  de la corrida antes de tocar el transporte, y vive hasta que el dueño
  registra su tratamiento (no solo hasta que el envío responde).
- Deduplicación por identidad: el mismo aviso repetido, el hook y el tick
  convergen en un solo siguiente paso; un diálogo de permisos es un episodio
  con un aviso y su recordatorio, no uno por tick.
- Un solo dueño director que reclama: el aviso despierta a la sesión real
  solicitante (`agent:main:sim9-<corrida>`); el dueño reclama, revalida
  corrida abierta e intento vigente, y reserva el siguiente paso antes de
  lanzar. Ya existe: es el lock y la reserva de `reconciliar`.
- Sobre acotado: identificadores y referencias verificables; sin transcripts,
  pantallas, credenciales ni texto libre con instrucciones.

**El choque se resuelve así**: cli-eventos pedía registrar la sesión real y
no abrir otra para observar; #214 manda los eventos a `vigia-mac`. Son
compatibles si cada aviso lleva la identidad de la sesión real solicitante y
el dueño director es quien reclama y decide. En la práctica: los avisos con
marca de corrida van a `sim9-<id>` (el vigía ya lo hace); el hook de claude
deja de ser el único camino ciego y gana la misma identidad; `vigia-mac`
queda para lo que no tiene corrida. Razón: respeta las dos decisiones de
David (fusión 2026-09-29 y #214) sin reescribir el director, y la medición
muestra que el hueco está en la identidad y en el pendiente, no en el
transporte.

**Corrección a la opción propuesta**: la propuesta decía "vigia-mac como
canal" sin fijar qué pasa con el hook Stop. Medido que el hook avisa a
`vigia-mac` sin identidad, el contrato mínimo exige que los adaptadores
normalicen también el hook al aviso común con identidad de corrida; si no,
la única señal inmediata seguiría sin llegar al dueño de la corrida.

**Sobra (fuera de 19.x)**: bandeja `cli-events/` del gateway, `MainAdmission`,
cambio de crons u3/revisor, canary de 72 h. El gateway de ensayo de la PC
(puerto 18790) y el worktree
`/Users/dn/dev/wt-goncloud-openclaw-cli-eventos` se conservan como evidencia;
no se borran.

## Conexión mínima con los contratos entregados por U3

- **Registro**: `workers.v1.json` sigue siendo la fuente de ejecutables,
  argv, patrones y modos. Una CLI nueva se incorpora con su fila de
  `cli-modos.tsv` y su worker; el director no aprende marcas nuevas.
- **Registro de corrida** (`corrida.v2`): el aviso vive en el almacenamiento
  de la corrida (`CORRIDA_STATE/<id>/`), usa el lock existente del registro
  y sus carriles (`lanes`, reserva `branch/worktree/base/owner/mode`). No
  crea otra fuente de verdad ni otro esquema de registro.
- **Seguimiento** (`seguimiento.v2`): el reloj global de 15 min y el corte
  consolidado de 30 no cambian; el aviso interno no añade mensajes de
  Telegram por transición.
- **Director**: `reconciliar` conserva la decisión y la reserva del siguiente
  paso. Los hooks y el vigía siguen siendo notificadores. El pendiente es la
  pieza nueva; su lector es el dueño que ya reclama con lock.

## Límites

- Sin nuevo servicio, cron ni aplicación (DoD 19.1). Sin plugin en el
  gateway. Sin tocar el motor de selección, el panel, las compuertas de merge
  ni la política de Telegram.
- La aceptación del gateway no acredita actuación del dueño; por eso el
  pendiente solo se cierra con el registro de tratamiento del dueño.
- La compactación de main con reinicio diario es configuración del gateway
  (Windows): declarada, no verificable desde esta Mac.

## Pruebas y validación

- Las señales y tiempos de esta medición se reproducen con
  `arnes/medir.sh <token> --relanzo` (una CLI por corrida, dobles locales).
- Los contratos vivos que 19.1 no puede romper:
  `scripts/tests/test-tmux-activity-watch.sh`,
  `scripts/tests/test-corrida-reconcile.sh`,
  `scripts/tests/test-instalar-mac.sh`, `scripts/tests/test-cli-modos.sh`,
  `pre-commit` y la batería de `scripts/run-checks.sh` en CI.
- Pruebas nuevas que el contrato mínimo exige en 19.1: aviso con identidad
  duplicado, aviso de generación vieja, hook más tick simultáneos, pendiente
  vivo tras envío aceptado sin respuesta, aviso sin pertenencia a la corrida
  rechazado, y un adaptador de prueba con otro nombre usando la ruta común
  sin cambios en el director.

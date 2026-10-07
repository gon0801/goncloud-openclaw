# seguimiento.v2 — corte de avance para el propietario

Fecha: 2026-09-20; forma corta desde el 2026-10-07. Define el mensaje que
David recibe mientras hay trabajo activo. David no programa: el corte le dice
si el trabajo va bien, qué se está haciendo y si le toca hacer algo.
`seguimiento.v1` queda para los avisos inmediatos de cuatro líneas y los
registros viejos.

## Forma

```text
Sin novedad: todo sigue en curso.
Encargos durables de agentes: 4 de 6 partes.
Ahora: integración y matriz (último movimiento hace 50 minutos). Atorada: adopción preparada.
revisor-correcciones: 8 de 13 partes.
Ahora: instalador (último movimiento hace 2 horas).
No necesito nada de ti.
```

Ese ejemplo es el caso real del 2026-10-07. Con la forma anterior ocupaba más
de 60 líneas: listaba una por una las 19 partes de los dos trabajos y dejaba
pasar texto interno de los agentes.

## Reglas

- **Línea 1, la novedad.** Frases fijas armadas con conteos y estados, nunca
  con texto libre de un agente: un trabajo entró al seguimiento, terminó una o
  más partes, cambió su cuenta de partes, tiene una parte atorada, destrabó
  una parte, necesita o ya no necesita respuesta, su avance dejó de ser
  verificable o volvió a serlo, un trabajo ya no está activo (se cerró o
  lleva más de un día sin moverse), o cambiaron las tareas sueltas. En un latido sin cambios dice
  `Sin novedad: todo sigue en curso.`
- **Dos líneas por trabajo, como máximo.**
  - `<nombre>: <c> de <n> <partes|tareas>.` La fracción sale de las unidades
    del plan (`resumirSeguimiento`); ningún modelo la estima. Un plan no
    verificable se escribe `avance desconocido`, nunca `0`. Una corrida se
    nombra por su título, o por su id si el título trae jerga; una fase real
    sigue siendo `Fase N`.
  - Qué pasa ahora: `Ahora: <partes en curso>`, con el tiempo desde su último
    movimiento cuando solo hay una; si ninguna está en curso, `Sigue: <la
    próxima pendiente>`; si todas terminaron, `Todas las partes terminadas;
    falta cerrarlo.` Las atoradas van al final: `Atorada: <nombre>.`
- **Las partes terminadas y las pendientes no se listan una por una.** Ya las
  cuenta la fracción. Una parte `omitido` (trabajo cancelado) nunca aparece.
- **Nombre de una parte.** Se le quita el código inicial (`B4 integración y
  matriz` da `integración y matriz`). Si lo que queda trae texto técnico, se
  escribe `la parte <k>`, con k igual a su posición entre las no omitidas.
- **Última línea.** `No necesito nada de ti.` o `Necesito de ti: <motivo>.`
  Un motivo con texto técnico cae a `Tienes una decisión pendiente.`
- Sin etiquetas entre corchetes, sin porcentajes, sin líneas en blanco, sin
  horas absolutas, sin rutas, ramas, hashes, números de PR, flags ni siglas.
- No salen el detalle, la última evidencia ni el siguiente paso que escriben
  los agentes: son texto libre y el límite de lenguaje no alcanza a filtrarlo
  (medido: `esperar LISTO-B4-23-r1` pasó entero).

## Límite de lenguaje (`sanearTextoPropietario`)

Todo texto que viene de un documento (nombre de parte, nombre de tarea
suelta, motivo de atención) pasa por el límite antes de imprimirse. Lo que
trae texto técnico no sale: el nombre cae a `la parte <k>` o `Tarea <k>` y el
motivo a la frase fija. Las fracciones (`6 de 13`), los acentos y el lenguaje
natural válido pasan siempre. Casos en `seguimiento-render.test.ts`, incluidos
el ejemplo aprobado y el caso real, byte por byte.

## Implementación

`tablero-runbook/seguimiento-render.ts` (`renderSeguimientoV2`): puro, sin
I/O. Recibe las novedades ya armadas por el reloj. Rechaza el insumo vacío y
un `ahora` inválido; una fecha de actividad ilegible solo omite el tiempo.

## Reloj y scratch (`seguimiento-clock.v1`)

La vigilancia interna corre cada 15 minutos; el consolidado sale en esa
cuadrícula, como mucho uno por ventana de 25 minutos (R12) y solo si hay
novedad desde el último corte enviado: cambió el conteo de un trabajo, el
conjunto de trabajos activos, las partes atoradas o el estado de atención.
Sin novedad el tick termina `NO_REPLY`; a las 4 horas del último corte sale un
latido (`LATIDO_SIN_NOVEDAD_SECS`), para que el silencio no se confunda con un
reloj muerto. En cuadrícula sana el primer tick que cumple la ventana es el de
+1800 desde el corte, y un tick desfasado del cron que caiga entre 1500 y 1800
también la cumple (tolerancia de desfase). `tablero-runbook/seguimiento-clock.ts` (`decidirSeguimiento`) es puro: dadas
la época actual (en segundos), los resúmenes activos, las tareas sueltas, el
último estado confirmado y un eventual evento inmediato, devuelve `NO_REPLY`
o `SEND` (`periodico` o `inmediato`). Nunca llama a Telegram, al disco ni al
reloj.

El corte vive en el scratch de la automatización global `avance-tareas`, con
esta forma (`schema: "seguimiento-clock.v1"`):

- `corte`: `{kind:"esperando-primer-reporte", inicioVentana}` o
  `{kind:"reporte-confirmado", ultimoReporteConfirmado}` (época en segundos).
- `ultimoEstado`: resumen estable del último corte confirmado (por trabajo:
  conteos, partes atoradas y si pide atención); contra él se calcula la
  novedad. Un silencio no lo mueve: lo que cambie mientras tanto sale junto en
  el siguiente corte. Un estado guardado que no se puede comparar manda un
  corte normal una vez; uno anterior a esta forma se compara solo por conteos.
- `ultimoInmediato`: la condición inmediata tratada, identificada por su
  `firma` estable, o `null` si no hay ninguna activa. Para la atención
  pendiente lleva además `entregados`, una firma por pendiente ya avisado: un
  tick manda solo los pendientes nuevos, y uno ya entregado no vuelve a salir
  porque otro aparezca, cambie o desaparezca (medido el 2026-10-07: la firma
  era del conjunto y cada cambio reenviaba el paquete entero). Un trabajo
  rancio se pregunta una vez mientras siga rancio. Un scratch sin `entregados`
  cuenta su conjunto firmado como ya avisado. La lista se guarda con el
  siguiente envío confirmado, porque un tick callado no escribe: un pendiente
  que se libera y vuelve antes de ese envío sigue contando como avisado (para
  David nunca dejó de estar pendiente); después de él, es un aviso nuevo. El `messageId` de su
  entrega es el del nivel superior del estado; el campo `messageId` anidado
  queda como legado: siempre `null` en escrituras nuevas y aceptado al leer
  por compatibilidad con scratches viejos. Vive separado
  del corte periódico: confirmar un inmediato no mueve
  `ultimoReporteConfirmado`, y un inmediato confirmado no silencia el próximo
  corte debido. Cuando la condición desaparece, el tick la registra inactiva
  (`null`); si vuelve, es un evento nuevo y sale otra vez.
- `messageId`: el del último Telegram confirmado, o `null`.
- `trabajosActivos`: los `trabajoId` del corte.

Reglas del corte:

- La creación llama una vez a `runbook.progress.decide` en `modo:"iniciar"`
  con `estado:null` y persiste de inmediato el `NO_REPLY` devuelto: así el
  primer tick (+15) y el segundo (+30) comparten la base.
- Solo `modo:"iniciar"` crea estado. En `modo:"tick"`, un scratch ausente o
  malformado devuelve `{ok:false, razon:"estado-invalido"}`: nunca reinicia
  el corte en silencio.
- Un `SEND` devuelve `estadoTrasConfirmar` sin `messageId`. Quien llama lo
  combina con el `messageId` y persiste el estado completo solo tras `ok:true`
  más `messageId`. Un envío fallido deja el scratch anterior intacto y el
  siguiente tick reintenta.
- Confirmar un periódico avanza el corte a la época actual; confirmar un
  inmediato conserva el corte y solo actualiza la deduplicación y el conjunto
  activo. Cerrar una fase la saca del próximo corte sin posponer el reporte
  debido de las demás.
- Sin trabajo activo y sin evento inmediato, el tick termina `NO_REPLY`.
- Un archivo que nombra una fase o corrida pero no se puede leer, parsear o
  validar no desaparece: `runbook.progress.list` conserva su `trabajoId` con
  un resumen conservador (`desconocido`, sin carriles) y su causa en
  `problemas` (`ilegible`, `json-invalido`, `documento-invalido`), sin exponer
  contenido crudo. `decidirSeguimiento` lo convierte en `DETENIDA` inmediata
  en formato `seguimiento.v1` exacto (deduplicada tras confirmar) sin mover
  el corte periódico; el reloj se conserva hasta verificarlo.
- Una fase con `atencion_requerida.necesaria` deriva `NECESITO TU RESPUESTA`
  inmediato en formato `seguimiento.v1` exacto del propio resumen, antes del
  corte y sin reclasificación manual. El motivo se sanea; si cambia, sale un
  nuevo aviso; confirmado, no se repite. Tampoco mueve el corte periódico.
- Un inmediato explícito del director debe cumplir `seguimiento.v1` con su
  etiqueta desde la frontera (`evento-invalido` si no); ya válido, se
  conserva intacto. Nunca sale crudo.
- `runbook.progress.decide` es la única entrada que la regla del director
  nombra; el agente no reproduce estas transiciones en prosa.

Quien llama en cada tick es `tablero-runbook/avance-tick.mjs`, el payload de
comando de `avance-tareas` (sin modelo): encuentra el cron por
`declarationKey`, pasa el scratch a `modo:"tick"`, manda el `SEND` por
`message send` y escribe `estadoTrasConfirmar` más `messageId` con la revisión
leída. `avance-tick.mjs iniciar` hace la creación sobre un scratch vacío. Solo
ve el trabajo que el gateway conoce (documentos de progreso de fases y
corridas); las tareas sueltas del director ya no entran al corte.

# seguimiento.v2 — reporte consolidado de 30 minutos

Fecha: 2026-09-20. Estado: activo desde que se mergea. Define el mensaje que
David recibe cada 30 minutos mientras haya trabajo activo. Conserva las
etiquetas y las tres preguntas de `seguimiento.v1`, pero permite bloques de
porcentaje entre el encabezado y esas preguntas. `seguimiento.v1` queda solo
para avisos inmediatos de cuatro líneas y registros viejos.

## Forma (v2)

```text
[AVANZA] Fase 14 — 46% (6/13 tareas)

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
```

## Reglas

- El encabezado muestra porcentaje y fracción. La fracción permite auditar el
  porcentaje redondeado. Los porcentajes salen de las unidades del plan
  (`resumirSeguimiento`); ningún modelo los estima.
- Si hay varias fases activas, el mismo mensaje trae un bloque por fase y un
  solo bloque de preguntas al final. No se crea un cron por agente ni un
  mensaje por carril.
- Aparecen los carriles no omitidos del corte: activos, pendientes, atorados
  y terminados. Un carril `omitido` (trabajo cancelado) nunca se imprime. Una
  fase grande no vuelca su tabla entera: quien arma el insumo pasa solo los
  carriles del corte.
- Un plan no verificable se escribe `desconocido`, nunca `0%`.
- `Que cambió` compara contra el último reporte enviado, no contra el inicio
  de la fase.
- `Que sigue` nombra la siguiente unidad verificable.
- `Que necesito de ti` es `nada` salvo cuando la etiqueta es
  `NECESITO TU RESPUESTA`.
- Si no hubo cambio durante la ventana, el reporte de 30 minutos sale igual
  porque confirma que el trabajo continúa. Dice cuánto tiempo lleva la unidad
  actual (minutos enteros desde `actividad.iniciadaEn`) y cuál fue la última
  evidencia observada; nunca dice "nada nuevo".
- Lenguaje para el propietario: sin rutas, ramas, hashes, números de PR,
  flags, siglas ni acentos graves.

## Límite de lenguaje (`sanearTextoPropietario`)

Todo campo interpolado (nombre y detalle de carril, actividad de tarea
suelta, `Que cambió`, `Que sigue`, `Que necesito de ti`, evidencia) pasa por
el límite antes de imprimirse. Lo que trae texto técnico no sale: el carril
usa una descripción derivada de su estado (`En implementando.`), el nombre
cae a `Carril <id>`, el cambio vacío cae al texto de continuidad, y `Que
sigue` / `Que necesito de ti` caen a frases seguras fijas. Las fracciones
(`6/13`), los porcentajes, los acentos y el lenguaje natural válido pasan
siempre. Casos en `seguimiento-render.test.ts`, incluido el ejemplo aprobado
byte por byte.

## Implementación

`tablero-runbook/seguimiento-render.ts` (`renderSeguimientoV2`): puro, sin
I/O. Rechaza el insumo vacío y las marcas de tiempo inválidas. Los casos
viven en `tablero-runbook/seguimiento-render.test.ts`, incluido el ejemplo
aprobado byte por byte.

## Reloj y scratch (`seguimiento-clock.v1`)

La vigilancia interna corre cada 15 minutos; el consolidado sale cada 30.
`tablero-runbook/seguimiento-clock.ts` (`decidirSeguimiento`) es puro: dadas
la época actual (en segundos), los resúmenes activos, las tareas sueltas, el
último estado confirmado y un eventual evento inmediato, devuelve `NO_REPLY`
o `SEND` (`periodico` o `inmediato`). Nunca llama a Telegram, al disco ni al
reloj.

El corte vive en el scratch de la automatización global `avance-tareas`, con
esta forma (`schema: "seguimiento-clock.v1"`):

- `corte`: `{kind:"esperando-primer-reporte", inicioVentana}` o
  `{kind:"reporte-confirmado", ultimoReporteConfirmado}` (época en segundos).
- `ultimoEstado`: resumen estable (identificadores de trabajo, conteos y
  porcentajes por fase) del último corte confirmado; contra él se calcula el
  `Que cambió`.
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
  (deduplicada tras confirmar) sin mover el corte periódico; el reloj se
  conserva hasta verificarlo.
- Una fase con `atencion_requerida.necesaria` deriva `NECESITO TU RESPUESTA`
  inmediato del propio resumen, antes del corte y sin reclasificación manual.
  El motivo se sanea; si cambia, sale un nuevo aviso; confirmado, no se
  repite. Tampoco mueve el corte periódico.
- `runbook.progress.decide` es la única entrada que la regla del director
  nombra; el agente no reproduce estas transiciones en prosa.

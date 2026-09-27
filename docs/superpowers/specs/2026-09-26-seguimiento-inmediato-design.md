# Seguimiento inmediato entre herramientas CLI

Estado: propuesta de U3a, posterior al cierre de U3 y anterior a U4.
Decisión de David del 2026-09-26: planear la mejora sin interrumpir U3.
[Plan de trabajo](../plans/2026-09-26-seguimiento-inmediato.md).

## Resultado esperado

Cuando cualquier agente CLI habilitado entrega su trabajo, Claw comprueba el
resultado y continúa por la ruta autorizada sin esperar el próximo chequeo
periódico. Muse y Claude son ejemplos del flujo, no una lista de agentes admitidos.

El objetivo es menos de 30 segundos entre la entrega del trabajador y la primera
actividad verificable del siguiente trabajador, cuando sus requisitos están
cumplidos. Este objetivo todavía no está probado. El aviso aceptado por el
gateway no acredita que Claw haya actuado.

U3a reutiliza los adaptadores, el registro, el director y el vigilante que entregue
U3. No agrega una aplicación, un orquestador, un servicio de colas ni otro reloj.
Los criterios de cierre y las autorizaciones de U3 permanecen iguales.

## Un contrato común para cualquier agente CLI

El alcance incluye todos los agentes CLI habilitados en el registro que entregue
U3, tanto implementadores como revisores. 19.0 conserva ese inventario y sus modos
de ejecución. Una CLI activa no se excluye para aprobar las mediciones.

Cada adaptador convierte una señal comprobada de su CLI al mismo aviso de fin.
El almacenamiento, el envío, la recuperación y la decisión del director son
comunes. No dependen de nombres como Muse o Claude ni del rol del trabajador.
Una CLI nueva se incorpora por el adaptador y el registro existentes, sin cambiar
el director ni agregar otra infraestructura de plugins.

La señal puede ser un hook nativo, un resultado estructurado o la terminación
observada por el lanzador cuando ese modo termina un proceso por encargo. Si el
modo interactivo no ofrece una señal comprobable, se registra la limitación y
se conserva el seguimiento previo. Eso no acredita seguimiento inmediato ni
permite cerrar U3a mientras afecte a una CLI habilitada. No se confunde silencio
con entrega ni se inventa un hook universal.

La misma prueba de contrato se ejecuta para cada adaptador habilitado. Una CLI
incorporada después del cierre necesita esa prueba y una medición real bajo el
mismo umbral antes de anunciar compatibilidad. No se promete soporte automático
para herramientas o modos que todavía no se han integrado.

## Hechos y preguntas pendientes

Base consultada: `origin/main` en `a90541d`. La medición inicial debe repetir
esta comprobación sobre el SHA que cierre U3.

| Componente | Hecho observado | Límite de la evidencia |
|---|---|---|
| `scripts/mac/tmux-activity-watch.sh` | `TICK_SECS` vale 15 por defecto. `QUIET_SECS` vale 900. `send_event` puede enviar a la sesión de una corrida. | No demuestra que la espera del usuario provenga de esos 900 segundos. |
| `scripts/mac/claude-stop-openclaw-event.sh` | Envía `system event --mode now`. No pasa la clave de sesión que usa el vigilante. Descarta la salida del envío. | Su configuración no demuestra entrega, destinatario correcto ni actuación del director. |
| `scripts/mac/corrida/adaptador.sh` | `adaptador_inspect` distingue estados y no considera el silencio como éxito. | Una marca en pantalla requiere comprobar el intento y su evidencia. |
| `scripts/mac/corrida/reconciliar.sh` | Requiere un solo director. Libera el lock del registro durante efectos externos. | Deduplicar avisos no permite ejecutar reconciliadores en paralelo. |
| Muse | Existe una entrada `muse` en `scripts/mac/cli-modos.tsv`. | El registro de workers consultado no tiene una entrada llamada Muse. Su identidad, modo y señal fiable de terminación se comprueban en 19.0. |

La copia instalada en la Mac consultada conserva los valores por defecto del
vigilante. Claude tiene una referencia al hook de aviso en su configuración.
No se ejecutó una tarea viva ni se midió su latencia durante esta planificación.

La investigación debe distinguir el tiempo de detección, transporte, espera del
director y arranque de la siguiente CLI. Una demora en cualquiera de esos pasos
puede producir el síntoma descrito.

## Opciones consideradas

| Opción | Decisión | Motivo |
|---|---|---|
| Acortar el silencio para todas las sesiones | Descartada como solución principal | Silencio no significa entrega. Puede generar avisos durante trabajo válido. |
| Reutilizar señales de fin y dirigirlas al dueño de la corrida | Elegida para comprobar | Aprovecha el hook y el vigilante existentes. Permite medir el recorrido completo. |
| Añadir otro supervisor o servicio de colas | Fuera de alcance | Duplica componentes sin demostrar que sean necesarios. |

Por ejemplo, para Claude el candidato es el evento `Stop`. Para Muse y las demás
CLI se comprueba la señal que su adaptador pueda observar en 19.0. Si no existe una señal
fiable, el plan registra la limitación antes de implementar. No se inventa un hook
ni se sustituye la prueba por una instrucción al modelo de que recuerde avisar.
El cierre de un proceso sólo sirve como señal si coincide con el modo de ejecución
medido. En una CLI interactiva, fin de proceso y fin de turno son distintos.

## Recorrido de un aviso

1. El adaptador reconoce una señal de fin de la ejecución observada.
2. La ruta existente guarda un aviso pendiente antes de intentar enviarlo.
3. El envío despierta al dueño registrado de esa corrida.
4. El dueño reclama el aviso y comprueba el intento, la entrega y sus requisitos.
5. El dueño registra el resultado del tratamiento y comienza el siguiente paso autorizado.

El aviso pendiente utiliza el almacenamiento de la corrida. No crea otra fuente
de verdad. Su identidad distingue corrida, carril, ejecución e instancia de turno
o entrega. Un nombre de sesión reutilizado no identifica la misma ejecución.
Los nombres concretos de campos y eventos se fijan contra el contrato entregado
por U3 en 19.0, antes de modificar sus validadores.

El destinatario se obtiene del registro. El payload no puede elegir otro agente,
una ruta de archivo o un comando. Una sesión personal o un aviso sin pertenencia
comprobada no provoca avance ni cae silenciosamente en la sesión general.
Los avisos contienen identificadores y referencias verificables; no incluyen
transcripts, pantallas, credenciales ni texto libre con instrucciones.

## Un solo dueño decide el siguiente paso

Los hooks y el vigilante sólo notifican. No invocan un reconciliador independiente
ni lanzan al revisor. El director de U3 conserva la decisión y registra una reserva
del siguiente paso antes del lanzamiento. Un aviso simultáneo o un tick periódico
encuentran la misma reserva y no lanzan otro trabajador.

Si el director está ocupado, conserva el aviso para tratarlo al quedar disponible.
La medición incluye esa espera. Si la cola del director impide cumplir el objetivo,
se registra como causa; acelerar sólo el envío no permite cerrar U3a.

El dueño vuelve a comprobar que la corrida esté abierta y que la ejecución siga
vigente antes de producir efectos. Un aviso antiguo o de una corrida cerrada no
reactiva trabajo. Si U3 incorpora pausa o cancelación, se respeta su control.
U3a no agrega esos estados ni adelanta el trabajo de U6.

Un `Stop`, un proceso terminado o una pantalla inmóvil no aprueban la entrega.
Una entrega válida puede iniciar revisión. Un error o una pregunta pendiente
continúan por la política existente. Una tarea final sin sucesor termina y no
inventa otro trabajo. Las compuertas de pruebas, revisión, merge y despliegue se
conservan, incluidas sus autorizaciones.

## Recuperación con el vigilante existente

El gateway puede aceptar un aviso y perderse la respuesta. Por eso el aviso
pendiente se conserva hasta que el dueño registre que lo trató, no sólo hasta
que el envío responda correctamente. El vigilante existente reintenta avisos
pendientes con la misma identidad y un ritmo acotado por su tick.

El hook y el vigilante convergen en la misma entrega. Un reinicio conserva el
pendiente y la reserva del siguiente paso. Si el lanzamiento tiene un resultado
incierto, el director observa la sesión y el registro antes de repetirlo.

Con gateway, director y capacidad disponibles, una pérdida de aviso debe
recuperarse en 60 segundos como máximo. Tras una caída del gateway, el plazo se
mide desde su recuperación comprobada. Si el límite no se cumple, se registra el
fallo. El sistema no presenta el tiempo caído como una transición normal.

El chequeo por silencio y el reloj global siguen siendo respaldo. El reporte
consolidado de 30 minutos no cambia. Un aviso interno no añade un mensaje de
Telegram por cada transición.

## Medición y criterios de aceptación

Cada transición registra estos puntos:

| Punto | Evidencia |
|---|---|
| Fin del trabajador | Señal fiable ligada a la ejecución y a la entrega observada. |
| Aviso pendiente | Escritura persistente completada. |
| Envío aceptado | Respuesta del transporte; no se interpreta como actuación. |
| Tratamiento por el dueño | Registro de reclamación y decisión. |
| Inicio del siguiente trabajo | Primera actividad de la siguiente CLI, posterior a la entrega del encargo. Crear el proceso o enviar teclas no basta. |

El fin y el siguiente inicio se miden con el mismo reloj monótono en el host de
las CLI. Si hay eventos en otro host, sus horas no se restan sin medir la diferencia
entre relojes. La evidencia declara resolución e incertidumbre. Las duraciones
afectadas por reinicios se identifican y no se inventan a partir de horas incompatibles.

La aceptación incluye:

- Al menos veinte transiciones reales, con al menos dos finalizaciones por cada
  CLI habilitada en 19.0 y cada una como destino al menos una vez. Se amplía la
  muestra si veinte no cubren el inventario. Incluye el flujo Muse a Claude y
  Claude al siguiente trabajador cuando esos agentes estén habilitados. Cada
  transición sin espera externa queda bajo 30 segundos. Las condiciones y el
  inventario se declaran antes de la prueba.
- Todas las muestras quedan registradas, incluidas fallidas y lentas. El reporte
  muestra mediana, máximo y cantidad bajo 30 segundos. Una espera del director
  no se elimina para mejorar el resultado.
- CI pendiente, falta de permiso, cuota o capacidad se muestran como esperas
  reales. No cuentan como éxitos rápidos. Las transiciones normales exigidas se
  completan además de esos casos y no se rebajan por falta de muestras.
- Avisos duplicados, aviso más tick simultáneos y reinicios producen un solo
  siguiente trabajador. Avisos antiguos, sesiones personales y corridas cerradas
  no producen avance. Preguntas, fallos y entregas incompletas no pasan por éxito.
- La pérdida de un aviso y la recuperación del gateway cumplen el límite de
  60 segundos. La tarea sin sucesor termina sin lanzar otra CLI.
- La instalación conserva un único vigilante, utiliza el instalador existente y
  permite volver al seguimiento previo sin perder el estado de las corridas.

Si 19.0 descubre que hace falta reescribir el director o añadir otro servicio,
la implementación se detiene y presenta el faltante. No amplía el bloque por su cuenta.

## Referencias comprobadas

- [Hooks de Claude](https://code.claude.com/docs/en/hooks#stop): `Stop` indica fin de respuesta, no aceptación del encargo.
- [Avisos de OpenClaw](https://docs.openclaw.ai/automation/cron-jobs/webhooks): solicitar despertar inmediato no acredita que el agente haya terminado su turno.
- [Diseño de U3](2026-09-19-native-harness-orchestration-design.md): director, adaptadores y recuperación existentes.
- [Contrato de corrida](../../spec/corrida.v2.md) y [seguimiento](../../spec/seguimiento.v2.md).
- `.saikit/decisiones/tmux-activity-watch.tsv`: el despertar por eventos y la exclusión de sesiones personales ya son decisiones del proyecto.

Las fuentes externas se consultaron durante esta conversación. 19.0 comprueba
compatibilidad con las versiones efectivamente instaladas después de U3.

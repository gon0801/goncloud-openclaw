# Fase 17: centro de tareas para OpenClaw y Hermes

Fecha: 2026-09-22. Estado: diseño propuesto, no implementado.
Plan: [Fase 17](../plans/2026-09-22-centro-tareas.md).
Contrato superior: [especificación del proyecto](../../spec/00-project-spec.md).

## Resultado para David

En cada computadora hay un panel con la misma experiencia. Una usa OpenClaw y
la otra Hermes. David elige a cuál encargarle una tarea. Cada instalación conserva
sus tareas, credenciales, sesiones y avisos; ninguna necesita a la otra.

El panel permite saber qué se pidió, quién responde, qué agente trabaja, qué CLI
se está ejecutando, qué falta, por qué espera y qué prueba acredita el resultado.
Cerrar el navegador no detiene el trabajo. La caída del coordinador no borra las
tareas ni deja al panel mostrando actividad antigua como si fuera actual.

La misma versión del sistema implica las mismas reglas y pruebas de aceptación.
No implica que dos modelos tomen decisiones idénticas, ni que cualquier goal
pueda terminar sin permisos, información o servicios externos.

## Límites

No hay cola central, estado replicado, elección automática de computadora,
transferencia de sesiones, failover entre hosts ni ejecución conjunta de una tarea.
No se reemplazan OpenClaw ni Hermes. No se incorpora OpenGrokBot como otro runtime.
No se copian credenciales, identidad de instalación ni memoria privada entre equipos.

La primera entrega es un panel de seguimiento de solo lectura. Los encargos se
dan mediante las entradas autenticadas existentes de cada agente. Botones para
crear, pausar, reintentar o cancelar quedan diferidos: necesitan un contrato de
control separado y autorización por operación. Un enlace a una sesión no envía
teclas ni ejecuta texto del navegador.

## Reutilización y dependencias

La Fase 14 ya posee registro y selección de workers, adaptadores CLI, worktrees,
capacidad, reconciliación, evidencias, entrega e instalación. En la base revisada
`31dfaf0` todas sus filas siguen pendientes. No se presume implementada.
La Fase 17 consume esas piezas; adapta sus fronteras dependientes de OpenClaw
para que Hermes opere solo. No introduce otro orquestador.

Antes de conectar ejecución se exige evidencia de las interfaces de Fase 14
mergeadas, sus pruebas y el manifiesto instalado. Hereda requisitos de Fases 9/15
y de entrega sin sello A/B/C. La instalación en Windows exige además la aceptación
del arreglo de Fase 16 cuando corresponda al host. El diseño y los fixtures de UI
pueden avanzar sin tocar máquinas vivas ni dar por cerradas esas fases.

Se mantienen `corrida.sh`, `corrida.v2`, `seguimiento.v2` y el escritor de progreso
del director. Hay un solo reloj local `avance-tareas`, con vigilancia cada 15
minutos, consolidado cada 30 y avisos excepcionales inmediatos. No hay cron por
tarea. La supervisión independiente debe reutilizar o sustituir de forma explícita
el mecanismo existente, sin dejar dos propietarios activos del reloj.

`runbook-progress.v2.md` describe campos aditivos pero el validador vivo exige
el literal `runbook-progress.v1`. Se preservan ese literal y las rutas antiguas.
Una migración distinta requeriría su propio cambio contractual y tests.

## Identidad y verdad del estado

El contrato propuesto del centro enlaza, sin confundirlos:

| Identidad | Significado |
|---|---|
| Instalación y equipo | Origen local, con identificador propio no clonado |
| Goal, tarea y unidad verificable | Resultado solicitado y su división aceptada |
| Responsable y agente delegado | Quién coordina y quién realiza el encargo |
| Runtime, CLI, proveedor y modelo | OpenClaw/Hermes y ejecutor real; desconocido si no se observa |
| Intento y sesión | Historial estable ante reintentos, sesión nativa y tmux si aplica |
| Proceso | Equipo, arranque del sistema, PID y fecha de creación o equivalente |

El director conserva la propiedad del progreso declarado. Las observaciones de
procesos, recursos y proveedor se guardan aparte, con origen y fecha, y no
sobrescriben el documento del lead. La vista combina ambas fuentes y distingue
declarado, observado y verificado. Una lectura rota muestra error o dato antiguo,
no una lista vacía. Los datos no disponibles son desconocidos, nunca cero.

Estados de presentación: pendiente, trabajando, esperando, bloqueada, verificando,
terminada, fallida y cancelada. Se mapean explícitamente desde los estados
existentes sin cambiarlos. Esperando incluye motivo y próxima comprobación;
bloqueada incluye causa, responsable de resolverla y siguiente acción permitida.
La salud del proceso y la antigüedad de la observación son campos separados.

El porcentaje principal cuenta unidades verificadas sobre unidades comprometidas
en una revisión del plan. No depende del tiempo, tokens, latidos ni estimaciones
del modelo. Un cambio de alcance registra nueva revisión y denominador. Sin plan
verificable se muestra desconocido. Los porcentajes legados conservan su etiqueta
y semántica; no se presentan como otro porcentaje global de la misma tarea.
El consolidado y el centro usan el mismo resumen de unidades.

Terminar exige el resultado prometido y evidencia de aceptación del artefacto
actual. Para código puede ser un SHA con checks; para un diagnóstico, un informe
que conteste criterios acordados; para operaciones, recibos y verificación viva.
Un proceso que sale, un PR mergeado o un mensaje "listo" no bastan por sí solos.
Merge y deploy siguen necesitando autoridad explícita, separada de la calidad.

## Seguimiento y recuperación

El supervisor local conserva inventario y último estado aunque el coordinador
caiga. Detecta la ausencia y publica el estado degradado sin depender de un turno
del agente. Si existe una interfaz pública soportada, solicita una continuación
acotada, con identidad de intento y presupuesto persistentes. No usa RPC privadas.
Si no existe, informa la limitación y el paso necesario; no declara paridad completa.

La intención de lanzamiento se registra antes del efecto y después se reconcilia
por intento. Una caída entre el efecto y su recibo no autoriza repetirlo. Se consulta
el destino o su clave de idempotencia; si no se puede resolver, queda resultado
desconocido hasta reconciliar. No se promete "exactly once" con un journal local.

La política local fija capacidad, presupuesto total y límite de reintentos antes
de ejecutar. Los reinicios no reinician esos contadores. Inicio conservador de
un worker local; ampliar capacidad requiere configuración explícita y medición,
siempre dentro del límite de Fase 14. No se matan procesos ajenos por nombre o PID
solo. Veinte minutos sin avance no equivalen a proceso muerto.

CPU y memoria muestran unidades, instante y cobertura del árbol de procesos.
Los tokens/costos/cuotas requieren fuente del proveedor; no se deducen de CPU.
Se muestra carga del equipo aparte del consumo atribuible a la tarea. Los límites
de CPU/memoria son prevención de nuevos lanzamientos, no promesa de aislamiento
duro si el sistema operativo no lo ofrece. La cadencia de muestreo tendrá un
presupuesto medido; no se crea un shell por tarea por cada refresco del panel.

## Panel

```text
Mi Mac · Hermes · versión del sistema · observado hace 8 s
Activas 3       Esperando 1       Necesitan respuesta 0

Tarea                 Estado          Responsable       Avance
Arreglo de OpenClaw    Verificando     Muse / Codex       6 de 8
Revisar documento     Trabajando      Hermes             1 de 3

Detalle: resultado esperado y criterios de cierre
Ahora: revisión de pruebas. Último avance verificable: hace 4 min.
Responsable: Hermes | Agente: Muse | CLI: muse | Intento: 2
Espera: CI | Próxima comprobación: 14:30 America/Vancouver
Recursos observados | Historial | Evidencias | Resultado final
```

Lista y detalle deben funcionar en escritorio y móvil. Los estados usan texto e
iconos además del color; las fechas incluyen zona horaria; la navegación funciona
con teclado. El detalle técnico es desplegable. Se diseñan estados vacío, error,
desconocido, sin conexión y datos antiguos. El usuario puede encontrar responsable,
ejecutor, bloqueo, siguiente paso y evidencia sin leer código.

LobsterBoard es candidato visual, condicionado a revisar la licencia del commit
elegido, sus dependencias y compatibilidad. No se importa código antes de esa
decisión. Si no resulta apto, se extiende el tablero existente con diseño propio;
no se bloquea el contrato de tareas por elegir un frontend. OpenGrokBot queda
como referencia de experiencia, no dependencia.

De esa referencia se toman requisitos observables, no su runtime: una línea
temporal de actividad por tarea, identificación visible del agente y la CLI
real, avisos de espera/bloqueo y acceso directo a la evidencia final. La
implementación se hace sobre el contrato de tareas propio y se prueba sin
OpenGrokBot instalado. No se copia código ni assets de ambos candidatos hasta
verificar licencia, commit, dependencias y permisos de reutilización.

## Datos y seguridad

El panel consume una proyección por allowlist. No exporta prompts, entorno,
argv crudo, transcripciones, tokens ni pantallas completas. La descripción de la
actividad se redacta en origen. Los metadatos privados de corridas no amplían el
contrato diagnóstico, que continúa prohibiendo persistir comandos y rutas.

Texto y enlaces son entrada no confiable: escape, truncado, esquemas de URL
permitidos y rechazo de caracteres de control. Bind local por defecto y acceso
autenticado; acceso remoto queda fuera del primer despliegue. Estado privado con
permisos comprobados por plataforma, retención acotada y sin secretos en Git.
Los ejecutables vienen de configuración local confiable con ruta absoluta y
argumentos separados, nunca de parámetros HTTP.

## Prueba de aceptación obligatoria

Los mismos escenarios corren en cada adaptador, con el otro runtime ausente:

1. Crear un encargo por la entrada nativa y verlo con responsable, CLI e intento.
2. Un agente con dos intentos no cuenta como dos agentes. Un hijo del CLI no
   aparece como otro responsable.
3. Un proceso vivo sin unidades nuevas conserva porcentaje; una sesión desaparecida
   deja de mostrarse como actividad actual al vencer la frescura declarada.
4. Esperar CI muestra causa y próxima comprobación. Falta de permiso produce
   bloqueo explícito sin impedir tareas independientes.
5. Cerrar navegador, matar coordinador y reiniciar supervisor conserva historial
   y seguimiento sin lanzar otro intento ni repetir un efecto incierto.
6. Dos tareas generan un consolidado; cerrar una no apaga el seguimiento de la otra.
   Un envío fallido no adelanta el checkpoint de entrega.
7. PID reutilizado, archivos corruptos, métricas faltantes y datos antiguos nunca
   se atribuyen a la tarea equivocada ni permiten matar procesos ajenos.
8. "Listo", pruebas rojas o evidencia de otro SHA no cierran la tarea. Una tarea
   sin PR cierra únicamente con su prueba de resultado.
9. Secretos sintéticos, XSS y rutas maliciosas no salen en API, eventos, HTML ni exportación.
10. Una tarea real de bajo riesgo en cada equipo termina con evidencia; el otro
    equipo permanece apagado o inaccesible. Se entregan capturas móvil/escritorio
    y comparación de la misma versión/capacidades, sin secretos.

## Fuentes y asuntos no comprobados

- Contratos locales: `docs/spec/corrida.v2.md`, `docs/spec/seguimiento.v2.md`,
  `docs/spec/runbook-progress.v2.md` y Fases 9, 14, 15, 16 de `Plans.md`.
- Candidatos consultados: [LobsterBoard](https://github.com/Curbob/LobsterBoard),
  [OpenGrokBot](https://github.com/wolfqing/OpenGrokBot) y
  [Hermes Agent](https://github.com/NousResearch/hermes-agent).
- El nombre Hermes se interpreta como NousResearch Hermes Agent; la identidad,
  versión instalada, APIs de continuación, plataformas de ambos equipos y
  transporte de notificaciones se verifican en 17.0. No se afirma compatibilidad viva.
- Las fuentes públicas no sustituyen recibos de instalación. La licencia y el
  commit apto de LobsterBoard siguen siendo una decisión de 17.0.

# Plan 17: centro de tareas común para OpenClaw y Hermes

> **Detalle de U4/U5.** La ruta activa y sus dependencias están al inicio de
> `Plans.md`. Este plan no se inicia mientras U1–U3 y U3a sigan sin aceptación; 17.0
> y 17.1 pueden prepararse sólo como inventario y contratos sin activar servicios.
> La prueba funcional de LobsterBoard pertenece a la ejecución de U4; esa
> preparación documental no completa 17.0.

Fecha: 2026-09-22. Estado: plan listo para evaluación; implementación no iniciada.
Base de investigación: `origin/main` en `31dfaf0`.
Diseño y aceptación: [especificación](../specs/2026-09-22-centro-tareas-design.md).
Estado de tareas: [Plans.md](../../../Plans.md), sección Fase 17.
Runbook de ejecución: [autopilot-fase17.md](../../runbooks/autopilot-fase17.md).

## Qué entrega

Un panel por computadora con la misma forma de encargar, seguir y verificar
trabajo. OpenClaw y Hermes usan instalaciones independientes del mismo sistema.
El panel hace visible el agente responsable, CLI real, avance comprobado,
esperas, bloqueos, recursos y evidencia final. El seguimiento persiste fuera
del turno del coordinador, con recuperación limitada por capacidad y autoridad.

Este pedido autoriza elaborar y publicar el plan. No autoriza ejecutar sus tareas,
instalar software vivo, cambiar configuración, mergear ni desplegar.

## Orden y responsables

El lead conserva el ledger y resuelve interfaces. Un implementer trabaja por
bloque; un reviewer distinto revisa el diff. Ingeniería instala únicamente bajo
autorización posterior. La identidad concreta de esos agentes se asigna al iniciar,
sin asumir que los agentes disponibles en un equipo existen en el otro.

| Bloque | Tareas | Salida |
|---|---|---|
| A. Probar LobsterBoard y fijar contratos | 17.0, 17.1 | Prueba del original, cobertura/faltantes y contratos verificables |
| B. Seguimiento portable | 17.2, 17.3, 17.4 | Dos adaptadores independientes y recuperación segura |
| C. Panel e instalación | 17.5, 17.6 | UI completa y paquete reproducible |
| D. Demostración | 17.7, 17.8 | Pruebas, revisión y aceptación viva por equipo |

La tabla agrupa trabajo, no impone una barrera bilateral. Para U4 se ejecutan
17.0–17.2, la parte OpenClaw de 17.4 y 17.5, con paquete, revisión y aceptación
local de 17.6–17.8. U5 añade 17.3 y prueba esas mismas piezas en Hermes, sin
reabrir evidencia OpenClaw vigente. Ninguna fila compartida se marca completa
para ambos equipos con un recibo de uno solo. Así 17.4 no depende de Hermes
para entregar U4, y U5 puede seguir dependiendo de U4 sin ciclo.
Antes de ejecutar, el lead adapta documentalmente el runbook a esta división
por host como preparación independiente, sin depender de 17.6 ni 17.7 y sin
activar servicios. La tarea 17.7 conserva la validación final del runbook contra
las interfaces implementadas; no es un requisito para preparar el arranque.

No se estima duración cerrada antes de 17.0. La mayor incertidumbre es separar
dependencias actuales de OpenClaw y comprobar la continuación soportada por Hermes.
La UI sola no resuelve esa dependencia. Fase 14 pendiente no se carga a Fase 17
como trabajo supuestamente terminado.

Para encargos gestionados, 17.0 comprueba en el perímetro que usará U4 la base
de T1–T8 del [plan de encargos](2026-09-30-encargos-agentes.md): versión y SHA,
interfaces nativas de identidad, admisión, resultados, consumo y presupuesto,
recibos de host, proyección y pruebas de integración. Una fila marcada en el plan
no sustituye esa prueba. Si falta una interfaz, se detiene sólo la conexión que
la necesita; 17.0, contratos y maqueta independientes pueden continuar. No se
exige cerrar U3b ni completar rutas CLI/Hermes ajenas al perímetro usado por U4.
U5 verifica por separado la base equivalente en su host; no hereda la aceptación
de OpenClaw.

## Contratos de tarea

### 17.0. Inventario y decisiones de compatibilidad

Propósito: no construir sobre capacidades supuestas.
Archivos previstos: `docs/spec/centro-tareas-capabilities.md`, fixtures de
capacidades y manifiestos de prueba. No leer archivos de credenciales.

Al autorizar la ejecución de U4, el alcance de 17.0 incluye instalar y arrancar
LobsterBoard sólo en un directorio temporal nuevo del equipo de prueba, registrado
en el recibo, sin instalación global ni servicio persistente. El original y su
estado quedan ahí; guardar configuración sin secretos y capturas redactadas en
`docs/evidence/fase17-lobsterboard/`. Para observar Claw, usar únicamente acceso
soportado ya autorizado, sin cambiar el gateway ni copiar credenciales. Registrar
el acceso del celular al entorno de prueba sin publicación a internet. Si no se
puede verificar la conexión real, queda pendiente; las fixtures no la sustituyen.
Detener el proceso al terminar y documentar cómo retirar sólo los archivos de la
prueba. La preparación documental previa no incluye arrancar este entorno.

- Inventariar versiones, plataformas, interfaces públicas de eventos, continuación,
  progreso y notificación. Probar que Hermes no necesita gateway OpenClaw.
- Mapear Fase 14 a commits, pruebas y recibos instalados. Reconciliar dependencias
  con entrega sin sello y Fase 16 sin modificar sus cierres por inferencia.
- Registrar dependencias OpenClaw en `scripts/mac/corrida/`, reloj y RPC de progreso;
  asignar su eliminación o adaptación a 17.2–17.4.
- Inventariar los contratos y recibos T1–T8 realmente instalados en el perímetro
  usado: consulta nativa, admisión, `report`/`resolve`, reservas del árbol,
  recibos de recursos y proyección. Registrar SHA, prueba y huecos por host; no
  inferir compatibilidad de la existencia de archivos o casillas marcadas.
- Revisar licencia, dependencias y compatibilidad de un commit identificado de
  LobsterBoard y registrar permisos de reutilización de código/assets antes de
  adoptar o empaquetar. Tras esa revisión y al ejecutar U4, probar el producto original
  en un entorno de prueba reversible con una plantilla existente, sin modificar
  su código. Configurar sólo los componentes necesarios para observar Claw.
- Comprobar en computadora y celular lectura, navegación, uso táctil y refresco.
  Registrar versión/commit, configuración reproducible, capturas, datos de Claw
  disponibles y una matriz de requisitos cubiertos, faltantes y desconocidos.
  Datos ficticios sólo prueban presentación; no acreditan conexión real a Claw.
- Conservarlo si cumple. Para cada faltante, probar primero configuración; sólo
  proponer una conexión o ajuste pequeño con alcance y prueba. Si licencia o
  compatibilidad impiden adoptarlo, o requiere desarrollo amplio, detener el
  carril UI y presentar alternativas acotadas. No iniciar automáticamente una
  app/plataforma propia ni rediseñar el panel.
- Identificar lint/formatter de los archivos a tocar. Si falta, configurar una
  base mínima focalizada antes del código, sin reformateo masivo.
- Definir límites numéricos de frescura, muestreo, retención, presupuesto y recursos
  mediante medición; documentar dato no observado como desconocido.

DoD: matriz con evidencia por capacidad y host, recibo de la prueba de LobsterBoard
original en computadora/celular o impedimento documentado, cobertura/faltantes,
decisión UI justificada y comandos focalizados reproducibles. Ninguna dependencia
requerida se marca disponible sin prueba. Un impedimento no habilita 17.5. Si falta
una API pública indispensable, se detiene ese carril y se presenta la limitación;
no se simula soporte.

### 17.1. Modelo de tareas, proyección y maqueta

Archivos previstos: `docs/spec/centro-tareas.v1.md`, fixtures y tests de contratos
en `tablero-runbook/`; maqueta junto al diseño. Los nombres de módulos nuevos
se concretan en 17.0, sin crear otro registro de workers.

Fijar identidad, estados, observaciones, unidades verificadas, criterios de cierre
por tipo de tarea y mapeos legacy. La proyección no es un nuevo escritor del progreso.
Para encargos gestionados, enlazar la identidad y los recibos T1–T8 sin crear un
segundo store, scheduler, registro de workers o contador de consumo. Distinguir
`report` recibido, `resolve` durable, recurso cerrado y unidad aceptada: ninguno
de los tres primeros incrementa por sí solo el porcentaje de producto.
Resolver la diferencia entre porcentaje de cola y unidades para que el encabezado
y el aviso al usuario coincidan en unidades verificadas. Conservar `%GLOBAL`
histórico con su etiqueta y semántica: puede diferir de `seguimiento.v2` sin ser
un error ni justificar un cambio de schema legacy. Validar escritorio/móvil
sobre la plantilla probada en 17.0 con casos de espera, bloqueo, degradación
y cierre. Usar datos
ficticios identificados para estados aún no disponibles; hacer maqueta sólo
de los ajustes pequeños necesarios, sin diseñar de nuevo lo que ya cumple.

DoD: tests de fixtures v1/v2 existentes y nuevos; cálculo de porcentaje único;
revisión de configuración o maqueta de ajustes contra el recorrido del diseño. No cambiar literal de schema
legacy ni rutas existentes inadvertidamente.

### 17.2. Adaptación OpenClaw y observaciones locales

Modificar fronteras existentes en `scripts/mac/corrida/`, módulos de progreso y
registro/selector de Fase 14. Añadir tests junto al módulo cambiado.
Conservar `corrida.sh` como entrada de ciclo de vida y las políticas de autoridad.
Enlazar identidad de tarea con intentos, sesiones y procesos verificados. Exponer
actividad redactada y métricas con origen, cobertura y fecha. No instrumentar
CLIs con hooks privados ni interceptar prompts.
En el perímetro de encargos gestionados, consumir consulta y recibos nativos
T1–T8; `corrida` proyecta y coordina trabajo de ingeniería, sin admitir, resolver
ni contabilizar de nuevo una tarea que pertenece al scheduler nativo.

DoD: una tarea fixture llega desde entrada nativa a proyección; un PID reutilizado
no se atribuye al intento anterior; métricas faltantes no son cero; tests de
compatibilidad verdes y manifiesto Fase 14 comprobado.

### 17.3. Adaptación Hermes independiente

Crear el adaptador Hermes en la misma frontera, con fixtures y pruebas de contrato
compartidas. Extraer sólo el núcleo puro necesario para progreso y reloj; el
transporte específico queda en adaptadores. Eliminar la dependencia obligatoria
de `openclaw cron list` o RPC OpenClaw en el camino Hermes.
Compartir la forma portable de consulta, recibos y proyección, no el almacén ni
el scheduler de OpenClaw. Hermes aporta autoridad nativa/local, transporte y
recibos propios; si faltan, 17.3 permanece pendiente y no se sustituye con una
RPC a OpenClaw.

DoD: iniciar, registrar, observar, reportar y verificar una tarea con ejecutable y
gateway OpenClaw ausentes; mismo contrato y capacidades requeridas que 17.2.
Documentar observabilidad parcial real de CLI/proveedor. No llamar equivalencia
completa a un simple copiado de skills.

### 17.4. Supervisión y recuperación acotada

Extender reconciliación Fase 14 y el mecanismo global de seguimiento existente.
Separar inventario/monitor del coordinador sin añadir un reloj competidor.
Para encargos gestionados, consumir intención, intento, reservas, liquidación y
recibos de reconciliación T1–T8; no duplicar su store, scheduler ni marca de
consumo. El presupuesto del árbol limita llamadas gestionadas y descendientes;
el cupo de host limita procesos propios hasta cierre verificado; los carriles de
`corrida` limitan trabajo de ingeniería. Mostrar los tres por separado y no
liberar uno por un recibo que sólo cierra otro. Medir recursos sin lanzar procesos
por cada tarea y refresco. Comprobar un dueño de vigilancia y reportes por host,
backoff y conservación del checkpoint después de fallo de entrega.

DoD: inyectar muerte antes/después de lanzar y recibir efectos; no duplicar
intentos conocidos; efecto incierto queda desconocido sin repetición automática.
Matar el coordinador mantiene panel/seguimiento degradado disponible. Límites
siguen vigentes tras reiniciar y no se mata proceso ajeno. Dos tareas usan un reloj
y un emisor de reportes, sin sondeo con modelo por falta de novedades.

### 17.5. Panel de tareas

Archivos propios de configuración, manifiesto de versión y conexiones pequeñas:
`integrations/lobsterboard/`, sin vendorear el producto ni guardar estado o secretos.
El original se ejecuta en el directorio temporal registrado en 17.0; la ubicación
instalada definitiva la resuelve 17.6 para la aceptación por host de 17.8.

Configurar LobsterBoard adoptado en 17.0, conservando la plantilla y componentes
que ya cumplen. Conectar la proyección de tareas, nunca salidas crudas. Antes de
cada ajuste, identificar el faltante medido, archivos afectados y prueba de
aceptación. Reutilizar lista, filtros, detalle, historial, evidencias, recursos y
cabecera disponibles; añadir sólo conexiones o ajustes pequeños donde falten.
Tests de componentes y recorridos junto a la integración. No añadir botones de
ejecución. Si cumplir los recorridos exige una app/plataforma propia o cambios
amplios, detener el carril UI y presentar alternativas acotadas, sin reducir
los criterios de aceptación ni iniciar una reescritura automáticamente.

DoD: los diez recorridos del diseño se representan sin estados ambiguos; pruebas
UI con viewport móvil y escritorio, teclado, texto de estados y datos antiguos.
Capturas y demo permiten identificar responsable, CLI y siguiente paso sin terminal.
Pruebas de XSS, enlaces maliciosos y secretos sintéticos cubren API y HTML.

### 17.6. Paquete e instalación por host

Extender instalador/manifiesto Fase 14, con preflight, dry-run y reversa por archivos
propios. Incluir selección explícita OpenClaw/Hermes, generación local de identidad,
configuración de credenciales por referencias privadas y health del único reloj.
El paquete comparte versión/capacidades, no estado. No tocar `.openclaw` como repo.

DoD: instalar dos veces en entornos temporales converge; upgrade y reversa conservan
tareas e identidad; instalar desde copia genera identidad distinta y no copia tokens;
la desinstalación propuesta sólo enumera archivos propios, sin borrar datos de usuario.
Documentar plataformas soportadas y rechazar explícitamente otras.

### 17.7. Integración, revisión y runbook operativo

Reunir fixtures compartidos y casos de crash, aislamiento, compatibilidad y datos
sensibles. Preparar el runbook de despliegue sólo con interfaces ya verificadas,
permisos y reversa por host. Verificar su launcher existente en dry-run y la lectura
por un ejecutor distinto. No presentar un launcher inventado como utilizable.

DoD: hooks verdes, PR con commits exclusivos de la tarea, batería completa una vez
en CI del head final, reviewer distinto y cero bloqueantes reproducibles. El runbook
identifica comando inicial de tablero, copia de progreso, dueños, límites, atasco y
permiso de instalación. Validación cruzada sugerida para recuperación/autoridad según
quality-kit; no ciclos ilimitados de revisión.

### 17.8. Instalación y aceptación viva

Sólo con autorización posterior que nombre equipo, ventana y cambios. Ingeniería
verifica dependencias instaladas, instala el paquete y ejecuta una tarea de bajo
riesgo en cada equipo con el otro inaccesible. Reutilizar el mismo SHA validado;
no repetir batería completa en cada host. Hacer el checklist vivo una vez por host.

DoD: recibos redactados, versión común, matriz de aceptación completa para ambos,
recursos medidos, seguimiento confirmado y reversa probada en el entorno autorizado.
El usuario acepta la demo. Si sólo un adaptador funciona, la fase sigue incompleta.

## Prioridad y decisiones

Required: 17.0–17.7; 17.8 requerida para declarar operación completa y condicionada
a permiso vivo. Cobertura de seguimiento, independencia, seguridad y evidencia
son criterios de pase, no puntos compensables por apariencia.

Required para la UI, por decisión de David del 2026-09-26: probar LobsterBoard
original con plantilla existente en 17.0 antes de desarrollar interfaz; conservarlo
si cumple y limitar cambios a ajustes pequeños demostrados por la prueba.
Recommended: demo visual de esa configuración; revisión cruzada de recuperación.

Optional/deferred: botones de control, costos históricos, comparación de rendimiento
entre motores, acceso remoto y un visor agregado de varios hosts.

Reject: segunda plataforma de orquestación, copiar OpenGrokBot como runtime,
failover entre computadoras, sesión activa compartida, segundo reloj, shell libre
en navegador, repetir efectos inciertos, cierre por autodeclaración y merge automático.

## Verificación y revisión del plan

`team_validation_mode: subagent`. Tres lecturas independientes cubrieron arquitectura,
producto/QA y seguridad. Se incorporaron la dependencia real de Fase 14, transición
de schema v1, reloj v2, porcentaje único, Hermes sin gateway, identidad de procesos,
licencia condicionada y recuperación sin duplicar efectos.

Enmienda del 2026-09-26: decisión del usuario de probar LobsterBoard original
antes de desarrollar UI. `team_validation_mode: subagent`; dos lecturas
independientes de producto/QA y arquitectura/seguridad verifican esta enmienda.
Spec delta: el contrato de producto, diseño, ledger y runbook fijan original
primero, prueba computadora/celular y ajustes pequeños según faltantes. Se elimina
el fallback automático a diseño propio; no cambia la autoridad de instalación.

Memoria reutilizada: contratos y decisiones versionados del repo. No se asume
ausencia de memoria externa por no haberla consultado. Spec delta en
`docs/spec/00-project-spec.md`; este diseño define producto y `Plans.md` registra tareas.

Durante implementación: prueba focalizada roja/verde por cambio. Cada bug incluye
regresión. La batería completa corre una vez por bloque sobre el head final en CI
de PR, con sus shards y candado, nunca repetida en la Mac por rutina. Checks de
documentos/ledger van por su job corto. Hooks obligatorios, sin `--no-verify`.
Los hallazgos se agrupan; sólo un bloqueante reproducible abre otra ronda del diff
corregido. El mismo bloqueante repetido dos veces detiene el ciclo para decisión.

## 事前確認 y autoridad

- Evento: editar documentos, hooks, rama, push y PR del plan. Razón: entregar este
  pedido y validar documentación en CI. Scope: planificación Fase 17.
- Evento: implementar 17.0–17.7, pruebas focalizadas y PRs de código. Razón:
  construir lo propuesto. Scope: futuro pedido de implementación; no concedido aquí.
- Evento: instalar/arrancar LobsterBoard temporal y configurar su prueba de
  17.0/17.5, con conexión observacional ya autorizada a Claw y acceso del celular.
  Razón: comprobar el original antes de desarrollar UI. Scope: incluido en el
  futuro pedido de ejecución U4, sólo entorno temporal registrado, sin instalación
  global, servicio persistente, cambios al gateway ni publicación a internet;
  no concedido por esta actualización documental.
- Evento: instalación persistente, cambios de servicio/config, notificaciones de prueba y tareas
  reales en dos hosts. Razón: 17.8. Scope: permiso posterior por equipo y ventana.
- Evento: merge/deploy. Razón: distribución del sistema. Scope: permiso separado;
  calidad, PR verde o este documento no lo conceden.

No se autoriza lectura general de secretos, borrado, force-push, reinicio del equipo,
cambio de modelos ni modificación de otros planes. No se fabrica un registro de
preaprobación para permisos aún no otorgados.

## Inicio posterior

Nueva sesión desde un worktree de implementación basado en `origin/main`: `claude`.
Antes de autorizar U4, sólo preparar el inventario y contratos, sin instalar ni
arrancar procesos; esto no completa 17.0. Con el pedido de ejecución U4, la primera
instrucción es `/harness-work 17.0` con este plan, incluyendo la prueba temporal
acotada descrita arriba. Confirmar su evidencia antes de desarrollar UI.
Esto es una guía para el siguiente pedido, no una sesión lanzada ni permiso vivo.

# Plan 17: centro de tareas común para OpenClaw y Hermes

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
| A. Comprobar y fijar contratos | 17.0, 17.1 | Capacidades, dependencias y diseño de UI verificables |
| B. Seguimiento portable | 17.2, 17.3, 17.4 | Dos adaptadores independientes y recuperación segura |
| C. Panel e instalación | 17.5, 17.6 | UI completa y paquete reproducible |
| D. Demostración | 17.7, 17.8 | Pruebas, revisión y aceptación viva por equipo |

No se estima duración cerrada antes de 17.0. La mayor incertidumbre es separar
dependencias actuales de OpenClaw y comprobar la continuación soportada por Hermes.
La UI sola no resuelve esa dependencia. Fase 14 pendiente no se carga a Fase 17
como trabajo supuestamente terminado.

## Contratos de tarea

### 17.0. Inventario y decisiones de compatibilidad

Propósito: no construir sobre capacidades supuestas.
Archivos previstos: `docs/spec/centro-tareas-capabilities.md`, fixtures de
capacidades y manifiestos de prueba. No leer archivos de credenciales.

- Inventariar versiones, plataformas, interfaces públicas de eventos, continuación,
  progreso y notificación. Probar que Hermes no necesita gateway OpenClaw.
- Mapear Fase 14 a commits, pruebas y recibos instalados. Reconciliar dependencias
  con entrega sin sello y Fase 16 sin modificar sus cierres por inferencia.
- Registrar dependencias OpenClaw en `scripts/mac/corrida/`, reloj y RPC de progreso;
  asignar su eliminación o adaptación a 17.2–17.4.
- Resolver licencia y commit de LobsterBoard; seleccionar tablero existente si
  la adopción no está permitida o no aporta una integración mantenible.
- Identificar lint/formatter de los archivos a tocar. Si falta, configurar una
  base mínima focalizada antes del código, sin reformateo masivo.
- Definir límites numéricos de frescura, muestreo, retención, presupuesto y recursos
  mediante medición; documentar dato no observado como desconocido.

DoD: matriz con evidencia por capacidad y host, decisión UI justificada, comandos
focalizados reproducibles y ninguna dependencia requerida marcada disponible sin
prueba. Si falta una API pública indispensable, se detiene ese carril y se presenta
la limitación; no se simula soporte.

### 17.1. Modelo de tareas, proyección y maqueta

Archivos previstos: `docs/spec/centro-tareas.v1.md`, fixtures y tests de contratos
en `tablero-runbook/`; maqueta junto al diseño. Los nombres de módulos nuevos
se concretan en 17.0, sin crear otro registro de workers.

Fijar identidad, estados, observaciones, unidades verificadas, criterios de cierre
por tipo de tarea y mapeos legacy. La proyección no es un nuevo escritor del progreso.
Resolver la diferencia entre porcentaje de cola y unidades para que el encabezado
y el aviso al usuario coincidan. Hacer maqueta escritorio/móvil con casos de espera,
bloqueo, degradación y cierre, usando datos ficticios.

DoD: tests de fixtures v1/v2 existentes y nuevos; cálculo de porcentaje único;
revisión de maqueta contra el recorrido del diseño. No cambiar literal de schema
legacy ni rutas existentes inadvertidamente.

### 17.2. Adaptación OpenClaw y observaciones locales

Modificar fronteras existentes en `scripts/mac/corrida/`, módulos de progreso y
registro/selector de Fase 14. Añadir tests junto al módulo cambiado.
Conservar `corrida.sh` como entrada de ciclo de vida y las políticas de autoridad.
Enlazar identidad de tarea con intentos, sesiones y procesos verificados. Exponer
actividad redactada y métricas con origen, cobertura y fecha. No instrumentar
CLIs con hooks privados ni interceptar prompts.

DoD: una tarea fixture llega desde entrada nativa a proyección; un PID reutilizado
no se atribuye al intento anterior; métricas faltantes no son cero; tests de
compatibilidad verdes y manifiesto Fase 14 comprobado.

### 17.3. Adaptación Hermes independiente

Crear el adaptador Hermes en la misma frontera, con fixtures y pruebas de contrato
compartidas. Extraer sólo el núcleo puro necesario para progreso y reloj; el
transporte específico queda en adaptadores. Eliminar la dependencia obligatoria
de `openclaw cron list` o RPC OpenClaw en el camino Hermes.

DoD: iniciar, registrar, observar, reportar y verificar una tarea con ejecutable y
gateway OpenClaw ausentes; mismo contrato y capacidades requeridas que 17.2.
Documentar observabilidad parcial real de CLI/proveedor. No llamar equivalencia
completa a un simple copiado de skills.

### 17.4. Supervisión y recuperación acotada

Extender reconciliación Fase 14 y el mecanismo global de seguimiento existente.
Separar inventario/monitor del coordinador sin añadir un reloj competidor.
Persistir intención, intento, presupuesto y resultado de reconciliación. Medir
recursos sin lanzar procesos por cada tarea y refresco. Comprobar unicidad del
servicio, backoff y conservación del checkpoint después de fallo de entrega.

DoD: inyectar muerte antes/después de lanzar y recibir efectos; no duplicar
intentos conocidos; efecto incierto queda desconocido sin repetición automática.
Matar el coordinador mantiene panel/seguimiento degradado disponible. Límites
siguen vigentes tras reiniciar y no se mata proceso ajeno. Dos tareas usan un reloj.

### 17.5. Panel de tareas

Extender `tablero-runbook/` o integrar el candidato permitido en 17.0. Tests de
componentes y recorridos junto a UI. Consumir la proyección, nunca salidas crudas.
Implementar lista, filtros por estado/responsable, detalle, historial, evidencias,
recursos y cabecera de instalación. No añadir botones de ejecución.

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

Recommended: adoptar LobsterBoard si licencia e integración pasan 17.0; demo
visual antes de cablear la UI; revisión cruzada del código de recuperación.

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
- Evento: instalación, cambios de servicio/config, notificaciones de prueba y tareas
  reales en dos hosts. Razón: 17.8. Scope: permiso posterior por equipo y ventana.
- Evento: merge/deploy. Razón: distribución del sistema. Scope: permiso separado;
  calidad, PR verde o este documento no lo conceden.

No se autoriza lectura general de secretos, borrado, force-push, reinicio del equipo,
cambio de modelos ni modificación de otros planes. No se fabrica un registro de
preaprobación para permisos aún no otorgados.

## Inicio posterior

Nueva sesión desde un worktree de implementación basado en `origin/main`: `claude`.
Primera instrucción: `/harness-work 17.0` con este plan como contexto y alcance de
inventario, sin instalación ni secretos. Conviene empezar sólo por esa tarea para
confirmar interfaces y dependencias antes de autorizar bloques de código.
Esto es una guía para el siguiente pedido, no una sesión lanzada ni permiso vivo.

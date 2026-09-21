# Orquestación autónoma con harnesses nativos

Fecha: 2026-09-19. Estado: aprobado por el dueño el 2026-09-19.

## Propósito

Claw recibe un trabajo de ingeniería y lo completa hasta producción verificada. `main` divide el trabajo, elige los trabajadores, vigila cada ejecución, coordina las revisiones, fusiona el cambio mediante un agente autorizado, despliega y comprueba el resultado vivo.

Cada trabajador externo usa la aplicación de terminal preparada para ese trabajador. Claude usa Claude Code. Codex usa Codex CLI. GLM usa ZCode. Kimi usa Kimi Code CLI. Cursor usa Cursor Agent CLI. Grok usa Grok CLI. Claw no cambia solo el modelo dentro de un ejecutor genérico y no ejecuta GLM dentro de Claude Code como camino normal.

David puede observar cada trabajador en una terminal. El tablero muestra el estado conjunto y conserva la historia de la corrida.

## Dependencias y contratos vigentes

Se corrige el diseño ahora; se implementa después de Fases 15 y 9 y de integrar entrega-sin-sello A/B/C. Fase 23 es independiente y sus pendientes recomendados no son prerrequisito. El plan de implementación contiene los checks de arranque y el orden de cuatro bloques.

Se extiende el `corrida.v2` existente del reloj global, con campos opcionales de trabajadores; se conservan registros anteriores, `seguimiento_global:true` y ausencia de `cron_vigia_id`. La vigilancia interna usa el tick global de 15 minutos y eventos tmux; los reportes consolidados salen cada 30 minutos con porcentajes derivados. No se agrega otro reloj ni cron de entrega por trabajador.

Fase 9 es dueña del instalador, recuperación de locks y agente usuario. Fase 15 es dueña de CI y tiempos de pruebas. Fase 14 extiende esos resultados, conserva sus pruebas y no duplica sus implementaciones.

El recibo `saikit-entrega.v1` de SummonAIKit es la autoridad persistente por PR/head. La corrida conserva referencias de evidencia y no crea otra firma, formato de aprobación ni requisito de hook activo. Los roles independientes se conservan para código. El plan define manejo de cuota, revisiones de deltas y correspondencia entre head revisado, merge commit y SHA vivo.

## Resultado esperado

Un pedido de ingeniería termina en uno de estos estados:

- El cambio está desplegado y el canary demuestra el comportamiento pedido.
- El cambio se revirtió y la reversa quedó verificada.
- Una compuerta obligatoria no está disponible después de los reintentos del runbook. Claw informa el comando y el error que impiden continuar.

El sistema no declara éxito por un commit, un PR, una CI verde o un merge. El éxito exige comprobar el artefacto vivo.

## Alcance

Este diseño agrega selección de trabajadores, ejecución por CLI nativa, aislamiento por worktree, terminales visibles, recuperación persistente y el ciclo autónomo hasta deploy.

El diseño amplía piezas existentes:

- `scripts/mac/corrida.sh` conserva el registro y el ciclo de vida de una corrida.
- `scripts/mac/agent-tmux.sh` inicia las CLIs en sesiones `tmux` con nombre.
- `scripts/mac/tmux-activity-watch.sh` detecta silencio, diálogos y fin de turno.
- `tablero-runbook` muestra el progreso escrito por el director y lo cruza con GitHub y el plan.
- `agent-dispatch` conserva el contrato de briefs, entregas y resultados completos.
- La cadena de calidad conserva verifier, adversary, reviewer, cross-review, CI y CodeRabbit.

El diseño no crea otro tablero ni otro administrador de sesiones.

## Términos

- **Trabajador:** combinación versionada de harness, proveedor, modelo o router, capacidades y política de permisos.
- **Harness:** CLI que ejecuta el trabajo y conserva su sesión.
- **Adaptador:** código determinista que inicia, consulta, reanuda y detiene un harness. El adaptador no toma decisiones de ingeniería.
- **Carril:** unidad de trabajo con archivos propios, worktree propio cuando escribe, y una entrega verificable.
- **Director:** `main`. Clasifica, asigna, decide el siguiente paso y escribe el progreso.

## Decisiones de producto

1. Cursor Agent es un trabajador más. No es el implementador obligatorio.
2. `main` elige un trabajador según la tarea, sus capacidades, su disponibilidad, su cuota y su historial.
3. Una corrida puede tener hasta cuatro harnesses externos activos.
4. Dos trabajadores con permiso de escritura no comparten un worktree.
5. El tablero y las terminales visibles son obligatorios. El tablero resume. La terminal muestra el detalle del harness.
6. Claw puede fusionar y desplegar sin una confirmación por tarea cuando todas las compuertas de este documento están verdes.
7. `main` no ejecuta el merge ni entra a producción. Delega esas acciones a `implementer` o `ingenieria`, según el contrato del repo.
8. La autoridad automática de merge sustituye el requisito anterior de una orden textual de David por tarea. El registro de la corrida y las compuertas verdes son la autoridad auditable.

## Registro de trabajadores

Un archivo versionado define los trabajadores disponibles. Cada entrada contiene:

- Un identificador estable.
- El nombre del harness.
- La ruta configurable del ejecutable.
- El proveedor y el modelo, o el router administrado por el harness.
- Los tipos de tarea admitidos.
- Si puede leer, escribir, revisar o controlar un navegador.
- El modo de permisos permitido.
- Los comandos de `health`, inicio, reanudación y cierre.
- Los patrones de cuota, autenticación vencida y bloqueo.
- La ubicación de su transcript o el comando que devuelve la pantalla.

La primera versión incluye estas entradas:

| Trabajador | Harness | Comando instalado medido el 2026-09-19 |
|---|---|---|
| Claude | Claude Code | `claude` 2.1.278 |
| Codex | Codex CLI | `codex` 0.155.1 |
| GLM | ZCode | `zcode` 0.16.5 |
| Kimi | Kimi Code CLI | `kimi` 0.39.1 |
| Cursor | Cursor Agent CLI | `cursor-agent` 2026.09.18-9a7762b |
| Grok | Grok CLI | `grok` 1.0.34 |

Las rutas absolutas viven en la instalación de la Mac o en configuración local. El archivo versionado no contiene rutas de usuario, tokens ni credenciales.

ZCode es el harness normal de GLM. Un wrapper de Claude Code contra un endpoint compatible puede existir como trabajador distinto, pero nunca se presenta como ZCode ni sustituye a ZCode sin registrarlo en el tablero.

Cursor Agent es un trabajador administrado por Cursor. Si Cursor enruta internamente una solicitud, el tablero muestra el modelo que reporte la CLI o `unknown`. Una elección explícita de Claude, Codex, GLM, Kimi o Grok usa su harness nativo.

## Selección de un trabajador

El selector aplica filtros antes de puntuar. Descarta un trabajador si ocurre una de estas condiciones:

- El ejecutable no está instalado.
- La autenticación o la cuota no permiten iniciar el trabajo.
- El harness no tiene una capacidad requerida.
- El repo prohíbe ese harness o su modo de permisos.
- Otro escritor posee el worktree.
- La selección superaría cuatro harnesses externos activos.
- El mismo trabajador implementó el cambio y se intenta usar como única revisión cruzada.

Después de filtrar, el selector puntúa:

- Afinidad declarada con el tipo de tarea.
- Resultado histórico en el mismo repo y tipo de tarea.
- Disponibilidad inmediata.
- Cuota y coste disponibles.
- Diversidad respecto de los trabajadores que ya participaron.

El selector registra la puntuación, el ganador y las alternativas descartadas. Un empate usa el orden estable del registro. La selección nunca depende del orden en que responde la red.

El historial solo usa resultados cerrados: éxito vivo, reversa, bloqueo, duración y rondas de corrección. El texto libre del modelo no modifica la puntuación.

## Adaptadores de los harnesses

Todos los adaptadores implementan el mismo contrato:

```text
health(worker, repo) -> available | limited | unauthenticated | broken
start(run, lane, worktree, brief) -> session
deliver(session, brief) -> accepted | blocked
inspect(session) -> running | waiting | complete | failed
resume(session) -> resumed | unavailable
stop(session) -> stopped | already_stopped
```

El contrato normaliza el ciclo de vida, no la interfaz interna. Cada adaptador usa las opciones reales de su CLI. Por ejemplo, ZCode conserva sus modos `build`, `edit`, `plan` y `yolo`; Cursor Agent conserva `--auto-review`, `--sandbox` y `--worktree`; Codex conserva su TUI; Claude Code conserva sus permisos y hooks.

`agent-tmux.sh` crea la sesión. `corrida.sh` la registra y la marca antes de entregar el brief. El adaptador confirma que la caja de entrada se vació y que la CLI empezó a trabajar. Un exit 0 de `tmux send-keys` no prueba la entrega.

## Aislamiento y concurrencia

Cada carril que escribe nace desde `origin/<default>` en un worktree propio. El director verifica la rama por defecto desde el remoto. No usa la rama por defecto local como base.

El registro mantiene un candado por worktree. Solo el dueño del candado puede escribir. Un revisor usa un worktree de solo lectura o inspecciona commits ya creados. Cuatro sesiones pueden correr a la vez cuando sus zonas de escritura no se solapan.

Las tareas que cambian los mismos archivos se ejecutan en serie. El director puede paralelizar investigación, pruebas y revisiones de solo lectura.

## Flujo autónomo

1. `main` clasifica el pedido y crea los carriles.
2. El director abre la corrida y escribe el primer estado antes de lanzar un trabajador.
3. El selector elige un trabajador por carril.
4. El adaptador crea el worktree y la sesión `tmux`.
5. La Mac abre o adjunta una pestaña de Terminal a la sesión. Si la automatización de Terminal falla, el trabajo continúa y el tablero marca `visibilidad degradada` con el comando exacto de `tmux attach`.
6. El trabajador implementa y corre pruebas focalizadas.
7. El trabajador crea commits locales. Todavía no hace push ni abre un PR.
8. Un harness distinto revisa `origin/<default>..HEAD` y la evidencia local.
9. El implementador corrige todos los hallazgos de la ronda en un bloque.
10. Solo un bloqueante reproducible abre otra ronda. Cada ronda posterior revisa el diff desde el SHA que vio la ronda anterior.
11. Cuando el cross-review no tiene bloqueantes, el agente autorizado ejecuta push y abre un PR.
12. La CI del PR ejecuta la batería completa una vez sobre el SHA publicado.
13. CodeRabbit revisa el SHA publicado.
14. Si CodeRabbit encuentra un bloqueante, el PR permanece abierto. El implementador corrige localmente sin hacer push.
15. Un harness distinto revisa solo la corrección local.
16. Después de la aprobación local, el implementador publica el nuevo SHA en el mismo PR. CI y CodeRabbit vuelven a revisar ese SHA.
17. Las observaciones no bloqueantes van al plan y no abren otra ronda.
18. Con recibo persistente válido para el head actual, CI verde y revisiones sin bloqueantes, el agente autorizado fusiona; la disponibilidad de CodeRabbit sigue la política del plan.
19. `ingenieria` despliega o espera el sync, según el repo.
20. El verificador ejecuta el smoke y el canary contra el artefacto vivo.
21. Si el canary falla, el runbook revierte y verifica la reversa.
22. El director cierra la corrida y envía el resultado.

Un estado `sin cuota`, `unknown` o `timeout` de CodeRabbit no equivale a aprobación. Se declara y se aplica el límite de una reconsulta en 20 minutos del plan; las tareas independientes continúan. Con recibo válido, revisión independiente y CI vigente se aplica la política canónica de indisponibilidad, respetando los checks obligatorios de GitHub.

`CodeRabbit limpio` significa que CodeRabbit terminó de revisar el SHA y no dejó bloqueantes reproducibles abiertos; los residuales no bloqueantes se registran. El check por sí solo no basta. El director lee los comentarios.

La ruta normal ejecuta la batería completa una vez, después del primer cross-review. Si CodeRabbit descubre un bloqueante, el nuevo SHA invalida la CI anterior y ejecuta la batería completa otra vez. Esa repetición es una corrección excepcional, no una batería de desarrollo.

## Compuertas del SHA

Cada compuerta referencia evidencia persistente y su SHA. Un cambio de código exige validar su delta y la CI del head resultante. Reiniciar una sesión no invalida la evidencia. Un rebase mecánico sin diferencias de contenido conserva la revisión con correspondencia explícita de SHA; el recibo y la CI deben aplicar al head actual.

| Evidencia | Evidencia mínima |
|---|---|
| Cross-review | Harness revisor, SHA visto, veredicto y hallazgos con `file:line` |
| CI | Nombre de los jobs, conclusión verde y SHA |
| CodeRabbit | Estado limpio o hallazgos resueltos y SHA |
| Merge | `expectedHeadOid` igual al SHA verificado |
| Deploy | SHA vivo, destino y hora |
| Canary | Comando o recorrido, resultado observable y SHA vivo |

El merge exige el recibo persistente del kit y CI vigente. La indisponibilidad declarada de CodeRabbit sigue la política de disponibilidad del plan.

## Cambios a contratos existentes

Este diseño cambia reglas que hoy están versionadas. La implementación actualiza todas sus copias en el mismo bloque:

- `docs/runbooks/loop-autopilot.md` deja de abrir un PR draft antes del cross-review. El primer push y el primer PR ocurren después de cerrar la revisión local.
- Se conserva la política canónica de CodeRabbit indisponible declarado; no se introduce un veto por cuota específico de esta ruta.
- La ruta de merge consume el recibo `saikit-entrega.v1` persistente en el PR y la autorización de la corrida. No consulta el estado efímero del hook ni exige un modelo firmante.
- El contrato de la Fase 6 que prohíbe a `main` mergear se conserva. `main` decide y un agente de la allowlist ejecuta.
- Los runbooks base y las copias de `agent-dispatch` apuntan al contrato único. No reescriben el ciclo.

Las pruebas de contrato buscan las reglas viejas y fallan si una copia sobrevive.

## Tablero y terminales

`tablero-runbook` sigue siendo una interfaz de solo lectura. El director escribe el estado. El plugin lo valida, lo guarda y lo pinta.

Cada carril muestra:

- Tarea y rol.
- Trabajador, harness, proveedor y modelo reportado.
- Repo, rama y worktree.
- Nombre de la sesión `tmux`.
- Estado y tiempo transcurrido.
- Último evento.
- Estado de cuota o autenticación.
- Cross-review, CI y CodeRabbit con su SHA.
- PR, merge, deploy y canary.
- Estado de la terminal: visible, separada o degradada.
- Comando de solo lectura para adjuntar la terminal cuando la apertura automática falla.

La primera versión abre las pestañas de Terminal de forma automática mediante la ruta ya probada de la Mac. El tablero no ejecuta comandos arbitrarios. Un botón que abra una terminal solo se agrega si el SDK instalado permite una llamada autenticada con argumentos cerrados. Sin esa capacidad, el tablero muestra el comando exacto para adjuntarse.

El cierre archiva el transcript, la decisión de selección, los eventos y la evidencia. Después cierra la sesión `tmux`. El tablero conserva el resultado.

## Estado persistente y recuperación

El registro de `corrida.sh` es la fuente del ciclo de vida. El progreso del tablero es la vista para el operador. Ninguno depende de la memoria de un modelo.

Después de un reinicio, `main` reconcilia:

1. El registro de la corrida.
2. Las sesiones `tmux` vivas.
3. El estado de cada worktree y su HEAD.
4. Las ramas remotas y los PRs.
5. Las referencias de evidencia de cross-review, CI y CodeRabbit y el recibo del PR.
6. El SHA desplegado y el último canary.

La reconciliación precede cualquier operación con efecto externo. Si un push, PR, merge o deploy ya ocurrió, el director registra el efecto y continúa. No repite la operación a ciegas.

Si un harness falla durante la implementación, el director aplica el relevo por disponibilidad de `docs/runbooks/loop-autopilot.md` §9. Cuota agotada, rate limit explícito, autenticación vencida o ejecutable ausente descartan ese candidato sin reintentar la misma cuenta. Una caída sin causa conocida permite una reanudación. Antes del relevo confirma que el escritor anterior y sus hijos dejaron de escribir, reconcilia efectos pendientes y conserva el worktree, brief, commits, diff y evidencias. Registra los intentos y entrega a otro trabajador compatible; agotar candidatos detiene solo ese carril. Las pruebas específicas de un host conservan su host y quedan pendientes si no está disponible.

Compatibilidad: antes de activar esta ruta, las fases usan las preferencias y lanzadores del base del repo según loop §9. SummonAIKit conserva la verificación de roles, pruebas y recibos; no implementa un segundo selector. La Fase 23 puede avanzar sin instalar esta fase, y sus mediciones Muse/Claude y permisos de merge no cambian.

Un evento de silencio obliga a leer la pantalla. El silencio no significa éxito ni fin de turno.

## Permisos y secretos

Los trabajadores escriben solo en su worktree. Los briefs no contienen secretos, tokens ni valores de configuración viva.

Los trabajadores no ejecutan merge, cambios de configuración viva ni deploy. Los agentes autorizados usan adaptadores acotados para esas acciones. El registro conserva la razón y la evidencia.

La lista dura de `corrida.sh` sigue vigente. Ninguna preaprobación permite borrado recursivo, `DROP`, push a la rama por defecto, lectura de credenciales o comandos que exceden el trabajo declarado.

El modo sin preguntas de una CLI no amplía su zona de escritura ni las operaciones autorizadas.

## Fallos y degradación

| Situación | Acción |
|---|---|
| Harness limitado antes de empezar | Elegir el siguiente trabajador compatible y registrar el descarte |
| Límite durante un turno | Relevo del loop §9: conservar el worktree y descartar la cuenta limitada sin reintentarla; entrega registrada al siguiente compatible |
| Sesión desaparecida | Comprobar commits y transcript antes de relanzar |
| Diálogo esperando | Resolverlo con la política de `corrida.sh`; lo no cubierto llega a David |
| Terminal no visible | Continuar en `tmux`, marcar degradación y mostrar el comando de attach |
| CI no disponible | Esperar con backoff; no fusionar |
| CodeRabbit sin cuota o sin respuesta | Declarar indisponibilidad; aplicar la política del plan sin esperar renovación ni asumir aprobación |
| SHA del PR cambió | Revalidar recibo/CI para el head y revisar solo el delta de código; conservar historia y correspondencia de SHA |
| Merge ya aplicado tras un error de API | Leer el estado antes de reintentar |
| Canary falló | Ejecutar reversa, verificarla y avisar |
| Reversa falló | Marcar atención requerida y entregar la evidencia exacta |

## Pruebas

### Registro y selector

Las pruebas validan el esquema, los filtros, la puntuación estable y la razón registrada. Deben fallar si el selector permite un harness no autenticado, supera cuatro sesiones, asigna dos escritores a un worktree o usa al implementador como única revisión cruzada.

### Adaptadores

Cada adaptador pasa el mismo contrato contra dobles de `tmux` y de su CLI. Las pruebas cubren inicio, entrega, inspección, reanudación, cierre, límite de cuota, autenticación vencida y una caja de entrada que no aceptó Enter.

### Máquina de estados

Las pruebas cubren caída del director, eventos duplicados, sesión desaparecida, push ya aplicado, PR ya abierto, merge ya aplicado y deploy parcial. Repetir una operación converge al mismo estado.

### Orden de las compuertas

Las pruebas impiden:

- El primer push antes de un cross-review aprobado.
- El push de una corrección antes de revisar su delta.
- El merge sin CI verde.
- El merge con un bloqueante abierto.
- El merge con revisión del bot atribuida falsamente al SHA actual, o ignorando un check requerido por GitHub.
- El cierre sin canary o reversa verificada.

Cada rama principal tiene una prueba de mutación. Si se elimina la condición, la prueba queda roja.

### Tablero

El render cubre pendiente, trabajando, limitado, esperando, revisión, CI, CodeRabbit, deploy, revertido y terminado. También cubre escape de texto, auth, truncado, falta de fuentes derivadas y ausencia de secretos.

### Smokes reales

El rollout ejecuta una tarea mínima en un repositorio desechable con cada harness instalado. Cada smoke demuestra inicio, autenticación, entrega, transcript, evento de fin y cierre. La evidencia registra harness y versión. No registra credenciales.

### Canary integral

Una tarea pequeña y de bajo riesgo recorre selección, terminal visible, implementación, cross-review local, PR, CI, CodeRabbit, merge, deploy o sync y verificación viva.

Durante la implementación solo corren pruebas focalizadas. El PR ejecuta la batería completa una vez sobre el SHA final. Los hooks de pre-commit corren sin `--no-verify`.

## Despliegue por etapas

1. Publicar el registro de trabajadores y los adaptadores con selección en modo informe. No lanzar trabajos.
2. Intentar los smokes reales de los seis harnesses y habilitar solo los que pasen; mínimo dos para un rollout parcial, con revisor independiente. Indisponibles quedan deshabilitados y pendientes; el cierre completo conserva las seis mediciones reales.
3. Activar ejecución autónoma sin merge ni deploy en un repositorio de prueba.
4. Activar el ciclo completo en un cambio de bajo riesgo.
5. Activar el ruteo general con máximo cuatro sesiones.

Cada etapa tiene un interruptor de apagado. Apagar la selección automática conserva el flujo actual de `agent-dispatch`.

## Criterios de aceptación

El trabajo termina cuando se cumplen todos estos criterios:

- Un pedido único inicia una corrida sin que David abra terminales manualmente.
- El selector explica por qué eligió cada trabajador.
- Cada trabajador usa su harness registrado.
- El tablero muestra hasta cuatro carriles y sus terminales visibles.
- Ningún par de escritores comparte un worktree.
- El primer PR se abre después del cross-review local.
- Una corrección de CodeRabbit se revisa localmente antes del siguiente push al mismo PR.
- Merge registra el head revisado y el commit integrado; deploy y canary verifican el artefacto derivado de ese commit. Un squash no obliga a igualar hashes diferentes.
- Un canary fallido produce una reversa verificada o una alerta con evidencia.
- El agente `usuario` prueba el recorrido desde el pedido y el tablero sin leer el código del cambio.

## Fuera de alcance

- Sustituir las CLIs nativas por un único protocolo en esta versión.
- Controlar la aplicación gráfica de Cursor Composer.
- Entrenar o ajustar modelos.
- Mostrar o administrar credenciales desde el tablero.
- Permitir que el tablero edite el estado o ejecute comandos arbitrarios.
- Cambiar de harness en silencio durante una tarea.

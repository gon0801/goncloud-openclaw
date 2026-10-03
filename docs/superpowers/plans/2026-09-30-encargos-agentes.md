# Implementar encargos durables para todos los agentes

> Plan de ejecución. Las casillas reflejan trabajo comprobado; la autorización vigente viene de la instrucción posterior del usuario de implementarlo.

**Objetivo:** entregar resultados a su solicitante, continuar el trabajo tras una caída y verificar los límites de consumo y el cierre de trabajadores propios.

**Arquitectura:** amplía las tareas del runtime nativo y conserva su scheduler. Usa adaptadores de host para procesos y resultados. Conserva el director para decisiones de ingeniería y `progress-events.py` para publicar progreso.

**Tecnologías:** runtime y pruebas nativas de OpenClaw, según la revisión fijada en T0; Python y Bash 3.2 en las integraciones actuales; pruebas aisladas en macOS y Windows.

**Especificación:** [Encargos y continuaciones comunes](../specs/2026-09-30-encargos-agentes-design.md). Consulta las decisiones en [la comparación de arquitecturas](../specs/2026-09-30-encargos-agentes-rationale.md).

**Compatibilidad posterior:** [revisión U3b–U6](../../evidence/agent-work/compatibility-u3b-u6.md). Antes de integrar otra fase que toque `corrida`, conserva un solo decisor, un solo reloj y las identidades/recibos nativos; la revisión identifica las fronteras que aún faltan.

**Estado:** T0 comprobada; T1–T12 tienen implementación parcial y pruebas según sus casillas y recibos. T2 requiere revalidar la cola con entrega nativa tras retirar el despertar heredado. Sin adopción productiva. Las correcciones de presupuesto y propiedad de sesiones se verifican antes de integrar fases dependientes.

## Conserva estas condiciones en todas las tareas

- Deriva agente, sesión y ejecución de identidad autenticada. No uses `main` como destino fijo.
- Conserva las autorizaciones vigentes. Un resultado no concede permisos de herramientas, merge o despliegue.
- Mantén separadas aceptación del encargo, recepción del resultado, consumo y cierre del recurso.
- Conserva claves al reintentar. El `runId` autentica, pero no cambia la clave del encargo.
- Registra decisión, siguientes encargos y consumo en una transacción. `agent_end` no consume resultados.
- Guarda `ProjectionPending` con el resultado antes de confirmar su recepción.
- Ejecuta sondeo, transporte y limpieza con código. La vigilancia sin novedades produce cero solicitudes al proveedor.
- Limita el sobre a 8 KiB y cada resumen a 1 KiB. Mide además el contexto efectivo del modelo.
- Permite como máximo una recuperación automática adicional con modelo por raíz. No reinicies presupuestos al crear hijos.
- Conserva cupos ante incertidumbre. Solo libera recursos propios tras verificar su ausencia.
- Preserva sesiones adoptadas del usuario. No mates por nombre, antigüedad o PID sin identidad de inicio.
- Comprueba 72 horas simuladas sin inferencia de vigilancia, 100 reenvíos sin admisiones adicionales y 100 ciclos sin procesos propios abandonados.
- Mide detección en hasta 5 segundos y recepción en hasta otros 5 segundos con hosts despiertos y red sana. Haz visible una espera sin avance en hasta 120 segundos.
- Aplica las instrucciones vigentes de quality-kit. No heredes la excepción antigua de rondas del diseño U3b.

## Revisa estos cinco casos durante la implementación

1. Dos raíces independientes usan la misma clave textual. Deduplica dentro del alcance correcto, sin mezclar usuarios. Cúbrelo en T1.
2. Un agente pierde permiso después de encolar trabajo. Revalida al admitir sin aumentar permisos. Cúbrelo en T2.
3. Un recibo se pierde después de ejecutar una herramienta externa. Conserva incertidumbre sin repetir el efecto. Cúbrelo en T3 y T8.
4. Un padre termina su turno mientras el hijo sigue trabajando. Conserva propietario y presupuesto sin tratarlo como huérfano. Cúbrelo en T4 y T7.
5. Se reutiliza un PID o el servidor tmux cambia. Protege el proceso nuevo y conserva el cupo pendiente. Cúbrelo en T7.

## Prepara dos repositorios y un mapa verificable

Trabaja en dos repositorios. `G` es este repositorio, `gon0801/goncloud-openclaw`. `R` es el checkout del código fuente de OpenClaw que T0 debe identificar y fijar. La copia local instalada contiene `dist`, no `src`; no la uses como checkout de desarrollo.

Para esta redacción se leyó la versión local 2026.9.7 y su metadato de origen `https://github.com/openclaw/openclaw.git`. La evidencia previa del gateway corresponde a 2026.9.6. T0 debe verificar ambos artefactos; no supongas que esas versiones siguen instaladas ni las alinees modificando producción.

Guarda en `G/docs/evidence/agent-work/runtime-map.json` el origen, `sourceBaseSha`, la versión, la integridad del paquete y las rutas reales de `taskDomain`, `taskStore`, `scheduler`, `toolContext`, `providerBoundary`, `sessionLifecycle`, `migrations` y `nativeTests`. Añade los argumentos exactos de pruebas, build e instalación de ensayo. En las tareas siguientes, `R.taskStore` significa esa ruta comprobada, no un archivo que ya existe con ese nombre.

T0 es la única tarea que resuelve esas rutas. Comprueba que la revisión candidata desciende de `sourceBaseSha` y conserva las interfaces mapeadas. Registra el SHA candidato y el digest del diff en cada prueba focalizada; la evidencia final exige un commit limpio. Un commit de implementación no cambia por sí solo el mapa de la base. Si cambia la base o una ruta mapeada, actualiza y revisa el mapa antes de continuar. No inventes nombres del código fuente ni implementes una base paralela para evitar inspeccionarlo.

Las rutas marcadas **crear** en este plan son entregables futuros. Los comandos que las ejecutan solo se usan después de crearlas. Los ejemplos no son instrucciones para ejecutar durante la redacción del plan.

## Asigna propietarios y límites de edición

| Propietario | Puede modificar | No modifica |
|---|---|---|
| Lead | Plan, mapa de fuentes, evidencia resumida y orden de integración | Estado vivo, permisos de negocio y trabajo ajeno |
| Implementador nativo | Rutas comprobadas de `R`, pruebas y migraciones del runtime | Tablas vivas, paquetes instalados y scheduler alternativo |
| Implementador de host | `G/scripts/agent-work/`, adaptadores y sus pruebas | Sesiones personales, credenciales y configuración real |
| Implementador de integración | Progreso, `corrida`, contratos de despacho y sus pruebas | Reglas de merge, despliegue y política de revisión |
| Revisor | Diff, evidencia del SHA y reproducciones aisladas | Código fuera de su encargo o producción |
| Responsable de despliegue | Artefactos comprobados y procedimiento de T11 | Cambios fuera de una autorización posterior de despliegue |

Usa un escritor por worktree. Las ramas previstas son `feat/agent-work-b0` a `feat/agent-work-b5` en cada repositorio que participe en el bloque. T0 registra repositorio, ruta, rama y SHA base en `block-bases.json`. Usa para B0 una base revisada de `G` y la fuente trazable de `R`; fija la base de cada bloque posterior al resultado comprobado del anterior. Registra esa base antes de iniciar el bloque. No empieces desde el checkout principal antiguo de esta Mac.

Este plan admite desarrollo secuencial. T6 y T7 pueden prepararse después de T0 con dobles del contrato, pero su aceptación exige integrarlas con B1 y B2. No paralelices escritores sobre `R.taskStore`, `R.scheduler` o el registro de `corrida`.

## Aplica autorización, calidad y evidencia

La instrucción posterior del usuario autoriza implementar el plan en entornos aislados. La tabla conserva los límites de efectos vivos:

| Operación | Alcance | Decisión actual |
|---|---|---|
| Leer código y escribir el plan | Checkout de documentación | Aprobado |
| Implementar y ejecutar pruebas aisladas | Bloques B0 a B4 | Autorizado |
| Enviar cambios o abrir PR | Repositorios identificados en T0 | Pendiente de instrucción posterior |
| Llamar modelos reales, enviar avisos o tocar sesiones vivas | Cualquier host | No autorizado por esta tarea |
| Instalar, migrar base viva o desplegar | B5 | No autorizado por esta tarea |

Durante una ejecución autorizada, aplica [loop-autopilot](../../runbooks/loop-autopilot.md) §§3–6 para entrega y revisión, §7 para cambios vivos, §9 para reanudación y §10 para aceptación. Prevalecen las instrucciones actuales del usuario. Las instrucciones antiguas que escriben snapshots con `runbook.progress.set` no sustituyen el contrato de eventos vigente.

En cada tarea de código, añade primero la regresión, conserva su fallo, implementa y corre la prueba focalizada. No aceptes un fallo por credenciales ausentes o dependencia rota como reproducción del bug. Conserva evidencia del SHA y de la aserción discriminatoria.

Agrupa correcciones de revisión por bloque. Solo un bloqueante reproducible abre otra ronda; usa un revisor distinto y limita esa ronda al delta. Un bloqueante repetido en dos rondas requiere decisión del operador. Registra los hallazgos no bloqueantes que no quepan en la corrección en `docs/evidence/agent-work/followups.md` y en el PR.

Haz un commit revisable por tarea usando `git add` con sus rutas y `git commit` con los hooks activos. Ejecuta la batería completa una vez por bloque sobre el SHA final, preferentemente en CI. Reutiliza evidencia válida de ese SHA. Distribuye la batería en jobs cuya unión la cubra; divide un job que supere unos diez minutos. Mantén los checks de documentos en un job separado. Antes de medición viva o release, añade la revisión cruzada exigida por quality-kit y conserva su veredicto para los artefactos seleccionados.

En `G`, la entrada de la batería es `bash scripts/run-checks.sh`; CI usa `SAIKIT_SHARD=i/3`. No ejecutes esa batería durante esta redacción. En `R`, T0 fija el comando propio y los jobs necesarios. La batería de `G` no sustituye la del runtime.

Guarda los recibos de tarea como `docs/evidence/agent-work/T<n>.md`: SHA, comando, aserción, resultado y referencia al artefacto completo. No subas credenciales ni transcripciones privadas. Mantén `status.md` con bloque, tarea, evidencia válida y siguiente acción. Durante desarrollo informa al usuario en la sesión existente; no crees un cron para reportar progreso.

## Ordena los bloques por sus condiciones de salida

| Bloque | Tareas | Condición para avanzar |
|---|---|---|
| B0: fijar fuentes y reproducir | T0 | Mapa verificable, entorno aislado y reproducción de la carencia nativa |
| B1: conservar encargos y continuaciones | T1–T3 | Reinicio, concurrencia y consumo atómico en verde |
| B2: limitar costo y recuperar sin modelos | T4–T5 | Presupuestos heredados, recuperación acotada y observabilidad en verde |
| B3: controlar ejecutores de host | T6–T7 | Resultado portable y cierre de procesos propios verificado |
| B4: integrar y probar la cadena | T8–T10 | Progreso, director, agentes y matriz de aceptación en verde |
| B5: preparar y ejecutar adopción | T11–T12 | Artefactos, reversa y autorización posterior antes de tocar producción |

Las interfaces de las tareas son nombres de contrato propuestos. Fija su ubicación real en T0 y conserva los nombres entre tareas.

## Integra esta base antes de U3b y del adaptador OpenClaw de U4

La compuerta de integración exige código, revisión y pruebas de las interfaces que la fase siguiente usa, con el par G/R y la cobertura explícita de cada host/adaptador. No exige desplegar todas las combinaciones para desarrollar U3b o U4; tampoco permite declarar T0–T12 completos con un subconjunto. La activación de entradas certificadas se coordina con T11–T12 y conserva las demás deshabilitadas.

- U3b parte del reconciliador y los adaptadores integrados aquí. Conserva las decisiones de ingeniería, las reglas quality-kit vigentes y un solo emisor por generación. No implementa otra admisión ni sesiones supervisoras con modelo para encargos gestionados.
- U4 adapta identidades, recibos y recursos de T1–T8 para presentación y seguimiento. No duplica almacén de tareas, consumo, presupuesto o recuperación. Un sondeo de transporte no crea otro dueño de avisos; cupo de host y presupuesto de árbol mantienen causas diferentes.
- U5 reutiliza el contrato portable y las pruebas, pero conecta la autoridad nativa de Hermes. El camino Hermes debe funcionar sin ejecutable ni Gateway OpenClaw y conserva recibo propio. Este plan no implementa ni acredita Hermes por equivalencia.
- U6 conserva su alcance de DAG, revisión de plan, criterios y control de meta. Define en U6.1 el vínculo versionado a tarea/root/generación y exige que pausa/reanudación cercen efectos nativos sin reiniciar presupuesto. El manejo `complete` de un encargo nunca acredita por sí solo la meta completa.

Antes de integrar otra fase se actualizan juntos su plan, diseño, runbook y el ledger. Los cambios compartidos en `corrida` se integran en secuencia; la prueba del puente y las regresiones del módulo cambiado deben pasar sobre ese resultado. La [matriz de compatibilidad](../../evidence/agent-work/compatibility-u3b-u6.md) conserva riesgos y evidencia; una promesa escrita no sustituye su prueba.

### T0. Fija la fuente y reproduce la limitación nativa

Dependencias: ninguna. No escribas implementación del servicio en esta tarea.

Archivos por crear en `G`: `docs/evidence/agent-work/runtime-map.json`, `block-bases.json`, `capabilities.md`, `coverage.json`, `status.md` y `scripts/agent-work/test-runtime.sh`. En `R`, guarda el ensayo junto a sus pruebas nativas según el mapa.

Interfaz de salida: mapa de fuente y ejecutor de pruebas `test-agent-work-runtime.sh <caso>`. El ejecutor valida SHA, rutas y argumentos; invoca la prueba nativa real. Vive fuera de `scripts/tests/` porque ese director entra automáticamente en la batería de G, cuyos jobs no contienen el checkout de R. El job nativo lo invoca de forma explícita con `AGENT_WORK_RUNTIME_SOURCE`. No sustituye el runtime por un mock para declarar resuelta su admisión.

- [x] Inspecciona los metadatos de los artefactos instalados sin modificarlos.
- [x] Obtén un checkout de fuente trazable y fija su SHA completo. Registra el repositorio de entrega y el origen autorizado de sus artefactos.
- [x] Completa el mapa de rutas, build, pruebas, migraciones y compatibilidad de cliente, gateway y aplicación local.
- [x] Registra las bases iniciales de ambos repositorios y las ramas de B0 a B5 en `block-bases.json`. Deja las bases de bloques posteriores pendientes de su cierre predecesor; no uses un SHA supuesto.
- [x] Prepara un perfil aislado con directorios, puertos y sockets propios. Usa proveedor simulado y registra sus solicitudes desde fuera del runtime.
- [x] Reproduce la pérdida de deduplicación tras reinicio con el mismo encargo. Guarda el resultado como limitación de la base, no como fallo del entorno.
- [x] Prueba las capacidades de identidad de turno, consulta, presupuesto y cierre. Marca cada una `available`, `requires-change` o `unsupported`, con su evidencia.
- [x] Registra agentes, destinos, CLI, hosts y rutas de delegación en `coverage.json`. Distingue nativo, CLI y sesiones adoptadas.

Verifica con `bash scripts/agent-work/test-runtime.sh baseline`. Exige fuente trazable y evidencia de la limitación esperada. Si la versión ya la corrigió, conserva una prueba positiva y reutiliza la capacidad. Si no puedes obtener fuente o build reproducible, marca B0 bloqueado y no inventes un módulo alternativo.

### T1. Registra encargos, identidad y resultados durables

Depende de T0. Modifica `R.taskDomain`, `R.taskStore`, `R.toolContext` y `R.migrations`. Añade casos a `R.nativeTests`.

Produce `submit(Caller, TaskKey, Assignment)`, `report(ProducerCapability, generation, FinalResult)` e `inspect(AuthorizedCaller, TaskId)`. Usa los tipos del diseño. Conserva `TaskKey` entre turnos y separa estado de entrega y manejo.

- [x] Añade `registration_identity`: misma clave y contenido devuelve el mismo ID; otro contenido da conflicto; dos solicitantes no colisionan.
- [x] Añade `result_receipt`: productor ajeno, generación antigua, digest incorrecto y revisión equivocada no avanzan la tarea. Una incidencia de permiso no ocupa el resultado final. El contrato `review.v1` valida el payload; otros contratos requieren esquema antes de habilitar sus rutas.
- [x] Ejecuta ambos casos y conserva las aserciones rojas.
- [x] Implementa las transacciones y la migración versionada dentro del almacén nativo. Persiste resultado, pendiente de manejo y `ProjectionPending` antes del ACK cuando corresponda.
- [x] Repite las pruebas con reinicio entre escrituras y confirma los recibos recuperados.

Verifica con `bash scripts/agent-work/test-runtime.sh registration_identity` y `bash scripts/agent-work/test-runtime.sh result_receipt`. Espera código cero y todas las aserciones, sin saltos.

### T2. Haz durable la admisión y la cola de la sesión

Depende de T1. Modifica `R.scheduler`, `R.taskStore`, `R.toolContext` y sus pruebas.

Consume el registro de T1. Produce `admit(AdmissionKey, ExecutionTarget, InputRefs, BudgetReservation)` y consulta durable de admisión. Revalida permisos al admitir. Mantén deshabilitada la entrada productiva hasta disponer del presupuesto de T4.

- [x] Añade `admission_restart`: dos emisores y reinicio antes o después de admitir generan una sola admisión lógica.
- [x] Revalida `requester_queue` en la entrega gestionada actual: una sesión ocupada recibe su continuación después de reiniciar; una sesión eliminada produce bloqueo y no otra conversación. La evidencia antigua del despertar heredado no acredita esta ruta.
- [x] Añade revocación de permiso entre registro y admisión. Exige rechazo sin ejecutar herramientas.
- [x] Ejecuta las pruebas en rojo.
- [x] Implementa reclamación exclusiva, cola persistente y consulta con exclusión durable de solicitudes anteriores. No traduzcas timeout a `NeverStarted`.
- [x] Comprueba también una solicitud retrasada que llega después de una consulta de ausencia.

Verifica con los casos `admission_restart` y `requester_queue` del ejecutor nativo. Exige los mismos IDs tras reinicio y cero peticiones adicionales por reenvío.

### T3. Confirma consumo junto con la siguiente acción

Depende de T2. Modifica `R.taskDomain`, `R.taskStore`, `R.sessionLifecycle` y sus pruebas.

Produce `resolve(Caller, HandlingReceipt, Decision)` y `cancel(AuthorizedCaller, TaskId, reason)`. Deriva claves de hijos del recibo y del `slot`.

- [x] Añade `handling_atomic`: decisión, hijos y recibo aparecen juntos o no aparece ninguno, incluso con dos consumidores.
- [x] Añade `handling_unresolved`: `agent_end` sin `resolve` conserva el resultado pendiente.
- [x] Añade cancelación concurrente, callback tardío y herramienta externa con efecto incierto. Exige evidencia conservada y ningún reenvío ciego.
- [x] Ejecuta los casos en rojo.
- [x] Implementa consumo, cancelación y recuperación de la misma decisión. Captura resultados antes de cualquier eliminación automática de hijos.
- [x] Repite con pérdida del ACK de consumo. Recupera los mismos hijos, sin nueva revisión.

Verifica con `handling_atomic` y `handling_unresolved`. Al cerrar B1, ejecuta la batería nativa completa sobre su SHA final y registra el artefacto construido.

### T4. Impón presupuestos a todo el árbol

Depende de T3. Modifica `R.providerBoundary`, `R.taskStore`, `R.sessionLifecycle` y sus pruebas. Crea `G/docs/evidence/agent-work/limits.json` con los valores del perfil de ensayo y sus fuentes.

Produce `reserveModelCall(rootId, requestUsageBound)` y `settleModelCall(reservationId, providerUsage)`, integradas en todas las llamadas gestionadas. Los nombres se enlazan a la frontera real fijada en T0.

- [x] Añade `budget_tree`: hijos concurrentes, reintentos y padre cuyo turno termina conservan el límite agregado.
- [x] Añade `budget_context`: cuenta sistema, historial, herramientas, adjuntos, salida y caché sin doble suma.
- [x] Prueba ausencia de métricas y proveedor sin límite de salida. Conserva reserva o rechaza la garantía estricta.
- [x] Ejecuta las pruebas en rojo.
- [x] Implementa reserva previa, liquidación y perfiles finitos. Incluye límites de concurrencia, profundidad, hijos y llamadas.
- [x] Intenta eludir el límite con un hijo nuevo, una sesión nueva y la recuperación nativa. Incluye `managed_tasks_submit` desde un run hijo activo, cancelado y recuperado: no crea otra raíz/presupuesto ni escapa del árbol de cancelación. Exige rechazo antes del proveedor; los hijos válidos siguen la continuación nativa con la raíz original.

Verifica con `budget_tree`, `budget_context` y `budget_evasion`. El perfil productivo se fija en T11 usando configuración y medición reales; no extrapoles el perfil pequeño del ensayo ni cambies silenciosamente un límite existente.

### T5. Recupera pendientes y muestra su causa sin inferencia

Depende de T4. Modifica `R.scheduler`, `R.taskDomain`, `R.providerBoundary` y sus pruebas.

Consume `inspect`, admisión y recibos. Produce recuperación determinista por identidad e incidencias deduplicadas. Expón edad, causa, recibo, hijos, reservas y uso del árbol mediante consulta autenticada.

- [x] Añade `idle_72h`: adelanta el reloj 72 horas con reconexiones y hooks repetidos. Exige cero solicitudes al proveedor y cero sesiones de vigilancia.
- [x] Añade `recovery_limit`: un fallo elegible permite una recuperación automática adicional por raíz; el siguiente conserva bloqueo sin otra llamada.
- [x] Añade `waiting_reason`: distingue cola ocupada, transporte caído, resultado inválido y admisión incierta en hasta 120 segundos.
- [x] Ejecuta las pruebas en rojo.
- [ ] Implementa la recuperación sobre la cola nativa y sus eventos de capacidad. No abras supervisores ni scouts de lectura.
- [x] Comprueba el contador externo del proveedor y la ausencia de rutas de recuperación que lo evadan.

Verifica con `idle_72h`, `recovery_limit`, `waiting_reason` y `recovery_queue`. Cierra B2 con la batería nativa del SHA final.

### T6. Entrega y recoge resultados de los CLI por identidad

Depende de T0 para preparar dobles y de B1–B2 para aceptar la integración. Crea `G/scripts/agent-work/host.py`, `contracts.py`, `spool.py`, `scripts/tests/test-agent-work-host.py` y su entrada `test-agent-work-host.sh`. Modifica `scripts/mac/corrida/adaptador.sh` y `lanzar-sesion.sh`.

Produce `Host.apply(OperationKey, AuthorizedOperation)` y el informe portable que consume `report`. Un CLI ficticio sin hooks debe cumplir el mismo contrato.

- [x] Añade `host_receipts`: registro antes de entrega, ACK vinculado al encargo y un solo encargo activo por instancia.
- [x] Añade informe parcial, credencial ajena, versión antigua y salida cero sin informe. Ninguno acredita entrega válida.
- [ ] Ejecuta las pruebas en rojo con socket tmux y directorios de ensayo.
- [x] Implementa entrega por referencia, escritura atómica de resultados y spool hasta recibo durable. Usa `hostId` explícito para cada lectura.
- [x] Repite cien veces el informe y pierde su ACK. Exige un resultado y el mismo recibo.

Verifica con `bash scripts/tests/test-agent-work-host.sh host_receipts`. Corre además `bash scripts/tests/test-native-harness-adapters.sh` cuando cambie su adaptador. No uses `~/bin`, el tmux personal ni un proveedor real.

### T7. Reserva recursos y verifica su cierre

Depende de T6. Crea `G/scripts/agent-work/resources.py`. Modifica `host.py`, `scripts/mac/corrida/terminar-sesion.sh`, `cerrar.sh` y las pruebas de host.

Produce reserva idempotente de host, identidad resistente a reutilización y `AbsenceVerified` o `CleanupPending`. El runtime conserva la reserva del árbol hasta recibir prueba válida.

- [ ] Añade `resource_identity`: PID reutilizado, reinicio del host, cambio de servidor tmux y sesión adoptada. Una sesión preexistente sin prueba de creación no se clasifica como pool propio por carecer de nonce. Cubre claim, replay, cierre y cierre repetido; exige cero señales a recursos ajenos.
- [ ] Añade `resource_close`: caída entre reserva y lanzamiento, descendiente desacoplado, ACK perdido y stop fallido.
- [ ] Ejecuta los casos en rojo.
- [ ] Implementa captura de evidencia, contención o rastreo de descendientes, detención y verificación. Sustituye éxito aparente tras fallo de stop por cierre pendiente en la ruta gestionada.
- [ ] Comprueba que terminar el turno del padre no abandona al hijo y que un host inaccesible no libera cupo.
- [ ] Ejecuta `resource_100_cycles`. Exige cero procesos propios abandonados y cuentas separadas para historial y pool intencional.

Verifica los tres casos con `test-agent-work-host.sh`. Certifica cada combinación de host y adaptador de `coverage.json`; una combinación sin prueba permanece deshabilitada. Cierra B3 con la batería de `G` y la integración nativa del mismo par de artefactos.

### T8. Enlaza resultados con progreso y con el director

Depende de B1–B3. Crea `G/scripts/agent-work/progress_bridge.py`, `scripts/mac/corrida_worker/task_handoffs.py` y `scripts/tests/test-agent-work-integration.sh`. Modifica `progress-events.py`, `corrida_worker/reconcile.py`, `state.py` y `corrida/reconciliar.sh`.

Produce `transferProjection(pending)` con confirmación por ID y contenido, y `applyTaskResult(record, result)` para el director. Conserva las decisiones de negocio en el reconciliador existente.

- [ ] Añade `projection_crash`: cae después del ACK de resultado y antes de encolar progreso. Reconstruye el mismo evento desde `ProjectionPending`.
- [ ] Añade pérdida del ACK de transferencia y tablero caído. Exige evidencia retenida, cola convergente y ninguna revisión repetida.
- [ ] Añade `director_handling`: persiste decisión antes de `resolve`; perder su respuesta conserva la misma corrección. Dos consumidores no generan dos efectos.
- [ ] Ejecuta los casos en rojo.
- [ ] Implementa los puentes usando los IDs del contrato de progreso existente. No guardes otra bandera autoritativa de consumo en `corrida`.
- [ ] Integra las transiciones definidas de revisión: `Changes` prepara el delta de corrección; `Approved` conduce a la compuerta vigente. Un caso que requiere juicio vuelve al solicitante registrado.
- [ ] Si el director U3b aún no está implementado, añade solo esas transiciones al reconciliador existente y sus contratos. No construyas otra máquina de estados ni incorpores su antigua política de rondas.

Verifica `projection_crash` y `director_handling` con `test-agent-work-integration.sh`. Corre `bash scripts/tests/test-progress-events-client.sh` y `bash scripts/tests/test-corrida-reconcile.sh` para los límites modificados.

### T9. Conecta todas las rutas de delegación gestionadas

Depende de T8. Modifica las entradas nativas identificadas en T0, `scripts/mac/claude-stop-openclaw-event.sh`, `tmux-activity-watch.sh`, `corrida/avisos.sh`, los lanzadores y los contratos de despacho inventariados. Actualiza `coverage.json` y `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md`; incluye las otras skills solo si T0 identifica su ruta real.

Consume las cinco operaciones del diseño. Produce un único camino gestionado por encargo, con identidad y presupuesto heredados.

- [ ] Añade `agents_routing`: ingeniería solicita a adversary, operaciones solicita a ingeniería y un agente solicita a un CLI remoto. Incluye un agente registrado que no se llame `main`.
- [x] Añade `delegation_bypass`: una ruta gestionada intenta enviar o crear un hijo sin contrato. Exige rechazo sin eludir la política de permisos.
- [x] Añade `hook_is_observation`: Stop o quietud sin informe no despierta un modelo.
- [ ] Ejecuta los casos en rojo.
- [ ] Migra cada entrada del inventario y actualiza sus instrucciones en el mismo cambio. Los cron de negocio conservan horarios y función.
- [ ] Conserva las rutas anteriores fuera del perímetro gestionado hasta su adopción explícita. Dentro del perímetro, impide que un reparador recree el vigía antiguo.
- [ ] Añade `main_cli_loop`: `main` solicita a un CLI en una sesión adoptada de `mac-local`, como en los loops de claw. El encargo sale de una sesión durable de `main`, nunca de un turno `isolated` de cron. El CLI entrega `agent-work.result.v1` por referencia en lugar de los archivos `LISTO`/`VEREDICTO`, y el informe despierta solo a la sesión que hizo `submit`. Mientras el CLI trabaja, cero solicitudes al proveedor. Registra la ruta en `coverage.json` y `routing.py` y actualiza `agent-dispatch` de `main`. La sesión adoptada se retira sin matar procesos, como `UserAdopted`; sin prueba, la ruta queda deshabilitada y su vigía se conserva.
- [ ] Añade `cli_silent_failure`: el CLI de esa ruta cierra su sesión sin informe, abre un diálogo de permiso, vence su plazo o entrega un informe inválido. Cada caso produce una sola incidencia durable con causa (`PermissionRequired`, `DeadlineMissed`, `TransportUnavailable` o resultado inválido) que despierta una vez a la sesión solicitante. Ningún caso abre turnos periódicos de modelo.
- [ ] Añade `cli_delivery_acceptance`: el host da por entregado un encargo a un CLI solo cuando el propio CLI escribe una aceptación ligada a ese encargo; teclear la referencia o verla en pantalla no cuenta. Sin aceptación en el plazo del encargo, la entrega queda `uncertain` con incidencia `TransportUnavailable` para el solicitante y no se vuelve a teclear a ciegas. Incluye una sugerencia fantasma en el composer y una sesión ocupada que no tomó la entrada.
- [ ] Inventaría en `coverage.json` los despertares con modelo de cada entrada: cron `*-vigia`, `corrida/latido.sh` con `vigia=claw` y avisos a `agent:main:vigia-mac`. Guarda ID, cadencia y recreadores, incluidos el `PROMPT.md` y `arranque.txt` de cada loop y la plantilla `~/.claude/skills/prompt-claw/SKILL.md`, que crea un `<loop>-vigia` por loop.

Verifica con `test-agent-work-integration.sh agents_routing`, `delegation_bypass`, `hook_is_observation`, `main_cli_loop`, `cli_silent_failure` y `cli_delivery_acceptance`. Reutiliza `test-agent-dispatch-spawn.sh` y `test-corrida-avisos.sh` para sus contratos modificados. No declares cobertura total mientras quede una fila gestionada sin prueba.

### T10. Prueba la cadena completa y prepara la integración

Depende de T9. Crea `G/scripts/tests/test-agent-work-e2e.sh`, `docs/evidence/agent-work/acceptance.md` y `followups.md`. Conecta las nuevas pruebas al runner de su repositorio sin excluir pruebas existentes.

- [ ] Añade `review_tail_restart`: el revisor entrega, la respuesta sale de las últimas 80 líneas y el solicitante reinicia. Exige una corrección registrada y aceptada sin recordatorio humano.
- [x] Añade `delivery_latency` con reloj controlado: desde la escritura durable del informe hasta su detección, hasta 5 segundos; desde la detección hasta el recibo durable, hasta otros 5 segundos. Simula hosts despiertos y red sana; guarda ambas mediciones por separado.
- [ ] Añade las fronteras de caída de la especificación con un contador externo de procesos y peticiones. Comprueba los resultados de dominio, no solo filas de la base.
- [ ] Ejecuta los casos en rojo antes de corregir cualquier fallo de integración.
- [ ] Completa la matriz de aceptación enlazando cada caso con su prueba y el par de SHA de `G` y `R`.
- [ ] Ejecuta las pruebas focalizadas y resuelve los hallazgos del bloque.
- [ ] Construye el artefacto nativo con integridad registrada. Ejecuta una sola vez las baterías completas del bloque en los jobs correspondientes.
- [ ] Prepara los PR con las dependencias exactas, evidencia y limitaciones de adaptadores. Conserva deshabilitada la admisión productiva.

Verifica con `bash scripts/tests/test-agent-work-e2e.sh review_tail_restart` y `acceptance`. La aceptación exige también `delivery_latency`, `idle_72h`, `resource_100_cycles` y los cien reenvíos, con evidencia reutilizada del mismo SHA cuando sea válida.

### T11. Prepara instalación, adopción y reversa

Depende de B4. Esta tarea prepara procedimientos y ensayos; no activa producción. Crea `G/docs/runbooks/agent-work-cutover.md`, `docs/evidence/agent-work/deploy-commands.md`, `artifact-manifest.json`, `scripts/agent-work/cutover.py` y `scripts/tests/test-agent-work-cutover.sh`. Modifica `scripts/mac/instalar-mac.sh` y su prueba para instalar los archivos de host nuevos.

Interfaz prevista: `cutover.py prepare`, `inspect`, `apply` y `rollback`, con manifiesto, generación y alcance explícitos. `apply` y `rollback` requieren autorización registrada y se ensayan primero con dobles.

- [ ] Fija las versiones, SHA, hashes, migraciones y compatibilidad en el manifiesto. Verifica que el paquete corresponde al código revisado.
- [ ] Escribe los comandos reales de instalación y recuperación a partir de T0. No uses el publicador de plugins como instalador del runtime nativo.
- [ ] Define el perfil productivo finito en `limits.json`, con los valores obtenidos de configuración y medición. Un valor desconocido impide habilitar esa capacidad.
- [ ] Añade y ejecuta en rojo `cutover_fencing`: dos emisores, resultados en vuelo, sesión activa y admisión incierta. Incluye un cron antiguo suspendido: conserva captura de resultados, drena sus turnos en vuelo y exige cero peticiones posteriores de ese cron y un solo propietario.
- [ ] Implementa adopción sin reiniciar sesiones, cambio de propietario por generación y captura persistente durante la transición.
- [ ] Ensaya reversa del binario y de la configuración. Comprueba compatibilidad con el esquema migrado; si el binario anterior no puede abrirlo, conserva la versión nueva con admisión congelada y usa el procedimiento probado de recuperación.
- [ ] Prueba fallos del propio rollback y conserva pendientes. No reactives automáticamente cron de cinco minutos.

Verifica con `bash scripts/tests/test-agent-work-cutover.sh`. El entregable incluye comandos ejecutados en ensayo, salidas esperadas, duración máxima y acción ante cada fallo. No incluyas comandos productivos supuestos o sin probar.

### T12. Ejecuta adopción y aceptación viva cuando se autorice

Depende de T11, artefactos revisados e instrucción posterior de despliegue. Esta tarea permanece pendiente en la entrega del plan.

- [ ] Comprueba la autorización, los hashes, la revisión cruzada y una ventana sin trabajo que la instalación pueda interrumpir. Si no puedes verificar la ventana, pospón el cambio vivo.
- [ ] Instala mediante el procedimiento probado con admisión nueva deshabilitada y captura de resultados activa. Relee versiones, archivos y capacidades del runtime real.
- [ ] Clasifica resultados previos como consumidos, pendientes o antiguos. Conserva los casos inciertos sin reenviarlos.
- [ ] Suspende los despertares antiguos de la entrada controlada y guarda sus IDs y configuración. Drena o concilia sus turnos en vuelo; conserva la captura de resultados. No toques cron de negocio ajenos a esa entrada.
- [ ] Transfiere la propiedad por generación y habilita la admisión de esa entrada. Comprueba que solo hay un emisor. Ejecuta dos entregas y una incidencia de permiso sin aprobarla.
- [ ] Usa las dos entregas para una revisión controlada con `Changes` y una operación sin SHA. Comprueba aceptación del encargo de corrección sin modificar un repositorio de negocio. Cancela y cierra ese trabajador de prueba por su identidad, sin producir entregas adicionales.
- [ ] Comprueba la proyección del tablero y el cierre verificado de todos los trabajadores de prueba.
- [ ] Con los turnos anteriores drenados y los trabajadores de prueba cerrados, mide 30 minutos sin novedades. Usa contadores externos de proveedor, sesiones y procesos del perímetro adoptado. Exige cero inferencia atribuible a vigilancia.
- [ ] Tras comprobar consumo y esa ventana, retira definitivamente los despertares suspendidos y sus recreadores automáticos de la entrada migrada. Continúa con las entradas certificadas de `coverage.json` repitiendo la suspensión y transferencia verificadas.
- [ ] Repite la suspensión, la ventana de 30 minutos y el retiro con la ruta `main` → CLI adoptado de los loops de claw. Después, cambia la plantilla `prompt-claw` para que un loop nuevo sobre esa ruta no cree `<loop>-vigia`. Un loop que no pueda usarla conserva su vigía y lo declara.
- [ ] Ante fallo, congela admisión nueva, conserva resultados y ejecuta la reversa probada. No repitas el canary como carga continua.
- [ ] Ejecuta el checklist posterior una vez. Guarda `docs/evidence/agent-work/deploy-receipt.md` con hashes, generación, contadores, recursos restantes y cobertura efectiva.

No declares completado el arreglo si el único verde es el tablero. Exige continuidad observada, cero sondeo con modelos y cierre comprobado. Describe los adaptadores no habilitados como limitaciones, sin prometer cobertura que no se midió.

## Resuelve interrupciones con estas reglas

| Situación | Acción y condición de salida |
|---|---|
| Falta fuente o no reproduce el artefacto | Marca B0 bloqueado. Conserva diagnóstico; no modifiques producción ni inventes equivalencia. |
| Cambia la base o una ruta mapeada de R | Actualiza y revisa el mapa antes de seguir. Invalida solo la evidencia afectada; los commits de implementación normales no cambian la base. |
| Fuente obtenida pero falta admisión durable | Implementa la ampliación nativa en B1. No habilites el servicio ni construyas un scheduler alternativo. |
| Ejecutor sin presupuesto o cierre verificables | Marca la capacidad no certificada. Completa el resto de pruebas aisladas, pero no habilites esa fila. |
| Resultado o efecto incierto | Conserva `NeedsReconciliation`. Consulta por identidad; no reenvíes por timeout. |
| Host inaccesible o stop fallido | Conserva cupo y `CleanupPending`. Reintenta consulta con código y verifica ausencia antes de liberar. |
| Principal revocado o sesión eliminada | Bloquea destino. No amplíes permisos ni abras otra sesión. |
| Presupuesto agotado | Conserva la tarea y la causa. No crees otro árbol para obtener presupuesto nuevo. |
| CI o hook falla | Corrige el fallo. No omitas comprobaciones ni uses `--no-verify`. |
| Bloqueante vuelve en dos rondas | Detén ese bloque y solicita decisión del operador según la regla vigente. |
| Caída del lead | Lee `status.md`, recibos y SHA. Reutiliza resultados válidos; no relances encargos por falta de memoria. |
| Falta autorización viva o ventana verificable | Entrega los artefactos preparados. Mantén T12 pendiente. |
| Reversa falla | Conserva admisión congelada, pendientes y evidencia. Ejecuta solo la recuperación ensayada de T11. |

## Clases de comando

| Clase | Uso futuro | Límite |
|---|---|---|
| `gh` | Consultar CI y preparar PR cuando se autorice ejecución | Sin merge ni publicación durante esta redacción |
| `ssh` | Inventario autorizado y adopción de hosts | No despertar agentes ni modificar producción antes de T12 |
| `red externa` | Obtener fuente y artefactos verificables | Proveedor simulado hasta el canary autorizado |

## Comprueba cobertura antes de declarar el plan ejecutado

| Requisito del diseño | Tareas que lo entregan |
|---|---|
| Fuente y capacidades verificadas | T0 |
| Contrato multiagente, identidad, permisos y operaciones sin SHA | T1, T2, T9 |
| Admisión, cola, consumo y cancelación durables | T2, T3 |
| Presupuesto heredado y cero inferencia de vigilancia | T4, T5 |
| Informes CLI portables, aceptación y generaciones | T6 |
| Propiedad, contención y cierre verificado | T7 |
| Proyección sin pérdida y decisiones del director | T8 |
| Cobertura de callers y eliminación de vías paralelas | T9, T12 |
| Reproducción del incidente y matriz completa | T10 |
| Artefactos, instalación, adopción y reversa | T11, T12 |

El alcance comprende trece tareas, de T0 a T12. No fija duración ni costo monetario sin medir el runtime y los ejecutores. No incluye reconstruir todo U3b, cambiar la política de calidad ni limpiar sesiones personales.

Entrega final: recibo del par de artefactos instalados, pruebas asociadas a sus SHA, continuidad observada, consumo atribuible y recursos propios restantes. Las casillas se actualizan solo con evidencia; alinear los planes dependientes no completa sus fases ni este plan.

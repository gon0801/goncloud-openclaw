# Fase U6: terminar metas compuestas con autonomía verificable

Fecha: 2026-09-24. Estado: planificado, implementación no iniciada.
Base revisada: `origin/main` en `cafe7d93329db0bebab241ae524eda9c50406f18`.
Ledger: [Fase U6](../../../Plans.md#fase-u6--metas-compuestas-con-autonomía-verificable).
Contrato superior: [especificación](../../spec/00-project-spec.md#metas-compuestas-contrato-objetivo-de-u6).

## Encargo y resultado

David pidió comparar U2–U5 con la autonomía discutida y planificar sólo lo que
falte como U6. El resultado objetivo es dar una meta o plan y recibir su resultado
verificado, sin reconfirmaciones dentro de la autorización aplicable. Terminar un
turno, cambiar de CLI o reiniciar no pierde el trabajo. Cien por ciento significa
todos los criterios obligatorios acreditados sobre el resultado vigente.

Esta entrega autoriza redactar, comprobar y publicar el plan. No ejecuta U6,
concede permisos nuevos, cambia modelos, instala servicios, mergea ni despliega.
Es un plan de implementación; no es un runbook listo para lanzar una fase viva.

## Qué ya cubren U2–U5

La comparación usa los contratos versionados, no sólo el estado instalado.
`cc:TODO` significa pendiente de aceptación, no falta de diseño. En la revisión
inicial U2 y U3 aún estaban abiertos. El ledger vigente ya acredita sus cierres;
U4 y U5 siguen pendientes. Usa los recibos actuales de `Plans.md`, no el estado
histórico de PR #152 o #153, para decidir dependencias.

| Necesidad | Dueño y cobertura existente | Residuo que sí pertenece a U6 |
|---|---|---|
| Permisos sin preguntas rutinarias | U2: 9.1–9.3, 9.6, política y diálogos; U3: 14.1–14.2 modos CLI y 14.4 autoridad persistente | Vincular la meta a la política y comprobar coherencia efectiva entre instrucciones, CLI, host y ruta de entrega al iniciar y reanudar |
| Meta convertida en trabajo verificable | U4: 17.1, identidades, unidades, criterios y revisión del plan | Generar/importar un plan ejecutable, validar dependencias y cobertura, conservar criterios al dividir o reparar tareas |
| Ejecución encadenada | U3: 14.1–14.2 selector/CLI/worktree; 14.5 reducer; 14.6 director | Elegir unidades habilitadas por resultados, avanzar entre ellas y reconciliar revisiones de una meta completa |
| Recuperación sin duplicados | U3: 14.5 intenciones y reconciliación; U4/U5: 17.4 supervisor y presupuesto; encargos nativos: registro, admisión, resultado y consumo durables | Caída en la transición entre unidades, vínculo de cada unidad con su encargo nativo, eventos tardíos y control persistente de pausa/cancelación de la meta |
| Cierre por evidencia | U2: 9.11–9.12 usuario y cierre; U3: 14.5/14.7 recibos/canary; U4: 17.1 y aceptación 8 | Agregar aceptación de todos los criterios del plan vigente, invalidando evidencia afectada por cambios posteriores |
| Merge/deploy autónomos | U1 sync seguro; U3: 14.4 autoridad y 14.5/14.7 entrega/read-back/reversa | Reutilizar esas rutas con autoridad inicial suficiente para la meta, incluida selección de artefacto futuro cuando esté expresamente autorizada |
| Seguimiento y Hermes | U2 reloj global; U4 panel; U5 misma aceptación con identidad/estado propios | Proyectar la meta agregada y comprobar su recorrido por host; no crear panel, reloj ni failover nuevos |

Fuentes: [F14 diseño](../specs/2026-09-19-native-harness-orchestration-design.md),
[F14 tareas](2026-09-19-native-harness-orchestration.md),
[F17 diseño y diez recorridos](../specs/2026-09-22-centro-tareas-design.md),
[F17 tareas](2026-09-22-centro-tareas.md), [corrida.v2](../../spec/corrida.v2.md)
y las decisiones de recuperación/U1 del ledger y `.saikit/decisiones/u1-sync.tsv`.

## Decisiones y dependencias

- Extender el reducer/reconciliador de U3 y el supervisor de U4/U5. `main`
  conserva la dirección y propiedad del progreso. El módulo de plan determina
  elegibilidad y valida transiciones; no decide por su cuenta cambios de producto.
- Task Flow y `/goal` son capacidades del runtime, no otra base de autoridad.
  Sólo se usan a través de la frontera de U3/U4 si está probada. Un flujo
  persistido no demuestra un lanzamiento ni una reanudación soportada.
  Referencia: [Task Flow oficial](https://docs.openclaw.ai/automation/taskflow).
- La [base de encargos gestionados](2026-09-30-encargos-agentes.md) aporta la
  identidad de tarea y raíz, generación, admisión, resultado, consumo y reservas.
  U6 consume su contrato nativo verificado; el plan de la meta sólo decide qué
  unidad queda habilitada y si se cumplieron los criterios agregados. No guarda
  otro estado autoritativo de tarea ni despacha por una ruta anterior en paralelo.
  El código U6 y sus pruebas aisladas pueden avanzar contra una base integrada
  y verificada para las rutas bajo prueba. La aceptación viva de cada host exige
  además el recibo de adopción de esas rutas en ese host; no exige adoptar todos
  los CLI ni esperar al otro host. Un módulo aislado o un recibo ajeno no acredita
  una ruta viva.
- Un único mecanismo de vigilancia y entrega por instalación; eventos y tick
  existentes despiertan la reconciliación. Sin cron por meta ni segundo servicio
  periódico. Se conservan `corrida.sh` y los recibos `saikit-entrega.v1`.
- Dependencia técnica OpenClaw: U4 aceptada, que incluye U2, U3 y U3a (Fase 19),
  más la base nativa de encargos integrada y verificada para las rutas usadas.
  Su aceptación viva exige adoptar esas rutas. Hermes añade U5 y una base
  equivalente verificada y adoptada en su propio host, sin consultar el gateway,
  la cola ni las credenciales de OpenClaw. Si falta esa capacidad, Hermes queda
  bloqueado; OpenClaw puede acreditarse por separado, sin declarar paridad.
  La prioridad de la ruta sigue U2, U3, U3a, U4, U5, U6; investigación/contratos de
  U6.0–U6.1 pueden prepararse antes sin activar ejecución. Si se implementa
  primero la parte OpenClaw de U6, no acredita Hermes ni el cierre bilateral.
- Se corrige el ciclo documental U4 → 17.4 → 17.3/U5 → U4: 17.4 empieza con
  OpenClaw tras 17.2, y se adapta/prueba en Hermes tras 17.3. Paquete, revisión
  y aceptación de 17.6–17.8 se entregan por host; el cierre bilateral permanece.
  El runbook integral F17 permanece inhabilitado hasta reflejar esa división.

## Contrato propuesto

Extensión aditiva del modelo U4, con nombre propuesto `meta-autonoma.v1`:
`goal_id`, `plan_revision`, criterios estables, unidades con dependencias,
alcance, `authorization_ref`, referencias de presupuesto/intento/evidencia y
control persistente. Los nombres definitivos se fijan en U6.1 contra el contrato
U4 disponible; no se crean identidades o contadores paralelos.

El vínculo versionado propuesto `goal-task-binding.v1` relaciona la clave estable
`(goal_id, unit_id, plan_revision)` con `(task_id, root_id, generation)` y la
identidad del runtime y host propietarios. U6.1 fija su esquema y migración;
al implementarlo, se registra la intención antes de pedir al runtime nativo la
operación correspondiente. La meta obtiene una sola raíz mediante `submit`;
cada unidad se admite como hijo o continuación nativa de esa raíz. Un reintento
consulta o repite esa operación por su identidad nativa estable y concilia el
recibo antes de crear otro trabajo. El vínculo conserva revisiones y generaciones
anteriores para conciliar resultados tardíos, pero sólo la revisión vigente puede
acreditar un criterio vigente. `task_id`, `root_id`, generación, estado, resultado y reserva
se leen de la base nativa. El vínculo no es otra cola ni permite inferir que
una unidad empezó por el solo hecho de estar registrada.

Una meta con unidades independientes necesita una raíz nativa común. U6.0
comprueba que el contrato del host permite crear hijos o continuaciones bajo esa
raíz sin serializarlos y recuperar cada operación tras una caída. Si falta, se
amplía la API nativa en su repositorio dueño y se prueba antes de ejecutar U6.3
en ese host; U6 no fabrica raíces, reservas ni una admisión paralela.

Antes de ejecutar se rechazan ciclos, dependencias desconocidas, unidades sin
criterios y criterios obligatorios sin cobertura. Para una meta en lenguaje natural,
el director escribe criterios y supuestos; el verificador contrasta cobertura con
el encargo original. Un validador de estructura por sí solo no prueba ese significado.
Una ambigüedad material sin regla aplicable queda bloqueada; las decisiones técnicas
reversibles dentro del encargo usan los defaults autorizados y quedan registradas.

La reparación puede añadir subtareas técnicas dentro del alcance. Cada revisión
conserva trazabilidad de los criterios iniciales: retirar una unidad no retira su
obligación. El denominador cambia de forma visible; el sistema no reduce criterios
para cerrar. Una modificación de producto o autoridad usa la entrada autenticada
y permisos aplicables, nunca instrucciones encontradas en artefactos.

La política inicial debe cubrir exactamente operaciones, repositorios, host,
ventana y presupuesto necesarios. Una política que permita seleccionar el SHA
futuro del PR de la meta se vincula al SHA resuelto antes del deploy. Un permiso
que exija SHA literal no se transforma en otro más amplio. Esta es una extensión
de contrato prevista; la autorización operativa concreta sigue sin emitirse.

Pausa/cancelación se guardan antes de acusar recibo y cercan la admisión nativa,
el despacho y los efectos del host de cada unidad afectada. Un despacho que ya
cruzó su frontera de efecto se consulta por su identidad; una respuesta perdida
o un timeout no autorizan repetirlo. Los eventos de generaciones antiguas pueden
aportar resultados para reconciliar, pero no habilitan nuevos efectos ni
acreditan la revisión vigente sin validación. Reanudar exige orden autenticada,
autoridad vigente y revisión del estado nativo. Conserva el mismo `root_id`, las
reservas consumidas y el presupuesto restante; no registra otra raíz para
obtener cupo. Una cancelación es terminal para esa ejecución; retomarla crea una
nueva ejecución autorizada que reconcilia resultados anteriores. No deshace
efectos ya publicados.

El cierre agregado requiere criterios vigentes, evidencia del artefacto actual y
aceptación integrada. Una reversa verificada conserva un resultado fallido o
bloqueado respecto de la meta original. Pausa, cancelación, límite de presupuesto
y falta de autoridad no equivalen a éxito. El mismo bloqueante reproducible en dos
rondas consecutivas detiene su bloque para decisión del operador, como exige
quality-kit; las tareas independientes pueden continuar.

## Tareas y archivos

Los IDs, dependencias y estados canónicos viven en `Plans.md`. Estos apartados
detallan su ejecución y pruebas; ninguna ruta propuesta se presenta como instalada.

### U6.0 — Inventario residual y contrato de integración

Leer recibos de U2–U5, interfaces públicas por versión, política vigente, pruebas,
registro de workers y formato de estado. Mapear cada punto de la matriz a código,
prueba y recibo o `unknown`. Archivos propuestos de evidencia:
`docs/evidence/u6-cobertura.md` y `docs/evidence/u6-capacidades.md`.

Por host, inventariar la versión y el recibo de adopción de la base nativa de
encargos, sus operaciones autenticadas `submit`, `inspect`, `resolve` y `cancel`,
la API de hijos o continuaciones con recuperación idempotente, la admisión real
de cada ruta, el presupuesto de raíz y el cierre de ejecutores.
Registrar qué rutas certificadas aceptan una unidad U6 y cuáles siguen
deshabilitadas. U6.1 puede proponer la extensión de una operación ausente; U6.3
puede codificarse y probarse de forma aislada contra la API nativa integrada y
verificada. Su ejecución viva espera el recibo de adopción de las rutas usadas
en ese host.
Comprobar también la raíz común y el presupuesto compartido de dos unidades
independientes; una carencia queda en el dueño de la base nativa.

Medir inicio, fin y continuación con el adaptador existente en entorno desechable
cuando esté autorizado; sin interfaz soportada, bloquear sólo la integración de ese
host. No parchear `dist` ni simular éxito. Registrar lint/formatter existentes;
si faltan para módulos nuevos, registrar el faltante para U6.1.
No reformatear el repo. Resultado visible: alcance pendiente y capacidades por host.

### U6.1 — Meta y plan ejecutable

Resolver primero cualquier faltante de lint/formatter registrado en U6.0, con
una base focalizada para los módulos nuevos; comprobarla antes de escribirlos.
No reformatear el repo.

Crear el contrato propuesto `docs/spec/meta-autonoma.v1.md`, extender el contrato
de centro de tareas entregado por 17.1 y añadir validación/importación/generación
en la frontera existente. Módulo sugerido `plan.py` junto al reducer U3; ubicación
final portable fijada por U6.0. Tests de comportamiento en `scripts/tests/` y
fixtures bajo `scripts/tests/fixtures/metas/`.

Definir `goal-task-binding.v1` como vínculo recuperable, no como segundo registro
de tareas. Definir una identidad estable para el `submit` de la meta y otra para
la operación nativa de cada unidad bajo la misma raíz, con alcance autenticado y
digest del encargo. Registrar el vínculo de la meta con su raíz y los vínculos
de cada unidad con su tarea. U6.1 verifica qué identidades de reintento ofrece la API;
si no admite hijos o continuaciones recuperables, especifica su extensión en el
dueño nativo antes de depender de ella. No presupone que el caller pueda fijar
una `TaskKey` ni llama `submit` por unidad. Tras una caída entre operación nativa
y vínculo, consultar o repetir esa misma operación recupera el `task_id` previo;
el mismo identificador con otro contenido da conflicto. Sólo un recibo o
consulta nativos actualizan `root_id` y `generation`. Un cambio de plan crea
otra revisión sin borrar el vínculo anterior ni reiniciar el presupuesto de la
raíz vigente.

Probar plan aportado y meta natural, cobertura semántica, DAG válido, ciclo,
referencia inexistente, criterio omitido, IDs repetidos y revisión desactualizada.
Probar también `submit` repetido de la raíz, reintento de hijo o continuación,
conflicto de contenido, caída entre cada recibo nativo y su vínculo, versión de
vínculo desconocida y resultado tardío de otra revisión.
Una migración de versión conserva los vínculos y recibos anteriores. El DAG y
la cobertura pertenecen a U6; el estado del encargo se consulta a la base nativa.
Ninguna entrada inválida lanza procesos. Resultado visible: unidades y criterios
del encargo, con dependencias y supuestos consultables.

### U6.2 — Autoridad y permisos efectivos

Extender preflight/política U2, registro y adaptadores U3, `agent-dispatch` y ruta
de entrega existente. Inventariar `USER.md`, `AGENTS.md` y skills instaladas por
host; proponer su delta en su repo dueño, sin escribir copias vivas ni ensanchar
la allowlist global. U6.0 fija los archivos exactos y sus repos antes de editar.

Probar por CLI admitida y rol, en `start` y `resume`, una operación autorizada
que normalmente solicite permiso. Registrar versión, política efectiva y cero
consultas; los nombres `acceptEdits`, `workspace-write` o `yolo` no son evidencia.
Comprobar que la autoridad autenticada de la meta se reduce al alcance del
`submit` de raíz y de cada admisión de hijo, continuación y `resolve` nativos.
Una revocación entre selección de unidad y admisión impide efectos; la revisión
de permisos no se delega al texto del plan.
Probar autoridad caducada, revocada, host/PR incorrecto y política de SHA literal
frente a selección autorizada de SHA futuro. Verificar con un doble de CLI la
negativa de acciones ajenas; no habilitar permisos globales para probar el rechazo.
La lista dura del contestador sigue vigente: merge sale por el kit autorizado.
Resultado visible: ninguna reconfirmación rutinaria en el recorrido autorizado;
lo ajeno queda bloqueado con motivo y no detiene unidades independientes.

### U6.3 — Avance y reparación de la meta

Extender reducer/reconciliación de 14.5 y supervisor 17.4. Los archivos previstos
por U3 son `scripts/mac/corrida_worker/{state,reconcile}.py` y la frontera
`corrida-worker.py`; U6.0 debe resolverlos al código portable real, no duplicarlos.
Admitir sólo unidades con dependencias verificadas. Persistir la decisión de
elegibilidad y la intención del vínculo versionado; crear la raíz nativa una vez
por meta y enviar cada unidad como hijo o continuación por una ruta certificada
de esa raíz. Conciliar el recibo de la operación nativa antes de afirmar que
empezó; un ACK perdido se recupera por la identidad de esa operación.
Consumir cada resultado mediante `resolve`, que guarda el recibo y los hijos
atómicamente. La selección U6 conserva el DAG y la revisión; la base nativa
conserva cola, resultado, manejo y presupuesto. Una respuesta tardía de otro
intento se reconcilia sin sobrescribir la revisión vigente.

Probar caída antes/después de cerrar una unidad y antes/después de lanzar la
siguiente, dos reconciliadores concurrentes, evento repetido y cambio de plan.
Exigir un solo `task_id` por vínculo, un solo consumo lógico por recibo y ninguna
admisión nueva por ACK perdido. Dos unidades paralelas comparten la misma raíz
y su presupuesto restante; la revisión nueva no permite crear otra raíz para
eludir el límite.
Con dos ramas independientes, la espera de CI de una no bloquea la otra. Un fallo
corregible vuelve al ciclo de calidad vigente. No resetear presupuesto al reiniciar.
Resultado visible: la siguiente tarea empieza sin mensaje de David después del
cierre del turno inicial, con historial y avance conservados.

### U6.4 — Pausa, cancelación y reanudación durables

Extender el control de meta en las entradas autenticadas OpenClaw/Hermes y el
registro existente. Reutilizar `stop/inspect/resume` de adaptadores U3, comprobando
identidad del proceso. Sin botones nuevos en el panel ni rutas HTTP de shell.

Persistir la intención de pausa o cancelación antes del ACK y aplicarla a cada
tarea nativa vinculada. Cercar una admisión que aún no cruzó su frontera de
efecto; si ya la cruzó, conservar su identidad y conciliar resultado y cierre.
La reanudación de una pausa verifica de nuevo autoridad, revisión, generación,
recibos pendientes y presupuesto. Continúa bajo el mismo `root_id` y sus
reservas; no crea otro árbol ni repite un efecto incierto. La cancelación ordena
al runtime nativo impedir continuaciones de la generación cancelada y conserva
los resultados tardíos para consulta.

Probar pausa/cancelación concurrentes con despacho, caída antes de la respuesta,
repetición de la orden, evento tardío y reinicio. Tras persistir el control no se
admiten nuevas acciones; las ya iniciadas se observan/reconcilian. Sólo una orden
válida reanuda una pausa; cancelar no revive por fallback. Resultado visible:
«pausada» o «cancelada» permanece tras reiniciar y conserva el resultado parcial.
La prueba de reanudación compara `root_id`, reservas consumidas y presupuesto
restante antes y después; una identidad de ejecutor incierta mantiene el bloqueo.

### U6.5 — Cierre integrado y proyección

Extender cierre U2/U3 y resumen/proyección de U4. El tablero y Telegram consumen
el mismo resultado agregado redactado; se conserva el literal legacy
`runbook-progress.v1` hasta una migración específica. Un plan vacío no cumple
una meta; cualquier caso sin trabajo exige prueba explícita del resultado pedido.

U6 es propietario del DAG, los criterios, la revisión vigente y el veredicto
agregado. Cada criterio apunta al recibo nativo y a la evidencia del artefacto
vigente; una tarea en `registered`, `admitted`, `pending-handling` o
`NeedsReconciliation` no cuenta como aceptada. El cierre exige el consumo nativo
de todos los resultados requeridos y una comprobación integrada de la meta.
El porcentaje usa el conjunto de criterios vigente con trazabilidad a los
originales; reparar o retirar una unidad no borra una obligación.

Probar evidencia vieja, pruebas rojas, autodeclaración `LISTO`, criterio eliminado,
artefacto cambiado tras verificación y reversa exitosa de una meta incumplida.
Cada caso impide 100% y cierre exitoso. La prueba positiva incluye resultado final
integrado, no sólo pruebas aisladas de unidades. Resultado visible: pendientes,
porcentaje y recibo de meta coherentes, con enlaces a evidencia del resultado actual.

### U6.6 — Integración, publicación y aceptación por host

Preparar el runbook sólo con comandos e interfaces implementados por U6.0–U6.5.
Resolver el arranque por frase «empieza la Fase U6»: el launcher actual sólo acepta
números, por lo que debe incorporarse un alias/ruteo probado sin reutilizar Fase 6.
No se prescribe hoy `lanzar-fase.sh U6` como comando disponible. El runbook hereda
base/loop y lleva progreso inicial, espejo, autoridad, cola, atasco y reversa por host.

Preflight y demo se hacen en un proyecto desechable con una meta de tres unidades,
dos independientes y una dependiente, criterios observables y autoridad acotada.
La aceptación cubre los doce escenarios siguientes. OpenClaw requiere U4; Hermes
requiere además U5 y corre con OpenClaw inaccesible. Mantener recibos separados
`docs/evidence/u6-aceptacion-openclaw.md` y `u6-aceptacion-hermes.md`. Si sólo uno
pasa, se declara cobertura parcial y U6 permanece pendiente de cierre bilateral.
Cada recibo incluye la versión efectiva del vínculo fijado en U6.1, las
identidades de raíz y tareas, la generación efectiva, el presupuesto restante y
el recibo de la base nativa adoptada en ese host. El ensayo de Hermes usa su
propio registro, cola,
credenciales y ejecutores con OpenClaw inaccesible; no presenta un proxy al
gateway de OpenClaw como independencia.

## Aceptación integral

1. Plan importado y meta natural producen unidades que cubren el encargo original.
2. Ciclo, referencia ausente y criterio sin cobertura se rechazan antes de lanzar.
3. Dependientes esperan verificación; otra rama avanza mientras la primera espera
   CI. Ambas conservan una raíz y presupuesto común por meta.
4. Finaliza el turno del director y continúa el plan sin una nueva orden del dueño.
5. Un test falla, se corrige y se acredita el resultado actual antes de avanzar.
6. Una caída entre `submit` de raíz o admisión nativa de unidad y su vínculo
   recupera el mismo `task_id`. Caída entre unidades y evento duplicado
   convergen sin otro escritor, nueva raíz ni nuevo reloj.
7. Efecto sin recibo se consulta: si ya ocurrió no se repite; si es incierto no se
   declara éxito ni se repite a ciegas. Reutilizar la reconciliación U3/U4.
8. Operaciones autorizadas no preguntan en inicio/reanudación; las ajenas no se
   ejecutan. Una política revocada o agotada sigue así después de reiniciar.
9. Pausa/cancelación cercan admisión y efectos nativos; respuesta perdida y
   eventos tardíos no reviven trabajo. Reanudar conserva raíz, reservas y presupuesto.
10. Borrar criterio, reciclar evidencia, decir `LISTO` o completar rollback no produce
    cumplimiento ficticio; modificar el artefacto invalida los criterios afectados.
11. El mismo bloqueante reproducible en dos rondas detiene ese bloque sin merge;
    el bloqueo queda visible y no se convierte en un pendiente para cerrar falsamente.
12. Todos los criterios vigentes y aceptación integrada permiten cerrar tras
    consumir sus resultados nativos, con un recibo por host y evidencia del otro
    runtime inaccesible en la prueba de independencia.

## Entrega, verificaciones y autoridad

Implementar secuencialmente U6.0, U6.1, U6.2; después U6.3/U6.4 en el mismo carril
para no competir por el reducer; luego U6.5 y U6.6. Rama propuesta de código
`faseu6/metas` desde `origin/main` recién obtenido; una integración por bloque
verificable si el tamaño obliga, con archivos y base escritos en el brief. El lead
reconciliará la ruta al iniciar; no incorpora cambios del checkout antiguo.

Pruebas focalizadas durante cada cambio y test que atrape cada bug. Hooks sin
saltos. Batería completa una vez por bloque sobre el SHA final en CI de PR; si
CI no la ejecuta, correrla completa localmente una vez. Conservar resultados
válidos sin repetirlos. Revisión según quality-kit/loop: sólo bloqueantes
reproducibles abren otra ronda, nuevo revisor y sólo diff de arreglos. Para cambios
de autoridad/recuperación se recomienda revisión cruzada con
`/Users/dn/quality-kit/cross-review.ps1`; medición viva/release la exige. El
checklist de aceptación se ejecuta una vez por host y build autorizado.

No instalar o ejecutar U6 ahora. Al solicitar su implementación se resuelve el
alcance operativo al principio y se guarda la autorización existente aplicable;
no se vuelve a preguntar por lo cubierto. Ausencia real de permisos conserva
el bloqueo y permite avanzar trabajo independiente. No se crea un grant en este PR.

| Operación | Autoridad en esta entrega |
|---|---|
| Documentos, revisión, hooks, rama, push, PR y CI del plan | Pedido actual de planificación |
| Código, lanzamiento de CLIs y pruebas de comportamiento U6 | Pedido posterior de implementación |
| Merge, sync, instalación, permisos y canaries vivos | Referencia explícita por alcance/host/ventana; reutilizar las vigentes que sí lo cubran |
| Saltar calidad, inventar autorización, borrar datos o secretos en Git | Fuera del alcance |

Un único PR de cierre `faseu6/cierre` actualiza ledger y recibos tras integración
y aceptación; no marca filas terminadas por tener código. Si no hay autorización
para una operación viva, permanece pendiente sin afirmar cumplimiento completo.

## Validación de la planificación

`Spec delta`: contrato objetivo U6 en `docs/spec/00-project-spec.md` y corrección
de dependencia por host F17. `team_validation_mode: subagent`: producto/cobertura,
arquitectura y seguridad/QA compararon independientemente U2–U5. Memoria consultada:
decisiones de U1, reconciliación de Fase 9, diseños F14/F17 y loop del repo.

Required: U6.0–U6.6 y aceptación bilateral para cierre completo. Recommended:
revisión cruzada temprana de autoridad y recuperación antes del canary.
Optional: botones de control del panel. Reject: plugin orquestador paralelo,
segunda base de verdad, segundo reloj, respuestas universales a permisos, cambiar
modelos como arreglo incidental, failover entre hosts y garantía de terminar una
meta imposible. La falta de una dependencia aceptada se conserva en su fase dueña.

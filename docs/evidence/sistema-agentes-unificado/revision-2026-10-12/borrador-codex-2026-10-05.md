# Plan: Sistema unificado de agentes

Fecha: 2026-10-05. Identificador: **SUA**. Estado: **diseño, sin implementación autorizada**.

Este es el único programa futuro para U3b, U4, U5, U6 y flota. Integra la adopción
selectiva de OpenCode y la sustitución de quality-kit como coordinador obligatorio.
Sus planes anteriores son antecedentes; no se ejecutan en paralelo ni se suman
como una segunda batería de aceptación.

- [Diseño y contratos](../specs/2026-10-05-sistema-agentes-unificado-design.md).
- [Cobertura de todas las filas y aceptación](../../evidence/sistema-agentes-unificado/cobertura.md).
- [Fuentes, decisiones y revisión](../../evidence/sistema-agentes-unificado/revision.md).

## Resultado y alcance

Un pedido de dominio o ingeniería avanza entre agentes nativos y CLI, con poteto,
especialistas competentes, modelos acreditados, límites persistentes, revisión y
evidencia. Los agentes nuevos se conectan automáticamente cuando cumplen su perfil.
Los sucesores de modelos se promueven tras comprobar acceso y capacidad. OpenClaw
y Hermes funcionan en sus computadoras con estado y credenciales independientes.

La solicitud actual permite diseñar y revisar documentos. No permite implementar,
lanzar trabajadores, instalar, cambiar modelos vivos, enviar mensajes, mergear ni
desplegar. Una autorización futura se interpreta con su alcance real y se conserva;
no se vuelve a pedir para cada paso que ya cubra. Escribir este plan no la concede.

## Bases y preparación

| Código | Base inspeccionada | Uso |
|---|---|---|
| G | `/Users/dn/dev/wt/flota-poteto`, `e5cae2de223b505802d5f29238663faf6a444a7e` | Diseño aislado de cambios ajenos; no es producción. Main remoto observado: `77fafb0f66e595d6a4812c3591d09627315dde82`. |
| R | `/Users/dn/dev/openclaw-agent-work-integration`, `6e3d428bf81c54effa0e06c67726e3a5ce90a24e` | Runtime con tareas durables y `Continue`; capacidades por comprobar en instalación. |
| O | `/Users/dn/dev/goncloud-Orbit`, `25cebe7be1be938be5f55c0b05299961732f72b7` | Receta de deploy existente; automatización pendiente. |
| H | Instalación, repo, plataforma y versión pendientes de inventario | No se inventan flags ni se usa OpenClaw como proxy. |

Antes de implementar se reconcilian estas bases con los commits aprobados. El PR
#247 contiene código previo que este diseño no acepta. Su discrepancia de modelo
mediante un salto de línea en argv tiene reproducción pendiente de corrección;
se incorpora a SUA-03 antes de admitir esa ruta. U1/U3/U3a/Fase14 conservan sus
recibos; sólo se repite evidencia invalidada o de un perímetro nuevo.

## Orden y dependencias

Un bloque puede integrar código sin activar producción. Cada integración registra
el par de versiones G/R o el paquete Hermes que la acredita. Las dependencias son
de artefactos; compartir contratos no crea dependencia de disponibilidad entre hosts.

| Bloque | Entrega | Depende de | Estado |
|---|---|---|---|
| SUA-00 | Inventario residual, contratos y fixtures comunes | — | pendiente |
| SUA-01 | Estado, DAG y control atómicos en OpenClaw | SUA-00 | pendiente |
| SUA-02 | Controlador, autoridad y excepciones | SUA-01 | pendiente |
| SUA-03 | Poteto, perfiles y rutas nativo/CLI/OpenCode | SUA-02 | pendiente |
| SUA-04 | Catálogo, promoción y alta automática | SUA-03 | pendiente |
| SUA-05 | Ingeniería y calidad propias del sistema | SUA-02, SUA-03 | pendiente |
| SUA-06 | Proyección, avisos y LobsterBoard | SUA-02 | pendiente |
| SUA-07 | Implementación Hermes independiente | SUA-00 | pendiente |
| SUA-08 | Automatización de deploy de Orbit | SUA-05 | pendiente |
| SUA-09O | Paquete y transición exclusiva OpenClaw | SUA-04, SUA-05, SUA-06 | pendiente |
| SUA-09H | Paquete y transición exclusiva Hermes | SUA-04, SUA-05, SUA-06, SUA-07 | pendiente |
| SUA-10O | Aceptación OpenClaw y Orbit | SUA-08, SUA-09O | pendiente |
| SUA-10H | Aceptación Hermes | SUA-09H | pendiente |
| SUA-11 | Retiro residual y cierre del programa | SUA-10O, SUA-10H | pendiente |

SUA-07 puede empezar con el contrato sin esperar el código de R. SUA-09H consume
formatos, políticas y fixtures de SUA-03–06; no llama sus servicios OpenClaw.
La parte OpenClaw de SUA-10O puede emitir su recibo antes del ensayo Orbit; el
bloque completo espera ambos. Hermes no bloquea ese recibo ni el de Orbit.

## Regla de ejecución futura por bloque

1. Leer las obligaciones del bloque y su autoridad. Reclamar recursos de escritura.
2. Abrir un cambio acotado sobre una base conocida, con worktree por escritor.
3. Reproducir cada bug antes de corregirlo y conservar su prueba en el mismo cambio.
4. Ejecutar pruebas focalizadas. Guardar comandos, salidas y artefactos redactados.
5. Revisar los hallazgos agrupados. Corregir bloqueantes bajo la política vigente.
6. Ejecutar hooks y la batería completa una vez sobre el commit final, reutilizando
   CI del mismo artefacto y entorno. No usar `--no-verify` ni recortar shards.
7. Registrar recibo, límites y estado; activar sólo el perímetro autorizado y probado.

SUA-05 implementa la nueva política de cuatro ciclos; su activación exige un recibo
de adopción autorizado por repo/host. Hasta ese recibo siguen vigentes las reglas
actuales del usuario. Un revisor no convierte
un defecto bloqueante en residual para permitir el cierre. Un límite agotado deja
el bloque detenido, con diagnóstico y resultado parcial.

Los nombres de ensayos I01–I24 siguientes son especificaciones futuras. No son
scripts ya instalados. SUA-00 fija su manifiesto y cada bloque implementa su caso
en el harness nativo; no se crean ejecutables vacíos para simular aceptación.

## SUA-00 — Inventario y contrato

**Dueño:** G, con lectura de R/O y del host H autorizado.

**Archivos:** `docs/evidence/agent-work/runtime-map.json`, contratos existentes en
`docs/spec/`, inventarios efectivos de agentes/CLI, configs de sync e instaladores.
Nuevos: `docs/spec/sistema-agentes.v1.md` y fixtures de contrato bajo
`scripts/tests/fixtures/sistema-agentes/`.

1. Registrar por ruta versión, ubicación, dueño, autoridad, resultado, recibo y
   capacidad `passed/failed/unknown`. Separar fuente, instalado y aceptación viva.
2. Fijar esquemas de meta/unidad/resultado/evidencia/control/flota/excepción y
   compatibilidad de versiones. Enumerar productores y consumidores a migrar.
3. Medir despertar por evento y mensaje: gateway ocioso/ocupado, sesión nueva,
   `/new`, tokens, latencia, `NO_REPLY`, aislamiento y borrado remoto de sesiones
   de ensayo propias. Elegir el verbo con evidencia, no por preferencia.
4. Definir baseline de coste y latencia del ciclo actual; documentar lo que no se
   puede medir. Verificar lint/formatter de R y configurar alcance de módulos
   nuevos en G antes de su primer cambio de código, sin reformatear todo el legado.
5. Publicar fixtures de planes válidos/inválidos, autoridad negativa, resultados y
   proyección. Fijar IDs I01–I24 y el inventario de consumidores de quality-kit.

**Verificar:** I01/I02; cada capacidad tiene prueba y recibo o `unknown`. El
inventario de H pendiente bloquea sólo su integración. Las mediciones vivas se
hacen únicamente cuando la futura autorización las cubra. No se cierran con mocks.

## SUA-01 — Frontera durable OpenClaw

**Dueño:** R. **Archivos:** `src/agents/tasks/managed-task.{db,store,types}.ts`,
handling, admission, budget, recovery y sus tests; entrada gateway correspondiente.
Nuevo módulo propuesto: `src/agents/goals/`, con decisiones separadas del store.

1. Añadir revisión de plan, época, claims, binding único, capacidad del solicitante
   y contadores persistentes. Migrar datos con versión y reversa compatible.
2. Implementar creación inicial de unidades y fan-in transaccional junto a tareas,
   sin fabricar resultados padres ni escribir tablas desde G.
3. Incluir control, reservas, reclamación de escritor y efectos en la misma frontera.
   Serializar `Prepared → Started` con pausa: es el permiso de inicio, no el ACK
   del destino. El recibo de pausa enumera efectos comprometidos o inciertos.
4. Recuperar recibos después de ACK perdido, reinicio y fallo intermedio. Revalidar
   autorización al admitir y antes de iniciar un efecto.

**Verificar:** I03/I04/I05/I06/I20. Inyectar fallos antes/después del commit; competir
dos reconciliadores; pausa y revisión ganan a admisiones obsoletas. Ensayar también
Started antes de pausa y envío después de su ACK: el recibo identifica ese efecto,
que no se presenta detenido. Control repetido devuelve recibo; otro Resume con
época obsoleta falla. Repetir un
resultado no crea escritor ni presupuesto. Probar pares con dos y tres plazas
ocupadas de cuatro. Los controles nativos de presupuesto existentes siguen verdes.

## SUA-02 — Controlador y autoridad

**Dueño:** R para control local; G para adaptadores/recetas. **Archivos:** módulo
`src/agents/goals/` propuesto; `scripts/mac/corrida_worker/{reconcile,task_handoffs,state}.py`,
entradas `corrida.sh` y skill `native-harness-orchestration` como consumidores.

1. Implementar `open/control/reconcile/read` con funciones puras internas de meta,
   ingeniería y flota. Importar Plans o pedido natural sin perder criterios.
2. Vincular solicitante durable, identidad autenticada y autoridad heredada. Una
   nueva sesión no toma una raíz por conocer su ID. Un hijo no crea otra raíz.
3. Seleccionar unidades aceptables; continuar ramas independientes; reparar dentro
   del alcance; invalidar sólo evidencia afectada por revisiones acreditadas.
4. Migrar las once clases de excepción antiguas a un enum explícito y añadir las
   necesarias para evidencia/capacidad incierta. Conservar IDs, opciones válidas,
   entrega al propietario, respuesta única y reaviso máximo de una vez por hora.
5. Conectar scheduler y eventos existentes; observación en sombra sin despachar.
   Reemplazar el decisor legacy por adaptadores de entrada al nuevo dueño.

**Verificar:** I01–I07/I12. Tres entradas: pedido pequeño, fila importada y pedido
compuesto. El turno termina y la meta continúa. Respuestas con cero/una/varias
excepciones no se aplican a otra. Un pedido grande autorizado no pregunta por
ritual; crear repo o enviar mail sin autoridad sí queda detenido.

## SUA-03 — Poteto y trabajadores especializados

**Dueño:** G/R. **Archivos:** `scripts/mac/workers.v1.json`,
`corrida_worker/{registry,selector}.py`, `scripts/mac/corrida/lib.sh`, adaptadores
nativos/CLI, configuración efectiva de perfiles y manifiestos administrados.

1. Materializar contexto de poteto canónico, perfil, skills y evidencia por tarea.
   Preservar memoria y archivos del usuario. Versionar contenido y adaptación.
2. Certificar seis rutas: turno, hijo y encargo nativo; inicio, resume e hijo CLI.
   Medir permisos efectivos y herramientas que necesita el procedimiento completo.
3. Crear perfiles de capacidad y competencia para todas las especialidades
   descubiertas, incluidas operaciones, ingeniería, revisión, adversario, Amazon,
   Meli y mail. No deducir capacidad del nombre ni compartir contexto indiscriminado.
4. Certificar OpenCode con el adaptador existente y los siete perfiles disponibles.
   Resolver permisos de shell/hijos y modelo efectivo; background no es requisito.
5. Reproducir y corregir discrepancias de argv/modelo, incluido `--model\nwrong`
   dentro de un argumento. Reanudar conserva el snapshot. Una ruta opaca no miente
   sobre el modelo y queda inelegible donde se necesita versión exacta.
6. Registrar y marcar sesiones antes de entregar instrucciones; serializar teclas
   por sesión propia. Conservar `.corrida/` fuera de Git y separar fuente del
   directorio autorizado donde el reviewer entrega su resultado.

**Verificar:** I08/I09/I11/I18. Quitar poteto, permitir escritura al reviewer o
deshabilitar una herramienta necesaria del hijo debe impedir esa admisión. Perfil
Meli pasa su tarea y rechaza una ajena; skill irrelevante no entra; memoria sobrevive.
Entregar un digest sin conducta observable no completa este bloque.

## SUA-04 — Modelos y agentes que se actualizan

**Dueño:** política de flota local; G distribuye manifiestos. **Archivos:** ampliar
registro/selector y el scheduler anfitrión; nuevo manifiesto versionado de catálogo,
perfiles y generaciones. No crear daemon ni store de tareas nuevo.

1. Consultar fuentes oficiales y acceso por cuenta. Mantener sucesión, estabilidad,
   capacidades y causa de inelegibilidad, independientes de nombres comerciales.
2. Probar un sucesor y promoverlo automáticamente dentro de plantilla/autorización.
   Mantener el intento activo; un relevo hereda raíz, gasto y restricciones.
3. Descubrir altas y retiros; validar perfil y conexiones ida/vuelta; publicar nuevos
   destinos mediante manifiesto autorizado, no una allowlist abierta de carpetas.
4. Refrescar fuentes/skills de especialidad por caducidad; acotar mantenimiento,
   backoff, coste y cambios. Aplicar generación con CAS, atestación y read-back.

**Verificar:** I10/I11/I19. Sucesor estable funciona sin editar IDs a mano; preview,
proveedor sin acceso y canary fallido no se promueven. Alta posterior recibe y
devuelve tarea; alta incompleta queda visible. Crash entre aplicar/verificar no
activa bytes no acreditados. Revocación permanece tras reversa.

## SUA-05 — Ingeniería y calidad

**Dueño:** G/R y cada repo consumidor. **Archivos:** `corrida_worker/gates.py`,
`scripts/ci-fast-allowlist.txt`, `scripts/run-checks.sh`, `.github/workflows/`,
verificadores de cobertura/corpus, hooks, recetas de repos y reglas administradas.
Nuevos: política de calidad versionada y catálogo de efectos por repo.

1. Implementar revisión independiente, resultados tipados, cobertura completa del
   diff y escritura restringida al resultado. No recortar silenciosamente el diff.
2. Implementar inactiva la política futura: contador por linaje estable del bloque,
   hallazgos acumulados, diagnóstico/relevo acotados y escalación persistente.
   Comprobar que la autoridad cubre expresamente sustituir stop2 por v2 en cada
   repo/host. Si ya lo cubre, registrar recibo y activar sin otra pregunta; si no,
   conservar la política vigente y dejar pendiente esa activación. Actualizar
   instaladores/consumidores al adoptar; no editar a mano marcadores de quality-kit.
3. Unificar merge en CI/reviewer del head exacto, check-run del bot, SHA esperado
   y lectura remota del resultado. Migrar y retirar la tabla de merge redundante.
4. Implementar push/PR draft, reintento CI, corrección, rebase y ready por política
   del repo. Separar autoridad de merge/deploy de respuestas a diálogos CLI.
5. Corregir el carril rápido del corpus y la duplicación de `test-ci-coverage-contract`;
   probar inventario y unión de shards. Mantener hooks, regresión y batería íntegra.
6. Migrar consumidores de `cross-review.ps1` a tareas/review comunes; reutilizar lo
   útil de sus validaciones. Retirar su obligatoriedad y copias de reglas obsoletas
   sólo en el perímetro migrado. El kit puede seguir como bootstrap opcional externo.

**Verificar:** I12/I13/I21. Código cero con texto `BLOCKER` no aprueba; evidencia de
otro head falla; comentario de bot sin check-run falla. Un bloqueante nuevo en
cada ronda no reinicia límites. Activación sin autoridad/recibo falla; con recibo
habilita v2 sólo para raíces nuevas del perímetro adoptado. Cambiar corpus dispara
su checker; shard vacío o
prueba omitida hace fallar cobertura. Reviewer sin acceso de escritura a fuente.

## SUA-06 — Seguimiento y panel

**Dueño:** proyección/emisor locales; G empaqueta. **Archivos:** proyección nativa,
`scripts/agent-work/progress_bridge.py`, contratos de seguimiento y manifiesto LobsterBoard.

1. Antes de UI propia, probar LobsterBoard original con plantilla, commit, licencia,
   assets y dependencias fijados. Guardar capturas móvil/escritorio y faltantes.
2. Proyectar meta/unidad/intento desde recibos nativos; distinguir declarado,
   observado, aceptado y desconocido. Vincular evidencia y próxima comprobación.
3. Unificar avisos y panel sobre el mismo snapshot; conservar un emisor por host,
   entrega durable, reintentos y checkpoint posterior al envío confirmado.
4. Aplicar allowlist de campos/URLs, escape, límites y autenticación. Panel inicial
   de lectura; acciones se mantienen en las entradas autenticadas existentes.
5. Hacer sólo ajustes ligados a faltantes. Si requiere reescritura amplia, detener
   la entrega UI con evidencia y alternativas; no sustituirla automáticamente.

**Verificar:** I14/I15/I16/I17. Dos tareas comparten reloj y consolidado; cerrar una
no apaga la otra. Una sin PR puede cerrar por evidencia. Probar teclado/móvil,
error/offline/vacío, frescura, corrupción, PID reutilizado, métricas ausentes y
secretos/XSS sintéticos. Sin OpenGrokBot instalado. Probar fallos de envío sin ACK.

## SUA-07 — Hermes independiente

**Dueño:** integración local H. **Archivos:** se fijan con el inventario real en el
primer paso; contrato objetivo y fixtures son los de SUA-00, no APIs inventadas.

1. Identificar instalación, plataforma, entradas, store, scheduler, identidad,
   autoridad, procesos y transporte. Registrar cada interfaz soportada y su versión.
   Registrar qué contratos/fixtures compartidos están listos aunque una integración
   R siga pendiente; las dependencias del paquete no exigen disponibilidad de R.
2. Implementar controlador y frontera transaccional locales. Si no hay operación
   durable adecuada, añadirla al host local antes de habilitar tareas compuestas.
3. Implementar los mismos contratos de poteto, flota, calidad, proyección y control.
   Compartir fixtures/esquemas; no credenciales, sesiones, cola ni RPC OpenClaw.
4. Acreditar versión/capacidades y fallos recuperables. Publicar instalador/reversa
   propios para SUA-09H. El modo legacy `--vigia hermes` no acredita este bloque.

**Verificar:** I01–I14/I16/I18/I20 contra H. Ejecutable y gateway OpenClaw ausentes
en el entorno de prueba; romper su acceso no altera Hermes. Una capacidad faltante
impide aceptar esa ruta y no bloquea desarrollo ni aceptación de OpenClaw.

## SUA-08 — Orbit

**Dueño:** O, con receta invocada por efecto admitido. **Archivos:** `docs/DEPLOY.md`,
nuevo `scripts/deploy-goncloud.sh` y prueba con dobles de SSH/Docker; receta en G.

1. Confirmar branch, método de merge, hooks EHV, destino y autoridad del repo.
2. Automatizar archivo desde revisión remota, copia verificada, respaldo y rebuild
   de la aplicación con `--no-deps`; conservar receta vigente y salud en 8010.
3. Registrar intención y recibo por SHA/destino. Consultar resultado tras fallo de
   transporte; no repetir un deploy incierto por silencio. Implementar reversa.
4. Permitir la ruta sin operador rutinario sólo dentro de una política que cubra
   selección del artefacto, publicación, destino y verificación.

**Verificar:** I23 primero con dobles: SHA equivocado, copia incompleta, fallo de
salud y ACK perdido. Ensayo real autorizado en SUA-10O; un script escrito o mock
verde no acredita el deploy vivo ni permite cerrar Orbit.

## SUA-09O y SUA-09H — Publicación y cambio de dueño

**Dueño:** instalador del host respectivo. **Archivos:** U1/sync seguro Windows,
`scripts/mac/instalar-mac.sh`, mecanismos T11–T12 y paquete H. Nuevo manifiesto de
paquete con commits, migración de store, rutas administradas y capacidades.

1. Preparar paquete reproducible; registrar versiones compatibles y reversa.
   Añadir destinos administrados de agentes/plugins con validación y read-back.
   Incluir el recibo de adopción de calidad para el perímetro que vaya a usar v2;
   sin él no cambiar reglas al instalar ni declarar completada esa adopción.
2. Instalar dos veces en entorno aislado; verificar convergencia, upgrade y reversa
   conservando tareas, permisos revocados, identidad y memoria.
3. Inventariar todas las entradas del vigía, cron y launchers. Poner la ruta nueva
   en sombra; detener admisión antigua; drenar y conciliar; cambiar dueño por CAS.
4. Verificar antes de activar. Un apply sin attest no admite trabajo. Conservar las
   entradas no migradas; retirar un cron compartido sólo cuando migren todas.
5. Añadir alias futuro `SUA` al launcher y validador del plan; probar localización,
   dry-run y rechazo/redirección informativa de U3b/U4/U5/U6/F antiguos. El alias
   numérico 6 nunca significa U6. Actualizar runbook y prompt de Claw para leer
   este plan; un alias histórico no puede lanzar un segundo programa.

**Verificar:** I19/I22/I24 por host. Crash en cada borde del corte, dos generaciones
concurrentes, resultados pendientes y proceso adoptado. Exactamente un dueño
admite por entrada. Reversa incompatible mantiene pausa y reparación; no revive
el dueño viejo mientras el nuevo conserva trabajo. Cron de negocio sigue activo.

## SUA-10O y SUA-10H — Aceptación por computadora

**Dueño:** verifier independiente y responsable de publicación del host.

1. Reusar fixtures/CI válidos; ejecutar I01–I24 aplicables contra el paquete final.
   I23 requiere Orbit en SUA-10O; en Hermes se prueba contrato de efecto y se
   referencia el recibo Orbit, sin duplicar su despliegue por demostrar paridad.
2. Ejecutar un pedido nativo de dominio y un plan de ingeniería con CLI. Cubrir las
   tres entradas heredadas de U3b; no exige repetir tres veces todos los ensayos.
3. Probar otro runtime inaccesible, pérdida de ACK, reinicio, pausa/cancelación,
   permiso revocado, sucesor de modelo, alta nueva y fallo de fuente de dominio.
4. Registrar capturas de panel, mensajes redactados, resultados, modelo/contexto
   efectivos, costes/latencias medidos y lectura de versiones instaladas.
5. Ejecutar checklist posterior al deploy una vez. Guardar aceptación del usuario
   cuando corresponda; no fabricar un `FUNCIONA` ni pedir repetirlo sin invalidación.

**Verificar:** recibo separado por host y por Orbit, cero bloqueantes abiertos,
criterios completos y límites explícitos. Fuentes desconocidas o ruta sin poteto
no cuentan como aprobadas. OpenClaw puede aceptarse antes que Hermes. No declarar
paridad o cierre total usando sólo el recibo de una computadora.

## SUA-11 — Cierre y retiro residual

**Dueño:** G, con recibos de R/H/O.

1. Conciliar cobertura de las 39 filas antiguas y criterios adicionales. Registrar
   cambios deliberados de política; una obligación omitida deja el programa abierto.
2. Confirmar cero consumidores de autoridades, wrappers y copias retiradas. Eliminar
   sólo los residuales ya migrados; conservar evidencia histórica y cron de negocio.
3. Publicar un único cierre del programa con enlaces a recibos. No repetir baterías
   válidas para producir otra marca verde. Registrar mejoras observadas frente al
   baseline y lo que no mejoró; no prometer ahorro sin medición.

**Verificar:** cobertura sin huecos, aceptación OpenClaw/Hermes/Orbit, política única
instalada y leída de vuelta, ningún launcher antiguo activo para el mismo encargo.

## Ensayos integrados

| ID | Resultado que debe distinguir |
|---|---|
| I01 | Pedido natural, plan y fila importada conservan alcance, supuestos y criterios. |
| I02 | Ciclo, ID duplicado, dependencia o criterio faltante se rechazan antes de lanzar. |
| I03 | A+B→C con dos reconciliadores y ACK perdido crea exactamente una C bajo la raíz. |
| I04 | Caídas entre commit/admisión/consumo recuperan tareas y gasto; termina el turno y sigue el plan. |
| I05 | Pausa/cancelación contra permiso Started; envío posterior al ACK queda enumerado si ya estaba comprometido. Replay de control estable, Resume obsoleto rechazado, eventos tardíos sin resurrección. |
| I06 | Efecto confirmado no se repite; efecto incierto conserva estado y exige conciliación. |
| I07 | Autoridad negativa, revocación, otra sesión, diseño, mail borrador y SHA futuro restringen efectos. |
| I08 | Poteto completo llega y funciona en las seis rutas; ausencia impide admitir la ruta. |
| I09 | CLI/modelo/argv, resume y permisos efectivos; OpenCode y sus hijos, reviewer sin escritura. |
| I10 | Sucesor estable se promueve automáticamente; preview/incompatible falla; intento activo conserva snapshot. |
| I11 | Alta nueva conecta ida/vuelta; perfil incompleto visible; competencia, caducidad y memoria preservada. |
| I12 | Corrección converge o detiene; nuevos hallazgos/relevo no reinician linaje. Adopción v2 exige autoridad/recibo; raíces previas conservan política. |
| I13 | Review/CI del head, criterio y entorno vigentes; LISTO, merge, rollback y criterio borrado no fabrican éxito. |
| I14 | Panel y aviso comparten estado/porcentaje; dos tareas, CI en espera y tareas sin PR se representan bien. |
| I15 | LobsterBoard original y ajustes probados en móvil/escritorio, teclado, vacío/error/offline y frescura. |
| I16 | PID reutilizado, sesión caída, datos corruptos y métricas ausentes no atribuyen ni matan recursos ajenos. |
| I17 | Secretos sintéticos, XSS y rutas/URLs maliciosas no se filtran por vista/evento/exportación. |
| I18 | Advisor con/sin eventos declara cobertura; caída no aprueba ni despacha. |
| I19 | Generaciones, apply sin attest, nuevo destino y reversa conservan autorización y tareas. |
| I20 | Presupuesto raíz, cupo global y escritor exclusivo; par atómico con dos/tres plazas ocupadas. |
| I21 | Batería íntegra, unión de shards, corpus real, logs y hooks; sin prueba omitida o duplicación inútil. |
| I22 | Corte por entrada deja un dueño; pending results/crash/reversa y cron mixto no pierden trabajo. |
| I23 | Orbit por SHA remoto, respaldo, copia, salud y reversa; autorización e incertidumbre comprobadas. |
| I24 | Cada host instala/reinstala/revierte y opera con el otro inaccesible; alias/runbook no duplican programas. |

## Comandos existentes y comandos futuros

Se confirmaron en fuente los siguientes puntos de entrada. Esta lista no afirma
que se hayan ejecutado como parte del diseño ni que acrediten contratos nuevos.

| Repositorio | Comando existente | Uso futuro |
|---|---|---|
| G | `bash scripts/tests/test-worker-registry.sh` | Compatibilidad de registro. |
| G | `bash scripts/tests/test-worker-selector.sh` | Elegibilidad y selección actuales. |
| G | `bash scripts/tests/test-worker-model-binding.sh` | Binding de modelo; ampliar con el defecto de newline. |
| G | `AGENT_WORK_RUNTIME_SOURCE=/ruta/R bash scripts/agent-work/test-runtime.sh handling_atomic` | Consumo/decisión nativos existentes; no prueba fan-in nuevo. |
| G | Mismo runner con `budget_tree`, `budget_evasion`, `admission_restart`, `result_receipt` | Guardas existentes de presupuesto, reinicio y resultado. |
| G | `bash scripts/run-checks.sh` | Batería completa; CI usa shards cuya unión se comprueba. |
| G | `pre-commit run --files <archivos-del-cambio>` | Hooks sin omitir. |
| R | `pnpm format:check`, `pnpm lint`, `pnpm tsgo:core` | Baseline de calidad del runtime inspeccionado. |
| R | `node scripts/run-vitest.mjs <archivo> --testNamePattern <caso>` | Casos concretos registrados al implementar. |

SUA-00 registra comandos reales para H; SUA-09 crea y verifica el launcher SUA.
`director_handling` no está en la lista actual del runner `test-runtime.sh`; no se
usa como prueba ficticia. `--help` de un perfil aislado prueba ayuda, no activación.
La aceptación guarda salida real del comando y artefacto al que corresponde.

## Evidencia y detenciones

Cada recibo incluye bloque/ensayo, host, commits o digest del paquete, versiones,
criterios, comando/procedimiento, entorno, resultado, fecha, verificador, costes
medidos y límites. Los registros se redactan antes de publicar. Las rutas locales
privadas y credenciales no se copian al panel.

Una falta de permiso detiene el efecto afectado. Una capacidad desconocida detiene
su integración. Un bloqueante detiene su bloque. Otra unidad independiente puede
seguir dentro de la autoridad y presupuesto; no se inventa un aprobado para
desbloquearla. La petición de operador incluye diagnóstico, artefacto revisable y
opciones concretas, sin convertir una preferencia de skill en permiso nuevo.

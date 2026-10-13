# Explorador A: sistema objetivo de SUA según sus documentos

Abreviaturas (todos sin trackear en /Users/dn/dev/wt/flota-poteto, rama feat/flota-poteto, HEAD e5cae2d):
D = docs/superpowers/specs/2026-10-05-sistema-agentes-unificado-design.md
P = docs/superpowers/plans/2026-10-05-sistema-agentes-unificado.md
C = docs/evidence/sistema-agentes-unificado/cobertura.md
Rv = docs/evidence/sistema-agentes-unificado/revision.md
FC = docs/superpowers/specs/2026-10-04-flota-poteto-contract.md
FD = docs/superpowers/specs/2026-10-04-flota-poteto-design.md

## Actores
| Actor | Dónde vive | Escribe/lee | Fuente |
|---|---|---|---|
| David | Entrada autenticada de OpenClaw o Hermes | Pide y controla; capacidad acotada emitida por el host ligada al dueño | D:10, D:148-152 |
| Controlador | Módulo local del runtime, invocado por su scheduler existente; uno por instalación | Decide (plan, dependencias, reparación, aceptación, siguiente acción); sin ledger propio, escribe solo vía host.commit | D:56, D:72, D:82-84 |
| Políticas internas (meta, ingeniería, flota) | Funciones puras dentro del controlador; recetas versionadas en G | Sin store, cola ni reloj | D:73-74, D:81-82 |
| Dueño nativo | R (/Users/dn/dev/openclaw-agent-work-integration) en OpenClaw; store/adaptador nativo en Hermes | Único que persiste: transacciones, permisos, reservas, tareas, procesos, recibos | D:57, D:75, D:86 |
| Adaptadores de efectos | Adaptadores CLI/host existentes ampliados; Orbit con receta | Ejecutan intención admitida, devuelven recibo; piden Prepared→Started | D:76, D:154-157 |
| Especialistas nativos y ejecutores CLI | Workers admitidos | Solo entregan resultados/propuestas; pueden proponer hijos, autorizarlos requiere capacidad delegada | D:111, D:151-152 |
| Reviewer, verifier, adversario, advisor | Workers admitidos, no dueños del control ni del cierre | Reviewer lee fuente inmutable y escribe solo su resultado; verifier acredita criterios; advisor observa sin despachar | D:78, D:206-208, D:304-307 |
| Proyección y emisor | Proyección reconstruible, emisor único por host | Solo lectura; "El panel no ordena trabajo" | D:77, D:39, D:329-333 |
| LobsterBoard | UI que lee la proyección; inicial solo lectura | Solo lectura | D:33-35, P:254-255, D:344-349 |
| G (goncloud-openclaw) | Recetas, perfiles, adaptadores, ensayos, manifiestos | No gobierna Hermes ni escribe tablas de R | D:80, D:86-87, P:126 |
| O (goncloud-Orbit) | Receta de deploy en docs/DEPLOY.md; script automatizado pendiente | Efecto admitido | P:33, P:286-299 |
| H (Hermes) | Por identificar al inventariar | Su propio controlador, store y scheduler | D:81, P:34, P:264-282 |
| OpenCode | Por el adaptador CLI existente tras certificar config/modelo/permisos | Ejecutor más, no director | D:309-320 |
| Scheduler existente | Del host | Despierta al controlador, mantiene catálogo | D:276, D:335 |
| claw/main | NO aparece como actor en D. Solo P:319-320 "Actualizar runbook y prompt de Claw para leer este plan" | — | — |

## Modelo de datos (D:113-129)
- Goal: raíz, solicitante, autoridad, presupuesto, revisión activa, época de control, política de calidad fijada. Sin estados de ciclo de vida propios; "meta cumplida" es hecho distinto.
- Plan: digest inmutable, unidades, dependencias, criterios, supuestos, cobertura. Una revisión invalida claims/admisiones afectadas; quitar criterio exige modificación de alcance autenticada (D:182-185).
- Control: Active(epoch) | Paused(epoch, reason) | Cancelled(epoch, reason). Cancelar es terminal; reanudar conserva todo (D:169-170).
- UnitBinding: clave única (root, planRevision, unitId, attempt) → tarea nativa.
- Assignment: especialista, host, ejecutor, cuenta, modelo exacto o desconocido, effort, generación, permisos, contexto, atestaciones.
- EvidenceClaim: criterio+versión, artefacto, dependencias, entorno, verificador autorizado, procedimiento, resultado, fecha, caducidad.
- Effect: Prepared | Started | Confirmed | Uncertain, con clave estable, alcance, época. Started = compromiso de inicio y permiso único de envío, no ACK del destino. Uncertain conserva reserva y exige conciliación.
- ProcessIdentity: instalación, boot ID, PID, creación, propietario, propio/adoptado. PID reutilizado no permite atribuir ni matar.
- Exception: ID, tipo, opciones válidas, evidencia, destinatario, recibo. Las 11 clases antiguas migran a enum (P:153-155; C:127-145).
- CorrectionBudget: clave (root, blockLineageId); consumido/límite, hallazgos abiertos, diagnóstico y relevo usados, versión de política.
- Avance: declarado/observado/aceptado/desconocido. Publicación: preparado→aplicado→verificado→activo. Autoridad: design/lectura/implementación/publicación. Capacidad: passed/failed/unknown.

## Interfaz (D:97-107; "no son comandos disponibles")
open(request, authority, idempotencyKey) -> GoalRef | Conflict
control(goal, Pause|Resume|Cancel, expectedControlEpoch, commandId) -> Receipt | Conflict
reconcile(goal) -> DecisionReceipt
read(goal) -> GoalView
decide(snapshot, verifiedFacts, policies) -> Decision  // pura
host.commit(goal, expectedPlanRevision, expectedControlEpoch, consumedResults, evidenceClaims, bindings, effects, decisionDigest) -> DurableReceipt | Conflict  // atómica
"Los llamadores no encadenan por su cuenta reserva, spawn, registro y aceptación" (D:109).

## Flujo de una meta
1. Pedido: David encarga a OpenClaw o Hermes; open() crea Goal con autoridad ∩ permisos de host/agente/CLI y política de calidad fijada. No se especifica qué agente recibe el pedido.
2. Plan: pedido pequeño, fila importada de Plans.md o compuesto (P:148, P:159-160). I02 rechaza ciclos/dups antes de lanzar. "Tamaño del plan no crea aprobación adicional" (D:201). Quién redacta el plan desde lenguaje natural NO se especifica ("el planificador" D:218 sin módulo).
3. reconcile → decide puro → host.commit atómico (valida solicitante/permiso/revisión/época/presupuesto; consume recibos y claims; dependencias; binding único; crea hijos, reserva, registra intenciones; guarda recibo de decisión) (D:137-141). Replay mismo digest = mismo recibo.
4. Asignación: filtro instrucciones → especialidad → herramientas/permisos → poteto → acceso → capacidad probada → presupuesto; entre elegibles calidad/latencia/costo con motivo (D:264-267). Tres límites: presupuesto del árbol, cupo del host, carriles. Recursos de escritura exclusivos entre raíces. Consumo desconocido no es cero.
5. Trabajo: especialista nativo o CLI. "El turno termina y la meta continúa" (P:160). Efecto externo pasa por Prepared→Started.
6. Despertar: scheduler invoca controlador por eventos y reconciliación recuperable (D:335). Latido 5 min sin modelo; recursos cada 15; aviso consolidado máx. cada 30; excepciones inmediatas, reaviso ≥60 (D:336-339). Respuesta inmediata de U3a se conserva. Sin daemon ni tarea permanente con modelo. Mecanismo concreto resultado→reconcile NO precisado.
7. Evidencia y revisión: ejemplo A backend y B frontend en worktrees distintos; C empieza una vez cuando ambos tienen aceptación vigente (D:41-45). Reviewer independiente + verifier; approve no sustituye pruebas.
8. Corrección: política vigente; v2 solo tras adopción.
9. Merge: CI y reviewer del head exacto, check-run real del bot, autoridad del repo, relectura del merge remoto (D:203-204). Orbit: intención y recibo por SHA, no repetir deploy incierto, reversa.
10. Seguimiento: panel y avisos leen el mismo snapshot. % de criterios con pesos fijos; 100% exige aceptación integrada actual; ni LISTO ni merge lo producen (D:324-327).
11. Cierre: entrega el resultado acreditado; tareas sin código cierran por evidencia, sin PR fabricado.
Fallos: Excepción tipada al propietario, una respuesta, reaviso máx. cada hora. Traducción: SIN_CUOTA → espera o cuenta elegible sin comprar; CI_ROJO omitir no permite merge; BOT_CALLADO silencio no es aprobación. Pausa sube época antes del ACK, serializada con Prepared→Started; si Started ganó, el envío puede ocurrir tras el ACK y el recibo lo enumera. Cancelación terminal. Reinicio: Started recuperado se concilia antes de reenviar; ACK perdido → consultar; si no idempotente → Uncertain. Cuota: indisponibilidad temporal. Relevo: nuevo intento en misma raíz y presupuesto. Detenciones locales: lo independiente sigue (P:421-425).

## Seis rutas poteto, selección, promoción, alta
Rutas: turno nativo, hijo nativo, encargo gestionado, inicio CLI, resume CLI, hijo CLI (D:299-302). Falta una ruta → esa no se admite, las demás siguen. Contexto = alcance+autoridad + poteto canónico + especialidad + skills + evidencia.
Promoción: scheduler revisa catálogo al arrancar, ante cambio de inventario y cada 24 h; sucesión estable verificada + canary; no compra accesos; no cambia intento activo (D:276-283).
Alta automática: agentes descubiertos desde inventarios, sin lista fija de 19; alta dentro de plantilla autorizada se valida, publica, prueba y habilita sola (D:285-289).

## quality-policy.v2 (D:210-260)
Cambia: máx. 4 ciclos por bloque desde la primera revisión con bloqueantes; nada reinicia el contador; linaje estable. Dos repeticiones sin progreso → diagnóstico independiente + un relevo (no suman ciclos); si no hay corrección, reaparece o se agota límite → bloque detenido con evidencia. "No se rota el modelo por ritual" (hoy: revisor distinto cada ronda). Bloqueante con reproducción o evidencia estática verificable (hoy: sin reproducción no bloquea).
Conserva: bloqueante nunca a backlog; agrupar hallazgos y revisar delta; no bloqueantes no abren ronda; hooks sin --no-verify; regresión por bug; pruebas focalizadas; batería completa una vez en CI; shards cubren la unión; checks de docs/ledger en su job. Quality-kit deja de ser coordinador obligatorio después de migrar consumidores.
Activación: implementar no la activa; requiere autoridad que cubra expresamente sustituir stop2; si la autorización del programa ya lo cubre, no se vuelve a preguntar; recibo con principal, alcance, digest anterior/nuevo, fecha, read-back. Sin recibo rigen las reglas actuales. Raíces existentes conservan su versión. SUA-05 la implementa inactiva; SUA-09 exige recibo al instalar; I12 lo prueba. "Cuatro" no es medido.

## Bloques (P:48-63)
| Bloque | Entrega | Depende | Ensayos |
|---|---|---|---|
| SUA-00 | Inventario y contrato (G): docs/spec/sistema-agentes.v1.md y fixtures nuevos; mide despertar por evento, costo/latencia; fija I01–I24 | — | I01/I02 |
| SUA-01 | Frontera durable en R: revisión de plan, época, claims, binding único, capacidad del solicitante, fan-in, control, reservas, efectos. Nuevo src/agents/goals/ | 00 | I03-I06/I20 |
| SUA-02 | open/control/reconcile/read; migrar 11 excepciones; sombra; reemplazar decisor legacy corrida_worker | 01 | I01–I07/I12 |
| SUA-03 | Poteto, seis rutas, perfiles, OpenCode, bug --model\nwrong (PR #247) | 02 | I08/I09/I11/I18 |
| SUA-04 | Catálogo, promoción, alta y retiro; sin daemon | 03 | I10/I11/I19 |
| SUA-05 | Revisión independiente, v2 inactiva, merge unificado (retira preaprobaciones.v1.json/autoridad-merge.sh), PR/CI/rebase, corpus y shards, migración de cross-review.ps1 | 02, 03 | I12/I13/I21 |
| SUA-06 | LobsterBoard original primero, proyección, avisos, allowlist/XSS | 02 | I14-I17 |
| SUA-07 | Hermes independiente; puede empezar con el contrato sin esperar R | 00 | I01–I14/I16/I18/I20 contra H |
| SUA-08 | Deploy de Orbit (scripts/deploy-goncloud.sh nuevo), solo dobles | 05 | I23 |
| SUA-09O/09H | Paquete, instalación doble, corte por entrada vía CAS, alias SUA en launcher | 09O: 04,05,06; 09H: +07 | I19/I22/I24 |
| SUA-10O/10H | Aceptación por host; I23 vivo solo en 10O | 10O: 08, 09O; 10H: 09H | I01–I24 aplicables |
| SUA-11 | Conciliar 39 filas, cero consumidores retirados, cierre único | 10O, 10H | cobertura |
Bases: G e5cae2d (no producción; main 77fafb0), R 6e3d428, O 25cebe7, H pendiente. Cadena crítica: 8 bloques. OpenClaw puede aceptarse antes que Hermes; cierre total exige ambos y Orbit. Sin estimación de tiempo/tokens: "No hay medición que permita prometer ahorro de tokens o tiempo" (D:66). 14 bloques, 39 filas, 38 criterios, 24 ensayos.

## Qué no hace / autorizado
Autorizado hoy: solo diseño y revisión de documentos (P:22-25; D:3). Exclusiones: sin cola/reloj/servicio central entre hosts; sin framework universal; sin decisor Python compitiendo; sin daemon de catálogo; sin compra de accesos; sin UI propia de fallback; sin proxy Hermes→OpenClaw; sin dos dueños como reversa; no adopta de OpenCode main director, SMALL sin revisión, PASS textual; sin failover entre hosts; no sustituye summa-gate ni crons de negocio; no convierte filas viejas en terminadas. Fuera del reemplazo: U0–U3a, U1/sync, Fase14 y evidencia de encargos (C:147-150).

## No obvio
1. El controlador vive dentro de R, no en scripts de G; SUA-02 reemplaza corrida_worker. FC §15 (FC:519) todavía dice que U3b conserva corrida_worker.reconcile() como único decisor.
2. FC cita reglas viejas (stop2 en FC:219-222; catálogo cada hora + 24h).
3. Estados de alta inconsistentes (NeedsRuntimeVerification vs NeedsProbe).
4. CorrectionBudget por (root, blockLineageId) sin planRevision; UnitBinding sí la incluye.
5. v2 cambia además: no rotar revisor por ritual; bloqueante con evidencia estática sin comando. C:87 solo menciona stop2→4 ciclos.
6. Started no es silencio: tras ACK de pausa pueden salir efectos comprometidos.
7. claw y Telegram no aparecen en D; destinatarios legacy de excepciones (claw o David) no mapeados.
8. Documentos SUA sin commit en la rama de un PR abierto (#247) cuyo código el diseño no acepta.
9. SUA-09H depende de bloques con código de OpenClaw.
10. SUA-07 no lista I15/I17 (LobsterBoard, XSS) aunque U5 prometía el mismo panel.
11. LobsterBoard BSL 1.1.
12. I01–I24 no existen como scripts.
13. Autoría Codex: gpt-6-sol (revisión completa) y gpt-5.6-terra (delta APPROVE); prototipo abstracto.
14. "Tabla adicional de merge" = preaprobaciones.v1.json + autoridad-merge.sh.

## Preguntas abiertas
Quién redacta el Plan desde lenguaje natural; papel de claw y canal de avisos (Telegram no mencionado); Goal sin estados terminales formales; Effect sin "descartado"/fallo definitivo; qué es un bloque en metas no de ingeniería; mecanismo resultado→reconcile en R y Hermes (SUA-00 lo mide); toda la frontera de Hermes desconocida.

# Arquitectura de resúmenes de envíos

Estado: propuesta para implementación aislada y revisión. No activa trabajos, modifica rutinas en vivo ni autoriza envíos. El inventario primario está en `docs/spec/resumen-envios-inventario-pausado.md`.

## 1. Decisión

Se recomienda un **libro mayor transaccional de obligaciones**, implementado con SQLite y biblioteca estándar de Python. La unidad durable no es un HTML ni una corrida: es comunicar un pedido o una vista previa a un destinatario concreto y conservar la evidencia que lo confirma, lo deja pendiente o lo vuelve incierto.

Se compararon dos formas:

- **A. Libro mayor transaccional.** Una base contiene evidencia, cortes, obligaciones, partes, intentos y recibos. Los tres cortes comparten selección, planificación y entrega.
- **B. Documentos y outboxes por destinatario.** Cada corte publica JSON inmutables y cada destinatario reconstruye su cobertura leyendo documentos y recibos de su outbox.

Se elige A. En B, «¿qué falta recibir de Isabel?» exige componer varios archivos y estados sin una transacción común. Los documentos crudos inmutables se conservan como evidencia en A, no como una segunda autoridad operativa.

Tres diseños independientes convergieron en A. La base sintetizada usa la identidad por línea y la marca de agua histórica del candidato 3, el bloqueo local por parte y la separación entre reintentos y extras del candidato 2, y las fronteras transaccionales explícitas del candidato 1. No hubo juez de otro proveedor porque la herramienta no permite seleccionar modelo; no se afirma diversidad de modelos.

## 2. Límites y módulos

```text
Amazon / ML ──> adaptadores de solo lectura ──> evidencia durable
Odoo ─────────> equivalencias SKU opcionales         │
                                                   v
                                      política pura de elegibilidad
                                                   │
                              cobertura histórica + planificador
                                                   │
                                  plan sellado y partes por destinatario
                                                   │
                       despachador ──> Gmail / Telegram / transportes falsos
                           │                         │
                           └──── recibos y conciliación
```

| Módulo bajo `scripts/resumen_envios/` | Única responsabilidad |
| --- | --- |
| `domain.py` | Claves, observaciones, decisiones, planes y estados; sin E/S. |
| `policy.py` | Plazos, elegibilidad, completitud y reglas de audiencia; sin recibos ni E/S. |
| `planner.py` | Cobertura, obligaciones y bloques/partes; sin canales ni cron. |
| `render.py` | Texto y HTML desde un plan; nunca deriva identidades desde el render. |
| `store.py` | SQLite, transacciones, restricciones y proyecciones de cobertura. |
| `delivery.py` | Intentos, bloqueo local, recibos, fallos e incertidumbre. |
| `history.py` | Evidencia histórica con confianza, sin modificar originales. |
| `service.py` | `advance_cut`, `resume_cut`, `reconcile_attempt` y `close_cut`. |
| `cli.py` | Composición de módulos y salida observable; sin reglas adicionales. |

El prototipo entregado implementa el dominio, la política, el libro, los planes y los transportes falsos. No contiene clientes de Amazon, ML, Odoo, Gmail o Telegram. Las fuentes entran como `SourceReport` desde fixtures anonimizados y la CLI exige `RESUMEN_ENVIOS_DRYRUN=1`, una base temporal y un directorio de bloqueos. Los adaptadores reales son una fase posterior, no una capacidad que esta propuesta declare verificada.

Los adaptadores de Amazon y ML no consultan entregas ni eligen destinatarios. Odoo solo implementa `SkuLookup.equivalent(platform, sku)`. Gmail y Telegram no seleccionan pedidos. El llamador solo invoca `advance_cut(kind)` o `resume_cut(cut_id)`.

## 3. Identidades y datos centrales

```python
@dataclass(frozen=True)
class CutKey:
    kind: Literal["principal", "temprano", "ultimo"]
    local_date: date

@dataclass(frozen=True)
class OrderKey:
    platform: Platform
    account: str | None
    native_order_id: str

@dataclass(frozen=True)
class LineKey:
    order: OrderKey
    native_line_id: str

@dataclass(frozen=True)
class PhotoKey:
    line: LineKey
    kind: Literal["personalization_preview"]

@dataclass(frozen=True)
class NoticeKey:
    subject: OrderKey | PhotoKey
    channel: Channel
    recipient: RecipientId

@dataclass(frozen=True)
class Deadline:
    raw_value: str | None
    platform_timezone: str
    platform_local_date: date | None
    display: Literal["verified", "verify_required"]
    membership_evidence: EvidenceRef | None

@dataclass(frozen=True)
class DeliveryUnit:
    key: UnitKey
    content_hash: str
    members: tuple[NoticeKey, ...]
    state: UnitState
```

- El ID interno de plataforma identifica; el número visible se muestra. Una cuenta se normaliza cuando la plataforma la requiere.
- `native_line_id` es, por ejemplo, `orderItemId`, nunca el índice visual, SKU o texto.
- Una foto es la vista previa de una línea. Renovar una URL presignada o cambiar sus bytes no crea otra obligación; los bytes y su hash quedan como contenido auditado.
- `NoticeKey` no contiene fecha ni hash. Atraso, pago confirmado, permanencia o equivalencia mejorada no reabren una entrega confirmada.
- `UnitKey` sí contiene corte, revisión, canal, destinatario, tipo y ordinal. La tabla de miembros limita exactamente qué obligaciones cierra un recibo.

`OrderObservation` conserva cliente, modalidad, acción, plazo, pago, líneas, cantidades, personalización y referencias crudas. Cada decisión publica `eligible`, `excluded` o `undetermined`, con regla, razón y evidencia.

## 4. Fuentes y completitud

Hay seis fuentes lógicas. Easy Ship combina pedidos y guías para su completitud; ML mantiene dos acciones separadas.

| Fuente | Checks mínimos |
| --- | --- |
| Amazon MX Easy Ship | `unshipped`, `pending`, `shipped/easyship`, paginación y acción/estado de cada candidato. |
| Amazon MX envío propio | Cuenta/modalidad, `unshipped`, `pending`, paginación y detalles de elegibilidad. |
| Amazon EE. UU. envío propio | Cuenta/marketplace, `unshipped`, `pending`, paginación y detalles. |
| Seller Flex | `FLEX-ALL`, paginación y detalles de acción/plazo. |
| ML por empacar | Acción por empacar, conteo visible, páginas e IDs internos. |
| ML por confirmar | Acción confirmar envío, conteo visible, páginas e IDs internos. |

`CheckResult` registra vista, inicio/fin, páginas, conteo esperado/observado, referencia cruda y error. `SourceReport` contiene checks, observaciones, huecos y motivo. Su estado se deriva, no se declara por un prompt:

- `complete_with_orders`: todos los checks terminaron, la evidencia quedó guardada y hay pedidos elegibles.
- `complete_empty`: todos los checks terminaron y no hay elegibles; puede haber exclusiones auditadas.
- `incomplete`: falta una vista, página, persistencia, ID estable o dato que impide clasificar un candidato. Enumera qué sí se verificó, qué faltó y por qué.

Una página de error, un filtro equivocado, un conteo discrepante o una fila ignorada nunca producen vacío completo. Un Amazon repetido se reconcilia por `OrderKey`; un ML repetido por ID interno. Conflictos de estado, plazo o acción quedan indeterminados, no se resuelven eligiendo lo más conveniente.

La falta de vista previa o de equivalencia Odoo tiene tratamiento explícito y no degrada una fuente si elegibilidad y demás contenido están comprobados. Si plazo/acción es ilegible, el marcador solo se permite cuando otra evidencia de plataforma confirma la pertenencia al corte; de lo contrario el pedido queda pendiente y la fuente incompleta.

## 5. Cortes y reglas de audiencia

La fecha sale del plazo y su zona IANA. En cada pedido, el instante del corte se convierte a esa zona para obtener «hoy». El calendario operativo determina el siguiente día de despacho; no se usa la fecha de generación como sustituto.

- **Principal:** incluye atrasados y pedidos que vencen el siguiente día de despacho. Revisa desde 18:00, arma borradores desde 18:15 y congela a 18:30 con la evidencia durable disponible.
- **Temprano y último:** incluyen vencidos hoy o antes con al menos una entrega no reportada. Recuperan fuentes incompletas y entregas faltantes aunque no exista lista principal.

| Situación | Operación correo | David | Isabel | Jorge |
| --- | --- | --- | --- | --- |
| Principal con pedidos comprobados | Resumen combinado | Resumen | Resumen | Nunca resumen |
| Principal completo sin elegibles | Nada | Aviso corto | Aviso corto | Nada |
| Repaso con extras | Solo si contiene Amazon | Extras | Extras | Nunca resumen |
| Repaso completo sin extras ni faltantes | Nada | Nada | Nada | Nada |
| Vista previa | No aplica | Foto separada | Foto separada | Foto separada |
| Sin pedidos comprobados y fuente incompleta | Propuesta: nada | Revisión incompleta | Revisión incompleta | Nada |

Un principal con elegibles ya comunicados no se anuncia como «sin pedidos». Un reintento antiguo conserva su parte original y no se disfraza de extra. Un pedido nuevo nunca hereda el recibo de otro.

Las fotos son obligaciones independientes. Para David e Isabel esperan la confirmación de su resumen normal correspondiente; Jorge solo participa en la fase posterior de fotos. Si falta la imagen, el pedido sale con «Personalización incompleta: falta imagen» y la foto queda `AWAITING_ASSET`. Al aparecer, solo se entrega esa foto pendiente.

## 6. Cobertura y planificación

Cada cobertura tiene uno de estos valores:

1. `CONFIRMED`: recibo exacto por canal, destinatario y miembros.
2. `OPEN_KNOWN`: obligación existente aún no confirmada; se retoma solo si su estado lo permite.
3. `NOT_OPENED_VERIFIED`: no hay obligación ni evidencia ambigua y la marca de agua garantiza historia completa para ese destinatario desde antes de la primera aparición.
4. `UNKNOWN`: evidencia ambigua, historial incompleto o entrega incierta. Va a conciliación, nunca a reenvío automático.

La marca de agua se fija por canal y destinatario. Antes de disponer de planes, miembros y recibos continuos, la ausencia de registro no demuestra que un pedido sea nuevo. No se ejecuta «marcar todo como enviado».

El planificador calcula cobertura dentro de la misma transacción que crea una revisión. Los borradores no envían. Al congelar se guardan fuentes, miembros, bloques y partes. Una revisión con intento no se renumera ni cambia; una revisión sin intentos puede retirarse completa antes de sustituirla.

Telegram empaqueta bloques enteros en orden determinista y conserva el formato aprobado. Cada destinatario tiene partes propias, hasta 50. El excedente queda `BLOCKED_CAPACITY` visible. Un bloque que por sí solo excede el canal también queda pendiente. No se trunca, se usa `assert` ni se declara éxito.

## 7. Entrega, concurrencia y reinicio

### Estados

```text
Parte: PLANNED -> IN_FLIGHT -> CONFIRMED
                    ├───────> FAILED_RETRYABLE -> PLANNED
                    └───────> UNCERTAIN -> RECONCILING
                                      ├────────> CONFIRMED
                                      ├────────> FAILED_RETRYABLE (ausencia autoritativa)
                                      └────────> UNCERTAIN
Foto: AWAITING_ASSET -> PLANNED
Exceso: PLANNED -> BLOCKED_CAPACITY
```

`UNKNOWN` no equivale a ausencia. Telegram `ok:true + message_id` prueba aceptación de API, no lectura. Gmail exige borrador ausente y fila en Enviados con asunto y destinatario; cerrar el compose no basta.

### Fronteras transaccionales

1. **Fuente:** el crudo se escribe de forma inmutable; una transacción guarda checks, observaciones y revisión. Sin commit no hay fuente completa.
2. **Plan:** `BEGIN IMMEDIATE` fija revisiones, cobertura, obligaciones y miembros. No hay red dentro de SQLite.
3. **Reclamo:** se adquiere `flock` por `UnitKey`, se inserta `IN_FLIGHT` con `attempt_id` y fencing token y se hace commit antes de llamar al canal. El lock se conserva hasta registrar el resultado.
4. **Resultado:** una transacción valida el token, guarda recibo y cierra exactamente los miembros. Repetir el callback del mismo intento es idempotente.
5. **Rechazo conocido:** solo esa parte vuelve a ser reintentable. Timeout, desconexión o respuesta perdida quedan inciertos.
6. **Fallo al guardar después de aceptar:** se reintenta únicamente persistir el mismo resultado mientras el proceso lo conserve. Si desaparece, la recuperación concilia el intento antes de cualquier envío.
7. **Conciliación:** aceptación probada confirma; ausencia autoritativa permite reintentar la misma parte; imposibilidad de consultar deja pendiente sin reenvío.
8. **Cierre:** una transacción relee fuentes congeladas, plan, unidades, fotos, recibos y errores antes de escribir el resultado.

El despacho se limita a un host. SQLite impide obligaciones duplicadas y tokens atrasados; `flock` impide que dos procesos locales ejecuten a la vez la misma parte, incluso si uno está lento. Un lease vencido nunca autoriza por sí solo otra llamada de red. No se promete exactly-once físico sin idempotencia o consulta real del canal.

El perfil `claw` tiene una cola de un solo consumidor para Amazon y Gmail. A las 18:30 no se inician nuevas lecturas; se espera o cancela de forma controlada la lectura activa, se marcan los checks faltantes y solo después puede Gmail usar ese perfil. Telegram no depende del navegador.

Al reiniciar, las partes confirmadas no se tocan, las pendientes/rechazadas se retoman y `IN_FLIGHT` pasa a conciliación. Dos ejecuciones pueden adquirir evidencia redundante, pero no sellar la misma revisión ni entregar simultáneamente la misma parte.

## 8. Cierre comprobable

Un corte es completo solo si las seis fuentes de la revisión congelada estaban completas, el plan y sus miembros quedaron guardados y toda obligación prevista está confirmada o registrada como no requerida.

- Una fuente incompleta al congelar deja el corte parcial de forma permanente; una llegada tardía se conserva, pero no lo convierte en completo.
- Si las fuentes estaban completas y solo falta una foto o entrega, el corte permanece pendiente y puede cerrarse completo después de comprobarla.
- Capacidad excedida, historial ambiguo, entrega incierta o error de guardado deja una razón explícita y conserva todas las confirmaciones anteriores.

## 9. Historia existente

La importación es idempotente por `(origen, hash, parser_version)` y nunca modifica los originales.

| Evidencia | Qué puede acreditar | Qué queda pendiente |
| --- | --- | --- |
| HTML de `envios-del-dia` | Contenido y contexto cuando el ID interno es recuperable | Canal, destinatario, parte y aceptación. |
| `faseC_marcas` | Marca por fecha/canal | No cierra cobertura sin miembros y destinatario exactos. |
| `personalizadas-sent.json` | Recibo solo si clave, línea, destinatario y mensaje son inequívocos | Claves que colapsan líneas, formas históricas o índices no verificados. |
| Recibos/scratch OpenClaw | Ejecución y artefactos asociados | No prueban entrega por sí solos. |

Los niveles son `CONFIRMED_EXACT`, `AMBIGUOUS`, `CONTRADICTORY` y `UNREADABLE`. Solo el primero alimenta cobertura histórica. Una contradicción abre conciliación; no se elige la versión más conveniente.

## 10. Oráculo y harness

El oráculo vive en verificación y no importa política, planificador, cobertura, render ni SQLite del prototipo.

- Deriva elegibilidad con bucles propios sobre filas crudas anonimizadas.
- Deduplica con conjuntos independientes de claves literales.
- Calcula entregas permitidas desde el guion de recibos externos, no desde lo que el prototipo afirma haber guardado.
- Compara bandejas simuladas, miembros, parcialidad y cierre. Un mensaje en la base sin mensaje correcto en el transporte falso no cuenta como éxito.

El harness controla reloj IANA, fuentes, páginas, errores, fotos y transportes. Puede aceptar, rechazar, perder respuesta, caer después de aceptar y devolver evidencia confirmada, ausente o desconocida. Inyecta fallos antes/después de cada escritura y ejecuta dos procesos sobre el mismo corte. Ningún adaptador real ni credencial está disponible.

La matriz incluye los tres cortes, ML elegible/cancelado/despachado y ambas acciones, pago pendiente, Easy Ship pickup/drop-off/entregado, personalización multilínea y foto tardía, Seller Flex ausente, A→A+B con cobertura asimétrica, vacío principal, repaso sin extras, pedido nuevo en el último, fuente después de 18:30, más de tres partes, 50/51 y bloque imposible, interrupción tras primera entrega, fallo al guardar, incierto, reinicio, concurrencia, plazo ilegible, SKU ausente, duplicados entre vistas y transiciones de horario.

## 11. Decisiones ya observadas y experimentos pendientes

No se construyen dos sistemas completos. La rebanada vertical usa SQLite temporal, una fuente simulada, dos destinatarios y transportes falsos; los resultados deciden si las restricciones bastan.

Ya ejecutado, sin red real:

- El armado anterior, sobre datos ficticios, contó un ML por confirmar pero no lo mostró y sustituyó un `ship-by` ilegible por la fecha del corte. Se reproduce con `bash scripts/tests/test-resumen-envios-legado.sh`.
- El helper del PR 386 pasó sus 13 casos con mock. Con `TG_SOLO_CHATS='1, 2'` envió a un solo chat y devolvió éxito. Su estado también reabrió correo, David e Isabel al quitar «pago pendiente».
- Por tanto, se empieza de cero. Del PR 386 solo se conservan como requisitos la cobertura Easy Ship y la selección por destinatario; no se importan su helper ni su estado.

La matriz ejecutable se reproduce con:

```bash
bash scripts/tests/test-resumen-envios.sh
bash scripts/tests/test-resumen-envios-legado.sh
python3 -m scripts.tests.resumen_envios_previews > docs/evidence/resumen-envios-vistas-previas.json
ruff check scripts/resumen_envios scripts/tests/resumen_envios_*.py
```

Los mismos fixtures ya ejercitan choque de workers, clasificación de fallos y capacidad de Telegram. Los parsers de toda la historia real y la conciliación de proveedores siguen pendientes: una simulación no prueba una garantía del canal ni la equivalencia de todos los registros históricos.

## 12. Horarios y decisión 09:00/11:00

Las invocaciones propuestas usan directamente `America/Vancouver` y llaman al mismo servicio idempotente:

| Invocación lógica | Expresión sin aplicar | Operación |
| --- | --- | --- |
| Principal A | `0 18 * * 0-4` | `advance_cut(principal)`: recolectar/guardar. |
| Principal B | `15 18 * * 0-4` | El mismo método: borrador y recuperación hasta el límite. |
| Principal C | `30 18 * * 0-4` | El mismo método: congelar, entregar y cerrar. |
| Temprano | `0 5 * * 1-5` | `advance_cut(temprano)`. |
| Último | `0 9 * * 1-5` | `advance_cut(ultimo)`; único último repaso. |

`verif-digest-20h` permanece pausado. La conciliación es una operación del servicio, no otro corte; no se propone un nuevo horario para el vigía sin evidencia de necesidad y duración.

No hay datos suficientes para recomendar 11:00. La comparación sin envíos captura proyecciones independientes a 09:00 y 11:00, sin marcar entregas ni crear un segundo repaso operativo. Por modalidad registra nuevos elegibles, plazo, recolección, preparación y entrega reales. Para cada hora calcula `listo = hora + preparación + entrega` y `margen = min(plazo, última_recolección) - listo`, además de los pedidos que perderían margen y los adicionales capturados.

Solo se recomienda 11:00 si el margen observado demuestra preparación y despacho reales y cubre el colchón elegido por David. Si faltan datos o fuentes decisivas, se mantiene 09:00. Una aprobación posterior reemplaza la hora; nunca crea otro último repaso.

## 13. Decisiones de David y retorno

David decide el calendario de festivos y despacho, el margen aceptable para cambiar de hora, la resolución operativa de conciliaciones que el canal no pueda comprobar, los destinatarios finales del aviso de revisión incompleta y cualquier activación. Los experimentos no deciden esas preferencias.

No se reabren reglas fijadas: plataformas como autoridad, Odoo solo SKU, destinatarios del resumen y fotos, ausencia de montos, parcialidad explícita, no repetir confirmados y no reenviar inciertos.

El retorno se limita a detener las rutinas nuevas, mantener o dejar pausados los seis trabajos originales juntos y conservar `envios-del-dia`, `faseC_marcas`, `personalizadas-sent.json` y `openclaw.sqlite`. No se propone otro procedimiento.

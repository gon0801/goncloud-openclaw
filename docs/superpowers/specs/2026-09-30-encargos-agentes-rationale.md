# Decisión de arquitectura: encargos comunes

Estado: síntesis documental de `pstack:architect`. No implementado.

## Problema y base comprobada

En C2-r1 el revisor entregó a las 21:23 PDT, pero a las 21:50 el solicitante buscó solo las últimas 80 líneas y repitió el encargo. La entrega existía; faltaba un consumo durable que produjera la continuación. De veinte ejecuciones del vigilante, once terminaron con error. Una buscaba archivos de la Mac bajo el HOME de Windows.

La muestra de uso de esas veinte ejecuciones, 19:54–21:49 PDT del 30/9, registró 740.615 tokens de entrada, 65.191 de salida y 5.897.833 de caché. Es una suma de contadores reportados, no una auditoría monetaria ni de toda la cuenta. Motiva medir el sistema completo y eliminar el sondeo con modelos; no demuestra el ahorro de una implementación futura.

[PR #232](https://github.com/gon0801/goncloud-openclaw/pull/232) ya añadió persistencia y publicación de rondas. El nuevo diseño conserva ese mecanismo. La inspección de admisión de OpenClaw 2026.9.6 encontró deduplicación en proceso y pérdida de esa protección al reiniciar. Los diseños anteriores de avisos y director son antecedentes, no capacidades desplegadas.

## Uso y forma elegida

El solicitante llama a `submit` con trabajo, resultado esperado y límites. El ejecutor entrega por `report`. El consumidor usa `resolve` para registrar la siguiente acción o un desenlace. Consulta y cancelación completan la interfaz. El runtime deriva la identidad real; ningún modelo elige una sesión ajena.

La [especificación](2026-09-30-encargos-agentes-design.md) contiene los tres sitios de llamada y los tipos derivados de ellos. Tareas nativas posee identidad, cola, resultado y consumo. El ejecutor posee procesos locales. El director o agente conserva decisiones de negocio. El tablero proyecta evidencia. Esta separación evita guardar dos estados autoritativos para el mismo encargo.

## Alternativas comparadas

Dos candidatos independientes produjeron paquetes completos de uso, tipos, módulos, caídas, presupuesto y recursos. A usó un servicio propio de encargos del gateway, conectado por adaptador al runtime. B amplió las tareas nativas y conservó el scheduler existente. Se emplearon modelos distintos para los candidatos y un tercero para el juicio independiente.

| Criterio, 0 a 3 | Juez A | Juez B | Lead A | Lead B |
|---|---:|---:|---:|---:|
| Fallos, identidad y continuación | 3 | 3 | 3 | 2 |
| Agentes, hosts y permisos | 3 | 3 | 3 | 3 |
| Consumo verificable | 3 | 2 | 3 | 2 |
| Propiedad y cierre de recursos | 3 | 3 | 3 | 3 |
| Encaje y dueño único | 2 | 3 | 2 | 3 |
| Dependencias y pruebas comprobables | 3 | 2 | 2 | 1 |
| Total antes de síntesis | 17 | 16 | 16 | 14 |

El juez recomendó B por propiedad, pese al total menor. La lectura inicial del lead favorecía A por su consumo explícito y menor cambio nativo. Al comparar dependencias, A también necesitaba modificar o demostrar la admisión nativa durable; su base privada no eliminaba ese requisito. Se adopta B para evitar dos coordinadores y se incorporan las garantías más completas de A.

La diferencia en corrección identifica una carencia concreta: reservar una continuación y despertar al solicitante todavía no prueba que registró qué sigue. La síntesis añade `resolve`, tomado de A, que crea decisión, hijos y recibo de consumo en una transacción. Un turno que termina sin ese recibo sigue pendiente. Esa incorporación es necesaria para resolver el incidente, no un añadido opcional.

También se integran de A la reserva previa de consumo, la contabilidad de caché sin doble suma, la inelegibilidad de ejecutores opacos para garantías estrictas y el límite de recuperación por raíz. De B se conservan identidad nativa de tarea/turno, permisos, cola existente y propietario único del lifecycle. Se explicitan incidencias no terminales, generaciones tardías y prueba de cierre de descendientes.

Se rechazan una base privada que duplique tareas nativas, sesiones supervisoras por corrida, lectura periódica de panes con modelo, reenvíos ciegos tras timeout y la liberación de cupo sin prueba de ausencia. No hubo candidatos descartados por falta de entrega.

## Intercambios aceptados

- Se acepta ampliar y mantener el runtime a cambio de una autoridad durable de tareas. La modificación debe tener versión y pruebas; no es una edición manual de SQLite.
- Se acepta conservar recursos reservados durante incertidumbre a cambio de evitar procesos duplicados y cierres falsos.
- Se acepta bloquear un ejecutor que no demuestre límites efectivos a cambio de no prometer control de consumo inexistente.
- Se acepta que el juicio útil cueste tokens. La garantía buscada es cero inferencia de vigilancia sin novedades, no costo cero de la tarea.
- Se acepta archivar evidencia e historial sin borrarlos por antigüedad. Su existencia no implica procesos fantasma.

## Revisión de forma y verificación

Se revisaron módulos superficiales, filtración de transporte, capas por orden temporal y métodos que solo reenvían argumentos. La interfaz resultante concentra operaciones completas; las fronteras responden a propietarios distintos. El scheduler no se duplica y el protocolo no se convierte en director universal de negocio.

Las pruebas del documento son criterios futuros. Solo se verificaron consistencia, referencias locales y los candados documentales al guardar el diseño. No se ejecutaron pruebas de admisión, modelos, procesos ni recuperación de producción. La cobertura de todos los agentes y la ausencia de huérfanos siguen pendientes de implementación y medición.

La revisión de la síntesis encontró una frontera de caída omitida: resultado confirmado antes de encolar su proyección. Se corrigió especificando una intención de proyección en la misma transacción del resultado, transferencia confirmada por ID a la cola existente y retención de evidencia hasta completar sus entregas. Se añadió el escenario correspondiente a la matriz de aceptación. Esto corrige el contrato documental; su comportamiento sigue pendiente de implementación y prueba.

## Riesgos y preguntas de validación futura

¿Puede la extensión nativa hacer durable la admisión, cola y recibo bajo reinicio sin iniciar dos turnos? ¿Puede vincular herramientas con una identidad de ejecución autenticada? ¿Puede cada CLI controlar consumo y contener sus descendientes? Estas preguntas tienen pruebas de salida en la especificación; una respuesta negativa impide habilitar la garantía correspondiente.

El primer paso posterior será un ensayo aislado de esos contratos con proveedor falso. Por instrucción del usuario, aquí se entrega únicamente el diseño.

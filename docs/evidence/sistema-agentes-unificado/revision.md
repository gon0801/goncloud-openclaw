# Revisión del diseño unificado

Fecha: 2026-10-05. Alcance: documentos y comprobaciones de diseño.

## Qué se contrastó

Se leyó el flujo actual, los planes, sus contratos y la historia que explica las
fronteras. Cuatro investigaciones cubrieron U3b, U4/U5, U6/runtime e historia.
La revisión de flota integró las inspecciones anteriores de OpenCode y quality-kit.
Después se escribieron y leyeron dos diseños completos y se compararon mediante
un juicio independiente. Las evidencias de trabajo se conservan en
`/Users/dn/.claude/orchestrate/plan-unificado-agentes/`.

| Fuente | Hallazgo que afecta el diseño |
|---|---|
| G `Plans.md`, fases 17/20/U6/F | Siguen pendientes; hay contratos y políticas contradictorias. Las fases cerradas tienen evidencia que debe conservarse. |
| G `scripts/mac/corrida_worker/{reconcile,task_handoffs,gates,registry}.py` | Existe coordinación y transporte reutilizables; un nuevo director paralelo duplicaría decisiones. |
| R `src/agents/tasks/managed-task.handling.worker.ts` y contratos/test de tareas | `Continue` existe y es durable por padre/resultado. No acredita fan-in A+B→C, admisión inicial arbitraria, pausa de meta o aceptación. |
| G `scripts/agent-work/progress_bridge.py` | Hay proyección durable con ACK. Su verdad de presentación debe derivarse del dueño nativo, sin un ledger de consumo adicional. |
| G instaladores y selección/publicación Windows | Destinos nuevos necesitan manifiesto autorizado; publicar archivos no acredita activar un plugin. |
| Modo legacy Hermes | Aún invoca rutas OpenClaw; no demuestra operación independiente. |
| O `docs/DEPLOY.md` | Receta con artefacto remoto, copia, respaldo, `--no-deps` y salud 8010; el script automatizado sigue pendiente. |

Bases de inspección: G `e5cae2d`, main remoto `77fafb0`, R `6e3d428`, O `25cebe7`.
Estos SHAs describen fuente consultada, no instalación ni aceptación productiva.
El checkout principal con cambios ajenos no se modificó.

## Comparación de alternativas

| Alternativa | Forma | Aporte / coste |
|---|---|---|
| A: políticas separadas | Goals, Engineering y Fleet producen decisiones para `Host.apply`. | Buena separación de conocimiento y cierres por host; expone más composición al llamador. |
| B: controlador local | `open/control/reconcile/read`; `host.commit` atómico. | Une decisiones de meta/unidad y reduce coordinación externa; necesita conservar módulos internos pequeños. |

El juicio independiente dio A **23/25** y B **23/25**. Favoreció B por su interfaz,
condicionado a incorporar las fronteras internas y entrega por host de A. La
síntesis adopta B con políticas puras internas, efectos inciertos explícitos,
review distinto de aceptación y cierres OpenClaw/Hermes separados.

Ambos candidatos dejaban ambigüedad en el límite de correcciones. Se cerró con
cuatro ciclos totales por bloque lógico bajo la raíz, sin reinicio por nuevo
hallazgo, modelo o revisión automática. Es una propuesta nueva versionada; no
se atribuye a una decisión previa ni se aplica a este trabajo documental.

Se aclaró también la colocación: el controlador vive en el runtime de cada host.
G distribuye integraciones, recetas y contratos, sin gobernar Hermes a distancia.
No se requiere que ambos compartan lenguaje o un servicio de políticas.

## Historia y cambios deliberados

- El fallo de continuidad y consumo repetido justificó estado durable y dueño
  único. No prueba que haya que conservar todos los scripts o una cola nueva.
- Hermes independiente es un requisito del usuario. No se dedujo un supuesto
  beneficio económico ni se convirtió en réplica del gateway OpenClaw.
- El historial contiene `35c0661` con cinco rondas más relevo y `8358fac` alineando
  a la regla de detener el mismo bloqueante en dos rondas. No hay medición que
  justifique una cifra óptima. SUA propone una política finita explícita.
- La fixture antigua de cupo esperaba admitir un par con tres plazas ocupadas de
  cuatro. El diseño corrige esa condición, conservando el límite y la atomicidad.
- El reviewer necesita entregar un veredicto. Esto no requiere permiso para
  modificar fuente; usa canal de resultado o directorio de salida restringido.
- `Continue` ya instalado en fuente reduce trabajo necesario, pero su clave por
  padre no sustituye un binding nativo de unidad en un DAG.

## OpenCode

La inspección local previa identificó versión 1.18.34, siete perfiles pstack,
modelo configurado `zai-coding-plan/glm-5.3-flash` y ausencia de bloques de permiso
por agente. El perfil de panel conserva herramientas de escritura. La profundidad
y herramientas heredadas limitan hijos; background requiere bandera experimental.
No se lanzaron modelos para convertir estas observaciones en certificación viva.

El documento propuesto aporta especialización, contexto por rol y telemetría. Se
adoptan tras certificar capacidades. Se descartan director adicional, `SMALL` sin
review, `PASS` sin evidencia, modelos de ejemplo como acceso supuesto y loops fijos.
Las [permissions de OpenCode](https://opencode.ai/docs/permissions/) describen su
configuración; no prueban por sí solas confinamiento del entorno local.

Informe completo anterior:
`/Users/dn/.claude/orchestrate/flota-poteto/docs/opencode-harness-review.md`.

## Quality-kit

Se conserva valor verificable: hooks, regresión por bug, inventario de pruebas,
unión de shards, detección de vacío y evidencia de revisión. Se propone retirar
coordinación y reglas copiadas obligatorias después de migrar sus consumidores.

La inspección de `cross-review.ps1` encontró selección fija de CLIs, `glm` hacia
`zcode`, falta de binding del modelo y recorte de diff a 60.000 caracteres. El mock
con texto `BLOCKER` y rc0 acredita que entrega no significa aprobación. No demuestra
un falso aprobado global: las compuertas de G sí exigen veredicto y SHA.

El carril rápido admite el corpus TSV mientras su consumidor está en la batería
omitida; `test-ci-coverage-contract` tiene ejecución duplicada. Son hallazgos de
cableado estático, no una ejecución de CI viva. SUA-05 los convierte en pruebas
discriminantes y mantiene la batería completa requerida por las reglas actuales.

Los límites de líneas y limpieza de archivos no acreditan especialidad ni vigencia
de fuentes. Por ello SUA añade pruebas de dominio y contexto, sin borrar memoria.
No se desinstaló el kit ni se editó su bloque administrado de reglas.

Informe completo anterior:
`/Users/dn/.claude/orchestrate/flota-poteto/docs/quality-kit-review.md`.

## Prototipo y verificación documental

Se ejecutó un modelo abstracto fuera del repo: 24 órdenes de llegada de resultados
y reconciliadores convergen en una C con binding de unidad; el control negativo
por claves de padre produce dos. Comprueba además rechazo de épocas/revisiones
viejas y conservación de efecto incierto. No importa código de OpenClaw/Hermes.

El validador documental comprobó 14 bloques sin ciclos, 39 filas antiguas, los 38
criterios heredados y 24 ensayos. Sus cuatro controles negativos rechazan fila
omitida, ciclo, destino desconocido y ensayo inexistente. También comprueba enlaces
locales y preservación exacta de los documentos históricos tras quitar el aviso
nuevo; en Plans conserva las filas históricas y los cierres U0–U3a.

Una revisión independiente agrupó dos bloqueantes documentales. Se corrigieron
juntos: `Started` es el punto de compromiso, el recibo de pausa enumera los efectos
que aún pueden llegar al destino; implementación de quality-policy.v2 se separa
de su adopción autorizada por repo/host. I05/I12 incluyen ambas condiciones.
El límite usa un linaje estable del bloque y el replay de control tiene recibo.

Las observaciones no bloqueantes quedaron en SUA-01 (Resume repetido/obsoleto) y
SUA-07 (inventariar entregables compartidos para no exigir runtime R disponible).
Los programas comparten calendario de entregables; la independencia exigida es
operativa. No se promete un calendario completamente desacoplado entre equipos.

Scripts y salidas de comprobación se conservan en el directorio de trabajo indicado
arriba. Ninguna comprobación del diseño acredita fan-in, promociones, UI o Hermes
vivos.

**Cierre documental:** gpt-6-sol hizo la revisión completa; gpt-5.6-terra revisó
únicamente las correcciones y emitió `APPROVE`, sin bloqueantes abiertos en ese
delta. Los hooks de pre-commit pasaron sobre los 17 documentos del cambio; JSON y
YAML no aplican a estos Markdown. `git diff --check` pasó. No se ejecutaron baterías
de producto, modelos trabajadores, instalaciones ni despliegues. El diseño define
su futura prueba; no reemplaza esos recibos con esta revisión documental.

## Condiciones de integración pendientes

| Condición | Cómo se resuelve | Si falla |
|---|---|---|
| API/plataforma Hermes real | Inventario y contrato local en SUA-07 | Bloquear esa integración; OpenClaw puede avanzar. |
| Poteto y permisos efectivos por ruta | Entrega/conducta y pruebas negativas SUA-03 | Ruta visible e inelegible. |
| Modelo efectivo/acceso/sucesor | Evidencia oficial, configuración real y canary SUA-04 | No promover ni afirmar versión. |
| UI/licencia LobsterBoard | Commit y prueba original móvil/escritorio SUA-06 | Detener UI con faltantes y alternativas acotadas. |
| Contabilidad CLI | Medición o límites conservadores comprobables | No admitir rutas incompatibles con presupuesto. |
| Publicación y autoridad | Paquete, read-back y permiso aplicable SUA-09/10 | Detener sólo el efecto sin autorización/evidencia. |
| Coste/latencia total | Baseline y recibos de ejecución | Informar desconocido o regresión, sin prometer ahorro. |

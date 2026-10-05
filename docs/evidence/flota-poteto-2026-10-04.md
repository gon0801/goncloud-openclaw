# Lecturas de la flota y pruebas de arquitectura

Fecha: 2026-10-04. Base investigada: `origin/main` en `77fafb0`.
Worktree: `feat/flota-poteto`. Las consultas siguientes son de solo lectura.

## Inventario nativo

Se consultó el gateway con OpenClaw CLI 2026.9.7 mediante
`gateway call agents.list --json` y `gateway call config.get --json`.
La respuesta de configuración se procesó en memoria y se conservaron únicamente
identificadores, estado de delegación y metadatos necesarios, sin credenciales.

La lectura inicial devolvió ocho agentes. La lectura posterior y la
configuración efectiva coinciden en 19:

```text
main operaciones ingenieria implementer reviewer adversary verifier scout
amazon pers meli mail limpia odoo arras gonserver skillverif tinkabot eggbot
```

Main tiene los 19 IDs en `subagents.allowAgents`. Operaciones declara `odoo`.
Las revisiones de configuración y aplicada coinciden en la lectura posterior.
No se reprodujo una discrepancia persistente; no se diagnosticó una causa para
el cambio entre lecturas. No se crearon agentes ni modificaron sus permisos.

`agents list --json --bindings` local devolvió solo main. Ese inventario local
no representa el gateway remoto. El descubrimiento debe nombrar la autoridad.

## Poteto y especialización

Se consultaron `agents.files.get` y `skills.status` con `agentId` explícito para
main, amazon, meli, mail, limpia y skillverif. No se conservaron contenidos
personales de AGENTS.md o SOUL.md en este documento.

| Agente | AGENTS.md bytes | SOUL.md bytes | Skills totales | Elegibles | Poteto |
|---|---|---|---|---|---|
| main | 13624 | 6877 | 212 | 113 | disabled=true, eligible=false |
| amazon | 1498 | 247 | 172 | 73 | disabled=true, eligible=false |
| meli | 1510 | 234 | 171 | 72 | disabled=true, eligible=false |
| mail | 1568 | 234 | 171 | 72 | disabled=true, eligible=false |
| limpia | 1697 | 268 | 171 | 72 | disabled=true, eligible=false |
| skillverif | 1267 | 261 | 170 | 71 | disabled=true, eligible=false |

La clave efectiva es `Poteto Mode`, con `enabled=false`. Su fuente declarada es
`openclaw-managed`, en `skills/grok/pstack/poteto-mode/SKILL.md` del gateway.
`blockedByAllowlist=false`; la deshabilitación no procede de esa allowlist.
Ninguno de los doce documentos muestreados menciona poteto o pstack.

Los perfiles tienen términos de su dominio y son breves. No se probó la calidad
de sus decisiones ni se midió el prompt efectivo. El número de skills elegibles
no equivale al número de skills cargadas completas en cada turno.

## Catálogo de modelos

`models list --all --json` devuelve 82 filas. Sus campos observados son `key`,
`name`, `input`, `contextWindow`, `local`, `available` y `tags`. No se observaron
campos explícitos de publicación, estabilidad u orden de sucesión. Disponibilidad
en este inventario no prueba una invocación con herramientas para cada cuenta.

El diseño requiere adaptadores de evidencia de publicación y pruebas por
runtime antes de actualizar las asignaciones. El prototipo usa esa evidencia
como entrada y no acredita descubrimiento automático en proveedores vivos.

## Límites

No se lanzaron tareas de negocio ni se escribieron configuraciones en el gateway.
No se habilitó una copia de poteto sin comprobar su adaptación y dependencias.
La comprobación de arranque, hijos y reanudación requiere ensayos de entrega
efectiva. Las pruebas sintéticas no sustituyen esos ensayos.

## Arreglo inicial comprobado

`scripts/tests/test-worker-model-binding.sh` reprodujo dos defectos antes del
arreglo: cambiar solo `worker.model` conservaba `claude-fable-5-1` en argv;
reanudar después de cambiar el registro tocaba la sesión antes de rechazar el
modelo distinto. Los mensajes discriminantes fueron:

```text
accepted invalid model binding ... claude-fable-5-1
resume touched session after model changed or pin missing
```

El arreglo valida el registro en la generación real de argv y rechaza el
desacuerdo entre flags explícitos de modelo y metadatos. La reanudación compara
modelo, trabajador y sesión antes de tocar tmux. La prueba cubre siete entradas
del registro, valores inválidos y preservación de la sesión viva.

Pasaron las pruebas focalizadas de modelo, registro, selector y adaptadores
nativos con tmux aislado. El prototipo pasó nueve pruebas conductuales. Los
hooks pre-commit pasaron; se corrigió un salto de línea final que detectaron.
La batería completa pertenece a CI sobre el commit publicado de este bloque.

Este arreglo rechaza drift; no implementa promoción automática. Una sustitución
concurrente del registro todavía requiere el snapshot por intento de F.2.
`workers.v1.json` conserva sus modelos y comandos. El prototipo está bajo
`docs/prototypes/flota-poteto` y no se importa desde producción.

## Revisión del arreglo

La primera revisión reprodujo un bloqueo: el elemento JSON `--model\nwrong`
pasaba la validación y se convertía en dos argumentos al serializar por líneas.
La corrección rechaza caracteres de control antes de serializar. La regresión
cubre LF, CR, NUL, tab y DEL tanto en el registro como en `worker_argv`, y exige
que el rechazo no produzca argumentos parciales.

Un segundo revisor examinó solo esa corrección y aprobó tras ejecutar
`bash scripts/tests/test-worker-model-binding.sh` con código de salida 0.
No se repitió la batería completa durante ninguna ronda.

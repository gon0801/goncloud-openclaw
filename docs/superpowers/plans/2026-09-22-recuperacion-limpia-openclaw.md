# Recuperación limpia de OpenClaw y ruta al centro de tareas

> **Histórico desde la reinstalación del 22 de septiembre.** La ruta activa es
> U0–U5 al inicio de `Plans.md`. No repitas este corte ni tomes sus filas TODO
> como autorización para desinstalar o restaurar el estado anterior. El
> inventario vivo de PR #132 y sus pendientes alimentan U0/U1.

> Plan maestro para agentes ejecutores. Antes de operar Windows, convertir el
> inventario real en un runbook de corte con comandos y destinos exactos, revisarlo
> y obtener una autorización operativa separada. Este plan no autoriza borrar,
> desinstalar, cambiar configuración viva, hacer merge ni desplegar.

**Goal:** OpenClaw limpio y estable, con los ocho agentes y sus cadenas de
modelos intactos; después, tareas autónomas con seguimiento y resultado
verificado, panel visual y la misma experiencia en Hermes en otro equipo.

**Arquitectura:** El estado viejo queda recuperable fuera de la instalación
nueva. Un respaldo oficial verificado y restaurado en staging protege lo único
que no está en Git. La nueva instalación usa configuración mínima y copia
selectiva de agentes, workspaces y skills; no importa la base antigua entera.
`main` y `corrida.sh` conservan la coordinación, el reloj global de Fase 9
conserva los avisos y Fase 17 añade una vista, no otro orquestador.

**Spec:** `docs/spec/00-project-spec.md`, sección "Objetivo de recuperación
limpia". Contrato anterior a reconciliar:
`docs/superpowers/specs/2026-09-22-openclaw-runtime-separation-design.md`.

**Estado:** propuesta de planificación. `team_validation_mode: subagent`
(producto, arquitectura y seguridad/QA, solo lectura). Las interfaces y el
contenido del Windows vivo son `unknown` hasta 18.0.

## Resultado y límites

El primer hito es un OpenClaw que arranca y atiende un encargo pequeño en
Windows sin arrastrar la instalación dañada. Ese hito no equivale todavía a
"autonomía completa" ni a paridad con Hermes. Los siguientes hitos prueban,
en ese orden, una tarea autónoma con seguimiento, un panel local útil y la
misma aceptación en el equipo Hermes. No se declara el goal completo antes
de las cuatro pruebas.

Se preservan como datos de recuperación el respaldo privado, el inventario
redactado, las ediciones únicas de agentes/workspaces/skills y las definiciones
de servicio/tareas. Se reconstruyen desde fuente conocida los repositorios,
paquetes, cachés, modelos descargables y launchers generados. No se presume
que el historial, la memoria ni las credenciales del estado viejo deban
activarse en el nuevo; el respaldo permite decidir después sin pérdida ciega.

La cadena de modelos se mide como arreglo ordenado `[primary,
...fallbacks]` para `main`, `operaciones`, `ingenieria`, `implementer`,
`reviewer`, `adversary`, `verifier` y `scout`, más `agents.defaults.model`.
Fuente primaria: exportación fresca del host, sin valores de autenticación.
Referencias fechadas: imagen del 19 de septiembre y
`docs/patches/modelos-vivos-2026-09-15.json5`. Cualquier diferencia se
presenta a David; no se elige una de las tres fuentes por intuición ni se
sustituye un modelo inaccesible. `usuario` de Fase 9 se evalúa como adición
posterior, no se cuenta entre los ocho rescatados.

## Secuencia de entregas

| Hito | Entrega comprobable | Dependencia |
|---|---|---|
| R0 | Inventario sin secretos y respaldo restaurado en staging | Ninguna operación destructiva |
| R1 | Instalación nueva en Windows con ocho agentes/cadenas exactas y reversa probada | R0 y autorización operativa cerrada |
| R2 | Una tarea real acotada avanza y cierra con avisos, CLI e evidencia sin vigilancia humana | R1; núcleo de Fases 9 y 14 |
| R3 | Panel local de solo lectura muestra esa misma tarea, inspirado visualmente en LobsterBoard y en funciones seleccionadas de OpenGrokBot | R2; contrato de Fase 17 revisado |
| R4 | Mismos escenarios en el equipo Hermes, con OpenClaw inaccesible | R3; adaptación independiente de Fase 17 |
| R5 | Reconciliación de planes, PRs y evidencia, sin reescribir historia | R1 medido; R2–R4 incorporados como trabajo pendiente y criterios de aceptación |

R2–R4 se implementan en sus planes de producto revisados, no copiando a ciegas
todo el PR de Fase 16 ni creando un segundo coordinador. La ejecución de R1
puede comenzar antes de esos desarrollos; su estado se comunica como
"OpenClaw recuperado, autonomía/panel pendientes" si corresponde.

## Fases ejecutables y punto de arranque

Fase 18 se entrega en cinco bloques consecutivos. Cada bloque tiene su propio
recibo y PR cuando modifica el repo; el siguiente no interpreta un PR abierto
como aceptación del anterior. R2–R4 vienen después de la reconciliación E,
en Fases 9, 14 y 17 revisadas. La etiqueta R5 nombra esa reconciliación, no
un hito que deba esperar a terminar Hermes.

| Bloque | Tareas | Resultado que ve David | Compuerta para el siguiente |
|---|---|---|---|
| A. Diagnóstico | 18.0 | Lista de qué se conservará, con ocho agentes y modelos ordenados; ninguna modificación viva | Manifiesto privado completo y recibo redactado; discrepancias resueltas, o se detiene B |
| B. Salvaguarda | 18.1–18.2 | Respaldo probado y procedimiento exacto de corte/reversa para su Windows | Restauración en staging y revisión del runbook; sin ambos no hay reinstalación |
| C. Preparación | 18.3 | Código y pruebas listos para instalar sin mezclar fuente con estado vivo | PR de código revisado y batería completa verde, sin desplegar |
| D. Reconstrucción | 18.4–18.5 | OpenClaw nuevo atiende un encargo pequeño con los ocho agentes | Autorización operativa por tarea, recibo de corte y aceptación viva; fallo devuelve al procedimiento de reversa |
| E. Replanificación | 18.6–18.7 | Fases 15, 9, 14, 16 y 17 quedan coherentes con el sistema medido | Un PR de ledger revisado; R2–R4 quedan con DoD y Depends, no marcados terminados |

El primer trabajo es **18.0**. El ejecutor puede preparar desde este repo la
plantilla del manifiesto y comparar las dos referencias fechadas. Para cerrar
18.0 debe leer el host Windows con alcance acordado y registrar versión,
instalador dueño, rutas, servicios, agentes, modelos, tareas y sync. No lee
valores de credenciales ni cambia configuración. Guarda el inventario completo
en destino privado y publica solo un recibo sin secretos. Si el host no está
accesible, deja los campos como `unknown`; no inicia 18.1 ni 18.4 por suposición.

## Tasks de recuperación (Fase 18)

Cada fila declara su propia salida. Los pasos con efecto vivo permanecen
bloqueados hasta recibir la referencia de autorización que indica la fila.

| Task | Contenido | DoD | Depends | Status |
|---|---|---|---|---|
| 18.0 | `[lane:fast] [tdd:skip:inventario]` Inventariar versión e instalador dueño, rutas reales de estado/config/agentes/workspaces, ocho IDs y roles, cadenas ordenadas/defaults, skills únicas, tareas programadas, sync, canales y credenciales solo por referencia/existencia. Resolver discrepancias con la captura y el snapshot fechado. | Un manifiesto redactado registra origen, hora y método de cada dato; ocho arreglos ordenados y defaults aprobados por David; ningún secreto ni transcripción sale al repo. Una ausencia no observada queda `unknown`. | - | cc:TODO |
| 18.1 | `[lane:gate] [tdd:skip:respaldo-operativo]` Crear con `openclaw backup create --verify` un archivo oficial en destino privado fuera del estado, verificarlo y restaurarlo a staging fresco con ACL restringidas; preservar por separado bundle del Git vivo, XML de tareas, launchers e inventario de ediciones no publicadas. | `backup verify` y `backup restore --target` pasan sobre el archivo real; se cotejan por separado la base compartida, las ocho bases de agente declaradas, presencia de credenciales sin mostrar valores, workspaces, bundle Git, XML y launchers. Hashes, tamaño, ACL, rutas y resultado quedan en recibo redactado. Un fallo frena R1 antes de mover nada. | 18.0, autorización de respaldo/lectura de datos privados | cc:TODO |
| 18.2 | `[lane:gate] [tdd:skip:procedimiento-host]` Escribir el runbook Windows específico después del inventario: CLI/versión y dueño de instalación, `uninstall --dry-run` por alcance, ruta nueva y vieja, puerto, tareas, sync deshabilitado, instalación, reautenticación, selección de archivos, corte y reversa. Revisión independiente y simulacro de solo lectura. | Cada comando tiene destino resuelto, efecto, salida esperada y acción ante fallo; el dry-run enumera exactamente los objetivos; `--all` solo se admite con `--dry-run`, nunca en el corte real; no hay borrado recursivo; un lector nuevo no necesita adivinar rutas. La autorización operativa cita ese runbook, SHA y ventana. | 18.0, 18.1 | cc:TODO |
| 18.3 | `[lane:gate] [tdd:required]` Preparar solo las piezas de código necesarias para el estado nuevo: fuente fuera de `.openclaw`, despliegue por allowlist, sync que no usa Git en la base viva y prueba de instalación/configuración idempotente. Extraer/revisar las piezas útiles del PR #128 en una rama nueva desde `origin/main`; no integrar la transacción antigua entera por inercia. | Pruebas focalizadas fallan antes y pasan después para source/runtime separados, ruta protegida, rollback y segundo ciclo sin escrituras/PRs; hooks y CI completos verdes en el SHA final; revisión independiente sin bloqueantes. | 18.2 | cc:TODO |
| 18.4 | `[lane:release] [tdd:skip:operacion-viva]` Ejecutar la reconstrucción limpia en Windows con la referencia operativa: detener/retirar solo el servicio identificado, mantener el estado viejo recuperable, instalar paquete/version aprobados en estado nuevo, reconfigurar conexiones y copiar únicamente agente/workspace/skill seleccionados. No importar SQLite/sesiones ni config vieja en bloque. | `doctor`, health 200/200 y tarea oficial del gateway sanos; ocho agentes, roles, defaults y cadenas ordenadas coinciden con 18.0; cada agente responde por su ruta real. Un proveedor inaccesible deja R1 bloqueado, sin sustituir su modelo ni declarar la fase verde. Estado viejo y respaldo permanecen íntegros; recibo de corte y reversa. | 18.1–18.3, autorización Windows separada | cc:TODO |
| 18.5 | `[lane:release] [tdd:skip:aceptacion-viva]` Comprobar trabajo real mínimo, sync y seguridad en el estado nuevo. La memoria semántica Ollama y el nodo aislado se instalan solo si el inventario/uso los exige; nunca se relaja Code Integrity. | Dos ciclos sin duplicados ni sobrescritura, un encargo acotado enviado a `main` y resultado observado, estado/consumo de procesos medidos, ningún prompt rutinario sin dueño; los componentes no restaurados se listan como pendientes, no como verdes. Rollback antes/después de tráfico distingue bases viejas y nuevas. | 18.4, autorización explícita para encargo y sync | cc:TODO |
| 18.6 | `[lane:fast] [tdd:skip:replan-documental]` Reconciliar Fases 15, 9, 14, 16 y 17 contra el estado medido, en un solo PR de ledger, sin borrar filas históricas. Dividir la aceptación de Fase 17 en panel local OpenClaw y paridad Hermes; recortar el primer canary de Fase 14 al CLI elegido y preservar expansión posterior; precisar instalación/seguimiento de Fase 9; marcar Fase 16 antigua como reemplazada solo donde R1 probó la nueva ruta. | Matriz por fila `conservar/reusar/reemplazar/diferir` con evidencia y nuevo Depends/DoD; 15 sigue cerrada con sus SHAs; ningún `cc:完了` nuevo sin recibo; #128/#130 reciben decisión explícita de reutilización o cierre sin merge automático. El plan resultante cubre R2–R4 y las cadenas de modelos. | 18.5 | cc:TODO |
| 18.7 | `[lane:fast] [tdd:skip:cierre]` Cerrar la recuperación como hito R1 y entregar la cola R2–R4 al plan revisado. | PR de cierre con recibos redactados, pruebas/CI vigentes y limitaciones; mensaje a David distingue "OpenClaw recuperado" de "goal completo". No se borra el archivo viejo ni el respaldo al cerrar. | 18.6 | cc:TODO |

## Trabajo posterior que las fases revisadas deben cubrir

- **Autonomía, R2:** Fase 9 instala y demuestra un único reloj de seguimiento,
  preflight y respuesta automática solo a acciones rutinarias preaprobadas;
  Fase 14 coordina un canary con el CLI realmente elegido, límite de procesos,
  presupuesto, reanudación y evidencia de cierre. Cerrar el navegador o el
  turno de `main` no detiene ni duplica la tarea. La ausencia de autorización
  para un efecto externo se comunica, mientras las tareas independientes siguen.
- **Panel, R3:** Fase 17 empieza por una vista OpenClaw local de solo lectura.
  Debe mostrar goal, responsable, agente, CLI, modelo observado o `unknown`,
  intento, avance verificable, espera, siguiente revisión y evidencia. Validar
  en móvil/escritorio con capturas contra una referencia visual elegida de
  LobsterBoard. Tomar de OpenGrokBot solo comportamientos descritos y probados
  (por ejemplo, estado por agente y cierre legible), no su gateway o Docker.
- **Hermes, R4:** adaptar el mismo contrato y pruebas en el otro equipo sin
  copiar identidad, secretos, sesiones ni estado. El runtime OpenClaw debe
  estar apagado o inaccesible durante esa prueba. No se promete continuidad
  automática entre equipos ni interfaz de continuación Hermes sin medirla.

## Compuertas de autoridad y recuperación

| Operación | Esta petición de plan | Autorización necesaria para ejecutar |
|---|---|---|
| Documentar, revisar, abrir PR de este plan | Aprobado por el pedido actual | Ninguna adicional |
| Inventario local de rutas/IDs/modelos sin secretos | Propuesto | Acceso al host y alcance de lectura acordados al lanzar 18.0 |
| Respaldo privado y restauración de prueba | Propuesto | Referencia para leer estado privado y escribir en destino exacto |
| Merge de código o deploy automático por sync | No aprobado | Referencia de merge+deploy del SHA exacto |
| Desinstalar servicio, cambiar tareas/config, pairing o cortar Windows | No aprobado | Referencia operativa con host, SHA, ventana y reversa |
| Enviar un encargo real y correr dos ciclos de sync en 18.5 | No aprobado | Referencia propia, o la de 18.4 solo si declara ese alcance, host, build/SHA, ventana y efectos permitidos |
| Borrar estado viejo, respaldos, sesiones, credenciales o cuarentena | No aprobado | Decisión posterior sobre objetivos exactos; no es requisito de R1 |

La palabra "sin permisos" significa que los trabajos rutinarios ya
preaprobados no vuelven a preguntar. No habilita shell libre ni una tabla que
apruebe borrado, merge, despliegue, secretos o efectos externos irreversibles.
Un efecto cuyo resultado quedó incierto tras un crash no se repite hasta
reconciliar su destino o su clave de idempotencia.

El rollback antes de reabrir tráfico puede volver al estado viejo intacto.
Después de recibir tráfico nuevo, no se sobrescribe la base nueva con la
vieja: se hace respaldo diagnóstico del estado nuevo, se conserva y se
restaura servicio por componente. La recuperación no depende de que `main`
esté despierto ni de un mensaje que pase por el gateway detenido.

## Verificación y fuentes

Implementación: pruebas focalizadas por bloque; `pre-commit` sin omitir hooks;
una batería completa por SHA final en CI de PR, incluidos los contratos
Windows; revisión del diff y evidencia de canary vivo separada de CI. Los
controles existentes son `.pre-commit-config.yaml`, `scripts/run-checks.sh` y
`.github/workflows/quality.yml`. El estado de formatter/lint para cada lenguaje
que toque 18.3 debe comprobarse antes de escribir código; no se presume
cobertura por la sola presencia de hooks.

Fuentes consultadas: documentación oficial de
[respaldo](https://docs.openclaw.ai/install/backups),
[desinstalación](https://docs.openclaw.ai/install/uninstall) y
[modelos por agente](https://docs.openclaw.ai/gateway/config-agents/models);
`Plans.md` y los diseños existentes de Fases 16/17. La compatibilidad de la
versión instalada, la ruta de instalación real y el estado del nodo/memoria
permanecen `unknown` hasta el inventario del host.

## Clasificación

**Required:** 18.0–18.7, R2–R4 para el goal completo, ocho agentes/cadenas
exactos, respaldo restaurado, reversa, preaprobación acotada y aceptación
de usuario. **Condicional:** Ollama/memoria semántica, nodo Windows, la novena
identidad `usuario` y componentes de Fase 16 que el inventario demuestre
necesarios. **Diferido:** seis CLIs desde el primer canary, métricas de costo
sin fuente del proveedor, controles de ejecución desde el navegador, visor
multi-host y acceso remoto. **Rechazado:** `uninstall --all` sin inventario,
borrado directo de `.openclaw`, restaurar la base vieja sobre mensajes nuevos,
copiar credenciales entre hosts, relajar Code Integrity, segundo reloj o
marcar una fase como completa por un PR/CI sin prueba viva.

# Cierre de Fase 9

## Propósito

Fase 9 debe terminar desde el estado que existe en `origin/main`. El cierre no
repite los carriles que ya se integraron. Corrige los pendientes que aún
impiden usar y verificar las corridas autónomas, instala desde `main`, ejecuta
un simulacro observable y deja el plan con estados terminales honestos.

El dueño inicia la ejecución con una frase a Claw. Claw abre el runbook, elige
al lead disponible y releva al trabajador cuando su proveedor no está
disponible. La ejecución no espera una respuesta humana salvo ante una acción
no preaprobada que no tenga una alternativa segura.

## Estado de partida

Los siguientes cambios ya están en `origin/main` y no se reimplementan:

- 9.1, 9.2 y 9.3 por PR #81.
- 9.4, 9.5 y 9.8 por PR #97.
- 9.6 por PR #98.
- 9.14 y 9.15 por PR #104.
- El watchdog global y los mensajes de avance cada 30 minutos por PR #110.

PR #100 contiene el trabajo de 9.7. El PR está abierto, quedó detrás de
`main` y su CI falló en `test-tmux-activity-watch.sh`. La misma prueba imprimió
su línea final verde, pero el runner la clasificó como fallo. El cierre recupera
el trabajo útil en el mismo PR y corrige la causa reproducible. No abre un PR
duplicado para 9.7.

El plan todavía marca como pendientes tareas ya integradas. El runbook antiguo
ordena relanzarlas y todavía depende del sello por sesión que SummonAIKit retiró.
Ese runbook se reemplaza antes de ejecutar el cierre.

## Alcance requerido

### Carril D: documentación y prueba intermitente

El carril D actualiza la rama `fase9/docs` con `origin/main`, sin rebase ni
force-push. Conserva el alcance válido de PR #100. Corrige 9.13 con una prueba
focalizada que reproduce la clasificación incorrecta del runner. El PR pasa
una revisión cruzada y una revisión de CodeRabbit. Solo un bloqueante con un
comando de reproducción abre otra ronda.

### Carril I: instalación y cierre concurrente

El carril I implementa 9.10 y 9.16 en una rama nueva desde `origin/main`.
El instalador copia y verifica las herramientas de corrida, pero no carga
`ai.goncloud.corrida-latido`. El watchdog global es el único reloj que envía
progreso. La corrección de 9.16 espera de forma acotada a un lanzamiento que
mantiene el lock y termina sin abandonar la corrida abierta.

### Carril U: aceptación de usuario

El carril U implementa 9.11 y 9.12 después de integrar D. El agente `usuario`
recibe una promesa observable y una ruta de acceso. No lee el diff ni arregla
el producto. `cierre-de-fase.sh` exige evidencia `FUNCIONA` para cada promesa
observable y rechaza `NO FUNCIONA`.

I y U pueden compartir un PR solo si sus archivos no se solapan y cada tarea
conserva un commit y una prueba focalizada propios. Si se solapan, el lead abre
dos PRs y serializa el segundo sobre el primero.

### Simulacro y cierre

Después de integrar el código, el lead instala desde el SHA de `origin/main`.
El simulacro de 9.9 usa reloj inyectado para cubrir los intervalos de 10, 30 y
60 minutos en un máximo de 10 minutos de pared. El simulacro comprueba los
siete escenarios de la fila 9.9, los mensajes reales con prefijo
`[SIMULACRO]` y el avance global de 30 minutos. No activa el LaunchAgent viejo.

El lead ejecuta `bash scripts/cierre-de-fase.sh 9`. El cierre documental corrige
las filas del plan con los PR, los SHA y las salvedades reales. La fase no se
declara cerrada con un escenario `unknown` que corresponda a una tarea
requerida.

## Tareas reconciliadas

- 9.0 termina con las mediciones existentes y declara cualquier dato no
  observado. Ninguna tarea requerida depende de ese dato.
- 9.1 a 9.6, 9.8, 9.14 y 9.15 se marcan terminadas con sus merges existentes.
- 9.7, 9.9 a 9.13 y 9.16 se cierran mediante los carriles de este documento.
- 9.17 pasa al bloque de hardening posterior a A, B y C. La recuperación de un
  PID vivo colgado no bloquea el flujo normal ni el simulacro.

## Revisión, CI y límites

Cada carril ejecuta pruebas focalizadas durante el desarrollo. Cada PR ejecuta
la batería completa una vez en CI sobre su SHA final. El lead no repite esa
batería localmente ni reinicia CI sin cambiar el SHA.

La primera revisión cruzada cubre el carril completo. Una ronda posterior usa
otro revisor y solo el diff de la corrección anterior. Un hallazgo no
bloqueante se corrige en la misma ronda si ocupa una línea. En otro caso se
registra para el hardening. Si el mismo bloqueante aparece en dos rondas
consecutivas, el carril se detiene.

CodeRabbit revisa una vez cuando el PR está listo. Si no tiene cuota, el PR lo
declara y continúa. Si encuentra un bloqueante reproducible, el implementador
lo corrige, otro revisor revisa el delta y CodeRabbit revisa el nuevo push.

Una falta de cuota o un fallo de arranque cambia al siguiente trabajador de la
lista del rol. El relevo conserva el brief, la rama y el worktree. Una prueba
roja o una revisión negativa no cambia de modelo para evitar la corrección.

## Progreso y recuperación

El lead publica `runbook-progress.v1` cuando cambia el estado de un carril o de
la cola. El watchdog global emite un resumen cada 30 minutos mientras exista
trabajo activo. El lead no crea otro cron periódico para producir el mismo
mensaje.

El estado recuperable vive en GitHub, las ramas, los worktrees y el archivo de
progreso. Un lead nuevo inspecciona esos datos antes de lanzar un proceso. Si
encuentra un proceso vivo, no lanza un duplicado.

## Dependencias con otras fases

La preparación y ejecución de este cierre no dependen de Fase 14. La
implementación de Fase 14 sí depende del cierre de Fase 9 y de Fase 15. Fase 23
permanece independiente.

## Hardening posterior a A, B y C

El plan de entrega sin sello gana un Bloque D que empieza después de B y C.
Incluye A.R2 a A.R11, 9.17 y todos los hallazgos no bloqueantes que produzcan B
y C. El bloque agrupa el trabajo por repositorio y conserva pruebas, revisión y
CI independientes. Registrar un hallazgo no lo marca como realizado.

## Fuera de alcance

- Implementar Fase 14, Fase 15 o Fase 23.
- Reactivar el sello por sesión.
- Instalar `ai.goncloud.corrida-latido` junto al watchdog global.
- Crear un router nuevo de modelos dentro de SummonAIKit.
- Resolver 9.17 antes del simulacro.

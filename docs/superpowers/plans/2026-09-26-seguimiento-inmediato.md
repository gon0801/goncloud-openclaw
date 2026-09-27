# Reducir la espera entre trabajadores CLI

Estado: plan propuesto para U3a. No inicia implementación ni instala componentes.
Orden elegido por David el 2026-09-26: cerrar U3, ejecutar U3a y después U4.
[Diseño y aceptación](../specs/2026-09-26-seguimiento-inmediato-design.md).
[Ledger](../../../Plans.md), Fase 19.

## Conservar el trabajo de U3 en curso

Espera al cierre de U3 antes de medir o modificar el seguimiento. Usa su SHA
integrado y sus recibos instalados como base de 19.0. Actualiza las rutas y
contratos de este plan si U3 los cambió, sin reabrir sus tareas cerradas.

No edites el worktree de U3, sus tareas 14.x, su plan ni su runbook durante esta
planificación. No cambies sus criterios de aceptación para introducir U3a.
U4 conserva su alcance; su ejecución espera también al cierre de U3a.
La investigación documental independiente puede continuar.

Antes de ejecutar, comprueba en `origin/main` el cierre de U3 y sus evidencias.
Un marcador `cc:TODO` no describe por sí solo lo que otro agente está implementando.
Si falta el cierre, conserva U3a pendiente. Este documento no es un launcher ni
habilita `lanzar-fase.sh 19`: la integración con las herramientas de fase se
comprueba en 19.0 antes de anunciar un comando de arranque.

## 19.0. Medir el recorrido y fijar el cambio mínimo

Responsable: lead de U3a, con medición del host por ingeniería bajo el alcance
operativo autorizado para U3a. No hereda automáticamente el permiso de U3.

1. Registra el SHA instalado de U3, versiones de CLI y límites del host.
2. Identifica qué ejecutable y modo corresponden a Muse en esa instalación.
3. Comprueba la señal de fin de Muse y Claude, el destino del aviso y el dueño de la corrida.
4. Mide al menos una transición Muse → Claude y otra Claude → continuación con el seguimiento previo.
5. Registra por separado detección, transporte, espera del dueño y comienzo efectivo del siguiente trabajo.
6. Fija la conexión mínima con los contratos entregados por U3 y sus pruebas.

Guarda la matriz y los tiempos en `docs/evidence/u3a-seguimiento-inmediato/`.
Identifica cada captura de datos ficticios para no presentarla como medición viva.
Si la señal de Muse o la ruta al dueño no están disponibles, documenta la limitación.
No marques 19.0 como resuelto por observar sólo Claude.

El contrato de implementación define identidad de ejecución y turno, persistencia
del aviso pendiente, confirmación de tratamiento y reserva del siguiente paso.
Reutiliza los campos y locks existentes donde correspondan. Documenta los campos
nuevos necesarios antes de modificar los validadores. La ruta elegida no incorpora
transcripts ni contenido libre de la CLI en los avisos.

Comprueba también que el consumidor de eventos y el tick compartan un solo dueño.
El lock de escritura del registro no demuestra exclusión durante un lanzamiento.
Si el recorrido necesita un cambio mayor del director, presenta el faltante antes
de implementar. No agregues un servicio o supervisor para resolverlo.

La base consultada usa pre-commit para higiene y `scripts/run-checks.sh` para la
batería de contratos, Node y sintaxis. No se comprobó un formatter específico para
los archivos shell y Python candidatos. Antes del código, registra los comandos
de lint y formato que entregue U3; si faltan, define una comprobación focalizada
para los archivos modificados. No reformatees el repositorio.

DoD: recibo de U3, identidad de Muse, señales y destinatario comprobados; dos
transiciones de base con tiempos; contrato mínimo y comandos de validación
registrados. El alcance de prueba y sus rutas están definidos antes de ejecutarlo.

## 19.1. Conectar el aviso con el dueño de la corrida

Responsable: un implementador en una rama creada desde `origin/main` después de
19.0. El reviewer no comparte autoría. U3a conserva un único escritor de los
archivos de seguimiento hasta integrar el bloque.

Reutiliza el hook de Claude, la señal de Muse comprobada en 19.0 y el vigilante.
Guarda el pendiente antes de enviar. Obtén el destinatario y la identidad de
intento del registro. Despierta al dueño existente y deja que compruebe la entrega.
No ejecutes `corrida.sh reconciliar` desde cada hook en paralelo.

El dueño registra una reserva antes de lanzar el siguiente trabajador. Revalida
corrida abierta, intento vigente, evidencia y permisos. Un aviso repetido y un
tick simultáneo deben producir el mismo resultado. Conserva el pendiente hasta
que el dueño registre su tratamiento. Recupera envíos fallidos con el vigilante
existente, sin un nuevo cron ni un segundo servicio.

Amplía las pruebas focalizadas sobre las fronteras modificadas. Incluye:

- Aviso duplicado, aviso tardío, nombre de sesión reutilizado y sesión personal.
- Aviso y tick simultáneos, dueño ocupado y cierre concurrente de la corrida.
- Caída antes de enviar, envío aceptado sin respuesta y reinicio antes o después de lanzar.
- Fin de turno con pregunta, fallo, entrega incompleta y tarea final sin sucesor.
- Metadatos inválidos o texto malicioso que intentan cambiar destino o autoridad.
- Muse y Claude por la ruta real de sus adaptadores, con dobles locales en CI.
- Activación y reversa del cambio, manteniendo el seguimiento anterior y un solo vigilante.

Para cada bug, conserva una prueba que falle sin su arreglo. Durante el desarrollo
corre sólo las pruebas focalizadas. Antes de abrir el PR, ejecuta los hooks y
comprueba que `git log origin/main..HEAD` contenga sólo commits del bloque.
La batería completa corre una vez en CI del PR sobre el head final. No la repitas
localmente si CI ya la cubrió.

DoD: contratos y casos anteriores aprobados, revisión sin bloqueantes, CI completa
del head final y paquete reversible preparado por el instalador existente. Un
aviso aceptado por el gateway no satisface el criterio de continuación.

## 19.2. Medir el resultado y cerrar U3a

Responsable: ingeniería instala en el host autorizado; el lead conserva los
recibos y el reviewer comprueba la evidencia. David valida el resultado observable.

1. Instala el SHA aprobado con la ruta existente y verifica los archivos leídos de vuelta.
2. Ejecuta veinte transiciones reales con las condiciones del diseño declaradas antes de medir.
3. Comprueba una pérdida de aviso, una caída recuperable y la reversa del seguimiento.
4. Publica todas las muestras y el resultado de cada criterio en la evidencia de U3a.
5. Cierra U3a en un único PR documental cuando todos los criterios estén acreditados.

Registra diez transiciones Muse → Claude y diez Claude → siguiente trabajador.
El cronómetro termina cuando la siguiente CLI empieza trabajo verificable. Para
cada transición normal exige menos de 30 segundos; publica mediana, máximo y
cantidad que cumplen. Incluye fallos y esperas del dueño, sin borrar muestras.
CI, permisos, cuota o capacidad pendientes se identifican como espera externa.
Prueba esos casos aparte de las veinte transiciones normales.

Exige recuperación en 60 segundos como máximo cuando el gateway y el dueño estén
disponibles; tras una caída, mide desde su recuperación. No atribuyas un éxito a
una hora de otro host sin comprobar la diferencia entre relojes. Usa el mismo
reloj monótono para fin e inicio de los trabajadores de cada transición.

Si un criterio falla, conserva U3a abierto y reporta la causa. No reduzcas los
umbrales para declarar cierre. La observación de una CLI no acredita otra.
No actives Hermes, nuevas pantallas ni autonomía de metas compuestas en este bloque.

DoD: veinte transiciones normales bajo 30 segundos, casos de recuperación dentro
del límite, ninguna continuación duplicada, SHA instalado verificado y reversa
probada. El recibo permite reproducir la medición sin secretos. U4 puede comenzar
tras el cierre de U3a.

## Archivos y responsabilidades

Las rutas se reconcilian en 19.0 con el resultado de U3. Esta tabla limita el
alcance; no obliga a modificar todos los archivos.

| Trabajo | Rutas previstas |
|---|---|
| Evidencia y contratos mínimos | `docs/evidence/u3a-seguimiento-inmediato/`, `docs/spec/corrida.v2.md`, este diseño y plan. |
| Señal y envío | `scripts/mac/claude-stop-openclaw-event.sh`, `scripts/mac/tmux-activity-watch.sh`, `scripts/mac/corrida/adaptador.sh`. La integración de Muse se ubica después de identificarla en 19.0. |
| Tratamiento por el dueño | `scripts/mac/corrida/`, `scripts/mac/corrida_worker/`, `scripts/mac/corrida-worker.py`, `scripts/mac/corrida.sh` y la skill de dirección entregada por 14.6. |
| Instalación y pruebas | `scripts/mac/instalar-mac.sh`, `scripts/tests/test-tmux-activity-watch.sh`, `scripts/tests/test-corrida-reconcile.sh`, `scripts/tests/test-instalar-mac.sh` y pruebas focalizadas nuevas si corresponde. |

Los cambios de contrato se limitan al aviso y su tratamiento. Los esquemas viejos
siguen siendo legibles. No se modifica el motor de elección de modelos, el panel,
las compuertas de merge ni la política de Telegram para reducir la latencia.

## Alcance de las autorizaciones

| Operación | Alcance | Estado actual |
|---|---|---|
| Redactar el plan, crear rama, ejecutar checks y publicar PR | Documentos de U3a y dependencia de U4. | Autorizado por este pedido. |
| Medir en 19.0 | Corrida de prueba con identidad propia, repos temporales, Muse y Claude instalados; avisos internos al dueño por conexión existente. Sin cambios a repos productivos ni mensajes externos. | Requiere pedido de ejecución U3a después del cierre de U3. |
| Implementar 19.1 | Rutas de la tabla, pruebas con dobles locales y PRs del bloque. | Requiere pedido de ejecución U3a. |
| Instalar y medir 19.2 | Host y ventana identificados, tareas de prueba acotadas, instalación reversible por la ruta existente. | Requiere autorización operativa de U3a. |
| Merge, despliegue fuera del host de prueba y mensajes externos | Fuera de la planificación. | No concedido por este documento. |

La autorización de una prueba incluye crear su estado temporal y enviar sus
avisos internos. No permite leer secretos, cambiar modelos del gateway, publicar
un webhook, reiniciar el host o borrar datos existentes. Reutiliza referencias de
autenticación ya configuradas. Una prueba que necesita más alcance queda pendiente
hasta tenerlo definido.

## Evidencia y revisión del plan

`Spec delta`: el contrato de producto registra U3a como mejora posterior a U3.
El diseño fija comportamiento y límites; `Plans.md` conserva estado y dependencias.
Los documentos de U4 reflejan que su ejecución espera a U3a. El plan y el runbook
de U3 no cambian.

`team_validation_mode: subagent`. Tres lecturas independientes cubrieron
arquitectura, producto y QA, y seguridad. Las decisiones incorporadas son medir
antes de atribuir causa, verificar Muse, dirigir el aviso al dueño correcto,
conservar un consumidor y probar el comienzo del siguiente trabajo.

Memoria consultada: `.saikit/decisiones/tmux-activity-watch.tsv`, contratos
`corrida.v2` y `seguimiento.v2`, y diseño de Fase 14. Ya existe una decisión de
avisar por eventos; U3a completa y mide esa ruta. No se consultó memoria externa.

Agrupa los hallazgos de revisión. Sólo un bloqueante reproducible abre otra ronda,
limitada al diff corregido y con otro revisor. Si el mismo bloqueante vuelve en
dos rondas seguidas, detén el bloque para decisión del operador. Registra los
no bloqueantes aceptados que queden pendientes en el ledger y en el PR.

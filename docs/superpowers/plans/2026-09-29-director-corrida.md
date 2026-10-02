# Construir el director de corrida.sh

Estado: plan propuesto para U3b. No inicia implementación ni instala nada.
[Diseño](../specs/2026-09-29-director-corrida-design.md).
[Tabla de transiciones, tipos y estado](../specs/2026-09-29-director-corrida-transiciones.md).
[Ledger](../../../Plans.md), Fase 20.

## Antes de empezar

U3b construye sobre los avisos durables de U3a (`scripts/mac/corrida/avisos.sh`,
fila 19.1). Antes de cambiar shell, comprueba en `origin/main` que 19.1 está
mergeado y que U3a cerró con 19.2. 20.0 y 20.1 no tocan shell y pueden empezar con
19.1 mergeado. El resto espera el cierre de U3a.

Antes de integrar 20.1 con `reconcile.py` o cambiar las entradas de 20.4 a 20.10,
usa las interfaces de T0 y los contratos de [encargos durables](2026-09-30-encargos-agentes.md)
que consume la entrada concreta. Comprueba sus pruebas focalizadas y registra el
par de SHA de G y R en el recibo de U3b. Para habilitar esa entrada como gestionada,
comprueba además su cobertura en `docs/evidence/agent-work/coverage.json`. No
exijas cerrar todas las tareas T0–T10 ni certificar otras rutas, CLI o Hermes para
desarrollar U3b. Una entrada sin cobertura conserva la ruta anterior y no acredita
continuación nativa. Rebasea cada PR de U3b sobre el último commit integrado de G
antes de editar archivos comunes.

Si U3a cambió interfaces que este plan nombra (`avisos_despertar_dueno`,
`avisos atender`, `latido_de`), reconcilia las rutas del plan en 20.1 antes de
tocar código. No reabras filas de U3a.

Reglas que aplican a todas las tareas:

- Cada tarea es un PR desde `origin/main` con un solo escritor por worktree.
- La prueba que abre la tarea se ve en rojo antes del arreglo. Guarda la salida roja
  en el LISTO del implementador.
- Durante el desarrollo corre solo las pruebas focalizadas. La batería completa
  corre una vez en CI sobre el head final.
- Las pruebas nunca tocan `~/bin/corrida.sh`, el `~/.local/state` real, el
  OpenClaw real ni el tmux de David. Usa sockets `tmux -L` y dobles de `gh`,
  `openclaw` y `tmux`.
- Bash 3.2 en los scripts de corrida. La lógica de decisión va en Python, en
  `scripts/mac/corrida_worker/`.
- Corre los hooks de pre-commit antes de cada commit. No uses `--no-verify`.
- `reconcile()` sigue siendo el único decisor de ingeniería. La tarea nativa
  conserva encargo, resultado y consumo; `task_handoffs.py` traduce el resultado
  a un efecto del director. No abras otra bandeja ni un segundo decisor.
- Para cada entrada gestionada, `submit`, `report` y `resolve` son la ruta de
  entrega y continuación. Stop, quietud y el latido solo observan. No crean
  sesiones supervisoras, empujones por silencio ni turnos de modelo.
- Aplica la regla vigente de quality-kit: un bloqueante repetido en dos rondas
  seguidas detiene el bloque y exige decisión del operador. Una revisión posterior
  examina solo el diff de la corrección y usa otro revisor. No heredes la excepción
  de cinco rondas del diseño original de U3b.

## 20.0. Medir el despertar de claw y la base de un turno nuevo

Objetivo: elegir el verbo que despierta a `agent:main:dir-<id>` y conocer el costo
de las rutas que el director no controla. No hay código.

1. Alinea el CLI `openclaw` de la Mac con la versión del gateway.
2. Manda el mismo texto de 12 líneas por `openclaw system event` y por
   `openclaw agent --message` a dos claves nuevas: `agent:main:dir-medicion-a` y
   `agent:main:dir-medicion-b`.
3. Repite el envío con el gateway ocioso y con un turno largo en curso en `main`.
4. Registra por envío: si se creó la sesión, `totalTokens` del turno, si llegó con
   carga, si se mezcló con otro run, latencia y si algo salió a Telegram con
   `NO_REPLY`.
5. Comprueba si una clave nueva nace sin el historial de `main`.
6. Mide `totalTokens` del primer turno de `agent:main:main` después de `/new`.
7. Comprueba si `sessions cleanup delete` desde la Mac borra una clave del gateway
   o solo actúa en local.

Regla de decisión: gana el verbo que llega en los dos casos con menos tokens. Si
ninguno llega con carga, usa `agent --message` con el reintento por `intent.notify`
pendiente.

Archivos: `docs/evidence/u3b-director/despertar-2026-MM-DD.md`.

Prueba en rojo: no aplica. Es una medición viva.

Verificación: la evidencia trae una fila por envío con los siete datos y el verbo
elegido. Borra las dos claves de medición al terminar.

Depende de: 19.1 mergeado.

## 20.1. Escribir `director.py` puro con su prueba de mesa

Objetivo: `fase_de_log`, `phase_of`, `punto_vigente`, `claves_que_persisten`,
`next_effect`, `TABLA`, `DECISIONES` y `PALABRAS_DAVID` según la
[referencia](../specs/2026-09-29-director-corrida-transiciones.md). Integra
`task_handoffs.py` y conserva los eventos `intent.task_handling` y
`observed.task_handled` existentes. Un bloqueante repetido propone la excepción
`BLOQUEANTE_REPETIDO` antes de otro relevo o revisión. No toca shell.

Archivos:

- Create: `scripts/mac/corrida_worker/director.py`
- Create: `scripts/mac/corrida_worker/test_director.py`
- Create: `scripts/tests/test-corrida-director.sh`
- Modify: `scripts/mac/corrida_worker/reconcile.py` (llama a `next_effect` después de `reconcile_lane`)
- Modify: `scripts/mac/corrida_worker/state.py` (catálogo de eventos y proyecciones)

Prueba en rojo primero:

- Una fila de cada tabla de transiciones es un caso: registro, `delivery_mode`,
  observaciones y efecto esperado literal. Un archivo LISTO o un panel quieto
  no hacen casar una fila `legacy` cuando el bloque es `managed`.
- La tupla `TABLA` y las tablas de la referencia coinciden fila por fila.
- Replay de U3a B1 (19.0: r1 `cebb151`, cambios, r2 `ae72063`, aprobado, PR #222,
  merge, ledger #223) como secuencia de registro y observaciones. Los efectos salen
  en el orden del loop que se hizo a mano.
- Dos veredictos consecutivos con el mismo bloqueante reproducible proponen
  `BLOQUEANTE_REPETIDO` y no crean otra ronda ni otro encargo. Un hallazgo sin
  reproducción queda como no bloqueante y no abre otra ronda.
- Un resultado nativo con `Changes` prepara una sola corrección mediante
  `task_handoffs.py`; un ACK perdido de `resolve` recupera el mismo recibo. El
  registro de corrida no crea otra bandera de consumo.
- Mutación: sin el chequeo de `intent` pendiente, `next_effect` propone el mismo
  efecto dos veces y la prueba falla.

Verificación:

```bash
bash scripts/tests/test-corrida-director.sh
bash scripts/tests/test-agent-work-integration.sh director_handling
```

Depende de: 19.1 mergeado. Puede ir en paralelo con 20.0 y 20.2.

## 20.2. Dejar el merge libre

Objetivo: `ci-y-revisor` como único modo de la compuerta de merge. Borrar la tabla
de preaprobaciones y la autoridad de merge en el mismo PR, porque borrar solo la
tabla hace que `compuerta.sh` niegue todo merge con `modo-recibo-invalido`.

Archivos:

- Delete: `scripts/mac/corrida/autoridad-merge.sh`
- Delete: `scripts/mac/corrida/preaprobaciones.v1.json`
- Delete: `scripts/tests/test-autonomous-merge-authority.sh`
- Modify: `scripts/mac/corrida/compuerta.sh` (sin `receipt-mode`, `tabla` ni `compuerta_kit_merge`)
- Modify: `scripts/mac/corrida_worker/gates.py` (sin recibo del kit; el bot exige su check-run en el head)
- Modify: `scripts/mac/corrida-worker.py` (sin `receipt-mode` ni `--receipt*` ni `--preaprobaciones`)
- Modify: `scripts/mac/instalar-mac.sh` (sin la verificación y la copia de la tabla; retira las copias instaladas en `~/bin/corrida/`)
- Modify: `scripts/tests/test-corrida-gates.sh`, `scripts/tests/test-instalar-mac.sh`, `scripts/tests/test-merge-allowlist-cierre-pr.sh`
- Check: `scripts/tests/test-simulacro-fase9.sh` por referencias a preaprobaciones de merge

Prueba en rojo primero:

- Un comentario de `github-actions` sin check-run `review` concluido en el head da
  `deny`. Hoy da `allow`.
- Sin tabla de preaprobaciones, un merge con CI verde y bot limpio en el head da
  `allow`. Hoy da `deny` con `modo-recibo-invalido`.

Verificación:

```bash
bash scripts/tests/test-corrida-gates.sh
bash scripts/tests/test-instalar-mac.sh
bash scripts/tests/test-merge-allowlist-cierre-pr.sh
```

Depende de: U3a cerrada.

## 20.3. Contar el cupo en toda la Mac

Objetivo: `preparar-carril --par` reserva implementador y revisor juntos bajo
`cupo_lock`, y el conteo cubre todos los registros abiertos.

Archivos:

- Modify: `scripts/mac/corrida/lib.sh` (`cupo_lock_tomar`, `cupo_lock_soltar`, `registro_contar_reservas_global`)
- Modify: `scripts/mac/corrida/preparar-carril.sh` (`--par`, `--at <sha>`, `.corrida/` en `info/exclude`)
- Create: `scripts/tests/test-corrida-preparar-carril.sh`

Prueba en rojo primero: dos corridas con 3 reservas entre ambas preparan un par a
la vez. Exactamente una pasa. Hoy pasan las dos, porque el tope se cuenta por
registro.

Verificación:

```bash
bash scripts/tests/test-corrida-preparar-carril.sh
bash scripts/tests/test-corrida-worktrees.sh
```

Depende de: U3a cerrada.

## 20.4. Registrar sesiones y serializar las teclas

Objetivo: `adaptador start` marca `OPENCLAW_WATCH` y `OPENCLAW_WATCH_RUN` y
registra la sesión en `sesiones[]`. `deliver` teclea una línea. `teclas_lock`
protege el panel en el adaptador, en `responder.sh` y en los avisos con lead. El
revisor arranca con permiso de escritura en su worktree.

Archivos:

- Modify: `scripts/mac/corrida/adaptador.sh`, `scripts/mac/corrida/responder.sh`, `scripts/mac/corrida/lib.sh`
- Modify: `scripts/mac/corrida/avisos.sh` (camino con lead bajo `teclas_lock`)
- Modify: `scripts/mac/corrida/preflight.sh` (mide la escritura en `.corrida/` por CLI)
- Modify: `scripts/tests/test-corrida-marcas.sh`, `scripts/tests/test-corrida-responder.sh`, `scripts/tests/test-native-harness-adapters.sh`

Prueba en rojo primero:

- Una sesión que lanzó `adaptador start` tiene `OPENCLAW_WATCH=1` y aparece en
  `sesiones[]` con `dueno: director`. Hoy no.
- `deliver` manda una sola línea que nombra el archivo, nunca su contenido.
- Con `teclas_lock` tomado por `deliver`, `responder` no teclea y sale con 1.

Verificación:

```bash
bash scripts/tests/test-corrida-marcas.sh
bash scripts/tests/test-corrida-responder.sh
bash scripts/tests/test-native-harness-adapters.sh
```

Además, `corrida.sh preflight` en la Mac reporta por cada CLI del registro si
escribe `.corrida/X` sin diálogo en un worktree detached. Registra el resultado en
`docs/evidence/u3b-director/`.

Depende de: 20.3.

## 20.5. Observar y correr en modo sombra

Objetivo: `observe.py` reemplaza el heredoc de `reconciliar_observar`.
`reconciliar.sh` toma `director.lock` con `director.otra-vez`. Con
`director.modo=sombra` imprime `SOMBRA <op> <lane> <args>` y no ejecuta.

Archivos:

- Create: `scripts/mac/corrida_worker/observe.py`, `scripts/mac/corrida_worker/protocolo.py`
- Create: `scripts/tests/test-corrida-observe.sh`
- Modify: `scripts/mac/corrida/reconciliar.sh`, `scripts/mac/corrida-worker.py` (subcomandos `observe` y `fase`)
- Modify: `scripts/tests/test-corrida-nucleo.sh`

Prueba en rojo primero:

- `sondas(implementando)` no invoca `gh`. El doble de `gh` falla si lo llaman.
- LISTO sin SHA, con SHA ajeno o de otra ronda no es válido.
- VEREDICTO con `-rev` sucio o fuera del head tiene `arbol_confiable` falso.
- Un bloqueante sin `archivo:línea` y comando pasa a residual.
- Con `director.lock` ocupado, un segundo `reconciliar` imprime `OCUPADO`, toca
  `director.otra-vez` y el dueño hace una pasada más.

Verificación:

```bash
bash scripts/tests/test-corrida-observe.sh
bash scripts/tests/test-corrida-nucleo.sh
bash scripts/tests/test-corrida-reconcile.sh
```

Después, corre una corrida real en sombra junto a un loop manual y compara efecto
por efecto. Registra la comparación en `docs/evidence/u3b-director/`.

Depende de: 20.1 y 20.4.

## 20.6. Llevar un bloque vivo hasta Aprobado

Objetivo: el director ejecuta `submit_managed_task`, `record_task_handling` y
`resolve_task_handling` para entradas gestionadas. Conserva `write_encargo`,
`write_brief`, `deliver`, `nudge`, `move_review_tree`, `discard_verdict`,
`relevar_impl` y `relevar_rev` solo para la ruta CLI anterior. El latido llama a
`reconciliar` y deja de despertar a `sim9`.

En una entrada gestionada, el director solicita el trabajo mediante la tarea
nativa y consume el resultado con `task_handoffs.py`. `deliver` y `nudge` quedan
solo para entradas CLI anteriores aún no adoptadas. La observación de una pantalla
quieta no acredita LISTO, VEREDICTO ni justifica despertar un modelo.

Archivos:

- Create: `scripts/mac/corrida/plantillas/encargo.md`, `scripts/mac/corrida/plantillas/brief-revision.md`
- Modify: `scripts/mac/corrida/reconciliar.sh` (ops de entrega y relevo)
- Modify: `scripts/mac/corrida/avisos.sh` (`avisos_despertar_dueno` lanza `atender` con `director.activo`)
- Modify: `scripts/mac/corrida/latido.sh` (llama a `reconciliar`; sin `system event` a `sim9` con director)
- Modify: `scripts/mac/corrida_worker/selector.py` (`exclude_authors` también en `role=write`)
- Modify: `scripts/tests/test-corrida-avisos.sh`, `scripts/tests/test-corrida-latido.sh`, `scripts/tests/test-corrida-reconcile.sh`

Prueba en rojo primero:

- Corrida con `director.activo` y sin lead: `emitir` lanza `atender`, no manda
  teclas, el pendiente pasa a tratados y `reconciliar` corre una vez. El doble de
  tmux falla si recibe `send-keys`.
- Con `director.activo`, el latido no manda `system event` a `agent:main:sim9-<id>`
  y sí lanza `reconciliar`.
- Un relevo permitido excluye al implementador saliente y el selector no lo elige.
- Un bloqueante repetido en dos rondas detiene el bloque antes de `relevar_impl`,
  incluso si la entrada usa la ruta CLI anterior.
- Con `delivery_mode=managed`, la tabla no llama a `launch_worker`, `deliver` ni
  `nudge`. Un informe válido produce una intención de manejo; perder el ACK de
  `resolve` conserva un solo hijo de corrección y el mismo recibo. El caso cruza
  G y R con `AGENT_WORK_RUNTIME_SOURCE` fijado; una prueba omitida no acredita
  esta ruta.
- Dos filas gestionadas comparten raíz y presupuesto: `Approved` de la primera
  crea la segunda mediante `Continue` en el mismo `resolve`. Si la base nativa
  aún solo devuelve `Complete`, no habilites bloques gestionados de varias filas.

Verificación:

```bash
bash scripts/tests/test-corrida-avisos.sh
bash scripts/tests/test-corrida-latido.sh
bash scripts/tests/test-corrida-reconcile.sh
bash scripts/tests/test-agent-work-integration.sh director_handling
```

Prueba real: un pedido chico en openclaw en modo vivo hasta Aprobado. Push, PR y
merge se hacen a mano en esta tarea.

Depende de: 20.2 y 20.5.

## 20.7. Publicar, mergear y desplegar

Objetivo: el director ejecuta `push`, `open_pr` en draft, `rerun_ci`, las filas
`ci-rN`, `revisor-rN` y `rebase-rN`, `mark_ready`, `gate_merge`, `merge` con
`merge_method`, los pasos de deploy, los hooks, el PR de ledger y `cierre_fase`.

Archivos:

- Create: `scripts/mac/corrida/repos.v1.json`, `scripts/mac/corrida_worker/repos.py`
- Create: `scripts/mac/corrida/plantillas/pr-body.md`
- Create: `scripts/tests/test-corrida-publicar.sh`
- Modify: `scripts/mac/corrida/reconciliar.sh`, `scripts/mac/instalar-mac.sh` (instala `repos.v1.json` y `plantillas/`)
- Modify: `scripts/tests/test-u1-un-solo-watchdog.sh` (admite `scripts/mac/corrida/repos.v1.json`, que nombra el directorio del sync seguro en un glob del paso `gateway`)

Prueba en rojo primero:

- `repos.py` rechaza una clave desconocida, un alias duplicado, un comando con
  metacaracteres y un paso sin operador y sin comando.
- `merge` corre `gh pr merge --squash --match-head-commit <head>` con el doble de
  `gh` y escribe `observed.merge.done` solo después de releer `mergedAt`.
- Un paso de deploy con `necesita_operador` abre `NECESITA_DAVID` y el paso
  siguiente no corre.
- Un diff que solo toca `docs/` no aplica el paso `mac`.

Verificación:

```bash
bash scripts/tests/test-corrida-publicar.sh
bash scripts/tests/test-instalar-mac.sh
```

Depende de: 20.6.

## 20.8. Excepciones, decisiones y respuestas de David

Objetivo: `raise_excepcion`, `notify_excepcion`, `decidir` y `contestar`; re-aviso
cada 60 minutos como mucho para una excepción que requiere al operador. En la
ruta gestionada, entrega la excepción al solicitante autenticado y conserva su
sesión. La sesión corta `dir-<id>` solo sirve a corridas anteriores fuera del
perímetro gestionado; `cerrar` no borra una sesión adoptada ni un hijo activo.

Archivos:

- Create: `scripts/mac/corrida/decidir.sh`, `scripts/mac/corrida/contestar.sh`
- Create: `scripts/tests/test-corrida-excepciones.sh`
- Modify: `scripts/mac/corrida.sh` (despacha `decidir` y `contestar`)
- Modify: `scripts/mac/corrida/reconciliar.sh`, `scripts/mac/corrida/cerrar.sh`, `scripts/mac/corrida/estado.sh`
- Modify: las instrucciones de `agents/main/` con la regla de una línea para las palabras de David

Prueba en rojo primero:

- Dos pasadas sobre el mismo hecho escriben un solo archivo de excepción.
- Una decisión fuera de `DECISIONES` sale con código 2.
- No hay re-aviso antes de 60 minutos.
- `contestar` con 0, 1 y 2 excepciones abiertas para David: con 1 la resuelve, con
  0 o 2 lista y sale con código 3.
- En una entrada gestionada, una excepción llega al solicitante registrado sin
  crear `agent:main:dir-<id>` ni una sesión de vigilancia.
- `BLOQUEANTE_REPETIDO` detiene el bloque y solo acepta una decisión explícita del
  operador; un re-aviso no inicia otra revisión.

Verificación:

```bash
bash scripts/tests/test-corrida-excepciones.sh
bash scripts/tests/test-corrida-estado.sh
```

Depende de: 20.0 (verbo elegido) y 20.7.

## 20.9. Entrada de claw

Objetivo: `plan`, `pedido` y `abrir --plan`; tablero con una parte por fila; la
skill `native-harness-orchestration` reescrita sin la regla "Main nunca mergea ni
despliega" y sin la secuencia manual de compuertas.

Archivos:

- Create: `scripts/mac/corrida_worker/plan.py`, `scripts/mac/corrida/plan.sh`, `scripts/mac/corrida/pedido.sh`
- Create: `scripts/mac/corrida/plantillas/pedido-grande.md`
- Create: `scripts/tests/test-corrida-plan.sh`
- Modify: `scripts/mac/corrida.sh`, `scripts/mac/corrida/abrir.sh`
- Modify: `agents/main/agent/workshop-skills/native-harness-orchestration/SKILL.md`
- Modify: `scripts/tests/test-native-harness-orchestration-skill.sh`

Prueba en rojo primero:

- `pedido` con 2 archivos, sin datos, sin secretos y sin repo nuevo es chico: un
  bloque y una fila.
- `pedido` grande sin respuestas sale con código 3 y la lista de lo que falta.
- `pedido` con `--repo-nuevo si` es grande y el plan abre `NECESITA_DAVID` antes del
  bloque de planificación.
- `plan` lee filas de `Plans.md` y las agrupa según `--bloques`.
- La skill ya no contiene "Main nunca mergea".

Verificación:

```bash
bash scripts/tests/test-corrida-plan.sh
bash scripts/tests/test-native-harness-orchestration-skill.sh
```

Depende de: 20.8.

## 20.10. Primera corrida completa y retiro del vigía con modelo

Objetivo: probar el director de punta a punta y retirar el vigía con modelo de U3a.

1. Corre un pedido chico en openclaw de principio a fin: abrir, implementar,
   revisar, PR, CI, bot, merge, deploy `mac`, cerrar.
2. Corre una fila de `Plans.md` con PR de ledger y `cierre-de-fase`.
3. Corre un pedido grande con su `CONFIRMAR_PLAN`.
4. Cuenta los turnos de modelo de claw y sus `totalTokens` en cada corrida.
5. Inventaría qué entradas despierta cada cron vigía con modelo de U3a. Para
   cada entrada adoptada, registra su ID de cron, configuración y generación;
   suspende su emisión anterior, drena turnos y resultados en vuelo y comprueba
   un solo emisor, recibos durables y cero peticiones posteriores del cron para
   esa entrada. Si el cron es compartido con entradas no adoptadas, mantenlo
   activo para ellas mediante un filtro probado; si no puede separarlas, no lo
   retires ni declares completado 20.10. Borra el cron y confirma su ausencia en
   `openclaw cron list` solo cuando todas las entradas que atendía estén migradas
   y drenadas. Conserva los cron de negocio.

Antes de la primera transferencia viva, ejecuta
`bash scripts/tests/test-agent-work-cutover.sh` sobre el par de artefactos elegido.
La prueba cubre la generación, el cron suspendido, los turnos antiguos en vuelo,
la preservación de resultados pendientes y el bloqueo ante incertidumbre. La
autorización y el recibo vivo de T12
son necesarios para adoptar la entrada y retirar su cron, pero no para desarrollar
el director en pruebas aisladas.

Añade a `test-corrida-latido.sh` el caso de dos entradas atendidas por un cron:
una gestionada y otra anterior. La primera no recibe despertares antiguos, la
segunda conserva su servicio y el borrado del cron se rechaza. Después de migrar
y drenar ambas, el mismo caso permite retirarlo. Exige ese verde antes del paso 5.

Archivos: `docs/evidence/u3b-director/primera-corrida-2026-MM-DD.md` y
`docs/evidence/usuario-20-2026-MM-DD.md` con el FUNCIONA de David.

Prueba en rojo: no aplica. Es una medición viva.

Verificación: `bash scripts/cierre-de-fase.sh 20` en VERDE salvo esta fila y 20.11.
La evidencia trae, por corrida, los efectos del registro, las excepciones, las
respuestas de David y los tokens de claw.

Depende de: 20.9.

## 20.11. Script de deploy de Orbit

Objetivo: que el deploy de Orbit deje de pedir a David. El propio director corre
este trabajo como un pedido chico en `gon0801/goncloud-Orbit`.

Archivos:

- En Orbit, Create: `scripts/deploy-goncloud.sh` (la receta de `docs/DEPLOY.md`: `git archive`, copia a `/mnt/data/appdata/orbit/app`, `docker compose up -d --no-deps --build app`, `curl /health`)
- En openclaw, Modify: `scripts/mac/corrida/repos.v1.json` (`comando` del paso `goncloud` y `necesita_operador=false`)

Prueba en rojo primero: en Orbit, una prueba del script con dobles de `ssh` y
`docker` que exige el orden de los pasos y falla si `/health` no responde
`"status":"ok"`.

Verificación: un pedido chico en Orbit mergea y despliega sin `NECESITA_DAVID`, y
`ssh goncloud curl -sS http://127.0.0.1:8010/health` responde `"status":"ok"`.

Depende de: 20.10.

## Archivos y responsabilidades

Esta tabla limita el alcance. No obliga a tocar todos los archivos.

| Trabajo | Rutas |
|---|---|
| Decisión pura | `scripts/mac/corrida_worker/{director,plan,protocolo,repos}.py`, `reconcile.py`, `state.py` |
| Observación | `scripts/mac/corrida_worker/observe.py`, `scripts/mac/corrida/reconciliar.sh` |
| Compuertas y merge | `scripts/mac/corrida/compuerta.sh`, `scripts/mac/corrida_worker/gates.py`, `scripts/mac/corrida-worker.py` |
| Sesiones, teclas y cupo | `scripts/mac/corrida/{adaptador,responder,lib,preparar-carril,avisos,latido}.sh`, `scripts/mac/corrida_worker/selector.py` |
| Entrada de claw | `scripts/mac/corrida.sh`, `scripts/mac/corrida/{abrir,plan,pedido,decidir,contestar,cerrar,estado}.sh`, skill `native-harness-orchestration` |
| Datos | `scripts/mac/corrida/repos.v1.json`, `scripts/mac/corrida/plantillas/` |
| Instalación | `scripts/mac/instalar-mac.sh` |
| Evidencia | `docs/evidence/u3b-director/`, `docs/evidence/usuario-20-*.md` |

No cambian `scripts/mac/tmux-activity-watch.sh`, `scripts/mac/tablero-trabajo.sh`,
`scripts/mac/corrida/seleccionar.sh` ni `tablero-runbook/`.

`reconcile.py`, `state.py`, `reconciliar.sh`, `adaptador.sh`, `avisos.sh` e
`instalar-mac.sh` también reciben cambios del plan de encargos durables. Integra
los commits de ese plan antes de abrir el PR correspondiente de U3b. Usa un solo
escritor por archivo y corre las pruebas focalizadas de ambos planes sobre el
commit combinado. El hecho de que U3b no edite `tmux-activity-watch.sh` no
revierte la migración de T9.

## Alcance de las autorizaciones

| Operación | Alcance | Estado actual |
|---|---|---|
| Redactar diseño, referencia y plan, crear rama, correr checks y abrir PR | Estos tres documentos y la Fase 20 en `Plans.md`. | Autorizado por este pedido. |
| Medir en 20.0 | Dos claves `agent:main:dir-medicion-*` en el gateway y un turno tras `/new`. Sin mensajes a Telegram fuera de la medición. | Requiere pedido de ejecución de U3b. |
| Implementar 20.1 a 20.9 | Rutas de la tabla, pruebas con dobles y un PR por tarea. | Requiere pedido de ejecución de U3b. |
| Mergear PRs de U3b | Merge libre con CI verde en el head y revisor sin bloqueantes, con `--match-head-commit`. | Autorizado por David el 2026-09-29 para las corridas del director. |
| Desplegar en la Mac | `scripts/mac/instalar-mac.sh` desde un checkout igual a `origin/main`. | Parte del ciclo del director una vez mergeado 20.7. |
| Publicar al gateway | Sync seguro en la PC. | Lo hace David. El director solo pregunta. |
| Borrar el cron vigía con modelo de U3a | Todas las entradas que sirve deben estar migradas y drenadas; una entrada no adoptada conserva su ruta anterior. | Autorizado por David al cerrar 20.10 y cumplir el candado de T11–T12. |
| Deploy de Orbit en goncloud | `scripts/deploy-goncloud.sh`. | Pregunta a David hasta cerrar 20.11. |

## Revisión

Cada PR tiene revisión cruzada de un harness distinto al del implementador. Agrupa
los hallazgos y corrígelos en una sola ronda. Solo un bloqueante con el comando que
lo reproduce abre otra ronda. Los no bloqueantes van a una fila del plan y se
nombran en el PR.

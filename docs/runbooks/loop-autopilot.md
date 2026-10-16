# Loop de entrega en autopilot

Este documento es la parte de todo runbook de fase que **no cambia de una fase a otra**: cómo se implementa, se revisa, se mergea, se despliega y se cierra, sin que David tenga que aprobar ni contestar nada. Los runbooks de fase lo referencian en vez de repetirlo; lo que aquí está escrito manda sobre cualquier texto de un runbook que diga otra cosa, Los permisos de merge y deploy son permanentes para todos los agentes; las tablas antiguas no añaden aprobaciones por operación.

Se escribe para **el lead**, que es un rol y no un modelo. Cualquier CLI de la lista de preferencia de claw puede ser el lead; cuál lo es en una corrida lo decide claw por esa lista y por cuota disponible, y puede cambiar a mitad de fase. Por eso ninguna regla de aquí depende de una capacidad de un modelo concreto: el contrato es texto en pantalla y estado en git.

Cada regla lleva su origen, `Medido:` con fecha. Si una regla no tiene un incidente detrás, no va aquí.

---

## 1. Roles

| Rol | Quién | Qué hace |
|---|---|---|
| **claw** | el agente `main` del gateway | Recibe "implementa las fases X e Y". Manda a hacer o valida el runbook. Elige y lanza al lead. Lo vigila por tmux. Contesta lo mecánico. Relanza al lead en otro host si se cae. Relaya el Telegram. Puede mergear y desplegar sin permiso adicional. |
| **lead** | un CLI disponible que Claw pueda lanzar y verificar en tmux | Escribe encargos, lanza implementadores, audita, cierra los PRs con `merge.py`, despliega, escribe progreso, cierra la fase. No escribe código de producto. |
| **implementador** | muse, cursor, glm, u otro, según el brief | Escribe el código de un carril en su worktree. Reporta con la línea de contrato. No hace push ni abre PR, y no comenta, descarta ni adjudica en GitHub: eso lo hace solo el coordinador. |
| **verificador** | otro agente distinto del implementador | Ejecuta el comportamiento que la fila pide y deja la evidencia que el recibo enlaza: comando, resultado y SHA. Para un bug, demuestra que su regresión falla sin el arreglo. Nunca el modelo que implementó. |
| **revisor** | el bot ai-review, sobre el PR | Revisa el diff completo del bloque excluyendo a los autores: es el rol `reviewer` del recibo, y no hay un revisor aparte de él. Sus hallazgos llegan al PR, y solo el coordinador los descarta o adjudica. |
| **CodeRabbit** | bot en GitHub | Revisa cuando el PR se promueve a listo, nunca los pushes del borrador; después solo ve los pushes de corrección. Sin cuota o `rate limited` no frena: pasa con aviso (decisión del 2026-09-25, §5). Sus comentarios se leen y se adjudican igual. |
| **David** | el dueño | Solo lee el Telegram de cierre y el tablero. Preaprobó por escrito lo que la fase necesita. |

El kit ya no mantiene una allowlist de hosts para autorizar la entrega. La lista de preferencia pertenece a Claw y puede incluir cualquier CLI cuyo binario, modo de permisos y arranque haya verificado. Claw puede mergear y desplegar.

Todo mensaje que la corrida manda a David cumple `seguimiento.v1`: cuatro líneas, etiquetas cerradas, lenguaje de usuario.

Medido: 2026-09-16, el runbook de la Fase 7 fijó «lead: Claude» y no pudo relevarlo. Corregido el 2026-09-21: entrega-sin-sello A movió la autoridad al recibo persistente del PR, por lo que el host ya no forma parte de la aprobación.

---

## 2. El contrato de reporte

Todo proceso que el lead o claw vigilan termina imprimiendo, como última línea, una de dos:

```
LISTO <sha>
ATORADO <razón en una línea>
```

Un implementador la imprime al cerrar su encargo. El lead la imprime al cerrar cada carril y al cerrar la fase. **El `LISTO` de una fase no se escribe de memoria: se gana con un comando.** Antes de imprimirlo, y antes de que nadie le diga a David que la fase terminó:

```
bash scripts/cierre-de-fase.sh <fase>
```

**El arranque se gana con su propio comando, y va ANTES de tocar ningun carril.** Una fase no esta arrancada hasta que esto imprima VERDE:

```
bash scripts/arranque-de-fase.sh <fase>
```

El lead no anuncia que empezo en prosa: pega esa salida. Comprueba las cinco cosas que el arranque produce y que si son observables -- filas en el plan, el primer avance enviado al tablero, los dos crons de seguimiento creados y encendidos, el apunte de sesiones con su linea del lead, y la sesion del lead viva y marcada. Ninguna es opinion. No comprueba si alguien leyo el runbook, que no se puede comprobar: comprueba lo que leerlo obliga a producir.

Medido: 2026-09-18. claw reporto la Fase 9 terminada. No solo no habia terminado -- 13 de 13 filas seguian abiertas -- es que nunca la arranco: los crons `corrida-vigia-9` y `corrida-empuje-9` de la tarea 0.4 no existian. Sin ellos no hay alarma, y sin alarma nadie se entera de que no hay alarma. Ocho horas. La instruccion ya estaba escrita en el runbook; lo que faltaba era la comprobacion, porque un paso saltado no se ve y una linea ROJO si.

**No es una compuerta de una sola pasada: es un bucle.** La primera corrida normalmente sale `ROJO`, y eso no es un fallo: su lista **es** la lista de lo que falta por hacer. Si el cierre se hizo entero antes de correrlo, puede salir `VERDE` a la primera. Se hace lo que dice cada línea, se vuelve a correr, y así hasta que imprima `VERDE` y salga 0. Solo entonces se escribe el `LISTO` y solo entonces se le dice a nadie que la fase terminó. Comprueba las cosas que un merge no comprueba: las celdas `Status` del plan cerradas, ninguna rama ni worktree de la fase sin recoger (ni en el remoto ni en el disco), ninguna sesión suya todavía marcada, los plugins que la fase declara encendidos en el gateway, los entregables de su documento de progreso en estado terminal —instalación y simulacro son carriles sin PR: que el remoto diga MERGED no los prueba—, y la rama por defecto en verde. Una línea `unknown` no bloquea: es una comprobación que no se pudo hacer, y se declara.

Medido 2026-09-17: la Fase 7 se reportó terminada con todo su código mergeado y CI en verde, y le faltaban las ocho celdas del plan, el plugin sin encender en el gateway (que era su tarea de despliegue), dos sesiones todavía marcadas y un worktree abierto. Ninguna de esas cinco cosas tenía alarma, porque un merge es observable y el cierre no lo era. Claw la busca en la pantalla de tmux; no interpreta spinners, colores ni mensajes propios de ningún producto. Si un proceso termina sin esa línea, se trata como `ATORADO sin reporte` y se aplica la fila de relanzamiento.

Medido: 2026-09-14, la skill `mac-tmux-control` nació leyendo el spinner de Claude Code como señal de vida; con otro CLI en la misma pantalla esa señal no existe.

---

## 3. El loop por tarea

Cada tarea de un carril pasa por esto, en este orden. Ningún paso se salta; si uno no aplica, se escribe por qué en el PR.

1. **Encargo.** El lead escribe `BRIEF.md` en la raíz del worktree del carril: GOAL con la fila del plan verbatim, SCOPE con la tabla de archivos, CONTEXT con rutas absolutas, ACCEPTANCE con la DoD verbatim, VERIFY con los comandos exactos, TIMEBOX, FORBIDDEN y REPORT. Un encargo por carril, no por tarea. **El encargo viaja como archivo.** Por tmux solo va una línea corta que lo nombra ("Lee `<ruta>/BRIEF.md` y haz lo que pide"), con el `Enter` en llamada aparte: con textos largos el TUI se traga el `Enter` y el encargo queda escrito sin enviarse. El encargo sigue la plantilla del encargo de la skill `autopilot-runbook` (regla de no limpiar y espejo de progreso).
2. **Implementación.** El implementador trabaja en su worktree, commitea con el hook, y termina con la línea de contrato. Donde la fila dice `[tdd:required]`, el rojo va pegado en `.saikit/scratch/<carril>/tdd.md`; sin rojo pegado, no terminó. **TIMEBOX con pausas: 6 horas** de reloj por carril, desde su lanzamiento hasta su `LISTO`. El tiempo detenido en un diálogo no cuenta: al quedar otra vez trabajando, el TIMEBOX **vuelve a 6 horas completas**. A su tope, el carril pasa a `atorado` con lo que tenga y los demás siguen.

Medido: 2026-09-17, primera corrida de la Fase 7, de donde esta regla se muda al loop: los dos carriles se lanzaron sin su flag sin-preguntas y uno pasó 7 h detenido en un prompt de permiso. Ese tiempo lo perdió el lanzamiento, no el implementador, y por eso el TIMEBOX se reinicia al quedar en modo sin preguntas.
3. **Auditoría del lead, antes de cualquier push o PR.** El lead lee el commit y **la evidencia del verificador**: la prueba que discrimina, con su mutación demostrada en una copia aislada (rojo sin el arreglo, con comando y resultado pegados). Cada hallazgo del lead se corrige con un encargo `BRIEF-r<N>.md` al mismo implementador y vuelve a este paso. Lo no bloqueante va a una fila del plan. El lead **no vuelve a correr la batería** ni repite la mutación: ese trabajo ya lo hizo el verificador de la sección 1, y repetirlo es pagar dos veces el mismo carril. Una prueba que pasa igual sin el arreglo, visible en esa evidencia, devuelve la tarea al paso 1 con un encargo de corrección. La batería completa corre una sola vez, en CI sobre el SHA final del bloque (paso 4); cuando el PR la cubre, nada de ella corre en local.
4. **Primer push y PR.** Solo cuando la auditoría del paso 3 cerró sin bloqueantes, el lead hace push y abre el PR **como draft**, desde el worktree, con el cuerpo en archivo. El CI corre la batería completa sobre el SHA publicado; CodeRabbit no. Si la unión de jobs no cubre la batería, el lead ejecuta localmente solo lo que falta y lo registra.
5. **Promoción.** Cuando CI está verde para el SHA publicado, el lead marca el PR como listo para revisión. Ahí CodeRabbit revisa una sola vez.
6. **Revisión del PR.** Promovido el PR, revisan los bots de la sección 4: el ai-review con su evidencia del head y CodeRabbit con sus hilos. Se leen y se adjudican sus hallazgos, no solo su check; comenta, descarta (`ai-review: descartar F<n>`) y adjudica **solo el coordinador**. Solo un bloqueante adjudicado que siga abierto —con el comando que lo reproduce— vuelve al paso 7 con un encargo de corrección. Un comentario no bloqueante no abre ronda ni impide el merge: si es de una línea se corrige en la misma ronda, y si no, queda en los residuales del paso 8. El PR espera hasta tener su aprobación —la evidencia completa del bot en su head y cero bloqueantes adjudicados abiertos—; la cuota de CodeRabbit no detiene (§5).
7. **Corrección tras la revisión, en local.** El PR permanece abierto. El implementador corrige localmente sin hacer push, y los bots revisan solo el delta de la corrección: la política de la sección 4 sobre los arreglos. Después el coordinador publica el nuevo SHA en el mismo PR. CI y los bots vuelven a revisar ese SHA.
8. **Cierre.** Registra los residuales y comprueba CI y CodeRabbit aprobados para el SHA actual del PR; no se exige `APPROVE lead`.
9. **Merge** por GitHub, sección 6. Base al día antes, con `git merge origin/<default>` en el worktree del carril y push normal: **nunca rebase**, que exige force-push y está prohibido. Después de actualizar la base, `merge.py mergear` comprueba de nuevo las compuertas para el SHA actual; si la revisión revela un bloqueante, vuelve al paso 7. La rama por defecto avanza sola cada dos horas con los snapshots del gateway, así que esto pasa en casi todo merge.
10. **Despliegue y verificación**, sección 7, si la fase lo pide.
11. **Progreso escrito**, sección 8. Solo entonces, la siguiente tarea. Los mensajes que la corrida manda a David en cada cambio de estado cumplen `seguimiento.v1`.

Medido: 2026-09-16, revisión de cierre de la Fase 6: en los siete carriles, al menos una prueba pasaba igual con el defecto puesto; ningún implementador lo detectó solo, el paso 3 lo atrapó en todos. Esa mutación hoy viaja en la evidencia del verificador (sección 1): el lead la exige, no la repite.

---

## 4. Política de rondas de revisión

La política activa es la **regla 4 de quality-kit**: tope 5+5 con relevo, guardada como datos en `docs/evidence/agent-work/politica-calidad.json` (decisión de David del 2026-10-12). Cambiar sus números es cambiar esa decisión con su recibo, no editar este runbook.

- **Quién revisa.** Los bots, sobre el PR: el bot ai-review revisa el diff completo del bloque excluyendo a los autores, y CodeRabbit trae sus hilos en línea. CI es la otra mitad de la revisión: la batería completa sobre el SHA publicado. No hay revisión cruzada en local con quality-kit ni un segundo modelo de revisión: la revisión es externa al carril y no se duplica. Nunca revisa el modelo que implementó.
- **Ronda.** Los hallazgos bloqueantes de una ronda se agrupan y se corrigen en una sola pasada, como encargo `BRIEF-r<N>.md` al mismo implementador, nunca lo escribe el lead. El SHA nuevo se publica en el mismo PR y los bots revisan el delta de la corrección.
- **Solo un hallazgo bloqueante abre ronda.** Bloqueante es seguridad, datos, una regla innegociable, el comportamiento que pide la fila roto o una prueba que no discrimina, y siempre va con el comando que lo reproduce: sin reproducción no bloquea.
- **Lo no bloqueante no abre ronda.** Se corrige en la misma si es de una línea; si no, va a una fila del plan con su razón y se nombra en los residuales del paso 8.
- **Tope 5+5 con relevo.** Cinco rondas por implementador; al llegar al tope, el carril releva a otro implementador y son cinco rondas más. Un bloqueante que vuelve cuenta como otra ronda: no hay paro por bloqueante repetido, el tope es el límite.
- **Un PR nunca se promueve con un bloqueante abierto.** Un bloqueante nunca va a una fila del plan: se corrige o el carril queda `ATORADO` y decide el operador.
- **La ronda cierra en el PR, y solo el coordinador la cierra.** Los hallazgos del bot se descartan o se adjudican en comentarios del PR, y la compuerta de merge (`merge.py mergear`, §6) lee esa adjudicación con su forma literal y su head:

```
ai-review: descartar F4
adjudicado F2 @<head corto>: no-bloqueante — el dato se valida en la capa de abajo
adjudicado cr:hilo-3 @<head corto>: no-aplica — duplicado de F1
```

Medido: 2026-10-12, decisión del dueño (`docs/evidence/sistema-agentes-unificado/revision-2026-10-12/decisiones-para-david.md:27`): «regla 4 de quality-kit con tope 5+5. La propuesta de cuatro ciclos queda inactiva». La cruzada local de quality-kit salió del flujo ese mismo día: los bots ya revisan el bloque con evidencia firmada y head nombrado.

Medido: 2026-09-16, PR #48: catorce rondas cruzadas sobre un cambio de documentación, a 100 a 150 mil tokens cada una, **todas con el mismo revisor**. Ese desperdicio lo causaron dos cosas, y ninguna era la falta de un tope: el revisor nunca rotó, y se siguió rondando por hallazgos bajos. El tope de tres que estuvo escrito aquí hasta el 2026-09-18 trataba el síntoma y, al hacerlo, mandaba a promover PRs con altas y medias vivas: la Fase 9 lo aplicó tal como estaba escrito y declaró "tope de rondas alcanzado" con cuatro medias abiertas.

Medido: 2026-09-18, en los repos del dueño: el criterio "sin tope, se sigue mientras aparezcan altas o medias" volvió la revisión una cadena sin fin, porque cada arreglo traía código nuevo que revisar y siempre salía algo. El dueño cambió la regla a bloqueantes con reproducción, segunda ronda solo sobre los arreglos y tope de 2 (quality-kit #12). Ese mismo día quitó el tope (quality-kit #13): las rondas siguen mientras salgan bloqueantes, cada una solo sobre los arreglos de la anterior. La lección de la Fase 9 queda en la regla de arriba: nunca se promueve con un bloqueante abierto.

---

## 5. PRs y CodeRabbit

- **Un PR por carril, nunca por tarea.** Las tareas de un carril son commits del mismo PR.
- **Borrador hasta que CI esté verde.** El PR nace como draft y solo se promueve con CI verde para el SHA publicado. CodeRabbit no ve los pushes del borrador: ve el PR promovido y, después, solo los pushes de corrección, que son pocos porque cada ronda revisa solo el delta de la anterior.
- **Tope de tres PRs abiertos a la vez** por corrida. Si hay que abrir un cuarto, se cierra uno primero.
- **CodeRabbit sin cuota no frena el PR.** Con la compuerta de `merge.py`, un `success` con «Review rate limited» cuenta como revisión ausente: pasa con el aviso `coderabbit-rate-limited`. Es la decisión de David del 2026-09-25 (#173 a #175: con CodeRabbit en su límite, la revisión del bot ai-review basta). El aviso va en el PR y en el Telegram; se vuelve a consultar en el siguiente PR.
- **Los comentarios de CodeRabbit se leen y se adjudican** antes de mergear. Un check en verde con comentarios sin leer no es una revisión aprobada; leídos, manda la regla de la sección 4: solo un bloqueante con reproducción abre ronda, y lo no bloqueante se nombra en los residuales del recibo. La compuerta nunca fue cero comentarios: es cero bloqueantes adjudicados abiertos.
- **Solo el coordinador toca el PR en GitHub.** Comenta, descarta (`ai-review: descartar F<n>`) y adjudica los hallazgos de los bots. Los implementadores nunca: su corrección viaja como encargo y commits, y su voz en el hilo del PR no existe.

Medido: 2026-09-16, PR #48 se mergeó con el check de CodeRabbit en verde y trece comentarios accionables sin leer, seis de ellos altos; cuatro eran candados que daban verde con el defecto puesto. Y en la noche del 15, siete PRs abiertos a la vez agotaron la cuota del bot antes de la mitad de la corrida.

---

## 6. Merge del PR

Con CI y CodeRabbit aprobados y los bloqueantes resueltos, cualquier agente Claw o CLI ejecuta `python3 scripts/agent-work/merge.py mergear <PR> --sha <head>`. El comando verifica sus compuertas sobre ese SHA —no draft, head exacto, checks verdes, CodeRabbit, la evidencia del bot con su `completion` y cada hallazgo abierto descartado o adjudicado— y solo entonces hace el squash; si algo falta, devuelve el faltan y no mergea. Un job de infraestructura caído se re-corre una vez con `python3 scripts/agent-work/merge.py reintentar <PR> --sha <head>`; la segunda caída es un fallo de verdad. No se requiere orden adicional, recibo del lead ni tabla de preaprobaciones. Confirma `MERGED` y el SHA integrado.

---

## 7. Despliegue y configuración del gateway

- Mergear no publica el runtime Windows. Cualquier agente puede ejecutar `publicar-runtime-windows.md` sin permiso adicional ni ventana de cron.
- **Los cambios de configuración van en tanda, no en ráfaga.** Doce escrituras seguidas son doce congelamientos seguidos.
- Todo despliegue tiene su canary escrito como comando, salida esperada y reversa automática. Sin reversa escrita, no se despliega.
- **La lectura de vuelta prueba que se escribio, no que algo lo este usando.** Un valor que un plugin lee al registrarse sigue sirviendo el viejo despues del cambio, y la configuracion leida de vuelta dice que si. No hay RPC que recargue un plugin: se reinicia el gateway. El canary de un cambio asi no se hace contra la configuracion sino contra el comportamiento: se pide lo que el valor nuevo tiene que cambiar y se mira si cambio.

Medido: 2026-09-16, 15:25 a 15:28 hora del Pacífico: doce recargas de configuración en tres minutos, una cada 30 a 49 segundos, cada una congelando el gateway 10 a 12 segundos y retrasando el latido hasta 36.7 segundos; el teléfono de David mostraba "gateway request timed out" a esa misma cadencia.

Medido: 2026-09-18, encendiendo el tablero de la Fase 7. Se agrego la fase a la lista de la configuracion del plugin, la lectura de vuelta trajo el valor nuevo, y el tablero siguio sirviendo la lista que cargo al arrancar: desde la aplicacion no habia camino a la fase. La lectura de vuelta decia que si durante todo ese rato. Solo el reinicio del gateway lo cambio.

---

## 8. Progreso escrito, no contado

Las corridas nuevas escriben eventos `runbook.progress.event` según [el contrato](../spec/runbook-progress-events.v1.md). El primer comando abre la corrida con el alcance y los presupuestos de ronda declarados. En cada cambio de carril, cola o atención se encola un evento con ID estable y se publica; LISTO y VEREDICTO se persisten como archivos de evidencia antes de anunciar el cierre de la ronda. `~/bin/progress-events.py publish --corrida <id>` reintenta la cola tras fallos de red incluso si no hubo otro cambio. `sync` genera `estado.md` y `.saikit/progress/<fase>.json` desde la misma revisión aceptada. `runbook.progress.set` queda solo para tableros históricos: la corrida administrada por eventos lo rechaza para impedir que una foto vieja borre rondas nuevas.

El lead manda a David un Telegram en cada cambio de estado. Mientras la corrida siga activa, claw o Hermes manda otro al menos cada 30 minutos. Los recordatorios del vigilante son internos y no cuentan como seguimiento al dueño. Todos los mensajes de la corrida a David (seguimiento, parte, cierre) cumplen `seguimiento.v1`: `[ETIQUETA]`, `Que cambio`, `Que sigue`, `Que necesito de ti`, en lenguaje de usuario.

Medido: 2026-09-16, el cierre de la Fase 6 quedó declarado en `Plans.md` con un residual de canary que, al repetirlo, pasaba: sin progreso escrito por corrida, el estado declarado y el real divergieron sin que nadie lo notara.

**Enviar el progreso no lo hace alcanzable.** La ruta del tablero es por prefijo, así que `/runbook/tablero/<fase>` sirve cualquier fase en cuanto su documento existe; pero la barra "Fases:" que da el único clic desde la aplicación se pinta con la lista `plugins.entries.tablero-runbook.config.fases` de la configuración del gateway, y el plugin la lee **una sola vez, al registrarse**. Una fase que no esté en esa lista existe y nadie llega a ella sin escribir la dirección a mano. Por eso el despliegue de una fase nueva lleva dos pasos más, los dos en la ventana segura de §7:

1. Agregar la fase a esa lista por `config.patch`, con `replacePaths` sobre `plugins.entries.tablero-runbook.config.fases` (un arreglo se reemplaza, no se fusiona).
2. Reiniciar el gateway: no hay RPC que recargue un plugin, y sin reinicio la configuración nueva queda guardada y sin efecto. Después, comprobar el enlace en el tablero de **otra** fase, porque la barra excluye la que estás viendo.

Medido: 2026-09-18, al cerrar la Fase 7. El documento estaba enviado y el tablero contestaba, y aun así desde la aplicación no había ningún camino a la Fase 7. Leer la configuración de vuelta decía que sí: la lista ya traía la fase, pero el plugin seguía sirviendo la que cargó al arrancar. La lectura de vuelta es un falso verde si no se reinicia.

---

## 9. El lead es reemplazable

El estado de una corrida vive en **git y en los PRs**, nunca en la memoria del lead: cada carril tiene su rama y su worktree, las comprobaciones de CI y CodeRabbit corresponden al SHA actual del PR, cada residual está escrito en el PR, y el progreso está en el archivo de la sección 8.

Por eso, si el lead muere, se cuelga o se queda sin cuota, claw relanza **otro host de la lista de preferencia** con la misma instrucción, y ese lead nuevo:

1. Lee `gh pr list` de los repos de la fase y el SHA actual de cada PR.
2. Lee el archivo de progreso y los worktrees. Si el progreso detiene un carril por una causa que el PR ya no tiene, consulta GitHub. En una corrida nueva publica `part.status` con el PR y evidencia de merge, luego ejecuta `sync`; en un tablero histórico usa `bash scripts/reconciliar-progreso.sh <progress.json>`. Así se limpia el motivo obsoleto sin repetir el merge.
3. Retoma cada carril donde quedó. No repite trabajo ya aprobado.
4. Comprueba los checks y revisiones del SHA actual en GitHub. Reutiliza la evidencia vigente y verifica solo los cambios nuevos; no se exige recibo del lead.

Un implementador caído se relanza **una vez** con el mismo encargo. Si el proveedor no tiene cuota, auth, binario o arranque, se detiene ese proceso y se releva al siguiente candidato compatible, conservando worktree, rama y brief. Una prueba roja o una revisión negativa no justifican cambiarlo.

Medido: 2026-09-16, corrida nocturna de la Fase 6: el primer lead murió por un error interno del gateway y se relanzó a mano; el segundo retomó desde los PRs sin repetir carriles cerrados.

---

## 10. Aceptación y cierre de fase

Cuando todos los carriles mergearon, antes de declarar la fase cerrada, el lead comprueba lo que un merge no prueba, y solo eso: la aceptación real de lo que la fase promete —la promesa visible de cada fila, recorrida como la recorrería David, sin leer el diff—, la comprobación de instalación de lo que la fase instala, y el simulacro cuando la fase lo declara. **No hay una revisión de código nueva al cierre**: cada diff del bloque ya tuvo su verificador y su revisor en las rondas de la sección 4, y repetir ahí una revisión completa con mutación de las pruebas es pagar dos veces el mismo carril. Si la aceptación encuentra un defecto real con reproducción, abre la corrección acotada de siempre: encargo al implementador del carril, rondas de la sección 4, merge por la ruta de la sección 6; no reabre la fase entera.

El orden del cierre es: esta aceptación, con instalación y simulacro; después el PR que cierra las celdas del plan; después la limpieza (ramas, worktrees, sesiones) y lo que la fase deba dejar desplegado; y al final el bucle de `cierre-de-fase.sh` (§2) hasta `VERDE`, que es lo que autoriza el `LISTO`. Correrlo antes no es un error: es la forma de saber qué falta.

Medido: 2026-09-16, revisión de cierre de la Fase 6, hecha después de que el cierre ya se había declarado: ocho hallazgos reales, dos de ellos con consecuencia directa, incluida una prueba con puerta trasera en accounting y un contrato de agente que prohibía justo lo que el sistema le encargaba. La lección que sobrevive no es repetir la revisión entera al final: es que la aceptación de la promesa, que ningún diff cubre, se comprueba con comando antes de declarar el cierre.

---

## 11. Lo que lleva un runbook de fase, y lo que no

Un runbook de fase lleva **solo lo específico de la fase**: quién implementa cada carril, la tabla de preaprobaciones de diálogos (un merge o deploy no se preaprueba en ella: rige §6), los prohibidos propios, los carriles con sus tareas y su tabla de archivos, la cola con sus compuertas escritas como comando y salida esperada, la tabla de atores propia, y el inventario. Se escribe con la skill `autopilot-runbook`.

**No repite** nada de este documento: ni el loop, ni la política de rondas, ni la de PRs, ni la ruta de merge, ni la ventana segura, ni la reanudación. Los referencia por número de sección. Si un runbook necesita apartarse de una sección de aquí, lo dice con esa sección nombrada y la razón.

Antes de lanzarse, el runbook pasa `scripts/tests/test-runbooks-no-contradicen-entorno.sh` en verde. Un runbook en rojo no se lanza.

**Un runbook se localiza con un comando, nunca con una ruta fija ni con un enlace.** Quien tenga que abrirlo corre `bash scripts/runbook.sh <fase>` desde cualquier clon del repo y obtiene la ruta absoluta en esa maquina; `--lista` las nombra todas. Ni el encargo, ni el brief, ni el mensaje que lanza a un implementador escriben la ruta a mano: escriben esa llamada. Una ruta fija solo vale en la maquina de quien la escribio, y un enlace de GitHub no abre porque el repo es privado.

Medido: 2026-09-18, arrancando la Fase 9. A los implementadores se les dio el enlace de GitHub del runbook y no pudieron abrirlo; la ruta que traian los documentos era la de otra maquina. El archivo estaba en su sitio en las dos, todo el tiempo. Lo que faltaba no era el archivo sino una forma de preguntar donde esta que contestara igual en la Mac, en el gateway Windows y en una maquina nueva.

Medido: 2026-09-16, los runbooks de las fases 6 y 7 pesaban 40 y 36 KB y repetían el loop entero; el de la 7 ya decía "hereda de la 6" a mano y se desfasó en tres puntos en un día.

---

## 12. Atores universales

Aplican en toda fase. El runbook de fase agrega las suyas y no repite estas.

| Situación | Qué hace el lead |
|---|---|
| Un candado del repo bloquea un comando legítimo | Usa la ruta que el candado nombra. Sin ruta: residual declarado. Jamás `--no-verify`. |
| El candado léxico rechaza un comando que solo *menciona* `main` o merge | Reescribe el comando sin la palabra; cuerpos largos van en archivo; `gh pr create` sin `--base`. |
| Una prueba pasa igual sin el arreglo | Encargo de corrección al mismo implementador. El arreglo no existe hasta que la prueba lo atrape. |
| La evidencia del bot quedó en otro head (el worker murió antes de publicar) | `merge.py` la rechaza como `evidencia-de-otro-head`. Se re-corre la revisión del bot sobre el head actual y se vuelve a consultar; el carril sigue. **Nunca se espera parado.** |
| CodeRabbit sin cuota o `rate limited` | No frena: `merge.py` lo pasa con el aviso `coderabbit-rate-limited` (decisión del dueño del 2026-09-25, #173 a #175). El aviso va en el PR y en el Telegram; se vuelve a consultar en el siguiente PR. |
| Cuota agotada, auth, binario ausente o fallo de arranque del **proveedor de modelo** | Se detiene el proceso anterior y se releva al siguiente candidato compatible, conservando worktree, rama, brief y commits. No se usa el relevo para escapar de una prueba o revisión. CodeRabbit no es un proveedor de modelo: su fila es la de arriba y nunca detiene un carril. |
| Una sesión queda esperando a una persona: permiso, confianza de la carpeta, límite de uso con cambio de modelo | Llega sola, sea el CLI que sea: el vigilante manda `waiting for approval`, y recuerda cada 30 minutos a toda sesión marcada que siga callada. Se contesta con la tabla de preaprobaciones de diálogos del runbook; lo que no está en la tabla se rechaza y se declara. La tabla nunca autoriza un merge ni un deploy: esa autoridad es la de §6. Si el CLI tiene modo sin preguntas, se cambia de modo en vez de contestar de una en una. Si el diálogo necesita a David, el mensaje cumple `seguimiento.v1`: pregunta en palabras simples con lo que implica cada opción. |
| Nadie vigila una sesión | **Toda** sesión que la corrida lanza se marca al lanzarla, **la del lead incluida**. Sin marca el vigilante la ignora por diseño. Excepción (T9 `:266`): una sesión gestionada (`AGENT_WORK_MANAGED=1` en tmux) nunca se marca con `OPENCLAW_WATCH` ni se relanza a mano; su host le reporta al solicitante el cierre, el diálogo o el plazo vencido. |
| Un carril pasa su TIMEBOX de 6 h | Pasa a `atorado` con lo que tenga; si su trabajo es mergeable se mergea, si no se declara. El tiempo detenido en un diálogo no contó (§3). El otro carril sigue. |
| Un comando de limpieza se vuelve pregunta | El hook de seguridad convierte en pregunta cualquier borrado destructivo, aunque sea bajo `/tmp`: `rm -rf`, `DROP DATABASE`. Los directorios de trabajo se crean con `mktemp -d` y no se borran; las bases de verificación llevan nombre único y se dejan. **No se limpia durante la corrida**: el cierre declara qué quedó, con rutas y nombres de base. |
| El lead se cae | Claw relanza otro host de la lista; sección 9. |
| Un implementador muere o calla 30 minutos sin mensaje de cuota | Se relanza una vez con el mismo encargo. A la segunda, atorado y declarado. |
| El implementador hizo push o abrió el PR solo | No se castiga ni se rehace: se verifica igual y se anota como desvío de proceso. |
| Un archivo fuera de la tabla del carril | Se descarta antes del push con un commit propio. Nunca se pushea sin declararlo. |
| El PR no puede mergearse | Corrige lo que `merge.py` nombra en su `faltan` (checks, conflictos, hallazgos sin adjudicar) y vuelve a ejecutar `merge.py mergear <PR> --sha <head>`. |
| Lo único que detiene toda la corrida | Perder acceso a GitHub o a la Mac, o un gateway que no responde tras un reinicio. Todo lo demás detiene un carril y deja evidencia. |

Medido: 2026-09-15 y 16, corrida de la Fase 6: cada fila de esta tabla es una situación que ocurrió al menos una vez esa noche y se resolvió a mano o se declaró.

Medido: 2026-09-17, corridas de las Fases 7 y 8, las tres filas de espera y vigilancia. En la Fase 8 el verificador del lead empezó una comprobación con `rm -rf` de un directorio bajo `/tmp`; el hook lo volvió pregunta a las 00:20 y nadie la contestó hasta las 07:15, 6 h 54 min, porque la sesión del lead no estaba marcada. El comando tardó segundos. En la Fase 7 un carril pasó 7 h en un prompt de red. Las pantallas de espera de los diez CLIs de la Mac se midieron ese día: no todas son permisos (codex se detiene en "límite de uso, ¿cambiar de modelo?"), y por eso el vigilante reconoce la forma del diálogo y no solo la pregunta.

---

## 13. Cómo se prueba este documento

`scripts/tests/test-loop-autopilot.sh` ancla las 13 secciones en orden y las reglas clave como frases literales, comprueba que la fila del lead **no nombra ningún modelo**, y que las secciones 1 a 12 citan su incidente con `Medido:`. Cambiar una regla es cambiar el ancla en el mismo commit; borrarla sin tocar el test pone el candado en rojo. Las fallas que originaron cada regla están citadas con fecha en el propio texto: si una regla pierde su `Medido:`, no debería estar aquí.

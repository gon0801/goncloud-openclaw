# Loop de entrega en autopilot

Este documento es la parte de todo runbook de fase que **no cambia de una fase a otra**: cómo se implementa, se revisa, se mergea, se despliega y se cierra, sin que David tenga que aprobar ni contestar nada. Los runbooks de fase lo referencian en vez de repetirlo; lo que aquí está escrito manda sobre cualquier texto de un runbook que diga otra cosa, salvo la tabla de preaprobaciones de esa fase.

Se escribe para **el lead**, que es un rol y no un modelo. Cualquier CLI de los que el kit de merge conoce puede ser el lead; cuál lo es en una corrida lo decide claw por una lista de preferencia y por cuota disponible, y puede cambiar a mitad de fase. Por eso ninguna regla de aquí depende de una capacidad de un modelo concreto: el contrato es texto en pantalla y estado en git.

Cada regla lleva su origen, `Medido:` con fecha. Si una regla no tiene un incidente detrás, no va aquí.

---

## 1. Roles

| Rol | Quién | Qué hace |
|---|---|---|
| **claw** | el agente `main` del gateway | Recibe "implementa las fases X e Y". Manda a hacer o valida el runbook. Elige y lanza al lead. Lo vigila por tmux. Contesta lo mecánico. Relanza al lead en otro host si se cae. Relaya el Telegram. **Nunca mergea ni toca la configuración del gateway.** |
| **lead** | un CLI en tmux, de cualquier host del kit | Escribe encargos, lanza implementadores, audita, corre la revisión cruzada, aprueba, mergea por el kit, despliega, escribe progreso, cierra la fase. No escribe código de producto. |
| **implementador** | muse, cursor, glm, u otro, según el brief | Escribe el código de un carril en su worktree. Reporta con la línea de contrato. No hace push ni abre PR. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Segunda opinión sobre un SHA. Nunca el modelo que implementó. |
| **CodeRabbit** | bot en GitHub | Revisa cuando el PR se promueve a listo, nunca los pushes del borrador; después solo ve los pushes de corrección, que son pocos porque el código ya pasó la cruzada. Sin cuota no bloquea, pero se declara. |
| **David** | el dueño | Solo lee el Telegram de cierre y el tablero. Preaprobó por escrito lo que la fase necesita. |

Hosts que el kit de merge conoce hoy, o sea leads posibles: `claude`, `codex`, `grok`, `zcode`, `kimi`, `dsh`. Claw no es host del kit y no lo necesita: no mergea.

Medido: 2026-09-16, `saikit-merge.sh` exige un veredicto sellado por el hook del host de la sesión y solo conoce esos seis; el runbook de la Fase 7 decía "lead: Claude" y con claw de lead los seis merges de la cola habrían fallado cerrados con "sin estado del hook".

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

**No es una compuerta de una sola pasada: es un bucle.** La primera corrida normalmente sale `ROJO`, y eso no es un fallo: su lista **es** la lista de lo que falta por hacer. Si el cierre se hizo entero antes de correrlo, puede salir `VERDE` a la primera. Se hace lo que dice cada línea, se vuelve a correr, y así hasta que imprima `VERDE` y salga 0. Solo entonces se escribe el `LISTO` y solo entonces se le dice a nadie que la fase terminó. Comprueba las seis cosas que un merge no comprueba: las celdas `Status` del plan cerradas, ninguna rama ni worktree de la fase sin recoger (ni en el remoto ni en el disco), ninguna sesión suya todavía marcada, los plugins que la fase declara encendidos en el gateway, y la rama por defecto en verde. Una línea `unknown` no bloquea: es una comprobación que no se pudo hacer, y se declara.

Medido 2026-09-17: la Fase 7 se reportó terminada con todo su código mergeado y CI en verde, y le faltaban las ocho celdas del plan, el plugin sin encender en el gateway (que era su tarea de despliegue), dos sesiones todavía marcadas y un worktree abierto. Ninguna de esas cinco cosas tenía alarma, porque un merge es observable y el cierre no lo era. Claw la busca en la pantalla de tmux; no interpreta spinners, colores ni mensajes propios de ningún producto. Si un proceso termina sin esa línea, se trata como `ATORADO sin reporte` y se aplica la fila de relanzamiento.

Medido: 2026-09-14, la skill `mac-tmux-control` nació leyendo el spinner de Claude Code como señal de vida; con otro CLI en la misma pantalla esa señal no existe.

---

## 3. El loop por tarea

Cada tarea de un carril pasa por esto, en este orden. Ningún paso se salta; si uno no aplica, se escribe por qué en el PR.

1. **Encargo.** El lead escribe `BRIEF.md` en la raíz del worktree del carril: GOAL con la fila del plan verbatim, SCOPE con la tabla de archivos, CONTEXT con rutas absolutas, ACCEPTANCE con la DoD verbatim, VERIFY con los comandos exactos, TIMEBOX, FORBIDDEN y REPORT. Un encargo por carril, no por tarea. **El encargo viaja como archivo.** Por tmux solo va una línea corta que lo nombra ("Lee `<ruta>/BRIEF.md` y haz lo que pide"), con el `Enter` en llamada aparte: con textos largos el TUI se traga el `Enter` y el encargo queda escrito sin enviarse.
2. **Implementación.** El implementador trabaja en su worktree, commitea con el hook, y termina con la línea de contrato. Donde la fila dice `[tdd:required]`, el rojo va pegado en `.saikit/scratch/<carril>/tdd.md`; sin rojo pegado, no terminó.
3. **Auditoría del lead, antes de cualquier PR.** El lead lee el commit, corre la batería una vez, y **muta él mismo** lo que la prueba protege: revierte el cambio en una copia y comprueba que la prueba se pone en rojo. Una prueba que pasa igual sin el arreglo no cuenta, y la tarea vuelve al paso 1 con un encargo de corrección.
4. **PR en borrador.** El lead hace push y abre el PR **como draft**, desde el worktree, con el cuerpo en archivo. El CI corre; CodeRabbit no.
5. **Rondas de revisión cruzada** sobre el SHA del PR, con la política de la sección 4. Cada hallazgo se corrige con un encargo `BRIEF-r<N>.md` al mismo implementador y vuelve al paso 3.
6. **Promoción.** Cuando una ronda no trae altas ni medias, el lead marca el PR como listo para revisión. Ahí CodeRabbit revisa una sola vez, sobre código que ya no va a cambiar.
7. **CodeRabbit.** Se leen sus comentarios, no solo su check. Lo accionable se corrige en el mismo PR y vuelve al paso 3. Cada push de corrección tras la promoción vuelve a pasar por CodeRabbit; se cierra cuando no deja nada nuevo o no tiene cuota.
8. **Aprobación.** `APPROVE lead <sha>` como comentario en el PR, con la lista de residuales y su razón. Solo eso mete el PR a la cola.
9. **Merge** por la ruta del kit, sección 6. Base al día antes, con `git merge origin/<default>` en el worktree del carril y push normal: **nunca rebase**, que exige force-push y está prohibido. CI verde del SHA nuevo, y re-APPROVE si `git diff <sha aprobado> HEAD -- <archivos del carril>` sale vacío, o vuelta al paso 5 si no. La rama por defecto avanza sola cada dos horas con los snapshots del gateway, así que esto pasa en casi todo merge.
10. **Despliegue y verificación**, sección 7, si la fase lo pide.
11. **Progreso escrito**, sección 8. Solo entonces, la siguiente tarea.

Medido: 2026-09-16, revisión de cierre de la Fase 6: en los siete carriles, al menos una prueba pasaba igual con el defecto puesto; ningún implementador lo detectó solo, el paso 3 lo atrapó en todos.

---

## 4. Política de rondas de revisión cruzada

- **Ronda 1**: el revisor más fuerte disponible, excluyendo al modelo que implementó. Comando, desde el worktree del carril:

```
/Users/dn/.local/bin/pwsh -NoProfile -File /Users/dn/quality-kit/cross-review.ps1 \
  -Con auto -Excluir <modelo> -Alcance last-commit
```

  `pwsh` va con ruta absoluta siempre, no solo por exec del nodo: no está en el PATH que hereda un CLI lanzado en tmux.

  **Los dos parámetros tienen conjuntos cerrados y el script aborta si te sales.** `-Alcance` acepta `staged`, `working` y `last-commit`, y **nada más**: no existe un alcance de rama entera, así que la revisión es por commit y por eso el loop pide un commit por tarea. Un carril con varios commits se revisa commit por commit, o antes de commitear con `-Alcance working`. `-Excluir` acepta solo los seis de la cadena (`claude`, `codex`, `grok`, `kimi`, `qwen`, `glm`) o vacío: si implementó alguien que no es candidato a revisor, como muse o cursor, se pasa `-Excluir ''` y se anota quién implementó en el PR, porque no hay a quién excluir. `glm` en esa cadena **es** zcode.

Medido: 2026-09-16, lectura del script: `-Alcance branch` no es un valor válido y `-Excluir cursor` tampoco; el loop los mandaba y el comando abortaba por validación de parámetro antes de revisar nada.
- **Si salen altas**: la ronda 2 la hace un modelo **distinto** al de la ronda 1. Se pide con `-Con <otro>`.
- **Se para** cuando una ronda no trae altas ni medias. Las bajas de esa última ronda se atienden si son de una línea; si no, se declaran como residuales.
- **Tope: tres rondas por PR.** A la cuarta, el lead decide qué se corrige y qué se declara. Lo que se corrige va como encargo `BRIEF-r<N>.md` al mismo implementador, nunca lo escribe el lead; el resto se declara como residual con su razón. Más rondas no compran calidad: compran costo.
- **Si el script sale con código 3** (ningún revisor externo disponible), el lead hace la revisión con un subagente propio y lo escribe en el PR como "revisión interna, sin cruzada". Nunca se espera a que la cadena vuelva.
- **Un revisor que tarda más que el tope del script no es un revisor caído**: se anota y se sigue con el siguiente. El tope se fija por medición, no por número redondo.

Medido: 2026-09-16, PR #48: catorce rondas cruzadas sobre un cambio de documentación, a 100 a 150 mil tokens cada una, todas con el mismo revisor. Y el mismo día la cadena entera salió con código 3: kimi y codex sin cuota, zcode, grok y qwen pasados de 300 segundos, cuando zcode necesita 366 en un diff real.

---

## 5. PRs y CodeRabbit

- **Un PR por carril, nunca por tarea.** Las tareas de un carril son commits del mismo PR.
- **Borrador hasta la aprobación cruzada.** El PR nace como draft y solo se promueve cuando la sección 4 cerró. CodeRabbit no ve los pushes del borrador: ve el PR promovido y, después, solo los pushes de corrección, que son pocos porque el código ya pasó la cruzada.
- **Tope de tres PRs abiertos a la vez** por corrida. Si hay que abrir un cuarto, se cierra uno primero.
- **Sin cuota de CodeRabbit no se espera**: el PR sigue su curso, pero la línea "CodeRabbit sin cuota: no revisó este PR" va en el cuerpo del PR y en el Telegram. Que no bloquee no significa que no se diga.
- **Los comentarios de CodeRabbit se leen** antes de mergear. Un check en verde con comentarios accionables no es una revisión aprobada.

Medido: 2026-09-16, PR #48 se mergeó con el check de CodeRabbit en verde y trece comentarios accionables sin leer, seis de ellos altos; cuatro eran candados que daban verde con el defecto puesto. Y en la noche del 15, siete PRs abiertos a la vez agotaron la cuota del bot antes de la mitad de la corrida.

---

## 6. Merge: la ruta del kit

El merge es siempre el del kit, con `--confirmado` como el sí escrito del dueño que ya está en la tabla de preaprobaciones de la fase. Ninguna otra ruta: ni la interfaz de GitHub, ni la API, ni a mano.

**Dónde y cómo se corre.** El script opera sobre la **rama del worktree en el que estás parado**, no toma número de PR y toma un lock por clon, así que se corre con `cd` al worktree de ese carril. En orden, desde ahí:

```
test -r /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh || { echo ATORADO kit ausente en /Users/dn/dev/summonaikit-claude/tools; exit 1; }
bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --dry-run       # debe terminar en LISTO
bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --confirmado    # squash con --match-head-commit
bash /Users/dn/dev/summonaikit-claude/tools/saikit-postmerge.sh --merge-commit <merge_commit> --rama <default>
```

**La ruta va escrita entera, no en una variable.** El candado léxico de este repo hashea el token literal del script y lo compara contra el manifiesto del kit: escrito como `$K/<script>` el token no resuelve, el hash no casa, y el candado deniega el comando con "hash does not match the kit manifest" aunque el kit esté intacto. Medido 2026-09-16, en las dos formas: afectaba a todos los merges de una fase. En otra máquina se sustituye esa ruta por la suya, también escrita entera.

**Si esa primera línea falla, el lead no busca el script por el disco ni cambia de ruta de merge**: reporta `ATORADO kit ausente en <ruta>` y para. Un merge por otra vía deja el PR sin sello y rompe la cadena.

`saikit-postmerge.sh` en VERDE cierra el ítem; en ROJO trae el comando de reversa listo; en UNKNOWN se anota y aplica la compuerta propia del ítem. El script del kit vive en `644` y **se invoca por `bash`**: comprobar su existencia con `test -x` da falso negativo. Si un PR no tiene worktree propio, se abre uno con `git worktree add <ruta> <rama>` solo para mergearlo y se borra después.

El kit exige un **veredicto sellado**: el subagente revisor del lead escribe el archivo de veredicto con la herramienta de escritura de su host, el hook del host lo sella, y el merge se corre **desde esa misma sesión viva, en el mismo host y con la misma ruta de proyecto**, antes de cerrar el turno. Un estado de otro host, otra sesión u otra ruta no sirve.

Precondiciones que el runbook de fase tiene que dejar listas antes de lanzar:

- `.saikit/autopilot.json` **ya en `origin/<default>`** de cada repo. El kit lo lee de ahí y rechaza cualquier PR que lo traiga; por eso el bootstrap es un PR aparte que mergea David antes de la corrida, y no es tarea de ningún carril.
- El hook del kit instalado para **cada host que pueda ser lead**, y probado con un merge de prueba por host, una vez.

Medido: 2026-09-15, Fase 6: el runbook mandaba commitear `autopilot.json` dentro del PR del carril; el kit lo rechaza por diseño y la corrida se atascó una noche entera hasta que se hicieron PRs de bootstrap a mano.

---

## 7. Despliegue y configuración del gateway

- Mergear a `main` de goncloud-openclaw o de un workspace **es** desplegar: el sync del gateway lo lleva en el siguiente ciclo. Se mergea en ventana segura: ningún cron con `Next` en 15 minutos, y fuera de los minutos :05 a :15 de las horas impares en `America/New_York`, leída con `TZ=America/New_York date`. El sync del gateway no es un cron y no aparece en `cron list`: lo cubre la franja de minutos, que es exactamente cuando corre.
- **Ningún cambio de configuración del gateway lo hace claw desde su propio turno.** Lo hace el lead desde la Mac, con cero corridas en vuelo verificadas, y con lectura de vuelta de la configuración después. Cada recarga en caliente congela al gateway entre diez y doce segundos; claw vive ahí y se mataría a sí mismo.
- **Los cambios de configuración van en tanda, no en ráfaga.** Doce escrituras seguidas son doce congelamientos seguidos.
- Todo despliegue tiene su canary escrito como comando, salida esperada y reversa automática. Sin reversa escrita, no se despliega.

Medido: 2026-09-16, 15:25 a 15:28 hora del Pacífico: doce recargas de configuración en tres minutos, una cada 30 a 49 segundos, cada una congelando el gateway 10 a 12 segundos y retrasando el latido hasta 36.7 segundos; el teléfono de David mostraba "gateway request timed out" a esa misma cadencia.

---

## 8. Progreso escrito, no contado

En cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `.saikit/progress/<fase>.json` en el formato `runbook-progress.v1` y lo envía con `openclaw gateway call runbook.progress.set --params "$(cat <archivo>)"`. La CLI **no** acepta la forma arroba-archivo: contesta `--params must be valid JSON` (medido 2026-09-16 y otra vez el 2026-09-17), así que el JSON va en línea. Un envío fallido no bloquea y se reintenta en el siguiente cambio. Cada escritura lleva `atencion_requerida` y `siguiente_paso` en lenguaje llano. Lo que no está en ese archivo no es progreso.

Medido: 2026-09-16, el cierre de la Fase 6 quedó declarado en `Plans.md` con un residual de canary que, al repetirlo, pasaba: sin progreso escrito por corrida, el estado declarado y el real divergieron sin que nadie lo notara.

---

## 9. El lead es reemplazable

El estado de una corrida vive en **git y en los PRs**, nunca en la memoria del lead: cada carril tiene su rama y su worktree, cada aprobación es un comentario `APPROVE lead <sha>` en el PR, cada residual está escrito en el PR, y el progreso está en el archivo de la sección 8.

Por eso, si el lead muere, se cuelga o se queda sin cuota, claw relanza **otro host de la lista de preferencia** con la misma instrucción, y ese lead nuevo:

1. Lee `gh pr list` de los repos de la fase y los comentarios `APPROVE lead`.
2. Lee el archivo de progreso y los worktrees.
3. Retoma cada carril donde quedó. No repite trabajo ya aprobado.
4. Si un PR aprobado no tiene sello vigente en el host nuevo, lo re-sella con un revisor propio contra el head actual y sigue.

Un implementador externo se relanza **una vez** con el mismo encargo; a la segunda, el carril queda `atorado` y se declara. No se cambia de implementador en silencio.

Medido: 2026-09-16, corrida nocturna de la Fase 6: el primer lead murió por un error interno del gateway y se relanzó a mano; el segundo retomó desde los PRs sin repetir carriles cerrados.

---

## 10. Revisión de cierre de fase

Cuando todos los carriles mergearon, antes de declarar la fase cerrada, el lead hace una revisión completa de lo implementado contra la DoD literal de cada fila, **no contra el cuerpo de los PRs**. Incluye mutar las pruebas nuevas. Lo que salga entra en un último loop de corrección con el mismo implementador de ese carril, con las mismas rondas de la sección 4, y se mergea por la misma ruta. Solo entonces se cierran las celdas de estado del plan, con el SHA de squash y las salvedades escritas en la celda.

El orden del cierre es: esta revisión y sus correcciones; después el PR que cierra las celdas del plan; después la limpieza (ramas, worktrees, sesiones) y lo que la fase deba dejar desplegado; y al final el bucle de `cierre-de-fase.sh` (§2) hasta `VERDE`, que es lo que autoriza el `LISTO`. Correrlo antes no es un error: es la forma de saber qué falta.

Medido: 2026-09-16, revisión de cierre de la Fase 6, hecha después de que el cierre ya se había declarado: ocho hallazgos reales, dos de ellos con consecuencia directa, incluida una prueba con puerta trasera en accounting y un contrato de agente que prohibía justo lo que el sistema le encargaba.

---

## 11. Lo que lleva un runbook de fase, y lo que no

Un runbook de fase lleva **solo lo específico de la fase**: quién implementa cada carril, la tabla de preaprobaciones, los prohibidos propios, los carriles con sus tareas y su tabla de archivos, la cola con sus compuertas escritas como comando y salida esperada, la tabla de atores propia, y el inventario. Se escribe con la skill `autopilot-runbook`.

**No repite** nada de este documento: ni el loop, ni la política de rondas, ni la de PRs, ni la ruta del kit, ni la ventana segura, ni la reanudación. Los referencia por número de sección. Si un runbook necesita apartarse de una sección de aquí, lo dice con esa sección nombrada y la razón.

Antes de lanzarse, el runbook pasa `scripts/tests/test-runbooks-no-contradicen-entorno.sh` en verde. Un runbook en rojo no se lanza.

Medido: 2026-09-16, los runbooks de las fases 6 y 7 pesaban 40 y 36 KB y repetían el loop entero; el de la 7 ya decía "hereda de la 6" a mano y se desfasó en tres puntos en un día.

---

## 12. Atores universales

Aplican en toda fase. El runbook de fase agrega las suyas y no repite estas.

| Situación | Qué hace el lead |
|---|---|
| Un candado del repo bloquea un comando legítimo | Usa la ruta que el candado nombra. Sin ruta: residual declarado. Jamás `--no-verify`. |
| El candado léxico rechaza un comando que solo *menciona* `main` o merge | Reescribe el comando sin la palabra; cuerpos largos van en archivo; `gh pr create` sin `--base`. |
| Una prueba pasa igual sin el arreglo | Encargo de corrección al mismo implementador. El arreglo no existe hasta que la prueba lo atrape. |
| El revisor cruzado sale 3 | Revisor interno, declarado en el PR. No se espera. |
| CodeRabbit sin cuota o sin respuesta en 20 minutos | No bloquea. Línea en el PR y en el Telegram. Se reintenta tras el próximo push. |
| Cuota agotada o rate limit de un **proveedor de modelo** (el del implementador o el del revisor) por más de 30 minutos | El carril se detiene y se declara. Los demás siguen. No se cambia de modelo ni de proveedor por cuenta propia. CodeRabbit no es un proveedor de modelo: su fila es la de arriba y nunca detiene un carril. |
| Una sesión queda esperando a una persona: permiso, confianza de la carpeta, límite de uso con cambio de modelo | Llega sola, sea el CLI que sea: el vigilante manda `waiting for approval`, y recuerda cada 30 minutos a toda sesión marcada que siga callada. Se contesta con la tabla de preaprobaciones del runbook; lo que no está en la tabla se rechaza y se declara. Si el CLI tiene modo sin preguntas, se cambia de modo en vez de contestar de una en una. |
| Nadie vigila una sesión | **Toda** sesión que la corrida lanza se marca al lanzarla, **la del lead incluida**: `/opt/homebrew/bin/tmux set-environment -t <sesión> OPENCLAW_WATCH 1`. Sin marca el vigilante la ignora por diseño. Se desmarcan todas al cerrar la fase. |
| Un comando de limpieza se vuelve pregunta | El hook de seguridad convierte en pregunta cualquier borrado destructivo, aunque sea bajo `/tmp`: `rm -rf`, `DROP DATABASE`. Los directorios de trabajo se crean con `mktemp -d` y no se borran; las bases de verificación llevan nombre único y se dejan. **No se limpia durante la corrida**: el cierre declara qué quedó, con rutas y nombres de base. |
| El lead se cae | Claw relanza otro host de la lista; sección 9. |
| Un implementador muere o calla 30 minutos sin mensaje de cuota | Se relanza una vez con el mismo encargo. A la segunda, atorado y declarado. |
| El implementador hizo push o abrió el PR solo | No se castiga ni se rehace: se verifica igual y se anota como desvío de proceso. |
| Un archivo fuera de la tabla del carril | Se descarta antes del push con un commit propio. Nunca se pushea sin declararlo. |
| La ruta del kit rechaza (sin sello, sin estado del hook, lock ajeno) | Una vez: re-sellar con un revisor propio desde la sesión viva y reintentar. Si sigue: el PR queda abierto con su `APPROVE lead <sha>` y la razón textual, y va en el Telegram. Ninguna otra ruta de merge. |
| Lo único que detiene toda la corrida | Perder acceso a GitHub o a la Mac, o un gateway que no responde tras un reinicio. Todo lo demás detiene un carril y deja evidencia. |

Medido: 2026-09-15 y 16, corrida de la Fase 6: cada fila de esta tabla es una situación que ocurrió al menos una vez esa noche y se resolvió a mano o se declaró.

Medido: 2026-09-17, corridas de las Fases 7 y 8, las tres filas de espera y vigilancia. En la Fase 8 el verificador del lead empezó una comprobación con `rm -rf` de un directorio bajo `/tmp`; el hook lo volvió pregunta a las 00:20 y nadie la contestó hasta las 07:15, 6 h 54 min, porque la sesión del lead no estaba marcada. El comando tardó segundos. En la Fase 7 un carril pasó 7 h en un prompt de red. Las pantallas de espera de los diez CLIs de la Mac se midieron ese día: no todas son permisos (codex se detiene en "límite de uso, ¿cambiar de modelo?"), y por eso el vigilante reconoce la forma del diálogo y no solo la pregunta.

---

## 13. Cómo se prueba este documento

`scripts/tests/test-loop-autopilot.sh` ancla las 13 secciones en orden y las reglas clave como frases literales, comprueba que la fila del lead **no nombra ningún modelo**, y que las secciones 1 a 12 citan su incidente con `Medido:`. Cambiar una regla es cambiar el ancla en el mismo commit; borrarla sin tocar el test pone el candado en rojo. Las fallas que originaron cada regla están citadas con fecha en el propio texto: si una regla pierde su `Medido:`, no debería estar aquí.

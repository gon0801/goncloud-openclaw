# Fase 8 — hallazgos de los dos lectores y bloqueos declarados

Fecha: 2026-09-16. Estado: **el runbook `autopilot-fase8.md` NO se lanza.** Dos
lectores de contexto fresco lo ejecutaron en seco contra la máquina real y
devolvieron 37 hallazgos. Cuatro son bloqueos que no se arreglan escribiendo
mejor: el mecanismo que el formato exige no existe, y el plan dice que esta
fase todavía no arranca. Este archivo es el rastro; el runbook se termina
cuando los bloqueos se levanten, no antes.

Los dos lectores verificaron con comandos, no por lectura. Lo que declaran
como verificado y correcto está al final, para no volver a gastar ahí.

## Bloqueos (no se arreglan redactando)

**B1 · El tablero de progreso no existe en esta máquina.** La skill
`autopilot-runbook` hace obligatorio el slot de progreso (`runbook-progress.v1`
enviado con `runbook.progress.set`), y el loop lo repite en su sección 8. Medido:

```
$ /Users/dn/.openclaw/bin/openclaw gateway call runbook.progress.get --params '{"fase":"8"}'
Gateway call failed: unknown method: runbook.progress.get
$ /Users/dn/.openclaw/bin/openclaw plugins list | grep -i "runbook\|tablero"
(sin salida; 40/59 plugins habilitados, ninguno es tablero-runbook)
$ ls /Users/dn/.openclaw/plugins
ls: No such file or directory
```

Y aunque existiera, la invocación que los tres documentos escriben aborta,
porque la CLI no acepta `@archivo`:

```
$ /Users/dn/.openclaw/bin/openclaw gateway call health --params @/ruta/archivo.json
Gateway call failed: --params must be valid JSON.
$ /Users/dn/.openclaw/bin/openclaw gateway call health --params '{}'
{ "ok": true, ... }
```

Fuente confirmada: `gateway-cli-MG0bIvmJ.mjs:184`, `parseGatewayCallParams`
hace `JSON.parse` del valor y no maneja `@`. **Esto afecta también al loop y al
spec**, no solo a este runbook: los tres traen la forma `--params @<archivo>`.

**B2 · El plan dice que esta fase todavía no arranca.**
`plans/repricing-01.md` cierra con: «Este plan no arranca antes de cerrar D.3
de `fabrica-02` (19-sep) por atención del dueño, no por dependencia técnica».
Hoy es 2026-09-16.

**B3 · El carril D implementa una fila de una fase sin validar.** El carril D es
E.1, de la fase E, y el plan dice dos veces que «las fases E, B revisada y M
llevan su propia ronda de cinco perspectivas antes de implementarse». E.1 es
`[stage:verificacion]` y de solo lectura, así que puede que esté exenta, pero
eso no está escrito en ninguna parte y el runbook se contradice a sí mismo al
afirmar que «esta fase no toca ninguna» de esas fases.

**B4 · No se sabe si muse puede trabajar en un worktree.** El runbook manda
cuatro worktrees en paralelo. La memoria del proyecto dice que muse edita
directo en `/Users/dn/dev/goncloud-Orbit`, que no es sesión de Claude Code y
que deja cambios sin commitear; el dueño, preguntado, no lo sabe. Los lectores
sí verificaron que `muse` está en el PATH con sesión de tmux viva. Si muse solo
trabaja en el checkout principal, **no hay paralelo posible** y el runbook pasa
de cuatro carriles simultáneos a una fila única. Además ese checkout está hoy
ocupado por otra sesión (rama `quitar-avisos-telegram`).

## Hallazgos que sí se arreglan escribiendo

Ordenados por gravedad. Cada uno con lo que el lector midió.

### Compuertas que no pueden salir del otro lado

1. **Q4, marcador del parche.** El runbook espera que `git grep -c
   pendiente_sonda` «devuelva 1 o más» y el fallback se dispara «en 0». Medido:
   con coincidencia imprime `archivo:N` y sale 0; **sin coincidencia no imprime
   nada y sale 1**. El esperado nunca se cumple literalmente y el fallback no
   puede dispararse jamás. Arreglo: compuerta por código de salida
   (`git grep -q … && echo SIN-SELLAR || echo SELLADO`), y decir en qué
   construcción del archivo tiene que aparecer el marcador, porque hoy un
   comentario lo satisface.
2. **Q4, precondición de rebase.** `git merge-base --is-ancestor origin/master
   HEAD` se cumple por construcción para cualquier rama recién creada desde
   `origin/master`, y nunca pregunta si el merge de B está dentro. Medido: sale
   `REBASADO` incluso parado en una rama que no tiene nada que ver con la fase.
   Arreglo: anclar al merge commit de Q3.
3. **Q1, colisión de migración.** La única compuerta que detecta un `0039`
   ajeno lee `origin/master` sin `fetch` previo, o sea la referencia de horas
   antes. Justo la fila de atores declara probable que otra sesión mergee.
   Arreglo: `fetch` antes, en la compuerta y en la regla 4.
4. **Q2, archivo de progreso.** La compuerta exige que el diff contenga «solo»
   rutas permitidas; si el entregable falta, la lista sigue conteniendo «solo»
   rutas permitidas y da verde sobre un entregable ausente. Arreglo: exigir la
   presencia, no solo la ausencia de intrusos.

### Cosas que matarían la corrida en el primer comando

5. **El `git push` de cada carril muere sin el entorno de Python.** El hook
   `pytest-pre-push` corre `tools/quality_run_python_tests.py`, que busca `uv`
   en el PATH (que un CLI en tmux no hereda) o `./.venv/bin/python` **relativo
   al worktree**. Un worktree recién creado no lo tiene. Está en la memoria del
   proyecto y no quedó escrito. Arreglo: enlazar el venv al crear cada
   worktree, y comprobarlo en el paso 0.0.
6. **`.saikit/` está en el `.gitignore` de Orbit** (línea 22; `.saikit/scratch/`
   en la 20). El archivo de progreso no se puede commitear sin `-f`, que el
   runbook no autoriza; el rojo de TDD que el loop exige en
   `.saikit/scratch/<carril>/tdd.md` tampoco entra al repo por diseño; y el
   carril A tiene `.saikit/**` en su columna «no toca», lo que le prohíbe
   escribir su propio rojo. Arreglo: declarar que todo lo de `.saikit/` es
   trabajo en curso que nunca se commitea, y sacar el archivo de progreso de la
   compuerta Q2.
7. **La precondición del kit no se comprueba entera.** El paso 0.0 lee
   `MANIFEST.sha256`, pero el loop exige además el hook instalado **por cada
   host que pueda ser lead** y probado con un merge de prueba una vez, y un
   veredicto sellado **desde la misma sesión viva, el mismo host y la misma
   ruta de proyecto** — y la cola mergea desde cuatro rutas distintas. Un lead
   en un host sin sello se entera en la cola, no al arranque.

### Contradicciones internas y con los documentos de arriba

8. **El carril D es Q2 en la cola y «el último de la cola» en la regla 10.**
9. **No hay PR de cierre y la fase no puede cerrarse sin él.** El loop manda
   cerrar las celdas de estado del plan con el SHA de squash; las
   preaprobaciones **niegan** editar el plan y ningún carril toca `plans/**`.
   Encima el CI corre `check_chat_context_fresh.py`, que truena si un PR marca
   `cc:完了` sin tocar `docs/CHAT-CONTEXT.md`, archivo que no está en ninguna
   tabla. Arreglo: un ítem Q5 con rama propia, sus archivos, su loop reducido y
   su comando de merge, y la preaprobación acotada a las celdas de estado.
10. **Quién hace el carril D.** El plan dice literalmente «(lead, solo
    lectura)»; el runbook dice «muse en los cuatro carriles». La regla de
    precedencia no lo resuelve porque «(lead…)» está dentro de la celda de la
    fila. Y la preaprobación del `ssh` no dice a quién se le concede.
11. **El archivo de candados pertenece a A.1 en la tabla del plan**, fila que
    esta fase no incluye; el runbook se lo asigna a B y luego a C. Hay que
    declarar la desviación.
12. **El carril C no puede cumplir su DoD dentro del presupuesto.** Sus tres
    candados viven en el archivo que no puede tocar hasta que B mergee (Q3),
    pero C es Q4: los agrega después de su aprobación, y el loop obliga a
    volver al paso 5 si el diff no es vacío. Son rondas extra que el inventario
    no presupuesta.
13. **`atencion_requerida` es objeto en el spec y booleano en el runbook**; y
    `paso_loop` está cerrado en 0–8 mientras el loop tiene once pasos: un
    carril que está mergeando no es representable.
14. **Dos rutas distintas para el archivo de progreso** (el checkout principal
    en la regla 10, el worktree del carril D en la compuerta) y ningún paso que
    las una.
15. **La precedencia no nombra al spec.** El runbook fija loop > plan >
    runbook; el plan declara una cadena de cinco niveles que incluye su spec
    por encima de sí mismo.
16. **El catálogo de mutantes que piden las DoD no tiene casa**:
    `docs/evidencia/**` está en «no toca» para B y C, y `.saikit/**` para A.
17. **El `BRIEF.md` de cada carril no aparece en ninguna tabla de archivos.**

### Cosas sin mecanismo escrito

18. **«El relay de claw»** para el aviso de cierre no tiene comando, canal,
    formato ni qué hacer si falla. Es el «vía X» sin mecanismo que la skill
    prohíbe. Agravante: el loop manda que la línea de CodeRabbit sin cuota vaya
    «en el Telegram», y el runbook declara que no hay Telegram.
19. **Cómo se lanza a muse**: no hay comando, ni nombre de sesión de tmux, ni
    cómo le llega el `BRIEF.md`, ni cómo vuelve su línea de contrato.
20. **`<pr>` aparece en las cuatro compuertas y nunca se define.** Y la
    compuerta Q3 es la única sin directorio de trabajo, con rutas relativas y
    llamando al Python del checkout principal, que está en otra rama.
21. **El comando de lectura del carril D no se puede teclear**:
    `… -tA' < <archivo.sql>` tiene un marcador nunca definido y el redirect así
    escrito no es shell válido; y esos `.sql` no tienen carpeta asignada.
22. **El runbook no está en git.** Vive sin trackear en
    `/Users/dn/dev/wt-fase8`, ruta que el propio documento no menciona. Si el
    lead muere, el que lo releva no tiene de dónde leerlo. Y si se mergeara a
    `main` de openclaw, eso **es** desplegar según el loop, con su ventana
    segura — justo la sección que el runbook declaró que no aplica.
23. **La tarea del tracker no se menciona.** El `CLAUDE.md` de Orbit lo hace
    obligatorio y el plan nombra `ORBIT 09` y `AUTO-07`.
24. **El candado léxico deniega más de lo que el runbook dice.** Medido dos de
    dos veces: el basename del script del kit dentro de un `echo`, con la ruta
    entera, devuelve `merge denied: … hash does not match the kit manifest`
    aunque el hash sí casa y aunque el comando no mergee nada. La regla real es
    que el basename no puede aparecer salvo como ruta absoluta resoluble, y el
    mensaje engaña porque dice «merge denied» para un `ls`.

## Verificado y correcto (no volver a gastar aquí)

Las seis salidas del paso 0.0 coinciden literalmente, incluida la línea de
`autopilot.json` con `"merge_despliega":"no"`. La última migración en
`origin/master` es `0038`, así que `0039` es el número correcto. El DSN
`postgresql://orbit:orbit@localhost:5432/postgres` es idéntico al de
`.github/workflows/quality.yml:76` y conecta. El check de CI se llama `quality`
y sale en las primeras tres líneas de `gh pr checks`. `-Excluir ''` sí está en
el conjunto válido de `cross-review.ps1:98`, y `-Alcance` solo acepta `staged`,
`working` y `last-commit`. Todos los binarios de ruta absoluta existen. No hay
Docker ni Colima en la Mac; PostgreSQL 16 de Homebrew responde. `orbit-app-1` y
`orbit-db-1` existen en `goncloud` y el `ssh` responde. `muse` y los seis hosts
del kit están en el PATH con sesiones de tmux vivas. No hay ramas `fase8/*` en
el remoto ni worktrees colisionando. Los tres candados del repo
(`test-runbooks-no-contradicen-entorno.sh`, `test-loop-autopilot.sh`,
`test-skill-autopilot-runbook.sh`) salen verdes con este runbook incluido.

## Qué haría falta para levantarlo

1. Que exista el tablero de progreso, o que la skill y el loop admitan una fase
   sin él y lo digan (B1). Corregir de paso la forma `--params @archivo` en el
   loop y en el spec, que hoy es incorrecta en los tres documentos.
2. Saber si muse trabaja en worktrees (B4). Es una pregunta de una línea y
   decide si la fase es paralela o secuencial.
3. Que D.3 de `fabrica-02` cierre, o que el dueño decida arrancar antes (B2).
4. Decidir si E.1, por ser solo lectura, está exenta de la ronda de cinco
   perspectivas de la fase E (B3).

Con esas cuatro, los 24 hallazgos de arriba son una tarde de redacción, no un
rediseño.

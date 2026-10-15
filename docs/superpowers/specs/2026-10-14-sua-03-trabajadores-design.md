# SUA-03, poteto y trabajadores especializados: diseño y corte en rebanadas

Fecha: 2026-10-14. Estado: diseño propuesto, sin código. Lo escribió el diseñador del bloque. Lo revisa el revisor asignado antes de implementar.

Bases leídas: G `origin/main` `97d35ab0`, en el worktree `~/dev/wt/sua-03-diseno` (rama `sua/03-diseno`). R `/Users/dn/dev/openclaw-agent-work-integration`, rama `feat/agent-work-integration`, HEAD `7b3db54226bf`, el que corre en la Mini desde SUA-02. Ningún comando de este documento se corrió contra la Mac mini. No se corrió opencode ni un encargo. Lo que dice de R sale de leer el código. Lo que dice de la Mini sale del repo, de `~/.local/state/` (en especial las lecturas P1 a P6 que corrió el coordinador el 2026-10-14, `~/.local/state/sua-loop/mediciones/sua03-p1-p6.txt`) y de la copia local de `goncloud-workspace-main` (sin `fetch`, del 2026-09-16), que sirve solo para la forma de los archivos. Lo que dice de opencode en esta Mac sale de leer `~/.config/opencode/` y `~/.agents/`, sin abrir ningún archivo de llaves.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-03" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md), con "Orden y dependencias", "Ensayos integrados" (I08, I09, I11, I18), "Regla de instalación en vivo" y "Decisiones de David vigentes".
- El [contrato](../../spec/sistema-agentes.v1.md) `sistema-agentes.v1`, en especial "Flota".
- Los diseños de [SUA-01](2026-10-13-sua-01-frontera-durable-design.md) y [SUA-02](2026-10-14-sua-02-controlador-design.md), y sus recibos.
- El [contrato histórico de flota](2026-10-04-flota-poteto-contract.md), secciones 8 y 9, como fuente de las obligaciones de poteto.

Palabras que este documento usa con un solo sentido. Las de SUA-01 y SUA-02 siguen igual.

| Palabra | Sentido |
|---|---|
| ruta | Una de las cinco formas de mandar trabajo: turno nativo, hijo nativo, encargo nativo a un agente, encargo por CLI (un proceso de opencode por encargo) e hijo de una CLI. |
| poteto | La skill `poteto-mode` de pstack con su carpeta (playbooks, references) y las skills `principle-*`, en una revisión fijada. |
| adaptación | El texto que traduce las herramientas que nombra poteto a las de un runtime. Hay dos: `opencode-run` y `openclaw`. |
| perfil | Una especialidad como datos: qué contratos de resultado admite, qué rutas la atienden, qué herramientas exige, qué skills lleva, si puede escribir fuente y su prueba de competencia. No es un agente. |
| paquete | Poteto, una adaptación, un perfil y las skills de ese perfil, con un manifiesto de digests. |
| generación | El número del paquete. Sube cuando cambia cualquier byte del paquete. |
| atestación | Un digest de lo que se entregó. Identifica contenido. No prueba que el modelo lo usó. |
| conducta | Lo que el trabajador hizo y que se lee después en sus eventos: qué archivos leyó, qué plan escribió, qué pruebas corrió. |
| banco | El arnés de `ruta_viva` con opencode real y un modelo real, en esta Mac, con su propio grupo y su propio Gateway de prueba. No toca la Mini ni el host vivo. |

## 1. Lo que existe hoy

### Las cinco rutas, por dónde entra el texto

- **Turno nativo.** R arma el prompt con los archivos de arranque del workspace del agente. Una sesión normal recibe todos (`filterBootstrapFilesForSession`, `src/agents/workspace.ts:1128-1146`).
- **Hijo nativo.** `sessions_spawn` llega a `spawnSubagentDirect` y a `runSpawnPipeline` (`src/agents/spawn-pipeline.ts:73`). Una sesión de subagente recibe solo `AGENTS.md` (`SUBAGENT_BOOTSTRAP_ALLOWLIST`, `workspace.ts:1085`, aplicado en `:1141-1143`). La fila de `subagent_runs` guarda el modelo resuelto y el solicitante: el registro lleva `model: resolvedModel`, `agentId`, `requesterAgentId` y `workspaceDir` (`src/agents/subagents/spawn/subagent-spawn.ts:557-575`), y se guarda en `payload_json` (`src/state/openclaw-state-schema.sql:2042-2051`).
- **Encargo nativo a un agente.** `admitManagedTask` lee la instrucción, comprueba su digest y llama a `spawnSubagentDirect` con `task: instruction`, `agentId` del destino y `context: "isolated"` (`src/agents/tasks/managed-task.admit.ts:51-56` y `:108-123`). El hijo es una sesión de subagente del agente destino. Le llega el brief y el `AGENTS.md` de ese agente, nada más. Ningún pedido real pasó por aquí (`SUA-00-inventario.md`, "Rutas nativas"). Solo `main`, `ingenieria` e `implementer` pueden recibirlo: los agentes con primario `opencode-go/deepseek-v4.1-flash` (`adversary`, `operaciones`, `reviewer`, `verifier`, `scout`) pasan por un plugin, y R rechaza un plugin dentro de un encargo (`docs/evidence/agent-work/T12-runbook.md:11`). Solo `main` puede pedirlo: `managedTasks.requesters` es `["main"]` en vivo (P1).
- **Encargo por CLI.** El host lanza `opencode run -m <modelo> --format json --print-logs --log-level INFO` con una sola línea de entrega (`opencode_argv`, `scripts/agent-work/sesion.py:205-213`; `delivery_line`, `host.py:74-78`). El entorno lo arma `opencode_env` (`sesion.py:216-241`): `PWD`, `TMPDIR`, y un `OPENCODE_CONFIG_CONTENT` con `external_directory` (`"*": "deny"` y la carpeta de la corrida en `allow`), `enabled_providers` con el proveedor del encargo y `small_model`. El brief es el único texto que el host entrega.
- **Hijo de una CLI.** opencode puede abrir subagentes con su herramienta `task` y procesos con `bash`. El host no los modela. El barrido del grupo los cierra (`GroupBoundaryBackend`, `sesion.py:453`). Que el grupo es una frontera lo midió M4 de `B22-fase0.md`, con `newgrp` dentro de tmux. En el canario A, intento 1, el grupo tenía un hijo `tracker.js sync` del plugin tokentracker (`B22-canarios.md:219`).

### Poteto hoy

- **En la Mini no hay poteto.** Ninguno de los 19 `AGENTS.md` vivos nombra `poteto` (P2: `poteto=0` en los 19). La copia local de `goncloud-workspace-main` tampoco lo nombra en `SOUL.md`, `USER.md`, `MEMORY.md` ni `skills/`. Tampoco ninguna skill de `agents/*/agent/workshop-skills/` de G, salvo una mención de pstack en `ingenieria/mac-node-ops/SKILL.md:65` que habla de cursor-agent.
- **En los encargos por CLI, poteto llega roto.** `~/.config/opencode/AGENTS.md` de David dice: antes de seguir una skill de pstack, lee `~/.agents/pstack-plataformas/opencode.md`. Ese archivo está fuera de la carpeta de la corrida. En el estreno de grok, la primera llamada del modelo leyó ese archivo; opencode lo negó y la sesión terminó sin acuse; con la regla `deny` ya no tira el encargo, pero el modelo trabaja sin la adaptación (`B22-canarios.md:136`; `followups.md`, fila B22-S8). Las skills de pstack que ve opencode son enlaces de `~/.agents/skills/` al checkout `~/dev/pstack-claude` (0.9.30, `006819d`). Los playbooks y las referencias que poteto manda abrir viven en esa carpeta, fuera de la corrida.
- **Dos revisiones de pstack en esta Mac.** Claude Code tiene instalada 0.9.84, commit `990cd7b0` (`~/.claude/plugins/installed_plugins.json`). opencode usa 0.9.30. El `SKILL.md` de `poteto-mode` difiere entre las dos (sha256 `af65d662…` contra `40cd8f44…`).
- **Los siete perfiles locales de opencode** son `comment-sicko`, `panel-glm47`, `panel-glm52`, `panel-glm53`, `panel-glm5turbo`, `poteto-agent` y `poteto-agent-rapido`, en `~/.config/opencode/agent/`. Ninguno declara `permission`. Los siete fijan un modelo `zai-coding-plan/*`. `pstack-plataformas/opencode.md:7` dice "Solo `zai-coding-plan/*`… No pases otro modelo", y `~/.config/opencode/AGENTS.md:3` dice lo mismo. La política de encargos admite ocho proveedores (`proveedores-permitidos.json`). Con `enabled_providers` de otro proveedor, un `task` a uno de esos perfiles pide un proveedor apagado (`unknown` 2).

### Lo que el host ya lee de una corrida

`read_events` (`sesion.py:334-385`) lee el flujo JSON y los logs. De los logs saca los permisos negados (`DENIED_LINE` y `message=evaluated … action.action=deny`), la carpeta de la sesión y el proveedor de cada llamada (`message=stream` con `providerID`, `:376-377`). La misma línea de log trae también `modelID`, `small` y `agent` (`B22-fase0.md:146-147`: `providerID=zai-coding-plan modelID=glm-5.3-flash … small=false agent=build`). Hoy nada lee `modelID`. `encargo.py estado --tarea` dice que `modelo` es "el que corrió de verdad", pero lo saca del `-m` de `argv.json` (`encargo.py:263-265`): es el pedido, no el usado. En el canario B el proveedor rechazó el modelo pedido y `estado` siguió diciendo ese modelo (`B22-canarios.md`, canario B).

### El revisor por CLI no puede entregar sin escribir en el repo

El protocolo le pide al CLI que `artifactRef` sea "the absolute path of the artifact file, inside workspaceRef" (`cli_protocol`, `host.py:106`). El host lo comprueba con `under(result["artifactRef"], assignment["workspaceRef"])` (`host.py:343`). La skill `encargo-cli` pide para una revisión `{"verdict": "changes", "findingsRef": "<archivo>"}` con un archivo relativo al repo. Un revisor que obedece deja un archivo nuevo en el repo, y `git status --porcelain` deja de estar vacío. El paso 6 del plan certifica justo eso.

### Lo que los especialistas tienen hoy

- La Mini tiene 19 agentes (`openclaw agents list --json`, P1; `config.get` no trae `agents.list`): `main`, `operaciones`, `ingenieria`, `implementer`, `reviewer`, `adversary`, `verifier`, `scout`, `amazon`, `pers`, `meli`, `mail`, `limpia`, `odoo`, `arras`, `gonserver`, `skillverif`, `tinkabot` y `eggbot`. Ninguno tiene filtro de skills (`skills: null`). `main`, `ingenieria` e `implementer` corren `opencode-go-resp/muse-spark-1.3-contributor`; los otros dieciséis, `opencode-go/deepseek-v4.1-flash`.
- G solo conocía ocho (`coverage.json`, `requesters`) y `usuario` (`agents/usuario/agent/AGENTS.md`), que no está en la lista viva.
- Amazon, Meli, mail y Odoo son agentes propios en la Mini, no solo trabajos de `operaciones`. `main` ya les abre hijos: las cinco últimas filas de `subagent_runs` son hijos de `mail` y de `odoo` pedidos por `agent:main:main` (P5). La copia local de `goncloud-workspace-operaciones`, del 11 de septiembre, todavía describe a `operaciones` como dueño de "MercadoLibre, Amazon, mails, reportes y Odoo" (`SOUL.md:30`). Las skills de dominio que G tiene están en `agents/operaciones/agent/workshop-skills/` (`sellercentral-browser-census`, `gmail-compose-rich-mail`, `packing-baseline-html-pair`).
- No existe ningún archivo de perfiles. `workers.v1.json`, `registry.py` y `selector.py` se retiraron (PR #291).

### Dónde carga OpenClaw sus skills

Por orden, para un agente: `skills.load.extraDirs`, las de plugins, las empaquetadas, el directorio de workshop del agente, el directorio administrado `~/.openclaw/skills` y `~/.agents/skills` (`resolveWorkspaceSkillSourcePlan`, `src/skills/loading/workspace-skill-sources.ts:97-135`), más las del workspace. El de workshop lo revisa OpenClaw cada semana ("The weekly collection review manages the skill collection", `src/skills/workshop/curator.ts:24-25`). El código de `src/skills/workshop/` solo nombra el directorio de workshop (`collection-restore.ts:45`), no el administrado. El prompt de skills no se quita en una sesión de hijo: solo con `toolPolicyRestricted` (`src/agents/embedded-agent-runner/run/attempt-system-prompt-prepare.ts:161-162`). En la Mini, `~/.openclaw/skills` tiene `grok` y `navegacion-estable`, y `~/.agents/skills` no existe (P3). Ningún nombre choca con poteto.

### Lo que opencode acepta en su configuración

El esquema de la SDK instalada (`~/.config/opencode/node_modules/@opencode-ai/sdk`, versión 1.18.25, `dist/v2/gen/types.gen.d.ts:1517-1640`) tiene `instructions` (lista de archivos), `skills.paths`, `agent.<nombre>` con `model`, `prompt`, `permission` y `disable`, `permission` con `edit`, `bash`, `task`, `skill` y `external_directory`, y `subagent_depth`. Que opencode 1.18.35 los aplique desde `OPENCODE_CONFIG_CONTENT` no está medido (`unknown` 1).

### Lo que dejaron SUA-02 y SUA-00 para este bloque

- SUA-02, "Lo que no entra": `flota.v1`, los permisos efectivos del trabajador por CLI y que el host distinga una sesión vencida del proveedor, que según el diseño de SUA-02 hoy llega como `launch-refused` (su sección 7 y la tabla de 4.5, `AUTH_VENCIDA` y `SIN_CUOTA`). Un rechazo del proveedor medido llegó como `launch-failed` (canario B, `B22-canarios.md:65`).
- SUA-02, conflicto 5: SUA-05 comprueba que un relevo usa otro modelo con el `flota.v1` de SUA-03.
- `followups.md`, fila "SUA-00 (`coverage.json` desfasado)": "SUA-03: decidir qué pasa con los siete adaptadores".
- `followups.md`, filas "SUA-02/pruebas inestables" y "SUA-02/residuales". Ninguna es de SUA-03 (sección 4.10).

## 2. Lo que falta, punto por punto contra el bloque

| Pide el bloque | Hoy | Lo que falta | Dónde |
|---|---|---|---|
| Paso 1. Poteto canónico, perfil, skills y evidencia por tarea | No hay poteto en la Mini. En opencode llega roto (B22-S8) | Un paquete fijado con digests, sus dos adaptaciones y su entrega por ruta | 4.2, 4.3 |
| Paso 1. Preservar memoria y archivos del usuario | Nada escribe en los workspaces | Un publicador que solo toca un bloque marcado de `AGENTS.md` y nombres administrados, con CAS y reversa | 4.3 |
| Paso 1. Versionar contenido y adaptación | Nada | `generation` y manifiesto | 4.2 |
| Paso 2. Certificar las cinco rutas | Solo la ruta por CLI, como ruta (`hostAdapterRoute`) | Entrega y conducta por ruta, con canario | 4.5, 5 |
| Paso 2. Permisos efectivos y herramientas del procedimiento | `permisosNegados` | Los permitidos también, y la comprobación de herramientas exigidas antes de lanzar | 4.6 |
| Paso 3. Perfiles de todas las especialidades | Ninguno | Once perfiles como datos, con prueba de competencia positiva y negativa, y siete agentes descubiertos sin perfil, visibles como incompletos | 4.4 |
| Paso 4. OpenCode con los siete perfiles locales, shell, hijos y modelo | Los siete fijan `zai-coding-plan` y no tienen permisos | La configuración por corrida que les pone el modelo del encargo y los permisos del perfil | 4.3, 4.6 |
| Paso 4. `flota.v1` por intento | Solo el contrato y seis fixtures | Un documento por intento, escrito por el host para la ruta por CLI y por un lector para el encargo nativo | 4.7 |
| Paso 5. Modelo efectivo | `estado` da el `-m` pedido | Leer `modelID` de los logs y compararlo con `argv.json` | 4.7 |
| Paso 6. El reviewer no escribe fuente | El protocolo obliga a escribir el artefacto en el repo | El revisor trabaja en un clon desechable dentro de la corrida, su artefacto va a la corrida, y el repo real se fotografía antes y después | 4.8 |
| Verificar. Quitar poteto, dejar escribir al reviewer o negar una herramienta del hijo impide la admisión | Nada lo comprueba | Rechazos en `plan_launch` y certificación de ruta por generación en la ruta por CLI; en las nativas, aplazado a SUA-04 | 4.5, 4.6 |
| Verificar. Meli pasa la suya y rechaza una ajena; skill irrelevante no entra; memoria sobrevive | Nada | Admisión por perfil, sondas de competencia, paquete con la lista exacta, prueba del publicador | 4.4, 5 |
| I18. Advisor con y sin eventos declara cobertura; caída no aprueba | No hay advisor | `cobertura` en el perfil; una revisión caída no deja veredicto | 4.4, 5 |
| Claude como trabajador | Fuera de la ruta por CLI (B22-S5) | Nada en SUA-03 | 4.9 |
| Residuales de SUA-02 y SUA-00 | Tres de SUA-02 y uno de SUA-00 | Dos entran enteros, uno a medias; el de SUA-00 sigue en SUA-04 | 4.10 |

## 3. Dos formas de entregar poteto y perfil, comparadas

Las dos parten de lo mismo: un paquete fijado en G con su manifiesto de digests. Difieren en dónde vive la copia que lee el trabajador.

### Forma A: el paquete vive en el entorno de cada ejecutor

Se instala una vez por host. En la Mini, poteto va a las skills de los agentes y una regla corta va a cada `AGENTS.md`. En esta Mac, poteto ya está en `~/.agents/skills/` y la regla en `~/.config/opencode/AGENTS.md`. El brief solo nombra el perfil.

### Forma B: el paquete viaja con cada intento

Cada intento lleva su copia. En la ruta por CLI, el host copia el paquete a `runs/<op>/contexto/` y se lo da a opencode por su configuración. En las rutas nativas, el brief llevaría el paquete entero, o R lo montaría como adjunto del hijo.

### Comparación

| Criterio | A, en el entorno | B, por intento |
|---|---|---|
| **Ruta por CLI** | No funciona sin cambiar archivos de David. La regla `external_directory` niega leer `~/.agents` (B22-S8, medido), y los playbooks viven ahí. Arreglarlo es abrir esa carpeta en `allow`, que también deja escribir en ella | Funciona con lo que ya se mide. La carpeta de la corrida es la única permitida, y lo que el host copia ahí se lee |
| **Rutas nativas** | Funciona sin R. El hijo y el encargo nativo reciben `AGENTS.md` del agente destino (`workspace.ts:1085`), y las skills administradas se cargan para cualquier sesión (`workspace-skill-sources.ts:97-135`) | No funciona sin R. `admitManagedTask` no pasa adjuntos (`managed-task.admit.ts:108-123`). Meter poteto en el brief cabe (unos 240 KB contra el tope de 1 MB de `brief.py`, `MAX_INSTRUCTION_BYTES`), pero el brief es el mensaje del hijo: son unos 240 KB de contexto en cada encargo, y los playbooks dejan de ser archivos que poteto manda abrir |
| **Snapshot del intento** (paso 5, "un intento nuevo conserva su snapshot") | El intento ve lo que haya en el entorno cuando corre. Un cambio de generación a media corrida le cambia el texto | La copia es del intento. Un intento nuevo tiene su propia carpeta y su propio digest |
| **Archivos de David** | Habría que editar su `~/.config/opencode/AGENTS.md`, sus siete agentes y `pstack-plataformas`, que usa a diario | No se tocan en la ruta por CLI. La configuración por corrida pisa lo que hace falta solo dentro de esa corrida |
| **Coste por turno** | Una regla de pocas líneas en cada `AGENTS.md`. Las skills solo se cargan si se leen | En la ruta por CLI, una copia de unos 250 KB en disco por corrida, que solo se lee si el modelo la abre. En las nativas, los 240 KB en el contexto de cada encargo |
| **Qué prueba la atestación** | Que el entorno tiene el contenido. No que el intento lo recibió | Que el intento recibió esa copia |

### Elección

Se elige **B en la ruta por CLI y A en las rutas nativas**. La razón que decide está en las dos primeras filas. En la ruta por CLI, A choca con la guarda medida y con los archivos de David. En las nativas, B exige cambiar R para un camino que ningún pedido real usa todavía, y A ya llega por los dos canales que R da a un hijo (su `AGENTS.md` y las skills).

Las dos mitades comparten el mismo paquete y el mismo manifiesto. Lo que cambia es el transporte. El hijo de una CLI sigue a su padre: lee lo que el host puso en la corrida.

Los bocetos son del diseñador. No se pidieron bocetos a otros modelos.

## 4. El diseño elegido

Una frase lo resume. G fija un paquete de poteto y once perfiles como datos, el host de encargos lo copia a cada corrida y lo exige antes de lanzar, un publicador lo pone en la Mini sin tocar memoria, y cada intento deja un `flota.v1` con lo que se lanzó de verdad.

### 4.1 Dónde vive cada pieza

| Pieza | Repo y archivo | Corre en | Por qué ahí |
|---|---|---|---|
| Manifiesto de poteto | G, `scripts/agent-work/contexto/poteto.v1.json` | Lo leen el host y el publicador | Fija revisión y digests en el repo dueño del dato |
| Perfiles | G, `scripts/agent-work/contexto/perfiles.v1.json` | Host, `encargo.py`, publicador | Son política, como `proveedores-permitidos.json` |
| Adaptaciones y bloque | G, `scripts/agent-work/contexto/{adaptacion-opencode-run.md,adaptacion-openclaw.md,bloque-agents.md}` | Copiados a cada destino | Texto entregado, versionado con el manifiesto |
| Fixtures de competencia | G, `scripts/agent-work/contexto/competencia/<perfil>/` | Banco y sondas nativas | Datos de prueba, sin efectos reales |
| Constructor del paquete | G, `scripts/agent-work/contexto.py`, puro salvo una frontera de lectura | Mac (host) y Mac (publicador) | Lo usan el host y el publicador; un solo constructor |
| Lanzamiento con contexto | G, `sesion.py` (`LaunchHeader`, `plan_launch`, `opencode_env`, `Route.open_for`), `native_gateway.py` | Mac, host vivo | Es donde nace la corrida |
| Lectura del intento y `flota.v1` | G, `sesion.py` (`read_events`), `scripts/agent-work/flota.py`, `encargo.py estado` | Mac, host vivo | El host es el único que ve argv y logs |
| Revisor sin escritura | G, `host.py` (`report`, `cli_protocol`) y `native_gateway.py` (foto del repo) | Mac, host vivo | El host acepta o rechaza el resultado |
| Lector de conducta | G, `scripts/agent-work/conducta.py` | Mac, sobre eventos de opencode o un extracto de la Mini | Una sola regla para el banco y para las sondas nativas |
| `brief.py --perfil` | G, `scripts/agent-work/brief.py` | Mini, copia en `~/.local/share/agent-work/` | Ahí escribe `main` sus briefs |
| Publicador nativo | G, `scripts/agent-work/publicar-contexto.py` | Mac, por ssh a la Mini | Como los `t12-*` de SUA-01 |
| Skill `encargo-cli` | G, `agents/main/agent/workshop-skills/encargo-cli/SKILL.md` | Mini, publicada | Ahí aprende `main` a pedir perfil |
| Certificación por ruta | G, `docs/evidence/agent-work/coverage.json` (`hostAdapterRoute.mac-local.opencode.contextGenerations` y `routes`) | Lo lee `Route.load` | SUA-04 parte de este archivo (plan, SUA-04 paso 3) |
| R | Nada | | Sección 4.12 |

Los módulos nuevos de G entran al `include` de `ruff.toml` y al `files` de los hooks `ruff-check` y `ruff-format` en el mismo PR que los crea ("Preparación antes de SUA-01", punto 6).

Lo que corre en la Mini: la copia de `brief.py`, la skill `encargo-cli`, las skills administradas, el bloque de cada `AGENTS.md` y `perfiles.v1.json`. Ningún proceso nuevo y ningún cambio de configuración del gateway.

### 4.2 El paquete y su versión

**Fuente.** pstack en el commit que Claude Code tiene instalado al construir la generación (`~/.claude/plugins/installed_plugins.json`, hoy `990cd7b0`, 0.9.84). El manifiesto guarda repo, commit, versión y el sha256 de cada archivo copiado. El constructor se niega si un archivo de la fuente no coincide. La copia de `~/dev/pstack-claude` (0.9.30) es material por comparar, como pide el contrato histórico de flota (sección 8), salvo lo que diga el `unknown` 1, punto b.

**Contenido de una generación.**
- `poteto-mode/` entero menos `scripts/` (playbooks y references incluidos), y las `principle-*`.
- Las skills que nombra cada perfil, una por una. No se calcula una clausura: el perfil la escribe y el constructor comprueba que cada nombre exista en la fuente.
- Las dos adaptaciones y el bloque de `AGENTS.md`.
- La skill `poteto-openclaw`, que es `adaptacion-openclaw.md` con su cabecera de skill. Sus bytes están en el manifiesto como un archivo más: no se publica nada en las rutas nativas fuera de una generación.

En 0.9.84, `poteto-mode` sin `scripts/` son 207 509 bytes y las `principle-*` 34 877.

**Manifiesto** (`poteto.v1.json`): `generation`, `source {repo, commit, version}`, `files [{path, sha256}]`, `adaptations {opencode-run, openclaw}` con su sha256, `block`, el sha256 de la plantilla del bloque de `AGENTS.md`, y `digest`, el sha256 del manifiesto canónico sin el campo `digest`. Cambiar un byte de cualquier archivo cambia `digest` y obliga a subir `generation`. `contexto/generaciones.json` fija el digest de cada generación. Una prueba lo fija: el mismo manifiesto con otro contenido y la misma `generation` es un error.

**Adaptación `opencode-run`.** Corta. Dice que las skills están en `<corrida>/contexto/skills` y se cargan con `skill`; que `task` sirve con los agentes que esta corrida deja; que `todowrite` es la lista del playbook; que las reglas de modelos y de agentes de `~/.config/opencode/AGENTS.md` no valen en un encargo, porque el modelo lo eligió el host; y que una skill que no está en el paquete no está disponible, y eso se dice en el resultado.

**Adaptación `openclaw`.** Las equivalencias de OpenClaw: leer una skill con `read` en su ruta, delegar con `sessions_spawn`, la lista del playbook con `progress_card` (el catálogo de R ya no tiene `update_plan`: es un alias que gobierna `progress_card`, `src/agents/tool-policy.ts:67-68`), correr con `exec`. Los nombres salen del catálogo de R (`src/agents/tool-catalog.ts`), porque la lectura de `tools.effective` de P4 quedó cortada.

**Bloque de `AGENTS.md`.** Pocas líneas entre dos marcas: `<!-- sua-contexto inicio generación=<n> digest=sha256:<hex> -->` y `<!-- sua-contexto fin -->`. Dice: para trabajo de ingeniería, revisión o verificación, lee `poteto-openclaw` y luego `poteto-mode` antes de usar otra herramienta; si el brief trae `profile: <id>`, ese manda; al delegar con `sessions_spawn`, empieza el `task` con el `profile: <id>` del pedido, si lo trae.

El bloque tiene dos formas, según el agente. El perfil por omisión de un agente es el único perfil de `perfiles.v1.json` cuyas `routes` nombran ese `agentId`. Si hay exactamente uno, el bloque agrega la línea "tu perfil por omisión es `<id>`". Si hay cero o más de uno, el bloque no la lleva y dice en su lugar "no tienes perfil por omisión: sin `profile` en el pedido, trabaja sin perfil y dilo en tu resultado". Es el caso de los siete agentes `sin-perfil` (4.4). No hay centinela: en las rutas nativas no corre `plan_launch`, y en la ruta por CLI un brief sin `profile` ya es `perfil-ausente`.

### 4.3 Cómo llega a cada ruta

| Ruta | Transporte | Qué se atesta |
|---|---|---|
| Turno nativo | El bloque en `AGENTS.md` del agente y las skills en `~/.openclaw/skills/` | El digest del bloque y del manifiesto administrado, releídos en la Mini |
| Hijo nativo | El mismo `AGENTS.md`, que es el único archivo de arranque del hijo (`workspace.ts:1085`), y las mismas skills | Lo mismo, más la lectura de la skill en los eventos del hijo |
| Encargo nativo a un agente | El `AGENTS.md` y las skills del agente destino. El perfil va dentro del brief: `brief.py --perfil <id>` con destino agente escribe la cabecera y el texto del perfil, así el digest de `instructionRef` los cubre | El digest de la sección de perfil del brief y el del manifiesto administrado |
| Encargo por CLI | `runs/<op>/contexto/`, copiada por el host antes de lanzar. `OPENCODE_CONFIG_CONTENT` gana `instructions: ["<corrida>/contexto/AGENTS.md"]`, `skills.paths: ["<corrida>/contexto/skills"]`, `agent.<cada uno de los siete>.model` igual al modelo del encargo, y los permisos del perfil (4.6) | El digest del paquete copiado, releído después de la corrida |
| Hijo de una CLI | Lo que su padre tiene en la corrida. `agent.<nombre>.model` hace que el hijo corra el modelo del encargo, dentro de `enabled_providers` | Las líneas `message=stream` con `agent=<hijo>` y su `modelID` |

La copia de la corrida es de la corrida. Un intento nuevo es otra operación, otra carpeta y otro digest (`operation_id` incluye `generation`, `contracts.py:19-21`). Así se cumple "un intento nuevo conserva su snapshot" sin mecanismo nuevo. Si el digest de la copia cambió al terminar, porque el modelo la editó, `estado` lo dice y `flota.v1` conserva el digest de antes de lanzar.

**Sin pisar memoria ni archivos de David.** El publicador nativo solo escribe en tres sitios: el bloque marcado de cada `AGENTS.md`, los nombres de skills que su manifiesto administra dentro de `~/.openclaw/skills/` (más `~/.openclaw/skills/.sua-contexto.json`), y `~/.local/share/agent-work/perfiles.v1.json`. Nunca escribe `MEMORY.md`, `memory/`, `USER.md`, `SOUL.md`, `IDENTITY.md`, `DREAMS.md` ni el directorio de workshop.
- **CAS.** `--leer` guarda el sha256 de cada `AGENTS.md` entero. `--aplicar` lo vuelve a leer justo antes de escribir y lo compara con lo que vio `--leer`: si cambió, aunque sea fuera del bloque, ese agente queda en conflicto y no se escribe. Sin bloque, lo agrega al final; con bloque, comprueba además que su contenido tenga el digest de la generación anterior según `.sua-contexto.json`; si no, alguien lo editó y ese agente queda en conflicto. Para cada skill administrada: si existe y no está en el manifiesto anterior, no es nuestra y se para.
- **Escritura.** Copia de respaldo del archivo entero, escritura en un temporal de la misma carpeta y `rename`. Relectura del digest después, que queda en `.sua-contexto.json` como el digest publicado de ese archivo.
- **Reversa.** `--revertir` compara primero cada archivo con su digest publicado. Si un `AGENTS.md` o una skill administrada cambió después de `--aplicar`, porque David o el agente la editó, ese archivo queda en conflicto, no se toca, y la reversa lo nombra para que se resuelva a mano. Los que siguen iguales vuelven al respaldo de cada `AGENTS.md` y a la generación anterior de las skills, que el publicador conserva en `~/.openclaw/sua-contexto/<generación>/`. Para la generación 1, la reversa quita el bloque y las skills administradas.
- **Lista de agentes.** Sale de `openclaw agents list --json` en la Mini, con su `workspace` (P1), no de una lista escrita en G. Hoy son 19.

En esta Mac, la ruta por CLI no toca `~/.config/opencode/` ni `~/.agents/`. La configuración por corrida solo vale dentro de esa corrida.

### 4.4 Los perfiles

**Los descubiertos.** Once. Ninguno se deduce del nombre de un agente. Cada uno dice qué rutas lo atienden, y eso sale de lo medido.

| Perfil | Contratos | Rutas que lo atienden | Escribe fuente | Fuente del hallazgo |
|---|---|---|---|---|
| `ingenieria` | `ready.v1` | CLI; nativo `ingenieria`, `implementer` | Sí | Agentes y skills de G |
| `revision` | `review.v1` | CLI; nativo `reviewer` solo como hijo o turno | No | Plan, paso 6 |
| `adversario` | `review.v1` | CLI; nativo `adversary` solo como hijo o turno | No | `coverage.json`, ruta `ingenieria → adversary` |
| `verificacion` | `review.v1` | CLI; nativo `verifier` solo como hijo o turno | No | Agente `verifier` y sus skills |
| `exploracion` | `ready.v1` | CLI; nativo `scout` solo como hijo o turno | No | Agente `scout` |
| `aceptacion` | `review.v1` | Ninguna hoy: `usuario` no está en la lista viva (P1) | No | `agents/usuario/agent/AGENTS.md` de G |
| `operaciones` | `ready.v1` | Nativo `operaciones`, turno o hijo | No en repos | `IDENTITY.md` de `operaciones` |
| `amazon` | `ready.v1` | Nativo `amazon`, turno o hijo | No en repos | Agente `amazon` (P1); `sellercentral-browser-census` |
| `meli` | `ready.v1` | Nativo `meli`, turno o hijo | No en repos | Agente `meli` (P1) |
| `mail` | `ready.v1` | Nativo `mail`, turno o hijo | No en repos | Agente `mail` (P1); hijos de `main` en `subagent_runs` (P5) |
| `odoo` | `ready.v1` | Nativo `odoo`, turno o hijo | No en repos | Agente `odoo` (P1); hijos de `main` en `subagent_runs` (P5) |

"Solo como hijo o turno" es lo medido: esos agentes no reciben un encargo nativo porque su primario pasa por un plugin (`T12-runbook.md:11`, y P1 da `opencode-go/deepseek-v4.1-flash` a los dieciséis). Amazon, Meli, mail y Odoo no se atienden por CLI: necesitan el navegador y las cuentas de la Mini. `main` no es un perfil de trabajador: es el solicitante. `aceptacion` queda con su ruta vacía: es un perfil incompleto y visible.

**Agentes descubiertos sin perfil.** `pers`, `limpia`, `arras`, `gonserver`, `skillverif`, `tinkabot` y `eggbot`. Su rol no se deduce del nombre. Quedan en `perfiles.v1.json` como `{"agentId": …, "status": "sin-perfil"}`, y `encargo.py perfiles` los lista así. Reciben el bloque y poteto como cualquier agente, porque el publicador no elige por rol, pero su bloque va sin perfil por omisión (4.2). Su perfil lo escribe quien lea su `AGENTS.md`, en SUA-04 (altas).

**Campos de cada perfil** (`perfiles.v1.json`): `id`, `purpose`, `resultContracts`, `routes` (lista de `{host, executor, agentId, via}`, con `via` entre `turn`, `child` y `task`: cómo llega el trabajo a esa ruta), `writesSource`, `requiredTools` por runtime, `skills` (nombres exactos del paquete), `sources` con `ref`, `revision` y `validUntil`, `coverage` (`checkpoint-only` o `events`) y `competence` por ruta, con llave `host/executor[/agentId]`: `{status, model, evidence, at, validUntil}`. Una fuente vencida contesta `perfil-sin-competencia`, con la fuente en la frase.

**Lo que distingue un perfil de otro** es la admisión, no el nombre. En SUA-03 la admisión por encargo solo existe en la ruta por CLI (4.5). En las rutas nativas, `competence` queda registrada para que SUA-04 la lea al elegir. Un encargo con `profile: meli` por CLI se rechaza porque `meli` no lista la ruta CLI. Un `review.v1` con `profile: ingenieria` se rechaza porque `ingenieria` solo admite `ready.v1`. Un perfil sin `competence.status: passed` en esa ruta se rechaza, salvo en modo canario. Una fuente con `validUntil` vencido deja el perfil sin admitir hasta refrescarla, y no toca a los demás.

**"Meli pasa su tarea y rechaza una ajena".** Tiene dos mitades.
- La mitad determinista es la admisión de arriba, con prueba unitaria: `admite(meli, ruta nativa meli, ready.v1)` pasa; `admite(meli, cli, ready.v1)` contesta `perfil-no-atiende-ruta`.
- La mitad de competencia es una sonda con fixtures. Positiva: un pedido de MercadoLibre de fixture, sin cuentas, con su respuesta esperada literal (por ejemplo, qué pedidos están demorados). Negativa: un pedido de personalización de Amazon de fixture, que el perfil Meli debe rechazar con la marca `FUERA-DE-PERFIL` y sin hacerlo. Las dos corren en la ruta que atiende al perfil, un turno del agente `meli` (sección 5, "Las sondas de competencia"). Lo mismo, con sus fixtures, para cada perfil.

**Skill irrelevante no entra.** El paquete de un perfil lleva poteto y exactamente las skills de su campo `skills`. Una prueba lo fija con una lista literal por perfil. En las rutas nativas, el agente conserva sus propias skills de workshop: son suyas, no de SUA. Lo que SUA agrega es solo poteto y su adaptación.

**I18, el advisor.** Hoy no hay un flujo de eventos que un advisor pueda leer en vivo. `adversario` y `revision` declaran `coverage: checkpoint-only`: leen el artefacto en un punto, no el flujo. `events` queda en el enum y ningún perfil lo usa. Un advisor caído no aprueba: sin `result.json` no hay resultado, el host deja una incidencia (`launch-failed`, `session-closed` o `deadline`) y en R la tarea no tiene veredicto. Ningún resultado de `review.v1` crea tareas: solo trae `verdict` (`managed-task.json.ts:100-104`, citado en el contrato).

### 4.5 La compuerta de admisión

"Ausencia impide admitir la ruta" se cumple en dos niveles.

**Por ruta, en la ruta por CLI: la aplica el host.** `coverage.json` gana, bajo `hostAdapterRoute.mac-local.opencode`, `contextGenerations: {"<n>": "<evidencia>"}`, como `certifiedCliVersions`. `Route.open_for` (`sesion.py:149`), que el host usa en cada reclamo (`RunHost.plan` carga la ruta en `native_gateway.py:516` y `plan_launch` la abre), abre solo si la versión de opencode y la generación del paquete están certificadas, salvo en `--canario`. Una generación sin certificar se rechaza antes de lanzar con su propia causa, `generacion-no-certificada`: un rechazo nuevo `GenerationNotCertified(generation, certified)` en `modelos.py`, con su frase en la tabla de `explicar` ("El paquete de poteto de la generación `<n>` no está certificado para encargos; certificadas: `<lista>`."). `ruta-no-certificada` y `_frase_ruta` (`modelos.py:715-720`) siguen hablando solo de la versión de opencode. `encargo.py preparar` usa la misma función (`encargo.py:175`) y lo dice en el mismo turno.

**Por ruta, en las rutas nativas: aplazado a SUA-04.** En SUA-03 ningún componente rechaza una generación nativa sin certificar. R no la conoce (4.11, conflicto 4), y el turno, el hijo y el encargo nativo los lanza R o el modelo de `main`, no un código de G que pueda negarse. Las rutas nativas se registran en `coverage.json` `routes` con su generación y su evidencia (rebanada G5), y la compuerta que las rechaza es el selector de SUA-04, que elige ruta leyendo ese archivo. Por eso el recibo de SUA-03 dice: I08 se cumple para la ruta por CLI y el hijo de una CLI; para las tres rutas nativas, entrega y conducta quedan certificadas, y "la ausencia impide admitir la ruta" queda aplazada a SUA-04. No dice que I08 se cumple en las nativas.

**Por encargo, en la ruta por CLI.** Todos estos rechazos ocurren antes de lanzar. Siete los decide `plan_launch` (`sesion.py:177-195`), que sigue siendo puro: recibe el paquete ya leído y no escribe en la corrida. `contexto-incompleto` sale de las dos fronteras con disco: `RunHost.plan` lee la fuente con `contexto.py` y compara cada archivo con el manifiesto antes de llamar a `plan_launch`; y el paso de lanzamiento de `claim_run_once` (`native_gateway.py:414-427`) copia el paquete a `runs/<op>/contexto/`, relee el digest de la copia y solo entonces llama a `backend.launch`.

| Causa | Cuándo |
|---|---|
| `perfil-ausente` | La cabecera del brief no trae `profile` |
| `perfil-desconocido` | El id no está en `perfiles.v1.json` |
| `perfil-no-atiende-ruta` | El perfil no lista `mac-local`/`opencode` |
| `perfil-no-admite-contrato` | `resultContract` de la asignación no está en `resultContracts` |
| `perfil-sin-competencia` | `competence` de esa ruta no es `passed`, o venció |
| `contexto-incompleto` | Un archivo de la fuente, o de la copia en la corrida, no coincide con el manifiesto. No es de `plan_launch` (arriba) |
| `herramienta-negada` | La configuración que el host va a pasar niega una herramienta de `requiredTools`, por ejemplo `task` o `skill` |
| `revisor-con-escritura` | El perfil tiene `writesSource: false` y la configuración que el host va a pasar no niega `edit` |

`LaunchHeader` (`sesion.py:38-78`) acepta una línea más, `profile: <id>`. `brief.py --perfil <id>` la escribe. `encargo.py preparar --perfil <id>` la pone en `briefArgs`, con `ingenieria` por omisión, así `main` la copia sin conocer los perfiles. Un host viejo rechaza un brief con `profile` (`MalformedHeader`), por eso el orden de la ventana de G5 importa (sección 6).

Así quedan las tres frases del "Verificar": quitar poteto es `contexto-incompleto` o `generacion-no-certificada`; dejar escribir al reviewer es `revisor-con-escritura`; negar una herramienta del hijo es `herramienta-negada`.

En las rutas nativas no hay rechazo por encargo en SUA-03 (4.11, conflicto 4).

### 4.6 Permisos efectivos

**Ruta por CLI.** Dos cosas distintas, y `flota.v1` solo guarda la segunda.
- Lo configurado: la parte de `OPENCODE_CONFIG_CONTENT` que el host arma para el perfil. Para `writesSource: false`, `permission.edit: "deny"`. Para todos, `external_directory` como hoy. Su digest va a `attestations` como `tools`.
- Lo medido: cada línea `message=evaluated permission=<p> … action.action=<a>` de stderr, como `"<p>:<a>"` sin repetir (`B22-fase0.md`, experimento de `PWD`, trae `permission=bash … action.action=allow`). `read_events` ya lee las de `deny`. Lee también las de `allow`. Va en `flota.permissions`. Vacío quiere decir que opencode no evaluó nada, y se escribe vacío.
- La guarda de carpeta no confina el shell (B22-S7). Ningún permiso de escritura se da por negado por la regla sola. Para el revisor, lo que cuenta es la foto del repo de 4.8.

**Rutas nativas.** Lo medido es la lista de `tools.effective` para la sesión (`src/gateway/server-methods` vía `core-descriptors.ts:137`, citado en el diseño de SUA-02), como `"tool:<nombre>"`. Si esa llamada no lista las herramientas que se arman por corrida (`unknown` 6 de SUA-02, que sigue abierto), va vacío.

**Herramientas del procedimiento.** Cada perfil declara `requiredTools` por runtime. Para poteto en opencode: `read`, `edit`, `bash`, `skill`, `task`, `todowrite`; sin `edit` para los perfiles que no escriben. Para OpenClaw, los nombres de la adaptación. La sonda de conducta comprueba que se usaron.

**Los siete perfiles locales.** La configuración por corrida pone `agent.<nombre>.model` al modelo del encargo para los siete. Los paneles pierden su diversidad de versiones de GLM: es honesto, porque un encargo corre un solo proveedor. La adaptación lo dice ("diversidad reducida: un solo modelo"). Si `unknown` 1 muestra que `agent.<nombre>` no se aplica desde `OPENCODE_CONFIG_CONTENT`, el host pone `permission.task: "deny"`. Como `task` está en los `requiredTools` de poteto en opencode, todos los perfiles de la ruta por CLI quedan `herramienta-negada`: la ruta por CLI no admite ningún encargo con perfil hasta resolverlo, y G3 no se mergea así.

### 4.7 `flota.v1` por intento

**Ruta por CLI.** El host escribe `runs/<op>/flota.json` al cerrar la operación, cuando ya leyó los logs: en la pasada en que el recurso de la corrida llega a `AbsenceVerified`, una sola vez. Una corrida sin paquete (todas hasta G3) no tiene perfil ni generación y no tiene documento: `estado` devuelve `flota: null`. Los digests de `poteto` y `tools` los toma el lanzador antes de lanzar y los deja en `sessions/<op>/contexto.json` (G3). `encargo.py estado --tarea` lo devuelve en `flota`. El documento pasa `contrato.py` sin hallazgos.

| Campo | De dónde sale | Si no se puede leer |
|---|---|---|
| `rootId`, `unitId` | `taskId` del reclamo. Para una tarea suelta es la raíz de su árbol en R (`managed-task.budget.shared.ts:79-82`) | Siempre se lee |
| `attempt` | `generation` del reclamo de R | Siempre se lee |
| `specialist` | `profile` de la cabecera del brief | No hay lanzamiento sin perfil |
| `host` | `client.host_id`, `mac-local` | |
| `executor` | `opencode` | |
| `accountRef` | `name` del permiso de `proveedores-permitidos.json` que cubre al proveedor, por ejemplo `glm` | `null` si el permiso no tiene nombre |
| `model` | `providerID/modelID` de las líneas `message=stream` con `small=false` y `agent=build`, comparado con el `-m` de `sessions/<op>/argv.json`. Si todas coinciden con `-m`, `{id: <-m>}` | `{id: null, reason: "opencode no registró ninguna llamada"}`, o `"opencode usó <x> y se pidió <y>"` |
| `generation` | `generation` del manifiesto copiado | |
| `permissions` | Lo medido (4.6) | Lista vacía |
| `attestations` | `poteto`: digest del paquete copiado. `profile`: digest canónico del perfil. `tools`: digest de la configuración por corrida | |
| `children`, opcional | Por cada `agent` distinto de `build` y `title` en las líneas `message=stream`: `{agent, model}` | Lista vacía |

`children` es un campo opcional nuevo. El contrato lo permite sin subir versión ("Un bloque que necesite más los agrega como opcionales"). Va al fixture `flota/modelo-exacto-con-hijos.json`.

`estado --tarea` gana `modeloUsado`, el `model.id` de arriba, `modeloUsadoRazon` cuando es `null`, y `permisos`, lo medido en 4.6; deja `modelo` como el pedido, con su docstring corregido.

**Encargo nativo a un agente.** Lo arma `flota.py nativo` sobre un extracto de solo lectura de la Mini, como la sombra de SUA-02. Solo para evidencia en SUA-03. `host` es `mini-native`, `executor` es `native`. `model` sale de `json_extract(payload_json, '$.model')` de `subagent_runs`, comparado con `modelId` del evento `session.started` del hijo en `trajectory_runtime_events` de la base del agente. P5 confirmó que `payload_json` trae `$.model` (por ejemplo `opencode-go/deepseek-v4.1-flash` en los hijos de `mail`). `~/.local/state/sua-loop/mediciones/turnos.sh:20` solo lee `modelId` de `session.started`; la consulta a `subagent_runs` es nueva y la escribe `flota.py`. Los campos existen en R (`subagent-spawn.ts:572`, `openclaw-state-schema.sql:2042-2051`). Si no coinciden o falta uno, `null` con la razón (`unknown` 5). `permissions` es lo de `tools.effective`. `accountRef` es `null`.

Turno nativo e hijo nativo no tienen intento de una unidad. No llevan `flota.v1`. Su evidencia es la de la sección 5.

**Causa del proveedor.** Es el residual de SUA-02. Cuando `read_events.error` trae un texto medido, `estado` gana `explicacion.causa` más precisa: `proveedor-sin-cuota` para "The usage limit has been reached." y `proveedor-sin-modelo` para "does not yet include access" (los dos en `B22-canarios.md`). La incidencia a R sigue siendo `launch-failed`. No hay texto medido para una sesión vencida (`unknown` 8): no se clasifica a ciegas.

### 4.8 El revisor no escribe fuente

Una foto del repo antes y después no basta: el revisor puede escribir con `bash`, mirar el resultado y dejarlo como estaba antes de terminar, y `permission.edit: "deny"` no cubre el shell. Por eso el revisor no trabaja en el repo real.

- **Un clon desechable.** Para un perfil con `writesSource: false`, el host clona el repo antes de lanzar: `git clone --no-hardlinks --no-checkout <repo> <corrida>/repo`, `git -C <corrida>/repo checkout --detach <inputRevision.sha>` y `git -C <corrida>/repo remote remove origin`. Sin enlaces duros, ningún objeto del clon es un archivo del repo real. Sin `origin`, un `git push` del revisor no tiene a dónde ir. `workspaceRef` y `PWD` apuntan al clon, que está dentro de la carpeta de la corrida y por eso ya es lo único que `external_directory` deja (`opencode_env`). No es `git worktree`: un worktree escribe en el `.git` del repo real y comparte sus refs.
- **Hasta G3, sin perfil.** Mientras la corrida no trae su perfil, el host trata `review.v1` como `writesSource: false` y todo lo demás como hoy. G3 lo cambia por el campo del perfil.
- **El artefacto de revisión va a la corrida.** Para `review.v1`, `cli_protocol` pide `artifactRef` dentro de la carpeta de la corrida, y `report` lo comprueba con `under(…, run.path)` en vez de `workspaceRef` (`host.py:106` y `:343`). Para `ready.v1` no cambia. La skill `encargo-cli` deja de pedir un archivo del repo para `findingsRef` de una revisión.
- **Al cerrar, el clon se borra.** Después de la prueba de cierre del grupo, el host borra `<corrida>/repo`. Lo que el revisor escribió ahí se pierde, y no importa.
- **La foto del repo real se queda como comprobación.** El host guarda antes de lanzar y relee al cerrar: `git rev-parse HEAD`, el sha256 de `git for-each-ref`, el de `git status --porcelain=v1 -z --untracked-files=all` y el de `git diff --binary HEAD`. Desde G2 guarda también el sha256 de `.git/config` y el de los archivos de `.git/hooks`, que corren código en el siguiente comando de git (nota de DeepSeek a 4.8), y el de `.git/info/exclude`, donde una ruta sembrada escondería un archivo del status (G3). Los archivos ignorados entran a la foto con el clon, en G3: antes del clon, una corrida de pruebas del revisor en el repo real deja `__pycache__` y eso no es fuente. La foto no sabe quién cambió el repo: un cambio de otro proceso durante la corrida (David, otro encargo) también rechaza la revisión, y el recibo lo dice como límite (F12). Si algo cambió, el resultado se rechaza con `invalid-result` y episodio `reviewer-wrote-source`, y `estado` dice qué cambió. El host no deshace nada. En la comparación, un campo que la foto previa no tiene no se cuenta como cambio (F4 de DeepSeek en #305), y un plazo de git vencido es foto fallida, nunca "no es un repo" (F1).
- **Lo que deja de importar.** Las escrituras temporales, los `__pycache__` de una corrida de pruebas, un `stash`, un commit o una rama: todo pasa en el clon.
- **Lo que sigue sin cubrir.** El shell no está confinado (B22-S7). El revisor puede escribir el repo real o cualquier otro repo de `~/dev` por su ruta absoluta. Si deja el repo real cambiado, la foto lo atrapa. Si lo escribe y lo restaura antes de cerrar, o si escribe otro repo, no se ve. La certificación dice lo que mide: el revisor trabajó en un clon y el repo real quedó igual. Se escribe así en el recibo.

### 4.9 Claude como trabajador

Nada de SUA-03 depende de la fase 0 de Claude de SUA-04. `executor: "cli"` queda sin uso. Ningún perfil lista una ruta de Claude. El adaptador `claude_opus` y los otros seis de `hostAdapterCoverage` no se tocan: el plan los retira o los reutiliza en SUA-04, paso 3. Claude sigue trabajando en la ventana de la Mac, fuera de la ruta por CLI.

### 4.10 Los residuales que llegan aquí

| Residual | Decisión | Rebanada |
|---|---|---|
| SUA-02: `flota.v1` | Entra entero | G2 |
| SUA-02: permisos efectivos del trabajador por CLI | Entra entero | G2 |
| SUA-02: que el host distinga una sesión vencida | Entra la causa en `estado` para los textos medidos. El episodio nuevo hacia R y su clase (`AUTH_VENCIDA`, `SIN_CUOTA`) en `classifyIncident` (`managed-root.decide.ts:110-124`) van juntos a SUA-04, que es dueño del acceso por cuenta y ya tiene que cambiar R. Hoy un episodio desconocido cae en `unexpected` (`:122`), que no aprueba nada | G2, y SUA-04 |
| SUA-00: los siete adaptadores sin host | No los decide SUA-03. El plan los pone en SUA-04, paso 3. La fila de `followups.md` se corrige en G5 para decir eso | G5 |
| SUA-02/pruebas inestables | De R. SUA-03 no cambia R. Sigue en `followups.md` | Ninguna |
| SUA-02/residuales (`raiz_controlador` y la sombra) | Son de SUA-09O. Siguen en `followups.md` | Ninguna |

### 4.11 Conflictos con el plan y con el contrato

**Conflicto 1. El protocolo del revisor contra el paso 6.** El paso 6 certifica con `git status --porcelain` vacío. Hoy el protocolo obliga a escribir el artefacto en el repo (sección 1), y la foto sola no ve una escritura que se deshace. Recomendación: 4.8, el revisor en un clon desechable y su artefacto en la carpeta de la corrida.

**Conflicto 2. `rootId` y `unitId` de una tarea suelta.** El contrato los define para una raíz de SUA. Una tarea suelta no tiene. Opción A: el `taskId`, que es la raíz de su árbol en R. Opción B: un campo opcional `taskId` y `rootId` nulo, que el contrato no permite. Recomendación: A. Una corrección (`continue`) es otra tarea con su propio `taskId`; quien necesite el árbol lo lee de `managed_task_children`. Cuando SUA-09O ligue tareas a raíces, el controlador copia el documento a su unidad.

**Conflicto 3. `executor` `cli` u `opencode`.** El enum trae los dos. Recomendación: la ruta por CLI de hoy escribe `opencode`, como el fixture `flota/modelo-exacto.json`. `cli` queda para la ruta de Claude de SUA-04.

**Conflicto 4. "Ausencia impide admitir" en las rutas nativas.** Un rechazo por encargo en el turno, el hijo o el encargo nativo pide cambiar R: R no sabe qué es poteto. Opción A: dejarlo en el nivel de ruta en SUA-03 (4.5) y hacer el rechazo por encargo en SUA-09O, cuando las tareas de raíz ya llevan su asignación. Opción B: un cambio de R ahora, con una cabecera en la instrucción que R compare con un digest publicado, para un camino que ningún pedido real usa. Recomendación: A. La frase del plan "ausencia impide admitir la ruta" (I08) habla de la ruta, y para las rutas nativas la compuerta de ruta también queda en SUA-04 (4.5). El recibo de SUA-03 no da I08 por cumplido en las rutas nativas.

**Conflicto 5. Turno nativo de `main`.** El plan pone el `AGENTS.md` de `main` como el ejemplo del turno nativo. Una sonda de conducta en `main` deja avisos en el Telegram de David. Recomendación: la conducta del turno nativo se mide en `ingenieria`, cuyo `AGENTS.md:13` dice "Nunca (anti-jobs): … Telegram a David" (P6). `main` lleva el bloque y su digest se relee, y su conducta como solicitante (pide perfil, usa `brief.py --perfil`) se lee en el canario A.

**Conflicto 6. Los topes de `limits.json` en el hijo nativo.** El paso 2 dice que el hijo respeta `agents.defaults.subagents` y `limits.json`. `limits.json` es el perfil de presupuesto de las tareas gestionadas (`ManagedBudgetProfile`). Un `sessions_spawn` suelto solo lo acotan los límites del agente. Recomendación: el hijo de un encargo nativo se certifica contra `limits.json`, con las pruebas de R que ya existen (`budget_tree`, `budget_evasion` de `test-runtime.sh`, que no se repiten); el hijo suelto, contra la configuración efectiva leída en la Mini (P1: `defaults.subagents.maxConcurrent` 8; la profundidad no está en la configuración y vale la de código, `maxSpawnDepth` 5, según `limits.json`).

**Conflicto 7. La fila de `followups.md` y el plan sobre los siete adaptadores.** 4.10. Manda el plan.

**Observaciones, sin conflicto:**
- El paso 5 ya tiene probado lo de la cabecera y el `argv` (el plan lo lista). Falta solo leer el modelo usado.
- "Background no es requisito" (paso 4) ya se cumple: `opencode run` no usa background.
- `coverage.json` `routes` todavía lista `user-adopted-session`, retirada el 2026-10-13. Sale en G5, con su fila de `migration`.
- `~/.config/opencode/AGENTS.md` y `pstack-plataformas/opencode.md` dicen "solo `zai-coding-plan`". Son de David y para su uso de opencode. Contradicen la política de encargos, pero dentro de un encargo los pisa la adaptación de la corrida. No se tocan.

### 4.12 R no cambia

Nada de este diseño escribe en R. Por eso SUA-03 no instala ninguna versión de R en la Mini y la "Regla de instalación en vivo" no aplica. Lo que sí cambia en vivo es G en esta Mac (el checkout del host) y archivos en la Mini que no son R. Su ventana está en la sección 6.

## 5. Cómo se prueba

Las pruebas de G son `unittest` y el arnés de `test-agent-work-e2e.sh`. Cada fila dice qué fallo la pone roja.

### Ensayos integrados

| Ensayo | Archivo y caso | Qué hace | Fallo que la pone roja |
|---|---|---|---|
| I08 | `test-agent-work-sesion.py`, "a brief without a profile is refused before launch" | `plan_launch` con un brief sin `profile` contesta `perfil-ausente` y no crea `runs/<op>/contexto` | Lanzar con el perfil por omisión del host |
| I08 | Mismo, "a package file that differs from the manifest is refused" | Un archivo de la fuente con un byte cambiado: `RunHost.plan` contesta `contexto-incompleto` sin llamar a `plan_launch`. Una copia alterada antes de lanzar: el paso de lanzamiento contesta lo mismo y no llama a `backend.launch` | Copiar sin comprobar |
| I08 | Mismo, "a new package generation closes the route" | `Route.open_for` con la generación 2 y `contextGenerations` con solo `1` contesta `generacion-no-certificada` y su frase literal; con `--canario` abre | Mirar solo la versión de opencode, o contestar la frase de la versión |
| I08 | Mismo, "the run config delivers the package" | `opencode_env` lleva `instructions` y `skills.paths` dentro de la corrida, y `agent.<siete>.model` igual a `-m` | Olvidar un perfil local |
| I08 | `test-agent-work-contexto.py`, "the package of each profile holds exactly its skills" | Lista literal de archivos por perfil | Una clausura calculada que arrastre otra skill |
| I08 | `test_agent_work_banco_e2e.py` (caso `banco`, solo con `AGENT_WORK_BANCO_REAL=1`) | opencode real, modelo real, perfil `ingenieria`, tarea de fixture. `conducta.py` sobre sus eventos: lectura de `contexto/skills/poteto-mode/SKILL.md` y del playbook antes de la primera edición, un `todowrite` con el primer paso del playbook literal, una corrida de pruebas después de la última edición y su salida citada en el resultado | La sonda de control (abajo) pasa |
| I09 | `test-agent-work-sesion.py`, "the model in use is read from the logs" | Un stderr de fixture con las dos líneas de `B22-fase0.md:146-147` da `zai-coding-plan/glm-5.3-flash`; con `modelID` distinto da `null` y la razón con los dos ids | Seguir leyendo el `-m` |
| I09 | Mismo, "allowed and denied evaluations are both measured" | Un stderr con una línea `allow` de `bash` y una `deny` de `external_directory` da `["bash:allow", "external_directory:deny"]` | Leer solo las negadas |
| I09 | `test-agent-work-flota.py`, "the attempt document passes the contract" | `flota.py` sobre una corrida de fixture; `contrato.validar` sin hallazgos; `model.id` y `children` literales | Un campo inventado |
| I09 | `test-agent-work-sesion.py`, "a reviewer profile that could edit is refused" | Perfil `revision` con `writesSource: false` y una configuración sin `permission.edit: "deny"` contesta `revisor-con-escritura` | Confiar en el perfil sin mirar la configuración |
| I09 | `test-agent-work-sesion.py`, "a reviewer works on a disposable clone" | Perfil `revision`: `workspaceRef` y `PWD` están bajo `runs/<op>/repo`, su `HEAD` es `inputRevision.sha`, `git remote` sale vacío y `git -C <clon> rev-parse --git-common-dir` no es el `.git` del repo real | Abrir el revisor en el repo real, o con `git worktree` |
| I09 | `test-agent-work-host.py`, "what a reviewer writes in its clone never reaches the repo" | El doble escribe un archivo en el clon, lo commitea, lo deshace y entrega `review.v1`: el resultado entra, el repo real queda igual en las cuatro medidas y el clon ya no existe tras el cierre | No borrar el clon, o clonar con enlaces duros |
| I09 | Mismo, "a reviewer that changed the real repo has its result refused" | El doble escribe un archivo en el repo real por su ruta absoluta y entrega `review.v1`: el host rechaza con `reviewer-wrote-source` | Comparar solo `HEAD` |
| I09 | Mismo, "a review artifact lives in the run folder" | `review.v1` con `findingsRef` en `runs/<op>/` pasa; uno en el repo, para un perfil que no escribe, se rechaza | Aceptar el artefacto en el repo |
| I09 | `test-agent-work-sesion.py`, "a child the run did not allow is refused" | Perfil que exige `task` y configuración con `permission.task: "deny"` contesta `herramienta-negada` | No mirar `requiredTools` |
| I09 | `banco` | Encargo `revision` sobre un repo con un error sembrado. Espera `changes` con el error nombrado y la foto del repo igual. Otro sobre un repo sano espera `approved`. `flota.v1` de cada uno con `model.id` no nulo y `permissions` no vacío | |
| I11 | `test-agent-work-contexto.py`, "a profile admits only its routes and contracts" | `meli` por CLI: `perfil-no-atiende-ruta`. `ingenieria` con `review.v1`: `perfil-no-admite-contrato`. `meli` en la ruta nativa de `meli` con `ready.v1`: admite | Admitir por nombre |
| I11 | Mismo, "an expired source or a missing competence closes only that profile" | `meli` con una fuente vencida no admite; `amazon` sí | Cerrar todos |
| I11 | `test-agent-work-publicar.py`, "a block names a default profile only when the agent has exactly one" | Fixture con un agente de un perfil (`meli`), uno de ninguno (`pers`) y uno nombrado por dos perfiles. El bloque del primero trae "tu perfil por omisión es `meli`"; los otros dos no traen esa línea y sí la de "no tienes perfil por omisión" | Escribir `<id>` vacío, o elegir uno de dos |
| I11 | `test-agent-work-publicar.py`, "the publisher touches only the block and its skills" | Árbol de fixture con `MEMORY.md`, `memory/`, `USER.md`, `SOUL.md`, una skill ajena en `~/.openclaw/skills` y un `AGENTS.md` con texto propio. Aplicar, aplicar otra vez y revertir. Todo lo no administrado queda byte por byte igual | Reescribir `AGENTS.md` entero |
| I11 | Mismo, "an edited block is a conflict, not an overwrite" | Bloque con una línea cambiada a mano: ese agente queda en conflicto y su archivo no cambia; los demás se publican | Pisar la edición |
| I11 | Mismo, "an edit between read and apply is a conflict" | `--leer`, luego una línea nueva fuera del bloque en un `AGENTS.md`, luego `--aplicar`: ese agente queda en conflicto y su archivo conserva la línea | Comprobar solo el bloque |
| I11 | Mismo, "a revert never undoes an edit made after apply" | `--aplicar`, luego una línea nueva en un `AGENTS.md` y en una skill administrada, luego `--revertir`: esos dos quedan en conflicto y con su edición; los demás vuelven al respaldo | Restaurar el respaldo sin comparar |
| I18 | `test-agent-work-host.py`, "a review that dies leaves no verdict" | Encargo `review.v1` cuyo doble sale sin resultado: incidencia y ningún `result.json` reportado | Fabricar un veredicto |
| I18 | `test-agent-work-contexto.py`, "advisor profiles declare their coverage" | `adversario` y `revision` dicen `checkpoint-only` y `estado` lo devuelve | Omitir la cobertura |

### La sonda de control

La lista de pasos se compara con la primera frase del primer paso del playbook: varios pasos de los playbooks de 0.9.84 son párrafos, y un elemento de lista no. Una prueba de conducta solo vale si distingue. `conducta.py` corre también sobre eventos que no tienen poteto y debe dar rojo con la razón esperada (que falta la lectura de `poteto-mode/SKILL.md`), no por un error de lectura:
- Ruta por CLI: los eventos de la operación de la tarea del canario D de B22 (tarea `595755ae…`), si siguen en el spool, y la misma tarea del banco corrida con `--sin-contexto`, una bandera que solo existe en el caso de banco.
- Rutas nativas: la sonda nativa corrida antes de publicar (M-15).

### Las sondas de competencia

Cada perfil tiene una positiva y una negativa en `contexto/competencia/<perfil>/`, con criterio literal. Los de ruta CLI corren en el banco. Los nativos corren como turno de su agente en la Mini: `operaciones`, `amazon`, `meli`, `mail` y `odoo`. `aceptacion` no corre: no tiene agente vivo. Cada turno nativo usa un `session-key` propio que se borra al terminar. Se toma el digest de `memory/` del agente antes y después. Si cambió, es un hallazgo y no se revierte.

La de `mail` prueba solo la selección de contexto: qué skill y qué fuente lee y qué haría, sin pedir un borrador. `openclaw agent` no tiene una bandera para quitar herramientas a un turno (`src/cli/program/register.agent-turn.ts:20-46`; solo `cron add` tiene `--tools`, `src/cli/cron-cli/register.cron-add.ts:158`), así que un turno de `mail` puede enviar.

**Si un agente de sonda avisa a David.** Todos los `AGENTS.md` salvo el de `scout` nombran `telegram` o `message` al menos una vez (P6), y solo el de `ingenieria` lo prohíbe de forma expresa (`AGENTS.md:13`). Antes de cada agente nuevo se corre una sola sonda y se leen sus `conversation_deliveries`. Si salió algo hacia David, se paran las sondas de ese agente, se cuenta como aviso en el recibo, y su competencia queda sin sonda viva (`competence.status: pending`) hasta que el coordinador elija otra forma.

### El párrafo "Verificar" del bloque, frase por frase

| Frase | Dónde queda cubierta |
|---|---|
| I08/I09/I11/I18 | Tabla de arriba y sección 6 |
| Quitar poteto impide la admisión | `perfil-ausente`, `contexto-incompleto`, `generacion-no-certificada` |
| Permitir escritura al reviewer impide la admisión | `revisor-con-escritura`, y la foto del repo rechaza el resultado |
| Deshabilitar una herramienta necesaria del hijo impide la admisión | `herramienta-negada` |
| Perfil Meli pasa su tarea y rechaza una ajena | Admisión (I11, primera fila) y la sonda de competencia de `meli` |
| Skill irrelevante no entra | Lista literal por perfil |
| Memoria sobrevive | Prueba del publicador y digest de `memory/` en la Mini antes y después de publicar |
| Un digest sin conducta no completa el bloque | Cada ruta tiene una sonda de conducta con su control (siguiente tabla) |
| Las clases `Live*` no corren con un encargo en vuelo | El banco usa el grupo `_appserverusr` y su propio host, como `ruta_viva` (`test_agent_work_ruta_viva_e2e.py:48-51`) |

### Cada ruta: qué se mide, cómo y qué canario

| Ruta | Entrega (digest) | Conducta observable | Dónde y cuántos avisos |
|---|---|---|---|
| Turno nativo | Digest del bloque en cada `AGENTS.md` y de `.sua-contexto.json`, releídos en la Mini | Turno de `ingenieria` con la tarea de fixture. En `trajectory_runtime_events`, `tool.call` de `read` sobre `poteto-mode/SKILL.md` y el playbook antes del primer cambio, `progress_card` (o su alias `update_plan`) con el primer paso literal, la corrida de pruebas después del último cambio (M-17) | Mini, `openclaw agent --agent ingenieria`, sin `--deliver`. 0 avisos: su `AGENTS.md:13` prohíbe Telegram a David (P6); se confirma con `conversation_deliveries` |
| Hijo nativo | El mismo `AGENTS.md`, único archivo de arranque del hijo | En el mismo turno, la tarea pide delegar la prueba con `sessions_spawn`. La fila de `subagent_runs` con `requester_session_key` del padre y `$.model`; el hijo lee `poteto-mode/SKILL.md` y empieza con `profile:` | Mismo turno. 0 avisos |
| Encargo nativo a un agente | Digest de la sección de perfil del brief y del manifiesto administrado | `main → ingenieria` con `brief.py --perfil ingenieria`. Fila de `managed_tasks` con `target.kind = agent`, `result_json`, y la conducta del hijo como arriba. `flota.py nativo` sobre el extracto | Canario A. 1 aviso |
| Encargo por CLI | Digest de `runs/<op>/contexto/` antes y después | Banco: perfiles `ingenieria` y `revision` con su control. En vivo: un encargo `ingenieria` que pide una ayuda con `task` | Banco, 0 avisos. Canario A, 1 aviso |
| Hijo de una CLI | Lo que el padre tiene en la corrida | En el banco y en el canario A, una línea `message=stream` con `agent=poteto-agent` y el `modelID` del encargo; los procesos de `boundary_before` de la prueba de cierre; la frontera vacía al cerrar | Dentro de los dos de arriba. 0 avisos más |

**El canario A** es un solo pedido a `main` con dos encargos: uno por CLI y uno nativo a `ingenieria`. `main` le avisa a David el resultado de cada encargo, también de los de prueba (`B22-canarios.md`, "Otros hechos"). Deja **dos avisos** en su Telegram. El coordinador le avisa a David antes de mandarlo, como en B22. Ningún otro canario pasa por `main`.

## 6. El corte en rebanadas

Seis rebanadas de G. Ninguna de R. Cada una trae su prueba y deja verde lo anterior.

**Dónde se corre.** `GWT` es el worktree de G de la rebanada. `RWT` es `~/dev/wt/r-sua02-c-gate`, que tiene R `7b3db54` construido (`dist/build-info.json` dice `7b3db54226bf`). El checkout principal de R tiene su `dist` en `4acb881e`, no sirve para los casos que exigen R construido.

**La compuerta de cada rebanada:**
- Las pruebas focalizadas de su fila.
- `python3 scripts/tests/test-agent-work-{sesion,encargo,routing,modelos,lanzar-encargos,host}.py` y `bash scripts/tests/test-sistema-agentes-contrato.sh`.
- Si toca el host: `AGENT_WORK_RUNTIME_SOURCE=$RWT bash scripts/tests/test-agent-work-e2e.sh ruta_viva`, sin `skipped`.
- `pre-commit run --files <archivos de la rebanada>`.
- La batería completa (`bash scripts/run-checks.sh`) una vez por PR, en CI, sobre el commit final.

| N.º | Rebanada | Qué cambia | Su prueba | Toca el host vivo |
|---|---|---|---|---|
| G0 | Línea base | Nada. La compuerta sobre G `97d35ab0` con `RWT` | Las de hoy | No |
| G1 | Paquete y perfiles | `contexto/` con `poteto.v1.json` (generación 1), `perfiles.v1.json`, las dos adaptaciones, el bloque y los fixtures de competencia. `contexto.py`. `brief.py --perfil` (acepta la bandera y escribe la línea; con destino agente, también el texto del perfil desde `--perfiles`). `ruff.toml` y hooks | `test-agent-work-contexto.py`, las filas de `brief.py` en `test-agent-work-routing.py` | No |
| G2 | Lo que el host lee del intento | `read_events` con `modelID`, `agent` y las evaluaciones `allow`. `flota.py` y `flota.json` al cerrar. `estado` con `modeloUsado`, `flota` y las causas de proveedor. Artefacto de revisión en la carpeta de la corrida y foto del repo real. `conducta.py`. El fixture `flota/modelo-exacto-con-hijos.json` | `test-agent-work-sesion.py`, `-host.py`, `-encargo.py`, `-flota.py`, `test-agent-work-conducta.py`, contrato | Sí, al actualizar su checkout (ventana) |
| G3 | Lanzamiento con contexto | `LaunchHeader` con `profile`. `preparar --perfil`. Los siete rechazos de `plan_launch`, `contexto-incompleto` en `RunHost.plan` y en el paso de lanzamiento, y `generacion-no-certificada` con su frase. Copia del paquete a la corrida. El clon desechable del revisor en `Workspace` y su borrado al cerrar. `opencode_env` con `instructions`, `skills.paths`, `agent.<siete>.model` y los permisos del perfil. `Route.open_for` con generación. El caso `banco`. Al final, `contextGenerations: {"1": …}` en `coverage.json` y `competence` de los cinco perfiles de la ruta CLI en `perfiles.v1.json`, con la evidencia del banco sobre el SHA de esta rebanada | `test-agent-work-sesion.py`, `-host.py`, `-encargo.py`, `-routing.py`, `banco` (M-16) | Sí, ídem |
| G4 | Publicación nativa | `publicar-contexto.py` con `--leer`, `--aplicar` y `--revertir`, los tres con su CAS. La skill `poteto-openclaw` sale del manifiesto de la generación 1, no se escribe aparte. La skill `encargo-cli` con `--perfil` y el artefacto de revisión fuera del repo. `opencode_env` pone `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` en corrida con paquete (riesgo 4, nota de G4 de `SUA-03-mediciones.md`) | `test-agent-work-publicar.py`; las anclas de `encargo-cli` en sus pruebas de siempre y `test-candados-declarados.sh` | No, salvo la variable de `opencode_env`, a propósito |
| G5 | Ventana, sondas, canario y cierre | La ventana de abajo. Sondas nativas después (M-17) y de competencia. Canario A. `coverage.json` `routes` con las cinco rutas, su generación y su evidencia; sale `user-adopted-session` con su fila de `migration`. Fila de `followups.md` de los siete adaptadores. Recibo `docs/evidence/sistema-agentes-unificado/SUA-03.md`, que da I08 por cumplido solo en la ruta por CLI y el hijo de una CLI | `test-agent-work-routing.py` (las filas de `migration`), contrato, el recibo | Sí |

PR: G1 y G2 en uno, G3 en otro, G4 y G5 en otro. Cada PR pasa por el revisor asignado.

### Por qué este orden

- **G1 y G2 no cambian ninguna conducta de lanzamiento.** G2 solo lee más y rechaza un resultado de revisión que hoy entraría escrito en el repo. Se puede mergear sin abrir nada.
- **G3 necesita las mediciones antes de escribir `opencode_env`.** M-13 dice qué llaves de configuración aplica opencode 1.18.35. Sin eso, `instructions` y `agent.<nombre>` son suposiciones.
- **La generación 1 se certifica en el mismo PR que la compuerta.** Si G3 entrara sin `contextGenerations`, el host actualizado cerraría la ruta viva.
- **G4 no toca el host.** Así el paquete de la ruta por CLI no cambia después de certificarse. Excepción de G4, a propósito: `opencode_env` agrega `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` en corridas con paquete. La regla protegía un paquete certificado, y la generación 1 todavía no lo está (la certifica M-16 después del PR de G4), así que la corrida con paquete puede cambiar sin romper ninguna certificación.
- **Una sola ventana, al final.** El checkout del host sigue en `4000a1d4` y tiene que moverse antes de la primera evidencia viva de SUA ("Preparación antes de SUA-01", punto 4). Se mueve una vez, con todo mergeado.

### La ventana en vivo (G5)

No instala R. Mueve el checkout del host en esta Mac y publica archivos en la Mini. Se hace con el slot libre y sin encargo en vuelo. No reinicia el gateway, salvo lo que diga `unknown` 4.

| Paso | Comando | Esperado |
|---|---|---|
| 1. Slot libre | `python3 scripts/agent-work/encargo.py estado` y `sqlite3 -readonly ~/.local/state/agent-work-host/enc-1/host.sqlite "select count(*) from operations where status not in ('acknowledged','abandoned','cancelled')"` | `slot` `free` y `0` |
| 2. `brief.py` nuevo en la Mini | Como `T12-runbook.md`, "El brief de `main` en la Mini": `scp`, los dos `shasum` y la prueba en una raíz temporal con `--perfil ingenieria` | Los dos sha256 iguales; la cabecera trae `profile: ingenieria` |
| 3. Host al día | `git -C ~/dev/wt/agent-work-host checkout <sha de main>`, `tmux -L agent-work kill-session -t host-encargos`, `bash scripts/agent-work/lanzar-encargos.sh` | `encargo.py estado` contesta `slot` `free` y ese `commit` |
| 4. Contexto nativo | `python3 scripts/agent-work/publicar-contexto.py --leer` y luego `--aplicar` | Cero conflictos; la relectura de cada digest coincide; los digests de `MEMORY.md`, `memory/`, `USER.md` y `SOUL.md` de cada workspace iguales antes y después |
| 5. Skill `encargo-cli` | Como `t12-skills-main-1.sh` de B22 | `SKILLS OK`, sha256 igual en los dos lados |
| 6. Prueba de humo del host | `encargo.py preparar --repo ~/dev/canario-encargos --perfil ingenieria` | `ok: true` y `briefArgs` con `--perfil ingenieria` |

Entre el paso 3 y el 5, un pedido de implementación "por CLI" sale bien: `preparar` ya pone el perfil en `briefArgs` y `brief.py` ya lo acepta. La reversa del paso 3 es volver el checkout a `4000a1d4` y relanzar. La del paso 4 es `--revertir`. La del 2 y el 5, los respaldos que dejan, como en B22.

## 7. Lo que no entra en SUA-03

| Qué | Por qué | Bloque |
|---|---|---|
| Rechazo por encargo en las rutas nativas | Pide R (4.11, conflicto 4) | SUA-09O |
| Episodios `AUTH_VENCIDA` y `SIN_CUOTA` hacia R | Son del acceso por cuenta y cambian R (4.10) | SUA-04 |
| Elegir modelo, sucesión, promoción y altas | El perfil dice qué ruta lo atiende, no qué modelo | SUA-04 |
| Los siete adaptadores sin host y la ruta de Claude | El plan los pone ahí | SUA-04 |
| Que el relevo use otro modelo | Usa `flota.v1` de SUA-03 | SUA-05 |
| Un advisor que lea eventos en vivo | No hay productor de eventos para él | Nadie por ahora; `coverage: events` queda en el enum |
| Consultar memoria con procedencia para armar el contexto | El paquete de SUA-03 lleva poteto, perfil y el brief; no lee memoria | SUA-04, refresco de fuentes |
| Confinar el shell del encargo | B22-S7, sin diseño | Fuera del programa hasta que se diseñe |
| Quitar las instrucciones globales de opencode de los encargos | B22-S8. La adaptación las pisa; quitarlas pide una forma medida | Fuera del programa |
| Tocar `~/.config/opencode/`, `~/.agents/` o el workshop de cualquier agente | Son de David o del agente | Nadie |

## 8. Riesgos, `unknown` y decisiones pendientes

### Riesgos conocidos

1. **La conducta es una aproximación.** Un modelo puede leer `SKILL.md`, escribir la lista y luego tomar un atajo. Las condiciones están atadas al resultado (pruebas después del último cambio, con su salida citada) y cada sonda tiene su control rojo. Sigue siendo una lectura de eventos, no una prueba de comprensión. El revisor debe atacar esto primero.
2. **El revisor sin escritura no confina el shell.** Trabaja en un clon, pero puede escribir el repo real o cualquier otro por ruta absoluta (4.8, "Lo que sigue sin cubrir").
3. **El bloque cuesta tokens en cada turno de cada agente.** Se mide su tamaño en caracteres en G1 y se fija con una prueba (tope de 1 500 caracteres). Frente a los ~20 500 tokens de un despertar de `main` (M-01), es poco, pero es en todos los turnos.
4. **Dos copias de pstack en esta Mac.** Si `skills.paths` no gana sobre `~/.agents/skills` con el mismo nombre (`unknown` 1, punto b), el modelo del encargo puede cargar 0.9.30. Entonces la fuente fijada pasa a ser la misma revisión que ve opencode, y el constructor se niega si las dos difieren. Cerrado en G4 por otro camino (medición del 2026-10-15, `SUA-03-mediciones.md`, nota de G4): `opencode_env` pone `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` en toda corrida con paquete, y con `skills.paths` quedan solo las skills del paquete; la generación 2 con nombres propios ya no hace falta. Queda probarlo en un turno real (M-16).
5. **Una sonda nativa puede escribir memoria.** El agente escribe su `memory/` por su cuenta. Se compara antes y después y se informa; no se revierte, porque esos archivos no son de SUA.
6. **Los paneles de opencode pierden diversidad dentro de un encargo.** 4.6.
7. **Ventana con el host viejo.** Si un pedido llega entre los pasos 2 y 3 de la ventana, el host viejo no ve `--perfil` en `briefArgs` (lo pone el `preparar` nuevo), así que no pasa nada. Si llega un brief con `profile` a un host viejo, sale `cabecera-mal-formada` con su frase, sin perder la tarea. Entre los pasos 3 y 5, una revisión pedida con la skill vieja lleva el perfil por omisión, `ingenieria`, y sale `perfil-no-admite-contrato` con su frase: `main` se la dice a David y se repite después del paso 5.

### Lo que no se pudo comprobar

| N.º | Qué no se sabe | Por qué importa | Comando que lo contesta |
|---|---|---|---|
| 1 | Si opencode 1.18.35 aplica desde `OPENCODE_CONFIG_CONTENT`: (a) `instructions`; (b) `skills.paths`, y quién gana con el mismo nombre que `~/.agents/skills`; (c) `agent.<nombre>.model`; (d) `permission.edit` y `permission.task`; (e) si el flujo `--format json` trae los eventos de un subagente; (f) si hay una línea `evaluated … allow` por cada herramienta | Es todo el transporte de 4.3 y la medición de 4.6 | M-13, en esta Mac (abajo) |
| 2 | Qué pasa con un `task` a `poteto-agent` (fijado a `zai-coding-plan/glm-5.3`) cuando `enabled_providers` es otro | Sin `agent.<nombre>.model`, el hijo de una CLI fallaría en todo encargo que no sea GLM | M-13, las dos corridas con `kimi-code-plan-cn` |
| 3 | Cerrado por P1 y P2: 19 agentes, ninguno con filtro de skills, ningún `AGENTS.md` nombra poteto, `defaults.subagents` trae solo `maxConcurrent: 8` (la profundidad es la de código, `maxSpawnDepth` 5) | | |
| 4 | Si una skill nueva en `~/.openclaw/skills` la ve un agente sin reiniciar el gateway. Lo demás lo cerró P3 y P4: el directorio tiene `grok` y `navegacion-estable`, y `tools.effective` de una sesión de hijo de `ingenieria` lista las herramientas por id | Si hace falta reiniciar, la ventana cae bajo la "Regla de instalación en vivo" | Después del paso 4 de la ventana: `openclaw skills list --agent ingenieria --json` nombra `poteto-mode` |
| 5 | Si `$.model` de `subagent_runs` (P5 confirmó que existe) coincide con `modelId` del `session.started` del hijo | Es `model.id` del encargo nativo | `flota.py nativo` sobre el extracto del canario A |
| 6 | Si `tool.call` de `trajectory_runtime_events` trae los argumentos (la ruta leída) o solo el nombre. P5 no lo contestó | Sin la ruta, la conducta nativa se lee de `transcript_events` | En `~/.openclaw/agents/ingenieria/agent/openclaw-agent.sqlite`: `select substr(event_json,1,400) from trajectory_runtime_events where json_extract(event_json,'$.type')='tool.call' order by created_at desc limit 3` |
| 7 | Si un turno de `operaciones`, `amazon`, `meli`, `mail` u `odoo` lanzado con `openclaw agent` sin `--deliver` le manda algo a David. `ingenieria` lo prohíbe (P6) | Es la cuenta de avisos de las sondas | `conversation_deliveries` de la primera sonda de cada agente (sección 5, "Si un agente de sonda avisa a David") |
| 8 | Qué texto da opencode con una sesión de proveedor vencida | Sin texto medido no se clasifica `AUTH_VENCIDA` | No se provoca. Cuando pase, `encargo.py estado --tarea <id>` con `logTail` lo deja escrito |
| 9 | Cerrado por lectura de R: `openclaw agent` no tiene bandera de herramientas (`register.agent-turn.ts:20-46`). La sonda de `mail` es solo de selección de contexto | | |

### Procedimientos que corre el coordinador

**En esta Mac (gastan suscripción, no tocan el host vivo ni la Mini):**
- **M-13.** En un repo temporal, con el entorno de `opencode_env` y su grupo de prueba (no `agent-work-enc1`), seis corridas cortas de `opencode run -m zai-coding-plan/glm-5.3-flash --format json --print-logs --log-level INFO`, una por punto de `unknown` 1, más dos con `-m kimi-code-plan-cn/kimi-for-coding` para el 2: un `task` a `poteto-agent` sin `agent.poteto-agent.model` y otro con él. Cada una con un `OPENCODE_CONFIG_CONTENT` que agrega una sola llave. Criterio, por punto: (a) el modelo repite un nonce que solo está en el archivo de `instructions`; (b) `skill` lista la del paquete y, con un `SKILL.md` de mismo nombre y otro nonce en `skills.paths` y en `~/.agents/skills`, el nonce que repite dice cuál ganó; (c) la línea `message=stream` con `agent=poteto-agent` trae el `modelID` del override; (d) con `permission.edit: "deny"` una edición deja `evaluated … action.action=deny` y el archivo no existe; (e) el flujo trae o no `tool_use` del hijo; (f) cuántas líneas `evaluated … allow` hay frente a cuántos `tool_use` completados. Recibo en `docs/evidence/sistema-agentes-unificado/SUA-03-mediciones.md`, como `B22-fase0.md`.
- **M-16.** El caso `banco` sobre el SHA de G3, con `AGENT_WORK_BANCO_REAL=1` y `AGENT_WORK_RUNTIME_SOURCE=$RWT`. Criterio: las filas `banco` de la sección 5, el control rojo por la razón esperada, y la positiva y la negativa de los cinco perfiles de la ruta CLI (`ingenieria`, `revision`, `adversario`, `verificacion`, `exploracion`), diez corridas.

**En la Mini, solo lectura: hechas.** P1 a P6 corrieron el 2026-10-14 y su salida está en `~/.local/state/sua-loop/mediciones/sua03-p1-p6.txt`. Lo que cambió en este diseño por ellas: la lista de agentes sale de `openclaw agents list --json` (`config.get` no trae `agents.list`), son 19 y `amazon`, `meli`, `mail` y `odoo` son agentes propios; ningún `AGENTS.md` nombra poteto; `~/.agents/skills` no existe en la Mini; `subagent_runs.payload_json` trae `$.model`; `ingenieria` prohíbe Telegram a David. Queda una lectura nueva, la del `unknown` 6.

**En la Mini, con turnos de modelo (sin `main`):**
- **M-15.** Antes de publicar (cualquier momento antes de la ventana): la sonda del turno y del hijo nativo en `ingenieria` con la tarea de fixture. Es el control: `conducta.py` debe dar rojo por falta de lectura de poteto.
- **M-17.** Después de publicar: la misma sonda. Debe dar verde. Y las sondas de competencia de los perfiles nativos, cada una en su agente: `operaciones`, `amazon`, `meli`, `mail` y `odoo`, con la regla de "Si un agente de sonda avisa a David".
- Al terminar cada una: `openclaw sessions delete --yes --json <llaves>`.

### Decisiones pendientes de David

Ninguna. Lo que se miró y no es una decisión nueva:
- Las sondas nativas gastan el modelo que cada agente ya tiene. Según `T12-runbook.md:11`, el primario de `main`, `ingenieria` e `implementer` es `opencode-go-resp/muse-spark-1.3-contributor`, y el de `operaciones` y otros cuatro es `opencode-go/deepseek-v4.1-flash`. El cierre de `opencode-go` de David ("open code go es solamente para main", `proveedores-permitidos.json`, `closed`) es la política de los encargos por CLI, y ninguna sonda de SUA-03 lo abre. Las sondas no cambian el modelo de ningún agente.
- Los dos avisos del canario A, el gasto de suscripción del banco y de M-13, y el bloque en cada `AGENTS.md` caben en la autorización del 2026-10-13 ("1. sí todo").

### Lo que impide empezar a implementar

Nada que sea una decisión. G1 y G2 pueden empezar ya. G3 necesita M-13 antes de escribir `opencode_env`. La ventana de G5 necesita M-15 y la lectura del `unknown` 6; P1 a P6 ya están. La compuerta usa `RWT=~/dev/wt/r-sua02-c-gate`, porque el `dist` del checkout principal de R es de `4acb881e`.

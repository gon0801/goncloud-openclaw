# Brief para Cursor — arreglar la flota de agentes OpenClaw (ingenieria estilo Grok)

Fecha: 2026-09-10 ~07:45Z. Lead: Claude (revisa 1 sola vez al final). Implementa: Cursor.
Diagnostico origen (LEELO PRIMERO, es la evidencia de cada tarea): `docs/briefs/2026-09-10-revision-agentes-openclaw.md`.
Meta: que `implementer`, `reviewer`, `adversary`, `verifier` e `ingenieria` completen tareas de ingenieria de forma fiable. Hoy reviewer y adversary llevan **0 corridas completadas**.

## 0. Como esta cableado esto (no asumir nada mas)

- **El repo ES el gateway.** `C:\Users\ehven\.openclaw` en la maquina Windows es un checkout de este mismo repo. `scripts/sync-repos.ps1` corre alla cada ~2 h: `git add -A` + commit `auto: snapshot .openclaw`, `git pull --rebase origin main`, `openclaw config validate` (si la config queda invalida **revierte el pull**), `git push`. Ultimos snapshots en `origin/main`: 21:09, 23:10, 01:10.
  → **Mergear a `main` = desplegar al gateway vivo** en <=2 h. Por eso el merge lo hace el lead, no tu.
- **Dos filesystems distintos, y esta es la trampa #1 de estos agentes:** sus tools de archivo (`read`, `ls`, `write`, `edit`) leen el **filesystem de Windows del gateway** (`C:\Users\ehven\...`), pero su `exec` esta pinneado al **nodo Mac** (`tools.exec.host=node`, node `71a0f52874f309cb...`). No son la misma maquina. Errores reales medidos por esto: `ls C:\Users\ehven\.openclaw\cron` → ENOENT x3, `exec host not allowed (requested gateway; configured host is node)`.
- **CLI del gateway desde la Mac:** `~/.openclaw/bin/openclaw <cmd>` (modo remote, ya configurado; `config get|patch|validate`, `agents`, `plugins`, `gateway call <rpc>`, `audit`, `logs`).
- **Muse esta trabajando en paralelo** en este mismo clone, rama `fix/crons-bugs-silenciosos` (crons de packing + scripts de gonserver). No te cruces con el: ver 1.3 y 1.4.
- **Hoy 13:00Z hay un estreno de produccion** (cron `packing-extras-7h` con census v13) y Muse aplica su Fase B despues. Nada tuyo puede tocar el gateway ni llegar a `main` antes de que el lead declare cerrado el estreno.

## 1. Guardrails (violar uno = entrega rechazada)

1. **PROHIBIDO tocar produccion en vivo.** No `openclaw config set|patch` contra el gateway, no `openclaw doctor --fix`, no `gateway restart|stop|start`, no `cron edit|run|rm`, no reiniciar el servicio del nodo Mac, no ssh a gonserver. Tu entregas los patches y los scripts; **la corrida real y la aplicacion en vivo son del lead.** (Esto es explicito por el antecedente de hot-patch a produccion; no es negociable ni "si funciona da igual".)
2. **NUNCA editar `openclaw.json` en el repo.** Windows lo auto-commitea; un edit tuyo choca en el `pull --rebase`, el sync loguea `CONFLICTO ... revisar a mano` y **deja de sincronizar en silencio**. Los cambios de modelo van como archivo de patch para `openclaw config patch` (tarea M1), aplicado por el lead.
3. **Aislamiento:** trabaja en un worktree propio, nunca en el arbol de Muse:
   `git fetch origin && git worktree add ../goncloud-openclaw-agents -b fix/agentes-openclaw origin/main`
   Rama desde `origin/main`, no desde local. Verifica antes del PR: `git log origin/main..HEAD` solo lista tus commits.
4. **Archivos PROHIBIDOS (son de Muse, colisionan):** `agents/*/agent/workshop-skills/telegram-bot-send/`, `.../telegram-send-gonserver/`, `.../gmail-compose-rich-mail/`, `.../openclaw-cron-jobs/`, `scripts/gonserver/**`, `docs/cron-messages/**`, `docs/briefs/2026-09-10-muse-*`. Si crees que uno necesita un cambio tuyo, **decilo en el PR**, no lo edites.
5. **No mergees a `main` ni pushees a `main`.** Abri UN PR contra `main` y para. (summa-gate bloquea `git push` a main de todas formas; no intentes rodearlo.)
6. Tests: cada fix logico lleva prueba que **falla sin el fix y pasa con el fix**. Corre las dos y pega ambas salidas. Verde sin rojo previo no cuenta.
7. Si un obstaculo de este brief esta mal escrito o es imposible, **corregilo y decilo en el PR** (eso ya lo hiciste bien antes). No inventes datos para cumplir un paso.
8. Marcadores honestos: si no pudiste verificar algo, escribi `not_observed`. Nada de "deberia funcionar".

## 2. Fases

- **Fase 1 (ya, sin tocar nada vivo):** W1 workspaces, W2 AGENTS.md, S1 summa-gate + tests, M1 patches de modelo (preparados, NO aplicados), N1 investigacion del nodo Mac.
- **Fase 2 (solo cuando el lead diga "estreno cerrado"):** el lead aplica M1; entonces vos corres las verificaciones V1 (ping a los 4 agentes de pipeline, ver 3.M1).
- Todo lo demas (doctor, restart, sessions_search, heartbeat) es del lead y NO esta en tu alcance.

## 3. Tareas

### W1 — Workspaces de los 4 agentes de pipeline
Archivos: `workspace-implementer/`, `workspace-reviewer/`, `workspace-adversary/`, `workspace-verifier/`. Hoy los 4 son identicos y son **plantilla sin llenar** (md5 iguales en IDENTITY/SOUL/USER; `BOOTSTRAP.md` stock en 3 de 4).

1. **Borrar `BOOTSTRAP.md`** de los 4 (reviewer, adversary, verifier; implementer ya no lo tiene). Es la "birth sequence": hace que el agente abra cada workspace nuevo con un ritual de presentacion en vez de trabajar.
2. **`IDENTITY.md`**: llenar `Name`, `Creature`, `Vibe`, `Emoji` reales por agente (una linea cada uno, en espanol, sin placeholders `_(pick something you like)_`). Emojis ya usados en la config: 🛠️ implementer, 🔍 reviewer, ⚔️ adversary, ✅ verifier — respetalos.
3. **`USER.md`**: reemplazar la directiva placeholder `- Prefer ...` (hoy esta **activa**, y la propia plantilla dice que nunca se deje asi) por 4-6 directivas reales con `<!-- observed: 2026-09-10 | status: active -->`, empezando con imperativo. Minimo estas, redactadas por vos:
   - responder siempre en espanol (mexicano), salvo codigo/identificadores;
   - reportar al lead en texto plano, sin jerga, con evidencia (salida de comando) antes de afirmar;
   - nunca adivinar rutas ni flags de CLI: correr `<cli> --help` o pedir la ruta al lead;
   - trabajar solo dentro del scope que el lead paso; no explorar el resto del disco.
4. **`SOUL.md`**: recortar el stock a <=12 lineas utiles (tono directo, opiniones, sin "Great question!"). Mismo archivo para los 4 esta bien; lo que diferencia es AGENTS.md.

### W2 — `AGENTS.md` de los 4 (el cambio de mayor impacto)
Hoy tienen buen contenido (principios saikit) pero **escritos para Claude Code**: nombran la tool `Write` (aca es `write`), `ctx7`, skills `saikit:auth-security` / `saikit:payments-webhooks` / `saikit:database` / `saikit:backend-patterns` que **no existen en este gateway**, y rutas `.saikit/veredictos/<sha>.json` relativas a un repo que el agente no tiene montado. Conservá los principios; traducí el andamiaje.

Por cada uno de los 4 archivos:
1. **Tools reales de OpenClaw** en vez de las de Claude Code: `read`, `write`, `edit`, `ls`, `exec`, `sessions_send`, `sessions_history`, `memory_search`, `browser`, `message`, `progress_card`, `context7__query-docs` / `context7__resolve-library-id`. Reemplazar toda mencion de `Write`/`Read`/`Bash`/`ctx7`.
2. **Bloque nuevo `## Dos maquinas` (obligatorio, primero de todo)**, con este contenido en tus palabras:
   `read`/`write`/`edit`/`ls` operan sobre el filesystem **Windows del gateway** (`C:\Users\ehven\...`). `exec` corre en la **Mac** (nodo `David's MacBook Pro`, rutas `/Users/dn/...`). Un archivo que ves con `read` NO lo ves con `exec ls`, y al reves. Si necesitas ejecutar algo sobre un archivo del gateway, pedile al lead que lo mueva; no inventes un servidor HTTP temporal para pasarlo.
3. **Bloque nuevo `## Contrato de dispatch`:** el lead te pasa SIEMPRE rutas absolutas, el repo y el alcance. Si falta un dato, **preguntá antes de empezar** (una sola pregunta corta) en vez de explorar. Prohibido inventar flags de CLI: `openclaw cron edit -sS` no existe y se intento 3 veces.
4. **Bloque nuevo `## Reglas de operacion (estilo Grok)`**, 5 lineas: backup antes de modificar algo existente; cambios aditivos (no borres lo que no entendes); declara tus propios incidentes aunque nadie los note; evidencia real antes de afirmar exito; `--help` antes de usar un flag nuevo.
5. **Skills:** reemplazar las `saikit:*` por las que existen de verdad, listadas con `openclaw` o leyendo `agents/*/agent/workshop-skills/`. Si para un dominio no hay skill, decir "no hay skill; usá Context7 y el repo" en vez de nombrar una inexistente.
6. **Rutas `.saikit/`:** dejarlas SOLO si el dispatch nombra un repo con `.saikit/`; si no, la instruccion pasa a ser "escribí el artefacto donde el lead te indique". Aplica sobre todo al bloque del `adversary` (su confinamiento de escritura) y a `## El veredicto sellado` del `reviewer`.
7. **No toques** los bloques de principios (`## Principios`), `## Boundary Discipline`, `## Definition of Done`, `## The end user is non-technical`: son buenos y son el valor del archivo.

### S1 — summa-gate: bug de roles + tests
Archivo: `summa-gate/index.ts`. Bug real: `canonicalRole()` evalua `/verif|test|qa/` **antes** que `/implement|engineer|coder|fix/`, asi que un subagente etiquetado `implementer: fix failing tests` se registra como **verifier**. Eso rompe el chequeo de orden implementer→verifier/reviewer del lane `full` (gate de cierre, seccion 7 + 5 del archivo).

1. Corregir el orden de `canonicalRole` (implementer primero, o hacer el match por prefijo de rol explicito). Cuidado: `adversary`/`critic` y `review|audit` deben seguir ganando cuando corresponde.
2. **Tests con rojo/verde reales.** Extraé las funciones puras a `summa-gate/lib.ts` (`canonicalRole`, `mergeGuardVerdict`, `adversaryPathAllowed`, `redirectTargets`, `labelRegex`, `isDocOrLock`) e importalas desde `index.ts`. Test con el runner nativo de node (nada de deps npm: el plugin declara "solo builtins + plugin-sdk"):
   `node --test summa-gate/*.test.ts` (node 24 en `~/.openclaw/tools/node/bin/node` hace type-stripping nativo).
   Casos minimos: `implementer: fix failing tests` → `implementer` (ROJO hoy: da `verifier`); `code reviewer` → `reviewer`; `adversary attack` → `adversary`; `qa run` → `verifier`; merge-guard bloquea `git push origin main`, `git push origin HEAD:main`, `gh pr merge`, `gh api repos/x/y/pulls/1/merge` y **no** bloquea `git push origin feature/x` ni `git push --dry-run origin feature/x`.
3. **Smoke de carga del plugin (obligatorio, es el riesgo del refactor):** un test que haga `await import('../index.ts')` con el `openclaw` real resuelto desde la instalacion de la Mac (`~/.openclaw/tools/node-v24.19.0/lib/node_modules`) y asserte que el default export trae `.register`. Si ese import NO resuelve en tu entorno, **no hagas el split a `lib.ts`**: dejá `index.ts` de una pieza, exportá las funciones puras desde ahi, y marcá el smoke como `not_observed` explicando por que. Un summa-gate que no carga = merge-guard apagado en produccion; ese riesgo no se corre a ciegas.

### M1 — Reasignacion de modelos (PREPARAR, no aplicar)
Causa raiz #1 del diagnostico: OpenAI OAuth plan `prolite` con la ventana de 168 h al **100 %** (reset 2026-09-15 01:28Z) y 0 creditos; los 5 agentes de ingenieria tienen primario **y fallbacks** OpenAI → se quedan sin salida. Ademas todo modelo OpenAI-OAuth corre en el harness **codex**, donde `message` y `progress_card` responden `Unavailable in this run`. Cuotas verificadas hoy: DeepSeek $51.35 (api-key, sin ventana), zai y kimi api-key sin metrica, xAI **85 %** de la ventana semanal usada (reset 2026-09-12 23:57Z) + prepago $3.22 → xAI solo como fallback por ahora.

**Reglas de diseno de la cadena (esto es el fix real, no la eleccion de modelo):**
- **Ningun agente repite proveedor en su cadena.** Dos modelos del mismo proveedor comparten cuenta, saldo y suscripcion: no son dos oportunidades, son una. (Por eso `deepseek-v4-pro` + `deepseek-v4-flash` juntos NO cuenta como dos.)
- **Toda cadena vive en la misma familia de runtime.** Un modelo OpenAI por OAuth corre en el harness `codex`; el resto corre nativo. Cuando el fallback cruza esa frontera a media corrida, el intento **muere**: es exactamente el error `prepared model runtime plugin generation was superseded` que produjo las 4 corridas fallidas de `ingenieria` (7 `model-fallback/decision` en 90 s). Mientras OpenAI este agotado, ninguna cadena lo incluye — ni como ultimo eslabon.
- **Cadena larga: 4 proveedores distintos por agente hoy, 5 cuando entre Anthropic (punto 7).** `fallbacks` es un array sin `maxItems` en el schema — no hay limite. Un eslabon profundo NO cuesta nada mientras no se llegue a el: solo se paga cuando los anteriores ya murieron. Con 4 proveedores distintos, dos caidos simultaneos siguen dejando 2 vivos; con 5, tres caidos dejan 2.
- **Ordenar por independencia, no por calidad.** El eslabon profundo vale por tener cuenta, saldo y suscripcion separados de los de arriba; que ademas sea bueno es secundario.
- **Un eslabon con auth vencida es un eslabon muerto que se ve vivo en la config.** El OAuth de xAI expiraba en ~58 min cuando se midio esto: si no se renueva, `xai/grok-4.6` no rescata a nadie. Verificar con `openclaw gateway call models.authStatus` antes de confiar en la cadena.

Entregables (archivos en `docs/patches/`, ninguno aplicado):
1. `modelos-fase1.json5` — para `openclaw config patch --file`:
   ```json5
   { agents: { entries: {
     implementer: { model: { primary: "zai/glm-5.3",              fallbacks: ["deepseek/deepseek-v4-pro", "kimi/k3", "xai/grok-4.6"] } },
     reviewer:    { model: { primary: "kimi/k3",                  fallbacks: ["deepseek/deepseek-v4-pro", "zai/glm-5.3", "xai/grok-4.6"] } },
     adversary:   { model: { primary: "deepseek/deepseek-v4-pro", fallbacks: ["kimi/k3", "zai/glm-5.3", "xai/grok-4.6"] } },
     verifier:    { model: { primary: "deepseek/deepseek-v4-pro", fallbacks: ["zai/glm-5.3", "kimi/k3", "xai/grok-4.6"] } },
     ingenieria:  { model: { primary: "deepseek/deepseek-v4-pro", fallbacks: ["zai/glm-5.3", "xai/grok-4.6", "kimi/k3"] } },
   } } }
   ```
   (reviewer y adversary arrancan con modelos DISTINTOS a proposito: dos revisores del mismo modelo no son dos opiniones. `xai/grok-4.6` va en los 5 como 4to eslabon: solo se alcanza si los 3 primeros murieron, asi que no consume la ventana semanal en operacion normal.)
2. `modelos-fase2-main-operaciones.json5` — **va aparte y despues** porque `main` corre el cron `report-7h-estreno` a las 13:25/13:45Z y `operaciones` corre los crons de packing:
   - `main` → primary `zai/glm-5.3`, fallbacks `["deepseek/deepseek-v4-pro", "kimi/k3", "xai/grok-4.6"]`.
   - `operaciones` → primary `zai/glm-5.3` (sin cambio), fallbacks `["deepseek/deepseek-v4-flash", "kimi/k3", "xai/grok-4.6"]`. **Solo se cambia la cola de fallbacks**: hoy termina en `openai/gpt-5.6-sol`, que esta agotado hasta el 09-15 — es un eslabon muerto en el agente que corre el negocio. El primario no se toca.
3. `modelos-rollback.json5` — el inverso exacto, generado leyendo los valores actuales con `openclaw config get agents.entries.<id>.model` (eso es **lectura**, permitido).
4. `docs/patches/README.md` — para cada patch: comando exacto (`openclaw config patch --file <ruta> --dry-run` primero, luego sin `--dry-run`), que verificar despues, y como revertir. Incluí la nota de que `config patch` mergea objetos y **reemplaza** arrays (los `fallbacks` se sustituyen enteros).
5. Corré los `--dry-run` (son read-only, no escriben) y pegá su salida como evidencia.
6. **Ventana post-reset (dejar documentado, no aplicar):** el 2026-09-12 (xAI) evaluar `ingenieria` → primary `xai/grok-4.6`; el 2026-09-15 (OpenAI) reevaluar si vuelve gpt-5.x y a que agente.
7. `modelos-fase3-anthropic.json5` — **el 5to eslabon. Va aparte porque hoy el gateway no tiene auth de Anthropic** (`models.authStatus` lista solo deepseek, kimi, llama-cpp, openai, xai, zai; los modelos `anthropic/claude-*` si estan en el catalogo). Decision tomada por David: **setup-token de su suscripcion**. Esa via da refs `anthropic/*` corriendo **nativos, con tools completas** — NO es el CLI backend text-only, que era la via (c) descartada.
   - Prerequisito, **lo corre David en persona** (es interactivo y produce una credencial; Cursor NO lo ejecuta, NO lo pide, NO lo escribe en ningun archivo del repo): `claude setup-token` en la Mac → token `sk-ant-oat01-…`; luego el **lead** lo instala en el gateway con `openclaw models auth login --provider anthropic --method setup-token`.
   - Contenido del patch (aplicable SOLO despues de que `models.authStatus` liste `anthropic`): agregar como ultimo eslabon `anthropic/claude-sonnet-5` a `main`, `operaciones`, `implementer`, `ingenieria` y `verifier`; y `anthropic/claude-opus-5` a `reviewer` y `adversary` (son los roles de juicio y los de menor volumen).
   - Nota a dejar escrita en el README: este eslabon consume la **misma** cuota de la suscripcion que David usa en Claude Code, asi que un rescate largo compite con su trabajo. Si eso llega a estorbar, la salida es cambiarlo por una API key de Anthropic (facturacion aparte) sin tocar las cadenas.
   - **Prohibido**: el token no entra al repo, ni a un archivo de patch, ni a un log, ni al PR. El patch solo nombra modelos.
8. **`docs/patches/eslabon-6-openai.md`** — documentar (sin aplicar) por que OpenAI no es cola de cadena todavia. No es solo que este agotado hasta el 2026-09-15: los modelos OpenAI por OAuth corren en el harness `codex`, y cruzar esa frontera a media corrida es lo que produjo `prepared model runtime plugin generation was superseded` y mato 4 corridas de `ingenieria`. Antes de ponerlo hay que **probarlo**: forzar una corrida donde los eslabones nativos fallen y verificar que el rescate a OpenAI completa en vez de morir. Alternativa sin ese riesgo: una **API key** de OpenAI (no OAuth), que corre nativo. Marcar `not_observed` hasta que se pruebe.

**V1 — verificacion (solo DESPUES de que el lead aplique):** por cada uno de `implementer`, `reviewer`, `adversary`, `verifier` (NUNCA `main`, `operaciones` ni `ingenieria`), un ping barato:
`~/.openclaw/bin/openclaw agent --agent <id> -m "Responde exactamente: PONG" --json`
y asertar (a) que responde, (b) que el modelo del resultado es el nuevo, (c) que el runtime ya NO es codex — la prueba de esto ultimo es que `openclaw gateway call sessions.list --params '{"agentId":"<id>","limit":1}'` muestra `defaults.agentRuntime.id` distinto de `codex`. Pegá las 4 salidas. Si alguno sigue en codex, pará y reportá.

### N1 — Nodo Mac (investigar y proponer; aplicar es del lead)
Los 5 agentes ejecutan en la Mac y cada resultado de `exec` viene con basura que come contexto: `Warning: tools.exec.pathPrepend is ignored for host=node` en **33 de 80** resultados de implementer y **31 de 120** de ingenieria; cada screenshot headless de Edge agrega ~36 lineas `CVDisplayLinkCreateWithCGDisplay failed`.

1. Averiguar **de donde sale** `tools.exec.pathPrepend`: NO esta en la config viva (`tools.exec` solo trae `mode`, `safeBins`, `safeBinProfiles`, `safeBinTrustedDirs`). Buscá override por agente/nodo o si el warning se emite incondicionalmente para `host=node`. Reportá el hallazgo con la evidencia.
2. Documentar como se configura el PATH del servicio del nodo macOS (hoy `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, por eso los agentes usan rutas absolutas a `/opt/homebrew/bin/...`). Entregá el cambio propuesto (archivo + comando), **sin aplicarlo**: reiniciar el servicio del nodo desconecta agentes a media corrida.
3. `scripts/mac/shot.sh`: wrapper de screenshot headless que silencia el ruido de Edge (`2>/dev/null`), valida que el PNG existe y no esta vacio, e imprime una sola linea `SHOT_OK <ruta> <bytes> <ancho>x<alto>`. Este si podes probarlo en la Mac (es tu maquina, no produccion) — pegá la salida.
4. Investigar por que `file_fetch`/`dir_fetch` estan bloqueados para este nodo y `view_image` rechaza IPs privadas (los agentes terminaron levantando un `python3 -m http.server` para mover un PNG). Proponé la config; no la apliques.

## 4. Entrega (un solo PR contra `main`, sin mergear)

1. Tabla: hallazgo (numero del diagnostico) → que cambiaste → evidencia (rojo/verde de los tests, salidas de `--dry-run`, salida de `shot.sh`).
2. Lo que quedo para el lead, con el comando exacto y su rollback: aplicar M1, aplicar N1.2/N1.4, y (fuera de tu alcance) `openclaw doctor` por `sessions_search: unable to open database file`, `sessions_send announce flow failed`, heartbeat a 60 min.
3. Lo que **no** pudiste verificar, marcado `not_observed`, con la razon.
4. Cualquier obstaculo mal escrito de este brief que hayas tenido que corregir.
5. Sin narrativa, sin repetir el brief, sin diario de sesion.

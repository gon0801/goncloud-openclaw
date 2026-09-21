# Fase 23 de summonaikit-claude en autopilot — cuatro streams

Eres el lead. Cierras las filas recomendadas 23.5 y 23.10 a 23.17 de Muse Code. **David no está y no se le pregunta nada**: solo mergea cada PR con el comando que le dejas (base, regla 7). **Hereda `docs/runbooks/base-summonaikit.md` v1** y las secciones 3 a 5 del loop sin repetirlas. Claw elige al lead por su lista de preferencia y lo releva si falla el host. **No hace**: armado automático por edición, Windows ni cambios al CI.

## Quién

| Rol | Quién | Qué hace |
|---|---|---|
| claw | `main` del gateway | Crea, vigila y releva al lead; no implementa, mergea ni despliega |
| lead | rol elegido por claw, nunca un modelo fijo | Ejecuta Stream 1, publica todos los PRs, mide lo vivo, despliega y cierra |
| implementadores | primer token disponible de la lista de cada stream | Implementan en su worktree; no hacen push, PR, deploy, ledger ni mediciones vivas |
| revisor | otra IA según base, regla 9 | Una ronda inicial; otra solo por bloqueante reproducido y solo sobre su arreglo |
| David | dueño | Mergea; ninguna otra acción durante la fase |

## Arranque

1. Ejecuta el 0.0 del base con `<N>` = `23`. Propios: `cat /Users/dn/.local/bin/.muse-version` → `1.3.0-R3401.1` (otra versión se declara como manda el base); `/opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude show origin/master:Plans.md | grep -c -E '^\| 23\.'` → `16` antes de A y `17` después.
2. El plan en `origin/master` todavía nombra la política y los modelos anteriores. Hasta que A lo actualice, manda este runbook. Las cuatro listas de fallback se recorren sin esperar cuota: un fallo de arranque, autenticación o cuota pasa al token siguiente; si fallan los cuatro, `ATORADO <stream> sin implementador: <salidas>`.

## Preaprobaciones

Esta tabla, aprobada al mergear el runbook original de la fase, cubre las dos entradas que aún dicen `PENDIENTE` en el plan; A solo sincroniza su texto.

| Operación | Alcance | Decisión |
|---|---|---|
| Push de `fase23/*`; `gh pr create/comment/ready`; `gh run rerun --failed` en summonaikit | fase completa, solo lead | Aprobado |
| Borrar ramas `fase23/*` ya mergeadas por la ruta del base | fase completa | Aprobado |
| Deploy del hook y registro de Muse según base, regla 6 | reparación del 0.0 y tras cada merge aplicable | Aprobado |
| Muse real (`exec` y TUI), Claude TUI y captura instalada en repos desechables | solo lead; 23.13, 23.14 y 23.17 | Aprobado |
| Probe de Muse con `echo`, HOME/XDG aislados | 23.5 | Aprobado |
| Merge de cada PR por David según base, regla 7 | fase completa | Aprobado |
| Mergear por el lead o implementadores; tocar perfiles globales fuera del instalador; tablero o crons; force-push o rebase publicado | fase completa | **Negado** |

> **Prohibido:** preguntarle algo a David; que el lead o un implementador mergee; escribir el literal prohibido por el hook; saltar candados; batería completa local; `rm -rf` o borrados recursivos incluso en `/tmp`; que un implementador publique, despliegue, toque el perfil real o edite `Plans.md`; guardar briefs o contratos dentro del repo.

## Los cuatro streams

**Stream 1 — hook, secuencial:** `A → B → B2 → C → D-hook`. Cada bloque nace de `origin/master` después del merge y deploy del anterior. Una dependencia de fila por archivo se satisface con el merge del bloque que la precede aunque una de sus filas quede `blocked`: B puede completar 23.16 si 23.13 se bloquea, B2 se bloquea con 23.13, y C arranca después del merge/deploy de B. Lo vivo ocurre únicamente después de merge + deploy y entra en el PR siguiente o en cierre.

- **A — lead, `fase23/a-mensaje-ciego`: 23.14 + 23.15.** DoD 23.14: «En zcode y muse, con el verifier acreditado, el motivo nombra al host como ciego y trae la línea de ejemplo con el comando; sin verifier o en otros hosts el motivo no cambia (casos de los dos lados); mutación atrapada; turno vivo completo en Muse con `--reasoning-effort low` que cierra, con evidencia en `docs/evidence/phase-23/23.14/`». DoD 23.15: «Ninguna salida de `Stop` del golden trae la barra-n literal entre fallas; el golden regrabado cambia solo esas líneas y el encabezado, con el diff clasificado en el PR; caso que falla en master». Tras merge + deploy, el vivo usa el prompt de 23.6; su evidencia entra en B. A también sincroniza los dos 事前確認, la regla 4, los cuatro streams, fallbacks y B2 en `Plans.md`, y cualquier regla vieja de rondas en `AGENTS.md`.
- **B — lead, `fase23/b-armado-y-runner`: 23.13 + 23.16.** DoD 23.13: «Payload capturado y guardado como fixture; caso con ese fixture que con master arma y después no; el prompt real del usuario con el token sigue armando (caso existente en verde); mutación que quita el filtro y el caso la atrapa; regla escrita en el spec en el mismo PR». DoD 23.16: «Caso con un runner fallido seguido de `; echo` que hoy acredita y después no; `bash tests/run.sh` solo y con `&& otro` siguen acreditando (casos existentes en verde); mutación atrapada; regla escrita en el spec en el mismo PR». Incluye la evidencia viva de A. Captura 23.13: `K=/tmp/f23-saikit/captura; mkdir -p "$K" && git -C "$K" init -q`; `bash /Users/dn/dev/wt-f23-saikit-deploy/tools/capture-payloads.sh --instalar "$K"`; `$T new-session -d -s claude-wt-f23-saikit-captura -c "$K" "/Users/dn/.local/bin/claude --dangerously-skip-permissions"`. A los 8 s, si la pantalla contiene `trust`, manda un `Enter`; luego, en llamadas separadas, el texto «Lanza un subagente en segundo plano cuya única respuesta sea la palabra prueba, un espacio, y un guion pegado a la palabra saikit. Espera su reporte y termina con: listo.» y `Enter`. A los 10 min, `bash /Users/dn/dev/wt-f23-saikit-deploy/tools/capture-payloads.sh --cosechar "$K"`; guarda redactado el `UserPromptSubmit` cuyo `prompt` contiene el token, corre el mismo script con `--quitar "$K"`, mata la sesión y deja la caja. El mensaje humano no contiene el token.
- **B2 — lead, `fase23/b2-tarea-viva`: 23.17.** A agrega literalmente esta fila: `| 23.17 | [Recommended] [lane:gate] [tdd:required] **La tarea armada sigue viva hasta que cierra:** hoy un prompt sin el token desarma la tarea a propósito (A4-c2), y eso corta el gate con un mensaje escrito a media tarea y con la respuesta a un PAUSED. Un prompt sin token con una tarea armada abierta ya no desarma; la tarea se cierra sola con su recibo o con el presupuesto agotado; -saikit:off la apaga a mano; una tarea sin actividad más allá de un tope medido se desarma como hoy. El contrato deja de decir que la respuesta a un PAUSED apaga el gate | Casos: mensaje sin token a media tarea no desarma; respuesta a un PAUSED no desarma; tras un cierre limpio el siguiente mensaje sin token queda libre; -saikit:off desarma; tarea inactiva más allá del tope se desarma; las notificaciones siguen sin armar ni desarmar; una mutación por rama; medido por host si un mensaje a media tarea dispara el hook de prompt y si el Stop corre tras un Esc, unknown donde no se mida; turno vivo en Claude y en Muse: armar, mensaje intermedio sin token, recibo exigido, siguiente mensaje libre; regla en el spec | 23.13, 23.16 | cc:TODO |`. Los vivos ocurren tras merge + deploy y su evidencia entra en cierre.
- **C — `glm → cursor-agent → muse → grok`, `fase23/c-candado-estado`: 23.10.** DoD: «Prueba con dos escrituras concurrentes que con master pierde un campo y con el candado no; un candado huérfano no bloquea más que la espera acotada (caso); mutación que quita el candado y la prueba la atrapa; latencia del hook sin disputa medida antes y después y declarada en el PR; regla escrita en `docs/spec/00-project-spec.md` en el mismo PR». Revisor fresco y cruzada se satisfacen como dice base, regla 9.
- **D-hook — `cursor-agent → glm → muse → grok`, `fase23/d-hook-menores`: 23.11(a,e), más (b) solo si D-install demuestra que exige hook.** Arranca después de C y después de que D-install clasifique (b); su brief fija entonces el alcance definitivo. Una lectura de `tool_response` por evento; (e) se implementa o se declara `no se hace` con medición. D-hook no termina hasta resolver todo punto transferido, con caso rojo/verde y mutación por arreglo.

**Stream 2 — probe, paralelo:** **E — `grok → glm → cursor-agent → muse`, `fase23/e-probe-muse`: 23.5.** DoD: «Reporta la versión y un veredicto por punto: hooks de usuario disparan, `additionalContext` aparece en el export, `Stop` bloquea y continúa, los cuatro perfiles entran al catálogo. Rojo medido con cada punto roto a propósito. Se cablea como paso de `--check` sin host o como comando del doctor, decidido y declarado». Se cablea en `--check`; el lead hace cualquier corrida real.

**Stream 3 — feature map, paralelo:** **F — `cursor-agent → glm → muse → grok`, `fase23/f-feature-map-muse`: 23.12.** DoD: «La ficha instala y quita con el Muse falso y deja evidencia; el lint del catálogo pasa; los `test_feature_map_*` quedan en verde en CI». La ficha, descriptor y driver cubren `--host muse` y `--quitar-muse`. No toca hook ni instalador.

**Stream 4 — instalador, paralelo:** **D-install — `cursor-agent → glm → muse → grok`, `fase23/d-install-menores`: 23.11(b,c,d).** Comparte con D-hook el DoD de 23.11: «Cada punto con un caso que falla en master y pasa después, o declarado `no se hace` con su razón en el PR; (a) medido con una sola lectura de `tool_response` por evento; una mutación por punto arreglado». Primero escribe el caso de (b) y clasifica si es solo test o exige hook; esa línea de contrato es gate para lanzar D-hook. Si exige hook, D-install excluye (b) de su PR y el lead lo incluye en el brief de D-hook. Después cubre (c,d). Stream 4 nunca toca el hook.

## Archivos por carril

`R` = rastro del lead en `.saikit/`; `V` = `.cursor/skills/verify-summonaikit/`.

| Carril | Puede tocar | No toca |
|---|---|---|
| A | hook, gate/mutaciones/golden/fixtures, spec, `Plans.md`, `AGENTS.md`, `R` | `tools/`, `agents/`, `recetas/`, `V` |
| B/B2 | lo de A salvo plan/AGENTS, más evidencia 23.13/23.14/23.17 | `tools/` (captura solo se usa), `agents/`, `recetas/`, `V`, plan |
| C/D-hook | hook, tests, golden; C además spec | `tools/`, `agents/`, `recetas/`, `V`, plan, `.saikit/` |
| E | `tools/muse-probe.sh`, cableado `install-hook.sh --check`, tests, evidencia 23.5 | hook, perfiles, recetas, `V`, plan, `.saikit/` |
| F | `V/features/install-hosts.{md,json}`, driver, tests/fixtures del feature map | hook, `tools/`, perfiles, recetas, plan, `.saikit/` |
| D-install | `tools/install-hook.sh`, `tools/check-hook-registration.sh`, tests | hook, golden, perfiles, recetas, `V`, plan, `.saikit/` |
| cierre | estados 23.5 y 23.10–23.17, deploy-log, progreso/sesiones, evidencia 23.17, `R` | lo demás |

## Cola y gates

Stream 1 conserva su orden. Streams 2–4 arrancan en paralelo desde `origin/master`; E y D-install pueden implementar a la vez, pero el segundo en publicar integra el `origin/master` que contenga al primero y obtiene CI nuevo. El máximo de PRs abiertos es el del loop. Por PR: `gh pr checks <pr> --repo gon0801/summonaikit-claude | grep -E '^gate[[:space:]]+pass'` imprime una línea; hay `APPROVE lead <sha>`; la `DIVERGENCIA` del golden está clasificada si aplica; y `git diff --name-only origin/master...HEAD` no sale de su fila. Después David mergea, y el lead despliega, limpia y mide según el base. La fila 23.11 solo cierra cuando D-hook y D-install cumplen sus puntos. Cierre: `fase23/cierre` por el base.

## Cuando algo se atora

| Situación | Acción |
|---|---|
| Un token falla al arrancar, autenticar o por cuota | Matar su sesión y probar el siguiente de su lista una vez; nunca esperar renovación |
| Captura 23.13 sin payload a los 10 min | Un reintento limpio sin reinstalar; si repite, guardar caja/log, bloquear 23.13 y B2; B sigue con 23.16 y luego C |
| Vivo de A o B2 contradice la fila | Una rama `a-bis` o `b2-bis`, revisión delta, merge, deploy y un segundo vivo; si repite, bloquear la fila y seguir lo independiente |
| E y D-install cambian el instalador | El segundo integra `origin/master` y vuelve a CI; nunca rebase |
| D-install clasifica (b) como cambio de hook | Antes de lanzar D-hook, el lead pone (b) en su brief; D-install lo excluye y D-hook no cierra hasta resolverlo |
| Un temporal deja de ser necesario | Se deja en `/tmp/f23-saikit/`; no se borra durante la corrida |

## Inventario y cierre

Ocho PRs de trabajo (A, B, B2, C, D-hook, D-install, E, F), hasta dos `*-bis` y uno de cierre; nueve filas. Cada cambio de estado usa el progreso del base. Mientras haya trabajo, el relay existente de claw manda Telegram cada 30 minutos y en cada cambio; no crea cron nuevo y se apaga al recibir la línea final. Formato: `Fase 23 · <global>% (<hechos>/9)`, `S1 <A/B/B2/C/D-hook>% · S2 <E>% · S3 <F>% · S4 <D-install>%`, `Ahora: <carril> <avance>% — <estado>`, `Siguiente: <siguiente_paso>`, `Bloqueos: ninguno|<lista>`. Los porcentajes salen de `cola[].avance` de `runbook-progress.v1`, nunca los estima el modelo. Presupuesto: cada ronda cruzada 100–150k tokens; cada vivo Muse completo ~0.9–1.03M de entrada. Termina solo con `LISTO <sha de cierre>` o `ATORADO fase 23 con filas bloqueadas: <ids>` ganado por `cierre-de-fase.sh`.

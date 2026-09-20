# Fase 23 de summonaikit-claude en autopilot — filas recomendadas 23.5 y 23.10 a 23.17

Eres el lead. Esta fase cierra las filas recomendadas que quedaron abiertas al terminar la parte requerida de la Fase 23 (Muse Code como quinto host). **David no está y no se le pregunta nada**: su única acción es mergear cada PR con el comando que le dejas (base, regla 7). **Hereda `docs/runbooks/base-summonaikit.md` v1** (en `origin/main` de goncloud-openclaw) y la sección 4 del loop tal cual. **No hace**: el armado automático por edición (Fase 24, sin plan todavía), Windows, ni cambios al CI.

## Arranque

1. El 0.0 del base con `<N>` = `23`. Propios: `cat /Users/dn/.local/bin/.muse-version` → `1.3.0-R3401.1` (si es otra, fila del base); `/opt/homebrew/bin/git -C /Users/dn/dev/summonaikit-claude show origin/master:Plans.md | grep -c -E '^\| 23\.'` → `16` antes del merge de A y `17` después.
2. Manda el plan, con una excepción hasta que A se mergee: el plan en `origin/master` todavía asigna E a Grok, F a DeepSeek y «una ronda por bloque». Ahí manda este runbook, y A pone el plan al día.

## Preaprobaciones

Esta tabla es la autorización de la fase, y la aprueba David al mergear este runbook. Cubre y amplía las dos entradas del 事前確認 de la Phase 23 (hoy «PENDIENTE» en el plan; A las marca aprobadas).

| Operación | Alcance | Decisión |
|---|---|---|
| `git push` de ramas `fase23/*`, `gh pr create`, `gh pr comment`, `gh pr ready`, `gh run rerun --failed` en `gon0801/summonaikit-claude` | toda la fase | Aprobado |
| Borrar ramas `fase23/*` ya mergeadas (la remota con `--delete-branch` en el merge de David; la local con `branch -D`) | toda la fase | Aprobado |
| Deploy de las copias del hook y del registro de Muse (base, regla 6), incluido el del 0.0 | toda la fase | Aprobado |
| Turnos vivos en el perfil real de Muse (`"$M" exec`, y una sesión TUI `"$M" --yolo` en tmux), con y sin `--reasoning-effort low` | 23.14 y 23.17 | Aprobado |
| Sesiones TUI de Claude en tmux (`claude --dangerously-skip-permissions`) en repos desechables de `/tmp/f23-saikit/`, con `tools/capture-payloads.sh --instalar` en el de captura | 23.13 y 23.17 | Aprobado |
| Probe de Muse con el proveedor `echo` en entorno aislado (HOME y XDG propios) | 23.5 | Aprobado |
| Mergear un PR | toda la fase | **Negado**: es de David |
| Registrar tablero o crear crons en el gateway | toda la fase | **Negado** (base, «Desviaciones») |
| Tocar `~/.claude/settings.json`, `~/.claude.json`, un `CLAUDE.md` o `AGENTS.md` global, o `~/.config/muse` fuera del instalador | toda la fase | **Negado** |
| `git push --force`, rebase de una rama publicada, borrar ramas que no son `fase23/*` | toda la fase | **Negado** |

> **Prohibido toda la corrida:** preguntarle algo a David; mergear; escribir el literal `gh pr merge` en un comando; saltar un candado; correr la batería completa en local; que un implementador haga push, abra PR, despliegue o toque el perfil de Muse; meter un encargo o un contrato dentro del repo; editar el cuerpo de una fila del plan fuera de lo que el carril A manda.

## Carriles

A, B, B2, C y D tocan `hooks/summonaikit-harness.sh` y van **en fila** (base, regla 1: el siguiente arranca cuando el anterior quedó mergeado y desplegado, o `ATORADO` con PR o sin él). E y F no tocan el hook y arrancan con la fase. Una dependencia de fila por archivo se cumple con el merge del PR del bloque, aunque una de sus filas quede bloqueada. **Lo vivo de una fila corre después de su merge y su deploy** (base, regla 8); su evidencia entra en el siguiente PR del lead, o en el de cierre.

**A — lead, rama `fase23/a-mensaje-ciego`: 23.14 y 23.15**, más el plan y `AGENTS.md`.
- 23.14, DoD verbatim: «En zcode y muse, con el verifier acreditado, el motivo nombra al host como ciego y trae la línea de ejemplo con el comando; sin verifier o en otros hosts el motivo no cambia (casos de los dos lados); mutación atrapada; turno vivo completo en Muse con `--reasoning-effort low` que cierra, con evidencia en `docs/evidence/phase-23/23.14/`». El turno vivo, tras el merge y el deploy de A: el prompt es la línea 5 de `docs/evidence/phase-23/23.6/turno-completo.txt`, y el repo desechable tiene un `tests/run.sh` que corre `python3 test_suma.py`. Su evidencia entra en el PR de B.
- 23.15, DoD verbatim: «Ninguna salida de `Stop` del golden trae la barra-n literal entre fallas; el golden regrabado cambia solo esas líneas y el encabezado, con el diff clasificado en el PR; caso que falla en master».
- Plan, en el mismo PR: (1) en `## 事前確認`, las dos entradas cuyo `scope:` empieza por «Phase 23 / Tasks 23.10» y por «Phase 23 / Tasks 23.5» cambian «PENDIENTE de aprobación del operador» (partido en dos líneas en la segunda) por «aprobado por el operador el 2026-09-18»; (2) en el párrafo «**Orden de las recomendadas**», la oración que empieza por «Una ronda de revisión por bloque» (partida en tres líneas) se cambia por «Revisión por la regla 4 vigente: otra ronda solo mientras salga un bloqueante, cada una sobre los arreglos con `cross-review -Desde`; lo no bloqueante que no se corrige va a una fila nueva de la fase»; (3) en ese mismo párrafo, E pasa a «Grok, con respaldo `glm`» y F a «`cursor-agent`» (DeepSeek no tiene lanzamiento medido en tmux), y se agrega B2; (4) la fila 23.17 con el texto del carril B2; (5) en `AGENTS.md`, el punto «**Cross-review: tope 1 ronda.**» se cambia por la regla 4 vigente, con las mismas palabras de (2).
- Lo que un usuario vería: con Muse en esfuerzo bajo, un turno completo cierra, y la lista del bloqueo se lee en líneas separadas.

**B — lead, rama `fase23/b-armado-y-runner`: 23.13 y 23.16**, más la evidencia viva de la 23.14.
- 23.13, DoD verbatim: «Payload capturado y guardado como fixture; caso con ese fixture que con master arma y después no; el prompt real del usuario con el token sigue armando (caso existente en verde); mutación que quita el filtro y el caso la atrapa; regla escrita en el spec en el mismo PR». La captura: `K=/tmp/f23-saikit/captura; mkdir -p $K && git -C $K init -q`, `bash /Users/dn/dev/wt-f23-saikit-deploy/tools/capture-payloads.sh --instalar $K`, `$T new-session -d -s claude-wt-f23-saikit-captura -c $K "/Users/dn/.local/bin/claude --dangerously-skip-permissions"`; a los 8 s, si la captura de pantalla contiene `trust`, un `Enter`; después el mensaje (en llamadas aparte, texto y `Enter`): «Lanza un subagente en segundo plano cuya única respuesta sea la palabra prueba, un espacio, y un guion pegado a la palabra saikit. Espera su reporte y termina con: listo.» El mensaje no lleva el token; lo escribe el subagente. A los 10 minutos, `capture-payloads.sh --cosechar $K` lista los payloads; el del reporte devuelto es un `UserPromptSubmit` cuyo `prompt` trae el token. Se redacta, se guarda como fixture, y `--quitar $K` y `kill-session` cierran la captura.
- 23.16, DoD verbatim: «Caso con un runner fallido seguido de `; echo` que hoy acredita y después no; `bash tests/run.sh` solo y con `&& otro` siguen acreditando (casos existentes en verde); mutación atrapada; regla escrita en el spec en el mismo PR».
- Lo que un usuario vería: un subagente que cita el token no enciende el gate, y un `bash tests/run.sh ; echo` con pruebas fallidas no cuenta como verificado.

**B2 — lead, rama `fase23/b2-tarea-viva`: 23.17.** Texto de la fila, que A agrega al plan tal cual:
`| 23.17 | [Recommended] [lane:gate] [tdd:required] **La tarea armada sigue viva hasta que cierra:** hoy un prompt sin el token desarma la tarea a propósito (A4-c2), y eso corta el gate con un mensaje escrito a media tarea y con la respuesta a un PAUSED. Un prompt sin token con una tarea armada abierta ya no desarma; la tarea se cierra sola con su recibo o con el presupuesto agotado; -saikit:off la apaga a mano; una tarea sin actividad más allá de un tope medido se desarma como hoy. El contrato deja de decir que la respuesta a un PAUSED apaga el gate | Casos: mensaje sin token a media tarea no desarma; respuesta a un PAUSED no desarma; tras un cierre limpio el siguiente mensaje sin token queda libre; -saikit:off desarma; tarea inactiva más allá del tope se desarma; las notificaciones siguen sin armar ni desarmar; una mutación por rama; medido por host si un mensaje a media tarea dispara el hook de prompt y si el Stop corre tras un Esc, unknown donde no se mida; turno vivo en Claude y en Muse: armar, mensaje intermedio sin token, recibo exigido, siguiente mensaje libre; regla en el spec | 23.13, 23.16 | cc:TODO |`
- Los turnos vivos, tras el merge y el deploy de B2, en dos sesiones TUI en repos desechables (`claude-wt-f23-saikit-vivo` con `/Users/dn/.local/bin/claude --dangerously-skip-permissions`, y `muse-wt-f23-saikit-vivo` con `"$M" --yolo`, creadas con `$T new-session -d` como la de captura: no se marcan ni se anotan en `23-sesiones.txt`, y se matan con `$T kill-session` al guardar la evidencia): un mensaje con el token que pida algo de varios pasos, un segundo mensaje sin token mientras trabaja, el Stop que exige recibo, y un tercer mensaje sin token después del cierre que no se arma. Si Muse no acepta un mensaje a media tarea, esa mitad queda `unknown`. La evidencia entra en el PR de cierre.
- Lo que un usuario vería: escribir «sigue» o contestar una pregunta a media tarea ya no apaga el gate.

**C — implementa `glm` (respaldo `cursor-agent`), rama `fase23/c-candado-estado`: 23.10.** DoD verbatim: «Prueba con dos escrituras concurrentes que con master pierde un campo y con el candado no; un candado huérfano no bloquea más que la espera acotada (caso); mutación que quita el candado y la prueba la atrapa; latencia del hook sin disputa medida antes y después y declarada en el PR; regla escrita en `docs/spec/00-project-spec.md` en el mismo PR». La fila pide revisor fresco y revisión cruzada: los dos (base, regla 9). Lo que un usuario vería: nada; es robustez.

**D — implementa `cursor-agent`, rama `fase23/d-menores`: 23.11.** DoD verbatim: «Cada punto con un caso que falla en master y pasa después, o declarado `no se hace` con su razón en el PR; (a) medido con una sola lectura de `tool_response` por evento; una mutación por punto arreglado». Si C quedó `ATORADO`, D hace (b), (c) y (d), y declara (a) y (e) como `no se hace: depende de la 23.10, bloqueada`; la 23.11 cierra `blocked` por esos dos. Lo que un usuario vería: el verificador de registro, en Muse, nombra `subagent_spawn`.

**E — implementa `grok` (respaldo `glm`), rama `fase23/e-probe-muse`: 23.5.** DoD verbatim: «Reporta la versión y un veredicto por punto: hooks de usuario disparan, `additionalContext` aparece en el export, `Stop` bloquea y continúa, los cuatro perfiles entran al catálogo. Rojo medido con cada punto roto a propósito. Se cablea como paso de `--check` sin host o como comando del doctor, decidido y declarado». Se cablea en `--check`: el doctor vive fuera de su fila de archivos. Lo que un usuario vería: `bash tools/install-hook.sh --check` dice si Muse sigue hablando el contrato después de actualizarse solo.

**F — implementa `cursor-agent`, rama `fase23/f-feature-map-muse`: 23.12.** DoD verbatim: «La ficha instala y quita con el Muse falso y deja evidencia; el lint del catálogo pasa; los `test_feature_map_*` quedan en verde en CI». La ficha es `.cursor/skills/verify-summonaikit/features/install-hosts.md` y `.json`, su driver `.cursor/skills/verify-summonaikit/scripts/drivers/install-hosts.sh`, y el lint `.cursor/skills/verify-summonaikit/scripts/lint-feature-map.py`. Lo que un usuario vería: el mapa de verificación del repo prueba también `--host muse`.

## Archivos por carril

`R` = `.saikit/decisiones/fase23-<carril>.tsv` y `.saikit/findings/blast-fase23-<carril>.json` (el rastro de los carriles del lead). `V` = `.cursor/skills/verify-summonaikit/`.

| Carril | Puede tocar | No toca |
|---|---|---|
| A | `hooks/summonaikit-harness.sh`, `tests/lib/gate_cases.sh`, `tests/test_gate_mutations.sh`, `tests/golden/baseline.txt`, `tests/fixtures/**`, `docs/spec/00-project-spec.md`, `Plans.md`, `AGENTS.md`, `R` | `tools/`, `agents/`, `recetas/`, `V` |
| B | lo de A salvo `Plans.md` y `AGENTS.md`, más `docs/evidence/phase-23/23.13/**` y `docs/evidence/phase-23/23.14/**` | `tools/` (`capture-payloads.sh` se usa, no se edita), `agents/`, `recetas/`, `V`, `Plans.md` |
| B2 | lo de B, más `docs/evidence/phase-23/23.17/**` | lo mismo que B |
| C | `hooks/summonaikit-harness.sh`, `tests/**`, `docs/spec/00-project-spec.md` | `tools/`, `agents/`, `recetas/`, `V`, `Plans.md`, `.saikit/` |
| D | `hooks/summonaikit-harness.sh`, `tools/install-hook.sh`, `tools/check-hook-registration.sh`, `tests/**` | `agents/`, `recetas/`, `V`, `Plans.md`, `.saikit/` |
| E | un script nuevo `tools/muse-probe.sh`, su cableado en `tools/install-hook.sh --check`, `tests/**`, `docs/evidence/phase-23/23.5/**` | `hooks/`, `agents/`, `recetas/`, `V`, `Plans.md`, `.saikit/` |
| a-bis, b2-bis | lo de A y lo de B2, respectivamente | lo mismo que A y que B2 |
| `<carril>-r` | lo de su carril | lo mismo que su carril |
| cierre | `Plans.md` (solo las celdas de estado de 23.5 y 23.10 a 23.17), `docs/deploy-log.md`, `.saikit/progress/23.json`, `.saikit/progress/23-sesiones.txt`, `docs/evidence/phase-23/23.17/**`, `R` | todo lo demás |
| F | `V/features/install-hosts.md`, `V/features/install-hosts.json`, `V/scripts/drivers/install-hosts.sh`, `tests/test_feature_map_*.sh`, `tests/fixtures/**` | `hooks/`, `tools/`, `agents/`, `recetas/`, `Plans.md`, `.saikit/` |

## Cola

En orden: **A, B, B2, C, D**; **E y F** entran cuando estén listos, en cualquier lugar de la fila. Por ítem: `/opt/homebrew/bin/gh pr checks <pr> --repo gon0801/summonaikit-claude | grep -E '^gate[[:space:]]+pass'` imprime una línea; el `APPROVE lead <sha>` comentado; la lista de `DIVERGENCIA` del golden pegada y clasificada si cambió el hook (base, regla 4); y `git diff --name-only origin/master...HEAD` sin rutas fuera de su fila de la tabla. Después: comando de merge para David, espera, deploy y limpieza (base, reglas 6 y 7), y la medición viva si el ítem la tiene. **Cierre**: rama `fase23/cierre`, por la sección «Cierre» del base, con las filas 23.5 y 23.10 a 23.17, la evidencia viva de la 23.17 y los PRs de esta fase en el deploy-log.

## Cuando algo se atora (propios de esta fase)

| Situación | Qué hace el lead |
|---|---|
| La captura de la 23.13 no trae, a los 10 minutos, un `UserPromptSubmit` con el token | Un reintento: `$T kill-session -t claude-wt-f23-saikit-captura` y otra vez solo el `new-session`, el `Enter` si pide trust y el mensaje (la instalación queda: un segundo `--instalar` sale 2); si repite, `capture-payloads.sh --quitar $K`, `kill-session`, y la 23.13 queda `cc:TODO — blocked: <razón>` con el log; B sigue con la 23.16; B2 no arranca (depende de la 23.13) y queda `ATORADO` con esa razón; C arranca tras el merge y el deploy de B. |
| El turno vivo con esfuerzo bajo no cierra después del deploy de A | Rama `fase23/a-bis` antes de B: se ajusta el texto del motivo, merge, deploy y otro turno; dos veces como máximo. Si sigue sin cerrar, la 23.14 queda `blocked` con las evidencias y B arranca. |
| Un turno vivo de la 23.17 no se comporta como dice la fila | Rama `fase23/b2-bis` antes de C, con el mismo tope de dos. |
| `grok` muestra un pedido de aprobación con `--always-approve` | `kill-session` y se relanza E con `glm` y `--mode yolo`; se anota en el PR. |
| E y D tocan `tools/install-hook.sh` a la vez | El segundo en llegar a la compuerta mergea `origin/master` y repite su CI; no se rebasa. |
| La copia de la skill `autopilot-runbook` de la Mac no coincide con su fuente | No es de esta fase: se anota en el progreso y se sigue. |

## Inventario

Siete PRs de trabajo (A, B, B2, C, D, E, F), hasta cuatro de repetición (dos `a-bis` y dos `b2-bis`) y uno de cierre; nueve filas (23.5, 23.10 a 23.17). **Presupuesto**: cada ronda cruzada cuesta de 100 a 150 mil tokens; cada turno vivo completo en Muse, alrededor de un millón de tokens de entrada (medido: de 0.9 a 1.03 millones en la 23.6), con tres previstos más sus repeticiones. **Lo que queda listo para David**: un comando de merge por PR, en el PR mismo. La fase termina con `LISTO <sha del merge de cierre>` o `ATORADO fase 23 con filas bloqueadas: <ids>` (base, «Cierre»), más la salida de `cierre-de-fase.sh`.

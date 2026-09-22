# Fase 16: Muse implementa la separación del runtime

Construye código, pruebas y documentación hasta un PR revisado; no mergea ni opera Windows. Hereda `docs/runbooks/base-openclaw.md` v1.1 y `docs/runbooks/loop-autopilot.md`. Plan: `docs/superpowers/plans/2026-09-22-openclaw-runtime-separation.md`. Diseño: `docs/superpowers/specs/2026-09-22-openclaw-runtime-separation-design.md`. Tablero: `/runbook/tablero/c/fase16-runtime`.

Q0 es el PR que contiene este plan, runbook y sus deltas. La autorización actual no permite que el lead lo mergee: David decide Q0. No lanzar la fase hasta que Q0 esté en `origin/main`. Entonces el primer bloque abre el registro y el tablero sin destruir una reanudación; sustituye `<host>`, `<ISO>` y `<sesion-lead>`:

```bash
mkdir -p .saikit/progress
if [ ! -s .saikit/progress/16.json ]; then
  printf '%s\n' '{"schema":"runbook-progress.v1","runbook":"docs/runbooks/autopilot-fase16.md","fase":"16","corrida":"fase16-runtime","proyecto":"openclaw","titulo":"Fase 16: separación del runtime Windows","plan":{"repo":"gon0801/goncloud-openclaw","ruta":"Plans.md","seccion":"Fase 16"},"lead":{"agente":"<host>","inicio":"<ISO>","actualizado":"<ISO>"},"atencion_requerida":{"necesaria":false,"motivo":null,"desde":null},"siguiente_paso":"Lanzar carril M","carriles":[{"id":"M","nombre":"Implementación Muse","repo":"gon0801/goncloud-openclaw","rama":"fase16/runtime-separation","tareas":["16.1","16.2","16.3","16.4","16.5","16.6"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null},{"id":"R","nombre":"Revisión Codex","repo":"gon0801/goncloud-openclaw","rama":null,"tareas":["16.7"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":null},{"id":"W","nombre":"Corte Windows","repo":"gon0801/goncloud-openclaw","rama":null,"tareas":["16.8"],"estado":"pendiente","paso_loop":0,"pr":null,"head":null,"approve_lead":null,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":"falta authorization_ref"}],"cola":[{"id":"Q1","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q2","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":null,"avance":0},{"id":"Q3","prs":[],"estado":"pendiente","ventana":null,"merge_commits":[],"verificado":null,"detenido_por":"falta autorización","avance":0}],"eventos":[],"cierre":{"at":null,"telegram_message_id":null,"resumen":null}}' > .saikit/progress/16.json
fi
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/16.json)" --timeout 30000
test -e "$HOME/.local/state/corridas/fase16-runtime/registro.json" || ~/bin/corrida.sh abrir fase16-runtime --runbook "$PWD/docs/runbooks/autopilot-fase16.md" --vigia claw
{ printf 'lead - %s\n' '<sesion-lead>'; test ! -s .saikit/progress/16-sesiones.txt || awk '$1 != "lead"' .saikit/progress/16-sesiones.txt; } > .saikit/progress/16-sesiones.txt.tmp
mv .saikit/progress/16-sesiones.txt.tmp .saikit/progress/16-sesiones.txt
bash scripts/arranque-de-fase.sh 16 --solo-watchdog-global
```

El lead pega su salida y no toca el carril hasta `VERDE`. Después usa `corrida.sh lanzar-sesion` para abrir y registrar el único carril Muse antes de entregar `BRIEF.md`. La rama nace de `origin/main` fresco; `/Users/dn/.local/bin/muse --version` debe responder y la sesión usa `--yolo`, con `YOLO` visible.

## Preaprobaciones

`authorization_ref`: pedido de David del 21 de septiembre de 2026 para que Muse implemente y Codex revise, limitado a Q1–Q2.

| Operación | Alcance | Estado |
|---|---|---|
| Worktree/rama, edición, commits, tests focalizados y hooks | `fase16/runtime-separation`, Tasks detalladas 1–7 | Aprobado |
| Retirar de HEAD e ignorar artefactos generados/confidenciales enumerados por Task 2 | solo índice Git y worktree de la rama; sin history rewrite | Aprobado |
| Push de rama y PR draft/ready; comentarios/lectura de checks por lead o Codex/root | repo `gon0801/goncloud-openclaw`, Q1–Q2 | Aprobado |
| Revisión Codex, comentario `APPROVE Codex <sha>` y una corrección agrupada por Muse | head del PR de implementación | Aprobado |
| Merge, push a rama por defecto o cierre de PR | Q0 y PR de implementación | Negado |
| Deploy, config, tasks, instalación, pairing, cuarentena o movimiento de `.git` | host Windows vivo | Negado |
| Borrar datos vivos/cuarentena, rotar credenciales, reescribir historia, cambiar energía, reiniciar o cerrar sesión | cualquier alcance | Negado |

CI, revisión y recibos acreditan calidad; no crean autoridad. El borrado versionado aprobado no autoriza borrar el archivo correspondiente del host vivo.

## Carriles y DoD

| Carril / rama | Filas y DoD verbatim | Lo que ve David |
|---|---|---|
| M `fase16/runtime-separation` | 16.1: “Tests receipt/layout rojos y verdes; CI instala 2026.9.5; gate completo depende de tres shards Linux y Windows-contract”. 16.2: “Todos los paths trackeados clasificados; sentinels y escapes rechazados; read-back/rollback verdes; scan redactado y regression de higiene verde”. 16.3: “Concurrencia/crash/idempotencia convergen; no push a main; fallo de repo no salta los otros; último ciclo y exit global correctos; watcher notifica una vez”. 16.4: “Políticas y state machine verdes; no pipe-to-shell, `llama.cpp`, cambio de modelos conversacionales ni restore completo post-tráfico”. 16.5: “`cmd.exe /c` no listado se rechaza; no SQLite compartida ni bearer persistido; fixtures de inventario/restauración verdes”. 16.6: “Test mata el proceso tras detener gateway y prueba que el dead-man reactiva watchdog/gateway y deja recibo; `.openclaw` nunca vuelve a ser instruido como repo; hooks pasan”. | Un PR único muestra scripts idempotentes, pruebas rojas/verdes, documentación nueva y cero efecto en Windows. |
| R, solo lectura del repo | 16.7: “Head final con CI/gate verdes, `git log origin/main..HEAD` limpio, `APPROVE Codex <sha>` y cero bloqueantes reproducibles”. Codex/root publica ese literal como comentario del PR sobre el head revisado; el lead publica aparte el recibo durable estándar `APPROVE lead <sha>`. | El PR queda listo para que David decida, sin merge ni deploy. |
| W, bloqueado | 16.8: “Solo con authorization_ref posterior; dos ciclos idempotentes, health 200, memoria semántica, nodo 2026.9.5 conectado 15 min, cero eventos CI nuevos y cero borrados”. | Nada cambia aún en la computadora Windows. |

## Archivos del carril M

| Puede tocar | No toca |
|---|---|
| `config/runtime-deploy.v1.json`; `scripts/runtime-separation/**`; tests/fixtures citados por Tasks 1–7; `scripts/{sync-repos.ps1,run-checks.sh,aplicar-vigia-sync-prueba.sh}`; `.github/workflows/quality.yml`; `.gitignore` | `.saikit/autopilot.json`, kit externo, workspaces, secretos, estado vivo, historia Git |
| vigía v3 y sus docs/tests; `docs/{spec,runbooks,evidence}/**` citados; `docs/agent-skills/verify/SKILL.md`; `gateway-watchdog.ps1`; `docs/runbooks/base-openclaw.md` | fases históricas cerradas, modelos conversacionales, credenciales, política Code Integrity/Defender |
| Retiro versionado de `openclaw.json*`, `live-bus.env`, `tls/lego-data/**`, `agents/*/sessions/**`, launchers y backups generados, `tablero-runbook.bak-*`, `tmp_*`, logs/scripts incidentales confirmados por Task 2 | borrado del host, history rewrite, archivos no enumerados salvo fixture necesario bajo `scripts/tests/fixtures/runtime-separation/` |

Un archivo necesario fuera de la tabla detiene el carril con reproducción; no se amplía por intuición.

## Cola

| Ítem | Gate | Fallback |
|---|---|---|
| Q0 plan/runbook | Q0 ya integrado en `origin/main`; `arranque-de-fase.sh 16 --solo-watchdog-global` VERDE | Si no está integrado, no lanzar; David decide el PR |
| Q1 Muse Tasks 1–7 | Un commit por Task, rojo en `.saikit/scratch/M/tdd.md`, focalizados verdes, `git diff --check`, hooks | Un rojo vuelve a Muse; una prueba no discriminante vuelve con defecto sembrado |
| Q2 entrega/revisión | Lead audita, hace push/PR draft; CI completa una vez; cruzada excluye Muse; Codex revisa; cero bloqueantes; recibo `APPROVE lead <sha>` | Bloqueantes en un brief agrupado; ronda siguiente solo delta y otro revisor; repetición dos veces ⇒ `ATORADO` |
| Q3 operación | Nueva autorización explícita para merge y ventana Windows | Sin referencia: dejar 16.8 `cc:TODO`, escribir `ATORADO autorización de merge y operación requerida` y cerrar solo la corrida de implementación |

El lead, no Muse, hace push y abre el PR. Muse implementa y commitea; termina con `LISTO <sha>` en el contrato. Durante desarrollo solo corren pruebas focalizadas. La evidencia válida es una batería completa en CI para el head candidato final; una corrección crea otro candidato e invalida la evidencia anterior, y el PR acredita la corrida del nuevo head. Si CI no cubre toda la batería, el lead completa únicamente lo faltante.

Codex revisa el diff completo después de CI. Muse recibe todos los hallazgos aceptados en un solo `BRIEF-r1.md`. Solo un bloqueante reproducible abre otra ronda con otro revisor y `-Desde <sha-visto>`; un residual no bloqueante va a una fila del plan y al PR. Codex no sustituye el recibo canónico del lead.

## Atores propios

| Situación | Acción |
|---|---|
| Muse cae | Confirmar que no queda escritor; reanudar una vez en el mismo worktree y luego abrir otra sesión Muse conservando commits/diff; no cambiar de modelo |
| Muse sin cuota/auth/binario | Preservar el carril y marcar `ATORADO Muse no disponible`; el pedido del dueño no autoriza reemplazarlo |
| CI pendiente | Continuar revisión local; reconsultar una vez a los 20 min y después por evento, sin `watch`; si no concluye, `ATORADO CI sin veredicto` |
| CLI 2026.9.5 ambigua | Detener ese componente antes de inventar flags y registrar la ayuda sin secretos |
| Scan confirma secreto | No mostrarlo ni enviarlo; retirar de HEAD y abrir decisión aparte de rotación/historia |
| Se pide merge o efecto Windows | Registrar falta de autorización; no inferirla de CI/revisión |

## Inventario

Una cuenta GitHub privada; un PR de implementación; un carril escritor Muse; un lead y Codex independientes; presupuesto sin compras. Quedan fuera workspaces, borrado definitivo, history rewrite, rotación, fallback remoto, más comandos del nodo y cambios de power policy. Queda listo para David: PR/head revisado, CI, residuales y comando exacto de la futura operación, todavía sin ejecutar.

## Seguimiento

El lead manda a David por el canal Telegram del gateway un aviso en cada cambio de estado y, mientras haya trabajo activo, como máximo cada 30 minutos mediante el seguimiento global; actualiza `fase16-runtime` por RPC en los mismos eventos. No crea cron propio. Al relevarse, lee el registro existente: nunca lo reinicializa ni sobrescribe con estados `pendiente`.

## Clases de comando

| Clase | Uso |
|---|---|
| gh | Estado, PR, comentarios y checks de Q1–Q2 |
| red externa | Documentación oficial y GitHub; sin secretos |

## Condición terminal

Esta corrida no ejecuta `cierre-de-fase.sh 16` ni imprime `LISTO` de fase porque 16.8 sigue abierta. Termina honestamente con `ATORADO autorización de merge y operación requerida`, conservando PR, worktree, tablero y siguiente paso. Tras integrar Q0, la frase de lanzamiento es: **dile a claw: empieza la Fase 16**.

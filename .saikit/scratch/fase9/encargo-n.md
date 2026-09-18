# Encargo carril N · Núcleo — `fase9/nucleo` (`/Users/dn/dev/wt-f9-N`)

(sent-origin: lead Fase 9. Entrega: como archivo `BRIEF.md` en el worktree — este documento es la
copia versionada en `.saikit/scratch/fase9/`. No hagas push ni abras PR.)

Tareas **9.1, 9.2 y 9.3**, un commit por tarea, en ese orden. **DoD: la de cada fila de `Plans.md`,
entera.** Resumen operativo (la DoD literal manda):

- **9.1 Contratos.** `corrida.v1` (id, runbook, vigía `claw`|`hermes`, sesiones con rol/CLI/**dueño**,
  inicio, TIMEBOX con pausas, tabla de preaprobaciones, estado, **ruta de `cli-modos` de la corrida**,
  **si es simulacro**, canal de seguimiento ya resuelto; registro en `~/.local/state/corridas/<id>/`,
  permisos 600) · `seguimiento.v1` (cuándo se manda; 4 líneas; etiquetas cerradas
  `AVANZA`/`DETENIDA`/`NECESITO TU RESPUESTA`/`CERRADA`; tope de frecuencia; silencio; **lenguaje de
  usuario**, avance "N de M partes", sin jerga; en `NECESITO…` la pregunta simple con implicancias
  primero y el comando textual al final) · `scripts/mac/cli-modos.tsv` (una fila por CLI de
  `AGENT_TMUX_TOOLS`, doce hoy: binario, flag sin preguntas, texto de barra, cambio a media corrida,
  teclas acepta/niega; `unknown` donde no se midió) · fixtures válidos e inválidos.
  Rojo: vigía fuera del conjunto, sesión sin rol, etiqueta desconocida, **mensaje con jerga**
  (acento grave, ruta con `/`, `--flag`, SHA hex, o lista negra: commit, merge, PR, worktree,
  branch, CI, hook, script); falta de fila para un CLI de `AGENT_TMUX_TOOLS`.
- **9.2 `corrida.sh` abrir/lanzar-sesion/cerrar + mensajes.** `abrir` escribe el registro y crea el
  cron hombre-muerto `corrida-vigia-<id>`; el destino se lee de un cron existente (`--canal-de`,
  default `verif-sync-repos`) y **jamás** va en archivos del repo ni en entorno. Todo subcomando lee
  del registro (tabla de modos, canal, simulacro). Con `--simulacro`, `corrida_mensaje` antepone
  `[SIMULACRO] `. `lanzar-sesion` crea con PATH embebido + flag de la tabla del registro, **marca
  ANTES del primer send-keys**, comprueba `has-session` y barra, entrega encargo con `Enter`
  verificado (reintento si la caja no se vació), anota en el registro. `cerrar` desmarca sesiones,
  quita el cron, manda `CERRADA`. `corrida_mensaje` valida contra el contrato y anota en
  `mensajes.jsonl`. Verde con tmux propio y CLIs de mentira según fila del plan; mutaciones que
  deben morir: marcar después, no comprobar barra, no reintentar `Enter`, mandar sin validar.
- **9.3 Preflight.** `corrida.sh preflight <id>`: gh autenticado con lectura real, binarios bajo
  PATH mínimo, flags que entran, vigilante corriendo con blob = `origin/<default>`, gateway,
  `message send --dry-run`, clases de comando (`ssh`, red externa, `psql`, `gh`) contra candados.
  Salida `APTO` o `NO APTO <razones>`; `NO APTO` no lanza y manda mensaje. Rojo/verde según fila;
  un runbook con `ssh` en bloque de comando sin declararlo en su tabla → rojo.

Forma fijada por el runbook: (1) `scripts/mac/corrida.sh` solo despacha y carga
`corrida/<subcomando>.sh` **relativo a sí mismo**; la biblioteca es `corrida/lib.sh` (ahí vive
`corrida_mensaje`) · (2) `scripts/tests/fixtures/tui-falso.sh` repinta `pantalla.txt` cada 0.2 s y
termina con línea `TUI-FALSO` · (3) `scripts/tests/fixtures/corrida/cli-modos-simulacro.tsv` trae
fila `tui-falso` (binario: ruta absoluta en `wt-f9-lead`; comprobación: `TUI-FALSO`) + fila `glm` ·
(4) `scripts/tests/fixtures/corrida/runbook-simulacro.md` mínimo con tabla de clases.

Cláusulas a–k del runbook: ver `3-worktrees-y-lanzamiento.md` (no limpiar, stub `OPENCLAW_BIN`,
bash 3.2, `TODO VERDE`, paths relativos, rojo en `.saikit/scratch/N/tdd.md`, `fix(9.x)` sin amend,
no instalar, tokens 700 no se leen, sin push/PR, tabla de archivos N). Rama base: `origin/main`
al abrir el worktree. Un commit por tarea. Rojo inicial pegado en `.saikit/scratch/N/tdd.md`.
Al terminar, última línea de tu reporte: `LISTO <sha>` (o `ATORADO <razón>`). TIMEBOX 6 h.

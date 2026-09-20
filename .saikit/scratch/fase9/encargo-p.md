# Encargo carril P · Política de diálogos — `fase9/politica` (`/Users/dn/dev/wt-f9-P`)

(sent-origin: lead Fase 9. Se abre **cuando N ya está mergeado**, en paralelo con M. Entrega como
`BRIEF.md` en el worktree; esta es la copia versionada. No hagas push ni abras PR.)

Tarea **9.6**. **DoD: la de la fila de `Plans.md`, entera.**

- **`corrida.sh responder <sesión>`** (invocado por el vigilante al detectar el diálogo): identifica
  con `cli-modos.tsv`, decide con la tabla del registro. Confianza de carpeta de un worktree de la
  corrida → acepta. Límite de uso → conserva el modelo y marca `cuota`. Fila `Aprobado` → acepta;
  `Negado` → niega. **Lista dura que ninguna tabla aprueba** y todo lo no casado → no contesta y
  escala `NECESITO TU RESPUESTA` con comando textual + dos opciones. Relee la pantalla y exige igual
  checksum antes de mandar la tecla. 3 diálogos en 10 min en CLI con cambio de modo → cambia de modo.
  Cada decisión a `decisiones.jsonl`.
- Verde por CLI con diálogo medido (fixture → decisión + tecla); pantalla que cambia entre lectura y
  envío → no manda nada; patrón ancho (`.*` sin ancla) → rechazado al cargar; `rm -rf` con fila
  `Aprobado` → igual escala; sesión fuera de registro abierto → jamás se toca. Mutaciones: sin
  relectura, sin lista dura.

Forma del runbook: (1) `responder` **nace apagado** (solo actúa con
`~/.local/state/corridas/<id>/responder.on`; sin él registra en `decisiones.jsonl` lo que
**habría** hecho, sin teclas) · (2) el enganche en `scripts/mac/tmux-activity-watch.sh` es de este
carril; con apagado/ausente el vigilante se comporta como hoy (la batería actual del vigilante sigue
verde sin tocar sus casos) · (3) el vigilante anexa cada evento a
`~/.local/state/tmux-activity-watch/eventos.jsonl` · (4) fixtures
`scripts/tests/fixtures/dialogos/confianza.txt` y `permiso-push.txt` (permiso `git push origin main`;
el simulacro los usa por ese nombre).

Cláusulas a–k: ver `3-worktrees-y-lanzamiento.md`. Archivos P: `scripts/mac/corrida/responder.sh`,
`scripts/mac/tmux-activity-watch.sh`, `test-corrida-responder.sh`, `test-tmux-activity-watch.sh`
(**solo agregar** casos), `fixtures/dialogos/`. Solo usas `lib.sh` y `cli-modos.tsv`. Rojo en
`.saikit/scratch/P/tdd.md`. `fix(9.x)` sin amend. Al terminar: `LISTO <sha>` (o `ATORADO <razón>`).
TIMEBOX 6 h.

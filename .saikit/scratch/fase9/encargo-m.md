# Encargo carril M · Mensajes — `fase9/mensajes` (`/Users/dn/dev/wt-f9-M`)

(sent-origin: lead Fase 9. Se abre **cuando N ya está mergeado**. Entrega como `BRIEF.md` en el
worktree; esta es la copia versionada. No hagas push ni abras PR.)

Tareas **9.4, 9.5 y 9.8**, un commit por tarea. **DoD: la de cada fila de `Plans.md`, entera.**

- **9.4 `corrida.sh estado`.** Lee: registro, espejo `runbook-progress.v1`
  (`~/.local/state/corridas/<id>/progress.json`, que el lead escribe además del RPC), última línea
  de contrato por sesión (`LISTO <sha>` / `ATORADO …`), diálogos esperando y desde cuándo,
  **carril callado ≥30 min** (los dos del estado del vigilante), TIMEBOX restante con pausas, PRs por
  `gh`. Emite texto `seguimiento.v1`. Fixtures → texto byte a byte: todo avanza, detenido en
  diálogo, **callado 30 min**, `LISTO` sin recoger, lead muerto, corrida cerrada. Sin `gh`: "GitHub:
  sin verificar". Panel con secuencias de control o 5000 caracteres → truncado y limpio.
- **9.5 Latido.** LaunchAgent `ai.goncloud.corrida-latido` cada 5 min; sin corridas abiertas no hace
  nada. Por corrida: (1) **mensaje a David** ante cambio de estado (callado/detenido **es** cambio;
  ninguna espera >30 min sin mensaje), 60 min sin mensaje aunque todo avance, inmediato
  `NECESITO TU RESPUESTA` si un diálogo lleva 10 min o la política no lo cubre; (2) **despierta al
  vigía** (parte + acción loop §12: `system event` claw, `eventos.jsonl` Hermes según 9.0). Tope: 1
  mensaje/15 min salvo `NECESITO`. Rutina `--silent`, `NECESITO` con notificación. Todo por
  `corrida_mensaje` (validado). Hombre muerto: cron `corrida-vigia-<id>`. Verde con openclaw de
  mentira y reloj inyectado según fila; mutaciones: sin latido por hora, sin escalamiento, sin tope.
- **9.8 Rama por defecto en rojo.** El latido consulta por tick la última corrida CI de la rama por
  defecto (`gh run list --branch <default> --limit 1`); si falló y ese SHA no se avisó → `DETENIDA`
  en lenguaje de usuario + registro local con sha/autor/archivos (el validador 9.1 no excepciona:
  sin sha ni rutas en el mensaje). Mismo sha al tick siguiente → 0; verde → 0; gh caído → 0 y el
  latido sigue. Mutación: sin memoria del sha → rojo. **No toques `scripts/sync-repos.ps1`.**

Forma del runbook: el latido escribe cada evento en `~/.local/state/corridas/<id>/eventos.jsonl`;
reloj y binario openclaw inyectables por entorno; el latido **ignora** directorios de
`~/.local/state/corridas/` sin registro `corrida.v1` válido.

Cláusulas a–k: ver `3-worktrees-y-lanzamiento.md`. Archivos M: `scripts/mac/corrida/{estado,latido}.sh`,
`scripts/mac/ai.goncloud.corrida-latido.plist`, `test-corrida-estado.sh`, `test-corrida-latido.sh`,
`fixtures/estado/`. Solo **usas** `lib.sh` y `cli-modos.tsv`. Rojo en `.saikit/scratch/M/tdd.md`.
`fix(9.x)` sin amend. Al terminar: `LISTO <sha>` (o `ATORADO <razón>`). TIMEBOX 6 h.

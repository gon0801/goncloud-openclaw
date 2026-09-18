# Encargo carril D · Docs — `fase9/docs` (`/Users/dn/dev/wt-f9-D`)

(sent-origin: lead Fase 9. Se abre **cuando M y P cerraron** (mergeados o `atorado`). Entrega como
`BRIEF.md` en el worktree; esta es la copia versionada. No hagas push ni abras PR.)

Tarea **9.7**. **DoD: la de la fila de `Plans.md`, entera.**

- Loop §§1,3,8,9,12 referencian `corrida.sh` y `seguimiento.v1`; TIMEBOX con pausas pasa del
  runbook de Fase 7 al loop. Skill `autopilot-runbook`: slots obligatorios "Seguimiento" (quién
  manda, canal, cadencia) y "Clases de comando" (tabla que lee el preflight). Plantilla del encargo
  del lead (regla de no limpiar + espejo de progreso). `docs/runbooks/guia-del-vigia.md`: qué hace
  el vigía ante cada evento, Markdown plano (Hermes la lee por SSH). Skills `agent-dispatch` y
  `mac-tmux-control` llaman a `corrida.sh` y marcan antes de mandar.
- Candados **para runbooks creados después de esta fase** (fases 6–9 exentas por nombre): runbook
  `autopilot-*.md` sin "Seguimiento" o sin tabla de clases → rojo; `new-session` a mano → rojo.
  Fixtures bueno/malo ambos lados. La guía trae una fila por evento de vigilante y latido
  (prueba cruzada contra el código).

Regla crítica: el candado de paridad compara la skill del repo con
`~/.claude/skills/autopilot-runbook/SKILL.md` y corre en pre-commit — **cada vez que edites la del
repo, copia el archivo entero a esa ruta antes de commitear**, o tu commit sale rojo. No toques
ningún runbook de fase (los nuevos candados exentan 6/7/8/9 por nombre).

Cláusulas a–k: ver `3-worktrees-y-lanzamiento.md`. Archivos D: `docs/runbooks/loop-autopilot.md`,
`docs/runbooks/guia-del-vigia.md`, `docs/agent-skills/autopilot-runbook/SKILL.md` + copia en
`~/.claude/…`, `agents/main/agent/workshop-skills/{agent-dispatch,mac-tmux-control}/SKILL.md`,
`test-loop-autopilot.sh`, `test-runbooks-no-contradicen-entorno.sh`,
`test-skill-autopilot-runbook.sh`, `test-guia-del-vigia.sh`, parte (4) de anclas de
`test-tmux-activity-watch.sh`, y solo si un ancla suya cambió:
`test-{mac-tmux-control,agent-dispatch-no-merge,agent-dispatch-spawn,mac-path-regla,camino-feliz,saikit-cierre-pr-merge-owner}.sh`.
No tocas código bajo `scripts/mac/` ni ningún `autopilot-*.md`. Rojo en
`.saikit/scratch/D/tdd.md`. `fix(9.x)` sin amend. Al terminar: `LISTO <sha>` (o `ATORADO <razón>`).
TIMEBOX 6 h.

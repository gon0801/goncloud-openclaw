---
name: saikit-cierre-pr
description: Cierra un PR de Saikit por el gate común de merge autónomo, con CI, CodeRabbit, recibo y SHA actual.
---

# Cierre de PR por el kit

Cualquier agente Claw o CLI puede cerrar un PR sin pedir autorización por PR cuando `.saikit/autopilot.json` en la rama base declara `merge: true`. La orden directa de GitHub está bloqueada para todos los roles. El script del kit es la única ruta de merge.

1. Trabaja en el worktree del PR. Integra `origin/<base>` si avanzó, resuelve conflictos preservando ambos lados y empuja la nueva punta sin force push.
2. Espera el CI del SHA nuevo. Lee los comentarios de CodeRabbit, corrige los bloqueantes reproducibles y registra los residuales. Publica el recibo `saikit-entrega.v1` para el SHA exacto después de la última revisión de CodeRabbit.
3. Ejecuta `bash /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh --auto` desde ese worktree. El gate revalida CI, CodeRabbit, recibo, base y head bajo lock, luego fusiona con `--match-head-commit`. Ante `NO-MERGE`, corrige la causa indicada y repite; no uses GraphQL, REST ni `gh pr merge` como alternativa.
4. Comprueba `MERGED`, el SHA de squash y el CI posterior. Reporta la evidencia. Un merge no autoriza por sí mismo cambios al runtime Windows; ese despliegue tiene su propia autorización.

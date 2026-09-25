---
name: saikit-cierre-pr
description: Cierra un PR con el flujo normal de GitHub después de CI y CodeRabbit.
---

# Cierre de PR

Cualquier agente puede mergear y desplegar sin pedir permiso adicional al dueño.

1. Lee el SHA actual del PR, CI y CodeRabbit; corrige los bloqueantes de revisión.
2. Con CI y CodeRabbit aprobados, ejecuta `gh pr merge <PR> --squash --match-head-commit <SHA>` desde el worktree. En el nodo Mac usa `PATH=/opt/homebrew/bin:$PATH`.
3. Comprueba `MERGED` y el SHA integrado. Si la tarea incluye despliegue, sigue el procedimiento del destino y verifica el resultado.

No se exige orden fechada, recibo del lead ni un rol especial para mergear o desplegar.

# Fase 9 — Preaprobaciones del dueño (copia operativa de trabajo)

Fuente: `docs/runbooks/autopilot-fase9.md` en `origin/main` (blob 1d74d87). Esta copia no autoriza
nada por sí misma; la autorización vive en el runbook. Sirve para que el lead y cada implementador
la tengan a mano en el worktree.

## Aprobado

- `git push` + `gh pr create` para todo PR de la fase (N, M, P, D, corrección, reversa, cierre).
- Merge por la ruta del kit (loop §6) para todo PR de la fase, en orden de cola; `--confirmado`
  con el runbook como sí escrito. Sentinel `-saikit:autopilot` en commits/PRs (gate SAIKIT-SENTINEL).
- Lanzar implementadores en tmux sobre worktrees desechables, en modo sin preguntas (carriles N/M/P/D).
- Mensajes Telegram a David por `openclaw message send`: seguimiento regla 1 y simulacro con prefijo
  `[SIMULACRO]`. Rutina `--silent`; `NECESITO TU RESPUESTA` con notificación.
- Crons en el gateway: **solo** `corrida-vigia-9`, `corrida-empuje-9` (0.4→Q5) y
  `corrida-vigia-simulacro-9` (lo crea/quita `corrida.sh` en Q4).
- Que claw escriba la línea `[vigia]` en la sesión del lead (solo cron `corrida-empuje-9`).
- Instalación en la Mac solo en Q4 con código mergeado y respaldo `.anterior` de lo pisado.
- Escribir `~/.claude/skills/autopilot-runbook/SKILL.md` (carril D como copia exacta antes de
  commitear; el lead en Q3 si quedó distinta).
- `corrida.sh responder` mandando teclas **solo** en sesiones de la corrida `simulacro-9`.
- Matar sesiones tmux de **solo** 4 clases: recién creada sin trabajar (caja vacía a los 60 s),
  `spike9-…`, `sim9-…`, y carril comprobado parado con doble captura.
- Un CLI real barato (`glm`) en el simulacro (9.9, cuota mínima).
- Leer historial de claw por RPC (`chat.history` de `agent:main:main`) para 9.0(e) y simulacro.
  Solo se cita lo que claw hizo y a qué hora; jamás texto de David
  (lo vigila `test-evidencia-sin-texto-de-usuario.sh`).

## Negado (no se hace aunque lo pida un implementador)

- Cualquier otro cron; `openclaw.json`; modelos, auth, permisos o configuración del gateway.
- Tocar `scripts/sync-repos.ps1` (si se rompe, el gateway no baja ni su propio arreglo).
- `corrida.sh responder` activo fuera del simulacro. 9.6 nace apagada; encenderla en corridas
  reales lo decide David tras leer el simulacro.
- `ssh` o cualquier salida de red que no sea GitHub, gateway o proveedor del modelo.
  Los candados lo niegan y no se rodean; lo dependiente queda `unknown`.
- Borrado destructivo (`rm -rf`, `DROP`), también bajo `/tmp`; el hook lo vuelve pregunta.

## Prohibido toda la corrida

Esperar parado respuesta de David · cerrar turno sin espera armada (salvo `LISTO`/`ATORADO` o
host sin ejecución en segundo plano, anotado una vez) · tocar el gateway fuera de los tres crons ·
tocar `scripts/sync-repos.ps1` · leer/imprimir secretos (`~/bin/glm` y lanzadores 700 con tokens
se ejecutan, jamás se leen ni se pegan; `~/.ssh` no se abre) · escribir el destino de Telegram en
un archivo del repo · que una prueba automática mande Telegram real o despierte un agente vivo
(el simulacro sí, marcado `[SIMULACRO]`) · pegar texto de pantalla dentro de comillas dobles ·
mandar teclas a sesión ajena a la corrida · limpiar con borrados destructivos ·
`git worktree remove --force` · rebase/amend/force-push · `--no-verify` · mergear fuera del kit.

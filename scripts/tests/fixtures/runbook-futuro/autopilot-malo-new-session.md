# Autopilot de la Fase 99 — sesión a mano (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead en cada cambio de estado. Canal: Telegram, destino leído
del cron. Cadencia: en cada cambio de estado. Todo mensaje cumple
`seguimiento.v1`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| `gh` | leer PRs y CI | permitido |

## Lanzamiento

Abre la sesión a mano (semilla de la mutación: new-session escrito a mano):

```
/opt/homebrew/bin/tmux new-session -d -s fase99-lead -c /tmp/x /bin/sh
```

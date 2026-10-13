# Autopilot de la Fase 99 — sesión a mano (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

El lead manda a David en cada cambio de estado y, mientras la corrida siga
activa, al menos cada 30 minutos. Canal: Telegram; el destino se lee del cron.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |

## Lanzamiento

Esta sesión se abre a mano (semilla de la mutación: new-session escrito a
mano):

```
/opt/homebrew/bin/tmux new-session -d -s fase99-lead -c /tmp/x /bin/sh
```

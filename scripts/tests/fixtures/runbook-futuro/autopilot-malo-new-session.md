# Autopilot de la Fase 99 — sesión a mano (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead en cada cambio de estado. Canal: Telegram, destino leído
del cron. Cadencia: en cada cambio de estado y un parte cada 60 minutos. Todo
mensaje cumple `seguimiento.v1`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |

## Lanzamiento

Las sesiones se abren con `corrida.sh lanzar-sesion`. Pero esta abre una a
mano (semilla de la mutación: new-session escrito a mano):

```
/opt/homebrew/bin/tmux new-session -d -s fase99-lead -c /tmp/x /bin/sh
```

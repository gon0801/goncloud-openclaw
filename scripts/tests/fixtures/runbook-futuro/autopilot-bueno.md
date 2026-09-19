# Autopilot de la Fase 99 — runbook futuro mínimo (fixture bueno)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead manda un mensaje en cada cambio de estado; el parte de la
hora lo manda el vigía (claw). Canal: Telegram, con el destino leído del cron
que ya entrega ahí, nunca pegado en este archivo. Cadencia: en cada cambio de
estado y un parte por hora; un AVANZA a menos de 15 minutos del anterior se
junta con el siguiente cambio. Todo mensaje cumple `seguimiento.v1` y sale
validado por `corrida.sh`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| `gh` | `gh pr checks` | permitido |
| red externa | bajar un tarball | negado |

## Lanzamiento

Las sesiones se lanzan con `corrida.sh lanzar-sesion`, que marca antes de
mandar. Ningún comando de este runbook abre sesiones a mano.

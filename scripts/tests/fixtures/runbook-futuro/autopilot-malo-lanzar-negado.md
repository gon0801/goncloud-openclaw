# Autopilot de la Fase 99 — lanzamiento negado (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead en cada cambio de estado. Canal: Telegram, destino leído
del cron. Cadencia: en cada cambio de estado y un parte cada 60 minutos. Todo
mensaje cumple `seguimiento.v1`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| gh | leer PRs y CI | permitido |

## Lanzamiento

Nunca llames corrida.sh lanzar-sesion; usa el lanzador alternativo.

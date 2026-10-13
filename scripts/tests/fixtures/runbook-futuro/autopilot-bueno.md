# Autopilot de la Fase 99 — runbook futuro mínimo (fixture bueno)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead manda a David un mensaje en cada cambio de estado; el parte de la
hora lo manda el vigía (claw). Canal: Telegram, con el destino leído del cron
que ya entrega ahí, nunca pegado en este archivo. Cadencia: en cada cambio de
estado y, mientras la corrida esté activa, al menos cada 30 minutos; un AVANZA a menos de 15 minutos del anterior se
junta con el siguiente cambio. Todo mensaje cumple `seguimiento.v1`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| gh | leer PRs y CI | permitido |
| `ssh` | `ssh despliegue` | negado |
| red externa | bajar un tarball | negado |

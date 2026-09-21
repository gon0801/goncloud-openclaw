# Autopilot de la Fase 99 — clase usada sin declarar (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

El lead manda a David en cada cambio de estado y, mientras la corrida siga
activa, al menos cada 30 minutos. Canal: Telegram; el destino se lee del cron.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| gh | leer PRs y CI | permitido |

## Operación

```bash
ssh servidor-interno uptime
```

## Lanzamiento

Las sesiones se lanzan con `corrida.sh lanzar-sesion`, que marca antes de mandar.

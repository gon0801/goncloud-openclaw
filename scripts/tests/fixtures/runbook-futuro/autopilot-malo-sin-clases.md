# Autopilot de la Fase 99 — sin clases (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

El lead manda a David en cada cambio de estado y, mientras la corrida siga
activa, al menos cada 30 minutos. Canal: Telegram; el destino se lee del cron.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| gh | permiso para gh remoto | permitido |

## Operación

La tabla trae una fila cuya celda de comando es una frase, no un comando: esa
es la semilla de la mutación.

```
gh pr checks 123
```

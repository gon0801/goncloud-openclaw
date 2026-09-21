# Autopilot de la Fase 99 — sin clases (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead en cada cambio de estado. Canal: Telegram, destino leído
del cron. Cadencia: en cada cambio de estado y un parte cada 60 minutos. Todo
mensaje cumple `seguimiento.v1`.

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| gh | permiso para gh remoto | permitido |

## Lanzamiento

Las sesiones se lanzan con `corrida.sh lanzar-sesion`, que marca antes de
mandar. La tabla trae una fila cuya celda de comando es una frase, no un
comando: esa es la semilla de la mutación.

```
gh pr checks 123
```

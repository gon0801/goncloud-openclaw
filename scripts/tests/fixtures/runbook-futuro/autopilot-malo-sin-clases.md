# Autopilot de la Fase 99 — sin clases (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

## Seguimiento

Quién manda: el lead en cada cambio de estado. Canal: Telegram, destino leído
del cron. Cadencia: en cada cambio de estado y un parte cada 60 minutos. Todo
mensaje cumple `seguimiento.v1`.

## Lanzamiento

Las sesiones se lanzan con `corrida.sh lanzar-sesion`, que marca antes de
mandar. Este runbook no trae la tabla que el preflight lee: esa es la semilla
de la mutación (sin sección Clases de comando).

```
gh pr checks 123
```

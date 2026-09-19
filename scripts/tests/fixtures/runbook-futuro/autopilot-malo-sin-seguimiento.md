# Autopilot de la Fase 99 — sin seguimiento (fixture malo)

David no está y no se le pregunta nada. Hereda el loop (`docs/runbooks/loop-autopilot.md`).

Este runbook cuenta cómo va la fase por el tablero y nada más. Nadie sabe
quién manda los mensajes ni por qué canal: esa es la semilla de la mutación
(sin sección Seguimiento).

## Clases de comando

| Clase | Para qué | Candado |
|---|---|---|
| `gh` | leer PRs y CI | permitido |

## Lanzamiento

Las sesiones se lanzan con `corrida.sh lanzar-sesion`, que marca antes de
mandar. Ningún comando de este runbook abre sesiones a mano.

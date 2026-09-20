# Autopilot de la Fase 99 — no abre

Este texto menciona el tablero en prosa. Eso siembra la mutación.

```
bash scripts/lanzar-fase.sh 99 -- x --y
```

Más tarde alguien escribe progreso:

```
openclaw gateway call runbook.progress.set --params '{"corrida":"tarde","proyecto":"x","plan":{},"cola":[{"estado":"pendiente"}]}'
```

# Autopilot de la Fase 99 — demo

Pantalla: `/runbook/tablero/c/demo-corrida`. David no está y no se le pregunta nada.

```
cat > .saikit/progress/99.json <<'JSON'
{"schema":"runbook-progress.v2","corrida":"demo-corrida","proyecto":"demo","plan":{"repo":"x/y","ruta":"Plans.md","seccion":"Fase 99"},"carriles":[{"id":"A","estado":"pendiente"}],"cola":[{"id":"Q1","estado":"pendiente"}]}
JSON
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/99.json)"
```

Después, el carril:

```
bash scripts/lanzar-fase.sh 99 -- muse --yolo
```

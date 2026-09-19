# TDD 9.7 — rojo antes de implementar (2026-09-19)

Tests escritos primero; docs después. Salidas verbatim recortadas.

## test-loop-autopilot.sh → rojo (7)

```
ok (6): la sección 8 exige los dos pasos de publicar una fase, y dónde comprobarlo
FAIL: docs/runbooks/loop-autopilot.md: la sección 1 no referencia corrida.sh
```

## test-skill-autopilot-runbook.sh → rojo (2)

```
ok (1): frontmatter con name y description
FAIL: docs/agent-skills/autopilot-runbook/SKILL.md: falta el slot 14 de la receta
```

## test-guia-del-vigia.sh → rojo (falta la guía)

```
FAIL: falta docs/runbooks/guia-del-vigia.md
```

## test-runbooks-no-contradicen-entorno.sh (2d) → discrimina

El bloque nuevo pasa en verde sobre los 10 exentos + 4 fixtures. Mutación con
un runbook futuro real (`autopilot-fase99.md` temporal, luego borrado):

malo (sin Seguimiento):

```
FAIL: (2d) docs/runbooks/autopilot-fase99.md: un runbook nuevo sin seccion Seguimiento, sin tabla de clases o con new-session a mano
```

bueno:

```
ok (2d): runbooks futuros revisados: autopilot-fase99.md; fixtures bueno/malo discriminan las tres reglas
TODO VERDE: runbooks sin contradicciones con el kit ni con el entorno
```

## test-tmux-activity-watch.sh (4) → rojo pendiente

Las 4 anclas nuevas (`corrida.sh lanzar-sesion`, `BEFORE the first send-keys`
en cada skill) fallan hasta editar las skills; se corre en la batería final
porque tarda (levanta tmux propio).

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

## Ronda 1 — rojo del pase (DA)

Repro del revisor: un runbook con SOLO los encabezados `## Seguimiento` y la
tabla de clases pasaba el candado viejo:

```
DA-SEG-PASA
DA-CLASES-PASA
DA-NO-SESION
```

El candado endurecido exige contenido (quién/canal/cadencia con número+unidad,
fila con clase+comando, llamada a `corrida.sh lanzar-sesion`): 5 mutaciones
del fixture bueno, una por sub-regla, dan las 5 en FAIL (2d); el bueno
intacto y el malo de encabezados-vacíos en ROJO. DB/DC/DD verificados contra
el código (`corrida.v1:35` dice "lo no casado escala"; `corrida.sh latido` ⇒
`subcomando desconocido`, la validación la hacen `preflight`/`cerrar` por
`corrida_mensaje`; `command -v capture-pane` ⇒ rc 1).

## Ronda 2 — rojos del pase (candado r1 vs 4 repros)

Contra el candado r1, con `autopilot-fase99.md` temporal:

```
RA => FAIL: (2d) docs/runbooks/autopilot-fase99.md: ... (falso negativo: la fila minima valida era rechazada)
RB => TODO VERDE (falso positivo: la frase-mencion pasaba)
RC => TODO VERDE (bug: la frase negativa satisfacia el lanzamiento)
RD => TODO VERDE (bug: palabras sueltas declaraban canal y cadencia)
```

Candado r2: RA pasa (fila minima en el bueno, `CLA=1`); RB/RC/RD dan FAIL
(2d). Matriz de aislamiento (Hseg/SEG/CLA/LAN/MANO): bueno 11110 PASA;
sin-seguimiento 00110 ROJO; sin-clases 11010 ROJO; new-session 11111 ROJO;
encabezados-vacios 10100 ROJO; lanzar-negado 11100 ROJO; seguimiento-vago
10110 ROJO. Nota de harness: backticks con comandos reales en la linea de
`bash` se evalúan antes de Bash — los repros se generaron con script Python
a archivo (`/tmp/r2-repro.py`), nunca con sed inline.

---
name: No-op commit drop
description: Cuando te piden dropear un commit no-op de la rama de un PR (el revisor dice que no aporta delta contra main). Verifica el drop contra los candados de commit del repo antes de rebasear, no solo contra main.
---

# No-op commit drop

Un commit puede ser no-op contra `main` y aun así sostener un candado
local en verde: dropearlo a ciegas agranda el rojo y el pre-commit te
bloquea el siguiente commit (medido 2026-09-17, Fase 7 carril P: el
commit 22794ba era idéntico a `origin/main`, pero la copia de la Mac
sí traía esas líneas y el candado anti-deriva compara repo contra Mac,
no contra main).

## Pasos

1. Confirma el no-op: mismo sha del archivo en el commit y en
   `origin/main`, y el commit no es ancestro
   (`git merge-base --is-ancestor` con exit 1).
2. Confirma disyunción: ningún commit posterior toca el mismo archivo
   (`git diff --name-only <noop>..HEAD` no lo lista).
3. ANTES de rebasear, revisá los candados de commit: si
   `.pre-commit-config.yaml` tiene hooks `always_run`, o hay checks de
   deriva que comparan el archivo contra una copia externa (no contra
   main), compará el contenido del archivo CON y SIN el commit contra
   lo que el candado exige.
4. Si dropear agranda un fallo vivo del candado (o introduce uno): NO
   rebasees; dejá el commit y reportá con la evidencia (shas iguales,
   diff del candado). Dropear primero y descubrir el bloqueo después
   cuesta el rebase más la restauración.
5. Dropeá sin editor interactivo: `git rebase --onto <sha>^ <sha> <rama>`
   (verificado 2026-09-17, Fase 7: 6/6 replays limpios, sin conflictos).
   Evita `GIT_SEQUENCE_EDITOR` con `sed -i`: el sed de la Mac es BSD y
   la forma GNU rompe el sequencer (detalle en mac-exec-detach-poll).
6. Si stasheaste trabajo antes del rebase y el stash toca el mismo
   archivo que el commit dropeado, no confíes en el pop: puede
   auto-mergear en silencio contra la base nueva y dejar el archivo sin
   las líneas que el commit aportaba (medido 2026-09-17: el pop "exitoso"
   dejó el SKILL.md sin sus dos filas). Restaurá el estado final querido
   de ese archivo desde su copia autoritativa y verificalo con diff antes
   de commitear.
7. Nunca uses `--no-verify` para pasar por encima del candado y
   aterrizar el drop: un rojo real fuera de tu carril se reporta al
   lead, no se esquiva.

## Criterio de cierre

Commit dropeado con batería local verde, o commit conservado con el
reporte de por qué el drop rompería el candado.

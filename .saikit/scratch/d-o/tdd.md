# D-O — hardening 9.17/9.18 y residuales de #126 (TDD)

Rama `entrega-sin-sello-d-openclaw` desde `origin/main` (31dfaf0, merge de #126).
Trabajo del 2026-09-22. Implementador: glm.

## 9.17 — recuperación explícita de lock con PID vivo

Defecto: `lock_abandonado_romper` se rinde si `kill -0` del PID responde
(`scripts/mac/corrida/lib.sh`, línea 134). Un dueño vivo colgado o un PID
reciclado no tienen salida operativa: solo borrar el directorio a mano.

Arreglo: `lock_recuperar_explicito <dir> <umbral> <etiqueta>` en lib.sh.
Nunca la llama el camino automático. Clasifica y audita por stderr:

- dueño vivo que refresca (token fresco): se niega, también a propósito;
- dueño vivo colgado (pid vivo, token viejo, proceso más viejo que el token): rompe;
- PID reciclado (token más viejo que el proceso actual, comparación
  `ps -o etime=` contra la edad del token): rompe y lo dice.

Reclamo por rename con re-verificación dentro de la tumba (token intacto y
edad re-medida): si el dueño refrescó entre la verificación y el `mv`, se
restaura y no se roba nada.

Invocación operativa (no hay subcomando: el alcance de la fila es lib.sh y su
prueba):

```
bash -c '. scripts/mac/corrida/lib.sh; lock_recuperar_explicito "$CORRIDA_STATE/<id>/.lock" "$CORR_LOCK_VIEJO" lock-recuperar'
```

Prueba: `scripts/tests/test-corrida-nucleo.sh` bloque (9f6), tres casos.

## 9.18 — endurecer `--solo-watchdog-global`

Defecto: con el flag, el python de `arranque-de-fase.sh` saltaba por completo
el chequeo de `corrida-empuje-<fase>`: un empuje sobrante salía VERDE.

Arreglo: con el flag, empuje presente ⇒ marca `SOBRANTE-corrida-empuje-<fase>`
⇒ ROJO nombrándolo. Las marcas de `avance-tareas` (ausente/apagado/ritmo) ya
existían en los dos modos; lo que faltaba era la prueba focalizada bajo el
flag: (2g) la añade para las tres.

Prueba: `scripts/tests/test-arranque-de-fase.sh` casos (2f) y (2g).

## Residuales del recibo de #126

1. `repo: null` en carril candidato: caso (11) en
   `test-reconciliar-progreso.sh`. El isinstance de `reconciliar-progreso.sh`
   ya convertía null a cadena vacía (por eso el caso nace verde); lo que
   faltaba es el ancla. Mutación medida: quitar el bloque de conversión ⇒ el
   python muere con NameError ⇒ rc 2 ⇒ caso rojo (y rojo también el caso (2)
   porque cualquier candidato pasa por ahí). Caso (11) afirma además rc 3,
   unknown nombrado y el control con repo válido conciliado.
2. `docs/runbooks/base-openclaw.md` vuelve a decir que las fases 6 y 7, ya
   cerradas, escriben `-Alcance last-commit`, que ese valor está en el
   conjunto, que el script aborta con un valor fuera del conjunto
   (`ValidateSet` de cross-review.ps1, verificado) y que combinado con
   `-Desde`/`-Base` aborta igual. Versión 1.1 → 1.2.
3. La regla 4 ya justificaba el veto de rebase con la historia que la ronda 1
   lee con `-Base`; ahora está anclada.
4. `test-loop-autopilot.sh` (3-r1b): el comando de ronda 1 de base-openclaw.md
   usa `-Base` y ni `-Desde` ni `-Alcance`. Anclas en (3-r1b) y (3d).

## Evidencia (este directorio)

- `rojo-test-arranque-de-fase.log` — (2f) en rojo sin producción: el empuje
  sobrante salía 0 (el defecto 9.18).
- `rojo-test-corrida-nucleo.log` — falta `lock_recuperar_explicito`.
- `verde-test-*.log` — las cuatro pruebas focales en rc 0 con producción.
- `mutacion-sin-sobrante.log` — quitar la marca SOBRANTE ⇒ (2f) rojo.
- `mutacion-sin-falta-flag.log` — quitar la marca FALTA ⇒ (2) rojo.
- `mutacion-roba-fresco.log` — quitar la guarda de token fresco ⇒ (9f6a) rojo
  (la explicita roba el lock del vivo que refresca).
- `mutacion-clasificacion-invertida.log` — invertir la comparación de edades ⇒
  (9f6c) rojo.
- `mutacion-sin-isinstance.log` — quitar la conversión de repo null ⇒ rc 2.
- `mutacion-sin-nota-fases67.log` — quitar la nota de fases 6/7 ⇒ ancla roja.
- `mutacion-sin-justificacion-rebase.log` — quitar «(`-Base`, loop §4)» de la
  regla 4 ⇒ ancla roja (primera versión del ancla, más corta, sobrevivía a la
  mutación: endurecida y re-medida).
- `mutacion-r1-con-alcance.log` — comando de ronda 1 con `-Alcance
  last-commit` ⇒ (3-r1b) rojo.

## Límite del poder discriminante, declarado

- Quitar SOLO la línea `if not isinstance(repo, str):` (dejar la asignación
  `repo = ''`) no cambia salida observable: el regex del shell rechaza `None`
  igual que `''`. La mutación natural es quitar el bloque completo, y esa sí
  muere (NameError, rc 2, medido).
- Las pruebas focales corren sueltas con `bash scripts/tests/test-*.sh`; la
  batería completa corre una vez en CI sobre este SHA.

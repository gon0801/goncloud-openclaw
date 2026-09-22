## D-O — hardening de Fase 9 (9.17, 9.18) y residuales del recibo de #126

Bloque D del plan entrega-sin-sello. Implementado por: **glm**. PR en borrador: la revisión la hace otro modelo con `-Excluir glm`; no lleva sello de lead y no declara cerrada la Fase 9.

### 9.17 — recuperación explícita de lock con PID vivo

`lock_abandonado_romper` se rinde si `kill -0` del PID responde: un dueño vivo colgado o un PID reciclado no tenían salida operativa salvo borrar el directorio a mano. Nuevo `lock_recuperar_explicito` en `scripts/mac/corrida/lib.sh`, llamada a propósito (el camino automático no cambia), verificada y auditable por stderr. Los tres casos de la DoD:

- **dueño vivo que refresca** (token fresco): se niega, incluso llamada a propósito;
- **dueño vivo colgado** (pid vivo, token viejo, proceso más viejo que el token): rompe y dice `dueno vivo colgado` con el pid;
- **PID reciclado** (token más viejo que el proceso actual; compara `ps -o etime=` con la edad del token): rompe y dice `pid reciclado`.

El reclamo es por rename con re-verificación dentro de la tumba (token intacto y edad re-medida): si el dueño refrescó entre la verificación y el `mv`, se restaura el lock y no se roba nada. Sin token o con token ilegible no toca nada. No hay subcomando nuevo: el alcance de la fila es lib.sh y su prueba; la invocación operativa queda documentada en `.saikit/scratch/d-o/tdd.md`.

Prueba: bloque (9f6) de `test-corrida-nucleo.sh`, tres casos.

### 9.18 — endurecer `--solo-watchdog-global`

Con el flag, `arranque-de-fase.sh` saltaba por completo el chequeo de `corrida-empuje-<fase>`: un empuje sobrante salía VERDE. Ahora, con el flag, empuje presente ⇒ `SOBRANTE-corrida-empuje-<fase>` ⇒ ROJO nombrándolo. `avance-tareas` ausente, apagado o fuera de la cadencia de 15 min ya se marcaba en los dos modos; el caso focalizado bajo el flag para las tres marcas es nuevo (2g). Sin el flag el contrato no cambia (los casos (1)–(10) existentes corren iguales).

Prueba: casos (2f) y (2g) de `test-arranque-de-fase.sh`.

### Residuales del recibo de #126

1. **`repo: null` en un carril candidato no llama a gh** — caso (11) de `test-reconciliar-progreso.sh`, con carril control. Afirma rc 3, el unknown nombrando al carril y su pr, el carril intacto y un solo evento (si gh llegara a llamarse con un repo vacío o raro, contestaría OPEN y no habría unknown: rc 0 ⇒ rojo).
2. **base-openclaw.md vuelve a decir que las fases 6 y 7 escriben `-Alcance last-commit`** y que el script aborta si el valor no está en el conjunto (`ValidateSet('staged','working','last-commit')` de cross-review.ps1, verificado en el kit) y combinado con `-Desde`/`-Base` aborta igual. Los runbooks cerrados no se reescriben. Versión 1.1 → 1.2.
3. **La regla 4 vuelve a justificar el veto de rebase**: un rebase reescribe la historia que la ronda 1 lee con `-Base`. El texto ya estaba; ahora lo ancla la prueba.
4. **`test-loop-autopilot.sh` ancla la ronda 1 de base-openclaw.md**: usa `-Base` y ni `-Desde` ni `-Alcance last-commit` (3-r1b), más las anclas del texto de (2) y (3) en (3d).

### Rojo primero y mutaciones (evidencia en `.saikit/scratch/d-o/`)

- Rojo medido antes del verde: `(2f) con el flag, un empuje propio sobrante debe salir ROJO; salio 0` (el defecto 9.18) y `falta lock_recuperar_explicito` (9.17). Logs `rojo-test-*.log`.
- Mutaciones atrapadas: quitar la marca SOBRANTE ⇒ (2f) rojo; quitar la marca FALTA ⇒ (2) rojo; quitar la guarda de token fresco de la recuperación ⇒ (9f6a) rojo (roba el lock del vivo); invertir la comparación de edades ⇒ (9f6c) rojo; quitar el bloque de conversión de repo null ⇒ rc 2; quitar la nota de fases 6/7, quitar «(`-Base`, loop §4)» de la regla 4 o poner `-Alcance last-commit` en el comando de ronda 1 ⇒ anclas rojas. La primera versión del ancla de la regla 4 era más corta y sobrevivía a la mutación: endurecida y re-medida.

### Verificación local

`bash scripts/tests/test-corrida-nucleo.sh`, `test-arranque-de-fase.sh`, `test-loop-autopilot.sh` y `test-reconciliar-progreso.sh` en rc 0 sobre este SHA. La batería completa corre una sola vez en CI sobre este SHA.

### Lo que no implementé, y por qué

- **Sin subcomando `corrida recuperar-lock`**: el brief acota la fila 9.17 a `scripts/mac/corrida/lib.sh` y su prueba; un subcomando nuevo tocaría el dispatcher o un archivo nuevo. La función documentada cumple la salida operativa auditable; si el lead quiere envoltorio de CLI, es una fila propia.
- **Quitar solo la línea `if not isinstance(repo, str):`** (dejando `repo = ''`) no es observable en la salida: el regex del shell rechaza `None` igual que `''`. La mutación natural (quitar el bloque completo) sí muere, medido. Declarado como límite del caso (11).
- **Runbooks de fases ya corridas**: intactos, como pide el brief; la nota de historia vive en base-openclaw.md.

### Fuera de este PR

Nada más del inventario D-B/C quedó pendiente en este repo: los cuatro residuales del recibo de #126 están arriba. Lo de otros repos va a sus propios PR (D-kit en quality-kit, D-S en summonaikit-claude).

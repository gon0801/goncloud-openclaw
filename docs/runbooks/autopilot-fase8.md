# Autopilot de la Fase 8 — cimientos del motor de precios (Orbit)

> **NO SE LANZA TODAVÍA.** Dos lectores de contexto fresco ejecutaron este
> runbook en seco contra la máquina real el 2026-09-16 y devolvieron 37
> hallazgos, cuatro de ellos bloqueos que no se arreglan redactando: el tablero
> de progreso que el formato exige **no existe en esta máquina** (el plugin no
> está instalado, el método es desconocido para el gateway, y la forma
> `--params @archivo` que el loop y el spec escriben no la acepta la CLI); el
> plan dice que Repricing no arranca antes de que cierre D.3 de `fabrica-02`;
> el carril D implementa una fila de la fase E, que todavía no pasó su ronda de
> cinco perspectivas; y no se sabe si muse puede trabajar en un worktree, de lo
> que depende que los carriles sean paralelos o secuenciales. El detalle, con
> los comandos y sus salidas, está en `autopilot-fase8-hallazgos.md`, junto con
> los 24 hallazgos que sí se arreglan escribiendo y lo que ya quedó verificado
> como correcto. **Este documento no se ejecuta hasta que esos cuatro bloqueos
> se levanten.**

Esto lo ejecutas tú, el **lead**, en autopilot. **David no está y no se le pregunta nada**: lo que necesitarías consultarle ya está decidido en la tabla de preaprobaciones de más abajo, o es una fila de la tabla de atores. Si algo no está escrito aquí ni en `docs/runbooks/loop-autopilot.md`, se declara como residual en el PR y la corrida sigue.

La fase construye los **cimientos** del motor de precios de Orbit: el esquema, las reglas puras, el camino de escritura con su reversa, y la medición del costo de envío. **No despliega nada, no toca producción con escrituras y no cambia un solo precio en Amazon.** El primer cambio real de precio es de David, en la fila A.4 del plan, y queda fuera de esta fase.

---

## Quién

| Rol | Quién | Qué hace en esta fase |
|---|---|---|
| **claw** | el agente `main` del gateway | Lanza al lead y lo vigila por tmux. Relanza si se cae. No mergea ni despliega. |
| **lead** | un CLI en tmux, de cualquier host que el kit de merge conozca; la lista vive en la sección 1 del loop y claw elige por preferencia y cuota | Escribe los encargos, lanza implementadores, audita, corre la cruzada, aprueba, mergea por la ruta del kit, escribe progreso y cierra la fase. No escribe código de producto. |
| **implementador** | **muse** en los cuatro carriles | Escribe el código en su worktree y reporta con la línea de contrato. No hace push ni abre PR. |
| **revisor cruzado** | otra IA por `cross-review.ps1` | Segunda opinión sobre el SHA del PR. Como implementa muse, que no es candidato a revisor, se pasa `-Excluir ''` y se anota en el PR quién implementó. |
| **David** | el dueño | **Ninguna acción durante la corrida.** Al cierre lee el reporte. Lo que queda listo para él son las filas A.4 y E.2 del plan, que esta fase deja preparadas y no ejecuta. |

---

## Arranque

**Paso 0.0 — precondiciones.** Corre esto antes de nada. Si una falla, aplica su fila en «Cuando algo se atora»; dos de ellas detienen la fase entera.

```
test -r /Users/dn/dev/summonaikit-claude/tools/MANIFEST.sha256 || echo ATORADO kit ausente
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
/opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit show origin/master:.saikit/autopilot.json
/opt/homebrew/bin/pg_isready -h localhost -p 5432
/opt/homebrew/bin/psql "postgresql://orbit:orbit@localhost:5432/postgres" -Atc "select 1"
ls /Users/dn/.openclaw/bin/openclaw
```

Esperado, en orden: sin salida (el `test` pasa); sin salida; la línea `{"merge":true,"merge_despliega":"no","salud_url":null,"revert_si_rojo":true,"rama":"master","sin_verify_app":false,"telegram":false}`; `localhost:5432 - accepting connections`; `1`; la ruta del binario. **Detienen la fase**: el kit ausente y `autopilot.json` ausente de `origin/master`. Las demás tienen fila propia.

**Paso 0.1 — lee el plan.** `plans/repricing-01.md` en `origin/master` de Orbit, v1.1, y su spec `docs/superpowers/specs/2026-09-15-repricing-01-design.md` v1.2. Las filas que esta fase implementa son **A.0, A.2, A.3 y E.1**, y sus DoD van verbatim al encargo de cada carril.

**Qué documento manda.** El plan `plans/repricing-01.md` manda sobre este runbook en todo lo que sea contenido de una fila (qué se construye, qué DoD tiene). Este runbook manda sobre el plan en todo lo que sea proceso de la corrida (quién, ramas, archivos, cola, atores). `docs/runbooks/loop-autopilot.md` manda sobre ambos, salvo la tabla de preaprobaciones de abajo. Si el plan y este runbook se contradicen en una fila, gana el plan y el lead anota la discrepancia como residual en el PR de ese carril; ninguna tarea de esta fase edita el plan.

**Dónde vive cada cosa.**

| Repo | Ruta local | Default | Copia desplegada |
|---|---|---|---|
| `gon0801/goncloud-Orbit` | `/Users/dn/dev/goncloud-Orbit` | `master` | `/mnt/data/appdata/orbit` en el host `goncloud` — **fuera de alcance**: `merge_despliega` es `no` y esta fase no despliega |
| `gon0801/goncloud-openclaw` | `/Users/dn/dev/goncloud-openclaw` | `main` | el gateway, por sync — **no se toca en esta fase**; solo vive aquí este runbook |

El checkout principal de Orbit **está ocupado por otra sesión** (rama `quitar-avisos-telegram` al escribir esto) y hay un worktree ajeno en `/private/tmp/orbit-base`. No se cambia de rama en el checkout principal ni se borran ramas ajenas: cada carril trabaja en su propio worktree, creado en el paso 1 de su carril.

---

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| Crear ramas, worktrees y PRs en `gon0801/goncloud-Orbit` | Las cuatro ramas `fase8/*` de este runbook | **Aprobado** |
| Mergear a `master` de Orbit por la ruta del kit | Los cuatro PRs de esta fase, con su `APPROVE lead <sha>` y CI verde | **Aprobado** |
| Lanzar implementadores y revisores cruzados con costo de tokens | Hasta el presupuesto del inventario | **Aprobado** |
| Crear una migración nueva en `migrations/` | Solo `0039_precio.sql`, sin aplicarla a ninguna base que no sea la local de pruebas | **Aprobado** |
| Leer producción de Orbit por `ssh goncloud` con consultas de **solo lectura** | Solo el carril D (E.1), solo `SELECT`, solo por el rol lector | **Aprobado** |
| Aplicar la migración a la base de producción | — | **Negado**: es la fila D.1 del plan y la corre David |
| Desplegar código a `/mnt/data/appdata/orbit` | — | **Negado**: `merge_despliega` es `no`; el deploy es de David |
| Escribir un precio en Amazon, aunque sea un centavo | — | **Negado**: es la fila A.4 del plan y lleva go literal de David |
| Sembrar goals en `precio_goal` de producción | — | **Negado**: es la fila D.1 |
| Tocar `.saikit/autopilot.json` en cualquier repo | — | **Negado**: el kit lo lee de `origin/master` y rechaza el PR que lo toque |
| Editar `plans/repricing-01.md` o su spec | — | **Negado**: el plan es la fuente; una discrepancia se declara, no se corrige aquí |

---

## Prohibido

> **Prohibido en esta fase, sin excepción:** preguntarle algo a David; aplicar la migración a producción; desplegar; escribir cualquier cosa en Amazon o en Mercado Libre; ejecutar `tools/precio_reversa.py` contra datos reales; escribir en la base de producción (solo `SELECT`); tocar `.saikit/autopilot.json`; editar el plan o su spec; mergear por cualquier vía que no sea la del kit; usar `--no-verify`; cambiar de rama en el checkout principal de Orbit o borrar ramas y worktrees ajenos; abrir un cuarto PR simultáneo; inventar la forma del parche de precio de Amazon (se entrega marcada `pendiente_sonda`).

---

## Reglas de trabajo

1. **Worktree por carril.** Cada carril nace de `origin/master` de Orbit, recién traído:

   ```
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit fetch -q origin
   /opt/homebrew/bin/git -C /Users/dn/dev/goncloud-Orbit worktree add /Users/dn/dev/wt-fase8-<carril> -b fase8/<rama> origin/master
   ```

   Antes de abrir el PR, `/opt/homebrew/bin/git log --oneline origin/master..HEAD` lista **solo** los commits de ese carril.

2. **Las pruebas de base tienen que correr de verdad, no saltarse.** Orbit salta sus pruebas de PostgreSQL cuando no hay base utilizable, así que un carril puede verse verde sin haber probado nada. En la Mac **no hay Docker**; la base es la de Homebrew, ya arriba. Todo comando de pruebas de esta fase lleva el DSN, idéntico al de CI:

   ```
   cd /Users/dn/dev/wt-fase8-<carril> && ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" \
     /Users/dn/dev/goncloud-Orbit/.venv/bin/python -m pytest <archivo> -q
   ```

   El encargo exige que el implementador pegue en el reporte el **conteo de la salida** (`N passed`) y el número de pruebas **saltadas**: si las pruebas de base del carril salen como `skipped`, el carril no terminó. El lead lo verifica corriendo el mismo comando en el paso 3 del loop.

3. **La auditoría del paso 3 del loop se hace con la base arriba.** Mutar una prueba que se está saltando no prueba nada. Antes de mutar, el lead confirma `/opt/homebrew/bin/pg_isready -h localhost -p 5432` en `accepting connections`.

4. **Número de migración.** Solo el carril A crea migración, y es `migrations/0039_precio.sql`: `0038` es la última en `origin/master` al escribir esto. Antes de mergear, el lead relee `/opt/homebrew/bin/git ls-tree --name-only origin/master migrations/ | sort | tail -1`; si ya hay un `0039`, el carril renumera en el mismo PR y vuelve al paso 3 del loop.

5. **Los candados de arquitectura tienen un dueño y un orden.** `tests/test_architecture.py` lo toca **primero el carril B** y después el carril C, que rebasa sobre `master` con B ya mergeado. C no abre su PR tocando ese archivo antes de que B esté en `master`.

6. **Un candado que no puede salir rojo no cuenta.** El candado de pureza de `app/precio/*` solo discrimina si esa carpeta existe con archivos: por eso vive en el carril B, que la crea. Cualquier candado nuevo de esta fase se entrega con su fuga sembrada en `tmp_path` demostrando el rojo; sin esa demostración, vuelve al paso 1 del loop.

7. **La forma del parche de precio de Amazon no se inventa.** El carril C entrega `app/spapi/precio_write.py` con el cuerpo del parche marcado `pendiente_sonda` y sus pruebas contra un cliente falso. Sellarlo es la fila A.4 del plan, de David. Un carril que "resuelva" la forma leyendo documentación y la dé por buena vuelve al paso 1.

8. **El carril D solo lee.** Sus consultas van por el rol lector y por `ssh goncloud`, nunca con el superusuario:

   ```
   ssh goncloud 'DSN=$(docker exec orbit-app-1 printenv ORBIT_DSN_READ); docker exec -i orbit-db-1 psql "$DSN" -X -P pager=off -tA' < <archivo.sql>
   ```

   Si `ssh` no responde, el dato queda `unknown` con el comando que lo resolvería y el carril sigue con lo que sí obtuvo.

9. **Nada en esta fase despliega.** `merge_despliega` es `no` en `autopilot.json` de Orbit: mergear a `master` **no** lleva el código al servidor. Por eso esta fase no tiene ventana segura de despliegue ni canary, y la sección 7 del loop no aplica; se declara aquí y no se cubre por otra vía.

10. **Progreso escrito.** En cada cambio de estado de un carril o de la cola, y al cierre, el lead escribe `.saikit/progress/8.json` en el repo de Orbit con el formato `runbook-progress.v1` (`docs/spec/runbook-progress.v1.md` en goncloud-openclaw) y lo envía:

    ```
    /Users/dn/.openclaw/bin/openclaw gateway call runbook.progress.set --params @/Users/dn/dev/goncloud-Orbit/.saikit/progress/8.json
    ```

    `openclaw` **no está en el PATH**: se escribe esa ruta absoluta. Cada escritura lleva `runbook` = `docs/runbooks/autopilot-fase8.md`, `fase` = `"8"`, `atencion_requerida` (verdadero solo para las filas de atores que dicen que llegan a David) y `siguiente_paso` en lenguaje llano de ≤160 caracteres. Un envío fallido no bloquea: se anota en `eventos` y se reintenta en el siguiente cambio. El archivo se commitea **solo** en el PR del carril D, que es el último de la cola.

11. **Telegram.** `autopilot.json` de Orbit trae `telegram: false`, así que el kit no avisa. El aviso de cierre lo manda el lead por el relay de claw, una sola vez, al terminar la fase.

---

## Loop de entrega

Rige `docs/runbooks/loop-autopilot.md` de goncloud-openclaw, completo y sin repetirlo aquí: el loop por tarea (sección 3), la política de rondas cruzadas (4), PRs y CodeRabbit (5), la ruta del kit para mergear (6), el progreso (8), la reanudación si el lead muere (9), la revisión de cierre de fase (10) y los atores universales (12). **Desviaciones de esta fase, nombradas:** de la sección 7 (despliegue y gateway), **nada aplica**, porque `merge_despliega` es `no` en Orbit y esta fase no despliega ni toca configuración del gateway; por eso tampoco hay ventana segura ni canary, y el ítem de cola no lleva compuerta de sync. De la sección 4, el parámetro `-Excluir` va **vacío** en los cuatro carriles, porque implementa muse y muse no está en la cadena de revisores; quién implementó se anota en el cuerpo del PR.

---

## Carriles

Los cuatro nacen de `origin/master` de Orbit. Van en dos olas para no pasar del tope de tres PRs abiertos de la sección 5 del loop: **ola 1** los carriles A y D, en paralelo; **ola 2** los carriles B y C, en paralelo, una vez que el PR del carril A está mergeado, porque sus pruebas necesitan las tablas de la migración.

### A · Migración del motor — rama `fase8/precio-migracion`

Fila **A.0** del plan, verbatim en el encargo. Crea `migrations/0039_precio.sql` con el enum `precio_mode` y las tablas `precio_goal`, `precio_decision`, `precio_cotizacion`, `precio_envio_muestra` y `precio_cambio`, con sus CHECK, índices parciales, triggers de append-only y transiciones, los GRANT por columna, y `apply_cap_de_config` ampliado con `precio:amazon_mx`, `precio:amazon_us` y `precio:meli`.

**DoD**: la de la fila A.0 del plan, entera. Además: el test de 0002 sobre `apply_cap_de_config` sigue verde, y el bloque `DO` de prueba bajo `SET ROLE` revierte lo que inserta.

### D · Medición del envío — rama `fase8/envio-medicion`

Fila **E.1** del plan. Solo lectura sobre producción. Produce `docs/evidencia/repricing-01/E.1/` con: las consultas y sus salidas literales; por producto y plataforma, `envios, mediana, p75, p90, max` de los últimos 180 días; el conteo de órdenes descartadas por traer más de un producto o por no ligar a una venta, con su razón; y el efecto de p50, p75 y p90 sobre el margen de al menos diez productos FBM.

**DoD**: la de la fila E.1. Además: ninguna consulta escribe, y cada tabla del documento cita el `SELECT` que la produjo.

### B · Reglas puras — rama `fase8/precio-reglas`

Fila **A.2** del plan. Crea `app/precio/{tipos,reglas,objetivo,ventas,config}.py` y la función `cotizar_a_precio` en `app/estimacion_fees.py`, con el banco de pruebas y el catálogo de mutantes.

**DoD**: la de la fila A.2, con todos sus bordes. Además: el candado de pureza de `app/precio/*` en `tests/test_architecture.py`, entregado con su fuga sembrada que lo pone rojo.

### C · Escritura y reversa — rama `fase8/precio-escritura`

Fila **A.3** del plan. Crea `app/spapi/write_client.py`, `app/spapi/precio_write.py` y `tools/precio_reversa.py`, en ese orden de commits: primero el cliente, después la reversa, después la escritura.

**DoD**: la de la fila A.3. Además: los tres candados con fuga sembrada, `SpapiClient` sin verbo de escritura, y el cuerpo del parche marcado `pendiente_sonda`.

### Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| **A** | `migrations/0039_precio.sql`, `tests/test_precio_migracion.py`, `tests/test_schema.py`, `docs/DATABASE.md`, `docs/DEPLOY.md` | `app/**`, `tools/**`, `tests/test_architecture.py`, `plans/**`, `docs/superpowers/**`, `.saikit/**` |
| **D** | `docs/evidencia/repricing-01/E.1/**`, `.saikit/progress/8.json` | todo lo demás del repo |
| **B** | `app/precio/{tipos,reglas,objetivo,ventas,config}.py`, `app/estimacion_fees.py` (solo agrega `cotizar_a_precio`), `tests/test_precio_reglas.py`, `tests/test_architecture.py` | `migrations/**`, `app/spapi/**`, `tools/**`, `app/cycle.py`, `app/apply.py`, `docs/evidencia/**` |
| **C** | `app/spapi/write_client.py`, `app/spapi/precio_write.py`, `tools/precio_reversa.py`, `tests/test_spapi_write_client.py`, `tests/test_precio_write.py`, `tests/test_architecture.py` (después de que B mergee) | `migrations/**`, `app/precio/**`, `app/spapi/client.py`, `app/apply.py`, `docs/evidencia/**` |

Ningún carril toca `plans/**`, `docs/superpowers/specs/**` ni `.saikit/autopilot.json`. El único archivo compartido es `tests/test_architecture.py`, entre B y C, con el orden de la regla 5.

---

## Cola de merge

En este orden. Cada ítem se mergea por la ruta del kit de la sección 6 del loop, desde el worktree de su carril. Ninguno lleva compuerta de despliegue: en Orbit mergear no despliega.

**Q1 · Carril A (`fase8/precio-migracion`).**
Compuerta, desde `/Users/dn/dev/wt-fase8-a`:

```
/opt/homebrew/bin/gh pr checks <pr> | head -3
/opt/homebrew/bin/git ls-tree --name-only origin/master migrations/ | sort | tail -1
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" /Users/dn/dev/goncloud-Orbit/.venv/bin/python -m pytest tests/test_precio_migracion.py tests/test_schema.py -q | tail -2
```

Esperado: `quality` en `pass`; la última migración de `master` **no** es `0039`; y la última línea del pytest dice `N passed` con `N ≥ 1` y **sin** `skipped`. Fallback automático: si la última migración ya es `0039`, el carril renumera a `0040` en el mismo PR y vuelve al paso 3 del loop; si el pytest trae `skipped`, aplica la fila «Las pruebas de base se saltan» de atores y el ítem no mergea.

**Q2 · Carril D (`fase8/envio-medicion`).**
Compuerta:

```
/opt/homebrew/bin/gh pr checks <pr> | head -3
/opt/homebrew/bin/git -C /Users/dn/dev/wt-fase8-d diff --name-only origin/master...HEAD
```

Esperado: `quality` en `pass`; y la lista de archivos contiene **solo** rutas bajo `docs/evidencia/repricing-01/E.1/` y `.saikit/progress/8.json`. Fallback: cualquier otra ruta se saca con un commit propio antes del merge, según la fila de atores universales del archivo fuera de tabla.

**Q3 · Carril B (`fase8/precio-reglas`).**
Compuerta:

```
/opt/homebrew/bin/gh pr checks <pr> | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" /Users/dn/dev/goncloud-Orbit/.venv/bin/python -m pytest tests/test_precio_reglas.py tests/test_architecture.py -q | tail -2
```

Esperado: `quality` en `pass`; `N passed` sin `skipped`. Fallback: `skipped` → fila de atores; rojo en `test_architecture.py` → vuelve al paso 3 del loop.

**Q4 · Carril C (`fase8/precio-escritura`).**
Precondición del ítem: el carril C está rebasado sobre `master` **con Q3 ya mergeado**, porque comparte `tests/test_architecture.py`. Se comprueba así, desde `/Users/dn/dev/wt-fase8-c`:

```
/opt/homebrew/bin/git fetch -q origin && /opt/homebrew/bin/git merge-base --is-ancestor origin/master HEAD && echo REBASADO || echo FALTA-REBASE
```

Compuerta:

```
/opt/homebrew/bin/gh pr checks <pr> | head -3
ORBIT_TEST_DSN="postgresql://orbit:orbit@localhost:5432/postgres" /Users/dn/dev/goncloud-Orbit/.venv/bin/python -m pytest tests/test_precio_write.py tests/test_spapi_write_client.py tests/test_architecture.py -q | tail -2
/opt/homebrew/bin/git -C /Users/dn/dev/wt-fase8-c grep -c pendiente_sonda -- app/spapi/precio_write.py
```

Esperado: `REBASADO`; `quality` en `pass`; `N passed` sin `skipped`; y el `grep -c` devuelve `1` o más, que es la prueba de que la forma del parche quedó sin sellar. Fallback: `FALTA-REBASE` → rebase y vuelta a la compuerta; el `grep -c` en `0` → el carril inventó la forma del parche, vuelve al paso 1 del loop con encargo de corrección.

---

## Cuando algo se atora

Estas son las de esta fase. Las universales están en la sección 12 del loop y no se repiten.

| Situación | Qué hace el lead |
|---|---|
| El kit no está en `/Users/dn/dev/summonaikit-claude/tools` | `ATORADO kit ausente en /Users/dn/dev/summonaikit-claude/tools` y **la fase para**. No se busca el script por el disco ni se mergea por otra vía. |
| `.saikit/autopilot.json` no está en `origin/master` de Orbit | `ATORADO bootstrap ausente` y **la fase para**: el kit lo lee de ahí y ningún carril puede agregarlo. `atencion_requerida: true`. |
| El candado léxico rechaza un comando por nombrar el script del kit | Es el comportamiento esperado del candado, no una falla: se corre el comando del kit tal como está escrito en la sección 6 del loop, con la ruta entera y sin envolverlo en otra cosa. |
| PostgreSQL local caído (`pg_isready` no dice `accepting connections`) | `/opt/homebrew/bin/brew services start postgresql@16`, esperar y reintentar una vez. Si sigue caído: los carriles A, B y C quedan `atorado` con `detenido_por` textual; el carril D no depende de eso y sigue. No se usa Docker: no está en la Mac. |
| Las pruebas de base salen `skipped` | El carril no terminó. Encargo de corrección al mismo implementador con el comando del DSN de la regla 2. Un `skipped` nunca cuenta como DoD cumplida. |
| `origin/master` de Orbit avanzó (otra sesión mergeó) | Rebase del carril sobre `origin/master` y vuelta a la compuerta del ítem. Es esperable: el checkout principal está ocupado por otra sesión. |
| Ya existe una migración `0039` al llegar a la compuerta | El carril A renumera a `0040` en el mismo PR, vuelve al paso 3 del loop y la cola se reordena solo en ese ítem. |
| El carril C necesita `tests/test_architecture.py` y B no ha mergeado | El carril C trabaja en todo lo demás y deja ese archivo para el final. No se adelanta: la regla 5 fija el orden. |
| `ssh goncloud` no responde en el carril D | Los datos que faltan quedan `unknown` con el `SELECT` que los resolvería escrito al lado, y el carril entrega lo que sí midió. No se detiene la fase por eso. |
| Un implementador entrega la forma del parche de precio resuelta | Encargo de corrección: se marca `pendiente_sonda`. Sellar esa forma es la fila A.4 del plan y es de David. |
| El plan y este runbook se contradicen en una fila | Gana el plan. El lead escribe la discrepancia como residual en el PR del carril y **no** edita el plan. |
| Se necesita un cuarto PR abierto | No se abre: se cierra uno primero, según la sección 5 del loop. La ola 2 no arranca hasta que Q1 esté mergeado. |

---

## Inventario y cierre

**Cuentas.** Cuatro carriles, cuatro PRs, cuatro ítems de cola, cuatro filas del plan (A.0, A.2, A.3, E.1). Una migración nueva (`0039`). Cero despliegues, cero escrituras en Amazon, cero escrituras en la base de producción.

**Presupuesto.** Hasta tres rondas cruzadas por PR según la sección 4 del loop, con cuatro PRs: como máximo doce rondas, a 100–150 mil tokens cada una. No hay nada que preparar antes de lanzar salvo las precondiciones del paso 0.0; la cuota de los proveedores se trata con la fila universal de la sección 12.

**Fuera de alcance de esta fase**, y por qué: las filas **A.1** (herramienta de goals) y **A.7** (catálogo y cobertura) del plan, que van a una fase siguiente para no pasar del tope de tres PRs; **A.5** y **A.6**, que dependen de A.1 y A.7; **A.4**, **E.2**, **D.1** y todo lo de las fases 0, B y M del plan, que llevan decisión o go literal de David. Las fases E, B y M del plan **no están validadas** por las cinco perspectivas: eso ocurre antes de implementarlas, y esta fase no toca ninguna de ellas.

**Cómo reporta el lead.** Al cerrar cada carril y al cerrar la fase, la última línea en pantalla es `LISTO <sha>` o `ATORADO <razón en una línea>`, según la sección 2 del loop. El cierre de fase incluye la revisión completa de la sección 10 del loop contra la DoD literal de las cuatro filas, con mutación de las pruebas nuevas, antes de declarar nada. El estado final queda en `.saikit/progress/8.json`, con `siguiente_paso` diciendo en lenguaje llano que lo que sigue es de David: la sonda de escritura de A.4 y el acta del percentil de envío de E.2.

**La fuente es este archivo.** Cualquier copia en una página web es eso, una copia, y lo dice en su pie.

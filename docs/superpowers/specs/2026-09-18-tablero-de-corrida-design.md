# Tablero de corrida — diseño

Fecha: 2026-09-18. Estado: propuesto.
Reemplaza en alcance, no en código, al tablero de fase de la Fase 7 (`tablero-runbook`), que se extiende.

## Para qué

Hoy el avance de una corrida en autopilot solo se ve si el lead se acuerda de escribirlo. La Fase 7 entregó el plugin `tablero-runbook` —RPC, rutas HTTP, render, 2 500 líneas con pruebas— y el propio `Plans.md` lo registra así: *"la Fase 7 entregó un tablero que nunca se encendió"*.

Medido el 2026-09-18, eso es inexacto y el matiz importa: el plugin **está vivo en el gateway y responde**. `openclaw gateway call runbook.progress.get --params '{"fase":"6"}'` desde la Mac devuelve el documento real de la Fase 6, su HTML de 10 107 bytes y sus derivados (`porcentajeMergeado: 100`, 7 de 7 carriles). Lo que nunca pasó fue que alguien lo usara **durante** una corrida: el único documento que existe es la escritura única de cierre del 16 de septiembre.

Este diseño cierra esa brecha por dos lados: el tablero se actualiza solo con lo que se puede derivar, y la corrida se abre en el nacimiento del runbook en vez de depender de que el lead se acuerde a media noche.

## Requisito que manda

La pantalla tiene que servir **siempre que se haga un runbook, en cualquier tarea y cualquier proyecto**. La sección "Degradación visible" es donde se cumple o se rompe.

## Qué NO cambia (invariantes que este diseño no toca)

1. **Cero hooks de agente y cero tools.** La decisión de blast radius de la Fase 7 se mantiene palabra por palabra: este plugin no registra `registerHook`, `registerTool` ni `api.on(...)`, así que no puede alterar, retrasar ni bloquear ningún turno. El manifest no declara `contracts`.
2. **Un solo escritor.** La regla 2 del spec `runbook-progress.v1` (una escritura reemplaza el documento completo, last-writer-wins, sin parches parciales) queda intacta. Todo lo derivado se calcula **en la lectura** y nunca se guarda.
3. **La regla de seguridad del render.** Truncar primero, escapar después, en el punto de interpolación, sin excepciones por campo, una sola función `esc()`.
4. **Sanitizar validando.** Las claves de disco y URL tienen forma cerrada. Ninguna se afloja.
5. **Fail-open.** Ningún fallo de disco, red o `gh` tumba la pantalla ni lanza; se registra la clase del error y se rotula en la vista.

## Arquitectura: un tercer cruce en la lectura

`armarTablero()` ya hace, en cada GET: leer el documento del disco → `derivar()` → cruzar en vivo con GitHub por `gh pr view` → renderizar. El cruce con GitHub **no se guarda**; se calcula y se rotula "GitHub" para distinguirlo de lo que reportó el lead.

Este diseño agrega un segundo cruce con el mismo molde:

```
GET /runbook/tablero/c/<corrida>
  └─ leer doc de disco            (lo que escribió el lead: el juicio)
     ├─ derivar()                 (puro, sin E/S)
     ├─ cruzarGitHub()            (existe: PRs, CI)
     ├─ cruzarPlan()              (NUEVO: estado de los ítems según el plan)
     └─ renderTablero()           (reescrito al estilo del tablero)
```

`plan.ts` es hermano de `github.ts` y copia su molde exacto: `execFile` con `shell:false`, argv literal, `windowsHide: true`, presupuesto de tiempo global además del timeout por llamada, `execFile` inyectable para las pruebas, y fail-open a `unknown`. Trae el plan con `gh api repos/<repo>/contents/<ruta>`.

No hay temporizador, no hay proceso nuevo, no hay segundo escritor. La pantalla está fresca en el momento en que alguien la abre.

**Por qué no un derivador con temporizador que escriba:** chocaría con la regla 2. El derivador y el lead escribirían el mismo documento completo y se pisarían; resolverlo obliga a partir el documento en capas con merge por campo. El cruce en lectura evita el problema en vez de resolverlo.

**Por qué no un disparador en la Mac:** vería el estado local sin esperar al push, pero es una pieza nueva en la Mac, que es justo donde `Plans.md` anota que "todo esto vive solo en esta Mac y se pierde al cambiar de máquina". Queda como fase 2 si la latencia del push resulta molesta en la práctica.

## Contrato: el delta sobre `runbook-progress.v1`

### La clave nueva `corrida`

Hoy la clave de disco y de URL es `fase`, con regex numérica a propósito (el código anota: "validar ES sanitizar"). Dos proyectos corriendo su "Fase 11" colisionarían. La regex **no se afloja**; se agrega una clave al lado:

| Campo | Forma | Papel |
|---|---|---|
| `corrida` | `^[a-z0-9][a-z0-9-]{0,40}$` | clave de disco y de URL; igual de sanitizante que `fase` |
| `fase` | sin cambios | texto de cabecera |
| `proyecto` | ≤300 caracteres | nombre legible; la cabecera dice `<fase> · <proyecto> — <título>` |

Rutas nuevas: `/runbook/tablero/c/<corrida>` y `/runbook/progress/c/<corrida>.json`. Las rutas por fase siguen sirviendo, así que el documento de la Fase 6 no se rompe.

### El bloque `plan`

```json
"plan": { "repo": "gon0801/goncloud-Orbit", "ruta": "plans/", "seccion": null }
```

- `repo` casa el `REPO_RE` que ya existe.
- `ruta` es un archivo (`Plans.md`) **o** un directorio (`plans/`). Sin `..`, sin ruta absoluta, ≤200 caracteres.
- `seccion` acota el cruce a un encabezado del plan, o `null` para todo el archivo.
- El bloque entero puede ser `null`: proyecto sin plan legible.

**El plugin no adivina la ruta, nunca.** Si el documento no la declara, no hay cruce con el plan. Adivinar "Plans.md" haría fallar en silencio justo al proyecto del screenshot.

### Campos de juicio que escribe el lead

Lo que ninguna derivación puede sacar:

- `cola[].avance` — entero 0–100, el relleno de las barras.
- `notas` — arreglo de líneas al pie (`"B: muse corrige 5 bloqueantes + 5 altas (r1)"`), ≤300 caracteres cada una, máximo 8.

`%GLOBAL` **no se escribe**: se deriva promediando los `avance` de los ítems que cuentan. Un ítem NO cuenta cuando su carril está `omitido` (`omitido` es valor de `carriles[].estado`, no de `cola[].estado`): es el renglón "No corre" del tablero de referencia. Un ítem sin carril —el "Cierre" de la referencia— SÍ cuenta, con su `avance` y la celda de carril vacía; el join tiene que tolerarlo.

## El parser del plan

Los marcadores sí son universales; lo medido el 2026-09-18:

| Proyecto | Archivo del plan | Marcadores contados |
|---|---|---|
| goncloud-openclaw | `Plans.md` (raíz) | 19 `cc:TODO`, 16 `cc:完了` |
| goncloud-trading-system | `Plans.md` (raíz) | 1 `cc:TODO`, 47 `cc:完了` |
| goncloud-Orbit | `plans/` (directorio) | 34 `cc:TODO`, 4 `cc:WIP`, 198 `cc:完了`, 23 `cc:DONE` |
| accounting, shopify, server | ninguno | — |

De ahí el mapeo:

| Marcador | Estado derivado |
|---|---|
| `cc:TODO` | `pendiente` |
| `cc:WIP` | `implementando` |
| `cc:完了`, `cc:DONE` | `mergeado` |
| cualquier otro | `unknown` |

`cc:DONE` cuenta como terminado: son 23 casos reales en Orbit y tratarlos como `unknown` pintaría la corrida peor de lo que está.

El cruce es **advertencia, no verdad**: cuando el plan y lo que escribió el lead discrepan, manda lo que escribió el lead y la fila se marca con la discrepancia. El lead sabe cosas que el marcador no (un ítem mergeado que hubo que revertir).

## El render

Al estilo del tablero de referencia, fondo oscuro:

- **Cabecera:** `<fase> · <proyecto> — <título>`, con `%GLOBAL` y su barra a la derecha.
- **Subtítulo:** hora en la zona de quien mira · "N de M ítems en master" · "sin atores" o el conteo.
- **Tabla:** ÍTEM · CARRIL · ESTADO (con punto de color) · RONDAS · PR · AVANCE (barra + porcentaje). Es un **join** de `cola[]` con `carriles[]`; ambos ya existen en el spec, solo se pintan juntos.
- **Pie:** las `notas`, y el rótulo de procedencia de cada cruce.
- **Banner de atención** arriba de todo cuando `atencion_requerida.necesaria`, como hoy.

## Los tres accesos

Los tres verificados el 2026-09-18.

| Quién | Cómo | Estado |
|---|---|---|
| David | `/runbook/tablero/c/<corrida>` por Tailscale | la ruta por fase ya sirve hoy |
| claw | RPC `runbook.progress.get` | verificado: responde |
| Hermes | por SSH **en la Mac**, el mismo `~/.openclaw/bin/openclaw gateway call runbook.progress.get` | verificado: la CLI de la Mac ya está autenticada |

Hermes **no necesita credencial del gateway, ni `curl`, ni un `eventos.jsonl` de respaldo**: entra por SSH a la Mac, y desde la Mac la CLI ya está autenticada. El `get` devuelve el documento, los derivados y el HTML, así que Hermes elige JSON o texto. Esto contesta, para este propósito, el `veredicto hermes: unknown` del spike 9.0.

## Degradación visible

La regla que hace que la pantalla sirva siempre:

> Cuando una fuente derivada no se puede leer, la pantalla **sigue viva con lo que escribió el lead y lo dice**. Nunca inventa, nunca se cae, nunca calla.

| Situación | Qué se ve |
|---|---|
| `plan` es `null` | tabla completa, sin columna derivada, rótulo "plan: no declarado" |
| `gh` falla, sin red, sin cuota | "plan: sin verificar" / "GitHub: sin verificar" |
| el repo no está en GitHub | "plan: sin verificar" |
| la `ruta` no existe en el repo | "plan: ruta no encontrada" |
| no hay documento para esa corrida | 404 con el texto de cómo abrirla |

Un proyecto sin `Plans.md` —accounting, shopify, server— **tiene tablero**: sus renglones son los que el lead declaró, sin capa derivada. Eso es lo que significa "sirve en cualquier proyecto".

## El paso de nacimiento

El slot 12 "Progreso" del skill global `~/.claude/skills/autopilot-runbook/SKILL.md` ya es OBLIGATORIO ("a missing slot is where the question comes from") y ya manda escribir `runbook-progress.v1` y enviarlo por `runbook.progress.set`. Pero dice *"on every lane or queue state change"*: depende de que el lead se acuerde a media corrida. Ese es el mecanismo que produjo un tablero que nunca se encendió.

Se le agrega un paso de **nacimiento**, y se actualiza a la clave `corrida`:

> Abrir la corrida en el tablero es el **primer comando del runbook**, antes de lanzar ningún carril: una escritura con `corrida`, `proyecto`, `plan` y los ítems en `pendiente`. Un runbook cuyo primer comando no sea ese está incompleto. La URL de la pantalla va en el encabezado del runbook.

El skill es global, fuera de este repo, así que el cambio aplica a cualquier proyecto desde el siguiente runbook que se escriba.

## Pruebas

El molde existe: `github.test.ts` inyecta el `execFile` en vez de llamar a `gh` de verdad. `plan.test.ts` hace igual.

Fixtures de los tres casos reales medidos arriba:

1. `Plans.md` en la raíz (openclaw) → estados derivados correctos.
2. directorio `plans/` con varios archivos (Orbit) → junta los marcadores de todos.
3. proyecto sin plan → "sin verificar", **no** error.

Candados que importan:

- `corrida` con `..`, `/`, percent-encoding malformado o mayúsculas → rechazada **antes** de construir ninguna ruta de disco.
- `cc:DONE` cuenta como terminado; un marcador desconocido da `unknown`, no `pendiente`.
- `gh` caído, sin cuota o colgado (presupuesto agotado) → la pantalla responde 200 con el rótulo, no 500.
- `%GLOBAL` sale del promedio de `avance`, no de contar marcadores; un ítem cuyo carril está `omitido` no entra en el promedio, y un ítem sin carril sí entra y se pinta con la celda de carril vacía.
- discrepancia entre plan y lead → manda el lead, y la discrepancia se ve.
- las rutas por `fase` siguen sirviendo el documento de la Fase 6 sin cambios (no regresión).
- `notas` con más de 8 líneas o de 300 caracteres se trunca antes de escapar.

Poder discriminante: cada prueba debe fallar si se quita el cambio que la motiva. En particular, la prueba de `cc:DONE` tiene que ponerse roja si se borra el sinónimo, y la de degradación tiene que ponerse roja si el rótulo desaparece aunque el HTML siga saliendo.

## Fuera de alcance

- El disparador en la Mac que empuja sin esperar al push (enfoque C; fase 2 si hace falta).
- Mandar avisos por Telegram desde el tablero: eso es el latido de la Fase 9, pieza aparte.
- Un tablero combinado con varios proyectos a la vez.
- Retrofitear los runbooks de las fases 6 a 9, que se escribieron antes de que esto existiera.
- Editar el estado desde la pantalla: es de solo lectura.

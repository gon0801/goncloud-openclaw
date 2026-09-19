# runbook-progress.v2, el JSON de progreso de un runbook en autopilot

Fecha: 2026-09-19. Estado: contrato publicado; un documento v1 sigue siendo válido y se sigue sirviendo por su ruta vieja (`/runbook/progress/<fase>.json`, RPC por `fase`). Este texto describe la forma v2. No sustituye a [runbook-progress.v1.md](runbook-progress.v1.md): lo extiende.

## Transición del `schema` (candado de la Fase 7)

El literal de **este** contrato es `runbook-progress.v2`. El validador del plugin `tablero-runbook` **sigue exigiendo** `schema: "runbook-progress.v1"` (candado de la Fase 7). Un documento cuyo `schema` sea `runbook-progress.v2` se rechaza. Eso lo clava `tablero-runbook/progress.test.ts` (el caso que asigna el literal `runbook-progress.v2` y exige una razón que nombre `schema`).

Los campos nuevos de v2 se validan **cuando están presentes**. Un documento v1 sin esos campos sigue validando igual que hoy. Esta nota es de transición, no un reescrito del candado.

## Para qué

Hoy el avance de un runbook está repartido en PRs, comentarios `APPROVE lead`, celdas de `Plans.md`, worktrees y palomitas manuales. Nadie lo lee junto. Este JSON es la **única fuente** que una interfaz pinta. Lo escribe el lead del runbook, no la interfaz. La interfaz lo cruza con el estado vivo de GitHub cuando puede, y con el plan cuando el bloque `plan` está presente.

La forma v1 usaba `fase` como única clave de disco y de URL. Dos proyectos con la misma fase se pisan. v2 agrega `corrida` como clave de disco y de URL, deja `fase` con la misma regex de siempre (texto de cabecera; validar **es** sanitizar: el path traversal se cierra ahí), y suma `proyecto`, el bloque `plan`, `cola[].avance` y `notas`.

## Dónde vive y cómo se escribe

- **Destino:** el gateway, vía el método RPC `runbook.progress.set` del plugin `tablero-runbook` (Fase 7). Desde la Mac: `~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat <archivo.json>)"`. La CLI remota ya está autenticada; no se lee ningún token.
- **Copia local del lead:** `.saikit/progress/<fase>.json` en el repo del runbook, misma forma, actualizada en cada escritura. Se commitea solo en el PR de cierre (es el rastro; durante la corrida cambia demasiado).
- **Cuándo se escribe:** en cada cambio de estado de un carril o de un ítem de la cola, y al cierre. No por cada comando. Una escritura fallida nunca detiene el trabajo: se reintenta en el siguiente cambio de estado y se anota en `eventos`.
- **Quién escribe:** solo el lead. Los implementers reportan al lead; el lead escribe.
- **Ruta vieja:** un documento v1 sin los campos nuevos se sirve por `/runbook/progress/<fase>.json` y por `runbook.progress.get` con `fase`. Esa ruta no se retira.
- **Ruta nueva (cuando hay `corrida`):** `/runbook/progress/c/<corrida>.json` y `/runbook/tablero/c/<corrida>`. `corrida` es clave de disco y de URL; se sanitiza con la misma idea que `fase`.

## Forma (v2)

```json
{
  "schema": "runbook-progress.v2",
  "runbook": "docs/runbooks/autopilot-fase12.md",
  "fase": "12",
  "corrida": "fase12-tablero",
  "proyecto": "goncloud-openclaw",
  "titulo": "Tablero de corrida",
  "plan": { "repo": "gon0801/goncloud-openclaw", "ruta": "Plans.md", "seccion": "Fase 12" },
  "lead": { "agente": "claude", "inicio": "2026-09-19T04:00:00Z", "actualizado": "2026-09-19T04:10:00Z" },
  "atencion_requerida": { "necesaria": false, "motivo": null, "desde": null },
  "siguiente_paso": "Contrato v2 publicado; el validador aún exige schema v1 y valida estos campos cuando vienen.",
  "carriles": [
    {
      "id": "C",
      "nombre": "Contrato",
      "repo": "gon0801/goncloud-openclaw",
      "rama": "fase12/contrato",
      "tareas": ["12.0"],
      "estado": "implementando",
      "paso_loop": 3,
      "ronda": 1,
      "pr": null,
      "head": null,
      "approve_lead": null,
      "ci": "sin-ci",
      "coderabbit": "pendiente",
      "residuales": [],
      "detenido_por": null,
      "ultimo_evento": { "at": "2026-09-19T04:10:00Z", "que": "campos v2 presentes sobre schema v1" }
    }
  ],
  "cola": [
    { "id": "12.0", "prs": [], "estado": "pendiente", "ventana": null, "merge_commits": [], "verificado": null, "detenido_por": null, "avance": 40 }
  ],
  "notas": ["C: contrato v2 y corte de lib.ts"],
  "eventos": [
    { "at": "2026-09-19T04:10:00Z", "carril": "C", "que": "escritura de progreso con campos v2", "situacion": null }
  ],
  "cierre": { "at": null, "telegram_message_id": null, "resumen": null }
}
```

Un documento v1 (sin `corrida`, `proyecto`, `plan`, `notas` ni `cola[].avance`) permanece una instancia válida de este contrato en lo que solapa, y se sigue sirviendo por la ruta vieja.

### Valores cerrados

Siguen valiendo los de v1. Lo que cambia o se suma:

| Campo | Valores |
|---|---|
| `schema` | en este contrato, literal `runbook-progress.v2`. El validador vivo del plugin, hoy, sigue exigiendo `runbook-progress.v1` (ver transición arriba) |
| `corrida` | cadena que casa `^[a-z0-9][a-z0-9-]{0,40}$` (minúsculas, sensible a mayúsculas); es clave de disco y de URL; misma idea sanitizante que `fase`. Rechaza `..`, `/`, mayúscula y vacío |
| `fase` | cadena que casa `^[0-9]{1,3}(\.[0-9]{1,3})?$`. La regex no cambia. En v1 era clave de disco y de URL. En v2 es texto de cabecera y sigue siendo la clave de la ruta vieja. Validar **es** sanitizar. El path traversal se cierra en esa forma cerrada |
| `proyecto` | texto de cabecera, no vacío, ≤300 caracteres |
| `plan` | `{repo, ruta, seccion}` o `null` (proyecto sin plan legible); el bloque entero puede faltar |
| `plan.repo` | el `REPO_RE` ya existente: `^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$` (nunca empieza con `-`) |
| `plan.ruta` | archivo (`Plans.md`) o directorio (`plans/`); relativa; ≤200 caracteres; nunca un segmento `..` ni una ruta absoluta (`/` o unidad de Windows) |
| `plan.seccion` | texto de cabecera ≤300 caracteres, o `null` (todo el archivo o directorio) |
| `cola[].avance` | entero 0–100 |
| `notas` | ≤8 líneas; cada una, texto ≤300 caracteres |
| `atencion_requerida` | `{necesaria: bool, motivo: string|null, desde: ISO|null}`; `necesaria: true` solo cuando una fila de atores dice que el caso llega a David (en Fase 6, la reversa de Q4 que falla dos veces); se pinta como banner arriba de todo |
| `siguiente_paso` | una frase en lenguaje llano, ≤160 caracteres, que David entienda sin contexto; la escribe el lead en cada cambio |
| `carriles[].repo`, `cola[].prs[].repo` | `^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9._-]{1,100}$` (nunca empieza con `-`) |
| `carriles[].pr`, `cola[].prs[].pr` | entero positivo menor que 10 000 000, o `null` |
| `carriles[].estado` | `pendiente` · `implementando` · `revision-cruzada` · `coderabbit` · `auditoria-lead` · `en-cola` · `mergeado` · `atorado` · `revertido` · `omitido` (este último no se usa en Fase 6; existe para runbooks que cancelen un carril) |
| `carriles[].paso_loop` | entero 0 a 8, el paso del loop de cross-review en curso (0 = no empezó) |
| `carriles[].ci` | `pendiente` · `verde` · `rojo` · `sin-ci` · `unknown` |
| `carriles[].coderabbit` | `pendiente` · `limpio` · `con-hallazgos` · `sin-cuota` · `unknown` |
| `cola[].estado` | `pendiente` · `esperando-ventana` · `mergeando` · `sync` · `verificado` · `revertido` · `atorado` |
| `cola[].verificado` | `null` (no aplica aún) · `pendiente` · `ok` · `fallo` · `unknown`: resultado de la compuerta del ítem (por ejemplo, SHA del gateway igual al mergeado tras el sync) |
| `cola[].detenido_por` | `null` o el texto de la fila de atores que aplicó; obligatorio cuando `estado` es `atorado` |
| `eventos[].situacion` | `null` o el texto literal de la primera columna de la tabla "Cuando algo se atora" que aplicó |

### Reglas

Las de v1 que siguen aplicando, más las de los campos nuevos:

1. En este contrato `schema` es literal `runbook-progress.v2`. El validador del plugin, en la transición, sigue rechazando cualquier valor distinto de `runbook-progress.v1`, incluido este literal, y valida los campos v2 solo cuando vienen.
2. `fase` sigue siendo la clave de la ruta vieja: una escritura reemplaza el documento completo de esa fase (last-writer-wins). `corrida`, cuando está, es la clave de la ruta nueva y del archivo en disco bajo esa clave. No hay parches parciales.
3. `carriles[].id` es único y estable durante toda la corrida; los carriles no desaparecen: un carril cancelado pasa a `omitido` con `detenido_por`.
4. `eventos` es append-only y el lead conserva al menos los últimos 50; el plugin guarda todos en un jsonl aparte.
5. Todo texto (`titulo`, `proyecto`, `nombre`, `rama`, `head`, `tareas[]`, `ventana`, `que`, `residuales`, `detenido_por`, `motivo`, `siguiente_paso`, `resumen`, `plan.seccion`, cada línea de `notas`) se escribe sin secretos ni salidas crudas: máximo 300 caracteres por campo (160 en `siguiente_paso`); el plugin trunca primero y escapa después, en el punto de interpolación, sin excepciones por campo.
6. Lo que no se sabe se escribe `unknown` o `null`, nunca se inventa. `null` significa "todavía no aplica"; `unknown` significa "se intentó saber y no se pudo". El bloque `plan` en `null` significa "este proyecto no tiene plan legible"; sin bloque, no hay cruce con el plan.
7. Un `estado: atorado`, en carriles o en cola, lleva `detenido_por` no nulo con la fila de atores que aplicó.
8. Exposición: `runbook.progress.get` y las rutas `/runbook/progress/<fase>.json` y `/runbook/progress/c/<corrida>.json` devuelven el documento completo, `residuales`, `eventos` y `notas` incluidos, a cualquiera que pase la autenticación del gateway. Quien escribe no pone nada que no pueda leer todo operador del gateway.
9. `corrida` y `fase` se validan por forma cerrada. Validar **es** sanitizar: `..`, `/` y basura de path no pasan la regex, y no se construye ninguna ruta de disco con un valor que no haya pasado. `corrida` no reutiliza la regex de `fase`.
10. `plan.ruta` acepta archivo o directorio y rechaza un segmento `..` y una ruta absoluta. El plugin no adivina la ruta.

## Qué deriva la interfaz (no se escribe en el JSON)

Porcentaje de carriles mergeados, carriles atorados, siguiente ítem de la cola, tiempo desde el último evento, y, cuando el plugin tiene acceso a GitHub, el estado vivo de cada PR (mergeable, checks) marcado como "GitHub" para distinguirlo de lo reportado por el lead.

Cuando el documento trae `cola[].avance`, el `%GLOBAL` de la pantalla se deriva promediando esos enteros sobre los ítems que cuentan (un ítem cuyo carril está `omitido` no cuenta). Ese porcentaje no se escribe en el JSON.

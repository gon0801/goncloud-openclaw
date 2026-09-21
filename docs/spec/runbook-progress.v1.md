# runbook-progress.v1 — el JSON de progreso de un runbook en autopilot

Fecha: 2026-09-15. Estado: activo desde que se mergea; obligatorio para todo runbook nuevo escrito con la skill `autopilot-runbook`. La Fase 6 en vuelo no se retrofitea: su cierre (Q5) escribe el JSON una vez con el estado final.

## Para qué

Hoy el avance de un runbook está repartido en PRs, comentarios `APPROVE lead`, celdas de `Plans.md`, worktrees y palomitas manuales. Nadie lo lee junto. Este JSON es la **única fuente** que una interfaz pinta. Lo escribe el lead del runbook, no la interfaz; la interfaz solo lo cruza con el estado vivo de GitHub cuando puede.

## Dónde vive y cómo se escribe

- **Destino:** el gateway, vía el método RPC `runbook.progress.set` del plugin `tablero-runbook` (Fase 7). Desde la Mac: `~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat <archivo.json>)"`. La CLI remota ya está autenticada; no se lee ningún token.
- **Copia local del lead:** `.saikit/progress/<fase>.json` en el repo del runbook, misma forma, actualizada en cada escritura. Se commitea solo en el PR de cierre (es el rastro; durante la corrida cambia demasiado).
- **Cuándo se escribe:** en cada cambio de estado de un carril o de un ítem de la cola, y al cierre. No por cada comando. Una escritura fallida nunca detiene el trabajo: se reintenta en el siguiente cambio de estado y se anota en `eventos`.
- **Quién escribe:** solo el lead. Los implementers reportan al lead; el lead escribe.

## Forma (v1)

```json
{
  "schema": "runbook-progress.v1",
  "runbook": "docs/runbooks/autopilot-fase6.md",
  "fase": "6",
  "titulo": "Autopilot de la Fase 6",
  "lead": { "agente": "claude", "inicio": "2026-09-16T01:10:00Z", "actualizado": "2026-09-16T03:42:10Z" },
  "atencion_requerida": { "necesaria": false, "motivo": null, "desde": null },
  "siguiente_paso": "Esperando ventana segura para mergear los tres workspaces; próximo intento a las 19:16 hora del Este.",
  "carriles": [
    {
      "id": "A",
      "nombre": "Director",
      "repo": "gon0801/goncloud-workspace-main",
      "rama": "fase6/director",
      "tareas": ["6.0a", "6.1", "6.3"],
      "estado": "en-cola",
      "paso_loop": 7,
      "ronda": 2,
      "pr": 15,
      "head": "c5bd640",
      "approve_lead": "c5bd640",
      "ci": "verde",
      "coderabbit": "sin-cuota",
      "residuales": ["6.3: fila ingenieria unknown, remote -v no coincidió"],
      "detenido_por": null,
      "ultimo_evento": { "at": "2026-09-16T03:40:00Z", "que": "APPROVE lead c5bd640" }
    }
  ],
  "cola": [
    { "id": "Q2", "prs": [{ "repo": "gon0801/goncloud-workspace-main", "pr": 15 }, { "repo": "gon0801/goncloud-workspace-ingenieria", "pr": 8 }, { "repo": "gon0801/goncloud-workspace-operaciones", "pr": 5 }], "estado": "esperando-ventana", "ventana": "19:16-21:05 America/New_York", "merge_commits": [], "verificado": null, "detenido_por": null }
  ],
  "eventos": [
    { "at": "2026-09-16T03:42:10Z", "carril": "A", "que": "escritura de progreso reintentada tras fallo de gateway call", "situacion": null }
  ],
  "cierre": { "at": null, "telegram_message_id": null, "resumen": null }
}
```

### Valores cerrados

| Campo | Valores |
|---|---|
| `fase` | cadena que casa `^[0-9]{1,3}(\.[0-9]{1,3})?$`; es clave de disco y de URL, por eso la forma es cerrada |
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

1. `schema` es literal `runbook-progress.v1`; cualquier otro valor se rechaza.
2. `fase` es la clave: una escritura reemplaza el documento completo de esa fase (last-writer-wins). No hay parches parciales.
3. `carriles[].id` es único y estable durante toda la corrida; los carriles no desaparecen: un carril cancelado pasa a `omitido` con `detenido_por`.
4. `eventos` es append-only y el lead conserva al menos los últimos 50; el plugin guarda todos en un jsonl aparte.
5. Todo texto (`titulo`, `nombre`, `rama`, `head`, `tareas[]`, `ventana`, `que`, `residuales`, `detenido_por`, `motivo`, `siguiente_paso`, `resumen`) se escribe sin secretos ni salidas crudas: máximo 300 caracteres por campo (160 en `siguiente_paso`); el plugin trunca primero y escapa después, en el punto de interpolación, sin excepciones por campo.
6. Lo que no se sabe se escribe `unknown` o `null`, nunca se inventa. `null` significa "todavía no aplica"; `unknown` significa "se intentó saber y no se pudo".
7. Un `estado: atorado`, en carriles o en cola, lleva `detenido_por` no nulo con la fila de atores que aplicó.
8. Exposición: `runbook.progress.get` y la ruta `/runbook/progress/<fase>.json` devuelven el documento completo, `residuales` y `eventos` incluidos, a cualquiera que pase la autenticación del gateway. Quien escribe no pone nada que no pueda leer todo operador del gateway.

## Qué deriva la interfaz (no se escribe en el JSON)

Porcentaje de carriles mergeados, carriles atorados, siguiente ítem de la cola, tiempo desde el último evento, y, cuando el plugin tiene acceso a GitHub, el estado vivo de cada PR (mergeable, checks) marcado como "GitHub" para distinguirlo de lo reportado por el lead.

### Resumen objetivo por fase y carril (`resumirSeguimiento`, RPC `runbook.progress.list`)

El porcentaje nunca lo estima un modelo; sale de las unidades del plan que ya cruza `tablero-runbook`:

- Solo `mergeado` cuenta como terminada. `pendiente` e `implementando` cuentan como no terminadas.
- Un carril `omitido` no entra en el denominador de la fase: las tareas que solo viven en carriles omitidos se excluyen. Una tarea compartida por dos carriles incluidos cuenta una sola vez a nivel de fase.
- Un carril `atorado` sí entra mientras no haya sido omitido formalmente.
- Si el plan no se puede verificar (`sin-verificar`, `ruta-no-encontrada`, `nulo`) o una tarea falta del cruce o llega `unknown`, el conteo es `desconocido`, nunca 0%. Un conjunto vacío verificado es `0/0`, 0%.
- `actividad.detalle` sale de `detenido_por`, o del estado del carril; `iniciadaEn` y `ultimaEvidencia` salen de `ultimo_evento`, o de `lead.inicio` y el estado. No se inventa prosa ni marcas de tiempo.
- Cada resumen lleva un `trabajoId` estable: `corrida:<id>` cuando el documento trae `corrida`, o `fase:<fase>`. La lista solo expone documentos abiertos (`cierre.at` nulo).
- Un archivo que nombra una fase o corrida pero está roto (ilegible, JSON inválido o documento inválido) conserva su `trabajoId` con progreso `desconocido` y su causa aparte: nunca se confunde con "nada activo".

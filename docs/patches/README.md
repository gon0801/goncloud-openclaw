# Patches de modelo — APLICADOS 2026-09-10

Estos archivos ya fueron aplicados al gateway el 2026-09-10 y quedan como registro de lo aplicado. Nota de fidelidad: lo aplicado en produccion usa `deepseek/deepseek-v4-flash` donde la tabla FASE-B original decia `deepseek/deepseek-v4-pro` (decision de David, 2026-09-10); estos archivos ya reflejan el flash real. `modelos-rollback.json5` NO se toco: describe el estado pre-M1 exacto (primarios OpenAI) y solo sirve para volver a ese estado.

`config patch` mergea objetos y **reemplaza arrays enteros**. Los `fallbacks` del patch sustituyen la lista previa completa.

Reglas de cadena (FASE B, brief `2026-09-10-cursor-FASE-B-cadenas-modelos.md`): ningun agente repite proveedor; toda la cadena en runtime nativo (sin OpenAI-OAuth/codex); 4 proveedores + Anthropic como 5o. Esta tabla reemplaza M1 puntos 1-2 del brief de agentes.

**Donde se aplican.** `openclaw config patch` desde la Mac escribe `~/.openclaw/openclaw.json` local, no el gateway. Correr los patches **en la maquina Windows** (CLI local al gateway). No usar `gateway call config.patch` a ciegas (sin dry-run verificado).

## Fuente del rollback

`openclaw config get agents.entries.<id>.model` (CLI remote) devolvio **unset**.

**Re-verificado 2026-09-10** con lectura viva (permitida):

```bash
~/.openclaw/bin/openclaw gateway call config.get --params '{}'
# usar parsed.agents.entries.<id>.model
```

Los valores de `modelos-rollback.json5` coinciden con esa lectura viva del gateway (mismo contenido que el snapshot `openclaw.json` del repo en ese momento). Si el gateway diverge despues, regenerar el rollback antes de revertir.

## modelos-fase1.json5

Reasigna implementer, reviewer, adversary, verifier, ingenieria. Cada cadena tiene 4 proveedores distintos. No toca `main` ni `operaciones`.

Cadenas (FASE B):

| agente | primary | fallbacks |
|---|---|---|
| implementer | zai/glm-5.3 | deepseek/deepseek-v4-flash, kimi/k3, xai/grok-4.6 |
| reviewer | kimi/k3 | deepseek/deepseek-v4-flash, zai/glm-5.3, xai/grok-4.6 |
| adversary | deepseek/deepseek-v4-flash | kimi/k3, zai/glm-5.3, xai/grok-4.6 |
| verifier | deepseek/deepseek-v4-flash | zai/glm-5.3, kimi/k3, xai/grok-4.6 |
| ingenieria | **xai/grok-4.6** | zai/glm-5.3, deepseek/deepseek-v4-flash, kimi/k3 |

```bash
# En la maquina Windows (gateway), no desde la Mac remota:
openclaw config patch --file docs/patches/modelos-fase1.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase1.json5
```

Verificar despues:

```bash
for id in implementer reviewer adversary verifier ingenieria; do
  ~/.openclaw/bin/openclaw config get agents.entries.$id.model
done
```

Esperado: `ingenieria` primary `xai/grok-4.6`; los demas segun tabla; ningun primario OpenAI-OAuth.

**Nota xAI OAuth:** el token en Windows puede vencer ~6 h. Si no auto-renueva, `ingenieria` cae a zai (cadena viva, no bug). Renovar solo en Windows con `openclaw models auth login --provider xai --agent main`.

## modelos-fase2-main-operaciones.json5

`main` y `operaciones`. Aplicar **despues** del estreno de packing. Incluye el 5o eslabon Anthropic (ya desbloqueado) para no dejar esos dos agentes en 4 eslabones.

- `main` → zai → deepseek-pro → kimi → xai → anthropic/claude-sonnet-5
- `operaciones` → zai *(sin cambio de primary)* → deepseek-flash → kimi → xai → anthropic/claude-sonnet-5

```bash
# Windows / gateway, despues del estreno:
openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase2-main-operaciones.json5
```

## modelos-fase3-anthropic.json5

5to eslabon para el pipeline + `ingenieria`. **YA DESBLOQUEADO (2026-09-10 ~07:50Z).** David instalo setup-token; `models.authStatus` lista `anthropic` (`anthropic:manual`, type token, inherited, sin expiracion). Smoke: verifier + `anthropic/claude-haiku-4-5` → harness nativo con tools.

**Aplicable junto con fase1** en Windows. No toca `main` ni `operaciones` (esos van en fase2 post-estreno, ya con Anthropic en la cola).

```bash
# Windows / gateway, junto con fase1:
openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5 --dry-run
openclaw config patch --file docs/patches/modelos-fase3-anthropic.json5
```

Contenido: `anthropic/claude-sonnet-5` en implementer/ingenieria/verifier; `anthropic/claude-opus-5` en reviewer/adversary. Cadena FASE B completa por agente.

Este eslabon consume la **misma** cuota de la suscripcion Claude de David. Si estorba, API key de Anthropic aparte. El token **no** entra al repo.

## Rollback

```bash
# Windows / gateway:
openclaw config patch --file docs/patches/modelos-rollback.json5 --dry-run
openclaw config patch --file docs/patches/modelos-rollback.json5
```

Si solo aplicaste fase1, el rollback tambien reescribe main/operaciones al snapshot. Recorta el JSON a mano si no queres eso.

## Ventana post-reset / ajuste con datos (documentado, no aplicar)

- 2026-09-10 ~13:41Z: chequear si OAuth xAI se auto-renovo. Si no, y login manual cada 6 h es insostenible, bajar `ingenieria` primary a eslabon profundo.
- 2026-09-12 (reset xAI semanal): reevaluar burn de grok en `ingenieria`.
- 2026-09-15 (reset OpenAI): ver `eslabon-6-openai.md` antes de reintroducir gpt-5.x.
- Metricas: `openclaw audit --kind agent_run --status failed --agent <id>`; `models.authStatus` (openai/xai/deepseek). Audit no guarda el modelo que atendio cada corrida.

## Primaries repartidos — PROPUESTA 2026-09-16 (NO aplicada)

Causa (corrida nocturna del 2026-09-15): los 8 agentes colgaban de la misma llave
`opencode-go` y una cuota agotada frenó toda la flota (cooldown de 10 min a 24 h).
Propuesta en `modelos-primaries-repartidos.json5`: ningún proveedor es primary de más
de 2 agentes y `main`/`operaciones` (negocio) no comparten primary con el pipeline.
Respeta FASE B (cadenas con proveedores distintos, runtime nativo sin OpenAI ni codex,
Anthropic al fondo: último fallback de cada cadena) y la regla nueva de David para
esta tabla (negocio separado).

| agente | primary | primer fallback |
|---|---|---|
| main | zai/glm-5.3 | opencode/glm-5.3-flash |
| operaciones | kimi/k3 | opencode/muse-spark-1.3-contributor-free |
| implementer | opencode-go/muse-spark-1.3-contributor | deepseek/deepseek-flash |
| reviewer | opencode/deepseek-v4-flash | opencode-go/deepseek-v4.1-flash |
| adversary | xai/grok-4.6 | opencode-go/deepseek-v4.1-flash |
| verifier | xai/grok-4.6 | deepseek/deepseek-flash |
| ingenieria | deepseek/deepseek-flash | xai/grok-4.6 |
| scout | opencode-go/deepseek-v4.1-flash | xai/grok-4.6 |

**Decisión de David, pendiente: esto toca el negocio.** La tabla mueve `main` a
`zai/glm-5.3` y `operaciones` a `kimi/k3`, así que los crons de packing (`packing-*`,
agente `operaciones`) pasarían a correr con otro proveedor. Separar el negocio de la
llave del pipeline es justo el punto del reparto, pero el cambio de proveedor de los
crons no se aplica sin que David lo apruebe en concreto. Y como el patch es **un solo
archivo con los 8 agentes**, esa decisión bloquea el apply completo: nadie corre el
`config patch` hasta que David apruebe ese cambio. No hay ruta documentada para aplicar
solo los 6 del pipeline; si hiciera falta, se parte el archivo y se documenta aquí.

Primaries por proveedor: opencode-go 2, xai 2, zai/kimi/opencode/deepseek 1. (Los dos
roles de control no comparten dominio de cuota: reviewer en `opencode/free`,
verifier en `xai`.) Primer fallback por proveedor: opencode 2, deepseek 2,
opencode-go 2, xai 2 (tope 3, con check). Carga primary+fb1 por proveedor: tope 4,
con check (una sola llave no carga con media flota en los dos primeros saltos).
Dirección del aislamiento: el pipeline no drena primaries de negocio (check b2);
al revés sí se permite (negocio cae al colchón free): que `main`/`operaciones`
sigan arriba importa más que la simetría.
Proveedor = prefijo antes de `/`: `opencode-go` y `opencode` cuentan aparte porque
son dominios de cuota distintos (llave de pago vs free: si `opencode-go` se agota,
`opencode/free` sigue; esa es la gracia del reparto). Prueba:
`bash scripts/tests/test-patch-modelos-repartidos.sh` (parseo con python3 stdlib,
sin dependencia json5: strip de `//`, comas colgantes y llaves sin comillas;
discrimina con fixture malo y cruza cada id de la propuesta contra los ids de
`modelos-vivos-2026-09-15.json5`).

Evidencia de que cada id existe (extraída el 2026-09-16; el archivo se fecha 09-15
porque coincide con lo medido ese día en el brief de la corrida): `openclaw models
list --json` falla en este gateway (`active gateway does not support required
capability "published-model-catalog"`), así que los ids se verificaron contra lo
vivo: `~/.openclaw/bin/openclaw gateway call config.get --params '{}' --json` — los
8 primaries y los 40 fallbacks de la propuesta aparecen en las cadenas vivas
(`docs/patches/modelos-vivos-2026-09-15.json5`). Criterio deliberado y estricto:
solo ids ya probados en una cadena viva. `main.models` declara más ids disponibles
(p. ej. `deepseek/deepseek-v4-flash`), pero al no estar en ninguna cadena no entran
en la propuesta; quedan candidatos para después. `openclaw config get
agents.entries.<id>.model` desde la Mac devuelve "unset" aunque esté puesto (quirk
conocido): la lectura fiable es la de arriba.

**No aplicar desde la Mac ni con runs en vuelo.** En la máquina Windows (gateway),
en ventana muerta (cero runs: `config patch` recarga la config y mata los runs):

```bash
# Windows / gateway, ventana muerta:
openclaw config patch --file docs/patches/modelos-primaries-repartidos.json5 --dry-run
openclaw config patch --file docs/patches/modelos-primaries-repartidos.json5
```

**Smoke test obligatorio: aplicar no es verificar.** Que un id aparezca en la config no
prueba que responda (es la regla que nació de los dos incidentes del 2026-09-10).
Ninguno de los primaries nuevos ha sido ganador en una corrida real:
`deepseek/deepseek-flash`, por ejemplo, solo figuraba como último fallback en lo vivo.
Después del patch, una llamada real por agente, leyendo quién contestó:

```bash
# Windows / gateway, tras aplicar, agente por agente:
openclaw agent --agent <id> --session-key smoke:<id> -m "Responde exactamente: PONG" --json \
  | jq '{trace:     (.result.meta.executionTrace // .meta.executionTrace),
         agentMeta: (.result.meta.agentMeta      // .meta.agentMeta)}'
```

Se exige, por agente: `trace.fallbackUsed == false` y
`trace.winnerProvider + "/" + trace.winnerModel` igual al primary de la tabla. Si `trace`
viene en `null`, el respaldo es `agentMeta.provider + "/" + agentMeta.model` (los dos son
campos obligatorios de `EmbeddedAgentMeta`). Tres trampas, todas verificadas contra el
`dist` de OpenClaw 2026.9.4, que hacen fallar este smoke si se escribe de memoria:

- **El resultado de la corrida va bajo `.result`.** El gateway devuelve
  `{runId, status, summary, …, result}` y la CLI imprime ese objeto tal cual (ella misma
  lee `response.result.deliveryStatus`). Por eso el filtro prueba los dos niveles:
  `.result.meta…` primero y `.meta…` como respaldo, para que sirva igual si algún día la
  corrida no va por el gateway.
- **`winnerProvider` es solo el proveedor** (`zai`), no `provider/model`: compararlo
  contra `zai/glm-5.3` nunca da igual. El modelo va aparte, en `winnerModel`.
- **No uses `//` sobre el booleano ni un `grep fallbackUsed`.** En jq, `false // x`
  devuelve `x` (comprobado), así que un respaldo con `//` sobre `fallbackUsed` convierte
  un verde en rojo y al revés: el `//` va sobre el objeto, nunca sobre el booleano. Y
  existe un homónimo, `run.delivery.fallbackUsed`, que es el fallback del **canal de
  entrega**: aparece en la evidencia de crons de este repo
  (`docs/cron-messages/evidence/verif-20h-prueba.20260911T041940Z-26022.json`, que es un
  registro de cron, no la salida de este comando), y un `grep` lo lee y da verde con el
  modelo caído al fallback. El filtro de arriba, corrido contra ese archivo, devuelve
  `null` en los dos campos en vez de mentir.

Un agente que conteste con `trace.fallbackUsed: true` se anota aquí con la razón, que sale
de `trace.attempts` (por qué falló el primary). **La razón decide, no el booleano**: un
token OAuth vencido, un rate limit o un cooldown de cuota son transitorios y se arreglan
en la cuenta, no cambiando la tabla; solo un fallo que persiste tras renovar credencial y
esperar el cooldown justifica cambiar el primary por un id que sí respondió. Hasta que los
8 pasen ese smoke, la tabla es una hipótesis, no una configuración verificada.

Rollback: `modelos-rollback.json5` describe el estado pre-M1 (primarios OpenAI) y ya
NO coincide con lo vivo (hoy primaries `opencode-go/*` + `defaults` + `scout`, que el
rollback no trae). Sirve solo como reversa de emergencia a pre-M1.

El rollback de ESTE patch se captura **en el mismo turno, justo antes de aplicar**, no se
regenera de un archivo fechado: `modelos-vivos-2026-09-15.json5` es una foto del 16 de
septiembre, y revertir con ella pisaría cualquier cambio de ruteo hecho después. Antes
del `config patch`, en la misma sesión:

```bash
# Windows / gateway, inmediatamente antes de aplicar:
openclaw gateway call config.get --params '{}' --json \
  | jq '{agents: {entries: (.parsed.agents.entries | map_values({model})),
                  defaults: {model: .parsed.agents.defaults.model}}}' \
  > docs/patches/rollback-vivo-$(date +%Y%m%dT%H%M%SZ).json
```

Ese archivo, y no el fechado, es el que se aplica si hay que revertir.

## V1 — solo despues de que el lead aplique fase1 (y fase3 si va junto)

Por cada uno de `implementer`, `reviewer`, `adversary`, `verifier` (NUNCA main/operaciones/ingenieria):

```bash
# El smoke es el MISMO de la sección "Primaries repartidos" (mismo comando, mismo jq,
# mismas aserciones), con una diferencia: acá el primary contra el que se compara es el
# de la tabla de fase1 de ESTE README, no el de "Primaries repartidos" (que no está
# aplicada). No hay dos procedimientos de smoke; este bloque solo agrega lo propio de V1.
~/.openclaw/bin/openclaw gateway call sessions.list --params '{"agentId":"<id>","limit":1}'
```

Assert, además del smoke: `sessions.list` devuelve la sesión que acaba de crear la corrida
(ordena por `updatedAt` descendente, así que con `limit:1` es esa), y **en la salida del
smoke** `agentMeta.agentHarnessId` es distinto de `codex`. Ojo: NO se comprueba leyendo
config. `agents.defaults.agentRuntime` y `agents.entries.<id>.agentRuntime` ya no existen
en 2026.9.4 — el esquema los rechaza con `unrecognized_keys` (verificado corriendo el zod
del `dist`) y el doctor los borra ("runtime is now provider/model scoped"). Un
`jq '.parsed.agents.defaults.agentRuntime'` devuelve `null` siempre, así que esa aserción
daría verde aunque las cuatro rutas siguieran clavadas a codex. El harness que de verdad
atendió la corrida viene por corrida, no por config, y ya está en el `jq` de arriba.

# SUA-04, modelos y agentes que se actualizan: diseño y corte en rebanadas

Fecha: 2026-10-16. Estado: diseño propuesto, sin código. Lo escribió el coordinador (Claude). Lo revisa el implementador asignado (Muse Wonder) antes de implementar: no es autor de este documento.

Bases leídas: G `origin/main` `f3041af5` (SUA-03 cerrado, recibo `docs/evidence/sistema-agentes-unificado/SUA-03.md`). R `/Users/dn/dev/wt/r-sua02-c-gate`, HEAD `7b3db54226bf`, el que corre en la Mini. goncloud-hermes `a8722f1` (`/Users/dn/dev/goncloud-hermes`). La Mini se leyó el 2026-10-16 solo con comandos de lectura.

Documentos que manda este diseño y que no cambia:
- El bloque "SUA-04" del [plan](../plans/2026-10-05-sistema-agentes-unificado.md), con su párrafo "Lo que B22 ya dejó para este bloque", las invariantes I10, I11 e I19 y la "Regla de instalación en vivo".
- El [contrato](../../spec/sistema-agentes.v1.md) `sistema-agentes.v1`.
- Los diseños de [SUA-01](2026-10-13-sua-01-frontera-durable-design.md), [SUA-02](2026-10-14-sua-02-controlador-design.md) y [SUA-03](2026-10-14-sua-03-trabajadores-design.md), y sus recibos.

Palabras con un solo sentido en este documento. Las de SUA-01 a SUA-03 siguen igual.

| Palabra | Sentido |
|---|---|
| línea | Un id de modelo sin su número de versión: `glm-{}-flash`, `gpt-{}-sol`. Dos ids de la misma línea son el mismo modelo en dos versiones. La regla es la de `model_lines.py` de goncloud-hermes. |
| estable | Un id con una sola versión limpia y sin `preview`, `exp`, `alpha`, `beta`, `free` ni `latest` (la misma regla de `model_lines.py`). |
| sucesor | El id estable más alto de la misma línea que el catálogo lista y que no es el actual. |
| promoción | Que el sucesor pase a ser el modelo por omisión de su proveedor, después de un canario verde. |
| intento | Una corrida de un encargo con su modelo fijado (SUA-03, `flota.v1`). |
| alta | Un agente que aparece en `openclaw agents list` de la Mini y que G no conocía. |
| retiro | Un agente que G conocía y que ya no aparece en esa lista. |

## 1. Lo que existe hoy

### La ruta por CLI elige su modelo así

- El modelo por omisión es **una constante global**: `DEFAULT_MODEL = "zai-coding-plan/glm-5.3-flash"` (`scripts/agent-work/modelos.py:27-28`). `authorize` lo pasa por el mismo camino que cualquier pedido (`modelos.py:602-637`).
- La política es `docs/evidence/agent-work/proveedores-permitidos.json`: 8 permisos (glm, claude, grok, gpt, muse, kimi, qwen, deepseek) con su forma de cobro y la frase fechada de David, y 3 cierres (opencode-go, opencode, zai). Ningún permiso nombra un modelo concreto, salvo el filtro de qwen.
- El catálogo sale de `opencode models`, con una caché de 6 horas en `<state_root>/catalogo.json` (`modelos.py:276-358`). Un modelo nuevo de un proveedor permitido corre sin editar nada (canario D de B22).
- Un proveedor que rechaza el modelo al lanzar (plan que no lo incluye, límite de uso) sale como `launch-failed`, con el texto de opencode en la frase (`host.py:712-720`, `modelos.py:786-806`; canarios B y gpt de B22).
- No hay sucesión, ni modelo por omisión por proveedor, ni ningún concepto de preview en G.

### Los modelos de los agentes nativos ya se actualizan solos, desde otro repo

- Cada agente de la Mini tiene una cadena `primary` + `fallbacks` en `~/.openclaw/openclaw.json` (`agents.entries.<id>.model`). La cadena sale de una tabla de David en goncloud-hermes (`model-routing.source.json` y `claw-routing.json`).
- `claw_autoupdate.py` de goncloud-hermes corre en la Mini desde launchd todos los días a las 4:50 (`~/Library/LaunchAgents/ai.goncloud.claw-autoupdate.plist`, instalado el 2026-10-15 a las 14:52). Para cada id de una cadena con una versión más nueva en su línea: prepara la ref nueva, la sonda con una llamada real, renombra cada uso, comprueba un turno real de agente y revierte si algo falla. Escribe con `openclaw config patch` dentro de `gateway suspend` (`claw_autoupdate.py:1-20`, `:598-606`).
- La regla de línea y de estable vive en `model_lines.py` de goncloud-hermes (`FAMILIES`, `parse`, `newer_in_line`, `_UNSTABLE`).
- R tiene en su catálogo `status: available|preview|deprecated|disabled` y `replacedBy` (`packages/model-catalog-core/src/model-catalog-types.ts:158,245-248`), pero `openclaw models list --json` no los muestra (`src/commands/models/list.types.ts:3-12`), y no encontré que R promueva a `replacedBy` por su cuenta.
- La política "Muse solo por suscripción" del 2026-10-15 vive en goncloud-hermes (`claw-routing.json`, `api_only_prefixes: ["meta/"]`).

### Los agentes de la Mini y cómo se descubren

- Hay 19 agentes. G los conoce de dos formas: las rutas de los 11 perfiles (`perfiles.v1.json`) y la lista raíz `agents` con 7 agentes `sin-perfil`. Esa lista solo la lee una prueba (`test-agent-work-contexto.py:383`).
- El publicador toma la lista viva de `openclaw agents list --json` (`publicar-contexto.py:169-195`). Un agente nuevo recibe el bloque "No tienes perfil por omisión". No se rechaza. El estado publicado tiene bloques para los 19.
- La ruta "encargo nativo a un agente" (tarea gestionada con `target.kind=agent`) nunca la usó ningún pedido real. En el canario A de SUA-03, `main` mandó el encargo nativo con `sessions_spawn` (fila de `followups.md` "canario A, nativo por sessions_spawn").
- R tiene `openclaw agents add|delete|bind|set-identity`.

### Los siete adaptadores sin host

`coverage.json` lista en `cliAdapters` y en `hostAdapterCoverage` (en `mac-local` y en `windows-remote`) `claude_fable`, `claude_opus`, `kimi_k3`, `kimi_coding`, `codex`, `zcode` y `grok` en `disabled-operator-setup-pending`. Ningún host los atiende desde el 2026-10-13. Los usan como fixtures `test-agent-work-routing.py:79-99` (`len(refused) == 15`), `:173-184`, `:604-608`, `test_agent_work_main_cli_loop_e2e.py:28,159` y los e2e de cutover. `managedRequesterRoutes` mantiene `main -> mac-local/claude_opus` deshabilitada.

### Claude por su CLI

- El host está atado a opencode: `RUN_ADAPTER = "opencode"` (`native_gateway.py:374`), `opencode_argv` y `opencode_env` (`sesion.py:340-386`), los lectores de logs de opencode (`sesion.py:418-575`), `Route.adapter_id: Literal["opencode"]` (`sesion.py:155`), `ADAPTER_ID` en `encargo.py:48` y `EXECUTOR` en `flota.py:20`. `host.py` y `routing.py` sí son agnósticos.
- Claude Code 2.1.301 está en la Mac. Tiene `-p`, `--output-format stream-json`, `--model`, `--permission-mode`, `--permission-prompts none`, `--allowed-tools`, `--add-dir`, `--settings`, `--safe-mode` y `--restricted`. No tiene `--cwd`. `--bare` nunca lee OAuth, así que con `--bare` no correría con la suscripción.
- Nadie midió que `claude -p` corra con el plan Max de David sin llave de API (B22-S5 dice "reportado el 2026-10-12, sin medir"). La Mini sí corre Claude por su CLI para los agentes nativos: `agents.defaults.models.anthropic/*` tiene `agentRuntime.id: claude-cli`.

### Abrir un proveedor a pedido de David (B22-S6)

`encargo.py permitir` escribe la política del checkout donde corre, exige `--ref P#### --cita` cotejada contra `~/.claude-mem/claude-mem.db`, se niega en el checkout del host y nunca reabre un cierre (`encargo.py:540-615`). La skill `encargo-cli` le dice a `main` que no lo haga y que se lo pida a Claude en la Mac. El código no distingue al llamador.

### Fuentes por caducidad

Las 18 fuentes de los 11 perfiles vencen el 2027-01-14 (`perfiles.v1.json`, `sources[].validUntil`). `contexto.admite` rechaza un perfil con una fuente vencida (`contexto.py:224-261`). Nada renueva una fuente ni avisa antes de que venza.

## 2. Lo que falta, punto por punto contra el bloque

| Punto del plan | Hoy | Falta |
|---|---|---|
| 1. Fuentes oficiales, acceso por cuenta, sucesión, estabilidad, capacidades, causa de inelegibilidad | CLI: catálogo de `opencode models` y política. Nativo: `model_lines.py` con models.dev y la lista de opencode-go | En la ruta por CLI: la línea, el estable, el sucesor y la causa de inelegibilidad por id (no estable, sin sesión, fuera de permiso, rechazado por el plan) |
| 2. Probar un sucesor y promoverlo dentro de la autorización; el intento activo conserva su modelo; un relevo hereda raíz, gasto y restricciones | Nativo: `claw_autoupdate` lo hace. CLI: nada. El intento ya conserva su `PermittedModel` (`sesion.py:151`) | CLI: el modelo por omisión por proveedor, la promoción con canario y su estado. Que un relevo de `main` herede la raíz se mide, no se construye: lo da R (SUA-02) |
| 3. Altas y retiros, perfil y conexión ida/vuelta, nuevos destinos por manifiesto; los siete adaptadores | El publicador acepta un agente nuevo como "sin perfil". Nadie mide la ida y vuelta | El descubrimiento con su estado visible, la sonda de ida y vuelta por tarea gestionada, el retiro, y sacar los siete adaptadores |
| 4. Refrescar fuentes y skills por caducidad; acotar mantenimiento, backoff y coste; generación con CAS, atestación y read-back | El publicador ya tiene CAS, respaldo y reversa (SUA-03) | El aviso antes del vencimiento y el refresco con su generación nueva |
| B22-S5 Claude por su CLI | Nada | Medir primero (fase 0). La ruta va en una rebanada aparte |
| B22-S6 `main` abre un proveedor | Nada | Que `main` pida el permiso y que lo autorice David, sin que `main` sea quien lo autoriza |

## 3. Quién es dueño de cada cosa

El plan dice "Dueño: política de flota local; G distribuye manifiestos". Hoy hay dos políticas de flota, una por lado, y SUA-04 no las junta:

| Qué | Dueño | Por qué |
|---|---|---|
| Cadenas de modelos de los agentes nativos y su sucesión | goncloud-hermes (`model-routing.source.json`, `claw-routing.json`, `claw_autoupdate.py`) | Ya existe, corre todos los días, prueba con un turno real y revierte. Duplicarlo en G haría dos escritores de `openclaw.json` |
| Modelo por omisión y sucesión de la ruta por CLI | G (`proveedores-permitidos.json`, `modelos.py`, `encargo.py`) | El plan lo pide así ("SUA-04 parte de ahí y no crea otra lista para esa ruta") |
| La regla de línea y de estable | Una sola regla, copiada en G con una prueba de igualdad contra la de goncloud-hermes | Dos reglas que divergen promoverían cosas distintas con el mismo id |
| Agentes, perfiles, bloques y paquete | G (`perfiles.v1.json`, publicador) | Es lo de SUA-03 |

La consecuencia para I10: en nativo, SUA-04 **mide** `claw_autoupdate` y lo registra como el mecanismo de la ruta nativa (con `--dry-run` y con su primera corrida real). En la ruta por CLI, SUA-04 **construye** la sucesión.

## 4. El diseño elegido

### 4.1 La regla de línea en G

`scripts/agent-work/lineas.py`, biblioteca estándar, con `parse(id) -> (línea, versión) | None`, `estable(id)` y `sucesor(actual, ids) -> id | None`. Es la regla de `model_lines.py` de goncloud-hermes, sin la parte de red. La prueba `test-agent-work-lineas.py` corre los mismos casos que las pruebas de `model_lines.py` (copiados como fixture literal) y uno más por familia que usa G. Si el archivo de goncloud-hermes existe en la máquina, la prueba compara también las dos funciones sobre esos casos. Si no existe, se salta con su motivo.

### 4.2 El modelo por omisión por proveedor

Cada permiso de `proveedores-permitidos.json` puede llevar `default: {"line": "<proveedor>/<línea>", "since": "<id>"}`. La raíz lleva `defaultGrant: "<nombre del permiso>"`: el proveedor cuyo modelo por omisión usa un encargo sin modelo. Hoy sería `{"defaultGrant": "glm", ...}` y el permiso `glm` con `default: {"line": "zai-coding-plan/glm-{}-flash", "since": "zai-coding-plan/glm-5.3-flash"}`.

El modelo por omisión **efectivo** de un proveedor se resuelve en cada `preparar`: el id promovido de su línea (4.3) o, si no hay ninguno, `since`. `DEFAULT_MODEL` desaparece, y `authorize(DefaultModel)` usa el de `defaultGrant`. Ningún id nuevo se escribe a mano: la línea no cambia con las versiones.

`encargo.py proveedores` muestra, por permiso, la línea, el id efectivo y, si lo hay, el sucesor pendiente y su estado.

### 4.3 La sucesión en la ruta por CLI

El estado vive fuera de G, en `<state_root>/sucesion.json` (`agent-work.succession.v1`): por línea, `{actual, candidato, estado, intentos, ultimo, evidencia}`. El estado es `pendiente | probando | promovido | rechazado` con su causa. Escritura atómica con candado, como la caché del catálogo.

`encargo.py sucesion [--aplicar]` hace, por cada permiso con `default`:

1. Lee el catálogo (`CatalogStore.current`).
2. Calcula el sucesor de `actual` en su línea entre los ids que el permiso admite (`ModelFilter`). Un id no estable no es sucesor. Un proveedor sin sesión no tiene sucesor y la causa queda escrita.
3. Sin `--aplicar`, imprime lo que haría y sale.
4. Con `--aplicar` y un sucesor nuevo: lanza **un canario** con ese modelo exacto, el caso `ingenieria` del banco (la tarea de `saluda.py` con su conducta, en su propio Gateway y su grupo; M-16). Si sale verde, `estado: promovido`, `actual` pasa al sucesor y la evidencia guarda el log del caso. Si sale rojo (incluido un `launch-failed` porque el plan del proveedor no incluye ese modelo), `estado: rechazado` con la causa, y no se vuelve a probar ese id hasta que cambie el catálogo o pasen 7 días. Un fallo de infraestructura del banco (slot ocupado, opencode que no contesta) no rechaza: deja `pendiente`.
5. Como mucho una promoción por corrida, y nunca mientras el host tenga un encargo en vuelo (el mismo chequeo del paso 1 de la ventana de SUA-03).

El modelo por omisión cambia solo para los encargos nuevos. Un intento en vuelo conserva su `PermittedModel` y su `flota.v1` lo registra. Un relevo de `main` (una corrección con `continue`) es un hijo de la misma raíz en R y lleva el modelo que pida su `preparar` (SUA-02). Esto se mide, no se construye.

Quién lo corre: un launchd en la Mac (`ai.goncloud.agent-work-sucesion.plist`), diario, que llama `encargo.py sucesion --aplicar` desde el checkout del host. Es un proceso de una pasada, no un daemon. El plist y su instalación quedan en `scripts/mac/` con su prueba, como el resto de lo que se instala en la Mac.

Una promoción avisa a David una vez: el host ya tiene `progress-events.py`, y el aviso usa la misma vía que los avisos del host. El texto dice qué id reemplazó a cuál, con su evidencia.

### 4.4 La sucesión nativa

No se construye nada. SUA-04:
- Registra en `coverage.json` (una entrada `modelSuccession` por ruta) que la ruta por CLI la lleva `encargo.py sucesion` y las nativas `claw_autoupdate` de goncloud-hermes, con su evidencia.
- Mide `claw_autoupdate.py --dry-run` en la Mini (M-19) y su primera corrida real del log de launchd (M-20). Ninguna de las dos la corre G.
- Abre en `followups.md` la fila de lo que `claw_autoupdate` no cubre de I10, si M-19 o M-20 lo muestran (por ejemplo, un id `preview` en una cadena, o un proveedor sin acceso).

### 4.5 Altas y retiros de agentes

`scripts/agent-work/agentes.py descubrir` (de solo lectura, por ssh como el publicador) compara `openclaw agents list --json` de la Mini con lo que G conoce: las rutas de los perfiles y la lista raíz `agents` de `perfiles.v1.json`. Contesta una línea por agente con su estado:

| Estado | Cuándo |
|---|---|
| `con-perfil` | Lo nombra la ruta de un perfil y está en la Mini |
| `sin-perfil` | Está en la lista raíz `agents` y en la Mini |
| `alta-sin-registrar` | Está en la Mini y G no lo conoce |
| `retirado` | G lo conoce y la Mini ya no lo tiene |
| `perfil-incompleto` | Un perfil nombra en su ruta un agente que la Mini no tiene |

`encargo.py perfiles` (que ya lista perfiles y agentes sin perfil) suma `alta-sin-registrar`, `retirado` y `perfil-incompleto`, con su frase, para que `main` y David lo vean. Un `alta-sin-registrar` no se agrega sola a `perfiles.v1.json`: entra por un PR que la pone en `agents` con `sin-perfil` (el paquete no cambia por eso: `perfiles.v1.json` no entra al digest de la generación, como se comprobó en SUA-03).

**La ida y vuelta.** `agentes.py sondear <id>` manda a ese agente una tarea gestionada (`managed_tasks_submit` con `target.kind=agent`, `resultContract: ready.v1`), como solicitante `main`, con el brief que arma `brief.py --perfil <su perfil>` (o sin perfil si no tiene). La tarea pide contestar un marcador literal y nada más. La sonda pasa si la tarea llega a `result-recorded` con el marcador, sin entregas hacia David y con `memory/` igual antes y después. Es la primera vez que se usa la ruta "encargo nativo a un agente", y su resultado va a `coverage.json` como evidencia de esa ruta (hoy "sin medir").

La sonda la corre el coordinador desde la Mac: una vez para cada alta, y una vez como M-18 sobre un agente existente (`ingenieria`) para medir la ruta.

**El retiro.** Un agente `retirado` deja de recibir bloque en la publicación siguiente. El publicador ya rechaza una publicación que no trae un bloque por agente vivo, y no exige bloque para un agente que no está. Lo que falta es que el estado (`.sua-contexto.json`) olvide el bloque del agente que ya no está, con su respaldo, como hace con una skill que sale del manifiesto (C8 de SUA-03). Un perfil cuya ruta queda sin agente se ve como `perfil-incompleto`, y `contexto.admite` lo rechaza en esa ruta con `perfil-no-atiende-ruta`.

### 4.6 Los siete adaptadores

- Salen de `cliAdapters`, de `hostAdapterCoverage` (en los dos hosts) y de las rutas `managedRequesterRoutes` y `migration` que los nombran: `claude_fable`, `kimi_k3`, `kimi_coding`, `codex`, `zcode` y `grok`. Cada uno con su fila en `migration` ("retirado: ningún host lo implementa desde el 2026-10-13").
- `claude_opus` también sale. La ruta de Claude por su CLI, si llega a existir, entra con un id nuevo (`claude`) y una forma `run-per-task`, como opencode. Dejar `claude_opus` como esqueleto confunde: su nombre fija un modelo y la ruta nueva elegiría el modelo como opencode (cabecera del brief).
- Las pruebas que los usaban como fixture pasan a usar ids de juguete que la prueba declara (`fixture-cli-a`, `fixture-cli-b`), no ids que parezcan reales. `len(refused) == 15` pasa a calcularse de lo que el archivo trae.

### 4.7 Claude por su CLI: primero se mide

La rebanada de esta ruta no se diseña aquí entera, porque depende de cuatro mediciones que nadie hizo (M-21, fase 0 de Claude, en esta Mac y con la suscripción de David):

1. Si `claude -p --output-format stream-json` corre con el plan Max sin llave de API.
2. Qué carpeta de trabajo usa: el cwd del proceso, `PWD` u otra.
3. Qué hace `--permission-prompts none` con una herramienta que pediría permiso: si la niega y sigue, si sale y con qué código.
4. Qué eventos deja para leer el modelo usado, los permisos y las herramientas (el equivalente de `message=stream` de opencode).

Con M-21 verde, una rebanada aparte (G7) generaliza el host: un `Adaptador` con `argv`, `env`, `leer_eventos` y su `id`, `opencode` como primera implementación sin cambiar su comportamiento, y `claude` como segunda. Si M-21 sale roja en el punto 1, la ruta de Claude por su CLI queda fuera de SUA-04 con su fila, y el permiso `claude` sigue "sin sesión" con su frase de hoy.

### 4.8 `main` pide abrir un proveedor (B22-S6)

`main` no autoriza: pide. El flujo:

1. David le dice a `main` por Telegram "abre el proveedor X".
2. `main` corre `encargo.py solicitar <nombre> --proveedor <id> --cobro <forma>`. El comando no toca la política: escribe una solicitud en `<state_root>/solicitudes/<id>.json` con lo que pidió y la marca de tiempo. Se niega si el nombre o el id está en `closed`: un cierre no se reabre por esta vía.
3. `main` le contesta a David con la frase literal que tiene que mandarle para confirmar: "confirmo abrir X (<id>, <cobro>)".
4. Cuando David manda esa frase, el coordinador (Claude en la Mac) corre `encargo.py permitir ... --ref <id del mensaje de Telegram> --cita "<frase>"`. La cita se coteja contra el transcript de la sesión de `main` en la Mini, de solo lectura. El cambio sale como PR, como hoy.

Lo nuevo en código es `solicitar`, y que `--ref` acepte también un mensaje de Telegram de la sesión de `main` (`tg:<chatId>:<messageId>`), cotejado por ssh de solo lectura. `main` no corre `permitir`. La skill `encargo-cli` cambia su sección "Proveedores" para decir el flujo.

### 4.9 Fuentes por caducidad

`encargo.py fuentes` lista por perfil cada fuente con `validUntil` y los días que le quedan. Lo corre el mismo launchd de 4.3. Una fuente con menos de 30 días avisa a David una vez por semana, con la lista. Renovar es un PR: se relee la fuente en su revisión nueva, se actualizan `revision` y `validUntil`, y si cambió su contenido se vuelven a correr las sondas de competencia de los perfiles que la usan (banco para la ruta por CLI, sondas nativas para el resto). No hay renovación automática: una fuente nueva puede cambiar lo que el perfil sabe, y eso pide su competencia otra vez.

### 4.10 Generaciones, atestación, reversa e I19

El publicador de SUA-03 ya hace CAS, respaldo, reversa y la foto de perfiles. Lo que I19 pide y falta probar con su nombre:

- **"Apply sin attest"**: una generación aplicada en la Mini y no certificada en `coverage.json` no abre la ruta por CLI (`generacion-no-certificada`, SUA-03). En nativo, el bloque de una generación aplicada sin certificar se publica igual, porque la ruta nativa no se certifica (conflicto 4 de SUA-03). Se prueba que la ruta por CLI la rechaza y se deja escrito para la nativa.
- **"Crash entre aplicar y verificar"**: el publicador relee cada digest después de escribir (`releido != sha256hex(contenido)`). Falta una prueba que mate el proceso entre la escritura del bloque y la del estado y compruebe que la siguiente `--aplicar` termina sin conflicto, y que la siguiente `--revertir` deja la generación anterior.
- **"Revocación permanece tras reversa"**: un proveedor cerrado sigue cerrado después de revertir una generación del paquete (la política está fuera del paquete), y una promoción revertida (4.3) no reabre un id `rechazado`. Las dos se prueban.
- **"Nuevo destino"**: un alta (4.5) no cambia la autorización de los agentes que ya estaban: su bloque y su competencia quedan iguales.

## 5. Cómo se prueba

| Invariante / frase de "Verificar" | Prueba | Ensayo vivo |
|---|---|---|
| I10. Sucesor estable funciona sin editar ids a mano | `test-agent-work-modelos.py`: un catálogo de fixture con `glm-5.3-flash` y `glm-5.4-flash` da sucesor `glm-5.4-flash`; un `preparar` sin modelo usa el promovido sin tocar `proveedores-permitidos.json` | M-22: una promoción real, si el catálogo trae un sucesor durante el bloque; si no, una línea de fixture en el banco |
| I10. Preview, proveedor sin acceso y canario fallido no se promueven | `glm-5.4-flash-preview` no es sucesor; un proveedor sin sesión no tiene sucesor; un canario rojo deja `rechazado` | Canario B de B22 como fixture (`launch-failed` por plan) |
| I10. El intento activo conserva su modelo | Un encargo en vuelo con el modelo viejo cierra con el viejo en `flota.v1` después de una promoción | — |
| I11. Alta posterior recibe y devuelve tarea | `agentes.py sondear` con un R de prueba (ruta_viva) | M-18 sobre `ingenieria` y la sonda de cada alta real |
| I11. Alta incompleta visible | `agentes.py descubrir` y `encargo.py perfiles` con una lista de agentes de fixture | — |
| I11. Competencia, caducidad y memoria preservadas | Un alta no cambia los bloques ni la competencia de los demás; `memory/` igual en la sonda | La sonda mide `memory/` |
| I19. Crash entre aplicar y verificar no activa bytes no acreditados | Matar el publicador entre bloque y estado; la siguiente `--aplicar` y la siguiente `--revertir` | — |
| I19. Revocación permanece tras reversa | Cierre + reversa de generación; promoción revertida + id rechazado | — |
| Siete adaptadores fuera | `test-agent-work-routing.py` sin esos ids; el contrato | — |
| B22-S6 | `solicitar` se niega a un cerrado; `permitir --ref tg:...` coteja la frase contra un transcript de fixture | Un pedido real de David a `main`, con su aviso |

Las mediciones del coordinador:

| Id | Qué | Dónde | Avisos |
|---|---|---|---|
| M-18 | Sonda de ida y vuelta por tarea gestionada a `ingenieria` | Mini, desde la Mac | 0: el brief lo prohíbe, y se lee `conversation_deliveries` |
| M-19 | `claw_autoupdate.py --dry-run` en la Mini | Mini, solo lectura | 0 |
| M-20 | La primera corrida real de `claw_autoupdate` (log de launchd) | Mini, solo lectura | Los que mande el propio autoupdate |
| M-21 | Fase 0 de Claude por su CLI (los cuatro puntos de 4.7) | Mac, suscripción de David | 0 |
| M-22 | Una promoción real en la ruta por CLI, o el banco con una línea de fixture | Mac | 1, el aviso de la promoción |

## 6. El corte en rebanadas

| Rebanada | Qué | Pruebas | Toca en vivo |
|---|---|---|---|
| G1 | Los siete adaptadores fuera de `coverage.json` y de las pruebas; ids de fixture | routing, contrato, cutover e2e | No |
| G2 | `lineas.py`, `default` por permiso, `defaultGrant`, adiós `DEFAULT_MODEL`, `proveedores` con línea y efectivo | modelos, encargo, lineas | Sí: el host al día (ventana) |
| G3 | `encargo.py sucesion`, `sucesion.json`, el canario con el caso del banco, el aviso, el launchd en `scripts/mac/` | modelos, encargo, banco sin la variable, instalar-mac | Sí: instalar el launchd |
| G4 | `agentes.py descubrir` y `sondear`, `perfiles` con los estados nuevos, el retiro en el publicador | contexto, publicar, encargo, routing | Sí: M-18 |
| G5 | `solicitar` y `--ref tg:` (B22-S6), la skill `encargo-cli` | encargo, routing | Sí: publicar la skill de `main` |
| G6 | `fuentes` y su aviso; las pruebas de I19 (crash y revocación) | contexto, publicar, modelos | No |
| G7 | Claude por su CLI, si M-21 sale verde: el `Adaptador` del host y `claude` | sesión, host, banco | Sí: host al día |
| G8 | Cierre: `coverage.json` (`modelSuccession`, la evidencia de la ruta nativa a un agente), filas y recibo `SUA-04.md` | routing, contrato | No |

Orden: G1, luego G2 a G6 en ese orden (G3 necesita G2; G4 a G6 son independientes entre sí). M-21 se mide en paralelo con G2. G7 solo si M-21 sale verde. Al final G8. Las ventanas en vivo se juntan donde se pueda, con el slot libre y sin encargo en vuelo, como en SUA-03.

## 7. Lo que no entra en SUA-04

| Qué | Por qué | Bloque |
|---|---|---|
| Juntar las dos políticas de flota (Hermes y G) en una | Son dos dueños hoy, y la nativa ya funciona | Fila para SUA-09O |
| Rechazo por encargo en las rutas nativas | Pide R | SUA-09O |
| Una sucesión nativa nueva en G | La hace `claw_autoupdate` | — |
| Que `main` encargue nativo por tarea gestionada en vez de `sessions_spawn` | Es conducta de `main` y de su skill; SUA-04 mide que la ruta funciona (M-18) | Fila, si M-18 sale verde |
| Kimi, codex, zcode y grok por su propio CLI | No hay ningún caso que lo pida: sus suscripciones entran por opencode | Fila, cuando un estreno lo muestre |

## 8. Riesgos y decisiones pendientes

### Riesgos

1. **El canario de la sucesión gasta suscripción.** Uno por id nuevo, como mucho uno al día, y nunca con un encargo en vuelo.
2. **La regla de línea diverge entre los dos repos.** La prueba de igualdad la detecta en G cuando goncloud-hermes está en la máquina, y se salta cuando no está. Se sabe que no protege en CI.
3. **Un `alta-sin-registrar` sin perfil recibe trabajo nativo.** Hoy ya pasa con el bloque "sin perfil". SUA-04 lo hace visible, pero no lo bloquea.
4. **`--ref tg:` coteja contra un transcript.** Quien controla la sesión de `main` podría escribir esa frase en ella. Lo cubre que el cotejo exige que la frase venga del rol `user` del canal de Telegram de David, y que el cambio sigue saliendo como PR.

### Decisiones pendientes de David

Ninguna nueva. Los avisos (promoción, fuentes por vencer, la sonda de B22-S6) y el gasto de suscripción del canario de la sucesión y de M-21 caben en la autorización del 2026-10-13 ("todo SUA de corrido"). Si M-21 muestra que `claude -p` exige una llave de API, no se pide ninguna: la ruta queda fuera, como dice 4.7.

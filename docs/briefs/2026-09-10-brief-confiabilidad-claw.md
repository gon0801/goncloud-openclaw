# Brief — llevar a Claw de "vivo" a "confiable" para ingenieria

Fecha: 2026-09-10 ~11:00Z. Lead: Claude (planea, escribe briefs, revisa — **no aplica**).
Meta: que la flota de OpenClaw haga tareas de ingenieria con la fiabilidad de un bot de Grok.
Estado de partida: hoy se arreglo que estaba **muerto**. Falta lo que lo hace **confiable**.

## 0. Lo que ya quedo (verificado, no asumido)

- **Modelos**: los 7 agentes con 5 proveedores en cadena, cada uno probado con llamada real:
  zai/glm-5.3 (`VIVO`), deepseek-v4-flash (`DS-OK`), kimi/k3 (`REV-KIMI-OK`), xai/grok-4.6 (`GROK-OK`), anthropic (`PONG`).
  `reviewer` y `adversary` pasaron de **0 corridas completadas** a responder.
- **Runtime**: los 5 agentes de pipeline salieron del harness `codex` → recuperan `message`, `progress_card`, `sessions_send`.
- **Anthropic** conectado por setup-token, nativo, sin expiracion.
- **main** ya tiene la regla de reportar fallos de subagentes (bloque `## Subagentes`, verificado en el archivo).
- **Mergeado a `main`**: PR #1 y #3 (Muse: crons packing) y PR #2 (Cursor: workspaces, summa-gate, nodo Mac).

## 1. Guardrails (para quien implemente)

1. **Nada se aplica sin dry-run previo** donde exista (`config patch --dry-run`). El dia de hoy dejo dos incidentes por saltarse esto: registrar `models.providers` sin `baseUrl` mato a deepseek y a kimi, dos veces.
2. **La URL/endpoint de un proveedor se saca de una llamada real en los logs** (`grep 'model-fetch.*provider=X.*url='`), NUNCA de memoria ni del nombre del producto. Asi se encontro que kimi es `https://api.kimi.com/coding/v1` con api `anthropic-messages` — cosa que nadie habria adivinado.
3. **Verificar con una llamada real, no con la config.** Que un modelo aparezca en `models list` no prueba que responda; el smoke test debe mostrar `fallbackUsed: false` y el `winnerProvider` esperado.
4. **Comandos de auth y de config se corren EN la maquina Windows** (son locales al gateway; no hay flag remoto ni RPC).
5. **No reiniciar el gateway con corridas activas** (produce `admitted run authority is no longer active`).
6. **Prohibido tocar los crons de packing** (`packing-*`, agente `operaciones`): son el negocio y ya estan estabilizados.

## 2. Trabajo pendiente, en orden de impacto

### P1 — `sessions_search` roto (memoria de la flota)  · owner sugerido: Grok (infra/ops)
Sintoma: **todos** los agentes fallan con `{"status":"error","tool":"sessions_search","error":"unable to open database file"}`. Observado en `main`, `verifier` y dos subagentes. `openclaw doctor` **no lo detecta**.
Por que importa: un agente de ingenieria que no puede consultar que se decidio o se intento antes repite errores. Es la diferencia entre un asistente y un compañero de trabajo.
- Localizar que base abre esa tool y por que falla (permisos, ruta, archivo inexistente, antivirus).
- Considerar que `memory.search` esta en provider `local` con `modelPath` de llama, y que doctor en la Mac reportaba provider `openai` sin api key — verificar cual aplica en el gateway.
- **Aceptacion**: `sessions_search` devuelve resultados en 3 agentes distintos, con la salida pegada como evidencia.

### P2 — Que el trabajo de Cursor llegue a los agentes  · owner: quien opere Windows
Los 4 workspaces (implementer/reviewer/adversary/verifier) ya tienen IDENTITY/USER llenos y AGENTS.md traducidos a OpenClaw **en `main`**, pero Windows los baja en su ciclo de sync (~2h). Hasta entonces los agentes siguen leyendo los viejos.
- Confirmar que el sync corrio (`git log` en `C:\Users\ehven\.openclaw` con commit de merge), o forzarlo.
- **Aceptacion**: un dispatch a `reviewer` demuestra que cargo el AGENTS.md nuevo (p.ej. responde citando una regla que solo existe en la version nueva).

### P3 — Sobrecarga de prompt: 138k tokens por turno  · owner sugerido: GLM o Cursor
Medido: un ping trivial a `verifier` consumio **138,569 tokens de prompt**. Segunda llamada en la misma sesion: `cacheRead 41,827` + **`cacheWrite 96,774`** — o sea ~97k se reescriben al cache en cada turno pese a que la conversacion solo crecio ~70 tokens. Costo: $0.17 y $0.13 en el modelo mas barato de Anthropic.
- Determinar **que compone** esos 138k (esquemas de tools, catalogo de skills, AGENTS.md, memoria, historial).
- Determinar **que invalida el cache**: algo volatil a media prompt (hora, listado de sesiones, inyeccion de memoria) tira todo lo que viene despues.
- Medir si el patron se repite en zai/deepseek/kimi o es propio de Anthropic. Dato de contexto: una llamada equivalente a `main` con deepseek-flash costo $0.0003, asi que el impacto en dinero depende brutalmente del proveedor.
- **Aceptacion**: informe con la composicion de los 138k, la causa de la invalidacion, y una propuesta cuantificada ("quitando X, el prompt baja a Y"). **No aplicar cambios**: es analisis.

### P4 — `sessions_send announce flow failed`  · owner sugerido: Grok
3 ocurrencias en los logs. Se atribuyo al `defaultAccount` de Telegram y **eso quedo descartado**: la cuenta `default` es el bot de Claw (aparece en su sessionKey `agent:main:telegram:default:...`), esta configurada a la vieja usanza y funciona. La advertencia de doctor es cosmetica y **no se debe "arreglar"**: repuntarla moveria el unico chat que usa David.
- Encontrar la causa real. Afecta los reportes entre agentes (operaciones → main), no los mensajes a David.
- **Aceptacion**: causa identificada; si no se puede arreglar, declararlo y documentar el workaround.

### P5 — Token de xAI vence cada 6 h  · owner sugerido: Grok
`grok-4.6` es el primario de `ingenieria`. Su OAuth dura 6 h y **no se renueva solo** (observado: conto 58m → 29m → 16m hasta morir). Renovarlo exige `openclaw models auth login --provider xai --agent main` **en Windows**.
- Evaluar si hay refresh automatico posible, o si conviene degradar grok a eslabon profundo y dejar de primario un proveedor sin vencimiento.
- **Aceptacion**: o queda renovandose solo, o queda escrito que es tarea manual y cada cuanto.

### P6 — Limpieza que reporto doctor  · owner: quien opere Windows
- 6 sesiones ancladas a routing OpenAI/Codex viejo (`agent:main:autonomy-smoke`, `cua-smoke`, `dashboard:55c4...`, `agent:ingenieria:subagent:fa2b...`, `summa-test`).
- 1 directorio de agente huerfano: `openclaw` (sin entrada en agents.list).
- Sistema de memoria ausente en los workspaces de implementer/reviewer/adversary/verifier (doctor da los dos commits a aplicar).
- Reinicio del gateway pendiente para tomar el catalogo nuevo (44 proveedores, 1015 modelos). **Fuera de la ventana de los crons de packing.**

## 3. La prueba que responde "¿ya es confiable?"

Nada de lo anterior contesta la pregunta. Todo lo verificado hoy fue `responde PONG`: prueba la plomeria, no el trabajo. **Hace falta una tarea de ingenieria real, chica y con criterio de exito objetivo, corrida por el pipeline completo y observada.**

Diseño propuesto (el lead la redacta en detalle cuando David apruebe el repo):
- **Tarea**: un bug real y acotado en un repo NO critico, que se pueda verificar con una prueba automatizada. Criterio de exito objetivo: la prueba falla antes del fix y pasa despues.
- **Ruta**: `implementer` implementa → `verifier` verifica → `reviewer` revisa → `adversary` ataca → Claw reporta a David.
- **Lo que se mide** (esto es el verdadero resultado del experimento, mas que si el bug quedo arreglado):
  1. ¿Invento rutas o flags de CLI? (hoy paso 6 veces en un dia).
  2. ¿El `verifier` caza una prueba que **no discrimina** (que pasa igual sin el fix)? Es la debilidad comun documentada de todos los implementadores.
  3. ¿Claw reporta honestamente cuando un subagente falla, o lo sustituye en silencio? (la regla ya esta escrita; falta ver si la cumple).
  4. ¿Cuanto costo la tarea completa, en dinero y en tiempo?
- **Aceptacion**: informe con esas 4 respuestas y evidencia. Ese informe, no la config, es lo que dice si Claw es confiable.

## 4. Lo que NO se toca

Crons de packing, `defaultAccount` de Telegram, y la config de modelos que quedo hoy (5 proveedores, los 5 verificados). Cualquier cambio ahi vuelve a abrir algo que ya cerro.

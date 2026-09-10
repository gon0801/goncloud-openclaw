# Cursor — FASE B: cadenas de modelos definitivas

Fecha: 2026-09-10 ~07:30Z. Decidido por David. Lead: Claude.

> **Esto REEMPLAZA los puntos 1 y 2 de la seccion M1 del brief `2026-09-10-cursor-agentes-openclaw.md`, sin importar que version de ese archivo hayas leido.** El brief se edito mientras vos ya estabas trabajando (mea culpa del lead): puede que tengas una version con cadenas de 3 eslabones y sin Anthropic. La tabla de aca abajo es la autoritativa. Todo lo demas de ese brief (guardrails, W1, W2, S1, N1, V1, entrega) sigue vigente igual.

## 1. Cadenas finales

| agente | 1o | 2o | 3o | 4o | 5o (pendiente auth) |
|---|---|---|---|---|---|
| `main` | zai/glm-5.3 | deepseek/deepseek-v4-pro | kimi/k3 | xai/grok-4.6 | anthropic/claude-sonnet-5 |
| `operaciones` | zai/glm-5.3 *(sin cambio)* | deepseek/deepseek-v4-flash | kimi/k3 | xai/grok-4.6 | anthropic/claude-sonnet-5 |
| `ingenieria` | **xai/grok-4.6** | zai/glm-5.3 | deepseek/deepseek-v4-pro | kimi/k3 | anthropic/claude-sonnet-5 |
| `implementer` | zai/glm-5.3 | deepseek/deepseek-v4-pro | kimi/k3 | xai/grok-4.6 | anthropic/claude-sonnet-5 |
| `reviewer` | kimi/k3 | deepseek/deepseek-v4-pro | zai/glm-5.3 | xai/grok-4.6 | anthropic/claude-opus-5 |
| `adversary` | deepseek/deepseek-v4-pro | kimi/k3 | zai/glm-5.3 | xai/grok-4.6 | anthropic/claude-opus-5 |
| `verifier` | deepseek/deepseek-v4-pro | zai/glm-5.3 | kimi/k3 | xai/grok-4.6 | anthropic/claude-sonnet-5 |

> **CORRECCION IMPORTANTE (07:55Z) — donde se aplican los patches.** El brief principal dice `openclaw config patch --file <ruta>`. Desde la **Mac eso escribe en la config de la Mac**, NO en la del gateway: verificado, `openclaw config validate` en la Mac responde `Config valid: ~/.openclaw/openclaw.json` (ruta local), y `config patch --help` no tiene ningun flag para apuntar a un gateway remoto. Es el mismo patron que `models auth login`. **Los patches se aplican EN la maquina Windows**, donde el CLI si es local a la config del gateway. (Existe tambien el RPC `gateway call config.patch --params '{"raw": ...}'`, pero su forma exacta no esta verificada y no tiene `--dry-run`: no lo uses a ciegas sobre la config viva.) Los archivos `.json5` que preparaste siguen siendo validos tal cual; lo unico que cambia es **desde donde** se corren.

Reparto de archivos igual que antes:
- `modelos-fase1.json5` → `implementer`, `reviewer`, `adversary`, `verifier`, `ingenieria` (aplicable ya).
- `modelos-fase2-main-operaciones.json5` → `main` y `operaciones` (solo DESPUES del estreno; `main` corre el cron `report-7h-estreno` y `operaciones` los de packing).
- `modelos-fase3-anthropic.json5` → agrega el 5o eslabon. **YA DESBLOQUEADO (07:50Z):** David corrio `claude setup-token` y el token quedo instalado en el gateway. `models.authStatus` ya lista `anthropic` con perfil `anthropic:manual` (type `token`, `inherited`, **sin expiracion**). Verificado con llamada real: `openclaw agent --agent verifier --model anthropic/claude-haiku-4-5` respondio ok, provider `anthropic`, `agentHarnessId: openclaw` → runtime **nativo con tools completas**, no CLI backend. El patch es aplicable junto con fase1.
- `modelos-rollback.json5` → sin cambios respecto al brief.

## 2. Que cambio respecto del brief y por que

1. **`ingenieria` vuelve a Grok de primario.** Es el agente de infra/ops, y la evidencia propia de David (goncloud-Orbit, ago 2026) pone a Grok como el mejor ahi por proceso: backups, disciplina aditiva, incidentes declarados. El lead lo habia bajado al 3er lugar para proteger la cuota semanal de xAI — proteccion innecesaria: con 4 eslabones abajo, si Grok se agota la cadena lo atrapa sola. Poner un proveedor de cuota corta primero es seguro justamente cuando hay respaldo profundo.
2. **`xai/grok-4.6` entra como 4o eslabon en los otros seis.** Un eslabon profundo no consume nada hasta que se llega a el.
3. **5o eslabon Anthropic** via setup-token de la suscripcion de David: da refs `anthropic/*` **nativos con tools completas** (no es el CLI backend text-only).

## 3. Estado de cuotas medido hoy 07:23Z (leelo antes de sacar conclusiones de una corrida)

| proveedor | medicion | implicacion |
|---|---|---|
| xai | OAuth renovado 07:41Z (David, en la Windows): **dura solo 6 h** — vence 09-10 13:41Z. Ventana semanal **91 %**, reset 09-12 23:57Z, prepago $3.22. **PENDIENTE DE MEDIR:** si el token se auto-renueva al usarse. Evidencia previa: el anterior conto 58m→29m→16m y murio sin renovarse, pero nadie llamaba a xAI en ese rato (ventana plana), asi que un refresh perezoso no se habria disparado. Si a las 13:41Z no se renovo solo, Grok de primario en `ingenieria` implica login manual cada 6 h = insostenible, y hay que devolverlo a eslabon profundo. | El % esta **estable** (3 lecturas a 20 s: 90/90/90): xAI solo consume cuando `main` lanza subagentes con grok-4.6 (los dos ultimos, hace 82 y 120 min). Ese ~9 % le alcanza a `ingenieria` hasta el reset. Renovar el OAuth **solo se puede en la maquina Windows** y con `--agent main` (`models auth login` es local por diseno: "Sign in for ... on this machine", sin flag para apuntar al gateway y sin RPC de auth; con varios agentes exige `--agent`, y `main` es el `systemAgent` del que los demas heredan). Si vence, `ingenieria` cae a zai — la cadena funcionando, no un bug. |
| deepseek | $51.35 (06:55Z) → $50.18 (07:23Z) → $49.74 (07:27Z), luego plano | El lead lo habia llamado "la cuota mas sana": **es falso**. Es saldo prepago y se mueve **a rafagas** atadas a la actividad de `main` (promedio $2.46/h en la ventana medida; ~$0.44 en 4 min en el pico; 0 cuando `main` esta quieto). Al mover `main` a zai deberia bajar bastante. Necesita alerta de saldo y plan de recarga. |
| zai, kimi | api-key, `status: static`, **sin metrica de cuota ni de saldo** | No hay forma de vigilarlas desde OpenClaw. Con estas cadenas, `main` (163 corridas/dia) queda sobre zai: el mayor consumidor sobre el proveedor sin medidor. Si zai se agota, se sabra por el fallo, no por el numero. |
| openai | 168h al **100 %**, reset 09-15 01:28Z | Fuera de toda cadena hasta el reset, y aun despues requiere la prueba de cruce de runtime (ver `eslabon-6-openai.md`). |

## 4. Como se ajusta despues (decision de David: arrancar y ajustar con datos)

No hay bake-off ahora. La evidencia se junta sola si se mira lo correcto dentro de ~1 semana:

- `openclaw audit --kind agent_run --status failed --agent <id>` → tasa de fallo por agente. Como cada agente tiene un primario estable y los fallbacks deberian ser raros, es buen proxy de "que tal le va a ese modelo en ese rol".
- **Limitacion conocida:** el audit **no** guarda que modelo atendio cada corrida (el campo viene vacio). Si los fallbacks dejan de ser raros, ese proxy se rompe y hay que cruzar con `model-fallback/decision` en los logs.
- `models.authStatus` → burn rate por proveedor (solo openai, xai, deepseek; zai y kimi nunca).
- Si con eso no alcanza para decidir, ahi si vale el bake-off: misma tarea real a `reviewer` con kimi vs glm vs deepseek. Los 4 agentes de pipeline tienen cero impacto de negocio.

## 5. Sin cambios

Guardrails del brief principal intactos, en particular: **preparas los patches, no los aplicas**; nada de `config patch` contra el gateway, ni doctor, ni restart, ni merge a `main`. El token de Anthropic no entra al repo ni al PR.

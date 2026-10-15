# M-13 (SUA-03), 2026-10-15 05:49-05:56Z, opencode 1.18.35 en la MacBook

Entorno como `opencode_env` (PWD, TMPDIR, OPENCODE_DISABLE_AUTOUPDATE, AGENT_WORK_MANAGED y OPENCODE_CONFIG_CONTENT con external_directory, enabled_providers y small_model), en un repo temporal por corrida. Script: `m13.sh`; salidas `<n>.out`, `<n>.err`, `<n>.meta`.

| Punto | Llave | Resultado | Aplica |
|---|---|---|---|
| a | `instructions: [<archivo>]` | El modelo repitió `NONCE-A-054929`, que solo estaba en el archivo | Sí |
| b | `skills.paths: [<dir>]` con una skill del mismo nombre en `~/.agents/skills` | opencode carga las dos y avisa `duplicate skill name ... existing=~/.agents/skills/... duplicate=<skills.paths>`: **gana `~/.agents/skills`**. Además lee `~/.claude/skills` (también con duplicados). El modelo no llamó a la herramienta `skill` y contestó una palabra que no estaba en ninguna, así que la carga se ve en el log y no en conducta | Se carga; pierde contra el global con el mismo nombre. Mitigado en G4: con `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` opencode 1.18.35 deja de leer `~/.agents/skills` y `~/.claude/skills` a la vez (medición del 2026-10-15: 102 skills → 1, solo built-in), y con `skills.paths` al paquete quedan solo las del paquete (62 = 61 del paquete + built-in; `poteto-mode` sale del paquete) |
| c | `agent.poteto-agent.model` | `message=stream agent=poteto-agent modelID=glm-5.3-flash` (su archivo lo fija a glm-5.3) | Sí |
| e | eventos del hijo | En stderr (`--print-logs`) aparecen las líneas `message=stream agent=poteto-agent`; en el flujo JSON de stdout solo el `tool_use` de `task` del padre | Solo en el log |
| d | `permission.edit: "deny"` | La herramienta de escribir y editar no se ofrece al modelo (dijo que no la tiene); no hay línea `evaluated`; `prueba.txt` no existe | Sí, quitando la herramienta |
| f | `evaluated ... allow` contra `tool_use` | 2 `evaluated` (read y bash) para 2 `tool_use` completados. La corrida no terminó: `stream error` del proveedor después de las herramientas y alarma a los 240 s | 1 a 1 en esta muestra |
| 2a | `task` a poteto-agent con `-m kimi` sin override | `ProviderModelNotFoundError: Model not found: zai-coding-plan/glm-5.3`: el hijo falla porque su proveedor no está en `enabled_providers` | Falla, como se esperaba |
| 2b | lo mismo con `agent.poteto-agent.model = kimi-code-plan-cn/kimi-for-coding` | `agent=poteto-agent modelID=kimi-for-coding`, `task` completado | Sí |

Para el diseño de SUA-03: (a), (c) y (d) se pueden usar en `opencode_env`. En (b) los nombres de las skills del paquete tienen que ser únicos frente a `~/.agents/skills` y `~/.claude/skills` (prefijo propio), porque el global gana. (e) la conducta del hijo se lee del log de stderr, no del flujo JSON. Sin el override de (c) cada hijo `poteto-agent` falla con un modelo que no sea de zai.

Nota de G3-r2: por el punto (b), `coverage.json` deja `contextGenerations` vacío: la generación 1 queda SIN certificar para encargos (solo corre con `--canario`). La generación 2, con nombres propios de skills, la construye G4 y la certifica M-16.

Nota de G4 (2026-10-15): la generación 2 ya no hace falta. La medición del 2026-10-15 (con `opencode debug skill`, sin turno de modelo) cerró el punto b por otro camino: `OPENCODE_DISABLE_EXTERNAL_SKILLS=1` deja fuera `~/.agents/skills` y `~/.claude/skills` a la vez (102 skills → 1, solo built-in), y con las dos variables más `skills.paths` al paquete quedan 62 = 61 del paquete + built-in, con `poteto-mode` saliendo del paquete. `opencode_env` la pone en toda corrida con paquete (`spec.config` no es None); un encargo sin perfil queda byte por byte igual. Falta probarlo en una corrida real (M-16 en el banco, que también certifica la generación 1): `debug skill` es el cargador, no un turno. `coverage.json` no cambia.

## M-16, banco real de la ruta por CLI

Entorno común de las tres corridas: R en `/Users/dn/dev/wt/r-sua02-c-gate` (`7b3db54226b`), opencode 1.18.35, modelo `zai-coding-plan/glm-5.3-flash` por suscripción, grupo de slot `_appserverusr`, casos con `--canary`. Cada corrida corre el banco (`test_agent_work_banco_e2e.py`) con opencode y modelo reales contra un repo temporal con `saluda()` en español y su prueba esperando `"hello"`.

| Corrida | Punta de G | Resultado | Causa |
|---|---|---|---|
| 1 | `04bc0a0b` | **ROJO 4/4.** 4 tests en 6122 s, `salida=1`. Los cuatro casos terminan con "nunca entregó resultado en 1500 s" | R rechazaba el typedPayload y el host no abría incidente: el modelo escribía el suyo propio (`{status, testOutput, ...}`, `{schema, verdict, findings, evidence}`) porque los briefs del banco no daban la forma que R valida, y el rechazo quedaba solo en el log del host, sin `invalid-result`. Arreglado en #308 |
| 2 | `5988b3a3` | **Revisión sana verde; el resto, rojo.** 5 tests en 774,624 s, `FAILED (failures=2, errors=1)`, `salida=1` | El banco abría el `artifact:<sha>` de R como ruta (la positiva de ingeniería y la revisión rota), y la medición de conducta del control salía con código 3 en vez de 1: las cuatro D de #308 |
| 3 | `4d7e56d4` | **VERDE 4/4.** 6 tests en 866,743 s, `OK`, `salida=0` (los cuatro casos y las dos pruebas de `Briefs`) | Sin causa: es la primera corrida que cierra el banco de cuatro casos |

De la corrida 1 también quedó visto, aunque el arnés no pudiera juzgarlo: el revisor sano aprobó con el repo intacto y el control sin paquete arregló el repo y citó la suite. Ninguna tarea llegó a `result-recorded`, así que la conducta no se pudo medir en esa corrida.

Las cuatro líneas `BANCO_E2E` de la corrida 3, literales:

```
BANCO_E2E case=ingenieria task=b20dfd41-f96e-4406-b66a-29f59935f2d8 conducta=ok suite_repo=pasa
BANCO_E2E case=revision-rota task=f9e2584b-9f31-4560-b691-a918d91ea59c verdict=changes
BANCO_E2E case=revision-sana task=bf48c575-541a-4d96-b32d-1beb9eeeb03f verdict=approved
BANCO_E2E case=control task=baac8465-a0d1-4e6a-9806-6b5e1b94c2e5 conducta=roja razones=['falta la lectura de contexto/skills/poteto-mode/SKILL.md antes del primer cambio', 'falta la lectura de contexto/skills/poteto-mode/playbooks/feature.md antes del primer cambio', "la primera lista no empieza con el primer paso del playbook: '`how` over the affected subsystem.'"]
```

### Corrida 4 (diez casos)

Pendiente: la escribe el coordinador al terminar la corrida.

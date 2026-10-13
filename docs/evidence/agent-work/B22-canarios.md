# B22, corte en vivo: recibo de los canarios

Es la evidencia del corte del host B8 al host de encargos y de los pedidos reales a `main` que lo probaron. Este recibo no cambia `coverage.json`, donde `mac-local/opencode` sigue `sandbox-tested-uncertified`.

```
medido:    2026-10-13 (UTC)
opencode:  1.18.35
host:      sesión host-encargos de tmux -L agent-work, lanzado con --canario
checkout:  ~/dev/wt/agent-work-host, en b2eb2662 al corte. Después en commits de la rama encargos/b22-fase3, sin merge,
           hasta ca56e496. Desde el intento 2 de qwen, en 6fa16cf9 (rama encargos/b22-fill)
spool:     ~/.local/state/agent-work-host/enc-1/ (host.sqlite, runs/, sessions/)
repo:      ~/dev/canario-encargos
R:         4acb881 en la Mini, sin cambios
hechos:    ~/.local/state/encargos-loop/B22/corte/HECHOS.md
crudos:    la misma carpeta. Por pedido: <nombre>.txt (el mensaje), <nombre>.json (la respuesta de main), <nombre>.estado y <nombre>.r
```

Cada pedido se mandó con `openclaw agent --agent main --session-key agent:main:b22-<nombre> --message-file <nombre>.txt --json`. Lo que R guarda de cada tarea se leyó en la Mini con `r-tarea.sh <taskId>`, que está en la carpeta de crudos.

En las tablas, `acknowledged|AbsenceVerified` es el estado de la operación y el estado de su recurso en `host.sqlite`. Cuando hay tres campos, el de en medio es el tipo del recurso (`TaskCreated`).

## Resumen

El host B8 está apagado. El host de encargos corre en `--canario`. El canario D, que es el criterio de aceptación de B22, pasó.

En el corte salieron cuatro defectos. Los tres primeros arreglos están en la rama `encargos/b22-fase3`. El cuarto es el commit `6fa16cf9`, de la rama `encargos/b22-fill`.

| Defecto | Dónde salió | Arreglo |
|---|---|---|
| El modelo dejó sus archivos temporales en `/tmp`, y el permiso negado sobre `/tmp/*` terminó la sesión sin resultado. | Canario A, intento 1 | `b2cd9682`: `TMPDIR` apunta a `runs/<op>/tmp/`. |
| `main` no registró tarea e hizo el trabajo con su propio `exec`. | Canario P, intentos 1 y 2 | `fd38670c` y `41ddb679`: descripción y regla nuevas en la skill `encargo-cli`. |
| La lectura de un archivo de fuera, el que nombra el `AGENTS.md` global de opencode, terminó la sesión sin acuse. | Estreno de grok, intento 1 | `ca56e496`: regla `"*": "deny"` en `external_directory`. La medición es M7. |
| El modelo escribió `artifactRef`, `digest` y `typedPayload` dentro de una llave `"fill"`, y el host rechazó el resultado. | Estreno de qwen, intento 1 | `6fa16cf9`: el paso 3 de la asignación (`cli_protocol` en `scripts/agent-work/host.py`) dice que los tres campos van al nivel de arriba del mismo objeto y que no se escribe una llave `fill`. |

Queda un límite medido y sin arreglo. La regla `external_directory` no confina el shell (sección "Límite medido").

## El corte, paso a paso

Los números de paso son los de la fase 2 en `~/.local/state/encargos-loop/B22/diseno/fases.md`.

| Paso | Qué se hizo | Resultado |
|---|---|---|
| Antes | Merge del PR #282 (fase 2) en `b2eb2662`. | El checkout del host, `~/dev/wt/agent-work-host`, se movió a ese commit. |
| 1 | Una pasada `--close-only` sobre el spool `mac-local-c` del host B8. | `errors: []`, 6 recursos, 0 pendientes. El respaldo es `mac-local-c/host.sqlite.pre-b22`. |
| 2 | Apagar el host B8 con `tmux -L agent-work kill-session -t '=host'`. | Su comando exacto quedó en `host-b8-cmd.txt` y su sha, `bff085d7`, en `host-b8-sha.txt`, los dos en la carpeta de crudos. La sesión adoptada `canario` sigue viva. |
| 3 | `lanzar-encargos.sh --canario`. | Imprimió `host: host-encargos arrancó`. `estado` contestó slot `free`, cli `1.18.35`, politica `d1c1fb615b3f` y canario `true`. `preparar --repo ~/dev/canario-encargos` contestó ok, con `zai-coding-plan/glm-5.3-flash`. |
| 4 y 5 | Los canarios A y P. | Están en la tabla de canarios. |
| 6 | Matar el host con `kill -TERM <pid>` y verlo volver. | Se hizo cuatro veces, una por cada cambio de código: pid `90791 → 44755 → 63389 → 8012`. Cada vez `estado` contestó con el pid y el commit nuevos en menos de 10 s. |

En `enc-1/host.log`, 4 pasadas fallaron con `gateway closed (1006 …): ssh tunnel did not start listening` o con `ssh exited (255)`. La pasada siguiente reclamó bien. Tres de las cuatro coinciden con un reinicio.

## Canarios

Cada fila es un pedido real a `main`.

| Canario | Tarea | Modelo | Qué pasó |
|---|---|---|---|
| A, intento 1 | `bc3fd7b9-d1b6-4e5d-884a-4618963c6824` | `zai-coding-plan/glm-5.3-flash`. El pedido no nombra modelo. | El modelo acusó recibo, creó `despedida.py` e hizo commit (`925dda2`). Dejó su script en `/tmp/result_gen.py`. `cat > /tmp/…` y `python3 /tmp/…` pasaron sin pedir permiso. `rm /tmp/result_gen.py /tmp/accept_gen.py` pidió `external_directory (/tmp/*)`. opencode lo negó solo, y la sesión terminó con salida 0 y sin resultado. El host dejó la incidencia `host:1:transport-unavailable:session-closed` y `permisosNegados ["external_directory:/tmp/*"]`. `main` canceló. Final: `cancelled\|TaskCreated\|AbsenceVerified`, con la frontera vacía. |
| A, intento 2 | `381d9dfa-8eb7-4283-ad0b-27cfa727e75e` | `zai-coding-plan/glm-5.3-flash` | PASA. Host en `b2cd9682`, con `TMPDIR` dentro de la corrida. Final: `acknowledged\|TaskCreated\|AbsenceVerified`. `gracias.py` quedó con grupo `staff`, en el commit `e91f464`. `proveedoresLlamados ["zai-coding-plan"]`, `carpetaDeSesion /Users/dn/dev/canario-encargos` y 0 permisos pedidos. No quedó ninguna sesión `enc-*`, el grupo quedó vacío y `managed-briefs` sigue en 10. En R: `result_json` presente, admisión `admitted` y `host_closure` `AbsenceVerified`. Pasaron 64,8 s entre el `created_at` de la tarea y el cierre del host en R. |
| P, intentos 1 y 2 | ninguna | No llegó al host. | `main` no registró tarea. Creó `/Users/dn/.local/state/agent-work-host/enc-1/b22-fuera-de-la-corrida.txt` con su propio `exec` y contestó "creado por CLI". El intento 1 corrió con la skill vieja. El intento 2 corrió con la primera versión de la skill nueva, y `main` no la abrió (`toolSummary.tools ["exec"]`). La causa es que la descripción de la skill hablaba de "trabajo sobre un repo". El arreglo son los commits `fd38670c` y `41ddb679`. Los dos archivos se borraron. |
| P, intento 3 | `a2a8239e-f7ec-4207-a05a-04943c81da1a` | `zai-coding-plan/glm-5.3-flash` | Con la skill de `41ddb679`, `main` usó la ruta entera: `preparar`, brief con cabecera, submit y admit. El modelo leyó el paso 4 de la asignación y dijo que la ruta pedida queda fuera de `workspaceRef` y de la carpeta de la corrida. Creó el archivo dentro del repo. El archivo de fuera no existe. Final: `acknowledged\|AbsenceVerified`. Este intento no ejercitó la negación de opencode. La ejercitaron el canario A, intento 1, y el estreno de grok. |
| B | `6897623c-2efa-49d3-bc48-0d5e252ddc67` | `zai-coding-plan/glm-5.3-highspeed`. El pedido dice "glm 5.3 highspeed". | El modelo viajó. `argv.json` trae `-m zai-coding-plan/glm-5.3-highspeed` y el brief empieza con la cabecera. El proveedor lo rechazó. La incidencia es `launch-failed`, con salida 1 y la frase "opencode salió sin acusar recibo. opencode dijo: Your current subscription plan does not yet include access to GLM-5.3-Highspeed.". `main` canceló con esa frase. Final: `cancelled\|AbsenceVerified`. |
| C | ninguna | `opencode-go/deepseek-v4-pro` | `main` contestó: "opencode-go está cerrado para encargos. David, 2026-10-12: «open code go es solamente para main». Permitidos con sesión: glm, grok, gpt, muse, kimi, qwen, deepseek. Permitidos sin sesión todavía: claude." El host no tuvo ninguna operación nueva. |
| D | `595755ae-247d-4ccc-993e-4754928ddb20` | `zai-coding-plan/glm-4.7`, que nunca había corrido aquí. El pedido dice "glm 4.7". | PASA. Final: `acknowledged\|AbsenceVerified`, con `argv -m zai-coding-plan/glm-4.7` y el resultado en R. Nadie editó ningún archivo entre B y D. Es el criterio de aceptación de B22. |
| E | ninguna | El pedido dice "claude". | `main` contestó: "claude está permitido, pero su suscripción no entra por opencode, que de anthropic solo acepta llave de API. Su ruta propia está pendiente (fila B22-S5 de followups.md)." El host no tuvo ninguna operación nueva. El canario E del diseño era kimi sin sesión. David ya inició sesión en kimi, así que se usó el único proveedor permitido sin sesión. |

### Salidas literales del canario A, intento 2

De `canario-a2-evidencia.txt`, tomado a las 04:58:58Z. Las dos operaciones del spool, con el intento 1 primero:

```
5237cd43d8125148cf0e79fa85be934fd4be402331339a5bf64dcb1e15031001|bc3fd7b9-d1b6-4e5d-884a-4618963c6824|cancelled|TaskCreated|AbsenceVerified|
687955d579ae284dc32272c3663ba4e88cfae159bfde0f3855f3991e70e56cab|381d9dfa-8eb7-4283-ad0b-27cfa727e75e|acknowledged|TaskCreated|AbsenceVerified|
```

La prueba del cierre de cada una. La línea de `boundary_before` se corta con `[…]`:

```
5237cd43d8125148cf0e79fa85be934fd4be402331339a5bf64dcb1e15031001|{"boundary_after":[],"boundary_before":[],"pane_gone":true,"session_gone":true,"signals":[]}
687955d579ae284dc32272c3663ba4e88cfae159bfde0f3855f3991e70e56cab|{"boundary_after":[],"boundary_before":["46022 Tue Oct 13 04:57:49 2026 /opt/homebrew/bin/opencode run -m zai-coding-plan/glm-5.3-flash --format json --print-logs --log-level INFO --title 381d9dfa-8eb7-4283-ad0b-27cfa727e75e Open assignment JSON at […]"],"pane_gone":true,"session_gone":true,"signals":["SIGTERM 46022"]}
```

El contenido de `enc-1/runs/687955d5…0e56cab/`:

```
accept.json
assignment.json
brief
result.json
tmp
```

`runs/687955d5…0e56cab/tmp/` contiene `opencode`. opencode usó el `TMPDIR` de la corrida, y la ruta larga no rompió nada.

`encargo.py estado --tarea 381d9dfa-8eb7-4283-ad0b-27cfa727e75e`, sin `logTail`:

```
{"ok": true, "tarea": "381d9dfa-8eb7-4283-ad0b-27cfa727e75e", "modelo": "zai-coding-plan/glm-5.3-flash", "cobro": "subscription", "estado": "acknowledged", "cierre": "AbsenceVerified", "explicacion": null, "permisosNegados": [], "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": null}
```

`sessions/<op>/argv.json` empieza así. Trae `--print-logs --log-level INFO`, las dos banderas que le faltaban a M5 (`B22-fase0.md`, "Lo que falta para cerrar este recibo"):

```
["/opt/homebrew/bin/opencode","run","-m","zai-coding-plan/glm-5.3-flash","--format","json","--print-logs","--log-level","INFO","--title","381d9dfa-8eb7-4283-ad0b-27cfa727e75e","Open assignment JSON at […]
```

### Salidas literales de B, D y P

`b.estado`:

```
{"ok": true, "tarea": "6897623c-2efa-49d3-bc48-0d5e252ddc67", "modelo": "zai-coding-plan/glm-5.3-highspeed", "cobro": "subscription", "estado": "cancelled", "cierre": "AbsenceVerified", "explicacion": {"causa": "launch-failed", "frase": "opencode salió sin acusar recibo. opencode dijo: Your current subscription plan does not yet include access to GLM-5.3-Highspeed.", "accion": "cancelar"}, "permisosNegados": [], "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": 1}
```

`d.estado`:

```
{"ok": true, "tarea": "595755ae-247d-4ccc-993e-4754928ddb20", "modelo": "zai-coding-plan/glm-4.7", "cobro": "subscription", "estado": "acknowledged", "cierre": "AbsenceVerified", "explicacion": null, "permisosNegados": [], "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": null}
```

`p3.estado`:

```
{"ok": true, "tarea": "a2a8239e-f7ec-4207-a05a-04943c81da1a", "modelo": "zai-coding-plan/glm-5.3-flash", "cobro": "subscription", "estado": "acknowledged", "cierre": "AbsenceVerified", "explicacion": null, "permisosNegados": [], "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": null}
```

## Estrenos por proveedor

Un encargo chico por suscripción, también pedido a `main`.

| Proveedor | Tarea | Modelo | Qué pasó |
|---|---|---|---|
| grok, intento 1 | `730557f4-a19d-4a48-ae11-eaa6b6d90319` | `xai/grok-4.7` | Host en `fd38670c`. La primera llamada del modelo leyó `/Users/dn/.agents/pstack-plataformas/opencode.md`, el archivo que nombra `~/.config/opencode/AGENTS.md`, la configuración global de opencode. opencode pidió `external_directory`, lo negó solo y la sesión terminó sin acuse. La incidencia es `launch-failed`, con `permisosNegados ["external_directory:/Users/dn/.agents/pstack-plataformas/*"]`. `main` canceló y le avisó a David por Telegram. |
| gpt | `92133b3a-1340-43e2-973d-48e0cf8e4789` | `openai/gpt-5.5` | La incidencia es `launch-failed`, con salida 1 y "opencode dijo: The usage limit has been reached.". La suscripción de OpenAI de David está en su límite de uso. `main` canceló. |
| grok, intento 2 | `6ed852ea-281c-47c6-9313-1c0d6c7c9de4` | `xai/grok-4.7` | PASA. Host en `ca56e496`, con la regla `deny`. Final: `acknowledged\|AbsenceVerified`, con `suma.py`. `permisosNegados ["external_directory:/Users/dn/.agents/pstack-plataformas/*", "external_directory:/Users/dn/.local/state/agent-work-host/*"]`. opencode negó las dos, el modelo siguió y entregó. `proveedoresLlamados ["xai"]`. En R: resultado y `host_closure` `AbsenceVerified`. |
| muse | `cb7caa06-02ca-4b81-bf98-2241472accd2` | `meta/muse-spark-1.3` | PASA. Final: `acknowledged\|AbsenceVerified`, con `producto.py`. `proveedoresLlamados ["meta"]` y 0 permisos negados. En R: resultado y `host_closure` `AbsenceVerified`. |
| kimi | `d308af29-2ba6-44d3-b634-e08c3d5e7882` | `kimi-code-plan-cn/kimi-for-coding` | PASA. Final: `acknowledged\|AbsenceVerified`, con `cociente.py`. `proveedoresLlamados ["kimi-code-plan-cn"]` y 0 permisos negados. En R: resultado y `host_closure` `AbsenceVerified`. |
| qwen, intento 1 | `15190266-1932-4aa9-873b-ff8f751020b8` | `alibaba-token-plan/qwen3.6-flash` | El modelo hizo el trabajo (`potencia.py`, commit `ec82d4a`). Escribió `artifactRef`, `digest` y `typedPayload` dentro de una llave `"fill"`. La incidencia es `invalid-result`, con la frase "El resultado llegó mal formado.". `main` canceló. Final: `cancelled\|AbsenceVerified`. |
| qwen, intento 2 | `97c5e11b-f54b-49ea-9dae-0fed16e133bd` | `alibaba-token-plan/qwen3.6-flash` | Host en `6fa16cf9`, con el paso 3 de la asignación aclarado. El modelo ya no anidó los campos bajo `fill`. Omitió `artifactRef` y escribió `artifactDigest` en lugar de `digest`. La incidencia es `invalid-result`. La tarea se canceló. Final: `cancelled\|AbsenceVerified`. `resto.py` quedó hecho. |
| qwen, intento 3 | `0b834fe7-aa68-4bd0-8a88-2b78f0c712e7` | `alibaba-token-plan/qwen3.8-max` | PASA. Final: `acknowledged\|AbsenceVerified`, con `maximo.py`. `proveedoresLlamados ["alibaba-token-plan"]`. En R: resultado y `host_closure` `AbsenceVerified`. |
| deepseek | no corrido | - | Cobra por token. Su estreno espera a que David lo pida. |

La suscripción de Qwen funciona. `qwen3.6-flash` no siguió el protocolo de resultado en dos intentos. El host lo detectó y lo reportó, sin dejar nada vivo. `estado --tarea` dice "El resultado llegó mal formado." y no dice qué campo falló (`followups.md`, fila B22-S9).

`estreno-grok.estado`, el intento 1:

```
{"ok": true, "tarea": "730557f4-a19d-4a48-ae11-eaa6b6d90319", "modelo": "xai/grok-4.7", "cobro": "subscription", "estado": "cancelled", "cierre": "AbsenceVerified", "explicacion": {"causa": "launch-failed", "frase": "opencode salió sin acusar recibo. opencode negó external_directory sobre /Users/dn/.agents/pstack-plataformas/*.", "accion": "cancelar"}, "permisosNegados": ["external_directory:/Users/dn/.agents/pstack-plataformas/*"], "proveedoresLlamados": ["xai"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": 0}
```

`estreno-grok2.estado`, el intento 2:

```
{"ok": true, "tarea": "6ed852ea-281c-47c6-9313-1c0d6c7c9de4", "modelo": "xai/grok-4.7", "cobro": "subscription", "estado": "acknowledged", "cierre": "AbsenceVerified", "explicacion": null, "permisosNegados": ["external_directory:/Users/dn/.agents/pstack-plataformas/*", "external_directory:/Users/dn/.local/state/agent-work-host/*"], "proveedoresLlamados": ["xai"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": null}
```

`estreno-grok2.r` trae el resultado de la tarea y `managed_task_host_closures: 0`. El `host_closure` de la tabla sale de `HECHOS.md`.

`estreno-qwen.estado`, el intento 1. `estreno-qwen2.estado` trae la misma `explicacion`:

```
{"ok": true, "tarea": "15190266-1932-4aa9-873b-ff8f751020b8", "modelo": "alibaba-token-plan/qwen3.6-flash", "cobro": "subscription", "estado": "cancelled", "cierre": "AbsenceVerified", "explicacion": {"causa": "invalid-result", "frase": "El resultado llegó mal formado.", "accion": "cancelar"}, "permisosNegados": [], "proveedoresLlamados": ["alibaba-token-plan"], "carpetaDeSesion": "/Users/dn/dev/canario-encargos", "salida": 0}
```

## M7: regla "deny" contra "ask"

Pregunta. Con una regla `"*": "deny"` en `external_directory`, ¿una llamada a algo de fuera termina la sesión, como hace el "ask" por omisión?

Medido con opencode 1.18.35 y `zai-coding-plan/glm-5.3-flash`, en un repo temporal. El entorno es igual al del host, con este `OPENCODE_CONFIG_CONTENT`:

```
{"permission":{"external_directory":{"*":"deny","<corrida>/**":"allow"}},"enabled_providers":["zai-coding-plan"],"small_model":"zai-coding-plan/glm-5.3-flash"}
```

Pedido. Leer con la herramienta `read` un archivo de fuera, correr `rm` sobre ese archivo y después crear `fin.txt`.

Salida literal. stderr, una vez por cada llamada:

```
message=evaluated permission=external_directory pattern=<fuera>/* action.permission=external_directory action.pattern=* action.action=deny
```

El flujo trae un `tool_use` de `read` y uno de `bash` con `status error` y este error:

```
error: "The user has specified a rule which prevents you from using this specific tool call. Here are some of the relevant rules […]"
```

Después trae un `tool_use` de `write` con estado `completed`. El archivo de fuera sigue ahí. `fin.txt` existe y cuenta lo que pasó. El proceso salió con 0.

Con el "ask" por omisión, la misma llamada termina la sesión (`B22-fase0.md`, M2 y M6):

```
permission requested: … ; auto-rejecting
```

Veredicto: **medido**. Con "deny" el modelo recibe el error de la llamada y sigue. Con "ask" opencode rechaza y la sesión termina.

Lo que fija. "Rechaza y termina", la conclusión de M2 y M6, vale para un permiso "ask" y no para una regla "deny". El host lanza con las dos reglas, `"*": "deny"` y `<corrida>/**: allow` (`opencode_env` en `scripts/agent-work/sesion.py`). `read_events` lee la línea `message=evaluated … action.action=deny` de stderr y `estado --tarea` la lista en `permisosNegados`, aunque el encargo termine bien.

## Límite medido: la guarda de carpeta no confina el shell

En el canario A, intento 1, estos dos comandos corrieron sin que opencode pidiera permiso:

```
cat > /tmp/accept_gen.py << 'EOF' …
python3 /tmp/accept_gen.py
```

Solo `rm /tmp/…` lo pidió.

`external_directory` cubre las herramientas de archivo de opencode (`read`, `write`, `edit`, `glob`) y las rutas que opencode reconoce como argumento de ciertos comandos. Una redirección del shell o un script escriben donde la cuenta del operador pueda. No se midió una lista completa de los comandos que opencode reconoce. Un confinamiento real, por ejemplo `sandbox-exec` con un perfil por corrida, no existe hoy (`followups.md`, fila B22-S7).

## Otros hechos

- Durante el canario A, intento 1, el grupo tenía, además de opencode, un hijo suyo: `node /Users/dn/.tokentracker/tracker/app/bin/tracker.js sync --auto --from-notify --source opencode`. Es un plugin de la configuración global de opencode. El barrido del grupo lo cubre.
- `main` le avisa a David por Telegram el resultado de cada encargo, también de los de prueba.
- En la Mini quedaron publicados `~/.local/share/agent-work/brief.py` (sha256 `dd9ef198…59f9`) y la skill `encargo-cli` de `41ddb679` (sha256 `8ca5f42a6da68c1d…`). El respaldo de lo anterior está en `~/.openclaw/respaldos/pre-b22f3-20261013T050317Z/`.
- Estado vivo al cerrar las mediciones: `host-encargos` en `--canario`, con el checkout del host en `6fa16cf9`.

## Lo que falta para cerrar este recibo

1. El estreno de gpt no entregó trabajo, porque la suscripción de OpenAI está en su límite de uso.
2. El estreno de deepseek espera a que David lo pida.
3. La certificación. `coverage.json` no cambia con este recibo (`followups.md`, fila B22).
4. El confinamiento real del proceso (`followups.md`, fila B22-S7).
5. Que `estado --tarea` diga qué campo de un resultado falló (`followups.md`, fila B22-S9).

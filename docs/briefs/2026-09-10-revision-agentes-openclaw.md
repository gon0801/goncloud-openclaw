# Revision de los agentes OpenClaw — por que fallan y que cambiar

Fecha: 2026-09-10 ~07:20Z. Fuente: config viva del gateway (`config.get`), `audit` (500 eventos), `logs` (ultimos 70 min), `chat.history` de 9 sesiones, `models.authStatus`, `plugins.list`, `sessions.list` por agente, y los archivos de este repo. Meta: que los agentes hagan tareas de ingenieria con la fiabilidad de Grok.

## 1. Diagnostico (con numeros)

**Corridas (audit, ultimos 500 eventos):**

| agente | ok | failed | cancelled | timed_out | modelo primario | runtime |
|---|---|---|---|---|---|---|
| main | 152 | 10 | 7 | 1 | deepseek-v4-flash | nativo |
| operaciones | 35 | 1 | 0 | 0 | zai/glm-5.3 | nativo |
| ingenieria | 29 | 4 | 0 | 0 | openai/gpt-5.3-codex-spark | **codex** |
| implementer | 3 | 0 | 0 | 1 | openai/gpt-5.5 | **codex** |
| verifier | 3 | 0 | 0 | 0 | openai/gpt-5.6-luna | **codex** |
| reviewer | **0** | 1 | 0 | 0 | openai/gpt-5.5-pro | **codex** |
| adversary | **0** | 1 | 0 | 0 | openai/gpt-5.5-pro | **codex** |

reviewer y adversary nunca han completado una corrida. Su unica sesion (05:11Z) tiene 1 mensaje (el encargo) y murio en 13 s sin respuesta. `main` lo compenso lanzando subagentes genericos con **grok-4.6** a las 05:21Z, y esos SI entregaron veredictos con sustancia (REQUEST_CHANGES razonados).

**Causa raiz #1 — cuota y plan de OpenAI.** `models.authStatus` del gateway: OpenAI OAuth plan `prolite`, ventana 168h **100 % usada** (reset 2026-09-15 01:28Z), 0 creditos. Los 5 agentes de ingenieria tienen primario OpenAI OAuth y reviewer/adversary tienen fallbacks tambien OpenAI (gpt-5.5, gpt-5.6-sol) → sin salida. Ademas gpt-5.5-**pro** probablemente exige un plan superior a prolite (no verificado). ingenieria cae a deepseek-flash: en 90 s el log muestra 7 `model fallback decision` y 4 `prepared model runtime plugin generation was superseded` (cambio de runtime codex→nativo a mitad de turno = sus 4 fallos).

**Causa raiz #2 — runtime codex.** Todo modelo OpenAI por OAuth corre en el harness **codex**, no en el loop nativo. Bajo codex, tools de OpenClaw desaparecen: verifier recibio `message failed: Unavailable in this run`, `progress_card failed: Unavailable in this run`, `exec: exec host not allowed (requested gateway; configured host is node)`. Los AGENTS.md les ordenan usar justo esas tools. No esta documentado si los hooks de summa-gate (merge-guard) se disparan dentro del harness codex → el candado de merge puede no aplicar a implementer/ingenieria.

**Causa raiz #3 — main (el cerebro) usa el modelo mas debil.** deepseek-v4-flash como primario del orquestador que habla contigo por Telegram, lanza subagentes y decide: 163 corridas/dia, 2 `empty response detected ... retrying` por hora, heartbeat cada 30 min. El resto de tu flota tiene mejor modelo que el que coordina.

**Otras fuentes de error medidas:**
- `sessions_search` → `unable to open database file` en TODAS las llamadas (main, verifier, subagentes). La memoria entre sesiones esta rota.
- Agentes adivinando rutas/flags: `read` de archivos inexistentes (verify_census_holes.sh, docs bajo node_modules), `ls C:\Users\ehven\.openclaw\cron` (ENOENT x3), `openclaw cron edit ... -sS` (flag inventado, x3).
- Ruido que come contexto en exec por nodo Mac: `Warning: tools.exec.pathPrepend is ignored for host=node` en 33/80 resultados de implementer y 31/120 de ingenieria; Edge headless escupe 36 lineas `CVDisplayLinkCreateWithCGDisplay failed` por screenshot; `view_image` bloquea IPs privadas y `file_fetch` esta bloqueado en el nodo → los agentes inventaron un `http.server` para mover archivos.
- Gateway: `slow SQLite transaction hold` x15/hora; un restart a las 23:05 (-07) dejo `restart recovery claim changed before agent adoption` y `admitted run authority is no longer active` (corridas canceladas); `sessions_send announce flow failed` x3 (los reportes operaciones→main no llegan a Telegram); `COMPANION_APP_UNAVAILABLE` intermitente en el nodo.
- Cuotas restantes: xAI SuperGrok semanal **85 % usada** (reset 09-12 23:57Z), prepago $3.22, OAuth **expira en ~1 h** (verificar que refresca solo); DeepSeek $51; zai/kimi api-key sin dato de cuota.

**Workspaces de implementer/reviewer/adversary/verifier (este repo):** IDENTITY.md = plantilla sin llenar; USER.md con la directiva placeholder `Prefer ...` activa (la propia plantilla dice que nunca se deje); SOUL.md stock; BOOTSTRAP.md stock ("birth sequence") en 3 de 4 → ritual de presentacion en cada sesion nueva. Los AGENTS.md tienen buen contenido (principios saikit) pero estan escritos para Claude Code: tool `Write` (en OpenClaw es `write`), `ctx7`, skills `saikit:auth-security` inexistentes aqui, rutas `.saikit/veredictos/<sha>.json` relativas a un repo que el agente no tiene.

**summa-gate:** cargado (`plugins.list`: enabled, source=config). Detalles: `canonicalRole` evalua `test` antes que `implement` (un label "implementer: fix tests" se registra como verifier); el sentinel se desarma con cualquier mensaje siguiente sin `-saikit`; no verificado bajo codex.

**Skills:** buenas como bitacora de lecciones, pero duplicadas por agente con deriva (routing de Telegram cambio en una y no en otra), contradictorias entre si (chip del destinatario en Gmail), y varias documentan workarounds de problemas que se arreglan en config (PATH del nodo, file_fetch, approvals tras restart).

## 2. Que cambiar (orden de impacto)

### A. Modelos y cuotas — hoy
1. Sacar OpenAI OAuth como primario de los 5 agentes de ingenieria hasta el reset (09-15) o hasta subir de plan. Ningun fallback puede ser OpenAI.
2. Asignacion propuesta (segun tu propia tabla de delegacion — GLM logica compleja, Kimi revisa, Grok ops — y cuotas reales):
   - `main` → `zai/glm-5.3` primario, `deepseek/deepseek-v4-pro` fallback, `xai/grok-4.6` tercero. (Cuando xAI resetee el 09-12, evaluar grok-4.6 como primario de main con tope de gasto.)
   - `ingenieria` (infra/ops, nodo Mac) → `xai/grok-4.6` primario, `zai/glm-5.3` fallback. Es el que mas se parece a "tipo Grok".
   - `implementer` → `zai/glm-5.3`, fallback `deepseek/deepseek-v4-pro`.
   - `reviewer` y `adversary` → `kimi/k3`, fallback `deepseek/deepseek-v4-pro`.
   - `verifier` → `deepseek/deepseek-v4-pro`, fallback `zai/glm-5.3`.
   - OpenAI (gpt-5.6-sol) queda como ultimo fallback SOLO en main, y solo despues del reset.
3. Renovar el OAuth de xAI hoy (`openclaw models auth login --provider xai`) si en 1 h no refresco solo; revisar cuota semanal antes de mover a grok todo.
4. Efecto colateral deseado: al no ser OpenAI-OAuth, los 5 agentes vuelven al runtime nativo → recuperan `message`, `progress_card`, `sessions_send`, y summa-gate aplica seguro.

### B. Workspaces de los 4 agentes de pipeline
5. Borrar BOOTSTRAP.md de los 4; llenar IDENTITY.md (nombre, emoji, tema en una linea); USER.md con 3-5 directivas reales (idioma, formato de reporte, "nunca adivinar rutas: pedirlas al lead"); recortar SOUL.md a 10 lineas de personalidad util.
6. AGENTS.md: traducir a OpenClaw (tools `write/edit/read/exec/sessions_send`, `context7__query-docs`, workshop-skills reales); quitar instrucciones de tools que no existen; anadir el contrato de dispatch: el lead pasa SIEMPRE rutas absolutas y el nombre del repo; el agente no explora rutas fuera de ese scope ni inventa flags de CLI (si duda: `<cli> --help` primero).
7. Reglas "estilo Grok" explicitas y cortas en los 4: backup antes de modificar, cambios aditivos, declarar incidentes propios, evidencia real (salida de comando) antes de afirmar, un `--help` antes de un flag nuevo.

### C. Nodo Mac (donde ejecutan los 5)
8. Quitar el warning de `pathPrepend` (esta llegando aunque no este en config: revisar override por agente/nodo) y configurar PATH en el servicio del nodo (`/opt/homebrew/bin`, `~/.local/bin`) como pide el propio warning; asi dejan de usar rutas absolutas y el warning deja de comer contexto.
9. Wrapper `~/bin/shot.sh` para screenshots headless (Edge con `2>/dev/null`) → 0 lineas de ruido.
10. Habilitar `file_fetch`/`dir_fetch` para el nodo (allowlist) y eliminar el hack del `http.server`; y `view_image` para la LAN si hace falta.

### D. Gateway
11. `openclaw doctor` (sin `--fix` primero) → resolver `sessions_search: unable to open database file`; revisar indice de memoria local (`memory.search.local.modelPath`) y el sqlite de estado.
12. No reiniciar el gateway con corridas activas (los `admitted run authority is no longer active` son eso); si hace falta, `cron disable` de los jobs largos antes.
13. `sessions_send` a main: definir delivery explicita (telegram + chat) para que los reportes operaciones→main lleguen; hoy fallan en silencio.
14. `slow SQLite transaction hold`: revisar que `state/openclaw.sqlite` no este bajo antivirus/OneDrive; si persiste, `openclaw backup` + `doctor --fix`.

### E. summa-gate y skills
15. summa-gate: reordenar `canonicalRole` (implementer antes que test/verif); test del merge-guard con un agente en runtime codex (si sigue habiendo alguno): `git push --dry-run origin main` en un repo de prueba debe salir bloqueado.
16. Skills compartidas en `~/.openclaw/skills/` (una copia) en vez de por agente; resolver contradicciones (Gmail chip, routing Telegram) y borrar las que documentan workarounds ya corregidos por C.

### F. Observabilidad
17. Audit con contenido de error (hoy `redaction: metadata_only` → el `--explain` no sirve); revision semanal `openclaw audit --status failed`.
18. Presupuesto por agente: main hace 163 corridas/dia + heartbeat 30 min; con glm/grok eso cuesta. Heartbeat a 60 min y `timeoutSeconds` por agente.

## 3. Lo que NO pude verificar
- Si gpt-5.5-pro esta disponible en plan prolite (la evidencia es indirecta: 0 respuestas).
- Si los hooks de summa-gate se disparan bajo runtime codex (docs no lo cubren).
- Cuota real de zai y kimi (api-key, sin metricas).
- Logs de antes de las 05:43Z (el RPC solo entrega el ultimo MB).
